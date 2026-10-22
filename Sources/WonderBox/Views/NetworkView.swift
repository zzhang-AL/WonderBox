import AppKit
import SwiftUI

struct NetworkView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NetworkContent(activity: model.networkActivity)
    }
}

private struct NetworkContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var metrics: MetricsStore
    @ObservedObject var activity: NetworkActivityMonitor
    @State private var search = ""
    @State private var forceQuitTarget: ApplicationNetworkUsage?
    @State private var showForceQuitConfirmation = false

    private static let download = Color(hex: 0x1E9BB8)
    private static let upload = Color(hex: 0xF18B43)

    private var snapshot: MetricSnapshot { metrics.snapshot }

    private var applications: [ApplicationNetworkUsage] {
        let ranked = activity.applications
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted {
                ($0.downPerSecond + $0.upPerSecond, $0.received + $0.sent) > ($1.downPerSecond + $1.upPerSecond, $1.received + $1.sent)
            }
        return search.isEmpty ? Array(ranked.prefix(25)) : ranked
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: String(localized: "Network"), subtitle: String(localized: "Live traffic by interface and by app"))

                historyPanel

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 215), spacing: 14)], spacing: 14) {
                    MetricCard(title: String(localized: "Received"), value: AppFormatters.bytes(snapshot.networkReceivedTotal),
                               detail: String(localized: "Since startup, Wi-Fi and Ethernet"),
                               symbol: "arrow.down.circle", tint: Self.download)
                    MetricCard(title: String(localized: "Sent"), value: AppFormatters.bytes(snapshot.networkSentTotal),
                               detail: String(localized: "Since startup, Wi-Fi and Ethernet"),
                               symbol: "arrow.up.circle", tint: Self.upload)
                    if let tunnel = snapshot.networkInterfaces.first(where: \.isTunnel) {
                        MetricCard(title: String(localized: "VPN Tunnel"),
                                   value: AppFormatters.rate(tunnel.downPerSecond + tunnel.upPerSecond),
                                   detail: String(localized: "\(tunnel.name) · also counted on Wi-Fi or Ethernet"),
                                   symbol: "lock.shield", tint: Color(hex: 0x7A67D8))
                    }
                }

                interfacesPanel
                applicationsPanel
            }
            .padding(28)
            .frame(maxWidth: 1_050, alignment: .leading)
        }
        // nettop runs only while this page is on screen.
        .onAppear { activity.acquire() }
        .onDisappear { activity.release() }
        .sectionRefresh(.network, busy: model.isRefreshingMetrics) { await model.refreshMetrics() }
        .confirmationDialog("Force quit this application?", isPresented: $showForceQuitConfirmation, titleVisibility: .visible) {
            if let target = forceQuitTarget {
                Button("Force Quit", role: .destructive) { activity.quit(target, force: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved changes may be lost.")
        }
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                rate(String(localized: "Download"), snapshot.networkDownPerSecond, color: Self.download, symbol: "arrow.down")
                rate(String(localized: "Upload"), snapshot.networkUpPerSecond, color: Self.upload, symbol: "arrow.up")
                Spacer()
            }
            HistoryGraph(series: [
                .init(title: String(localized: "Download"), values: metrics.downloadHistory, color: Self.download),
                .init(title: String(localized: "Upload"), values: metrics.uploadHistory, color: Self.upload)
            ], format: { AppFormatters.rate(UInt64($0)) }, minimumTop: 64 * 1_024)
        }
        .appPanel()
    }

    private func rate(_ title: String, _ value: UInt64, color: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.medium)).foregroundStyle(color)
            Text(AppFormatters.rate(value)).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
        }
    }

    private var interfacesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Interfaces").font(.headline)
            if snapshot.networkInterfaces.isEmpty {
                Text("No active interfaces").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(snapshot.networkInterfaces) { interface in
                HStack(spacing: 12) {
                    Image(systemName: interface.isTunnel ? "lock.shield" : "network")
                        .foregroundStyle(interface.isTunnel ? Color.secondary : Self.download)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(interface.name).font(.subheadline.weight(.medium).monospaced())
                        Text(interface.kind).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(AppFormatters.rate(interface.downPerSecond), systemImage: "arrow.down")
                        .frame(width: 120, alignment: .trailing)
                    Label(AppFormatters.rate(interface.upPerSecond), systemImage: "arrow.up")
                        .frame(width: 120, alignment: .trailing)
                    Text("\(AppFormatters.bytes(interface.received)) / \(AppFormatters.bytes(interface.sent))")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .trailing)
                }
                .font(.subheadline.monospacedDigit())
            }
            Text("Totals count physical interfaces only. Traffic through a VPN or proxy tunnel also crosses Wi-Fi or Ethernet, so tunnels are listed but not added twice.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .appPanel()
    }

    private var applicationsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Top Network Users").font(.headline)
                Spacer()
                Text("Totals since this page opened").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Search apps", text: $search).textFieldStyle(.roundedBorder)

            if activity.isUnavailable {
                InlineMessage(text: String(localized: "Per-app traffic is unavailable because nettop could not be started."), isError: true)
            } else if activity.applications.isEmpty {
                ProgressView("Measuring app traffic…").frame(maxWidth: .infinity, minHeight: 100)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(applications) { usage in
                        EquatableRow(value: usage) { row(usage) }.equatable()
                        Divider().padding(.leading, 42)
                    }
                }
            }
            Text("Per-app traffic comes from nettop and includes system services. Helper processes are counted with their app.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .appPanel()
    }

    private func row(_ usage: ApplicationNetworkUsage) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: ApplicationIconCache.icon(for: usage.location))
                .resizable().scaledToFit().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(usage.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(AppFormatters.bytes(usage.received)) received · \(AppFormatters.bytes(usage.sent)) sent")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Label(AppFormatters.rate(usage.downPerSecond), systemImage: "arrow.down")
                .foregroundStyle(usage.downPerSecond > 0 ? Self.download : Color.secondary)
                .frame(width: 110, alignment: .trailing)
            Label(AppFormatters.rate(usage.upPerSecond), systemImage: "arrow.up")
                .foregroundStyle(usage.upPerSecond > 0 ? Self.upload : Color.secondary)
                .frame(width: 110, alignment: .trailing)
            if usage.isQuittable {
                QuitMenu(quit: { activity.quit(usage, force: false) },
                         forceQuit: { forceQuitTarget = usage; showForceQuitConfirmation = true })
            } else { Color.clear.frame(width: 88) }
        }
        .font(.subheadline.monospacedDigit())
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}
