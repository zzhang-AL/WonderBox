import AppKit
import SwiftUI

/// The menu bar window: a live health summary, one tile per subsystem, the heaviest apps and the
/// quick actions. Every tile opens its page in the main window.
struct MenuBarPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var dockPresence: DockPresenceController
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var preventer: SleepPreventer
    @ObservedObject var optimizer: MemoryOptimizer
    @AppStorage("awakeDuration") private var awakeDuration = AwakeDuration.oneHour.rawValue
    @AppStorage("keepDisplayAwake") private var keepDisplayAwake = false
    @AppStorage("menuTopAppsMetric") private var topAppsMetric = MenuTopAppsMetric.memory
    @State private var panelWindow = PanelWindowBox()
    @State private var isRefreshing = false

    private var selectedAwakeDuration: AwakeDuration {
        AwakeDuration(rawValue: awakeDuration) ?? .oneHour
    }

    private var actionMessage: String? {
        model.quickActionMessage ?? optimizer.message
    }

    private var actionMessageIsError: Bool {
        model.quickActionMessage == nil && optimizer.messageIsError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MenuHealthHeader(
                systemInfo: model.systemInfo,
                isRefreshing: isRefreshing,
                refresh: { Task { await refreshAll() } },
                open: open
            )

            MenuMetricGrid(fans: model.fans, temperatures: model.temperatures, open: open)

            MenuTopApps(
                processor: model.processorMonitor,
                optimizer: optimizer,
                metric: $topAppsMetric,
                open: open
            )

            quickActions

            quickCleanEstimateLabel

            if let actionMessage {
                InlineMessage(text: actionMessage, isError: actionMessageIsError) {
                    model.dismissQuickActionMessage()
                }
            }

            footer
        }
        .padding(14)
        .frame(width: 380)
        .background(PanelWindowReader(box: panelWindow))
        .task {
            model.startApplicationServices()
            await runLiveUpdates()
        }
        .onChange(of: topAppsMetric) { _, _ in
            Task { await refreshTopApps(fresh: true) }
        }
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 8) {
            MenuActionButton(
                title: preventer.isActive ? preventer.remainingText : String(localized: "Keep Awake"),
                symbol: preventer.isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
                tint: AppSection.awake.tint,
                isActive: preventer.isActive,
                help: preventer.isActive
                    ? String(localized: "Stop keeping the Mac awake")
                    : String(localized: "Keep the Mac awake for \(selectedAwakeDuration.title). Right-click for other durations."),
                action: toggleAwake
            )
            .contextMenu { awakeMenu }

            MenuActionButton(
                title: optimizer.isOptimizing ? String(localized: "Working…") : String(localized: "Optimize Memory"),
                symbol: "memorychip",
                tint: AppSection.memory.tint,
                isWorking: optimizer.isOptimizing,
                isDisabled: model.isQuickCleaning,
                help: String(localized: "Ask apps to release cached memory"),
                action: { Task { await model.optimizeMemory() } }
            )

            MenuActionButton(
                title: model.isQuickCleaning ? String(localized: "Working…") : String(localized: "Quick Clean"),
                symbol: "sparkles",
                tint: AppSection.cleaner.tint,
                isWorking: model.isQuickCleaning,
                isDisabled: optimizer.isOptimizing || model.isUninstallingApplication || model.isScanningStorage
                    || model.isCleaningStorage || model.isEstimatingQuickClean,
                help: String(localized: "Remove caches and logs that are safe to delete"),
                action: { Task { await model.quickClean() } }
            )
        }
    }

    @ViewBuilder
    private var quickCleanEstimateLabel: some View {
        Group {
            if model.isEstimatingQuickClean {
                Label("Estimating reclaimable caches…", systemImage: "hourglass")
            } else if let estimate = model.quickCleanEstimate {
                Label("Quick Clean · About \(AppFormatters.bytes(estimate)) reclaimable", systemImage: "externaldrive.badge.checkmark")
            } else {
                Label("Cache estimate not available yet", systemImage: "externaldrive")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Estimate includes the default Quick Clean categories; actual reclaimed space may vary")
    }

    @ViewBuilder
    private var awakeMenu: some View {
        ForEach(AwakeDuration.allCases) { duration in
            Button {
                awakeDuration = duration.rawValue
                preventer.enable(duration: duration.seconds, keepDisplayAwake: keepDisplayAwake)
            } label: {
                if duration == selectedAwakeDuration {
                    Label(duration.title, systemImage: "checkmark")
                } else {
                    Text(duration.title)
                }
            }
        }
        Divider()
        Toggle("Keep Display Awake", isOn: $keepDisplayAwake)
        if preventer.isActive {
            Divider()
            Button("Stop Keeping Awake") { preventer.disable() }
        }
    }

    private func toggleAwake() {
        if preventer.isActive {
            preventer.disable()
        } else {
            preventer.enable(duration: selectedAwakeDuration.seconds, keepDisplayAwake: keepDisplayAwake)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                open(model.selection ?? .overview)
            } label: {
                Label("Open WonderBox", systemImage: "macwindow")
            }
            .keyboardShortcut("o")
            .help("Open the main window (⌘O)")

            Spacer()

            Button {
                open(.settings)
            } label: {
                Image(systemName: "gearshape")
            }
            .keyboardShortcut(",")
            .help("Settings (⌘,)")
            .accessibilityLabel("Open settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .keyboardShortcut("q")
            .help("Quit WonderBox (⌘Q)")
            .accessibilityLabel("Quit WonderBox")
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    // MARK: Updates

    /// Samples every two seconds while the panel is on screen and idles while it is closed. A
    /// reopened panel starts over at tick 0, so fans and app rankings are fresh immediately.
    private func runLiveUpdates() async {
        var tick = 0
        while !Task.isCancelled {
            guard panelWindow.isOnScreen else {
                tick = 0
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            // The main window's loop may have just sampled; don't double the sampling rate.
            if Date().timeIntervalSince(model.metrics.snapshot.sampledAt) >= 1.5 {
                await model.metrics.refresh()
            }
            if tick % 2 == 0 { await refreshTopApps(fresh: tick == 0) }
            if tick % 5 == 0 { await model.refreshFans() }
            if tick % 5 == 0 { await model.refreshQuickCleanEstimate() }
            tick += 1
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// `fresh` takes a second, short CPU sample so percentages aren't averaged over the time the
    /// panel was closed.
    private func refreshTopApps(fresh: Bool) async {
        switch topAppsMetric {
        case .memory:
            await optimizer.refreshApplications()
        case .cpu:
            await model.processorMonitor.refresh()
            if fresh {
                try? await Task.sleep(for: .seconds(1))
                await model.processorMonitor.refresh()
            }
        }
    }

    private func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await model.refreshMetrics()
        await model.refreshQuickCleanEstimate(force: true)
        await refreshTopApps(fresh: true)
        await model.refreshFans()
    }

    private func open(_ section: AppSection) {
        model.selection = section
        dockPresence.willShowMainWindow()
        openWindow(id: "main")
    }
}

enum MenuTopAppsMetric: String, CaseIterable, Identifiable {
    case memory, cpu

    var id: Self { self }

    var title: String {
        switch self {
        case .memory: String(localized: "Memory")
        case .cpu: "CPU"
        }
    }

    var section: AppSection {
        switch self {
        case .memory: .memory
        case .cpu: .cpu
        }
    }
}

enum MenuFormatting {
    /// "119 GB" → ("119", "GB"), "16%" → ("16", "%"), so the number can be set larger than its unit.
    static func split(_ text: String) -> (value: String, unit: String) {
        if text.hasSuffix("%") { return (String(text.dropLast()), "%") }
        if let space = text.lastIndex(where: { $0 == " " || $0 == "\u{00A0}" }) {
            return (String(text[..<space]), String(text[text.index(after: space)...]))
        }
        return (text, "")
    }

    /// "Apple M4 Pro" → "M4 Pro"; the vendor adds nothing in a chip.
    static func chipName(_ processor: String) -> String {
        processor.hasPrefix("Apple ") ? String(processor.dropFirst(6)) : processor
    }

    static func mean(_ values: some Collection<Double>) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}

// MARK: - Header

private struct MenuHealthHeader: View {
    @EnvironmentObject private var metrics: MetricsStore
    let systemInfo: SystemInformation
    let isRefreshing: Bool
    let refresh: () -> Void
    let open: (AppSection) -> Void

    private var health: SystemHealth {
        SystemHealth(snapshot: metrics.snapshot, recentCPU: MenuFormatting.mean(metrics.cpuHistory.suffix(5)))
    }

    var body: some View {
        let health = health
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { open(.overview) } label: {
                    HealthRing(score: health.score, color: health.grade.color)
                }
                .buttonStyle(.plain)
                .help(health.issues.isEmpty
                      ? String(localized: "No issues found")
                      : health.issues.map(\.title).joined(separator: "\n"))
                .accessibilityLabel(String(localized: "Health score \(health.score), \(health.grade.title)"))

                VStack(alignment: .leading, spacing: 2) {
                    Text(health.grade.title)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text(health.issues.first?.title ?? String(localized: "Everything looks normal"))
                        .font(.caption)
                        .foregroundStyle(issueColor(health))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button(action: refresh) {
                    Group {
                        if isRefreshing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("r")
                .disabled(isRefreshing)
                .help("Refresh Status (⌘R)")
                .accessibilityLabel("Refresh menu bar status")
            }

            ViewThatFits(in: .horizontal) {
                chips(includeSystem: true)
                chips(includeSystem: false)
            }
        }
    }

    /// A good score can still carry a minor issue; it reads as a warning, not as good news.
    private func issueColor(_ health: SystemHealth) -> Color {
        guard !health.issues.isEmpty else { return .secondary }
        return health.grade == .poor ? .critical : .warning
    }

    private func chips(includeSystem: Bool) -> some View {
        HStack(spacing: 6) {
            InfoChip(text: MenuFormatting.chipName(systemInfo.processorName))
            InfoChip(text: AppFormatters.memory(metrics.snapshot.memory.total))
            if includeSystem {
                InfoChip(text: systemInfo.operatingSystem)
            }
            InfoChip(text: String(localized: "Up \(AppFormatters.duration(metrics.snapshot.uptime))"))
        }
        .fixedSize()
    }
}

private struct HealthRing: View {
    let score: Int
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: 4)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(width: 46, height: 46)
        .animation(.easeOut(duration: 0.4), value: score)
    }
}

private struct InfoChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.subtleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - Metric tiles

private struct MenuMetricGrid: View {
    @EnvironmentObject private var metrics: MetricsStore
    let fans: [FanReading]
    let temperatures: [TemperatureReading]
    let open: (AppSection) -> Void

    private var snapshot: MetricSnapshot { metrics.snapshot }

    var body: some View {
        let tiles = tiles
        VStack(spacing: 8) {
            ForEach(Array(stride(from: 0, to: tiles.count, by: 2)), id: \.self) { index in
                if index + 1 < tiles.count {
                    HStack(spacing: 8) {
                        tiles[index]
                        tiles[index + 1]
                    }
                } else {
                    tiles[index].environment(\.menuTileIsWide, true)
                }
            }
        }
    }

    /// GPU, battery and fan tiles only exist where the hardware does (a MacBook Air has no fan);
    /// an odd last tile spans the row.
    private var tiles: [AnyView] {
        var result = [AnyView(cpuTile)]
        if let gpu = snapshot.gpuUsage { result.append(AnyView(gpuTile(gpu))) }
        if !temperatures.isEmpty { result.append(AnyView(temperatureTile)) }
        result.append(AnyView(memoryTile))
        result.append(AnyView(diskTile))
        result.append(AnyView(networkTile))
        if let battery = snapshot.battery { result.append(AnyView(batteryTile(battery))) }
        if let fastest = fans.max(by: { $0.currentRPM < $1.currentRPM }) {
            result.append(AnyView(fanTile(fastest)))
        }
        return result
    }

    private var cpuTile: some View {
        let load = LoadLevel(snapshot.cpuUsage)
        let cores = snapshot.cpuCores.isEmpty ? ProcessInfo.processInfo.activeProcessorCount : snapshot.cpuCores.count
        var detail = String(localized: "\(cores) cores")
        if let average = snapshot.loadAverage.first {
            detail += " · " + String(localized: "Load \(String(format: "%.2f", average))")
        }
        return MenuTile(
            title: "CPU", symbol: "cpu", tint: AppSection.cpu.tint,
            badge: TileBadge(text: load.title, color: load.color),
            value: AppFormatters.percent(snapshot.cpuUsage), detail: detail,
            help: String(localized: "User \(AppFormatters.percent(snapshot.cpuUser)) · System \(AppFormatters.percent(snapshot.cpuSystem))"),
            action: { open(.cpu) }
        ) {
            if snapshot.cpuCores.isEmpty {
                MenuTrend(values: metrics.cpuHistory, tint: AppSection.cpu.tint)
            } else {
                CoreBars(values: snapshot.cpuCores, tint: AppSection.cpu.tint)
            }
        }
    }

    private func gpuTile(_ usage: Double) -> some View {
        let load = LoadLevel(usage)
        let detail = snapshot.gpuStatistics.map { String(localized: "\(AppFormatters.memory($0.memoryInUse)) in use") } ?? load.title
        return MenuTile(
            title: "GPU", symbol: "cube.transparent", tint: AppSection.gpu.tint,
            badge: TileBadge(text: load.title, color: load.color),
            value: AppFormatters.percent(usage), detail: detail,
            help: snapshot.gpuStatistics.map {
                String(localized: "Renderer \(AppFormatters.percent($0.renderer)) · Tiler \(AppFormatters.percent($0.tiler))")
            } ?? "GPU",
            action: { open(.gpu) }
        ) {
            MenuTrend(values: metrics.gpuHistory, tint: AppSection.gpu.tint)
        }
    }

    /// One tile for both sides: SMC exposes many sensors, but only the hottest CPU and GPU reading
    /// is worth a glance. Unavailable sensors render an em dash rather than disappearing.
    private var temperatureTile: some View {
        let cpu = TemperatureReading.summary(temperatures)
        let gpu = TemperatureReading.summary(temperatures, gpu: true)
        let hottest = temperatures.map(\.celsius).max() ?? 0
        return MenuTile(
            title: String(localized: "Temperature"), symbol: "thermometer.medium", tint: AppSection.cpu.tint,
            value: cpu, detail: "GPU " + gpu,
            help: String(localized: "Highest available sensor reading; unavailable sensors show a dash"),
            action: { open(.cpu) }
        ) {
            MeterBar(fraction: min(max(hottest / 100, 0), 1), color: AppSection.cpu.tint)
        }
    }

    private var memoryTile: some View {
        let memory = snapshot.memory
        return MenuTile(
            title: String(localized: "Memory"), symbol: "memorychip", tint: AppSection.memory.tint,
            badge: TileBadge(text: String(localized: "Pressure \(memory.pressure.title)"), color: memory.pressure.color),
            value: AppFormatters.percent(memory.usedFraction),
            detail: "\(AppFormatters.memory(memory.used)) / \(AppFormatters.memory(memory.total))",
            help: String(localized: "App \(AppFormatters.memory(memory.app)) · Wired \(AppFormatters.memory(memory.wired)) · Compressed \(AppFormatters.memory(memory.compressed)) · Swap \(AppFormatters.memory(memory.swapUsed))"),
            action: { open(.memory) }
        ) {
            // History starts as zeros; memory is never really zero, so skip the placeholder run.
            MenuTrend(values: Array(metrics.memoryHistory.drop(while: { $0 == 0 })), tint: AppSection.memory.tint)
        }
    }

    private var diskTile: some View {
        let fraction = snapshot.diskFraction
        let free = snapshot.diskTotal - min(snapshot.diskTotal, snapshot.diskUsed)
        let color: Color = fraction > 0.9 ? .critical : fraction > 0.8 ? .warning : AppSection.storage.tint
        return MenuTile(
            title: String(localized: "Free Space"), symbol: "internaldrive", tint: AppSection.storage.tint,
            badge: TileBadge(text: String(localized: "\(AppFormatters.percent(fraction)) used"), color: fraction > 0.8 ? color : .secondary),
            value: AppFormatters.bytes(free),
            detail: String(localized: "\(AppFormatters.bytes(snapshot.diskUsed)) of \(AppFormatters.bytes(snapshot.diskTotal)) used"),
            help: String(localized: "Available space includes purgeable files macOS can remove on demand"),
            action: { open(.storage) }
        ) {
            MeterBar(fraction: fraction, color: color)
        }
    }

    private var networkTile: some View {
        let tunnel = snapshot.networkInterfaces.contains { $0.isTunnel && $0.downPerSecond + $0.upPerSecond > 0 }
        let top = max(metrics.downloadHistory.max() ?? 0, metrics.uploadHistory.max() ?? 0, 1_024)
        return MenuTile(
            title: String(localized: "Network"), symbol: "arrow.up.arrow.down", tint: AppSection.network.tint,
            badge: tunnel ? TileBadge(text: "VPN", color: AppSection.network.tint) : nil,
            value: AppFormatters.rate(snapshot.networkDownPerSecond),
            detail: String(localized: "Upload \(AppFormatters.rate(snapshot.networkUpPerSecond))"),
            help: String(localized: "Since boot: received \(AppFormatters.bytes(snapshot.networkReceivedTotal)) · sent \(AppFormatters.bytes(snapshot.networkSentTotal))"),
            action: { open(.network) }
        ) {
            ZStack {
                MenuTrend(values: metrics.downloadHistory, maximum: top, tint: AppSection.network.tint)
                Sparkline(values: metrics.uploadHistory, maximum: top)
                    .stroke(Color(hex: 0xF18B43), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func batteryTile(_ battery: BatteryDetails) -> some View {
        let color: Color = battery.level < 0.2 && !battery.isPluggedIn ? .critical : AppSection.battery.tint
        var detail = battery.state
        if let minutes = battery.minutesRemaining, !battery.isFullyCharged {
            detail += " · " + String(localized: "\(AppFormatters.duration(TimeInterval(minutes * 60))) remaining")
        } else if let power = battery.systemPower {
            detail += " · " + AppFormatters.watts(power)
        }
        var help: [String] = []
        if let cycles = battery.cycleCount { help.append(String(localized: "\(cycles) cycles")) }
        if let power = battery.systemPower { help.append(String(localized: "System power \(AppFormatters.watts(power))")) }
        if let watts = battery.adapterWatts { help.append(String(localized: "\(watts) W adapter")) }
        if let temperature = battery.temperature { help.append(String(format: "%.1f °C", temperature)) }
        return MenuTile(
            title: String(localized: "Battery"),
            symbol: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent",
            tint: AppSection.battery.tint,
            badge: battery.health.map {
                TileBadge(text: String(localized: "Health \(AppFormatters.percent($0))"), color: $0 < 0.8 ? .warning : .secondary)
            },
            value: AppFormatters.percent(battery.level), detail: detail,
            help: help.isEmpty ? battery.state : help.joined(separator: " · "),
            action: { open(.battery) }
        ) {
            MeterBar(fraction: battery.level, color: color)
        }
    }

    /// Thermal state still counts toward the health score on fanless Macs; this tile is about the fans.
    private func fanTile(_ fastest: FanReading) -> some View {
        let state = snapshot.thermalState
        let span = fastest.maximumRPM - fastest.minimumRPM
        let fraction = span > 0 ? (fastest.currentRPM - fastest.minimumRPM) / span : 0
        var detail = String(localized: "Thermal state \(state.title)")
        if let temperature = snapshot.battery?.temperature {
            detail += " · " + String(format: "%.0f °C", temperature)
        }
        return MenuTile(
            title: fans.count == 1 ? AppSection.fan.title : String(localized: "\(fans.count) fans"),
            symbol: "fan", tint: AppSection.fan.tint,
            badge: state == .nominal ? nil : TileBadge(text: state.title, color: state.color),
            value: "\(Int(fastest.currentRPM.rounded())) RPM", detail: detail,
            help: String(localized: "Fastest fan; range \(Int(fastest.minimumRPM.rounded()))–\(Int(fastest.maximumRPM.rounded())) RPM"),
            action: { open(.fan) }
        ) {
            MeterBar(fraction: fraction, color: state == .nominal ? AppSection.fan.tint : state.color)
        }
    }
}

private struct TileBadge {
    let text: String
    let color: Color
}

private struct MenuTile<Visual: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    var badge: TileBadge?
    let value: String
    let detail: String
    let help: String
    let action: () -> Void
    @ViewBuilder let visual: () -> Visual
    @Environment(\.menuTileIsWide) private var isWide
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if isWide {
                    // A tile alone in the last row: one line instead of a tall, mostly empty card.
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            header
                            valueText(size: 18)
                        }
                        .frame(width: 128, alignment: .leading)
                        VStack(alignment: .leading, spacing: 7) {
                            visual()
                                .frame(height: 14)
                                .frame(maxWidth: .infinity)
                            detailText
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 5) {
                            header
                            Spacer(minLength: 4)
                            accessory
                        }
                        .frame(height: 16)
                        valueText(size: 22)
                        visual()
                            .frame(height: 22)
                            .frame(maxWidth: .infinity)
                        detailText
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if isWide { accessory }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? Color.primary.opacity(0.07) : Color.subtleBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .stroke(isHovering ? tint.opacity(0.45) : Color.separatorSoft, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(title), \(value), \(detail)"))
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// The badge, or an "opens in the main window" arrow while hovered.
    @ViewBuilder
    private var accessory: some View {
        if isHovering {
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
        } else if let badge {
            Text(badge.text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(badge.color)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(badge.color.opacity(0.12))
                .clipShape(Capsule())
        }
    }

    private func valueText(size: CGFloat) -> some View {
        let parts = MenuFormatting.split(value)
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(parts.value)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(parts.unit)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var detailText: some View {
        Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

private struct MenuTileIsWideKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var menuTileIsWide: Bool {
        get { self[MenuTileIsWideKey.self] }
        set { self[MenuTileIsWideKey.self] = newValue }
    }
}

/// A line over a soft fill, the shape most rolling histories here use.
private struct MenuTrend: View {
    let values: [Double]
    var maximum: Double? = 1
    let tint: Color

    var body: some View {
        if values.count < 2 {
            Capsule().fill(Color.primary.opacity(0.06)).frame(height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        } else {
            ZStack {
                SparklineArea(values: values, maximum: maximum)
                    .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Sparkline(values: values, maximum: maximum)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// One bar per logical core, efficiency cores first.
private struct CoreBars: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: values.count > 16 ? 1 : 2) {
                ForEach(values.indices, id: \.self) { index in
                    let value = min(1, max(0, values[index]))
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(value > 0.85 ? Color.warning : tint.opacity(0.35 + value * 0.65))
                        .frame(height: max(2, proxy.size.height * value))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .animation(.easeOut(duration: 0.3), value: values)
        .accessibilityHidden(true)
    }
}

private struct MeterBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color.gradient)
                    .frame(width: max(6, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

// MARK: - Top apps

private struct MenuTopApps: View {
    @ObservedObject var processor: ProcessorMonitor
    @ObservedObject var optimizer: MemoryOptimizer
    @Binding var metric: MenuTopAppsMetric
    let open: (AppSection) -> Void

    private struct Row: Identifiable, Equatable {
        var id: URL { location }
        let location: URL
        let name: String
        let value: Double
        let text: String
        let isQuittable: Bool
    }

    private static let limit = 5

    private var rows: [Row] {
        switch metric {
        case .memory:
            optimizer.applications
                .sorted { $0.footprint > $1.footprint }
                .prefix(Self.limit)
                .map { Row(location: $0.location, name: $0.name, value: Double($0.footprint),
                           text: AppFormatters.memory($0.footprint), isQuittable: $0.isQuittable) }
        case .cpu:
            processor.applications
                .filter(\.cpuAvailable)
                .sorted { $0.cpuPercent > $1.cpuPercent }
                .prefix(Self.limit)
                .map { Row(location: $0.location, name: $0.name, value: $0.cpuPercent,
                           text: AppFormatters.decimalPercent($0.cpuPercent), isQuittable: $0.isQuittable) }
        }
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Top Apps")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Sort by", selection: $metric) {
                    ForEach(MenuTopAppsMetric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }

            if rows.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Measuring…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                let top = max(rows.first?.value ?? 0, .ulpOfOne)
                VStack(spacing: 2) {
                    ForEach(rows) { row in
                        MenuAppRow(
                            name: row.name, location: row.location, text: row.text,
                            share: row.value / top, tint: metric.section.tint, isQuittable: row.isQuittable,
                            open: { open(metric.section) },
                            quit: { force in quit(row.location, name: row.name, force: force) }
                        )
                    }
                }
            }
        }
        .padding(10)
        .background(Color.subtleBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .stroke(Color.separatorSoft, lineWidth: 1)
        }
    }

    private func quit(_ location: URL, name: String, force: Bool) {
        if force {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = String(localized: "Force Quit \(name)")
            alert.informativeText = String(localized: "Unsaved changes in \(name) will be lost.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Force Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task {
            switch metric {
            case .memory:
                if let usage = optimizer.applications.first(where: { $0.location == location }) {
                    await optimizer.quit(usage, force: force)
                }
            case .cpu:
                if let usage = processor.applications.first(where: { $0.location == location }) {
                    await processor.quit(usage, force: force)
                }
            }
        }
    }
}

private struct MenuAppRow: View {
    let name: String
    let location: URL
    let text: String
    let share: Double
    let tint: Color
    let isQuittable: Bool
    let open: () -> Void
    let quit: (_ force: Bool) -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: ApplicationIconCache.icon(for: location))
                .resizable()
                .frame(width: 18, height: 18)
            Text(name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(text)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovering ? 1 : 0)
            .accessibilityLabel(String(localized: "Actions for \(name)"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint.opacity(isHovering ? 0.16 : 0.09))
                    .frame(width: proxy.size.width * min(1, max(0, share)))
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu { actions }
        .animation(.easeOut(duration: 0.3), value: share)
    }

    @ViewBuilder
    private var actions: some View {
        if isQuittable {
            Button("Quit") { quit(false) }
            Button("Force Quit…") { quit(true) }
            Divider()
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([location]) }
        Button("Open in WonderBox", action: open)
    }
}

// MARK: - Quick action button

private struct MenuActionButton: View {
    let title: String
    let symbol: String
    let tint: Color
    var isActive = false
    var isWorking = false
    var isDisabled = false
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Group {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .medium))
                    }
                }
                .frame(height: 18)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isActive ? Color.white : isDisabled ? Color.secondary : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background {
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(isActive ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(isHovering ? tint.opacity(0.14) : Color.subtleBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .stroke(isHovering && !isActive ? tint.opacity(0.4) : Color.separatorSoft, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isWorking || isDisabled)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(help)
    }
}

// MARK: - Panel visibility

/// The panel's own window, so the update loop can idle while the menu is closed.
@MainActor
private final class PanelWindowBox {
    weak var window: NSWindow?

    /// Not yet attached means SwiftUI is still putting the panel on screen.
    var isOnScreen: Bool {
        guard let window else { return true }
        return window.isVisible && window.occlusionState.contains(.visible)
    }
}

private struct PanelWindowReader: NSViewRepresentable {
    let box: PanelWindowBox

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.box = box
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var box: PanelWindowBox?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            box?.window = window
        }
    }
}
