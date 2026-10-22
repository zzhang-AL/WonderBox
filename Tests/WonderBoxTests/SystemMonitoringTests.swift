import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import WonderBox
import WonderSupport

final class GraphicsMemoryTests: XCTestCase {
    func testHelperWireFormatRoundTripsAndRejectsGarbage() {
        let entries: [pid_t: GraphicsMemory] = [
            175: GraphicsMemory(resident: 400 << 20, compressed: 2 << 20, purgeable: 70 << 20),
            42: GraphicsMemory(resident: 1, compressed: 0, purgeable: 0)
        ]
        let text = GraphicsMemoryLedger.encode(entries)
        XCTAssertEqual(GraphicsMemoryLedger.decode(text), entries)
        XCTAssertEqual(GraphicsMemoryLedger.decode(text + "\nnot a line\n-3 1 2 3\n9 1 2\n"), entries)
    }

    func testOwnProcessGraphicsMemoryIsReadable() {
        XCTAssertNotNil(GraphicsMemoryLedger.read(pid: getpid()))
    }

    func testTotalsExcludePurgeablePages() {
        let memory = GraphicsMemory(resident: 10, compressed: 5, purgeable: 100)
        XCTAssertEqual(memory.total, 15)
        XCTAssertEqual((memory + memory).purgeable, 200)
        XCTAssertTrue(GraphicsMemory().isEmpty)
    }
}

final class NettopParserTests: XCTestCase {
    func testDropsCumulativeFirstBlockAndEmitsLaterBlocks() {
        let parser = NettopStreamParser()
        XCTAssertTrue(parser.feed(Data(",bytes_in,bytes_out,\nmDNSResponder.233,44942168,30445486,\n".utf8)).isEmpty)
        XCTAssertTrue(parser.feed(Data(",bytes_in,bytes_out,\nGoogle Chrome H.77072,1960,1802,\nGoogle Chrome H.77072,40,0,\n".utf8)).isEmpty)
        let blocks = parser.feed(Data(",bytes_in,bytes_out,\n".utf8))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?[77072], NetworkTraffic(received: 2000, sent: 1802))
        XCTAssertNil(blocks.first?[233], "totals from the first block are not rates")
    }

    func testLinesSplitAcrossReadsAndOddNames() {
        let parser = NettopStreamParser()
        _ = parser.feed(Data(",bytes_in,bytes_out,\n,bytes_in,bytes_out,\nweird.name,with.dots.512,10".utf8))
        let blocks = parser.feed(Data(",20,\n,bytes_in,bytes_out,\n".utf8))
        XCTAssertEqual(blocks.first?[512], NetworkTraffic(received: 10, sent: 20))
        XCTAssertNil(NettopStreamParser.parse("no-pid,1,2,"))
        // Through a pseudo-terminal lines end in CRLF.
        let tty = NettopStreamParser()
        let blocks2 = tty.feed(Data(",bytes_in,bytes_out,\r\n,bytes_in,bytes_out,\r\napsd.146,5,7,\r\n,bytes_in,bytes_out,\r\n".utf8))
        XCTAssertEqual(blocks2.first?[146], NetworkTraffic(received: 5, sent: 7))
        XCTAssertNil(NettopStreamParser.parse("app.12,x,2,"))
    }
}

final class CompositorAttributionTests: XCTestCase {
    private let loon = CompositorApp(path: "/Applications/Loon.app", name: "Loon", pid: 100)
    private let other = CompositorApp(path: "/Applications/Other.app", name: "Other", pid: 200)
    private let own = CompositorApp(path: "/Applications/WonderBox.app", name: "WonderBox", pid: 300)

    /// Feeds 2 Hz readings of `value(t)` from `start` to `end` seconds and collects findings.
    private func run(_ model: inout CompositorAttribution, from start: Double, to end: Double,
                     value: (Double) -> Double) -> [CompositorAttribution.Finding] {
        var findings: [CompositorAttribution.Finding] = []
        var t = start
        while t <= end {
            findings += model.record(value(t), at: t)
            t += 0.5
        }
        return findings
    }

