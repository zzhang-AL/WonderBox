import Foundation

/// Live system metrics, kept apart from `AppModel` on purpose: they change every few seconds, and an
/// `ObservableObject` change re-renders every view observing it. Holding them in `AppModel` made the
/// whole scene graph — window, sidebar and menu bar — recompute on each sample. Only views that
/// actually display metrics observe this store.
@MainActor
final class MetricsStore: ObservableObject {
    static let historyLength = 60

    @Published private(set) var snapshot = MetricSnapshot()
    @Published private(set) var processorHistory = ProcessorHistory()
    @Published private(set) var isRefreshing = false
    @Published private(set) var cpuHistory: [Double] = Array(repeating: 0, count: 30)
    @Published private(set) var gpuHistory: [Double] = Array(repeating: 0, count: 30)
    @Published private(set) var memoryHistory: [Double] = Array(repeating: 0, count: 30)
    @Published private(set) var downloadHistory: [Double] = []
    @Published private(set) var uploadHistory: [Double] = []
    /// Whole-system power in watts, where the battery controller reports it.
    @Published private(set) var powerHistory: [Double] = []

    private var previousCounters: SystemCounters?
    private var refreshTask: Task<Void, Never>?

    /// `refreshDisk` re-reads free space instead of reusing a recent reading (after cleanups).
    func refresh(refreshDisk: Bool = false) async {
        if let refreshTask { await refreshTask.value; return }
        isRefreshing = true
        let task = Task { await sample(refreshDisk: refreshDisk) }
        refreshTask = task
        defer { refreshTask = nil; isRefreshing = false }
        await task.value
    }

    private func sample(refreshDisk: Bool) async {
        let previous = previousCounters
        let sample = await Task.detached(priority: .utility) {
            SystemMonitor.sample(previous: previous, refreshDisk: refreshDisk)
        }.value
        let hadBaseline = previous != nil
        previousCounters = sample.counters
        snapshot = sample.snapshot
        processorHistory.append(sample.snapshot)
        Self.append(sample.snapshot.cpuUsage, to: &cpuHistory)
        Self.append(sample.snapshot.gpuUsage ?? 0, to: &gpuHistory)
        Self.append(sample.snapshot.memoryFraction, to: &memoryHistory)
        // The first sample has no baseline, so its rates are zero rather than measured.
        if hadBaseline {
            Self.append(Double(sample.snapshot.networkDownPerSecond), to: &downloadHistory)
            Self.append(Double(sample.snapshot.networkUpPerSecond), to: &uploadHistory)
        }
        if let power = sample.snapshot.battery?.systemPower {
            Self.append(power, to: &powerHistory)
        }
    }

    private static func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }
}
