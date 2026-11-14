import SwiftUI

/// One Activities item in full, opened from the Dashboard: a subagent's steps on a timeline (time, a dot
/// on a rail, what it did) and its answer; a command and its output; a routine run's status and output.
/// It reads again every few seconds while the work runs.
struct DashboardActivityDetailView: View {
    @State private var model: AgentTodayDetailModel
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    init(item: AgentTodayItem, agentID: String, client: (any AgentBoardClient)?) {
        _model = State(initialValue: AgentTodayDetailModel(item: item, agentID: agentID, client: client))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space20) {
                    DashboardActivityHeader(item: model.item)
                    BighelpDeferredSection { content }
                }
                .padding(BighelpTokens.space24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .bighelpToolbarText()
                        .accessibilityIdentifier("dashboard.activity.done")
                }
            }
        }
        .task { await model.follow() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            note(String(localized: "Loading…"))
        case .unsupported:
            note(String(localized: "Update the Bighelp plugin on this computer to see what this did."))
        case .gone:
            note(String(localized: "The computer no longer has a record of this."))
        case .failed:
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                note(String(localized: "This didn't load."))
                Button(String(localized: "Try again")) { Task { await model.refresh() } }
                    .font(.bighelp(.body, weight: .semibold))
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityIdentifier("dashboard.activity.retry")
            }
        case .loaded(let detail):
            switch detail.body {
            case .subagent(let subagent): DashboardSubagentReadout(item: detail.item, subagent: subagent)
            case .command(let command): DashboardCommandReadout(item: detail.item, command: command)
            case .scheduled(let run): DashboardRoutineReadout(item: detail.item, run: run)
            case .none: note(detail.item.detail ?? String(localized: "The computer kept nothing more about this."))
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.bighelp(.body))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("dashboard.activity.note")
    }
}

/// What it is and how it's going: "Subagent · Running · 3 min", "Command · Done at 4:46 PM".
private struct DashboardActivityHeader: View {
    let item: AgentTodayItem
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            DashboardActivityIcon(item: item, size: 48)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(item.title)
                    .font(item.kind == .command ? .bighelp(.title3, weight: .bold).monospaced()
                                                : .bighelp(.title3, weight: .bold))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(Self.status(item, now: context.date))
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(item.state == .failed ? theme.danger : theme.secondaryText)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    static func status(_ item: AgentTodayItem, now: Date) -> String {
        let kind = switch item.kind {
        case .subagent: String(localized: "Subagent")
        case .command: String(localized: "Command")
        case .scheduled: String(localized: "Routine")
        }
        let ended = (item.endedAt ?? item.startedAt)?.formatted(date: .omitted, time: .shortened)
        let state: String = switch item.state {
        case .running: DashboardActivityTime.running(since: item.startedAt, now: now)
        case .done: ended.map { String(localized: "Done at \($0)") } ?? String(localized: "Done")
        case .failed: ended.map { String(localized: "Didn't finish · \($0)") } ?? String(localized: "Didn't finish")
        case .stopped: ended.map { String(localized: "Stopped at \($0)") } ?? String(localized: "Stopped")
        case .unknown: String(localized: "Didn't report back")
        }
        return "\(kind) · \(state)"
    }
}

/// The tile Activities rows and the read-out share.
struct DashboardActivityIcon: View {
    let item: AgentTodayItem
    let size: CGFloat
    @BighelpThemeReader private var theme

