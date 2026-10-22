import AppKit
import SwiftUI

struct GPUView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GPUContent(monitor: model.processorMonitor, compositor: model.compositor, probe: model.compositorProbe)
    }
}

private struct GPURowState: Equatable {
    let usage: ApplicationProcessorUsage
    let compositing: Double?
    let isReading: Bool
    let snapshot: Date?
}

private enum GPUSort: String, CaseIterable, Identifiable {
    case usage, memory
    var id: Self { self }
    var title: String {
        switch self {
        case .usage: String(localized: "GPU Time")
        case .memory: String(localized: "Video Memory")
        }
    }
}

private struct GPUContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var metrics: MetricsStore
    @ObservedObject var monitor: ProcessorMonitor
    @ObservedObject var compositor: CompositorMonitor
    @ObservedObject var probe: CompositorProbe
    @State private var search = ""
    @State private var sort = GPUSort.usage
    @State private var forceQuitTarget: ApplicationProcessorUsage?
    @State private var showForceQuitConfirmation = false

    private var applications: [ApplicationProcessorUsage] {
        let active = monitor.applications.filter {
            ($0.gpuPercent ?? 0) >= 0.05 || $0.gpuMemory.total >= 1_048_576 || $0.isCompositor
                || compositor.contribution(for: $0.location) != nil
        }
        let ranked = active.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }.sorted { left, right in
            // Apps loading WindowServer go first: that cost is invisible everywhere else.
            let l = compositor.contribution(for: left.location)?.value ?? 0
            let r = compositor.contribution(for: right.location)?.value ?? 0
            if (l >= 5) != (r >= 5) { return l >= 5 }
            if l >= 5, l != r { return l > r }
            switch sort {
            case .usage: return (left.gpuPercent ?? -1, left.gpuMemory.total) > (right.gpuPercent ?? -1, right.gpuMemory.total)
            case .memory: return (left.gpuMemory.total, left.gpuPercent ?? -1) > (right.gpuMemory.total, right.gpuPercent ?? -1)
            }
        }
        return search.isEmpty ? Array(ranked.prefix(20)) : ranked
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "GPU", subtitle: String(localized: "Per-app GPU time, video memory and the window compositing each app causes"))

                CompositorAlertBanner(compositor: compositor, probe: probe)

                ProcessorHistoryCard(kind: .gpu,
                                     value: metrics.snapshot.gpuUsage.map(AppFormatters.percent) ?? "—",
                                     detail: model.systemInfo.graphicsName,
                                     history: metrics.processorHistory)

                statistics
                applicationsPanel
                CompositorPanel(compositor: compositor, probe: probe)
            }
            .padding(28)
            .frame(maxWidth: 1_050, alignment: .leading)
        }
        .task { await monitor.prime() }
        .sectionRefresh(.gpu, busy: model.isRefreshingMetrics || monitor.isRefreshing) {
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

    private var statistics: some View {
        let gpu = metrics.snapshot.gpuStatistics
        let total = monitor.totalGraphicsMemory
        let top = compositor.sortedContributions.first
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 215), spacing: 14)], spacing: 14) {
            MetricCard(
                title: String(localized: "Video Memory"),
                value: AppFormatters.memory(total),
                detail: String(localized: "Used by apps · \(AppFormatters.percent(Double(total) / Double(max(metrics.snapshot.memory.total, 1)))) of memory"),
                symbol: "memorychip",
                tint: AppSection.gpu.tint
            )
            MetricCard(
                title: String(localized: "Driver Memory"),
                value: gpu.map { AppFormatters.memory($0.memoryInUse) } ?? "—",
                detail: gpu.map { String(localized: "\(AppFormatters.memory($0.memoryAllocated)) allocated") } ?? "",
                symbol: "square.stack.3d.up",
                tint: Color(hex: 0x3178F6)
            )
            MetricCard(
                title: "WindowServer",
                value: AppFormatters.decimalPercent(compositor.compositorGPU),
                detail: top.map { String(localized: "Mostly from \($0.app.name) +\(AppFormatters.decimalPercent($0.value))") }
                    ?? String(localized: "Idles around \(AppFormatters.decimalPercent(compositor.floor))"),
                symbol: "macwindow.on.rectangle",
                tint: compositor.compositorGPU - compositor.floor >= 20 ? .critical : Color(hex: 0xF18B43)
            )
            MetricCard(
                title: String(localized: "Renderer"),
                value: gpu.map { AppFormatters.percent($0.renderer) } ?? "—",
                detail: gpu.map { String(localized: "Tiler \(AppFormatters.percent($0.tiler))") } ?? "",
                symbol: "square.grid.3x3",
                tint: Color(hex: 0x13A58D)
            )
        }
    }

    private var applicationsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Top GPU Users").font(.headline)
                Spacer()
                Picker("Sort by", selection: $sort) {
                    ForEach(GPUSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button { Task { await monitor.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Recount")
                .accessibilityLabel("Refresh process usage")
                .disabled(monitor.isRefreshing)
            }
            TextField("Search apps", text: $search)
                .textFieldStyle(.roundedBorder)

            if !monitor.gpuCountersAvailable && !monitor.applications.isEmpty {
                InlineMessage(text: String(localized: "This GPU driver does not expose per-process usage; unavailable values are shown as —."))
            }
            if let message = monitor.privilegedMessage {
                InlineMessage(text: message, isError: true)
            }
            if monitor.applications.isEmpty {
                ProgressView("Measuring process usage…").frame(maxWidth: .infinity, minHeight: 100)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(applications) { usage in
                        EquatableRow(value: GPURowState(usage: usage, compositing: compositor.contribution(for: usage.location)?.value,
                                                        isReading: monitor.isReadingPrivilegedMemory,
                                                        snapshot: monitor.privilegedSnapshotDate)) {
                            row(usage)
                        }
                        .equatable()
                        Divider().padding(.leading, 42)
                    }
                }
            }
            Text("Video memory is the unified memory the GPU driver charges to each app — Metal buffers, textures and window surfaces it owns. Apps that animate through Core Animation are rendered inside WindowServer, so their cost shows as compositing load rather than their own GPU time.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .appPanel()
    }

    private func row(_ usage: ApplicationProcessorUsage) -> some View {
        let contribution = compositor.contribution(for: usage.location)
        return HStack(spacing: 12) {
            if usage.isCompositor {
                // WindowServer has no app icon; the generic executable icon says nothing.
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xF18B43))
                    .frame(width: 30, height: 30)
                    .background(Color(hex: 0xF18B43).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(nsImage: ApplicationIconCache.icon(for: usage.location))
                    .resizable().scaledToFit().frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(usage.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    if usage.isCompositor {
                        StatusPill(text: String(localized: "Compositor"), color: Color(hex: 0xF18B43))
                            .help("WindowServer composites every window. Much of its GPU time is caused by other apps; see Window Compositing below.")
                    }
                }
                HStack(spacing: 4) {
                    Text("\(usage.processCount) processes")
                    if let contribution {
                        Text("·")
                        Text("compositing +\(AppFormatters.decimalPercent(contribution.value))")
                            .foregroundStyle(contribution.value >= 15 ? Color.critical : Color(hex: 0xF18B43))
                            .fontWeight(.semibold)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            ProgressView(value: min(1, (usage.gpuPercent ?? 0) / 100))
                .tint(AppSection.gpu.tint)
                .controlSize(.small).frame(width: 90).accessibilityHidden(true)
            Text(usage.gpuPercent.map(AppFormatters.decimalPercent) ?? "—")
                .font(.system(.body, design: .rounded, weight: .semibold))
                .monospacedDigit().frame(width: 60, alignment: .trailing)
            memoryCell(usage)
                .frame(width: 96, alignment: .trailing)
            if usage.isQuittable {
                Menu {
                    Button("Force Quit…", role: .destructive) {
                        forceQuitTarget = usage
                        showForceQuitConfirmation = true
                    }
                } label: { Text("Quit") } primaryAction: {
                    Task { await monitor.quit(usage, force: false) }
                }
                .frame(width: 88, alignment: .trailing)
            } else { Color.clear.frame(width: 88) }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func memoryCell(_ usage: ApplicationProcessorUsage) -> some View {
        if usage.gpuMemoryNeedsAuthorization && usage.gpuMemory.total == 0 {
            Button("Read…") { Task { await monitor.readPrivilegedGraphicsMemory() } }
                .buttonStyle(.link)
                .disabled(monitor.isReadingPrivilegedMemory)
                .help("System processes such as WindowServer need administrator rights to read once")
        } else {
            HStack(spacing: 3) {
                if usage.gpuMemoryFromSnapshot {
                    Image(systemName: "camera.shutter.button").font(.caption2).foregroundStyle(.secondary)
                        .help(String(localized: "From the administrator snapshot taken at \(monitor.privilegedSnapshotDate?.formatted(date: .omitted, time: .shortened) ?? "—"); not updated live"))
                }
                Text(usage.gpuMemory.total > 0 ? AppFormatters.memory(usage.gpuMemory.total) : "—")
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .monospacedDigit()
            }
            .help(usage.gpuMemory.purgeable > 0 ? String(localized: "Plus \(AppFormatters.memory(usage.gpuMemory.purgeable)) purgeable") : "")
        }
    }
}

/// Names the app behind a WindowServer spike as soon as it is detected.
struct CompositorAlertBanner: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var compositor: CompositorMonitor
    @ObservedObject var probe: CompositorProbe
    @State private var unexplainedDismissedAt: Date?

    var body: some View {
        if let finding = compositor.alert, let contribution = compositor.contributions[finding.app.id] {
            banner(color: contribution.value >= 15 ? .critical : .warning) {
                Image(nsImage: ApplicationIconCache.icon(for: URL(fileURLWithPath: finding.app.path)))
                    .resizable().scaledToFit().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(finding.app.name) is using about \(AppFormatters.decimalPercent(contribution.value)) GPU through WindowServer")
                        .font(.subheadline.weight(.semibold))
                    Text("WindowServer went from \(AppFormatters.decimalPercent(finding.before)) to \(AppFormatters.decimalPercent(finding.after)) after it \(finding.kind.title). Activity Monitor shows this as WindowServer.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let running = NSRunningApplication(processIdentifier: finding.app.pid) {
                    Button("Hide") { running.hide() }
                }
                Button("Verify") { probe.start([finding.app], monitor: compositor) }
                    .disabled(probe.isRunning)
                    .help("Hide the app for a few seconds and measure how much WindowServer drops")
                dismissButton { compositor.alert = nil }
            }
        } else if compositor.unexplained > 0, !recentlyDismissed {
            banner(color: .warning) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 24)).foregroundStyle(Color.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text("WindowServer has \(AppFormatters.decimalPercent(compositor.unexplained)) GPU load from an unknown app")
                        .font(.subheadline.weight(.semibold))
                    Text("Probably an app that was already running. A quick check hides apps one at a time for a few seconds and stops when it finds the source.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Quick Check") {
                    model.selection = .gpu
                    probe.start(CompositorProbe.candidates(rankedBy: compositor), monitor: compositor)
                }
                .disabled(probe.isRunning)
                dismissButton { unexplainedDismissedAt = Date() }
            }
        }
    }

    private var recentlyDismissed: Bool {
        unexplainedDismissedAt.map { Date().timeIntervalSince($0) < 120 } ?? false
    }

    private func banner<Content: View>(color: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(color.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous).stroke(color.opacity(0.3), lineWidth: 1)
            }
    }

    private func dismissButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "xmark") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss message")
            .accessibilityLabel("Dismiss message")
    }
}