    func testStepAfterActivationIsCreditedAndRefinedAsTheLoadRamps() {
        var model = CompositorAttribution(ignoredPath: own.path)
        _ = run(&model, from: 0, to: 10) { _ in 4 }
        model.enqueue(loon, .activated, previous: own, at: 10)
        // Jumps to 37% right away, then keeps ramping to 49% a few seconds later.
        let findings = run(&model, from: 10.5, to: 22) { $0 < 15 ? 37 : 49 }
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.app, loon)
        XCTAssertEqual(findings.first?.kind, .activated)
        XCTAssertEqual(model.contributions[loon.id]?.value ?? 0, 45, accuracy: 0.5)
        XCTAssertEqual(model.unexplained, 0)
    }

    func testHidingTheCulpritRecordsTheDropAndClearsItsShare() {
        var model = CompositorAttribution(ignoredPath: own.path)
        _ = run(&model, from: 0, to: 10) { _ in 4 }
        model.enqueue(loon, .unhidden, at: 10)
        _ = run(&model, from: 10.5, to: 25) { _ in 48 }
        XCTAssertNotNil(model.contributions[loon.id])

        model.enqueue(loon, .hidden, at: 25)
        let findings = run(&model, from: 25.5, to: 32) { _ in 4 }
        XCTAssertEqual(findings.last?.kind, .hidden)
        XCTAssertEqual(findings.last?.delta ?? 0, -44, accuracy: 0.5)
        XCTAssertNil(model.contributions[loon.id])
    }

    func testOwnAppIsNeverBlamedButTheAppLeftBehindIs() {
        var model = CompositorAttribution(ignoredPath: own.path)
        _ = run(&model, from: 0, to: 10) { _ in 4 }
        model.enqueue(own, .activated, at: 10)
        _ = run(&model, from: 10.5, to: 15) { _ in 40 }
        XCTAssertTrue(model.contributions.isEmpty)

        var second = CompositorAttribution(ignoredPath: own.path)
        _ = run(&second, from: 0, to: 10) { _ in 4 }
        second.enqueue(loon, .activated, at: 10)
        _ = run(&second, from: 10.5, to: 30) { _ in 40 }
        // Switching from Loon to another app calms WindowServer down: Loon was the cause.
        second.enqueue(other, .activated, previous: loon, at: 30)
        let findings = run(&second, from: 30.5, to: 36) { _ in 5 }
        XCTAssertEqual(findings.last?.app, loon)
        XCTAssertEqual(findings.last?.kind, .deactivated)
        XCTAssertNil(second.contributions[loon.id])
    }

    func testSmallJitterIsNotAttributed() {
        var model = CompositorAttribution(ignoredPath: own.path)
        _ = run(&model, from: 0, to: 10) { t in 4 + (Int(t * 2).isMultiple(of: 2) ? 0.8 : -0.8) }
        model.enqueue(loon, .activated, at: 10)
        let findings = run(&model, from: 10.5, to: 16) { _ in 6 }
        XCTAssertTrue(findings.isEmpty)
        XCTAssertTrue(model.contributions.isEmpty)
    }

    func testLoadWithoutAnEventIsReportedAsUnexplained() {
        var model = CompositorAttribution(ignoredPath: own.path)
        _ = run(&model, from: 0, to: 30) { _ in 4 }
        _ = run(&model, from: 30.5, to: 40) { _ in 40 }
        XCTAssertEqual(model.unexplained, 36, accuracy: 1)
    }

    func testContributionsShrinkWhenTheLoadGoesAwayOnItsOwn() {
        var model = CompositorAttribution(ignoredPath: own.path)
        _ = run(&model, from: 0, to: 10) { _ in 4 }
        model.enqueue(loon, .activated, at: 10)
        _ = run(&model, from: 10.5, to: 25) { _ in 44 }
        // The app stops animating by itself; no event explains the drop.
        _ = run(&model, from: 25.5, to: 40) { _ in 4 }
        XCTAssertNil(model.contributions[loon.id])
    }

    func testProbeResultReplacesTheShare() {
        var model = CompositorAttribution(ignoredPath: own.path)
        model.recordProbe(app: loon, drop: 30, noise: 3, baseline: 34, at: 0)
        XCTAssertEqual(model.contributions[loon.id]?.source, .probe)
        model.recordProbe(app: loon, drop: 1, noise: 3, baseline: 34, at: 1)
        XCTAssertNil(model.contributions[loon.id])
        XCTAssertGreaterThan(model.suspicion(of: loon.id, now: 2), -1)
    }
}

