import Foundation

/// An app as far as WindowServer attribution is concerned. `path` matches
/// `ApplicationProcessorUsage.location.path`, so the GPU list can show each app's share.
struct CompositorApp: Hashable, Sendable {
    let path: String
    let name: String
    /// Main process, used to hide and unhide the app.
    let pid: pid_t
    var id: String { path }
}

/// Attributes WindowServer GPU load to apps.
///
/// WindowServer composites every window and hosts Core Animation's render server, so an app that
/// animates constantly, redraws too often or covers the screen in translucent layers can show 0%
/// GPU itself while WindowServer climbs. No counter splits that cost by app. Instead, every app
/// launch, switch, hide or quit is a natural experiment: when WindowServer steps up or down right
/// after one app's event, the step is that app's share.
///
/// Times are seconds on any monotonic clock; GPU values are percent of one GPU (0–100).
struct CompositorAttribution {
    enum EventKind: Sendable {
        case launched, activated, unhidden, windowOpened
        case deactivated, hidden, terminated, windowClosed

        var turnsOn: Bool {
            switch self {
            case .launched, .activated, .unhidden, .windowOpened: true
            case .deactivated, .hidden, .terminated, .windowClosed: false
            }
        }

        var title: String {
            switch self {
            case .launched: String(localized: "launched")
            case .activated: String(localized: "came to the front")
            case .unhidden: String(localized: "was unhidden")
            case .windowOpened: String(localized: "opened a window")
            case .deactivated: String(localized: "went to the background")
            case .hidden: String(localized: "was hidden")
            case .terminated: String(localized: "quit")
            case .windowClosed: String(localized: "closed its windows")
            }
        }
    }

    enum Source: Sendable, Equatable {
        case event(EventKind)
        case probe
    }

    /// An app's current share of WindowServer GPU, in percentage points.
    struct Contribution: Identifiable, Sendable {
        let app: CompositorApp
        var value: Double
        let date: Date
        let source: Source
        var id: String { app.id }
    }

    /// A WindowServer step that followed one app's event.
    struct Finding: Identifiable, Sendable {
        let id = UUID()
        let date: Date
        let app: CompositorApp
        let kind: EventKind
        let before: Double
        let after: Double
        /// Another app had an event in the same window, so the step may be shared.
        let ambiguous: Bool
        var delta: Double { after - before }
    }

    private struct Event {
        let time: Double
        let app: CompositorApp
        let kind: EventKind
        /// For activations: the app that went to the background at the same moment.
        let previous: CompositorApp?
        /// Second look once a ramping load has settled.
        var refine = false

        var after: ClosedRange<Double> {
            if refine { return 7...10 }
            return kind == .launched ? 2...6 : 1...4
        }
        var dueAt: Double { time + after.upperBound }
    }

    private struct Point {
        let time: Double
        let value: Double
    }

    /// Steps below this many percentage points, or three times the baseline's spread, are noise.
    static let minimumStep = 3.0
    /// WindowServer idles at a few percent; a long-running offender must not raise the idle estimate.
    static let floorCeiling = 10.0

    /// Our own app is the observer and never the culprit.
    var ignoredPath: String?
    private(set) var current: Double = 0
    private(set) var floor: Double = 0
    private(set) var unexplained: Double = 0
    private(set) var contributions: [String: Contribution] = [:]

    private var history: [Point] = []
    private var lows: [Point] = []
    private var pending: [Event] = []
    private var lastEvent: [String: Double] = [:]
    private var overCountSince: Double?
    private var unexplainedSince: Double?
    private let historySeconds = 600.0

    var totalAttributed: Double { contributions.values.reduce(0) { $0 + $1.value } }

    init(ignoredPath: String? = nil) {
        self.ignoredPath = ignoredPath
    }

    /// Adds one WindowServer reading and returns any steps attributed by it.
    mutating func record(_ value: Double, at time: Double, date: Date = Date()) -> [Finding] {
        history.append(Point(time: time, value: value))
        history.removeAll { $0.time < time - historySeconds }
        lows.removeAll { $0.time < time - historySeconds }
        current = Self.median(history.suffix(4).map(\.value))
        let findings = evaluateDueEvents(now: time, date: date)
        reconcile(now: time)
        return findings
    }

    mutating func enqueue(_ app: CompositorApp, _ kind: EventKind, previous: CompositorApp? = nil, at time: Double) {
        // A launch fires activate and window-open right after it; keep only the first.
        if let last = lastEvent[app.id], time - last < 1.5, kind != .terminated { return }
        lastEvent[app.id] = time
        lastEvent = lastEvent.filter { time - $0.value < 30 }
        if kind == .terminated { contributions[app.id] = nil }
        pending.append(Event(time: time, app: app, kind: kind, previous: previous))
    }

    /// Drops queued events, e.g. after the probe hid and unhid apps itself.
    mutating func discardPendingEvents() {
        pending.removeAll()
    }

