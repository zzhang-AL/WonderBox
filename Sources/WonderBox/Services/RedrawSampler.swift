import AppKit
import CoreMedia
import ScreenCaptureKit

/// Measures how much each app redraws without hiding anything. ScreenCaptureKit tags every captured
/// frame with the rectangles that changed since the previous one; capturing each app's own windows
/// in a small stream gives its redrawn area per second. That tracks the compositing work the app
/// causes, though not effects such as blur that cost more per pixel, so the quick check still
/// confirms the top suspects by hiding them.
enum RedrawSampler {
    struct Share: Identifiable, Equatable, Sendable {
        let app: CompositorApp
        /// Redrawn area, in full screens per second (one screen = all displays' combined area).
        let screensPerSecond: Double
        /// Captured frames that changed, per second (capped by the 60 Hz capture rate).
        let framesPerSecond: Double
        var id: String { app.id }
    }

    struct Result: Equatable, Sendable {
        /// Largest redraw first.
        let shares: [Share]
        var total: Double { shares.reduce(0) { $0 + $1.screensPerSecond } }
    }

    enum Failure: Error {
        case permissionDenied
        case nothingToCapture
    }

    /// Output scale: dirty rectangles keep their shape at a quarter of the resolution, and the
    /// stream costs WindowServer a sixteenth of the pixels.
    private static let downscale = 4
    /// Apps beyond this many are not captured; each costs one stream.
    static let maximumApps = 10

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards macOS only points to System Settings.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func sample(_ apps: [CompositorApp], seconds: Double) async throws -> Result {
        guard hasPermission else { throw Failure.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let screenArea = content.displays.reduce(0.0) { $0 + Double($1.width * $1.height) }
        guard screenArea > 0 else { throw Failure.nothingToCapture }

        var captures: [(app: CompositorApp, stream: SCStream, collector: RedrawCollector)] = []
        for app in apps.prefix(maximumApps) {
            let windows = content.windows.filter {
                $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width * $0.frame.height > 0
                    && $0.owningApplication.map { owner in matches(owner.processID, app) } == true
            }
            // A stream captures one display; an app's windows go to the display under their centre.
            for display in content.displays {
                let onDisplay = windows.filter { display.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
                guard !onDisplay.isEmpty else { continue }
                let configuration = SCStreamConfiguration()
                configuration.width = max(64, display.width / downscale)
                configuration.height = max(64, display.height / downscale)
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                configuration.queueDepth = 3
                configuration.showsCursor = false
                let collector = RedrawCollector(pointsPerPixel: Double(display.width) / Double(configuration.width))
                let stream = SCStream(filter: SCContentFilter(display: display, including: onDisplay),
                                      configuration: configuration, delegate: nil)
                try stream.addStreamOutput(collector, type: .screen, sampleHandlerQueue: collector.queue)
                captures.append((app, stream, collector))
            }
        }
        guard !captures.isEmpty else { throw Failure.nothingToCapture }

        // Start all streams first so every app is measured over the same window of time.
        var started: [SCStream] = []
        do {
            for capture in captures {
                try await capture.stream.startCapture()
                started.append(capture.stream)
            }
        } catch {
            for stream in started { try? await stream.stopCapture() }
            throw error
        }
        let begin = DispatchTime.now().uptimeNanoseconds
        try? await Task.sleep(for: .seconds(seconds))
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000_000
        for stream in started { try? await stream.stopCapture() }

        var totals: [String: (app: CompositorApp, area: Double, frames: Int)] = [:]
        for capture in captures {
            let reading = capture.collector.reading
            totals[capture.app.id, default: (capture.app, 0, 0)].area += reading.area
            totals[capture.app.id, default: (capture.app, 0, 0)].frames += reading.frames
        }
        return Result(shares: totals.values.map {
            Share(app: $0.app, screensPerSecond: $0.area / screenArea / elapsed, framesPerSecond: Double($0.frames) / elapsed)
        }.sorted { $0.screensPerSecond > $1.screensPerSecond })
    }

    /// Windows belong to the app's main process, or to another process inside the same bundle.
    private static func matches(_ pid: pid_t, _ app: CompositorApp) -> Bool {
        if pid == app.pid { return true }
        guard let path = NSRunningApplication(processIdentifier: pid)?.bundleURL?.standardizedFileURL.path else { return false }
        return path == app.path
    }

    /// Total redrawn area in the frame, in output pixels, or nil for frames that did not change.
    static func redrawnPixels(in sampleBuffer: CMSampleBuffer) -> Double? {
        guard let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
              let status = (attachments[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)),
              status == .complete,
              let rects = attachments[.dirtyRects] as? [Any]
        else { return nil }
        let area = rects.reduce(0.0) { sum, value in
            let rect: CGRect?
            if let value = value as? NSValue {
                rect = value.rectValue
            } else if let dictionary = value as? NSDictionary {
                rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
            } else {
                rect = nil
            }
            return sum + (rect.map { Double($0.width * $0.height) } ?? 0)
        }
        return area > 0 ? area : nil
    }
}

/// Accumulates one stream's redrawn area. Called on its own serial queue.
private final class RedrawCollector: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.wondercraft.WonderBox.redraw", qos: .utility)
    private let pointsPerPixel: Double
    private var sawFirstFrame = false
    private var area = 0.0
    private var frames = 0

    init(pointsPerPixel: Double) {
        self.pointsPerPixel = pointsPerPixel
    }

    /// Area in points. Read after the stream stops; the queue serializes it with the callbacks.
    var reading: (area: Double, frames: Int) {
        queue.sync { (area, frames) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixels = RedrawSampler.redrawnPixels(in: sampleBuffer) else { return }
        // The first frame reports everything as changed.
        guard sawFirstFrame else { sawFirstFrame = true; return }
        area += pixels * pointsPerPixel * pointsPerPixel
        frames += 1
    }
}
