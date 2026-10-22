import Foundation
import WonderSupport

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

private func cleanSystemCaches() {
    let manager = FileManager.default
    let root = URL(fileURLWithPath: "/Library/Caches", isDirectory: true).standardizedFileURL
    guard let items = try? manager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
    ) else {
        fail("failed to read /Library/Caches", code: 77)
    }

    var removed = 0
    var failed = 0
    for item in items {
        let candidate = item.standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/"), candidate.path != root.path else {
            failed += 1
            continue
        }
        do {
            try manager.removeItem(at: candidate)
            removed += 1
        } catch {
            failed += 1
        }
    }

    if failed > 0 {
        print("Cleaned \(removed) system cache items; \(failed) are protected by the system")
    } else {
        print("Cleaned \(removed) system cache items")
    }
}

/// Read-only: graphics memory of every process, including root ones like WindowServer that the
/// app itself cannot inspect.
private func printGraphicsMemory() {
    print(GraphicsMemoryLedger.encode(GraphicsMemoryLedger.readAll()))
}

switch Array(CommandLine.arguments.dropFirst()) {
case ["clean-system-caches"]: cleanSystemCaches()
case ["gpu-memory"]: printGraphicsMemory()
default: fail("usage: WonderMaintenanceHelper clean-system-caches | gpu-memory", code: 64)
}