    /// Hiding an app removed `drop` points of WindowServer load: that is its share.
    mutating func recordProbe(app: CompositorApp, drop: Double, noise: Double, baseline: Double, at time: Double, date: Date = Date()) {
        if drop >= noise {
            contributions[app.id] = Contribution(app: app, value: drop, date: date, source: .probe)
            lows.append(Point(time: time, value: max(baseline - drop, 0)))
        } else {
            contributions[app.id] = nil
        }
    }

    /// Higher is more suspicious: apps with recent events first, then known contributors.
    func suspicion(of path: String, now: Double) -> Double {
        var score = contributions[path]?.value ?? 0
        if let last = lastEvent[path] { score += max(0, 1_000 - (now - last)) }
        return score
    }

    private mutating func evaluateDueEvents(now: Double, date: Date) -> [Finding] {
        let due = pending.filter { $0.dueAt <= now }
        guard !due.isEmpty else { return [] }
        pending.removeAll { $0.dueAt <= now }

        var findings: [Finding] = []
        for event in due {
            let before = values(in: (event.time - 5)...(event.time - 0.2))
            let after = values(in: (event.time + event.after.lowerBound)...(event.time + event.after.upperBound))
            guard before.count >= 3, after.count >= 3 else { continue }
            let b = Self.median(before), a = Self.median(after)
            let noise = max(Self.minimumStep, 3 * Self.medianDeviation(before))
            let delta = a - b
            let ambiguous = (pending + due).contains { $0.app.id != event.app.id && !$0.refine && abs($0.time - event.time) < 4 }
            if a < b - noise { lows.append(Point(time: now, value: a)) }

            if event.refine {
                // Loads keep ramping for seconds as animations spin up. Unless another app acted
                // meanwhile, the extra rise belongs to the same app.
                let interrupted = lastEvent.contains { $0.key != event.app.id && $0.key != ignoredPath && $0.value > event.time }
                if !interrupted, var contribution = contributions[event.app.id], delta > contribution.value {
                    contribution.value = delta
                    contributions[event.app.id] = contribution
                }
                continue
            }

            if event.kind.turnsOn {
                if delta >= noise, event.app.id != ignoredPath {
                    let total = (contributions[event.app.id]?.value ?? 0) + delta
                    contributions[event.app.id] = Contribution(app: event.app, value: total, date: date, source: .event(event.kind))
                    findings.append(Finding(date: date, app: event.app, kind: event.kind, before: b, after: a, ambiguous: ambiguous))
                    var followUp = event
                    followUp.refine = true
                    pending.append(followUp)
                } else if delta <= -noise, let previous = event.previous, previous.id != ignoredPath {
                    // Switching away from `previous` calmed WindowServer down: it was the one.
                    if var contribution = contributions[previous.id] {
                        contribution.value += delta
                        // What is left is within noise: the drop accounted for all of it.
                        contributions[previous.id] = contribution.value >= noise ? contribution : nil
                    }
                    findings.append(Finding(date: date, app: previous, kind: .deactivated, before: b, after: a, ambiguous: ambiguous))
                }
            } else {
                if delta <= -noise {
                    findings.append(Finding(date: date, app: event.app, kind: event.kind, before: b, after: a, ambiguous: ambiguous))
                }
                // Hidden, closed or quit: whatever it was costing is gone now.
                contributions[event.app.id] = nil
            }
        }
        return findings
    }

    /// Keeps contributions honest. If WindowServer calms down without any event (the app stopped
    /// animating by itself) they shrink; load that nothing explains is surfaced as unexplained.
    private mutating func reconcile(now: Double) {
        let observedLow = lows.map(\.value).min() ?? .infinity
        floor = min(Self.percentile(history.map(\.value), 0.1), observedLow, Self.floorCeiling)
        let excess = max(current - floor, 0)
        let sum = totalAttributed

        if sum > excess + max(3, sum * 0.25) {
            overCountSince = overCountSince ?? now
            if now - (overCountSince ?? now) >= 6 {
                let scale = sum > 0 ? excess / sum : 0
                for (id, var contribution) in contributions {
                    contribution.value *= scale
                    contributions[id] = contribution.value >= 1 ? contribution : nil
                }
                overCountSince = nil
            }
        } else {
            overCountSince = nil
        }

        let missing = excess - totalAttributed
        if missing >= 8 {
            unexplainedSince = unexplainedSince ?? now
            unexplained = now - (unexplainedSince ?? now) >= 3 ? missing : 0
        } else {
            unexplainedSince = nil
            unexplained = 0
        }
    }

    private func values(in range: ClosedRange<Double>) -> [Double] {
        history.filter { range.contains($0.time) }.map(\.value)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static func medianDeviation(_ values: [Double]) -> Double {
        let center = median(values)
        return median(values.map { abs($0 - center) })
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(Int(Double(sorted.count - 1) * p), sorted.count - 1)]
    }
}
