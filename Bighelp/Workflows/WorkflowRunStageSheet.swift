import SwiftUI

/// Which stage of a run is open in `WorkflowRunStageSheet`.
struct WorkflowStageSelection: Identifiable, Hashable {
    let id: String
}

/// One stage of a run, live or finished: how it ended, who decided, what it
/// read and what it made. Tap a file to read it.
struct WorkflowRunStageSheet: View {
    let model: WorkflowRunModel
    let context: WorkflowsContext
    let stageKey: String
    @State private var opened: WorkflowOutput?
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    private var detail: WorkflowRunDetail? { model.detail }
    private var stage: WorkflowRunStage? { detail?.stages.first { $0.key == stageKey } }

    var body: some View {
        NavigationStack {
            Form {
                if let detail, let stage {
                    Section { header(stage) }
                    result(stage, in: detail)
                    reads(stage, in: detail)
                    made(stage, in: detail)
                    if context.isNerdMode, !stage.attempts.isEmpty { attempts(stage) }
                } else {
                    Text("This stage isn't in the run any more.")
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .scrollContentBackground(.hidden)
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle(stage?.title ?? "Stage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .bighelpDefaultAction()
                }
            }
            .sheet(item: $opened) { output in
                WorkflowRunFileSheet(model: model, context: context, output: output)
                    .bighelpSheetSize(.large)
            }
        }
        .accessibilityIdentifier("workflows.run.stage-sheet")
    }

    // MARK: Header

    private func header(_ stage: WorkflowRunStage) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            WorkflowStageIcon(kind: stage.kind, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(stage.iteration > 1 && stage.kind == .agent ? "\(stage.title) v\(stage.iteration)" : stage.title)
                    .font(.bighelp(.headline))
                Text([stage.kind.title, context.agentName(stage.agentID), Self.time(stage)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
            Label(stage.state.title, systemImage: stage.state == .planned ? "circle" : stage.state.symbol)
                .font(.bighelp(.caption).weight(.semibold))
                .foregroundStyle(stage.state == .planned ? theme.tertiaryText : stage.state.color(theme))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Result and who decided

    @ViewBuilder
    private func result(_ stage: WorkflowRunStage, in detail: WorkflowRunDetail) -> some View {
        switch stage.kind {
        case .decision:
            Section("Decision") {
                if let reference = stage.uses.first, let decided = detail.output(reference) {
                    row("Result", Self.decisionWords(decided.value?.displayText))
                    let producer = detail.stages.first { $0.key == decided.stageKey }
                    row("Decided by", context.agentName(producer?.agentID) ?? producer?.title ?? decided.stageKey)
                        .accessibilityIdentifier("workflows.run.stage.decided-by")
                } else {
                    Text(stage.state == .planned ? "Not decided yet." : "No decision was recorded.")
                        .foregroundStyle(theme.secondaryText)
                }
            }
        case .signoff:
            Section("Your sign-off") {
                if stage.decisions.isEmpty {
                    if stage.state == .waitingForYou {
                        Button("Review it now") {
                            dismiss()
                            context.open(.workflowSignoff(runID: detail.summary.id))
                        }
                        .accessibilityIdentifier("workflows.run.stage.review")
                    } else {
                        Text(stage.state == .planned ? "Not reviewed yet." : "No sign-off was recorded.")
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                ForEach(Array(stage.decisions.enumerated()), id: \.offset) { _, decision in
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        Text(Self.signoffWords(decision))
                            .font(.bighelp(.body).weight(.semibold))
                        if !decision.notes.isEmpty {
                            Text(decision.notes)
                                .font(.bighelp(.footnote))
                                .foregroundStyle(theme.secondaryText)
                        }
                        if let at = decision.decidedAt {
                            Text(at.formatted(date: .abbreviated, time: .shortened))
                                .font(.bighelp(.caption))
                                .foregroundStyle(theme.tertiaryText)
                        }
                    }
                }
            }
        case .check:
            Section("Check") {
                row("Result", stage.state == .accepted ? "Passed"
                    : stage.state == .planned ? "Not checked yet" : stage.state.title)
            }
        default:
            if let attempt = stage.attempts.last, attempt.state != .planned {
                Section("Result") {
                    row("Done by", context.agentName(attempt.agentID ?? stage.agentID) ?? "An agent")
                    row("Status", stage.state.title)
                    if stage.attempts.count > 1 { row("Tries", "\(stage.attempts.count)") }
                }
            }
        }
    }

    // MARK: Inputs and outputs

    @ViewBuilder
    private func reads(_ stage: WorkflowRunStage, in detail: WorkflowRunDetail) -> some View {
        if !stage.uses.isEmpty {
            Section("What it used") {
                ForEach(stage.uses, id: \.self) { reference in
                    if reference.hasPrefix("inputs.") {
                        let key = String(reference.dropFirst("inputs.".count))
                        row("Input: \(key)", detail.inputs[key]?.displayText ?? "Not given")
                            .accessibilityIdentifier("workflows.run.stage.input.\(key)")
                    } else if let output = detail.output(reference) {
                        let producer = detail.stages.first { $0.key == output.stageKey }?.title ?? output.stageKey
                        outputRow(output, label: "From \(producer)")
                    } else {
                        row(reference, "Not made yet")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func made(_ stage: WorkflowRunStage, in detail: WorkflowRunDetail) -> some View {
        // The newest of each, as the computer lists them.
        let outputs = Dictionary(grouping: detail.outputs.filter { $0.stageKey == stage.key }, by: \.name)
            .compactMap { $0.value.max { $0.iteration < $1.iteration } }
            .sorted { $0.name < $1.name }
        if !outputs.isEmpty {
            Section("What it made") {
                ForEach(outputs) { output in outputRow(output, label: nil) }
            }
        }
    }

    @ViewBuilder
    private func outputRow(_ output: WorkflowOutput, label: String?) -> some View {
        let name = output.iteration > 1 ? "\(output.name) v\(output.iteration)" : output.name
        if output.isFile {
            Button { opened = output } label: {
                HStack(spacing: BighelpTokens.space12) {
                    Image(systemName: "doc.text").foregroundStyle(theme.action)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label.map { "\($0): \(name)" } ?? name)
                            .font(.bighelp(.body))
                            .foregroundStyle(theme.primaryText)
                        if let words = output.wordCount {
                            Text("\(words.formatted()) words")
                                .font(.bighelp(.caption))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.bighelp(.caption))
                        .foregroundStyle(theme.tertiaryText)
                }
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workflows.run.stage.file.\(output.stageKey).\(output.name)")
        } else {
            row(label.map { "\($0): \(name)" } ?? name, Self.valueText(output))
        }
    }

    private func attempts(_ stage: WorkflowRunStage) -> some View {
        Section("Attempts") {
            ForEach(stage.attempts) { attempt in
                row("#\(attempt.number)", ([attempt.state.rawValue]
                    + (attempt.tokens.map { ["\($0.input.formatted()) in", "\($0.output.formatted()) out"] } ?? [])
                    + [attempt.outcomeCode].compactMap { $0 }).joined(separator: " · "))
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.bighelp(.caption))
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .font(.bighelp(.body))
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Words

    static func time(_ stage: WorkflowRunStage) -> String? {
        guard let started = stage.startedAt, let ended = stage.endedAt, ended > started else { return nil }
        return WorkflowWords.duration(ended.timeIntervalSince(started))
    }

    static func decisionWords(_ value: String?) -> String {
        switch value {
        case "pass": "Pass"
        case "changes": "Changes needed"
        case let value?: value
        case nil: "Not decided yet"
        }
    }

    static func signoffWords(_ decision: WorkflowStageDecision) -> String {
        let version = decision.iteration > 1 ? " (version \(decision.iteration))" : ""
        return switch decision.decision {
        case "approve", "approved": "Approved by you\(version)"
        case "changes", "changes_requested": "You asked for changes\(version)"
        default: "\(decision.decision)\(version)"
        }
    }

    /// A short value as words: notes as lines, numbers and text as they are.
    static func valueText(_ output: WorkflowOutput) -> String {
        guard let value = output.value else { return output.type == "notes" ? "No notes" : "Saved on your computer" }
        if output.type == "decision" { return decisionWords(value.displayText) }
        if let notes = value.array {
            let lines = notes.compactMap { $0.object?["text"]?.string ?? $0.displayText }
            return lines.isEmpty ? "No notes" : lines.map { "• \($0)" }.joined(separator: "\n")
        }
        return value.displayText ?? "Saved on your computer"
    }
}

/// One file a stage made, read from the computer.
struct WorkflowRunFileSheet: View {
    let model: WorkflowRunModel
    let context: WorkflowsContext
    let output: WorkflowOutput
    @State private var text: String?
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if let text {
                        WorkflowDocumentView(text: text)
                    } else if failed {
                        ContentUnavailableView {
                            Label("Couldn't load the file", systemImage: "doc.questionmark")
                        } description: {
                            Text("Try again in a moment.")
                        } actions: {
                            Button("Try again") { Task { await load() } }
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                    }
                }
                .padding(BighelpTokens.space16)
            }
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle(WorkflowSignoff.fileName(output))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if let text {
                    ToolbarItem(placement: .primaryAction) {
                        Button { share(text) } label: { Image(systemName: "square.and.arrow.up") }
                            .bighelpIconLabel("Share")
                    }
                }
            }
        }
        .task { if text == nil { await load() } }
        .accessibilityIdentifier("workflows.run.file")
    }

    private func load() async {
        failed = false
        guard let sha = output.sha256,
              let data = try? await WorkflowArtifactReader.read(client: context.client, runID: model.runID, sha256: sha) else {
            failed = true
            return
        }
        text = String(decoding: data, as: UTF8.self)
    }

    private func share(_ text: String) {
        let name = WorkflowSignoff.fileName(output)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? Data(text.utf8).write(to: url, options: .atomic)
        UsageShareSheet.present(url, title: name)
    }
}

extension WorkflowRunDetail {
    /// The newest output a reference names (`draft.draft`).
    func output(_ reference: String) -> WorkflowOutput? {
        let parts = reference.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return outputs.filter { $0.stageKey == parts[0] && $0.name == parts[1] }.max { $0.iteration < $1.iteration }
    }
}