final class SystemSamplingTests: XCTestCase {
    func testPerCoreSplitHandlesWrappedCounters() {
        // user, system, idle, nice
        let before: [[UInt32]] = [[UInt32.max - 9, 0, 100, 0], [0, 0, 0, 0]]
        let after: [[UInt32]] = [[10, 20, 120, 0], [0, 50, 50, 0]]
        let split = SystemMonitor.cpuSplit(current: after, previous: before)
        XCTAssertEqual(split.cores[0], 40.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(split.cores[1], 0.5, accuracy: 1e-9)
        XCTAssertEqual(split.user, 20.0 / 160.0, accuracy: 1e-9)
        XCTAssertEqual(split.system, 70.0 / 160.0, accuracy: 1e-9)
        XCTAssertTrue(SystemMonitor.cpuSplit(current: after, previous: []).cores.isEmpty)
    }

    func testLiveSampleIncludesCoresInterfacesAndMemory() {
        let first = SystemMonitor.sample(previous: nil)
        let second = SystemMonitor.sample(previous: first.counters)
        XCTAssertEqual(second.snapshot.cpuCores.count, ProcessInfo.processInfo.activeProcessorCount)
        XCTAssertTrue(second.snapshot.cpuCores.allSatisfy { (0...1).contains($0) })
        XCTAssertGreaterThan(second.snapshot.memory.total, 0)
        XCTAssertTrue(second.snapshot.networkInterfaces.allSatisfy { NetworkInterfaceUsage.isRelevant($0.name) })
    }

    func testTunnelsAreListedButNotCountedAsPhysicalTraffic() {
        XCTAssertTrue(NetworkInterfaceUsage.isPhysical("en0"))
        XCTAssertFalse(NetworkInterfaceUsage.isPhysical("utun4"))
        XCTAssertTrue(NetworkInterfaceUsage.isRelevant("utun4"))
        XCTAssertFalse(NetworkInterfaceUsage.isRelevant("lo0"))
        XCTAssertFalse(NetworkInterfaceUsage.isRelevant("awdl0"))
    }

    func testBatteryHealthAndFormatting() {
        var battery = BatteryDetails(level: 0.8, isCharging: false, isPluggedIn: true, isFullyCharged: false)
        XCTAssertNil(battery.health)
        battery.designCapacity = 4_629
        battery.fullChargeCapacity = 4_471
        XCTAssertEqual(battery.health ?? 0, 0.966, accuracy: 0.001)
        XCTAssertEqual(AppFormatters.decimalPercent(4.94), "4.9%")
        XCTAssertEqual(AppFormatters.decimalPercent(48.4), "48%")
        XCTAssertEqual(AppFormatters.decimalPercent(0.01), "0%")
        XCTAssertEqual(AppFormatters.watts(9.899), "9.9 W")
    }
}

final class ProcessUsageAggregationTests: XCTestCase {
    private func process(pid: pid_t, path: String, app: String? = nil, cpu: UInt64 = 0, energy: UInt64 = 0,
                         readable: Bool = true, gpu: [UInt64: UInt64] = [:], memory: GraphicsMemory? = nil) -> ProcessProcessorCounter {
        ProcessProcessorCounter(pid: pid, startedAt: 1, path: path, cpuNanoseconds: cpu, gpuContexts: gpu,
                                applicationPath: app, energyNanojoules: energy, usageReadable: readable, graphicsMemory: memory)
    }

    func testPowerVideoMemoryAndResponsibleGroupingAreAggregated() throws {
        let app = "/Applications/Demo.app"
        let webkit = "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
        let before = ProcessorSample(sampledAt: 1, processes: [
            process(pid: 1, path: app + "/Contents/MacOS/Demo", cpu: 0, energy: 0, gpu: [7: 0]),
            process(pid: 2, path: webkit, app: app, cpu: 0, energy: 0)
        ], gpuCountersAvailable: true)
        let after = ProcessorSample(sampledAt: 2, processes: [
            process(pid: 1, path: app + "/Contents/MacOS/Demo", cpu: 500_000_000, energy: 2_000_000_000, gpu: [7: 250_000_000],
                    memory: GraphicsMemory(resident: 100, compressed: 20, purgeable: 5)),
            process(pid: 2, path: webkit, app: app, cpu: 0, energy: 1_000_000_000, memory: GraphicsMemory(resident: 30))
        ], gpuCountersAvailable: true)
        let usage = try XCTUnwrap(ProcessProcessorInspector.usage(current: after, previous: before).first)
        XCTAssertEqual(usage.location.path, app)
        XCTAssertEqual(usage.processCount, 2)
        XCTAssertEqual(usage.cpuPercent, 50, accuracy: 1e-6)
        XCTAssertEqual(usage.gpuPercent ?? 0, 25, accuracy: 1e-6)
        XCTAssertEqual(usage.powerWatts ?? 0, 3, accuracy: 1e-6)
        XCTAssertEqual(usage.gpuMemory, GraphicsMemory(resident: 130, compressed: 20, purgeable: 5))
    }

