import AppKit
import CoreGraphics
import IOKit
import UserNotifications

/// Samples WindowServer's GPU time twice a second and feeds app lifecycle and window changes to
/// `CompositorAttribution`, so a spike is named within seconds of the app that caused it.
///
/// Each tick reads the IOAccelerator client list (well under a millisecond) and, every other tick,
/// the on-screen window list. Published values only change when they move noticeably, so idle
/// ticks do not re-render anything.
@MainActor
final class CompositorMonitor: ObservableObject {
    static let backgroundDetectionKey = "compositorBackgroundDetection"
    static let notificationsKey = "compositorNotifications"

    @Published private(set) var compositorGPU: Double = 0
    @Published private(set) var floor: Double = 0
    @Published private(set) var unexplained: Double = 0
    @Published private(set) var contributions: [String: CompositorAttribution.Contribution] = [:]
    @Published private(set) var findings: [CompositorAttribution.Finding] = []
    /// The latest spike worth telling the user about.
    @Published var alert: CompositorAttribution.Finding?
    @Published private(set) var isRunning = false

    private(set) var compositorPID: pid_t?
    /// Set while the probe hides apps itself, so those hides are not read as natural experiments.
    var suspendEvents = false {
        didSet { if !suspendEvents { attribution.discardPendingEvents() } }
    }

    private var attribution = CompositorAttribution(ignoredPath: Bundle.main.bundleURL.standardizedFileURL.path)
    private var loop: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var lastCompositorTime: (time: UInt64, gpu: UInt64)?
    private var windowPresence: [String: Double] = [:]
    private var identities: [pid_t: CompositorApp] = [:]
    private var frontmost: CompositorApp?
    private var tick = 0
    private var lastGaugePublish: Double = 0
    private let clients = CompositorClients()
    private let alertThreshold = 8.0

    var sortedContributions: [CompositorAttribution.Contribution] {
        contributions.values.sorted { $0.value > $1.value }
    }

    var totalAttributed: Double { attribution.totalAttributed }

    func contribution(for location: URL) -> CompositorAttribution.Contribution? {
        // Locations come from resolved paths already; no need to standardize on every lookup.
        contributions[location.path]
    }

    func start() {
        guard loop == nil else { return }
        isRunning = true
        if observers.isEmpty { observeWorkspace() }
        frontmost = NSWorkspace.shared.frontmostApplication.map(identity(of:))
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let readWindows = self.tick.isMultiple(of: 4)
                self.tick += 1
                let clients = self.clients
                let reading = await Task.detached(priority: .utility) { Self.read(clients: clients, windows: readWindows) }.value
                self.process(reading)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        isRunning = false
        lastCompositorTime = nil
    }

    func recordProbe(_ results: [CompositorProbe.Result], noise: Double, baseline: Double) {
        let now = Self.now()
        for result in results {
            attribution.recordProbe(app: result.app, drop: result.compositorDrop, noise: noise, baseline: baseline, at: now)
        }
        publishContributions()
    }

    func suspicion(of path: String) -> Double {
        attribution.suspicion(of: path, now: Self.now())
    }

    // MARK: Sampling

    private struct Reading: Sendable {
        let time: UInt64
        let compositorPID: pid_t?
        /// WindowServer's accumulated GPU nanoseconds across its clients.
        let compositorTime: UInt64?
        /// On-screen normal windows: owner pid → total area. Nil on ticks that skip the window list.
        let windows: [pid_t: Double]?
    }

