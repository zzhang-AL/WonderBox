import Foundation
import XCTest
@testable import WonderBox

final class SystemHealthTests: XCTestCase {
    private func snapshot(diskFree: Double = 0.5) -> MetricSnapshot {
        var snapshot = MetricSnapshot()
        snapshot.memory = MemoryBreakdown(total: 100, app: 40, pressure: .normal)
        snapshot.diskTotal = 1_000
        snapshot.diskUsed = UInt64(1_000 * (1 - diskFree))
        snapshot.thermalState = .nominal
        return snapshot
    }

    func testIdleMacScoresFullMarks() {
        let health = SystemHealth(snapshot: snapshot(), recentCPU: 0.2)
        XCTAssertEqual(health.score, 100)
        XCTAssertEqual(health.grade, .excellent)
        XCTAssertTrue(health.issues.isEmpty)
    }

    func testIssuesAreOrderedByPenalty() {
        var value = snapshot(diskFree: 0.05)
        value.thermalState = .serious
        value.memory.pressure = .warning
        let health = SystemHealth(snapshot: value, recentCPU: 1)
        // Thermal 25, processor 20, memory pressure 15, disk 10.
        XCTAssertEqual(health.issues, [.thermal(.serious), .processorBusy, .memoryPressure(.warning), .diskFull])
        XCTAssertEqual(health.score, 30)
        XCTAssertEqual(health.grade, .poor)
    }

    func testScoreNeverDropsBelowZero() {
        var value = snapshot(diskFree: 0)
        value.thermalState = .critical
        value.memory = MemoryBreakdown(total: 100, app: 100, swapUsed: 16 << 30, pressure: .critical)
        XCTAssertEqual(SystemHealth(snapshot: value, recentCPU: 1).score, 0)
    }

    func testLowBatteryCountsOnlyWhenUnplugged() {
        var value = snapshot()
        value.battery = BatteryDetails(level: 0.1, isCharging: false, isPluggedIn: true, isFullyCharged: false)
        XCTAssertTrue(SystemHealth(snapshot: value, recentCPU: 0).issues.isEmpty)
        value.battery?.isPluggedIn = false
        XCTAssertEqual(SystemHealth(snapshot: value, recentCPU: 0).issues, [.batteryLow])
    }

    func testLoadLevelBuckets() {
        XCTAssertEqual(LoadLevel(0.1), .low)
        XCTAssertEqual(LoadLevel(0.3), .medium)
        XCTAssertEqual(LoadLevel(0.95), .high)
    }
}

final class MenuFormattingTests: XCTestCase {
    func testSplitsNumberFromUnit() {
        XCTAssertTrue(MenuFormatting.split("16%") == ("16", "%"))
        XCTAssertTrue(MenuFormatting.split("119 GB") == ("119", "GB"))
        XCTAssertTrue(MenuFormatting.split("30.5\u{00A0}KB/s") == ("30.5", "KB/s"))
        XCTAssertTrue(MenuFormatting.split("Normal") == ("Normal", ""))
    }

    func testChipNameDropsVendor() {
        XCTAssertEqual(MenuFormatting.chipName("Apple M4 Pro"), "M4 Pro")
        XCTAssertEqual(MenuFormatting.chipName("Intel(R) Core(TM) i7"), "Intel(R) Core(TM) i7")
    }
}
