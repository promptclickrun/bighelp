import SwiftUI

/// One start of a Dev Factory recipe: its runs, one per project, with each run's steps.
/// It reads each run's detail and keeps reading while any run works.
@MainActor
@Observable
final class DevFactoryRunGroupModel {
    let groupID: String
    private(set) var details: [String: WorkflowRunDetail] = [:]
    private(set) var busyRunID: String?
    var errorMessage: String?

    @ObservationIgnored let store: DevFactoryStore
    @ObservationIgnored private var isOnScreen = false

    init(groupID: String, store: DevFactoryStore) {
        self.groupID = groupID
        self.store = store
    }

    var group: WorkflowCodeGroup? { store.group(id: groupID) }

    /// The group's runs with their newest details.
    var runs: [WorkflowRunSummary] {
        (group?.runs ?? []).map { details[$0.id]?.summary ?? $0 }
    }

    func appear() async {
        isOnScreen = true
        while isOnScreen, !Task.isCancelled {
            await refresh()
            let working = runs.contains { $0.state.isWorking }
            try? await Task.sleep(for: .seconds(working ? 3 : 15))
        }
    }

    func disappear() { isOnScreen = false }

    func refresh() async {
        await store.load()
        for run in group?.runs ?? [] {
            if let detail = try? await store.client.run(id: run.id) { details[run.id] = detail }
        }
    }

    /// Approves (or sends back with notes) exactly the changes the run is waiting on.
    func signoff(_ run: WorkflowRunSummary, _ decision: WorkflowSignoffDecision, notes: String = "") async {
        guard let signoff = details[run.id]?.changesSignoff, busyRunID == nil else { return }
        busyRunID = run.id
        defer { busyRunID = nil }
        do {
            _ = try await store.client.signoff(runID: run.id, stageKey: signoff.stageKey, decision: decision,
                                               artifactSHA256: signoff.sha256, notes: notes)
            errorMessage = nil
        } catch WorkspaceClientError.rejected(let code, _) where code == "approval_stale" {
            errorMessage = "The changes moved on since you looked. Look again, then approve."
        } catch {
            errorMessage = WorkflowsStore.reason(error)
        }
        await refresh()
    }

    func perform(_ action: WorkflowRunAction, on run: WorkflowRunSummary) async {
        guard busyRunID == nil else { return }
        busyRunID = run.id
        defer { busyRunID = nil }
        do {
            _ = try await store.client.control(runID: run.id, action: action, expectedVersion: run.version)
            errorMessage = nil
        } catch {
            errorMessage = WorkflowsStore.reason(error)
        }
        await refresh()
    }

    func can(_ action: WorkflowRunAction, _ run: WorkflowRunSummary) -> Bool {
        guard let detail = details[run.id] else { return false }
        if !detail.allowedActions.isEmpty { return detail.allowedActions.contains(action.rawValue) }
        return action == .retry ? [.needsAttention, .failed].contains(run.state) : !run.state.isFinished
    }
}

/// Dev Factory's run view (approved 4A): one card per project with its steps, what it
/// does now, and the button it needs. A card opens the run's own Workflows screen.
struct DevFactoryRunGroupView: View {
    @State private var model: DevFactoryRunGroupModel
    let onOpenRun: (WorkflowRunSummary) -> Void
    let onLookAtChanges: (WorkflowRunSummary) -> Void
    @State private var askingChanges: WorkflowRunSummary?
    @State private var notes = ""
    @Environment(\.openURL) private var openURL

