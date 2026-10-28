import AppKit
import CoreGraphics

/// Display settings that raise WindowServer's load regardless of which apps run: extra displays,
/// high refresh rates and resolutions rendered well above the panel's own pixels.
enum DisplayContext {
    struct Display: Equatable, Sendable {
        let name: String
        let isBuiltIn: Bool
        let refreshRate: Double
        /// Pixels WindowServer renders each frame.
        let renderedPixels: Int
        /// Pixels of the panel itself; nil when the native mode is not reported.
        let nativePixels: Int?
    }

    /// Rendering this many times the panel's pixels is a "More Space" style setting. The default
    /// on recent MacBooks is already scaled slightly, so smaller ratios are not worth a mention.
    static let scaledRatio = 1.5
    static let highRefreshRate = 100.0

    static func current() -> [Display] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let names = Dictionary(NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { ($0.uint32Value, screen.localizedName) }
        }, uniquingKeysWith: { first, _ in first })
        return ids.prefix(Int(count)).compactMap { id in
            guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
            // IOKit's kDisplayModeNativeFlag.
            let native = modes.first { $0.ioFlags & 0x0200_0000 != 0 }
            return Display(
                name: names[id] ?? String(localized: "Display"),
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                refreshRate: mode.refreshRate,
                renderedPixels: mode.pixelWidth * mode.pixelHeight,
                nativePixels: native.map { $0.pixelWidth * $0.pixelHeight }
            )
        }
    }

    /// What about the current setup adds load; empty when nothing stands out.
    static func notes(for displays: [Display]) -> [String] {
        var notes: [String] = []
        let external = displays.filter { !$0.isBuiltIn }.count
        if external > 0 {
            notes.append(String(localized: "\(external) external displays: every extra screen is composited each frame"))
        }
        for display in displays where display.refreshRate >= highRefreshRate {
            notes.append(String(localized: "\(display.name) refreshes at \(Int(display.refreshRate.rounded())) Hz"))
        }
        for display in displays {
            guard let native = display.nativePixels, native > 0 else { continue }
            let ratio = Double(display.renderedPixels) / Double(native)
            if ratio >= scaledRatio {
                notes.append(String(localized: "\(display.name) uses a scaled resolution that renders \(String(format: "%.1f", ratio))× the panel's pixels"))
            }
        }
        return notes
    }
}