    private nonisolated static func read(clients: CompositorClients, windows readWindows: Bool) -> Reading {
        let compositor = clients.read()
        var windows: [pid_t: Double]?
        if readWindows {
            windows = [:]
            // Owner pid and bounds need no screen-recording permission.
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            for window in list {
                guard (window[kCGWindowLayer as String] as? Int) == 0,
                      let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                      let bounds = window[kCGWindowBounds as String] as? [String: Double] else { continue }
                let area = (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
                if area >= 2_500 { windows?[pid, default: 0] += area } // ignore tiny utility windows
            }
        }
        return Reading(time: DispatchTime.now().uptimeNanoseconds, compositorPID: compositor?.pid,
                       compositorTime: compositor?.time, windows: windows)
    }

    private func process(_ reading: Reading) {
        compositorPID = reading.compositorPID
        guard let gpu = reading.compositorTime else { return }
        defer { lastCompositorTime = (reading.time, gpu) }
        guard let last = lastCompositorTime, reading.time > last.time, gpu >= last.gpu else { return }

        let now = Double(reading.time) / 1e9
        if let windows = reading.windows { detectWindowChanges(windows, now: now) }
        let value = Double(gpu - last.gpu) / Double(reading.time - last.time) * 100
        let found = attribution.record(value, at: now)
        publish(now: now)
        found.forEach(report)
    }

    private func publish(now: Double) {
        // The gauge re-renders whatever shows it; refresh it every two seconds unless it jumps.
        let jump = abs(attribution.current - compositorGPU) >= 10
        if jump || now - lastGaugePublish >= 2 {
            if abs(attribution.current - compositorGPU) >= 0.5 { compositorGPU = attribution.current }
            if abs(attribution.floor - floor) >= 0.5 { floor = attribution.floor }
            lastGaugePublish = now
        }
        if abs(attribution.unexplained - unexplained) >= 1 || (attribution.unexplained == 0) != (unexplained == 0) {
            unexplained = attribution.unexplained
        }
        publishContributions()
    }

    private func publishContributions() {
        let next = attribution.contributions
        let changed = next.count != contributions.count || next.contains { key, value in
            guard let old = contributions[key] else { return true }
            return abs(old.value - value.value) >= 0.5
        }
        if changed { contributions = next }
    }

    private func report(_ finding: CompositorAttribution.Finding) {
        findings.insert(finding, at: 0)
        if findings.count > 30 { findings.removeLast(findings.count - 30) }
        guard finding.kind.turnsOn, finding.delta >= alertThreshold else { return }
        alert = finding
        if UserDefaults.standard.object(forKey: Self.notificationsKey) as? Bool ?? true { notify(finding) }
    }

    // MARK: Events

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, CompositorAttribution.EventKind)] = [
            (NSWorkspace.didLaunchApplicationNotification, .launched),
            (NSWorkspace.didActivateApplicationNotification, .activated),
            (NSWorkspace.didUnhideApplicationNotification, .unhidden),
            (NSWorkspace.didHideApplicationNotification, .hidden),
            (NSWorkspace.didTerminateApplicationNotification, .terminated)
        ]
        for (name, kind) in events {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.handle(kind, app: app) }
            })
        }
    }

    private func handle(_ kind: CompositorAttribution.EventKind, app running: NSRunningApplication) {
        guard isRunning, running.activationPolicy == .regular || kind == .terminated else { return }
        let app = identity(of: running)
        var previous: CompositorApp?
        if kind == .activated {
            previous = frontmost
            frontmost = app
            if previous?.id == app.id { return }
        }
        if kind == .terminated { identities[running.processIdentifier] = nil }
        guard !suspendEvents else { return }
        attribution.enqueue(app, kind, previous: previous, at: Self.now())
        publishContributions()
    }

    private func detectWindowChanges(_ windows: [pid_t: Double], now: Double) {
        var current: [String: Double] = [:]
        var apps: [String: CompositorApp] = [:]
        for (pid, area) in windows {
            guard let app = identity(of: pid) else { continue }
            apps[app.id] = app
            current[app.id, default: 0] += area
        }
        var changes: [(CompositorApp, CompositorAttribution.EventKind)] = []
        for (id, _) in current where windowPresence[id] == nil {
            if let app = apps[id] { changes.append((app, .windowOpened)) }
        }
        for id in windowPresence.keys where current[id] == nil {
            if let app = identities.values.first(where: { $0.id == id }) { changes.append((app, .windowClosed)) }
        }
        windowPresence = current
        // Many apps appearing or disappearing at once is a Space or display switch, not one app.
        guard !suspendEvents, !changes.isEmpty, changes.count < 3 else { return }
        for (app, kind) in changes { attribution.enqueue(app, kind, at: now) }
    }

    // MARK: Identity

    private func identity(of running: NSRunningApplication) -> CompositorApp {
        if let cached = identities[running.processIdentifier] { return cached }
        let executable = running.executableURL?.path ?? ProcessMemoryInspector.executablePath(of: running.processIdentifier) ?? ""
        let app = CompositorApp(
            path: ProcessMemoryInspector.applicationPath(forProcess: running.processIdentifier, executablePath: executable),
            name: running.localizedName ?? URL(fileURLWithPath: executable).lastPathComponent,
            pid: running.processIdentifier
        )
        identities[running.processIdentifier] = app
        return app
    }

    /// Window owners that are regular apps; menu-bar extras and system UI are not candidates.
    private func identity(of pid: pid_t) -> CompositorApp? {
        if let cached = identities[pid] { return cached }
        guard let running = NSRunningApplication(processIdentifier: pid), running.activationPolicy == .regular else { return nil }
        return identity(of: running)
    }

    private static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    private func notify(_ finding: CompositorAttribution.Finding) {
        let center = UNUserNotificationCenter.current()
        let title = String(localized: "\(finding.app.name) is driving up GPU usage")
        let body = String(localized: "WindowServer GPU went from \(AppFormatters.decimalPercent(finding.before)) to \(AppFormatters.decimalPercent(finding.after)) after it \(finding.kind.title). Activity Monitor shows this as WindowServer.")
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: finding.id.uuidString, content: content, trigger: nil))
        }
    }
}

/// WindowServer's GPU user clients, kept between ticks so each tick reads only their counters
/// instead of walking the whole accelerator registry. Re-enumerated every 10 seconds to pick up
/// new contexts.
private final class CompositorClients: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [io_registry_entry_t] = []
    private var pid: pid_t?
    private var enumeratedAt: UInt64 = 0
    private let lifetime: UInt64 = 10_000_000_000

    func read() -> (pid: pid_t, time: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        if entries.isEmpty || now - enumeratedAt > lifetime {
            enumerate()
            enumeratedAt = now
        }
        guard let pid else { return nil }
        var total: UInt64 = 0
        for entry in entries {
            let usage = IORegistryEntryCreateCFProperty(entry, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [[String: Any]]
            for counter in usage ?? [] {
                total &+= (counter["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0
            }
        }
        return (pid, total)
    }

    private func enumerate() {
        entries.forEach { IOObjectRelease($0) }
        entries = []
        pid = nil
        var roots: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &roots) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(roots) }
        var root = IOIteratorNext(roots)
        while root != 0 {
            var children: io_iterator_t = 0
            if IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS {
                var child = IOIteratorNext(children)
                while child != 0 {
                    let creator = IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String
                    // "pid 175, WindowServer"
                    if let creator, creator.hasSuffix(", WindowServer"),
                       let text = creator.split(separator: ",").first?.split(separator: " ").last, let owner = pid_t(text) {
                        pid = owner
                        entries.append(child) // keep the reference; released on the next enumeration
                    } else {
                        IOObjectRelease(child)
                    }
                    child = IOIteratorNext(children)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(root)
            root = IOIteratorNext(roots)
        }
    }

    deinit {
        entries.forEach { IOObjectRelease($0) }
    }
}
