import SwiftUI

struct PageHeader: View {
    let title: String
    let subtitle: String
    var actionTitle: String?
    var actionSymbol: String = "arrow.clockwise"
    var isWorking = false
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: actionSymbol)
                }
                .disabled(isWorking)
            }
        }
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color
    var progress: Double? = nil
    var history: [Double] = []
    /// Top of the sparkline's scale; nil scales to the largest value (for unbounded rates).
    var historyMaximum: Double? = 1
    var actionSymbol: String? = nil
    var actionHelp: String? = nil
    var actionIsWorking = false
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let actionSymbol, let action {
                    Button(action: action) {
                        if actionIsWorking {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: actionSymbol)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(actionHelp ?? title)
                    .accessibilityLabel(actionHelp ?? title)
                    .disabled(actionIsWorking)
                }
            }

            HStack(alignment: .lastTextBaseline) {
                Text(value)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Spacer(minLength: 8)
                if history.count > 1 {
                    Sparkline(values: history, maximum: historyMaximum)
                        .stroke(tint, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                        .frame(width: 72, height: 28)
                        .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                if let progress {
                    ProgressView(value: min(1, max(0, progress)))
                        .tint(tint)
                        .controlSize(.small)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 112, alignment: .topLeading)
        .appPanel()
    }
}

struct EmptyContentView: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 31, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 54, height: 54)
                .background(Color.subtleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct InlineMessage: View {
    let text: String
    var isError = false
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.warning : Color.healthy)
            Text(text)
                .font(.subheadline)
            Spacer()
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Dismiss message")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background((isError ? Color.warning : Color.healthy).opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A plain polyline, far cheaper to redraw every few seconds than a Swift Charts chart.
struct Sparkline: Shape {
    let values: [Double]
    /// Top of the scale; nil uses the largest value.
    var maximum: Double? = 1

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let top = max(maximum ?? (values.max() ?? 0), .ulpOfOne)
        let step = rect.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let fraction = min(1, max(0, value / top))
            let point = CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.maxY - CGFloat(fraction) * rect.height)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

/// `Sparkline` closed down to the baseline, for a filled area under the line.
struct SparklineArea: Shape {
    let values: [Double]
    var maximum: Double? = 1

    func path(in rect: CGRect) -> Path {
        var path = Sparkline(values: values, maximum: maximum).path(in: rect)
        guard values.count > 1 else { return path }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Rolling history with gridlines and a top-of-scale label, drawn with plain paths so it stays
/// cheap to refresh with every sample.
struct HistoryGraph: View {
    struct Series: Identifiable {
        let title: String
        let values: [Double]
        let color: Color
        var id: String { title }
    }

    let series: [Series]
    /// Formats the top-of-scale label, e.g. a byte rate.
    let format: (Double) -> String
    var minimumTop: Double = 1
    var height: CGFloat = 130

    private var top: Double {
        max(series.flatMap(\.values).max() ?? 0, minimumTop) * 1.1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<3) { _ in
                        Divider().opacity(0.6)
                        Spacer(minLength: 0)
                    }
                    Divider().opacity(0.6)
                }
                ForEach(series) { line in
                    Sparkline(values: line.values, maximum: top)
                        .stroke(line.color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                Text(format(top))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            .frame(height: height)
            .overlay {
                if series.allSatisfy({ $0.values.count < 2 }) {
                    Text("Waiting for samples…").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 14) {
                ForEach(series) { line in
                    HStack(spacing: 6) {
                        Capsule().fill(line.color).frame(width: 14, height: 3)
                        Text(line.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("Last 3 minutes").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(series.map(\.title).joined(separator: ", "))
    }
}

/// Quit / Force Quit control shared by the per-app lists.
struct QuitMenu: View {
    let quit: () -> Void
    let forceQuit: () -> Void

    var body: some View {
        Menu {
            Button("Force Quit…", role: .destructive, action: forceQuit)
        } label: { Text("Quit") } primaryAction: {
            quit()
        }
        .frame(width: 88, alignment: .trailing)
    }
}

/// Re-renders its content only when `value` changes. List rows hold native controls (menus,
/// progress bars) that are costly to update; without this every published sample rebuilt every
/// row, even rows whose figures did not move.
struct EquatableRow<Value: Equatable, Content: View>: View, Equatable {
    let value: Value
    @ViewBuilder let content: () -> Content

    var body: some View { content() }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }
}