    init(model: DevFactoryRunGroupModel, onOpenRun: @escaping (WorkflowRunSummary) -> Void,
         onLookAtChanges: @escaping (WorkflowRunSummary) -> Void) {
        _model = State(initialValue: model)
        self.onOpenRun = onOpenRun
        self.onLookAtChanges = onLookAtChanges
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BighelpTokens.space12) {
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                }
                ForEach(model.runs) { run in
                    card(run)
                }
                if let detail = model.details.values.first, !detail.stages.isEmpty {
                    Text("Steps: " + detail.stages.map { DevFactoryWords.filled($0.title, inputs: detail.inputs) }
                        .joined(separator: " · "))
                        .font(.bighelp(.caption))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(BighelpTokens.space16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .navigationTitle(model.group?.name ?? "Run")
        .navigationBarTitleDisplayMode(.inline)
        .bighelpRefreshable { await model.refresh() }
        .task { await model.appear() }
        .onDisappear { model.disappear() }
        .alert("What should change?", isPresented: Binding(get: { askingChanges != nil },
                                                           set: { if !$0 { askingChanges = nil } })) {
            TextField("Notes for the agent", text: $notes)
            Button("Send back") {
                if let run = askingChanges {
                    Task { await model.signoff(run, .changes, notes: notes) }
                }
            }
            .disabled(notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("devfactory.group")
    }

    private func card(_ run: WorkflowRunSummary) -> some View {
        let detail = model.details[run.id]
        let waitsOnChanges = run.state == .waitingForYou && detail?.changesSignoff != nil
        return VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(spacing: BighelpTokens.space8) {
                Text(run.code?.project.label ?? run.workflowName)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(theme.raisedSurface, in: .rect(cornerRadius: 6))
                Spacer(minLength: 0)
                CodePill(text: DevFactoryWords.state(run), tint: DevFactoryWords.tint(run, theme))
                    // A run that finishes while you watch gets the kit's done.
                    .bighelpNoodleMoment(.done, when: run.state == .succeeded, size: 28)
            }
            if let stages = detail?.stages, !stages.isEmpty {
                HStack(spacing: 4) {
                    ForEach(stages) { stage in
                        Capsule().fill(DevFactoryWords.tint(stage.state, theme)).frame(height: 5)
                    }
                }
                .accessibilityHidden(true)
            }
            Text(DevFactoryWords.line(run, detail: detail))
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            actions(run, waitsOnChanges: waitsOnChanges)
        }
        .padding(BighelpTokens.space16)
        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16)
                .stroke(run.state == .waitingForYou ? theme.warning.opacity(0.5) : theme.border,
                        lineWidth: run.state == .waitingForYou ? 1 : BighelpTokens.hairline)
        }
        .contentShape(.rect)
        .onTapGesture { onOpenRun(run) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("devfactory.run.\(run.code?.project.key ?? run.id)")
    }

    @ViewBuilder
    private func actions(_ run: WorkflowRunSummary, waitsOnChanges: Bool) -> some View {
        let busy = model.busyRunID == run.id
        HStack(spacing: BighelpTokens.space8) {
            if waitsOnChanges {
                Button("Approve") { Task { await model.signoff(run, .approve) } }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.warning)
                    .accessibilityIdentifier("devfactory.approve")
                Button("Look at changes") { onLookAtChanges(run) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("devfactory.changes")
                Menu {
                    Button("Ask for changes", systemImage: "arrow.uturn.backward") {
                        notes = ""
                        askingChanges = run
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: BighelpTokens.scaled(32), height: BighelpTokens.scaled(32))
                        .contentShape(.rect)
                }
                .accessibilityLabel("More for \(run.code?.project.label ?? "this run")")
            } else if model.can(.retry, run), run.state != .running {
                Button("Try again") { Task { await model.perform(.retry, on: run) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("devfactory.retry")
                if model.can(.cancel, run) {
                    Button("Cancel", role: .destructive) { Task { await model.perform(.cancel, on: run) } }
                        .buttonStyle(.bordered)
                }
            }
            if let pull = run.code?.pullRequest {
                Button("Pull request #\(pull.number)", systemImage: "arrow.triangle.pull") { openURL(pull.url) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("devfactory.pull-request")
            }
            if busy { ProgressView() }
        }
        .font(.bighelp(.subheadline).weight(.semibold))
        .disabled(busy)
    }

    @BighelpThemeReader private var theme
}

/// Dev Factory's words for a run, from what the computer says (never guessed).
enum DevFactoryWords {
    static func state(_ run: WorkflowRunSummary) -> String {
        switch run.state {
        case .waitingForYou: "Needs you"
        case .needsAttention: "Needs attention"
        case .succeeded: run.code?.pullRequest == nil ? "Done" : "PR open"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .planned: "Waiting to start"
        default: "Running"
        }
    }

    /// What the run does now: the computer's reason when it waits or stopped, else its step.
    static func line(_ run: WorkflowRunSummary, detail: WorkflowRunDetail?) -> String {
        if let changes = detail?.changesSignoff, run.state == .waitingForYou {
            return "Look at the changes and approve them. " + changes.summary
        }
        if let reason = run.code?.reason, !reason.isEmpty { return reason }
        switch run.state {
        case .planned: return "Starts when a slot frees up on your computer."
        case .succeeded: return run.code?.pullRequest.map { "Opened pull request #\($0.number)." } ?? "Finished."
        default:
            return run.stageTitle.map { "\(filled($0, inputs: detail?.inputs ?? [:]))…" } ?? run.stateLine
        }
    }

    /// "Update {package} to {version}" with the run's inputs in place.
    static func filled(_ title: String, inputs: WorkflowJSON) -> String {
        inputs.reduce(title) { text, input in
            guard let value = input.value.displayText, !value.isEmpty else { return text }
            return text.replacingOccurrences(of: "{\(input.key)}", with: value)
                .replacingOccurrences(of: "{inputs.\(input.key)}", with: value)
        }
    }

    static func tint(_ run: WorkflowRunSummary, _ theme: BighelpTheme) -> Color { tint(run.state, theme) }

    static func tint(_ state: WorkflowRunState, _ theme: BighelpTheme) -> Color {
        switch state {
        case .waitingForYou: theme.warning
        case .needsAttention, .failed: theme.danger
        case .succeeded, .accepted: theme.success
        case .cancelled: theme.tertiaryText
        case .planned: theme.raisedSurface
        case .unknown: theme.raisedSurface
        default: state.isWorking ? theme.action : theme.raisedSurface
        }
    }
}
