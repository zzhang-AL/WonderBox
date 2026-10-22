import AppKit
import Darwin
import Foundation
import IOKit
import WonderSupport

enum ProcessorKind: String, Identifiable {
    case cpu, gpu
    var id: Self { self }
    var title: String { rawValue.uppercased() }
}

struct ApplicationProcessorUsage: Identifiable, Equatable, Sendable {
    var id: URL { location }
    let location: URL
    let name: String
    let processCount: Int
    /// Activity Monitor convention: one fully occupied CPU core is 100%.
    let cpuPercent: Double
    /// Nil means the driver didn't expose counters; this is distinct from an idle GPU.
    let gpuPercent: Double?
    let isQuittable: Bool
    /// False when none of the app's processes could be read (other users' processes, e.g. WindowServer).
    var cpuAvailable = true
    /// Average power over the last interval from the kernel's energy model; nil when unreadable.
    var powerWatts: Double? = nil
    var gpuMemory = GraphicsMemory()
    /// Some processes hold GPU contexts but their graphics memory needs administrator rights to read.
    var gpuMemoryNeedsAuthorization = false
    /// Part of `gpuMemory` comes from the last administrator snapshot rather than a live reading.
    var gpuMemoryFromSnapshot = false
    /// WindowServer: composites every window, so its GPU time is mostly other apps' doing.
    var isCompositor = false
}

struct ProcessProcessorCounter: Sendable {
    let pid: pid_t
    let startedAt: UInt64
    let path: String
    let cpuNanoseconds: UInt64
    // Track each context independently: closing one must not reset a process's other contexts.
    let gpuContexts: [UInt64: UInt64]
    /// Group key, resolved at sampling time; nil falls back to the executable's bundle.
    var applicationPath: String? = nil
    var energyNanojoules: UInt64 = 0
    /// False for processes `proc_pid_rusage` refuses (other users'), kept only for their GPU counters.
    var usageReadable = true
    var graphicsMemory: GraphicsMemory? = nil
}

struct ProcessorSample: Sendable {
    let sampledAt: TimeInterval
    var processes: [ProcessProcessorCounter]
    let gpuCountersAvailable: Bool
    /// Administrator snapshot of graphics memory for processes the app cannot read itself.
    var privilegedGraphicsMemory: [pid_t: GraphicsMemory] = [:]
}

/// Which processes get their graphics ledgers read this round. Reading needs a task port per
/// process, so only GPU users are read every time and everything else on a slower full sweep.
struct GraphicsMemoryScanPlan: Sendable {
    var fullScan = true
    var known: Set<pid_t> = []
    /// Paths resolved last round, keyed by pid; reused while the process start time matches.
    var resolved: [pid_t: ResolvedProcess] = [:]
}

struct ResolvedProcess: Sendable {
    let startedAt: UInt64
    let path: String
    let applicationPath: String
}

enum ProcessProcessorInspector {
    static func sample(plan: GraphicsMemoryScanPlan = GraphicsMemoryScanPlan()) -> ProcessorSample {
        let gpu = gpuCounters()
        let processes = ProcessMemoryInspector.allProcessIdentifiers().compactMap { pid -> ProcessProcessorCounter? in
            let contexts = gpu.contexts[pid]
            let info = ProcessMemoryInspector.resourceUsage(of: pid)
            // Unreadable processes are only interesting for their GPU use (WindowServer).
            guard info != nil || contexts != nil else { return nil }
            let startedAt = info?.ri_proc_start_abstime ?? 0
            let path: String
            let applicationPath: String
            if let known = plan.resolved[pid], known.startedAt == startedAt, startedAt != 0 {
                (path, applicationPath) = (known.path, known.applicationPath)
            } else {
                guard let executable = ProcessMemoryInspector.executablePath(of: pid) else { return nil }
                path = executable
                applicationPath = ProcessMemoryInspector.applicationPath(forProcess: pid, executablePath: executable)
            }
            var graphics: GraphicsMemory?
            if plan.fullScan || contexts != nil || plan.known.contains(pid) {
                graphics = GraphicsMemoryLedger.read(pid: pid)
            }
            return ProcessProcessorCounter(
                pid: pid, startedAt: startedAt, path: path,
                cpuNanoseconds: info.map { $0.ri_user_time &+ $0.ri_system_time } ?? 0,
                gpuContexts: contexts ?? [:],
                applicationPath: applicationPath,
                energyNanojoules: info?.ri_energy_nj ?? 0,
                usageReadable: info != nil,
                graphicsMemory: graphics
            )
        }
        return ProcessorSample(sampledAt: ProcessInfo.processInfo.systemUptime, processes: processes,
                               gpuCountersAvailable: gpu.available)
    }

