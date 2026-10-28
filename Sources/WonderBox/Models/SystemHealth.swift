import Foundation
import SwiftUI

/// A 0–100 summary of how comfortable the Mac is right now, plus what is dragging it down.
/// Penalties only kick in past thresholds a user would notice, so an idle Mac scores 100.
struct SystemHealth: Equatable {
    enum Issue: Equatable {
        case thermal(ProcessInfo.ThermalState)
        case memoryPressure(MemoryPressure)
        case memoryFull
        case swap
        case processorBusy
        case diskFull
        case batteryLow

        var title: String {
            switch self {
            case let .thermal(state): String(localized: "Thermal state \(state.title)")
            case let .memoryPressure(pressure): pressure == .critical
                ? String(localized: "Memory Pressure Critical") : String(localized: "Memory Pressure Elevated")
            case .memoryFull: String(localized: "Memory nearly full")
            case .swap: String(localized: "Heavy swap use")
            case .processorBusy: String(localized: "Processor busy")
            case .diskFull: String(localized: "Disk space low")
            case .batteryLow: String(localized: "Battery low")
            }
        }
    }

    enum Grade: Equatable {
        case excellent, good, fair, poor

        var title: String {
            switch self {
            case .excellent: String(localized: "Excellent")
            case .good: String(localized: "Good")
            case .fair: String(localized: "Fair")
            case .poor: String(localized: "Strained")
            }
        }

        var color: Color {
            switch self {
            case .excellent, .good: .healthy
            case .fair: .warning
            case .poor: .critical
            }
        }
    }

    let score: Int
    /// Largest penalty first.
    let issues: [Issue]

    var grade: Grade {
        switch score {
        case 90...: .excellent
        case 75..<90: .good
        case 55..<75: .fair
        default: .poor
        }
    }

    /// `recentCPU` should be smoothed over a few samples; a single sample makes the score flicker.
    init(snapshot: MetricSnapshot, recentCPU: Double) {
        var penalties: [(Issue, Double)] = []

        switch snapshot.thermalState {
        case .fair: penalties.append((.thermal(.fair), 10))
        case .serious: penalties.append((.thermal(.serious), 25))
        case .critical: penalties.append((.thermal(.critical), 45))
        default: break
        }

        let memory = snapshot.memory
        switch memory.pressure {
        case .warning: penalties.append((.memoryPressure(.warning), 15))
        case .critical: penalties.append((.memoryPressure(.critical), 35))
        case .normal: break
        }
        if memory.usedFraction > 0.85 {
            penalties.append((.memoryFull, min(1, (memory.usedFraction - 0.85) / 0.15) * 10))
        }
        let gigabyte: UInt64 = 1 << 30
        if memory.swapUsed >= 8 * gigabyte {
            penalties.append((.swap, 10))
        } else if memory.swapUsed >= 2 * gigabyte {
            penalties.append((.swap, 5))
        }

        if recentCPU > 0.6 {
            penalties.append((.processorBusy, min(1, (recentCPU - 0.6) / 0.4) * 20))
        }

        if snapshot.diskTotal > 0 {
            let free = 1 - snapshot.diskFraction
            if free < 0.1 {
                penalties.append((.diskFull, (0.1 - max(0, free)) / 0.1 * 20))
            }
        }

        if let battery = snapshot.battery, !battery.isPluggedIn, battery.level < 0.2 {
            penalties.append((.batteryLow, 10))
        }

        let total = penalties.reduce(0) { $0 + $1.1 }
        score = max(0, min(100, Int((100 - total).rounded())))
        issues = penalties.filter { $0.1 >= 1 }.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

/// Coarse load buckets for badges, so small percentage changes don't change the wording.
enum LoadLevel: Equatable {
    case low, medium, high

    init(_ fraction: Double) {
        switch fraction {
        case ..<0.3: self = .low
        case ..<0.7: self = .medium
        default: self = .high
        }
    }

    var title: String {
        switch self {
        case .low: String(localized: "Low Load")
        case .medium: String(localized: "Medium Load")
        case .high: String(localized: "High Load")
        }
    }

    var color: Color {
        switch self {
        case .low: .healthy
        case .medium: .warning
        case .high: .critical
        }
    }
}

extension ProcessInfo.ThermalState {
    var title: String {
        switch self {
        case .nominal: String(localized: "Normal")
        case .fair: String(localized: "Warm")
        case .serious: String(localized: "Hot")
        case .critical: String(localized: "Critical")
        @unknown default: String(localized: "Unknown")
        }
    }

    var color: Color {
        switch self {
        case .nominal: .healthy
        case .fair, .serious: .warning
        default: .critical
        }
    }
}
