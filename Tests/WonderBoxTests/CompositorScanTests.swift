import XCTest
@testable import WonderBox

final class CompositorScanTests: XCTestCase {
    private func app(_ name: String) -> CompositorApp {
        CompositorApp(path: "/Applications/\(name).app", name: name, pid: 1)
    }

    private func share(_ name: String, _ screens: Double) -> RedrawSampler.Share {
        RedrawSampler.Share(app: app(name), screensPerSecond: screens, framesPerSecond: 30)
    }

    func testSuspectsNeedRealRedrawAndShare() {
        let redraw = RedrawSampler.Result(shares: [
            share("Video", 6), share("Chat", 1.2), share("Editor", 0.5), share("Clock", 0.15), share("Notes", 0.3)
        ])
        // Editor and Notes are under 10% of the 8.15 total; Clock is under the absolute floor.
        XCTAssertEqual(CompositorProbe.suspects(in: redraw).map(\.name), ["Video", "Chat"])
    }

    func testSuspectsAreCapped() {
        let redraw = RedrawSampler.Result(shares: (1...5).map { share("App\($0)", 2) })
        XCTAssertEqual(CompositorProbe.suspects(in: redraw).count, CompositorProbe.verificationLimit)
    }

    func testIdleScreenHasNoSuspects() {
        XCTAssertTrue(CompositorProbe.suspects(in: RedrawSampler.Result(shares: [share("Mail", 0.05)])).isEmpty)
    }

    @MainActor
    func testScanShortensTheEstimate() {
        XCTAssertEqual(CompositorProbe.estimatedSeconds(for: 10, scanning: false), 38)
        XCTAssertEqual(CompositorProbe.estimatedSeconds(for: 10, scanning: true), 16)
    }

    func testDisplayNotesFlagOnlyCostlySettings() {
        let air = DisplayContext.Display(name: "Built-in", isBuiltIn: true, refreshRate: 60,
                                         renderedPixels: 2940 * 1912, nativePixels: 2560 * 1664)
        XCTAssertTrue(DisplayContext.notes(for: [air]).isEmpty, "the default slightly scaled mode is normal")

        let scaled = DisplayContext.Display(name: "Studio", isBuiltIn: false, refreshRate: 120,
                                            renderedPixels: 6016 * 3384, nativePixels: 3840 * 2160)
        let notes = DisplayContext.notes(for: [air, scaled])
        XCTAssertEqual(notes.count, 3)
        XCTAssertTrue(notes[1].contains("120"))
        XCTAssertTrue(notes[2].contains("2.5"))
    }
}