    static func usage(current: ProcessorSample, previous: ProcessorSample?) -> [ApplicationProcessorUsage] {
        guard let previous, current.sampledAt > previous.sampledAt else { return [] }
        let elapsedNanoseconds = (current.sampledAt - previous.sampledAt) * 1_000_000_000
        let old = Dictionary(uniqueKeysWithValues: previous.processes.map { ($0.pid, $0) })

        struct Group {
            var cpu: UInt64 = 0, gpu: UInt64 = 0, energy: UInt64 = 0, count = 0
            var readable = 0, energyReadable = 0
            var memory = GraphicsMemory()
            var needsAuthorization = false, fromSnapshot = false, compositor = false
        }
        var groups: [String: Group] = [:]
        for process in current.processes {
            let path = process.applicationPath
                ?? ProcessMemoryInspector.applicationBundlePath(containing: process.path) ?? process.path
            var value = groups[path, default: Group()]
            value.count += 1
            if process.usageReadable { value.readable += 1 }
            if process.path.hasSuffix("/WindowServer") { value.compositor = true }
            // PID reuse and newly observed processes have no comparable baseline.
            if let baseline = old[process.pid], baseline.startedAt == process.startedAt, baseline.path == process.path {
                value.cpu += delta(process.cpuNanoseconds, baseline.cpuNanoseconds)
                if process.usageReadable, baseline.usageReadable {
                    value.energy += delta(process.energyNanojoules, baseline.energyNanojoules)
                    value.energyReadable += 1
                }
                for (context, time) in process.gpuContexts {
                    if let before = baseline.gpuContexts[context] { value.gpu += delta(time, before) }
                }
            }
            if let memory = process.graphicsMemory {
                value.memory = value.memory + memory
            } else if let snapshot = current.privilegedGraphicsMemory[process.pid] {
                value.memory = value.memory + snapshot
                value.fromSnapshot = true
            } else if !process.usageReadable, !process.gpuContexts.isEmpty {
                value.needsAuthorization = true
            }
            groups[path] = value
        }
        return groups.map { path, value in
            let metadata = ApplicationMetadataCache.metadata(for: path)
            return ApplicationProcessorUsage(
                location: metadata.location,
                name: metadata.name,
                processCount: value.count,
                cpuPercent: Double(value.cpu) / elapsedNanoseconds * 100,
                gpuPercent: current.gpuCountersAvailable && previous.gpuCountersAvailable
                    ? Double(value.gpu) / elapsedNanoseconds * 100 : nil,
                isQuittable: metadata.isQuittable,
                cpuAvailable: value.readable > 0,
                // Nanojoules over nanoseconds is watts.
                powerWatts: value.energyReadable > 0 ? Double(value.energy) / elapsedNanoseconds : nil,
                gpuMemory: value.memory,
                gpuMemoryNeedsAuthorization: value.needsAuthorization,
                gpuMemoryFromSnapshot: value.fromSnapshot,
                isCompositor: value.compositor
            )
        }
    }

    private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    /// AGX publishes cumulative nanoseconds per Metal context. This is driver-dependent, not a
    /// promised cross-version API: leave GPU percentages unavailable if AppUsage is absent.
    static func gpuCounters() -> (contexts: [pid_t: [UInt64: UInt64]], available: Bool) {
        var roots: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &roots) == KERN_SUCCESS else {
            return ([:], false)
        }
        defer { IOObjectRelease(roots) }
        var result: [pid_t: [UInt64: UInt64]] = [:]
        var available = false
        var root = IOIteratorNext(roots)
        while root != 0 {
            var children: io_iterator_t = 0
            if IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS {
                var child = IOIteratorNext(children)
                while child != 0 {
                    let creator = IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                    let usage = IORegistryEntryCreateCFProperty(child, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]]
                    if let creator, let pidText = creator.split(separator: ",").first?.split(separator: " ").last,
                       let pid = pid_t(pidText), let usage {
                        var id: UInt64 = 0
                        if IORegistryEntryGetRegistryEntryID(child, &id) == KERN_SUCCESS {
                            // Context IDs are stable within a registry entry; sum its API counters.
                            let times = usage.compactMap { ($0["accumulatedGPUTime"] as? NSNumber)?.uint64Value }
                            if !times.isEmpty {
                                available = true
                                result[pid, default: [:]][id] = times.reduce(0, &+)
                            }
                        }
                    }
                    IOObjectRelease(child)
                    child = IOIteratorNext(children)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(root)
            root = IOIteratorNext(roots)
        }
        return (result, available)
    }
}

