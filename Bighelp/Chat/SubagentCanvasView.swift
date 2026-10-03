import SwiftUI

/// Watch one helper agent: what it was asked, its steps as they happen in the
/// chat's own tool folders, and how it ended. It follows the chat's model, so
/// it updates while open and keeps the end state after the helper finishes.
struct SubagentCanvasView: View {
    let model: ChatModel
    let subagentID: String

    @State private var recordNote: String?
    @State private var showsWholeTask = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var state: SubagentCanvasState? { model.subagentCanvases[subagentID] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                if let state {
                    header(state)
                    steps(state)
                    if state.isFinished { result(state) }
                } else {
                    Text("This helper is no longer part of this chat.")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(BighelpTokens.space16)
                        .bighelpSurface(.card)
                }
                if let recordNote {
                    Text(recordNote)
                        .font(.bighelp(.caption))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("subagent.canvas.record-note")
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(BighelpTokens.space20)
            .frame(maxWidth: .infinity)
        }
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .accessibilityIdentifier("subagent.canvas.\(subagentID)")
        .navigationTitle("Subagent")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: refreshKey) { await keepRecordFresh() }
    }

    // MARK: Header

    private func header(_ state: SubagentCanvasState) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack(alignment: .center, spacing: BighelpTokens.space12) {
                SubagentPhaseGlyph(phase: state.phase)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                Text(Self.statusLine(for: state))
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("subagent.canvas.status")
            }
            let task = state.goal.isEmpty ? state.history?.task ?? "" : state.goal
            if !task.isEmpty {
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    SubagentCanvasCaption(title: "Task")
                    Text(task)
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(showsWholeTask || dynamicTypeSize.isAccessibilitySize ? nil : 6)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("subagent.canvas.goal")
                    if task.count > 280 {
                        Button(showsWholeTask ? "Show less" : "Show all") { showsWholeTask.toggle() }
                            .font(.bighelp(.caption).weight(.semibold))
                            .foregroundStyle(theme.action)
                            .bighelpPlainButtonStyle()
                    }
                }
            }
            if let modelName = state.model {
                Text(modelName)
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BighelpTokens.space16)
        .bighelpSurface(.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subagent.canvas.header")
    }

    // MARK: Steps

    @ViewBuilder
    private func steps(_ state: SubagentCanvasState) -> some View {
        let transcript = state.transcript()
        let entries = ChatTranscriptProjection.entries(
            items: transcript.items, activityEvents: transcript.events,
            // Hermes already leaves out the helper's reasoning when the host hides it.
            visibility: .init(showReasoning: true, showToolCalls: true), isBotMode: false)
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            SubagentCanvasCaption(title: "Steps")
            if entries.isEmpty {
                HStack(spacing: BighelpTokens.space8) {
                    if state.isFinished {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(theme.secondaryText)
                            .accessibilityHidden(true)
                    } else {
                        BighelpThinkingOrb(scenario: .working, scale: .inline)
                            .accessibilityHidden(true)
                    }
                    Text(state.isFinished ? "No steps were reported." : "Waiting for its first step…")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(BighelpTokens.space16)
                .bighelpSurface(.card)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("subagent.canvas.waiting")
            } else {
                LazyVStack(alignment: .leading, spacing: BighelpTokens.space16) {
                    ForEach(entries) { entry in
                        switch entry {
                        case .message(let item):
                            TimelineItemView(item: item, onApprovalTap: { _ in })
                        case .activity(let turn):
                            ChatActivityTurnView(
                                turn: turn,
                                isLive: state.phase == .working && entry.id == entries.last?.id
                            )
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("subagent.canvas.steps")
            }
        }
    }

    // MARK: Result

    private func result(_ state: SubagentCanvasState) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            SubagentCanvasCaption(title: state.phase == .failed ? "What went wrong" : "Result")
            if let text = state.resultText {
                Text(text)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let reason = state.failureReason {
                Text(reason)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.resultText == nil, state.failureReason == nil {
                Text(state.historyIsFinal ? "Its reply is the last step above." : "Hermes didn't send a summary.")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
            }
            if !state.filesWritten.isEmpty {
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text(state.filesWritten.count == 1 ? "Changed 1 file" : "Changed \(state.filesWritten.count) files")
                        .font(.bighelp(.caption).weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                    ForEach(state.filesWritten, id: \.self) { path in
                        Label((path as NSString).lastPathComponent, systemImage: "doc")
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.top, BighelpTokens.space4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BighelpTokens.space16)
        .bighelpSurface(.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subagent.canvas.result")
    }

    // MARK: Saved record

    /// A new step or the end asks for the saved record again; while the helper
    /// works it's read every few seconds, and only while this page is open.
    private var refreshKey: String {
        guard let state else { return subagentID }
        return "\(subagentID):\(state.childSessionID ?? "-"):\(state.toolCount):\(state.isFinished)"
    }

    private func keepRecordFresh() async {
        guard state?.childSessionID != nil else { return }
        // A burst of steps asks once.
        try? await Task.sleep(for: .milliseconds(250))
        while !Task.isCancelled {
            let finished = state?.isFinished == true
            let read = await model.refreshSubagentHistory(id: subagentID)
            guard !Task.isCancelled else { return }
            recordNote = read == .unavailable && finished
                ? "Its saved record couldn't be read, so this shows the steps reported while it worked."
                : nil
            guard !finished, state?.isFinished == false else { return }
            try? await Task.sleep(for: .seconds(4))
        }
    }

    /// "Working · Reading notes.md…", "Done · Worked for 1m 12s".
    static func statusLine(for state: SubagentCanvasState) -> String {
        switch state.phase {
        case .waiting:
            return "Getting ready…"
        case .working:
            return state.currentActivity.map { "Working · \($0)" } ?? "Working…"
        case .done:
            return "Done · " + BighelpActivitySummary.doneLabel(elapsed: state.durationSeconds)
        case .failed:
            return "Couldn’t finish"
        case .stopped:
            return "Stopped"
        case .finished:
            return "Finished"
        }
    }

    @BighelpThemeReader private var theme
}

/// Opens one helper's canvas from the Subagents sheet.
struct SubagentCanvasRoute: Hashable, Sendable {
    let id: String
}

/// The helper's state as a small glyph: the working orb, or how it ended.
struct SubagentPhaseGlyph: View {
    let phase: SubagentCanvasState.Phase

    var body: some View {
        switch phase {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(theme.secondaryText)
        case .working:
            BighelpThinkingOrb(scenario: .working, scale: .inline)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(theme.danger)
        case .stopped:
            Image(systemName: "minus.circle.fill").foregroundStyle(theme.secondaryText)
        case .finished:
            Image(systemName: "circle.dashed").foregroundStyle(theme.secondaryText)
        }
    }

    @BighelpThemeReader private var theme
}

/// A small, bold, letterspaced section caption, as DESIGN.md asks.
private struct SubagentCanvasCaption: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.bighelp(.caption2).weight(.bold))
            .tracking(0.9)
            .foregroundStyle(theme.secondaryText)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
    }

    @BighelpThemeReader private var theme
}
