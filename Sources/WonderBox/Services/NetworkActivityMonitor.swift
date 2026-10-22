import AppKit
import Foundation

struct ApplicationNetworkUsage: Identifiable, Equatable, Sendable {
    var id: URL { location }
    let location: URL
    let name: String
    let processCount: Int
    let downPerSecond: UInt64
    let upPerSecond: UInt64
    /// Bytes since the Network page started measuring.
    let received: UInt64
    let sent: UInt64
    let isQuittable: Bool
}

struct NetworkTraffic: Equatable, Sendable {
    var received: UInt64 = 0
    var sent: UInt64 = 0
}

/// Incremental parser for `nettop -P -d -x -J bytes_in,bytes_out -L 0`, which prints one block per
/// interval: a ",bytes_in,bytes_out," header, then "name.pid,in,out," lines with per-interval deltas.
/// The first block holds totals since each socket opened rather than deltas, so it is dropped.
/// Output comes through a pseudo-terminal, so lines end in "\r\n".
final class NettopStreamParser: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var block: [pid_t: NetworkTraffic] = [:]
    private var headersSeen = 0

    /// Feeds raw output; returns blocks completed by it.
    func feed(_ data: Data) -> [[pid_t: NetworkTraffic]] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var completed: [[pid_t: NetworkTraffic]] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            buffer.removeSubrange(buffer.startIndex...newline)
            if Self.isHeader(line) {
                if headersSeen > 1 { completed.append(block) }
                headersSeen += 1
                block = [:]
            } else if let entry = Self.parse(line) {
                block[entry.pid, default: NetworkTraffic()].received &+= entry.traffic.received
                block[entry.pid, default: NetworkTraffic()].sent &+= entry.traffic.sent
            }
        }
        return completed
    }

    static func isHeader(_ line: String) -> Bool {
        line.hasSuffix(",bytes_in,bytes_out,") || line.hasPrefix(",bytes_in")
    }

    /// "Google Chrome H.77072,1960,1802," → pid 77072. Names are truncated and may contain dots or
    /// commas, so fields are taken from the right.
    static func parse(_ line: String) -> (pid: pid_t, traffic: NetworkTraffic)? {
        var fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if fields.last == "" { fields.removeLast() }
        guard fields.count >= 3,
              let sent = UInt64(fields[fields.count - 1]),
              let received = UInt64(fields[fields.count - 2]) else { return nil }
        let name = fields[..<(fields.count - 2)].joined(separator: ",")
        guard let dot = name.lastIndex(of: "."), let pid = pid_t(name[name.index(after: dot)...]), pid > 0 else { return nil }
        return (pid, NetworkTraffic(received: received, sent: sent))
    }
}

/// Per-application network rates. `nettop` is the only public way to get per-process byte counts;
/// it runs as one streaming child process, and only while someone is looking at the Network page.
@MainActor
final class NetworkActivityMonitor: ObservableObject {
    @Published private(set) var applications: [ApplicationNetworkUsage] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isUnavailable = false

    private var process: Process?
    private var output: FileHandle?
    private var demand = 0
    private let interval = 3
    private var totals: [String: NetworkTraffic] = [:]
    private var pidPaths: [pid_t: String] = [:]

    func acquire() {
        demand += 1
        if demand == 1 { start() }
    }

    func release() {
        demand = max(0, demand - 1)
        if demand == 0 { stop() }
    }

    private func start() {
        let nettop = URL(fileURLWithPath: "/usr/bin/nettop")
        guard FileManager.default.isExecutableFile(atPath: nettop.path) else {
            isUnavailable = true
            return
        }
        // nettop fully buffers its output into a pipe (nothing arrives for minutes); a
        // pseudo-terminal makes it flush every line.
        var primary: Int32 = -1, secondary: Int32 = -1
        guard openpty(&primary, &secondary, nil, nil, nil) == 0 else {
            isUnavailable = true
            return
        }
        let output = FileHandle(fileDescriptor: primary, closeOnDealloc: true)
        let terminal = FileHandle(fileDescriptor: secondary, closeOnDealloc: true)
        let process = Process()
        process.executableURL = nettop
        process.arguments = ["-P", "-d", "-x", "-L", "0", "-s", String(interval), "-J", "bytes_in,bytes_out"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = terminal
        process.standardError = FileHandle.nullDevice
        let parser = NettopStreamParser()
        output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for block in parser.feed(data) {
                Task { @MainActor in self?.apply(block) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.processEnded() }
        }
        do {
            try process.run()
            // The child holds its own copy of the terminal; ours would keep the pty open after it exits.
            try? terminal.close()
            self.process = process
            self.output = output
            isRunning = true
            isUnavailable = false
        } catch {
            output.readabilityHandler = nil
            isUnavailable = true
        }
    }

    private func stop() {
        output?.readabilityHandler = nil
        output = nil
        process?.terminate()
        process = nil
        isRunning = false
        applications = []
        totals = [:]
        pidPaths = [:]
    }

    private func processEnded() {
        guard process?.isRunning == false else { return }
        process = nil
        isRunning = false
    }

    private func apply(_ block: [pid_t: NetworkTraffic]) {
        guard isRunning else { return }
        struct Group { var traffic = NetworkTraffic(); var count = 0 }
        var groups: [String: Group] = [:]
        for (pid, traffic) in block {
            guard let path = path(of: pid) else { continue }
            groups[path, default: Group()].traffic.received &+= traffic.received
            groups[path, default: Group()].traffic.sent &+= traffic.sent
            groups[path, default: Group()].count += 1
        }
        for (path, group) in groups {
            totals[path, default: NetworkTraffic()].received &+= group.traffic.received
            totals[path, default: NetworkTraffic()].sent &+= group.traffic.sent
        }
        pidPaths = pidPaths.filter { block[$0.key] != nil }

        applications = totals.compactMap { path, total -> ApplicationNetworkUsage? in
            guard total.received > 0 || total.sent > 0 else { return nil }
            let current = groups[path]
            let location = URL(fileURLWithPath: path)
            let bundle = location.pathExtension == "app" ? Bundle(url: location) : nil
            return ApplicationNetworkUsage(
                location: location,
                name: bundle?.productName ?? (bundle == nil ? location.lastPathComponent : location.deletingPathExtension().lastPathComponent),
                processCount: current?.count ?? 0,
                downPerSecond: (current?.traffic.received ?? 0) / UInt64(interval),
                upPerSecond: (current?.traffic.sent ?? 0) / UInt64(interval),
                received: total.received,
                sent: total.sent,
                isQuittable: ProcessMemoryInspector.isQuittable(bundle: bundle, path: path)
            )
        }
    }

    private func path(of pid: pid_t) -> String? {
        if let cached = pidPaths[pid] { return cached }
        guard let executable = ProcessMemoryInspector.executablePath(of: pid) else { return nil }
        let path = ProcessMemoryInspector.applicationPath(forProcess: pid, executablePath: executable)
        pidPaths[pid] = path
        return path
    }

    func quit(_ usage: ApplicationNetworkUsage, force: Bool) {
        guard usage.isQuittable else { return }
        for app in ProcessMemoryInspector.runningApplications(at: usage.location) {
            _ = force ? app.forceTerminate() : app.terminate()
        }
    }
}
