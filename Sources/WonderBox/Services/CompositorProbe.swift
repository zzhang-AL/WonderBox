import AppKit
import CoreGraphics

/// Finds the app behind WindowServer's GPU load by measurement rather than inference. With Screen
/// Recording allowed, it first measures how much every app redraws without touching any window,
/// then confirms only the top suspects by hiding each one and measuring how far WindowServer drops.
/// Without it, it hides apps one at a time, most suspicious first. Every app is unhidden right after
/// its measurement, and the run stops as soon as one app explains most of the excess load. When no
/// app does, the display setup is the next place to look.
@MainActor
final class CompositorProbe: ObservableObject {
    struct Result: Identifiable, Sendable {
        let app: CompositorApp
        /// WindowServer GPU, in percentage points, saved while the app was hidden.
        let compositorDrop: Double
        /// Whole-GPU percentage points saved, including the app's own rendering.
        let totalDrop: Double
        var id: String { app.id }
    }

    enum Phase: Equatable {
        case idle
        case running(step: String, progress: Double)
        case finished(Date)
        case cancelled
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var results: [Result] = []
    @Published private(set) var baseline: Double = 0
    @Published private(set) var totalBaseline: Double = 0
    /// Drift between measurements; drops below this are noise. GPU busy time moves with clock
    /// scaling, so a few points of jitter are normal.
    @Published private(set) var noise: Double = 3
    @Published private(set) var stoppedEarly = false
    /// Redraw per app from the passive scan; nil when it did not run.
    @Published private(set) var redraw: RedrawSampler.Result?
    /// WindowServer percentage points the scan's own capture added.
    @Published private(set) var scanOverhead: Double?
    @Published private(set) var scanMessage: String?
    /// WindowServer above its idle floor when the check started.
    @Published private(set) var excess: Double = 0
    @Published private(set) var displayNotes: [String] = []

    private var task: Task<Void, Never>?
    private let settleSeconds = 1.0
    private let measureSeconds = 2.0
    /// One app explaining this share of the excess load ends the search.
    private let enoughShare = 0.7
    private let scanSeconds = 3.0
    /// Suspects confirmed by hiding after a scan.
    nonisolated static let verificationLimit = 3
    /// Redraw below this many screens per second cannot move WindowServer noticeably.
    nonisolated static let minimumRedraw = 0.2

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Whether a run would start with the passive scan.
    static func scans(_ count: Int) -> Bool {
        count > 1 && RedrawSampler.hasPermission
    }

    static func estimatedSeconds(for count: Int, scanning: Bool) -> Int {
        let hidden = scanning ? min(count, verificationLimit) : count
        return Int((Double(hidden) * 3.5 + 2.5 + (scanning ? 3 : 0)).rounded())
    }

    /// Apps worth confirming by hiding, largest redraw first: enough redraw to move WindowServer,
    /// and a real share of all redraw rather than a blinking cursor next to a playing video.
    nonisolated static func suspects(in redraw: RedrawSampler.Result, limit: Int = verificationLimit) -> [CompositorApp] {
        let total = redraw.total
        return redraw.shares
            .filter { $0.screensPerSecond >= minimumRedraw && $0.screensPerSecond >= total * 0.1 }
            .prefix(limit)
            .map(\.app)
    }

    /// The confirmed drops account for at least half of the load above the floor.
    var isExplained: Bool {
        excess < 5 || results.filter { $0.compositorDrop >= noise }.reduce(0) { $0 + $1.compositorDrop } >= excess * 0.5
    }

