import AppKit
import Darwin
import Foundation

/// Aggregates process physical footprints (Activity Monitor's "Memory" column) per application bundle,
/// so multi-process apps such as browsers and Electron apps report their real total.
enum ProcessMemoryInspector {
    /// `PROC_PIDPATHINFO_MAXSIZE` is a macro and not imported into Swift.
    private static let pathBufferSize = 4 * Int(MAXPATHLEN)

    /// System UI processes that relaunch automatically; quitting them never frees memory for long.
    private static let protectedBundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.WindowManager",
        "com.apple.loginwindow",
        "com.apple.notificationcenterui"
    ]

    static func topConsumers(limit: Int = 12) -> [ApplicationMemoryUsage] {
        var groups: [String: (footprint: UInt64, resident: UInt64, count: Int)] = [:]
        for pid in allProcessIdentifiers() {
            if Task.isCancelled { break }
            guard let usage = resourceUsage(of: pid), usage.ri_phys_footprint > 0,
                  let path = executablePath(of: pid)
            else { continue }
            let key = applicationPath(forProcess: pid, executablePath: path)
            groups[key, default: (0, 0, 0)].footprint += usage.ri_phys_footprint
            groups[key, default: (0, 0, 0)].resident += usage.ri_resident_size
            groups[key, default: (0, 0, 0)].count += 1
        }

        let ownBundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        return groups
            .sorted { $0.value.footprint > $1.value.footprint }
            .prefix(limit)
            .map { key, value in
                let location = URL(fileURLWithPath: key)
                let bundle = location.pathExtension == "app" ? Bundle(url: location) : nil
                let isProtected = bundle?.bundleIdentifier.map(protectedBundleIdentifiers.contains) ?? false
                return ApplicationMemoryUsage(
                    location: location,
                    name: bundle.map { $0.productName ?? location.deletingPathExtension().lastPathComponent }
                        ?? location.lastPathComponent,
                    footprint: value.footprint,
                    resident: value.resident,
                    processCount: value.count,
                    isQuittable: bundle != nil && !isProtected && key != ownBundlePath
                )
            }
    }

    static func footprint(of pid: pid_t) -> UInt64? {
        resourceUsage(of: pid)?.ri_phys_footprint
    }

    /// V6 adds `ri_energy_nj`, the kernel's per-process energy estimate.
    static func resourceUsage(of pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return result == 0 ? info : nil
    }

    /// The application a process should be accounted to. Helpers inside a bundle roll up into the
    /// outermost `.app`; XPC services outside any app (WebKit's GPU and WebContent services) are
    /// charged to the app macOS holds responsible for them. Command-line tools are not: a terminal
    /// is "responsible" for everything started in it, which says nothing about who uses the GPU.
    static func applicationPath(forProcess pid: pid_t, executablePath path: String) -> String {
        if let bundle = applicationBundlePath(containing: path) { return canonicalApplicationPath(bundle) }
        if let host = systemExtensionHost(of: path) { return host }
        if path.contains(".xpc/"), let responsible = responsibleProcess(of: pid), responsible != pid,
           let owner = executablePath(of: responsible),
           let bundle = applicationBundlePath(containing: owner) {
            return canonicalApplicationPath(bundle)
        }
        return path
    }

    /// Chrome relaunches itself from a code-sign clone ("…/code_sign_clone/…/Google Chrome.app.bundle");
    /// map such copies back to the installed app so the main process joins its helpers.
    static func canonicalApplicationPath(_ bundlePath: String) -> String {
        guard bundlePath.hasSuffix(".app.bundle") else { return bundlePath }
        cloneLock.lock()
        defer { cloneLock.unlock() }
        if let cached = cloneTargets[bundlePath] { return cached }
        let installed = Bundle(path: bundlePath)?.bundleIdentifier
            .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }
        cloneTargets[bundlePath] = installed ?? bundlePath
        return installed ?? bundlePath
    }

    /// Network, VPN and endpoint-security extensions run from /Library/SystemExtensions, outside
    /// their app. Charge them to the installed app whose bundle identifier prefixes theirs, e.g.
    /// `com.loon.Loon.LoonTunnelExtension` → `com.loon.Loon`.
    static func systemExtensionHost(of path: String) -> String? {
        guard let range = path.range(of: ".systemextension/") else { return nil }
        let extensionPath = String(path[..<range.lowerBound]) + ".systemextension"
        cloneLock.lock()
        if let cached = extensionHosts[extensionPath] { cloneLock.unlock(); return cached }
        cloneLock.unlock()
        let host = Bundle(path: extensionPath)?.bundleIdentifier.flatMap { identifier in
            hostIdentifiers(forExtension: identifier).lazy
                .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }
                .first
        }
        cloneLock.lock()
        extensionHosts[extensionPath] = .some(host)
        cloneLock.unlock()
        return host
    }

    /// Successively shorter prefixes, never shorter than a two-part vendor prefix.
    static func hostIdentifiers(forExtension identifier: String) -> [String] {
        var parts = identifier.split(separator: ".")
        var candidates: [String] = []
        while parts.count > 2 {
            parts.removeLast()
            candidates.append(parts.joined(separator: "."))
        }
        return candidates
    }

    private nonisolated(unsafe) static var extensionHosts: [String: String?] = [:]
    private nonisolated(unsafe) static var cloneTargets: [String: String] = [:]
    private static let cloneLock = NSLock()

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    /// libquarantine's `responsibility_get_pid_responsible_for_pid`; resolved once, absent on very old systems.
    private static let responsibleFunction: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    static func responsibleProcess(of pid: pid_t) -> pid_t? {
        guard let responsible = responsibleFunction?(pid), responsible > 0 else { return nil }
        return responsible
    }

    /// Outermost `.app` bundle on the path, so nested helper bundles roll up into their host application.
    static func applicationBundlePath(containing executablePath: String) -> String? {
        let components = executablePath.split(separator: "/")
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") || $0.hasSuffix(".app.bundle") }) else {
            return nil
        }
        return "/" + components[...index].joined(separator: "/")
    }

    static func allProcessIdentifiers() -> [pid_t] {
        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytesNeeded > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(bytesNeeded) / MemoryLayout<pid_t>.size + 32)
        let bytesWritten = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard bytesWritten > 0 else { return [] }
        return buffer.prefix(Int(bytesWritten) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Running instances of the app at `location`, including copies launched from a code-sign clone.
    static func runningApplications(at location: URL) -> [NSRunningApplication] {
        let target = location.standardizedFileURL
        let identifier = Bundle(url: target)?.bundleIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL == target || (identifier != nil && $0.bundleIdentifier == identifier)
        }
    }

    static func isQuittable(bundle: Bundle?, path: String) -> Bool {
        guard let bundle, path != Bundle.main.bundleURL.standardizedFileURL.path else { return false }
        return !protectedBundleIdentifiers.contains(bundle.bundleIdentifier ?? "")
    }
}

/// Display name and quit eligibility per application path. Reading a bundle touches the file system,
/// and the same few hundred paths come back on every sample.
enum ApplicationMetadataCache {
    struct Metadata: Sendable {
        let location: URL
        let name: String
        let isQuittable: Bool
    }

    private nonisolated(unsafe) static var entries: [String: Metadata] = [:]
    private static let lock = NSLock()

    static func metadata(for path: String) -> Metadata {
        lock.lock()
        if let cached = entries[path] { lock.unlock(); return cached }
        lock.unlock()
        let location = URL(fileURLWithPath: path)
        let bundle = location.pathExtension == "app" ? Bundle(url: location) : nil
        let metadata = Metadata(
            location: location,
            name: bundle?.productName ?? (bundle == nil ? location.lastPathComponent : location.deletingPathExtension().lastPathComponent),
            isQuittable: ProcessMemoryInspector.isQuittable(bundle: bundle, path: path)
        )
        lock.lock()
        if entries.count > 2_000 { entries.removeAll() }
        entries[path] = metadata
        lock.unlock()
        return metadata
    }
}
