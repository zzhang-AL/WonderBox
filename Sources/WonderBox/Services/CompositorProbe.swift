import AppKit
import CoreGraphics

/// Finds the app behind WindowServer's GPU load by measurement rather than inference: hides apps
/// with visible windows one at a time, most suspicious first, and measures how far WindowServer
/// drops while each is hidden. Every app is unhidden right after its measurement, and the run stops
/// as soon as one app explains most of the excess load.
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

    private var task: Task<Void, Never>?
    private let settleSeconds = 1.0
    private let measureSeconds = 2.0
    /// One app explaining this share of the excess load ends the search.
    private let enoughShare = 0.7

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    static func estimatedSeconds(for count: Int) -> Int {
        Int((Double(count) * 3.5 + 2.5).rounded())
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

        let steps = Double(candidates.count + 1)
        phase = .running(step: String(localized: "Measuring the baseline"), progress: 0)
        let before = await Self.measure(compositorPID: compositorPID, seconds: measureSeconds)
        let excess = max(before.compositor - monitor.floor, 0)

        var measured: [(CompositorApp, (compositor: Double, total: Double))] = []
        for (index, app) in candidates.enumerated() {
            if Task.isCancelled { break }
            guard let running = NSRunningApplication(processIdentifier: app.pid), !running.isHidden, !running.isTerminated else { continue }
            phase = .running(step: String(localized: "Hiding \(app.name)"), progress: Double(index + 1) / steps)

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
        if !stoppedEarly {
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