    init(item: AgentTodayItem, size: CGFloat = 36) {
        self.item = item
        self.size = size
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.bighelp(size > 40 ? .title3 : .subheadline, weight: .semibold))
            .foregroundStyle(item.state == .running ? theme.actionForeground
                             : item.state == .failed ? theme.danger : theme.primaryText)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(item.state == .running ? theme.action : theme.secondaryText.opacity(0.12)))
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch item.state {
        case .running:
            switch item.kind {
            case .subagent: "person.2"
            case .command: "terminal"
            case .scheduled: "calendar.badge.clock"
            }
        case .done: "checkmark.circle"
        case .failed: "xmark.circle"
        case .stopped: "stop.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

enum DashboardActivityTime {
    /// "Running · 3 min", or "Running · just started" in its first minute.
    static func running(since started: Date?, now: Date) -> String {
        guard let started else { return String(localized: "Running") }
        let seconds = max(0, now.timeIntervalSince(started))
        guard seconds >= 60 else { return String(localized: "Running · just started") }
        let length = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return String(localized: "Running · \(length)")
    }
}

// MARK: Subagent

/// The subagent's task, what it did newest first (how it's going on top), then its answer.
private struct DashboardSubagentReadout: View {
    let item: AgentTodayItem
    let subagent: AgentTodayDetail.Subagent
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space20) {
            if let goal = subagent.goal, goal != item.title {
                DashboardReadoutSection(title: String(localized: "Task")) {
                    Text(goal)
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            DashboardReadoutSection(title: String(localized: "Steps")) {
                VStack(alignment: .leading, spacing: 0) {
                    if subagent.stepsTruncated {
                        Text("Showing the newest \(subagent.steps.count) steps.")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.bottom, BighelpTokens.space8)
                    }
                    // Newest first, so a running step shows on top as it happens; the rail ends at the first step.
                    ending(isLast: subagent.steps.isEmpty)
                    let steps = Array(subagent.steps.reversed())
                    ForEach(steps) { step in
                        DashboardTimelineRow(at: step.at, dot: dot(step.state), isLast: step.id == steps.last?.id) {
                            DashboardStepText(step: step)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("dashboard.activity.steps")
            }
            if let summary = subagent.summary {
                DashboardReadoutSection(title: item.state == .running ? String(localized: "So far")
                                                                     : String(localized: "Answer")) {
                    MarkdownMessageView(document: MarkdownDocument(summary))
                        .foregroundStyle(theme.primaryText)
                        .tint(theme.action)
                        .textSelection(.enabled)
                        .padding(BighelpTokens.space16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius16,
                                                                         style: .continuous))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("dashboard.activity.answer")
                }
            }
            if let model = subagent.model {
                Text("Model: \(model)")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.tertiaryText)
            }
        }
    }

    /// The timeline's first row: how it ended, or that it's still working.
    @ViewBuilder
    private func ending(isLast: Bool) -> some View {
        switch item.state {
        case .running:
            DashboardTimelineRow(at: nil, dot: .running, isLast: isLast) {
                Text(subagent.steps.isEmpty ? "Starting…" : "Working…")
                    .font(.bighelp(.body, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
            }
        case .done:
            DashboardTimelineRow(at: item.endedAt, dot: .done, isLast: isLast) {
                Text("Finished")
                    .font(.bighelp(.body, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
            }
        case .failed, .stopped, .unknown:
            DashboardTimelineRow(at: item.endedAt, dot: .failed, isLast: isLast) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.state == .stopped ? "Stopped" : "Didn't finish")
                        .font(.bighelp(.body, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                    if let error = subagent.error ?? item.detail {
                        Text(error)
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func dot(_ state: AgentTodayDetail.Step.State?) -> DashboardTimelineDot {
        switch state {
        case .running: .running
        case .failed: .failed
        case .done, nil: .done
        }
    }
}

/// One step in plain words: "Searched the web" over "kyoto station ryokan"; a note it wrote; its thinking.
struct DashboardStepText: View {
    let step: AgentTodayDetail.Step
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch step.kind {
            case .tool:
                let phrase = ChatToolPhrase.phrase(forTool: step.tool, arguments: nil)
                Text(step.state == .running ? phrase.live : phrase.past)
                    .font(.bighelp(.body, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                if let preview = step.preview {
                    Text(preview)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(3)
                }
                if step.state == .failed {
                    Text("Didn't work")
                        .font(.bighelp(.footnote, weight: .medium))
                        .foregroundStyle(theme.danger)
                }
            case .message:
                Text("Wrote")
                    .font(.bighelp(.body, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Text(step.preview ?? "")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(4)
            case .thinking:
                Text("Thought")
                    .font(.bighelp(.body, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Text(step.preview ?? "")
                    .font(.bighelp(.subheadline).italic())
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(4)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// A timeline dot: grey for done, the action color while it runs, red when it failed. It doesn't pulse.
enum DashboardTimelineDot { case done, running, failed }

/// A row on the timeline: the time on the left, a dot on the rail, then what happened. The rail runs
/// down to the next row; the last row's stops at its dot.
struct DashboardTimelineRow<Content: View>: View {
    let at: Date?
    let dot: DashboardTimelineDot
    let isLast: Bool
    @ViewBuilder let content: Content
    @BighelpThemeReader private var theme
    @ScaledMetric(relativeTo: .caption) private var timeWidth: CGFloat = 62

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(at?.formatted(date: .omitted, time: .shortened) ?? "")
                .font(.bighelp(.caption))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: timeWidth, alignment: .trailing)
                .padding(.top, 3)
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(theme.canvas, lineWidth: 2))
                .padding(.top, 4)
                .frame(width: 28)
                .accessibilityHidden(true)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, isLast ? 0 : BighelpTokens.space16)
        }
        // The rail, behind the dot: the row's whole height, so it meets the next row's.
        .background(alignment: .topLeading) {
            if !isLast {
                Rectangle()
                    .fill(theme.separator)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .padding(.leading, timeWidth + 13)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch dot {
        case .done: theme.secondaryText
        case .running: theme.action
        case .failed: theme.danger
        }
    }
}

// MARK: Command

/// The command, how it ended, and its output laid out to read.
private struct DashboardCommandReadout: View {
    let item: AgentTodayItem
    let command: AgentTodayDetail.Command
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space20) {
            // The title already shows a short command whole.
            if let text = command.command, text != item.title {
                DashboardReadoutSection(title: String(localized: "Command")) {
                    DashboardCodeBlock(text: text, prefix: "$ ")
                }
            }
            if let exit = command.exitCode {
                Label(exit == 0 ? String(localized: "Finished with no errors (exit code 0)")
                                : String(localized: "Ended with exit code \(exit)"),
                      systemImage: exit == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.bighelp(.subheadline, weight: .medium))
                    .foregroundStyle(exit == 0 ? theme.success : theme.danger)
            }
            DashboardReadoutSection(title: String(localized: "Output"),
                                    note: command.outputTruncated ? String(localized: "The newest part") : nil) {
                if let output = command.readableOutput {
                    DashboardCodeBlock(text: output, prefix: nil)
                        .accessibilityIdentifier("dashboard.activity.output")
                } else {
                    Text(item.state == .running ? "Nothing yet." : "It printed nothing.")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }
}

/// Monospaced text on a soft surface, wrapped to the screen and selectable.
private struct DashboardCodeBlock: View {
    let text: String
    let prefix: String?
    @BighelpThemeReader private var theme

    var body: some View {
        Text((prefix ?? "") + text)
            .font(.bighelp(.footnote).monospaced())
            .foregroundStyle(theme.primaryText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(BighelpTokens.space12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous))
    }
}

// MARK: Routine

/// A routine run: its job, its answer as formatted text, and the rest of the run's record on request.
private struct DashboardRoutineReadout: View {
    let item: AgentTodayItem
    let run: AgentTodayDetail.Scheduled
    @State private var showsRecord = false
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space20) {
            if let job = run.job, job != item.title {
                Label(job, systemImage: "calendar.badge.clock")
                    .font(.bighelp(.subheadline, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            if let error = run.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let response = run.response {
                DashboardReadoutSection(title: String(localized: "Result")) {
                    MarkdownMessageView(document: MarkdownDocument(response.answer))
                        .foregroundStyle(theme.primaryText)
                        .tint(theme.action)
                        .textSelection(.enabled)
                        .padding(BighelpTokens.space16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius16,
                                                                         style: .continuous))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("dashboard.activity.answer")
                }
                if let record = response.record, !record.isEmpty {
                    DisclosureGroup(isExpanded: $showsRecord) {
                        MarkdownMessageView(document: MarkdownDocument(record))
                            .foregroundStyle(theme.secondaryText)
                            .textSelection(.enabled)
                            .padding(.top, BighelpTokens.space8)
                    } label: {
                        Text("Run details")
                            .font(.bighelp(.subheadline, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                            .frame(minHeight: BighelpTokens.hitTarget)
                    }
                    .tint(theme.secondaryText)
                }
            } else if run.error == nil {
                Text("This run saved no output.")
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }
}

/// A titled part of the read-out.
private struct DashboardReadoutSection<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder let content: Content
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                if let note {
                    Text(note)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            content
        }
    }
}
