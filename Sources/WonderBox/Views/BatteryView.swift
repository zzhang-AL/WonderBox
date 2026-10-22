import AppKit
import SwiftUI

struct BatteryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        BatteryContent(monitor: model.processorMonitor)
    }
}

private struct BatteryContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var metrics: MetricsStore
    @ObservedObject var monitor: ProcessorMonitor
    @State private var forceQuitTarget: ApplicationProcessorUsage?
    @State private var showForceQuitConfirmation = false

    private var battery: BatteryDetails? { metrics.snapshot.battery }

    private var energyUsers: [ApplicationProcessorUsage] {
        monitor.applications
            .filter { ($0.powerWatts ?? 0) >= 0.01 }
            .sorted { ($0.powerWatts ?? 0) > ($1.powerWatts ?? 0) }
            .prefix(15)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: String(localized: "Battery"),
                           subtitle: battery == nil ? String(localized: "This Mac has no battery")
                               : String(localized: "Charge, health, power draw and energy use by app"))

                if let battery {
                    statusPanel(battery)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 215), spacing: 14)], spacing: 14) {
                        tiles(battery)
                    }
                    if !metrics.powerHistory.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("System Power").font(.headline)
                            HistoryGraph(series: [.init(title: String(localized: "System Power"), values: metrics.powerHistory,
                                                        color: AppSection.battery.tint)],
                                         format: AppFormatters.watts, minimumTop: 10)
                        }
                        .appPanel()
                    }
                }
                energyPanel
            }
            .padding(28)
            .frame(maxWidth: 1_050, alignment: .leading)
        }
        .task { await monitor.prime() }
        .sectionRefresh(.battery, busy: model.isRefreshingMetrics || monitor.isRefreshing) {
            await model.refreshMetrics()
            await monitor.prime()
        }
        .confirmationDialog("Force quit this application?", isPresented: $showForceQuitConfirmation, titleVisibility: .visible) {
            if let target = forceQuitTarget {
                Button("Force Quit", role: .destructive) { Task { await monitor.quit(target, force: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved changes may be lost.")
        }
    }

    private func statusPanel(_ battery: BatteryDetails) -> some View {
        let tint: Color = battery.level < 0.2 && !battery.isPluggedIn ? .critical : AppSection.battery.tint
        return HStack(spacing: 22) {
            ZStack {
                Circle().stroke(Color.subtleBackground, lineWidth: 10)
                Circle().trim(from: 0, to: battery.level)
                    .stroke(tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(AppFormatters.percent(battery.level))
                        .font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                    Image(systemName: battery.isCharging ? "bolt.fill" : battery.isPluggedIn ? "powerplug.fill" : "battery.75percent")
                        .font(.caption).foregroundStyle(tint)
                }
            }
            .frame(width: 104, height: 104)

            VStack(alignment: .leading, spacing: 8) {
                Text(battery.state).font(.title3.weight(.semibold))
                Text(remainingText(battery)).font(.subheadline).foregroundStyle(.secondary)
                if let adapter = battery.adapterWatts {
                    Label("\(adapter) W power adapter", systemImage: "powerplug")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .appPanel()
    }

    private func remainingText(_ battery: BatteryDetails) -> String {
        guard let minutes = battery.minutesRemaining else {
            if battery.isPluggedIn && !battery.isCharging { return String(localized: "Running on the power adapter") }
            return String(localized: "Estimating time remaining…")
        }
        let duration = AppFormatters.duration(TimeInterval(minutes * 60))
        return battery.isCharging ? String(localized: "\(duration) until full") : String(localized: "\(duration) remaining")
    }

    @ViewBuilder
    private func tiles(_ battery: BatteryDetails) -> some View {
        if let power = battery.systemPower {
            MetricCard(title: String(localized: "System Power"), value: AppFormatters.watts(power),
                       detail: String(localized: "Whole-Mac draw"),
                       symbol: "bolt", tint: AppSection.battery.tint,
                       history: metrics.powerHistory, historyMaximum: nil)
        }
        if let power = battery.batteryPower {
            MetricCard(title: String(localized: "Battery Power"),
                       value: AppFormatters.watts(abs(power)),
                       detail: power > 0.05 ? String(localized: "Charging") : power < -0.05 ? String(localized: "Discharging") : String(localized: "Idle"),
                       symbol: power > 0.05 ? "arrow.down.to.line" : "arrow.up.forward",
                       tint: Color(hex: 0x3178F6))
        }
        if let health = battery.health {
            MetricCard(title: String(localized: "Health"), value: AppFormatters.percent(health),
                       detail: String(localized: "\(battery.fullChargeCapacity ?? 0) of \(battery.designCapacity ?? 0) mAh"),
                       symbol: "heart", tint: health < 0.8 ? .warning : .healthy, progress: health)
        }
        if let cycles = battery.cycleCount {
            MetricCard(title: String(localized: "Cycle Count"), value: "\(cycles)",
                       detail: battery.voltage.map { String(format: "%.2f V", $0) } ?? "",
                       symbol: "arrow.triangle.2.circlepath", tint: Color(hex: 0x7A67D8))
        }
        if let temperature = battery.temperature {
            MetricCard(title: String(localized: "Temperature"), value: String(format: "%.1f °C", temperature),
                       detail: String(localized: "Battery"), symbol: "thermometer.medium",
                       tint: temperature >= 40 ? .warning : Color(hex: 0xE1A127))
        }
    }

    private var energyPanel: some View {
        let total = energyUsers.reduce(0) { $0 + ($1.powerWatts ?? 0) }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Energy Users").font(.headline)
                Spacer()
                Text("Average power over the last few seconds").font(.caption).foregroundStyle(.secondary)
            }
            if monitor.applications.isEmpty {
                ProgressView("Measuring process usage…").frame(maxWidth: .infinity, minHeight: 100)
            } else if energyUsers.isEmpty {
                Text("No app is drawing noticeable power right now.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(energyUsers) { usage in
                        let share = total > 0 ? (usage.powerWatts ?? 0) / total : 0
                        EquatableRow(value: [usage.powerWatts ?? 0, share, usage.cpuPercent, usage.gpuPercent ?? -1]) {
                            row(usage, share: share)
                        }
                        .equatable()
                        Divider().padding(.leading, 42)
                    }
                }
            }
            Text("Estimated by macOS's per-process energy model for CPU, GPU and other components. System processes owned by other users are not included.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .appPanel()
    }

    private func row(_ usage: ApplicationProcessorUsage, share: Double) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: ApplicationIconCache.icon(for: usage.location))
                .resizable().scaledToFit().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(usage.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("CPU \(AppFormatters.decimalPercent(usage.cpuPercent)) · GPU \(usage.gpuPercent.map(AppFormatters.decimalPercent) ?? "—")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            ProgressView(value: min(1, share))
                .tint(AppSection.battery.tint).controlSize(.small).frame(width: 110).accessibilityHidden(true)
            Text(AppFormatters.watts(usage.powerWatts ?? 0))
                .font(.system(.body, design: .rounded, weight: .semibold))
                .monospacedDigit().frame(width: 70, alignment: .trailing)
            if usage.isQuittable {
                QuitMenu(quit: { Task { await monitor.quit(usage, force: false) } },
                         forceQuit: { forceQuitTarget = usage; showForceQuitConfirmation = true })
            } else { Color.clear.frame(width: 88) }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}
