import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var metrics: MetricsStore

    private var health: (title: String, detail: String, color: Color, symbol: String) {
        switch metrics.snapshot.thermalState {
        case .nominal:
            switch metrics.snapshot.memory.pressure {
            case .normal: (String(localized: "All Good"), String(localized: "Thermals and resource usage are normal"), .healthy, "checkmark.circle.fill")
            case .warning: (String(localized: "Memory Pressure Elevated"), String(localized: "The system is compressing memory; optimize or quit heavy apps"), .warning, "memorychip")
            case .critical: (String(localized: "Memory Pressure Critical"), String(localized: "Swap is heavily used; free memory now"), .critical, "exclamationmark.triangle.fill")
            }
        case .fair: (String(localized: "Light Load"), String(localized: "The thermal system is adjusting"), .warning, "thermometer.medium")
        case .serious: (String(localized: "High Load"), String(localized: "Consider closing heavy tasks"), .warning, "thermometer.high")
        case .critical: (String(localized: "Temperature Warning"), String(localized: "Reduce the current system load"), .critical, "exclamationmark.triangle.fill")
        @unknown default: (String(localized: "Status Unknown"), String(localized: "Waiting for the next sample"), .secondary, "questionmark.circle")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: String(localized: "Overview"),
                    subtitle: "\(model.systemInfo.computerName) · \(model.systemInfo.operatingSystem)"
                )

                healthBanner

                CompositorAlertBanner(compositor: model.compositor, probe: model.compositorProbe)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 215), spacing: 14)], spacing: 14) {
                    MetricCard(
                        title: String(localized: "Processor"),
                        value: AppFormatters.percent(metrics.snapshot.cpuUsage),
                        detail: model.systemInfo.processorName,
                        symbol: "cpu",
                        tint: Color(hex: 0x3178F6),
                        progress: metrics.snapshot.cpuUsage,
                        history: metrics.cpuHistory
                    )
                    if let gpuUsage = metrics.snapshot.gpuUsage {
                        MetricCard(
                            title: "GPU",
                            value: AppFormatters.percent(gpuUsage),
                            detail: model.systemInfo.graphicsName,
                            symbol: "cube.transparent",
                            tint: Color(hex: 0x7A67D8),
                            progress: gpuUsage,
                            history: metrics.gpuHistory,
                            actionSymbol: "macwindow.on.rectangle",
                            actionHelp: String(localized: "Go to GPU and window compositing"),
                            action: { model.selection = .gpu }
                        )
                    }
                    MetricCard(
                        title: String(localized: "Memory"),
                        value: AppFormatters.percent(metrics.snapshot.memoryFraction),
                        detail: String(localized: "\(AppFormatters.memory(metrics.snapshot.memory.used)) used · \(AppFormatters.memory(metrics.snapshot.memory.compressed)) compressed"),
                        symbol: "memorychip",
                        tint: AppSection.memory.tint,
                        progress: metrics.snapshot.memoryFraction,
                        history: metrics.memoryHistory,
                        actionSymbol: "wand.and.stars",
                        actionHelp: String(localized: "Go to memory optimization"),
                        action: { model.selection = .memory }
                    )
                    MetricCard(
                        title: String(localized: "Disk"),
                        value: AppFormatters.percent(metrics.snapshot.diskFraction),
                        detail: String(localized: "\(AppFormatters.bytes(metrics.snapshot.diskTotal - min(metrics.snapshot.diskTotal, metrics.snapshot.diskUsed))) available"),
                        symbol: "internaldrive",
                        tint: Color(hex: 0xE66756),
                        progress: metrics.snapshot.diskFraction,
                        actionSymbol: "magnifyingglass",
                        actionHelp: String(localized: "Scan disk"),
                        action: { model.selection = .storage }
                    )
                    MetricCard(
                        title: String(localized: "Network"),
                        value: AppFormatters.rate(metrics.snapshot.networkDownPerSecond),
                        detail: String(localized: "Upload \(AppFormatters.rate(metrics.snapshot.networkUpPerSecond))"),
                        symbol: "arrow.up.arrow.down",
                        tint: AppSection.network.tint,
                        history: metrics.downloadHistory,
                        historyMaximum: nil,
                        actionSymbol: "list.bullet",
                        actionHelp: String(localized: "See traffic by app"),
                        action: { model.selection = .network }
                    )
                    if let battery = metrics.snapshot.batteryLevel {
                        MetricCard(
                            title: String(localized: "Battery"),
                            value: AppFormatters.percent(battery),
                            detail: batteryDetail,
                            symbol: metrics.snapshot.isCharging ? "battery.100percent.bolt" : "battery.75percent",
                            tint: battery < 0.2 ? .critical : .healthy,
                            progress: battery,
                            actionSymbol: "bolt",
                            actionHelp: String(localized: "See battery health and energy use"),
                            action: { model.selection = .battery }
                        )
                    }
                    MetricCard(
                        title: String(localized: "Uptime"),
                        value: AppFormatters.duration(metrics.snapshot.uptime),
                        detail: model.systemInfo.modelIdentifier,
                        symbol: "clock.arrow.circlepath",
                        tint: Color(hex: 0xE1A127)
                    )
                }

                systemDetails
            }
            .padding(28)
            .frame(maxWidth: 1_160, alignment: .leading)
        }
        .sectionRefresh(.overview, busy: model.isRefreshingMetrics) { await model.refreshMetrics() }
    }

    private var batteryDetail: String {
        let state = metrics.snapshot.battery?.state
            ?? (metrics.snapshot.isCharging ? String(localized: "Charging") : String(localized: "On battery"))
        guard let power = metrics.snapshot.battery?.systemPower else { return state }
        return "\(state) · \(AppFormatters.watts(power))"
    }

    private var healthBanner: some View {
        HStack(spacing: 15) {
            Image(systemName: health.symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(health.color)
                .frame(width: 46, height: 46)
                .background(health.color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(health.title)
                    .font(.headline)
                Text(health.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(
                text: model.isMonitoring ? String(localized: "Live") : String(localized: "Paused"),
                color: model.isMonitoring ? .healthy : .secondary
            )
        }
        .appPanel(padding: 14)
    }

    private var systemDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Device")
                .font(.headline)
            Divider()
            // Grid sizes the label column to the longest translated label instead of a fixed width.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 14) {
                detailRow(String(localized: "Model"), model.systemInfo.modelIdentifier)
                detailRow(String(localized: "Processor"), model.systemInfo.processorName)
                detailRow("GPU", model.systemInfo.graphicsName)
                detailRow(String(localized: "Architecture"), model.systemInfo.architecture)
                detailRow(String(localized: "Operating System"), model.systemInfo.operatingSystem)
            }
            .font(.subheadline)
        }
        .appPanel()
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