@MainActor
final class ProcessorMonitor: ObservableObject {
    @Published private(set) var applications: [ApplicationProcessorUsage] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var gpuCountersAvailable = false
    @Published private(set) var privilegedSnapshotDate: Date?
    @Published private(set) var isReadingPrivilegedMemory = false
    @Published private(set) var privilegedMessage: String?
    private var previous: ProcessorSample?
    private var privilegedGraphicsMemory: [pid_t: GraphicsMemory] = [:]
    private var refreshCount = 0
    /// Every Nth refresh reads every process's graphics ledgers, catching apps that start using the GPU.
    private let fullScanInterval = 5

    var totalGraphicsMemory: UInt64 {
        applications.reduce(0) { $0 &+ $1.gpuMemory.total }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let baseline = previous
        var resolved: [pid_t: ResolvedProcess] = [:]
        for process in baseline?.processes ?? [] {
            if let applicationPath = process.applicationPath {
                resolved[process.pid] = ResolvedProcess(startedAt: process.startedAt, path: process.path, applicationPath: applicationPath)
            }
        }
        let plan = GraphicsMemoryScanPlan(
            fullScan: refreshCount % fullScanInterval == 0,
            known: Set(baseline?.processes.compactMap { ($0.graphicsMemory?.isEmpty == false) ? $0.pid : nil } ?? []),
            resolved: resolved
        )
        refreshCount += 1
        let privileged = privilegedGraphicsMemory
        // Sampling and aggregation both stay off the main thread.
        let (sample, usage) = await Task.detached(priority: .utility) {
            var sample = ProcessProcessorInspector.sample(plan: plan)
            sample.privilegedGraphicsMemory = privileged
            Self.carryForwardGraphicsMemory(into: &sample, from: baseline)
            return (sample, ProcessProcessorInspector.usage(current: sample, previous: baseline))
        }.value
        applications = usage
        previous = sample
        gpuCountersAvailable = sample.gpuCountersAvailable
    }

    /// Processes skipped by this round's scan plan keep their last reading instead of dropping to zero.
    nonisolated static func carryForwardGraphicsMemory(into sample: inout ProcessorSample, from baseline: ProcessorSample?) {
        guard let baseline else { return }
        let old = Dictionary(baseline.processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        for index in sample.processes.indices where sample.processes[index].graphicsMemory == nil {
            let process = sample.processes[index]
            if let before = old[process.pid], before.startedAt == process.startedAt, before.path == process.path {
                sample.processes[index].graphicsMemory = before.graphicsMemory
            }
        }
    }

    func prime() async {
        await refresh()
        if applications.isEmpty {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    /// One-off administrator read of graphics memory for processes the app cannot inspect
    /// (WindowServer and other system services). The figures are a snapshot and do not update.
    func readPrivilegedGraphicsMemory() async {
        guard !isReadingPrivilegedMemory else { return }
        guard let helper = HelperLocator.executable(named: "WonderMaintenanceHelper") else {
            privilegedMessage = String(localized: "The maintenance helper is not installed")
            return
        }
        isReadingPrivilegedMemory = true
        defer { isReadingPrivilegedMemory = false }
        switch AdministratorShell.run("\(AdministratorShell.quote(helper.path)) gpu-memory") {
        case let .success(output):
            privilegedGraphicsMemory = GraphicsMemoryLedger.decode(output)
            privilegedSnapshotDate = Date()
            privilegedMessage = nil
            await refresh()
        case let .failure(failure):
            privilegedMessage = failure.isCancelled ? nil : failure.message
        }
    }

    func quit(_ usage: ApplicationProcessorUsage, force: Bool) async {
        guard usage.isQuittable else { return }
        for app in ProcessMemoryInspector.runningApplications(at: usage.location) {
            _ = force ? app.forceTerminate() : app.terminate()
        }
        try? await Task.sleep(for: .seconds(1))
        await refresh()
    }
}
