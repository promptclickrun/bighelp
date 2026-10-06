import SwiftUI
import WidgetKit

/// What the Workflows widget shows: the runs going on now on the computer in
/// use, each with its step and what that step is doing. The app writes it while
/// it's open; the widget only reads it, and says how old it is once it's stale.
struct BighelpWorkflowsSnapshot: Codable, Equatable, Sendable {
    /// Where a run is, in the words the app uses.
    enum Phase: String, Codable, Sendable {
        case working, waitingForYou, needsAttention, paused

        var title: String {
            switch self {
            case .working: "Running"
            case .waitingForYou: "Waiting for you"
            case .needsAttention: "Needs attention"
            case .paused: "Paused"
            }
        }

        var symbol: String {
            switch self {
            case .working: "arrow.triangle.2.circlepath"
            case .waitingForYou: "person.crop.circle.badge.clock"
            case .needsAttention: "exclamationmark.triangle.fill"
            case .paused: "pause.circle.fill"
            }
        }

        var tintHex: String {
            switch self {
            case .working: "3E8EDB"
            case .waitingForYou: "E5624F"
            case .needsAttention: "E0A030"
            case .paused: "8E8781"
            }
        }

        var tint: Color { Color(widgetHex: tintHex) }
    }

    struct Run: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let number: Int
        let phase: Phase
        /// The step running now, as the workflow names it.
        var step: String?
        /// What that step is doing ("Checking", "Running") or what it needs.
        var detail: String?
        let stepsDone: Int
        let stepCount: Int
        var startedAt: Date?

        /// The step in progress, counting from one; nil when the host didn't say.
        var stepNumber: Int? {
            guard stepCount > 0 else { return nil }
            return min(stepsDone + 1, stepCount)
        }

        var progress: Double { stepCount > 0 ? min(1, Double(stepsDone) / Double(stepCount)) : 0 }

        /// "Step 2 of 5", or nil when the host didn't count steps.
        var stepLine: String? { stepNumber.map { "Step \($0) of \(stepCount)" } }
    }

    var runs: [Run] = []
    /// Workflows could be read on this computer at the last update.
    var isAvailable = false
    var generatedAt: Date = .distantPast

    static let empty = BighelpWorkflowsSnapshot()
    static let kind = "BighelpWorkflowsWidget"
    static let fileName = "bighelp-workflows-widget-v1.json"
    static let maximumRuns = 8
    /// After this the widget says when it was last updated.
    static let staleAfter: TimeInterval = 10 * 60

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BighelpWidgetSnapshot.appGroup)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func load() -> BighelpWorkflowsSnapshot {
        guard let url = fileURL, let data = try? Data(contentsOf: url), data.count <= 65_536,
              let value = try? JSONDecoder.bighelpWidget.decode(Self.self, from: data) else { return .empty }
        return value
    }

    func save() throws {
        guard let url = Self.fileURL else { return }
        try JSONEncoder.bighelpWidget.encode(self)
            .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func isStale(at date: Date) -> Bool { date.timeIntervalSince(generatedAt) > Self.staleAfter }

    /// "loopdy://workflow-run/<id>" opens one run; without an ID, the Workflows home.
    static func url(run: String? = nil) -> URL {
        guard let run else { return URL(string: "loopdy://workflows")! }
        var components = URLComponents()
        components.scheme = "loopdy"; components.host = "workflow-run"; components.path = "/" + run
        return components.url ?? URL(string: "loopdy://workflows")!
    }
}

// MARK: - Timeline

struct WorkflowsWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: BighelpWorkflowsSnapshot
    let palette: BighelpWidgetSnapshot

    static let preview = WorkflowsWidgetEntry(
        date: .now,
        snapshot: BighelpWorkflowsSnapshot(
            runs: [
                .init(id: "a", name: "Weekly newsletter", number: 12, phase: .working, step: "Draft the issue",
                      detail: "Running", stepsDone: 1, stepCount: 4, startedAt: .now.addingTimeInterval(-540)),
                .init(id: "b", name: "Launch checklist", number: 3, phase: .waitingForYou, step: "Approve the budget",
                      detail: "Waiting for your OK", stepsDone: 2, stepCount: 3, startedAt: .now.addingTimeInterval(-3_600)),
            ],
            isAvailable: true, generatedAt: .now),
        palette: .empty)
}

struct WorkflowsWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WorkflowsWidgetEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (WorkflowsWidgetEntry) -> Void) {
        let entry = entry()
        completion(context.isPreview && entry.snapshot.runs.isEmpty ? .preview : entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WorkflowsWidgetEntry>) -> Void) {
        let entry = entry()
        // The app reloads this as runs move; the second entry marks it stale if the app stops.
        var entries = [entry]
        if !entry.snapshot.runs.isEmpty {
            let stale = entry.snapshot.generatedAt.addingTimeInterval(BighelpWorkflowsSnapshot.staleAfter + 1)
            if stale > entry.date {
                entries.append(WorkflowsWidgetEntry(date: stale, snapshot: entry.snapshot, palette: entry.palette))
            }
        }
        completion(Timeline(entries: entries, policy: .after(.now.addingTimeInterval(30 * 60))))
    }

    private func entry() -> WorkflowsWidgetEntry {
        WorkflowsWidgetEntry(date: .now, snapshot: BighelpWorkflowsSnapshot.load(), palette: BighelpWidgetSnapshot.load())
    }
}

