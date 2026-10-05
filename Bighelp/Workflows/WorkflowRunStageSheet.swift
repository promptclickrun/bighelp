import SwiftUI

/// Which stage of a run is open in `WorkflowRunStageSheet`.
struct WorkflowStageSelection: Identifiable, Hashable {
    let id: String
}

/// One stage of a run, live or finished: how it ended, who decided, what it
/// read and what it made. Tap a file to read it; tap a parallel block's agent
/// to open it.
struct WorkflowRunStageSheet: View {
    let model: WorkflowRunModel
    let context: WorkflowsContext
    let stageKey: String

    var body: some View {
        NavigationStack {
            WorkflowRunStagePage(model: model, context: context, stageKey: stageKey, isRoot: true)
                .navigationDestination(for: WorkflowStageSelection.self) { selection in
                    WorkflowRunStagePage(model: model, context: context, stageKey: selection.id, isRoot: false)
                }
        }
        .accessibilityIdentifier("workflows.run.stage-sheet")
    }
}

/// The page of one stage in `WorkflowRunStageSheet`.
struct WorkflowRunStagePage: View {
    let model: WorkflowRunModel
    let context: WorkflowsContext
    let stageKey: String
    let isRoot: Bool
    @State private var opened: WorkflowOutput?
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    private var detail: WorkflowRunDetail? { model.detail }
    private var stage: WorkflowRunStage? { detail?.stages.first { $0.key == stageKey } }

    var body: some View {
            Form {
                if let detail, let stage {
                    Section { header(stage) }
                    if let outcome = stage.outcome { ending(outcome, note: stage.outcomeNote) }
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
                if isRoot {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .bighelpDefaultAction()
                    }
                }
            }
            .sheet(item: $opened) { output in
                WorkflowRunFileSheet(model: model, context: context, output: output)
                    .bighelpSheetSize(.large)
            }
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
        case .decision where stage.uses.count > 1:
            Section("Verdicts") {
                ForEach(stage.uses, id: \.self) { reference in
                    let decided = detail.output(reference)
                    let producer = detail.stages.first { $0.key == decided?.stageKey }
                    row(context.agentName(producer?.agentID) ?? producer?.title ?? reference,
                        Self.decisionWords(decided?.value?.displayText))
                }
            }
            .accessibilityIdentifier("workflows.run.stage.verdicts")
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
        case .parallel:
            Section {
                ForEach(detail.stages.filter { $0.group == stage.key }) { agent in
                    NavigationLink(value: WorkflowStageSelection(id: agent.key)) {
                        HStack(spacing: BighelpTokens.space12) {
                            WorkflowStageIcon(kind: .agent, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.title).font(.bighelp(.body))
                                Text(context.agentName(agent.agentID) ?? "An agent")
                                    .font(.bighelp(.caption))
                                    .foregroundStyle(theme.secondaryText)
                            }
                            Spacer(minLength: 0)
                            Label(agent.state.title, systemImage: agent.state == .planned ? "circle" : agent.state.symbol)
                                .font(.bighelp(.caption).weight(.semibold))
                                .foregroundStyle(agent.state == .planned ? theme.tertiaryText : agent.state.color(theme))
                        }
                        .frame(minHeight: BighelpTokens.hitTarget)
                    }
                    .accessibilityIdentifier("workflows.run.stage.agent.\(agent.key)")
                }
            } header: {
                Text("Agents at the same time")
            } footer: {
                Text("The workflow goes on when every one is done.")
                    .font(.bighelp(.footnote))
            }
        case .check:
            Section("Check") {
                row("Result", stage.state == .accepted ? "Passed"
                    : stage.state == .planned ? "Not checked yet" : stage.state.title)
            }
        case .delivery:
            Section("Delivery") {
                row("Result", stage.state == .accepted ? "Sent"
                    : stage.state == .planned ? "Not sent yet" : stage.state.title)
                if let said = model.events.last(where: { $0.stageKey == stage.key && $0.kind == "delivered" }) {
                    row("What happened", said.text)
                }
            }
            .accessibilityIdentifier("workflows.run.stage.delivery")
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

    /// A decision that ended the run, and why.
    private func ending(_ outcome: WorkflowStage.Ending.Outcome, note: String?) -> some View {
        Section("How the run ended") {
            Label(outcome.title, systemImage: outcome.symbol)
                .font(.bighelp(.body).weight(.semibold))
                .foregroundStyle(outcome == .failed ? theme.danger : outcome == .succeeded ? theme.success
                                 : theme.secondaryText)
            if let note, !note.isEmpty {
                Text(note).font(.bighelp(.body)).textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("workflows.run.stage.outcome")
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
        if output.isFile || output.isAttachment {
            Button { opened = output } label: {
                HStack(spacing: BighelpTokens.space12) {
                    Image(systemName: output.isImage ? "photo" : output.isAttachment ? "doc" : "doc.text")
                        .foregroundStyle(theme.action)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label.map { "\($0): \(name)" } ?? name)
                            .font(.bighelp(.body))
                            .foregroundStyle(theme.primaryText)
                        if let words = output.wordCount {
                            Text("\(words.formatted()) words")
                                .font(.bighelp(.caption))
                                .foregroundStyle(theme.secondaryText)
                        } else if output.isAttachment {
                            Text([output.fileName, output.bytes.map {
                                ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
                            }].compactMap { $0 }.joined(separator: " · "))
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
    @State private var data: Data?
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if let text {
                        WorkflowDocumentView(text: text)
                    } else if let data {
                        WorkflowAttachmentView(output: output, data: data)
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
                if let shared = text.map({ Data($0.utf8) }) ?? data {
                    ToolbarItem(placement: .primaryAction) {
                        Button { share(shared) } label: { Image(systemName: "square.and.arrow.up") }
                            .bighelpIconLabel("Share")
                            .accessibilityIdentifier("workflows.run.file.share")
                    }
                }
            }
        }
        .task { if text == nil && data == nil { await load() } }
        .accessibilityIdentifier("workflows.run.file")
    }

    private func load() async {
        failed = false
        guard let sha = output.sha256,
              let data = try? await WorkflowArtifactReader.read(client: context.client, runID: model.runID, sha256: sha) else {
            failed = true
            return
        }
        if output.isAttachment {
            self.data = data
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
    }

    private func share(_ data: Data) {
        let name = WorkflowSignoff.fileName(output)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? data.write(to: url, options: .atomic)
        UsageShareSheet.present(url, title: name)
    }
}

/// A file or picture an agent handed off: the picture itself, or the file's name and size to share.
struct WorkflowAttachmentView: View {
    let output: WorkflowOutput
    let data: Data
    @BighelpThemeReader private var theme

    var body: some View {
        if output.isImage, let picture = UIImage(data: data) {
            Image(uiImage: picture)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous))
                .accessibilityLabel(output.fileName ?? output.name)
                .accessibilityIdentifier("workflows.run.file.image")
        } else {
            VStack(spacing: BighelpTokens.space12) {
                Image(systemName: "doc")
                    .font(.system(size: 48))
                    .foregroundStyle(theme.action)
                Text(output.fileName ?? output.name)
                    .font(.bighelp(.headline))
                Text([output.mimeType, ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.secondaryText)
                Text("Share it to open it in another app or save it to Files.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("workflows.run.file.attachment")
        }
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
