import SwiftUI

/// Opens a run's sign-off with its own model.
struct WorkflowSignoffScreen: View {
    let context: WorkflowsContext
    @State private var model: WorkflowRunModel

    init(context: WorkflowsContext, runID: String) {
        self.context = context
        _model = State(initialValue: WorkflowRunModel(runID: runID, client: context.client))
    }

    var body: some View {
        WorkflowSignoffView(model: model, context: context)
            .task {
                await model.load()
                await model.loadSignoffFile()
            }
    }
}

/// Sign-off: how the run got here, the reviewer's notes and the exact file,
/// then Ask for changes or Approve. Stacked on iPhone; side by side at regular width.
/// Approving never publishes anything: the file comes to you.
struct WorkflowSignoffView: View {
    let model: WorkflowRunModel
    let context: WorkflowsContext
    @State private var showsChanges = false
    @State private var notes = ""
    @State private var decided: WorkflowSignoffDecision?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @BighelpThemeReader private var theme

    private var signoff: WorkflowSignoff? { model.detail?.signoff }
    private var run: WorkflowRunSummary? { model.summary }
    private var isWaiting: Bool { run?.state == .waitingForYou }

    var body: some View {
        Group {
            if let signoff, let run {
                if sizeClass == .regular {
                    HStack(spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                                BighelpDeferredSection { summary(run) }
                                BighelpDeferredSection { history(signoff) }
                                BighelpDeferredSection { reviewerNotes(signoff) }
                            }
                            .padding(BighelpTokens.space20)
                        }
                        .frame(width: 360)
                        .background(theme.surface.opacity(0.5))
                        Divider().overlay(theme.separator)
                        VStack(spacing: 0) {
                            fileHeader(signoff)
                            Divider().overlay(theme.separator)
                            ScrollView {
                                BighelpDeferredSection { document }
                                    .padding(.horizontal, BighelpTokens.space40)
                                    .padding(.vertical, BighelpTokens.space24)
                                    .frame(maxWidth: 720)
                                    .frame(maxWidth: .infinity)
                            }
                            Divider().overlay(theme.separator)
                            approvalBar(signoff)
                        }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                            BighelpDeferredSection { summary(run) }
                            BighelpDeferredSection { history(signoff) }
                            BighelpDeferredSection { reviewerNotes(signoff) }
                            VStack(alignment: .leading, spacing: 0) {
                                fileHeader(signoff)
                                Divider().overlay(theme.separator)
                                BighelpDeferredSection { document }
                                    .padding(BighelpTokens.space16)
                            }
                            .workflowCard(theme, padding: 0)
                        }
                        .padding(.horizontal, BighelpTokens.space16)
                        .padding(.vertical, BighelpTokens.space8)
                        .frame(maxWidth: 680)
                        .frame(maxWidth: .infinity)
                    }
                    .safeAreaInset(edge: .bottom) {
                        approvalBar(signoff)
                            .background(theme.surface.ignoresSafeArea())
                    }
                }
            } else if model.detail != nil {
                ContentUnavailableView("Nothing to sign off", systemImage: "checkmark.seal",
                                       description: Text("This run isn't waiting for your sign-off."))
            } else {
                WorkflowLoadStateView(state: model.state) { Task { await model.load() } }
            }
        }
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflows.signoff")
        .navigationTitle(run.map { "Sign-off · Run \($0.number)" } ?? "Sign-off")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if let run, sizeClass == .regular {
                ToolbarItem(placement: .topBarTrailing) { WorkflowStatePill(state: run.state, detail: waitedText(run)) }
            }
        }
    }

    // MARK: Left column

    private func summary(_ run: WorkflowRunSummary) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            Text(run.workflowName)
                .font(.bighelp(.title3).weight(.bold))
            if sizeClass != .regular {
                WorkflowStatePill(state: run.state, detail: waitedText(run))
            }
            Text("Run \(run.number)")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
        }
    }

    private func waitedText(_ run: WorkflowRunSummary) -> String? {
        guard run.state == .waitingForYou, let since = run.waiting?.since ?? run.updatedAt else { return nil }
        return WorkflowWords.duration(Date.now.timeIntervalSince(since))
    }

    private func history(_ signoff: WorkflowSignoff) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text("How it got here")
                .font(.bighelp(.subheadline).weight(.semibold))
                .foregroundStyle(theme.secondaryText)
            ForEach(model.detail?.signoffHistory(for: signoff) ?? signoff.history) { step in
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    HStack(spacing: BighelpTokens.space8) {
                        Image(systemName: step.asksForChanges ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(step.asksForChanges ? theme.warning : theme.success)
                        Text(step.title)
                            .font(.bighelp(.subheadline))
                        Spacer(minLength: BighelpTokens.space8)
                        Text([context.agentName(step.agentID),
                              step.durationMs.map { WorkflowWords.duration(Double($0) / 1_000) }]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(.bighelp(.caption).monospacedDigit())
                            .foregroundStyle(theme.secondaryText)
                    }
                    if !step.notes.isEmpty {
                        Text(step.notes.map(\.text).joined(separator: " "))
                            .font(.bighelp(.footnote))
                            .padding(BighelpTokens.space8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.raisedSurface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius8))
                            .padding(.leading, 26)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: BighelpTokens.space8) {
                Image(systemName: "circle")
                    .foregroundStyle(theme.action)
                Text("Sign-off")
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(theme.action)
                Spacer()
                Text("you")
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.action)
            }
        }
        .accessibilityIdentifier("workflows.signoff.history")
    }

    @ViewBuilder
    private func reviewerNotes(_ signoff: WorkflowSignoff) -> some View {
        if !signoff.reviewNotes.isEmpty {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                HStack {
                    Text("Reviewer notes on v\(signoff.artifactIteration)")
                        .font(.bighelp(.subheadline).weight(.semibold))
                    Spacer()
                    if let decision = model.detail?.reviewDecision(for: signoff) {
                        Text(decision)
                            .font(.bighelp(.caption).monospaced())
                            .foregroundStyle(decision == "pass" ? theme.success : theme.warning)
                    }
                }
                ForEach(signoff.reviewNotes) { note in
                    HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                        Text(note.isMajor ? "Major" : "Minor")
                            .font(.bighelp(.caption))
                            .foregroundStyle(note.isMajor ? theme.warning : theme.secondaryText)
                        Text(note.text)
                            .font(.bighelp(.footnote))
                    }
                }
            }
            .workflowCard(theme, padding: BighelpTokens.space12)
            .accessibilityIdentifier("workflows.signoff.notes")
        }
    }

    // MARK: The file

    private func fileHeader(_ signoff: WorkflowSignoff) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            Image(systemName: "doc.text")
                .foregroundStyle(BighelpTokens.Palette.violet)
            VStack(alignment: .leading, spacing: 0) {
                Text(signoff.artifactName)
                    .font(.bighelp(.subheadline).monospaced())
                Text([signoff.artifactWords.map { "\($0.formatted()) words" }, "Markdown"].compactMap { $0 }.joined(separator: " · "))
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: BighelpTokens.space8)
            if model.previousText != nil {
                Picker("Show", selection: $showsChanges) {
                    Text("Read").tag(false)
                    Text("Changes from v\(max(1, signoff.artifactIteration - 1))").tag(true)
                }
                .bighelpSegmentedPicker()
                .fixedSize()
                .accessibilityIdentifier("workflows.signoff.mode")
            }
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space12)
    }

    @ViewBuilder
    private var document: some View {
        if let text = model.signoffText {
            WorkflowDocumentView(text: text, previous: model.previousText, showsChanges: showsChanges)
        } else if model.isLoadingFile || model.state == .loading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        } else {
            VStack(spacing: BighelpTokens.space8) {
                Text(model.message ?? "The file isn't here yet.")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                Button("Try again") { Task { await model.loadSignoffFile() } }
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    // MARK: Approve

    private func approvalBar(_ signoff: WorkflowSignoff) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            if let decided, !isWaiting {
                Label(decided == .approve ? "Approved. The file is yours; nothing was published."
                                          : "Sent back with your notes. The run goes on.",
                      systemImage: "checkmark.circle.fill")
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(theme.success)
                    .accessibilityIdentifier("workflows.signoff.done")
                if decided == .approve, let id = run?.id {
                    Button("Open run") { context.openRun(id) }
                        .accessibilityIdentifier("workflows.signoff.open-run")
                }
            } else if isWaiting {
                Label {
                    let fingerprint = context.isNerdMode ? signoff.artifactSHA256 : WorkflowSHA.short(signoff.artifactSHA256)
                    Text("Approving exactly this file · \(Text(fingerprint).font(.bighelp(.caption).monospaced()))")
                } icon: {
                    Image(systemName: "lock")
                }
                .font(.bighelp(.caption))
                .foregroundStyle(theme.secondaryText)
                .accessibilityIdentifier("workflows.signoff.fingerprint")
                if let message = model.message {
                    Text(message)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.warning)
                        .accessibilityIdentifier("workflows.signoff.message")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: BighelpTokens.space8) {
                        notesField(signoff)
                        buttons(signoff)
                    }
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        notesField(signoff)
                        HStack(spacing: BighelpTokens.space8) { buttons(signoff) }
                    }
                }
                Text("No agent is running while this waits. Approving hands the file to you; it does not publish anything.")
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let run {
                Label("This run is \(run.state.title.lowercased()).", systemImage: run.state.symbol)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(run.state.color(theme))
            }
        }
        .padding(BighelpTokens.space16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notesField(_ signoff: WorkflowSignoff) -> some View {
        // The agent that wrote the file gets the notes.
        let writer = model.detail?.outputs.first { $0.sha256 == signoff.artifactSHA256 }?.stageKey
        let name = context.agentName(model.detail?.stages.first { $0.key == writer }?.agentID) ?? "the agent"
        return TextField("Notes", text: $notes,
                         prompt: Text("Notes for \(name) (needed to ask for changes)").bighelpFieldHint(theme),
                         axis: .vertical)
            .lineLimit(1...4)
            .font(.bighelp(.body))
            .padding(.horizontal, BighelpTokens.space12)
            .frame(minHeight: BighelpTokens.hitTarget)
            .background(theme.raisedSurface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous))
            .accessibilityIdentifier("workflows.signoff.notes-field")
    }

    @ViewBuilder
    private func buttons(_ signoff: WorkflowSignoff) -> some View {
        let ready = model.signoffText != nil && !model.isWorking
        Button("Ask for changes") { decide(.changes) }
            .buttonStyle(.bordered)
            .disabled(!ready || notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .frame(minHeight: BighelpTokens.hitTarget)
            .accessibilityIdentifier("workflows.signoff.changes")
        Button("Approve v\(signoff.artifactIteration)") { decide(.approve) }
            .buttonStyle(.borderedProminent)
            .disabled(!ready)
            .bighelpDefaultAction()
            .frame(minHeight: BighelpTokens.hitTarget)
            .accessibilityIdentifier("workflows.signoff.approve")
    }

    private func decide(_ decision: WorkflowSignoffDecision) {
        Task {
            if await model.signoff(decision, notes: notes) {
                decided = decision
                notes = ""
                await context.store.load()
            }
        }
    }
}