    func testUnreadableCompositorNeedsAuthorizationUntilASnapshotExists() throws {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
        let before = ProcessorSample(sampledAt: 1, processes: [process(pid: 175, path: path, readable: false, gpu: [1: 0])],
                                     gpuCountersAvailable: true)
        var after = ProcessorSample(sampledAt: 2, processes: [process(pid: 175, path: path, readable: false, gpu: [1: 400_000_000])],
                                    gpuCountersAvailable: true)
        var usage = try XCTUnwrap(ProcessProcessorInspector.usage(current: after, previous: before).first)
        XCTAssertTrue(usage.isCompositor)
        XCTAssertFalse(usage.cpuAvailable)
        XCTAssertNil(usage.powerWatts)
        XCTAssertEqual(usage.gpuPercent ?? 0, 40, accuracy: 1e-6)
        XCTAssertTrue(usage.gpuMemoryNeedsAuthorization)

        after.privilegedGraphicsMemory = [175: GraphicsMemory(resident: 400 << 20)]
        usage = try XCTUnwrap(ProcessProcessorInspector.usage(current: after, previous: before).first)
        XCTAssertFalse(usage.gpuMemoryNeedsAuthorization)
        XCTAssertTrue(usage.gpuMemoryFromSnapshot)
        XCTAssertEqual(usage.gpuMemory.total, 400 << 20)
    }

    @MainActor
    func testSkippedProcessesKeepTheirLastVideoMemoryReading() {
        let path = "/Applications/Demo.app/Contents/MacOS/Demo"
        let baseline = ProcessorSample(sampledAt: 1, processes: [process(pid: 1, path: path, memory: GraphicsMemory(resident: 64))],
                                       gpuCountersAvailable: true)
        var sample = ProcessorSample(sampledAt: 2, processes: [process(pid: 1, path: path), process(pid: 2, path: path)],
                                     gpuCountersAvailable: true)
        ProcessorMonitor.carryForwardGraphicsMemory(into: &sample, from: baseline)
        XCTAssertEqual(sample.processes[0].graphicsMemory, GraphicsMemory(resident: 64))
        XCTAssertNil(sample.processes[1].graphicsMemory)
    }

    func testHelpersInsideABundleRollUpToTheOutermostApp() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)"
        XCTAssertEqual(ProcessMemoryInspector.applicationPath(forProcess: getpid(), executablePath: helper), "/Applications/Google Chrome.app")
        XCTAssertEqual(ProcessMemoryInspector.applicationPath(forProcess: -1, executablePath: "/usr/sbin/mDNSResponder"), "/usr/sbin/mDNSResponder")
        XCTAssertEqual(ProcessMemoryInspector.hostIdentifiers(forExtension: "com.loon.Loon.LoonTunnelExtension"), ["com.loon.Loon", "com.loon"])
        XCTAssertEqual(ProcessMemoryInspector.hostIdentifiers(forExtension: "io.tailscale.ipn.macsys.network-extension"),
                       ["io.tailscale.ipn.macsys", "io.tailscale.ipn", "io.tailscale"])
        XCTAssertNil(ProcessMemoryInspector.systemExtensionHost(of: "/usr/libexec/nesessionmanager"))
    }
}

/// Opt-in: renders the monitoring pages at full length with live data, for reviewing layout.
/// `WONDERBOX_RENDER_PREVIEWS=1 WONDERBOX_PREVIEW_DIR=… swift test --filter MonitoringPagePreviews`
@MainActor
final class MonitoringPagePreviews: XCTestCase {
    func testRenderMonitoringPages() async throws {
        guard ProcessInfo.processInfo.environment["WONDERBOX_RENDER_PREVIEWS"] == "1" else { throw XCTSkip("Opt-in UI preview") }
        let directory = ProcessInfo.processInfo.environment["WONDERBOX_PREVIEW_DIR"] ?? "/tmp"
        let model = AppModel()
        model.compositor.start()
        model.networkActivity.acquire()
        for _ in 0..<4 {
            await model.refreshMetrics()
            await model.processorMonitor.refresh()
            try await Task.sleep(for: .seconds(2.5))
        }
        let pages: [(String, AnyView, CGFloat)] = [
            ("gpu", AnyView(GPUView()), 2_300),
            ("cpu", AnyView(ProcessorView(kind: .cpu)), 1_900),
            ("network", AnyView(NetworkView()), 1_900),
            ("battery", AnyView(BatteryView()), 1_600),
            ("overview", AnyView(OverviewView()), 1_100)
        ]
        for (name, page, height) in pages {
            let host = NSHostingView(rootView: page.environmentObject(model).environmentObject(model.metrics)
                .frame(width: 960, height: height).background(Color.appBackground))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: height), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.frame = window.contentView!.bounds
            try await Task.sleep(for: .milliseconds(600))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("wonderbox-\(name)-preview.png"))
            window.contentView = nil
        }
        model.networkActivity.release()
        model.compositor.stop()
    }
}