    /// Regular apps with on-screen windows, most suspicious first.
    static func candidates(rankedBy monitor: CompositorMonitor) -> [CompositorApp] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var area: [pid_t: Double] = [:]
        for window in list where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double] else { continue }
            area[pid, default: 0] += (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
        }
        let own = Bundle.main.bundleURL.standardizedFileURL.path
        var seen = Set<String>()
        let apps: [(CompositorApp, Double)] = area.compactMap { pid, area in
            guard let running = NSRunningApplication(processIdentifier: pid), running.activationPolicy == .regular,
                  let executable = running.executableURL?.path else { return nil }
            let app = CompositorApp(path: ProcessMemoryInspector.applicationPath(forProcess: pid, executablePath: executable),
                                    name: running.localizedName ?? running.executableURL?.lastPathComponent ?? "",
                                    pid: pid)
            guard app.path != own, seen.insert(app.id).inserted else { return nil }
            return (app, area)
        }
        return apps.sorted {
            let left = monitor.suspicion(of: $0.0.id), right = monitor.suspicion(of: $1.0.id)
            return left == right ? $0.1 > $1.1 : left > right
        }
        .prefix(12)
        .map(\.0)
    }

    func start(_ candidates: [CompositorApp], monitor: CompositorMonitor) {
        guard !isRunning, !candidates.isEmpty, let compositorPID = monitor.compositorPID else { return }
        results = []
        stoppedEarly = false
        redraw = nil
        scanOverhead = nil
        scanMessage = nil
        displayNotes = []
        task = Task { await run(candidates, compositorPID: compositorPID, monitor: monitor) }
    }

    func cancel() {
        task?.cancel()
    }

    private func run(_ candidates: [CompositorApp], compositorPID: pid_t, monitor: CompositorMonitor) async {
        let frontmost = NSWorkspace.shared.frontmostApplication
        // Our own hides would otherwise be read as natural experiments.
        monitor.suspendEvents = true
        defer { monitor.suspendEvents = false }

        let scanning = Self.scans(candidates.count)
        // Baseline, the scan, each hide and the closing baseline.
        var steps = Double(candidates.count + 1)
        if scanning { steps = Double(min(candidates.count, Self.verificationLimit) + 2) }
        phase = .running(step: String(localized: "Measuring the baseline"), progress: 0)
        let before = await Self.measure(compositorPID: compositorPID, seconds: measureSeconds)
        let excess = max(before.compositor - monitor.floor, 0)
        self.excess = excess

        var order = candidates
        var doneSteps = 1.0
        if scanning, !Task.isCancelled {
            phase = .running(step: String(localized: "Measuring how much each app redraws"), progress: doneSteps / steps)
            async let load = Self.measure(compositorPID: compositorPID, seconds: scanSeconds)
            do {
                let result = try await RedrawSampler.sample(candidates, seconds: scanSeconds)
                redraw = result
                order = Self.suspects(in: result)
                scanOverhead = await load.compositor - before.compositor
            } catch {
                scanMessage = String(localized: "The redraw scan failed (\(error.localizedDescription)); checking apps one at a time instead.")
                _ = await load
                steps = Double(candidates.count + 2)
            }
            doneSteps += 1
        }

        var measured: [(CompositorApp, (compositor: Double, total: Double))] = []
        for app in order {
            if Task.isCancelled { break }
            guard let running = NSRunningApplication(processIdentifier: app.pid), !running.isHidden, !running.isTerminated else { continue }
            phase = .running(step: String(localized: "Hiding \(app.name)"), progress: doneSteps / steps)
            doneSteps += 1

            // hide() often reports false for inactive apps yet still hides them.
            running.hide()
            try? await Task.sleep(for: .seconds(settleSeconds))
            let result = await Self.measure(compositorPID: compositorPID, seconds: measureSeconds)
            // Always restore, even when cancelled mid-measurement.
            running.unhide()
            if Task.isCancelled { break }
            measured.append((app, result))

            if excess >= 5, before.compositor - result.compositor >= excess * enoughShare {
                stoppedEarly = true
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        guard !Task.isCancelled else {
            frontmost?.activate()
            phase = .cancelled
            return
        }

        var base = before
        noise = CompositorAttribution.minimumStep
        if !stoppedEarly && !measured.isEmpty {
            phase = .running(step: String(localized: "Measuring the baseline again"), progress: (steps - 0.5) / steps)
            let after = await Self.measure(compositorPID: compositorPID, seconds: measureSeconds)
            base = ((before.compositor + after.compositor) / 2, (before.total + after.total) / 2)
            noise = max(CompositorAttribution.minimumStep, abs(before.compositor - after.compositor))
        }
        baseline = base.compositor
        totalBaseline = base.total
        results = measured
            .map { Result(app: $0.0, compositorDrop: base.compositor - $0.1.compositor, totalDrop: base.total - $0.1.total) }
            .sorted { $0.compositorDrop > $1.compositorDrop }
        monitor.recordProbe(results, noise: noise, baseline: base.compositor)
        displayNotes = DisplayContext.notes(for: DisplayContext.current())
        frontmost?.activate()
        phase = .finished(Date())
    }

    /// Average GPU percent of WindowServer and of all processes over a window of time.
    private nonisolated static func measure(compositorPID: pid_t, seconds: Double) async -> (compositor: Double, total: Double) {
        let start = ProcessProcessorInspector.gpuCounters().contexts.mapValues { $0.values.reduce(0, &+) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        try? await Task.sleep(for: .seconds(seconds))
        let end = ProcessProcessorInspector.gpuCounters().contexts.mapValues { $0.values.reduce(0, &+) }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0)
        guard elapsed > 0 else { return (0, 0) }
        func delta(_ pid: pid_t) -> Double {
            guard let a = start[pid], let b = end[pid], b >= a else { return 0 }
            return Double(b - a)
        }
        let total = end.keys.reduce(0.0) { $0 + delta($1) }
        return (delta(compositorPID) / elapsed * 100, total / elapsed * 100)
    }
}