// MARK: - Views

struct BighelpWorkflowsWidgetView: View {
    let entry: WorkflowsWidgetEntry
    /// Draws one size outside WidgetKit, for the app's own pictures of the widget.
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.bighelpWidgetColors) private var colors

    private var family: WidgetFamily { familyOverride ?? widgetFamily }

    private var runs: [BighelpWorkflowsSnapshot.Run] { entry.snapshot.runs }

    var body: some View {
        Group {
            if family.isAccessory {
                accessory
            } else {
                VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 10) {
                    header
                    if runs.isEmpty {
                        Spacer(minLength: 0)
                        Text(emptyText).font(.caption).foregroundStyle(colors.secondary)
                        Spacer(minLength: 0)
                    } else if family == .systemSmall {
                        small(runs[0])
                    } else {
                        list
                    }
                    if !runs.isEmpty, entry.snapshot.isStale(at: entry.date) {
                        Text("As of \(entry.snapshot.generatedAt, style: .time)")
                            .font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .widgetURL(BighelpWorkflowsSnapshot.url(run: family == .systemSmall || family.isAccessory ? runs.first?.id : nil))
    }

    private var emptyText: String {
        if entry.snapshot.generatedAt == .distantPast { return "Open bighelp to see your running workflows here." }
        if !entry.snapshot.isAvailable { return "Workflows aren't set up on this computer." }
        return "No workflows running right now."
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "flowchart")
                .font(.caption.weight(.bold))
                .foregroundStyle(colors.accent)
            Text("Workflows").font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
            if !runs.isEmpty {
                Text("\(runs.count)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(colors.secondary)
                    .accessibilityLabel(runs.count == 1 ? "1 running" : "\(runs.count) running")
            }
        }
    }

    private func small(_ run: BighelpWorkflowsSnapshot.Run) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(run.name).font(.subheadline.weight(.semibold)).lineLimit(2)
            if let line = run.stepLine {
                Text(line).font(.caption2.weight(.semibold)).foregroundStyle(run.phase.tint)
            }
            if let step = run.step {
                Text(step).font(.caption).foregroundStyle(colors.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            progress(run)
            HStack(spacing: 4) {
                Image(systemName: run.phase.symbol).font(.caption2).foregroundStyle(run.phase.tint)
                Text(run.detail ?? run.phase.title).font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
                if runs.count > 1 {
                    Spacer(minLength: 0)
                    Text("+\(runs.count - 1)").font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(colors.secondary)
                }
            }
        }
    }

    private var list: some View {
        let limit = family == .systemMedium ? 2 : 5
        return VStack(alignment: .leading, spacing: family == .systemMedium ? 8 : 12) {
            ForEach(runs.prefix(limit)) { run in
                Link(destination: BighelpWorkflowsSnapshot.url(run: run.id)) { row(run) }
            }
            if runs.count > limit {
                Text("\(runs.count - limit) more running")
                    .font(.caption2).foregroundStyle(colors.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ run: BighelpWorkflowsSnapshot.Run) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: run.phase.symbol)
                    .font(.caption.weight(.semibold)).foregroundStyle(run.phase.tint).widgetAccentable()
                Text(run.name).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let started = run.startedAt {
                    Text(started, style: .time)
                        .font(.caption2.monospacedDigit()).foregroundStyle(colors.secondary).lineLimit(1)
                        .accessibilityLabel(Text("Started \(started, style: .time)"))
                }
            }
            Text(detailLine(run)).font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
            progress(run)
        }
    }

    /// "Step 2 of 5 · Draft the issue · Running": where it is and what it's doing.
    private func detailLine(_ run: BighelpWorkflowsSnapshot.Run) -> String {
        [run.stepLine, run.step, run.detail ?? run.phase.title].compactMap { $0 }.joined(separator: " · ")
    }

    private func progress(_ run: BighelpWorkflowsSnapshot.Run) -> some View {
        UsageWidgetBar(fraction: run.progress, tint: run.phase.tint)
    }

    @ViewBuilder private var accessory: some View {
        #if os(iOS)
        if family == .accessoryCircular {
            if let run = runs.first, let number = run.stepNumber {
                Gauge(value: run.progress) {
                    Image(systemName: "flowchart")
                } currentValueLabel: {
                    Text("\(number)/\(run.stepCount)").font(.caption.monospacedDigit())
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .widgetAccentable()
            } else {
                Image(systemName: "flowchart").font(.title2).widgetAccentable()
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(runs.first?.name ?? "No workflows running").font(.headline).lineLimit(1).widgetAccentable()
                if let run = runs.first {
                    Text([run.stepLine, run.step].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).lineLimit(1)
                    ProgressView(value: run.progress)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #else
        EmptyView()
        #endif
    }
}

struct BighelpWorkflowsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: BighelpWorkflowsSnapshot.kind, provider: WorkflowsWidgetProvider()) { entry in
            BighelpWidgetScaffold(snapshot: entry.palette) {
                BighelpWorkflowsWidgetView(entry: entry)
            }
        }
        .configurationDisplayName("Workflows")
        .description("Workflows running now: the step each one is on and what it's doing.")
        .supportedFamilies(Self.families)
        .bighelpWidgetPlacement()
    }

    private static var families: [WidgetFamily] {
        #if os(visionOS)
        [.systemSmall, .systemMedium, .systemLarge]
        #else
        [.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular]
        #endif
    }
}