/// WindowServer load broken down by the apps causing it, with the quick check and a change log.
private struct CompositorPanel: View {
    @ObservedObject var compositor: CompositorMonitor
    @ObservedObject var probe: CompositorProbe
    /// Refreshed on a timer rather than per render: listing windows is not free.
    @State private var candidates: [CompositorApp] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Window Compositing", systemImage: "macwindow.on.rectangle").font(.headline)
                Spacer()
                StatusPill(text: "WindowServer \(AppFormatters.decimalPercent(compositor.compositorGPU))",
                           color: compositor.compositorGPU - compositor.floor >= 20 ? .critical : Color(hex: 0xF18B43),
                           symbol: "gauge.with.dots.needle.33percent")
            }
            Text("WindowServer draws every window and runs Core Animation's renderer. An app that animates nonstop, redraws too often or uses large translucent windows can show 0% GPU itself while WindowServer climbs. When an app launches, comes forward, hides or quits, any jump in WindowServer is credited to it here.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                breakdown
                quickCheck
            }
            Divider()
            changes
        }
        .appPanel()
        .task {
            while !Task.isCancelled {
                if !probe.isRunning { candidates = CompositorProbe.candidates(rankedBy: compositor) }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: Breakdown

    private var breakdown: some View {
        let parts = compositor.sortedContributions
        let total = max(compositor.compositorGPU, compositor.floor + compositor.totalAttributed + compositor.unexplained, 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Where it comes from").font(.subheadline.weight(.semibold))
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    segment(compositor.floor, of: total, width: proxy.size.width, color: Color.secondary.opacity(0.35))
                    ForEach(parts) { part in
                        segment(part.value, of: total, width: proxy.size.width, color: part.value >= 15 ? .critical : Color(hex: 0xF18B43))
                    }
                    segment(compositor.unexplained, of: total, width: proxy.size.width, color: Color.warning.opacity(0.55))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 12)
            .background(Color.subtleBackground)
            .clipShape(Capsule())

            legend(color: Color.secondary.opacity(0.35), title: String(localized: "Baseline"), value: compositor.floor)
            ForEach(parts) { part in
                HStack(spacing: 8) {
                    Image(nsImage: ApplicationIconCache.icon(for: URL(fileURLWithPath: part.app.path)))
                        .resizable().scaledToFit().frame(width: 18, height: 18)
                    Text(part.app.name).lineLimit(1)
                    Spacer()
                    Text("+\(AppFormatters.decimalPercent(part.value))")
                        .monospacedDigit().fontWeight(.semibold)
                        .foregroundStyle(part.value >= 15 ? Color.critical : Color(hex: 0xF18B43))
                    if let running = NSRunningApplication(processIdentifier: part.app.pid) {
                        Button("Hide") { running.hide() }.controlSize(.small)
                    }
                }
                .font(.subheadline)
                .help(source(part))
            }
            if compositor.unexplained > 0 {
                legend(color: Color.warning.opacity(0.55), title: String(localized: "Unknown source"), value: compositor.unexplained)
            }
            if parts.isEmpty && compositor.unexplained == 0 {
                Text("No app is adding noticeable load right now.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func source(_ part: CompositorAttribution.Contribution) -> String {
        let time = part.date.formatted(date: .omitted, time: .standard)
        switch part.source {
        case .event(let kind): return String(localized: "Measured when it \(kind.title) at \(time)")
        case .probe: return String(localized: "Measured by the quick check at \(time)")
        }
    }

    private func segment(_ value: Double, of total: Double, width: CGFloat, color: Color) -> some View {
        color.frame(width: max(width * value / total, value > 0 ? 2 : 0))
    }

    private func legend(color: Color, title: String, value: Double) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 18, height: 10)
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(AppFormatters.decimalPercent(value)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    // MARK: Quick check

    private var quickCheck: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick check").font(.subheadline.weight(.semibold))
            Text("Hides apps with visible windows one at a time for about three seconds, most suspicious first, and measures how much WindowServer drops. Each app comes back right away; the check stops once one app explains most of the load.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if probe.isRunning {
                    Button("Cancel", role: .cancel) { probe.cancel() }
                } else {
                    Button {
                        probe.start(CompositorProbe.candidates(rankedBy: compositor), monitor: compositor)
                    } label: {
                        Label("Start Quick Check", systemImage: "eye.slash")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(candidates.isEmpty || compositor.compositorPID == nil)
                    Text("Up to \(CompositorProbe.estimatedSeconds(for: candidates.count)) seconds")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            switch probe.phase {
            case .running(let step, let progress):
                ProgressView(value: progress) { Text(step).font(.caption) }
            case .cancelled:
                Text("Cancelled; every window is back.").font(.caption).foregroundStyle(.secondary)
            case .finished(let date):
                results(at: date)
            case .idle:
                if !candidates.isEmpty {
                    Text("Order: \(candidates.map(\.name).joined(separator: " → "))")
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func results(at date: Date) -> some View {
        let scale = max(probe.results.map(\.compositorDrop).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("WindowServer \(AppFormatters.decimalPercent(probe.baseline)) before · \(date.formatted(date: .omitted, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
            if probe.baseline < 5 {
                Text("WindowServer was nearly idle, so the result says little. Run it again while the GPU is busy.")
                    .font(.caption).foregroundStyle(Color.warning)
            }
            ForEach(probe.results) { result in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(nsImage: ApplicationIconCache.icon(for: URL(fileURLWithPath: result.app.path)))
                            .resizable().scaledToFit().frame(width: 18, height: 18)
                        Text(result.app.name).lineLimit(1)
                        Spacer()
                        if result.compositorDrop >= probe.noise {
                            Text("−\(AppFormatters.decimalPercent(result.compositorDrop))").monospacedDigit().fontWeight(.semibold)
                        } else {
                            Text("No clear effect").foregroundStyle(.tertiary)
                        }
                    }
                    .font(.subheadline)
                    if result.compositorDrop >= probe.noise {
                        GeometryReader { proxy in
                            Capsule().fill(Color(hex: 0xF18B43)).frame(width: proxy.size.width * result.compositorDrop / scale)
                        }
                        .frame(height: 4)
                    }
                }
            }
        }
    }

    // MARK: Changes

    private var changes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent changes").font(.subheadline.weight(.semibold))
            if compositor.findings.isEmpty {
                Text("No noticeable jumps yet. Open or switch to the app you suspect.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(compositor.findings.prefix(8)) { finding in
                HStack(spacing: 10) {
                    Text(finding.date, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        .frame(width: 64, alignment: .leading)
                    Text("\(finding.app.name) \(finding.kind.title)").lineLimit(1)
                    if finding.ambiguous {
                        Image(systemName: "arrow.triangle.branch").font(.caption).foregroundStyle(.tertiary)
                            .help("Another app changed at the same time; the step may be shared")
                    }
                    Spacer()
                    Text("\(AppFormatters.decimalPercent(finding.before)) → \(AppFormatters.decimalPercent(finding.after))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text((finding.delta >= 0 ? "+" : "−") + AppFormatters.decimalPercent(abs(finding.delta)))
                        .monospacedDigit().fontWeight(.semibold)
                        .foregroundStyle(finding.delta >= 0 ? Color(hex: 0xF18B43) : Color.healthy)
                        .frame(width: 56, alignment: .trailing)
                }
                .font(.subheadline)
            }
        }
    }
}
