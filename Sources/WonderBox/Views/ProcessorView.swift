import AppKit
import SwiftUI

struct ProcessorView: View {
    @EnvironmentObject private var model: AppModel
    let kind: ProcessorKind

    var body: some View {
        ProcessorContent(kind: kind, monitor: model.processorMonitor)
    }
}

private struct ProcessorContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var metrics: MetricsStore
    let kind: ProcessorKind
    @ObservedObject var monitor: ProcessorMonitor
    @State private var search = ""
    @State private var forceQuitTarget: ApplicationProcessorUsage?
    @State private var showForceQuitConfirmation = false

    private var applications: [ApplicationProcessorUsage] {
        let ranked = monitor.applications.filter {
            // Other users' processes (WindowServer) are only sampled for their GPU counters.
            (kind == .gpu || $0.cpuAvailable) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }.sorted {
            let left = percent($0) ?? -1
            let right = percent($1) ?? -1
            return left == right ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : left > right
        }
        return search.isEmpty ? Array(ranked.prefix(20)) : ranked
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: kind.title, subtitle: String(localized: "Live application usage, including helper processes"))

                ProcessorHistoryCard(kind: kind,
                           value: kind == .cpu ? AppFormatters.percent(metrics.snapshot.cpuUsage)
                               : metrics.snapshot.gpuUsage.map(AppFormatters.percent) ?? "—",
                           detail: kind == .cpu ? model.systemInfo.processorName : model.systemInfo.graphicsName,
                           history: metrics.processorHistory)

                if kind == .cpu {
                    CoreUsagePanel(snapshot: metrics.snapshot, information: model.systemInfo)
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(kind == .cpu ? "Top CPU Users" : "Top GPU Users").font(.headline)
                        Spacer()
                        Text("Refreshes every 3 seconds").font(.caption).foregroundStyle(.secondary)
                        Button { Task { await monitor.refresh() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Recount")
                        .accessibilityLabel("Refresh process usage")
                        .disabled(monitor.isRefreshing)
                    }
                    TextField("Search apps", text: $search)
                        .textFieldStyle(.roundedBorder)

                    if kind == .gpu && !monitor.gpuCountersAvailable {
                        InlineMessage(text: String(localized: "This GPU driver does not expose per-process usage; unavailable values are shown as —."))
                    }
                    if monitor.applications.isEmpty {
                        if monitor.isRefreshing {
                            ProgressView("Measuring process usage…").frame(maxWidth: .infinity, minHeight: 100)
                        } else {
                            Text("Waiting for the next sample…").foregroundStyle(.secondary)
                        }
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(applications) { usage in
                                EquatableRow(value: usage) { row(usage) }.equatable()
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                    Text(kind == .cpu
                         ? "100% means one fully occupied CPU core; multi-core apps can exceed 100%."
                         : "GPU usage is sampled from driver counters. Concurrent GPU contexts can total more than 100%; this is not the overall device utilization.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .appPanel()
            }
            .padding(28)
            .frame(maxWidth: 1_050, alignment: .leading)
        }
        .task { await monitor.prime() }
        .sectionRefresh(kind == .cpu ? .cpu : .gpu, busy: model.isRefreshingMetrics || monitor.isRefreshing) {
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

    private func percent(_ usage: ApplicationProcessorUsage) -> Double? {
        kind == .cpu ? usage.cpuPercent : usage.gpuPercent
    }

    private func row(_ usage: ApplicationProcessorUsage) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: ApplicationIconCache.icon(for: usage.location))
                .resizable().scaledToFit().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(usage.name).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(usage.processCount) processes")
                    if let watts = usage.powerWatts, watts >= 0.05 {
                        Text("·")
                        Text(AppFormatters.watts(watts))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            ProgressView(value: min(1, (percent(usage) ?? 0) / 100))
                .tint(kind == .cpu ? AppSection.cpu.tint : AppSection.gpu.tint)
                .controlSize(.small).frame(width: 110).accessibilityHidden(true)
            Text(percent(usage).map { String(format: "%.1f%%", $0) } ?? "—")
                .font(.system(.body, design: .rounded, weight: .semibold))
                .monospacedDigit().frame(width: 90, alignment: .trailing)
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
    }
}

/// Per-core load split into efficiency and performance clusters, plus the user/system split.
private struct CoreUsagePanel: View {
    let snapshot: MetricSnapshot
    let information: SystemInformation

    private var clusters: [(title: String, cores: ArraySlice<Double>, tint: Color)] {
        let cores = snapshot.cpuCores
        let efficiency = min(information.efficiencyCores, cores.count)
        guard efficiency > 0, information.performanceCores > 0 else {
            return [(String(localized: "Cores"), cores[...], AppSection.cpu.tint)]
        }
        return [
            (String(localized: "Efficiency cores"), cores.prefix(efficiency), Color(hex: 0x13A58D)),
            (String(localized: "Performance cores"), cores.dropFirst(efficiency), AppSection.cpu.tint)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cores").font(.headline)
                Spacer()
                Text("User \(AppFormatters.percent(snapshot.cpuUser)) · System \(AppFormatters.percent(snapshot.cpuSystem))")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                if snapshot.loadAverage.count == 3 {
                    Text("Load \(snapshot.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " "))")
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        .help("Average number of runnable threads over 1, 5 and 15 minutes")
                }
            }
            if snapshot.cpuCores.isEmpty {
                Text("Waiting for usage samples…").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(clusters, id: \.title) { cluster in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(cluster.title).font(.subheadline.weight(.medium))
                            Spacer()
                            Text(AppFormatters.percent(cluster.cores.reduce(0, +) / Double(max(cluster.cores.count, 1))))
                                .font(.subheadline.weight(.semibold)).monospacedDigit()
                        }
                        HStack(alignment: .bottom, spacing: 6) {
                            ForEach(Array(cluster.cores.enumerated()), id: \.offset) { _, load in
                                VStack(spacing: 4) {
                                    ZStack(alignment: .bottom) {
                                        RoundedRectangle(cornerRadius: 3).fill(Color.subtleBackground)
                                        RoundedRectangle(cornerRadius: 3).fill(cluster.tint)
                                            .frame(height: max(2, 44 * load))
                                    }
                                    .frame(height: 44)
                                    Text(AppFormatters.percent(load))
                                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: 46)
                            }
                        }
                    }
                }
            }
        }
        .appPanel()
    }
}
