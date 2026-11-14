import SwiftUI

struct SessionSubagentRosterSheet: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    /// Read live from the chat, so rows and an open canvas update as helpers work.
    let model: ChatModel
    let sessionCatalog: SessionCatalogStore?

    private var subagents: [SessionSubagentSnapshot] { model.sessionSubagents }
    /// Every helper this chat has seen, running or finished, so a finished
    /// helper stays open to the end of its story.
    private var nativeSubagents: [SubagentCanvasState] { model.subagentCanvases.ordered }
    /// Running first, then the ones that ended lately, as Hermes lists them.
    private var commands: [ChatBackgroundCommand] { model.backgroundCommands }

    var body: some View {
        let totalSubagents = subagents.count + nativeSubagents.count
        let summary = ChatBackgroundSummary(subagents: totalSubagents, commands: commands.count(where: \.isRunning))
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: BighelpTokens.space12) {
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        Label(summary.isEmpty ? String(localized: "Nothing running now") : summary.detail,
                              systemImage: "square.stack.3d.up")
                            .font(.bighelp(.headline))
                            .foregroundStyle(theme.primaryText)
                        Text(totalSubagents > 0 ? "Tap a subagent to watch it work." : "Work the bot left running in this chat.")
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(BighelpTokens.space16)
                    .bighelpSurface(.card)
                    .accessibilityIdentifier("subagent.roster.summary")
                    ForEach(subagents) { subagent in
                        let card = SessionSubagentRosterPresentation.card(for: subagent)
                        NavigationLink(value: subagent) {
                            HStack(alignment: .top, spacing: BighelpTokens.space12) {
                                BighelpThinkingOrb(scenario: .working, scale: .inline)
                                    .frame(width: 22, height: 22)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                    Text(card.name)
                                        .bighelpFont(.label)
                                        .foregroundStyle(theme.primaryText)
                                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                        .truncationMode(.tail)
                                    Text(card.summary)
                                        .bighelpFont(.body)
                                        .foregroundStyle(theme.secondaryText)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                        .truncationMode(.tail)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right")
                                    .font(.bighelp(.caption).weight(.semibold))
                                    .foregroundStyle(theme.tertiaryText)
                                    .accessibilityHidden(true)
                            }
                            .padding(BighelpTokens.space16)
                            .contentShape(.rect)
                            .bighelpSurface(.card)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(card.name), \(card.summary)")
                        .accessibilityIdentifier("subagent.roster.\(subagent.sessionID)")
                    }
                    ForEach(nativeSubagents) { subagent in
                        nativeSubagentRow(subagent)
                    }
                    ForEach(commands) { command in
                        BackgroundCommandRow(command: command, model: model)
                    }
                }
                .frame(maxWidth: 680)
                .padding(BighelpTokens.space20)
                .frame(maxWidth: .infinity)
            }
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle("In the background")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: SessionSubagentSnapshot.self) { subagent in
                SessionSubagentDetailView(
                    subagent: subagent,
                    sessionCatalog: sessionCatalog
                )
            }
            .navigationDestination(for: SubagentCanvasRoute.self) { route in
                SubagentCanvasView(model: model, subagentID: route.id)
            }
        }
    }

    private func nativeSubagentRow(_ subagent: SubagentCanvasState) -> some View {
        NavigationLink(value: SubagentCanvasRoute(id: subagent.id)) {
            HStack(alignment: .top, spacing: BighelpTokens.space12) {
                SubagentPhaseGlyph(phase: subagent.phase)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text(subagent.goal.isEmpty ? "Subagent task" : subagent.goal)
                        .bighelpFont(.label)
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .truncationMode(.tail)
                    Text(nativeSubagentStatus(subagent))
                        .bighelpFont(.body)
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.bighelp(.caption).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .padding(BighelpTokens.space16)
            .contentShape(.rect)
            .bighelpSurface(.card)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(subagent.goal.isEmpty ? "Subagent task" : subagent.goal), \(nativeSubagentStatus(subagent))")
        .accessibilityHint("Shows what it's doing")
        .accessibilityIdentifier("subagent.native.roster.\(subagent.id)")
    }

    /// "Working · Reading notes.md…", "Done · Read 2 files, ran tests".
    private func nativeSubagentStatus(_ subagent: SubagentCanvasState) -> String {
        let status = SubagentCanvasView.statusLine(for: subagent)
        guard subagent.isFinished, let summary = subagent.stepSummary else { return status }
        return subagent.phase == .done ? "Done · \(summary)" : "\(status) · \(summary)"
    }

    @BighelpThemeReader private var theme

}

/// A command the agent left running: what it runs, for how long, and Stop. Its latest output shows
/// with Nerd Mode on.
private struct BackgroundCommandRow: View {
    let command: ChatBackgroundCommand
    let model: ChatModel
    @Environment(\.nerdModeEnabled) private var nerdModeEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isStopping = false
    @State private var stopMissed = false
    @State private var showsAllOutput = false
    @BighelpThemeReader private var theme

    static let previewLines = 4

    var body: some View {
        let showsOutput = nerdModeEnabled && !command.output.isEmpty
        let hasMoreOutput = showsOutput && Self.lastLines(command.output, Self.previewLines) != command.output
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack(alignment: .top, spacing: BighelpTokens.space12) {
                Image(systemName: command.isRunning ? "terminal.fill" : "terminal")
                    .font(.bighelp(.subheadline, weight: .semibold))
                    .foregroundStyle(command.isRunning ? theme.action : theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text(command.command)
                        .font(.bighelp(.subheadline, weight: .semibold).monospaced())
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .truncationMode(.middle)
                    // Once a minute, so the run time keeps up without redrawing all the time.
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(Self.status(command, now: context.date))
                            .bighelpFont(.body)
                            .foregroundStyle(theme.secondaryText)
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsOutput {
                Text(showsAllOutput ? command.output : Self.lastLines(command.output, Self.previewLines))
                    .font(.bighelp(.caption).monospaced())
                    .foregroundStyle(theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(BighelpTokens.space12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.secondaryText.opacity(0.1)))
                    .accessibilityIdentifier("background.command.output.\(command.id)")
            }
            if command.isRunning || hasMoreOutput {
                HStack(spacing: BighelpTokens.space8) {
                    if command.isRunning {
                        Button(role: .destructive, action: stop) {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(BighelpV2ButtonStyle(emphasis: .secondary))
                        .disabled(isStopping)
                        .accessibilityLabel("Stop \(command.command)")
                        .accessibilityIdentifier("background.command.stop.\(command.id)")
                    }
                    if hasMoreOutput {
                        Button(showsAllOutput ? "Less output" : "All output") { showsAllOutput.toggle() }
                            .buttonStyle(BighelpV2ButtonStyle(emphasis: .secondary))
                    }
                }
            }
            if stopMissed {
                Text("It had already finished.")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(BighelpTokens.space16)
        .bighelpSurface(.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("background.command.\(command.id)")
    }

    private func stop() {
        guard !isStopping else { return }
        isStopping = true
        Task {
            stopMissed = !(await model.stopBackgroundCommand(command.id))
            isStopping = false
        }
    }

    /// "Running · 6 min", or how it ended.
    static func status(_ command: ChatBackgroundCommand, now: Date) -> String {
        guard command.isRunning else { return command.outcome }
        guard let started = command.startedAt else { return command.outcome }
        let seconds = max(0, now.timeIntervalSince(started))
        guard seconds >= 60 else { return String(localized: "Running · just started") }
        let length = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return String(localized: "Running · \(length)")
    }

    static func lastLines(_ text: String, _ count: Int) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let trimmed = lines.reversed().drop { $0.allSatisfy(\.isWhitespace) }.reversed()
        return trimmed.suffix(count).joined(separator: "\n")
    }
}

private struct SessionSubagentDetailView: View {
    let subagent: SessionSubagentSnapshot
    let sessionCatalog: SessionCatalogStore?

    @State private var availabilityMessage: String?

    private var record: SessionRecord? {
        sessionCatalog?.session(id: subagent.sessionID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                let card = SessionSubagentRosterPresentation.card(for: subagent)
                VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                    HStack(alignment: .top, spacing: BighelpTokens.space12) {
                        subagentStatusIcon
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            Text(card.name)
                                .font(.bighelp(.headline))
                                .foregroundStyle(theme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(record.map(SessionSubagentDetailPresentation.statusTitle)
                                ?? "Waiting for child chat")
                                .font(.bighelp(.subheadline))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(card.summary)
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(BighelpTokens.space16)
                .bighelpSurface(.card)
                .accessibilityIdentifier("subagent.detail.summary.\(subagent.sessionID)")

                Text("Assigned goal")
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text(subagent.goal)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(BighelpTokens.space16)
                    .bighelpSurface(.card)

                if let subagentStreamAcceptanceFixture,
                   subagentStreamAcceptanceFixture.isControlling(
                       sessionID: subagent.sessionID
                   ) {
                    fixtureControls(subagentStreamAcceptanceFixture)
                }

                if let record {
                    persistedSession(record)
                } else {
                    HStack(spacing: BighelpTokens.space8) {
                        BighelpThinkingOrb(scenario: .working, scale: .inline)
                            .accessibilityHidden(true)
                        Text(availabilityMessage ?? "Loading the persisted child chat from Hermes…")
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(BighelpTokens.space16)
                    .bighelpSurface(.card)
                    .accessibilityIdentifier("subagent.detail.persistence-placeholder")
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(BighelpTokens.space20)
            .frame(maxWidth: .infinity)
        }
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .accessibilityIdentifier("subagent.detail.\(subagent.sessionID)")
        .navigationTitle("Subagent chat")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            subagentStreamAcceptanceFixture?.observeDetail(
                sessionID: subagent.sessionID
            )
        }
        .task(id: subagent.sessionID) {
            await refreshPersistedSession()
        }
    }

    @ViewBuilder
    private var subagentStatusIcon: some View {
        if let record {
            switch SessionSubagentDetailPresentation.state(for: record) {
            case .live:
                BighelpThinkingOrb(scenario: .working, scale: .inline)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.success)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(theme.danger)
            case .cancelled:
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(theme.secondaryText)
            case .waiting:
                Image(systemName: "clock")
                    .foregroundStyle(theme.secondaryText)
            case .recorded:
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(theme.secondaryText)
            }
        } else {
            BighelpThinkingOrb(scenario: .working, scale: .inline)
        }
    }

    @ViewBuilder
    private func persistedSession(_ record: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            HStack(spacing: BighelpTokens.space8) {
                switch SessionSubagentDetailPresentation.state(for: record) {
                case .live:
                    BighelpThinkingOrb(scenario: .working, scale: .inline)
                        .accessibilityHidden(true)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.success)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.danger)
                case .cancelled:
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(theme.secondaryText)
                case .waiting:
                    EmptyView()
                case .recorded:
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(theme.secondaryText)
                }
                Text(SessionSubagentDetailPresentation.statusTitle(for: record))
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("subagent.detail.status.\(subagent.sessionID)")
            }

            if record.items.isEmpty && record.activityEvents.isEmpty {
                Text("No child activity has arrived yet.")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(BighelpTokens.space16)
                    .bighelpSurface(.card)
            } else {
                let visibility = sessionCatalog?.activityVisibility(for: record) ?? .default
                ChatFoldedSteps(entries: transcriptEntries(for: record, visibility: visibility),
                                activityEvents: record.activityEvents, isLive: record.isActive,
                                interimReplies: .following(visibility))
            }

            if let availabilityMessage {
                Text(availabilityMessage)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func transcriptEntries(for record: SessionRecord, visibility: ChatActivityVisibility) -> [ChatTranscriptEntry] {
        ChatTranscriptProjection.entries(
            items: record.items,
            activityEvents: record.activityEvents,
            visibility: visibility,
            isBotMode: record.kind == .botMode,
            isScheduled: record.isCronSession
        )
    }

    private func fixtureControls(
        _ fixture: SubagentStreamAcceptanceFixtureController
    ) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            Button("Test fixture: emit second live event") {
                fixture.emitSecondLiveEvent()
            }
            .accessibilityIdentifier("fixture.subagent-stream.emit-second")
            .disabled(fixture.observedDetailSessionID != subagent.sessionID
                || fixture.didEmitSecondEvent)

            Button("Test fixture: emit terminal catch-up") {
                fixture.emitCanonicalTerminalCatchUp()
            }
            .accessibilityIdentifier("fixture.subagent-stream.emit-terminal")
            .disabled(!fixture.didEmitSecondEvent || fixture.didEmitTerminalEvent)
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fixture.subagent-stream.controls")
    }

    private func refreshPersistedSession() async {
        guard let sessionCatalog else {
            availabilityMessage = "This child chat is not available in this preview."
            return
        }

        do {
            _ = try await sessionCatalog.refreshOrPrepareSession(
                id: subagent.sessionID
            )
            try Task.checkCancellation()
            availabilityMessage = nil
        } catch is CancellationError {
            return
        } catch {
            availabilityMessage = record == nil
                ? "Waiting for Hermes to persist this child chat…"
                : "The latest child-chat update is not available yet."
        }
    }

    @BighelpThemeReader private var theme

    @Environment(\.subagentStreamAcceptanceFixture)
    private var subagentStreamAcceptanceFixture
}
