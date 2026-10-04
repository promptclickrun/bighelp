import SwiftUI
import UniformTypeIdentifiers

/// Opens one run with its own model, which polls only while it's on screen.
struct WorkflowRunScreen: View {
    let context: WorkflowsContext
    @State private var model: WorkflowRunModel

    init(context: WorkflowsContext, runID: String) {
        self.context = context
        _model = State(initialValue: WorkflowRunModel(runID: runID, client: context.client))
    }

    var body: some View {
        WorkflowRunView(model: model, context: context)
            .onAppear { model.setOnScreen(true) }
            .onDisappear { model.setOnScreen(false) }
    }
}

/// One run: where it is, each stage's time, what it made, and Cancel or Try
/// again. Token counts, attempts and the raw events log are Nerd Mode only.
struct WorkflowRunView: View {
    let model: WorkflowRunModel
    let context: WorkflowsContext
    @BighelpThemeReader private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                if let detail = model.detail {
                    WorkflowRunContent(model: model, context: context, detail: detail, showsGraph: false)
                } else {
                    WorkflowLoadStateView(state: model.state) { Task { await model.load() } }
                }
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.top, BighelpTokens.space8)
            .padding(.bottom, BighelpTokens.space48)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workflows.run")
        }
        .scrollIndicators(.hidden)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .navigationTitle(model.summary.map { "Run \($0.number)" } ?? "Run")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .refreshable { await model.load() }
    }
}

/// The run's page body, shared by the run page and the Mac monitor's middle column.
struct WorkflowRunContent: View {
    let model: WorkflowRunModel
    let context: WorkflowsContext
    let detail: WorkflowRunDetail
    var showsGraph: Bool
    @State private var isConfirmingCancel = false
    @State private var exporting: (name: String, data: Data)?
    @State private var shareURL: URL?
    @BighelpThemeReader private var theme

    private var run: WorkflowRunSummary { detail.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            BighelpDeferredSection { header }
            if let message = model.message {
                Label(message, systemImage: "info.circle")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.warning)
                    .accessibilityIdentifier("workflows.run.message")
            }
            BighelpDeferredSection { banner }
            // The monitor shows the stages as a graph; the page lists them.
            if showsGraph {
                BighelpDeferredSection { graph }
            } else {
                BighelpDeferredSection { stageRail }
            }
            if let current = currentStage, run.state.isWorking {
                BighelpDeferredSection { currentStageCard(current) }
            }
            BighelpDeferredSection { files }
            if context.isNerdMode, !model.events.isEmpty || detail.stages.contains(where: { !$0.attempts.isEmpty }) {
                BighelpDeferredSection { nerdDetails }
            }
            Text("Runs keep going when you close the app.")
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.tertiaryText)
        }
        .confirmationDialog("Cancel this run?", isPresented: $isConfirmingCancel, titleVisibility: .visible) {
            Button("Cancel run", role: .destructive) { Task { await model.perform(.cancel) } }
                .accessibilityIdentifier("workflows.run.cancel.confirm")
            Button("Keep it running", role: .cancel) {}
        } message: {
            Text("The stage that's running stops. What's done so far stays on \(context.hostName).")
        }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: ChatAttachmentDocument(data: exporting?.data ?? Data()),
                      contentType: UTType(filenameExtension: "md") ?? .plainText,
                      defaultFilename: exporting?.name) { _ in exporting = nil }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text(run.workflowName)
                .font(.bighelp(.title2).weight(.bold))
                .foregroundStyle(theme.primaryText)
            WorkflowStatePill(state: run.state)
            Text(headerLine)
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .accessibilityIdentifier("workflows.run.line")
            HStack(spacing: BighelpTokens.space8) {
                if model.canDo(.retry) {
                    Button { Task { await model.perform(.retry) } } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                    }
                    .workflowProminent(theme)
                    .accessibilityIdentifier("workflows.run.retry")
                }
                if model.canDo(.cancel) {
                    Button("Cancel run", role: .destructive) { isConfirmingCancel = true }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("workflows.run.cancel")
                }
            }
            .font(.bighelp(.subheadline).weight(.semibold))
            .controlSize(.large)
            .disabled(model.isWorking)
        }
    }

    private var headerLine: String {
        var parts = ["Run \(run.number)"]
        if let revision = run.revision { parts.append("rev \(revision)") }
        if let started = run.startedAt {
            parts.append("started \(started.formatted(date: .omitted, time: .shortened))")
            if run.state.isWorking { parts.append(WorkflowWords.duration(Date.now.timeIntervalSince(started))) }
        }
        if context.isNerdMode, detail.tokens.total > 0 {
            parts.append("\(detail.tokens.total.formatted(.number.notation(.compactName))) tokens")
        }
        if run.stageCount > 0 { parts.append("\(run.stagesDone) of \(run.stageCount) stages done") }
        return parts.joined(separator: " · ")
    }

    // MARK: Banner

    @ViewBuilder
    private var banner: some View {
        if run.state == .waitingForYou {
            HStack(spacing: BighelpTokens.space12) {
                WorkflowStageIcon(kind: .signoff, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waiting for your sign-off")
                        .font(.bighelp(.headline))
                    Text("No agent is running while it waits.")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
                Button("Review") { context.open(.workflowSignoff(runID: run.id)) }
                    .workflowProminent(theme)
                    .font(.bighelp(.body).weight(.semibold))
                    .bighelpDefaultAction()
                    .accessibilityIdentifier("workflows.run.review")
            }
            .workflowCard(theme)
        } else if let problem = run.attention ?? run.failure {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Label(run.state == .failed ? run.stateLine : "Needs attention",
                      systemImage: run.state.symbol)
                    .font(.bighelp(.headline))
                    .foregroundStyle(run.state.color(theme))
                Text(problem.message)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if run.state == .needsAttention {
                    Text("Nothing tries again by itself. Try again starts a new attempt; the old one stays on the record.")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .workflowCard(theme)
            .accessibilityIdentifier("workflows.run.problem")
        }
    }

    // MARK: Stages

    private var graph: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            WorkflowGraph(nodes: detail.stages.map { stage in
                WorkflowGraph.Node(id: stage.key, kind: stage.kind, title: stage.title,
                                   detail: stageTime(stage), state: stage.state)
            }, loop: nil)
            .padding(BighelpTokens.space16)
        }
        .workflowCard(theme, padding: 0)
    }

    private var currentStage: WorkflowRunStage? {
        detail.stages.first { $0.key == run.stageKey }
    }

    private var stageRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(detail.stages.enumerated()), id: \.element.key) { index, stage in
                HStack(alignment: .top, spacing: BighelpTokens.space12) {
                    VStack(spacing: 0) {
                        Image(systemName: stage.state == .planned ? "circle" : stage.state.symbol)
                            .font(.bighelp(.body).weight(.semibold))
                            .foregroundStyle(stage.state == .planned ? theme.tertiaryText : stage.state.color(theme))
                            .frame(width: 24, height: 24)
                        if index < detail.stages.count - 1 {
                            Rectangle().fill(theme.border).frame(width: 1).frame(maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stage.iteration > 1 && stage.kind == .agent ? "\(stage.title) v\(stage.iteration)" : stage.title)
                            .font(.bighelp(.subheadline).weight(stage.key == run.stageKey ? .semibold : .regular))
                            .foregroundStyle(stage.state == .planned ? theme.secondaryText : theme.primaryText)
                        if let agent = context.agentName(stage.agentID) {
                            Text(agent)
                                .font(.bighelp(.caption))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .padding(.bottom, BighelpTokens.space12)
                    Spacer(minLength: BighelpTokens.space8)
                    Text(stageTime(stage))
                        .font(.bighelp(.caption).monospacedDigit())
                        .foregroundStyle(stage.state.isWorking && stage.state != .accepted
                                         ? stage.state.color(theme) : theme.tertiaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("workflows.run.stage.\(stage.key)")
            }
        }
        .workflowCard(theme)
    }

    private func stageTime(_ stage: WorkflowRunStage) -> String {
        switch stage.state {
        case .planned: return "planned"
        case .running, .launched, .checkingOutput:
            let verb = stage.state == .checkingOutput ? "checking" : "running"
            guard let started = stage.attempts.last?.launchedAt ?? stage.startedAt else { return verb }
            return "\(verb) \(WorkflowWords.duration(Date.now.timeIntervalSince(started)))"
        case .waitingForYou: return "you"
        default:
            // `minutes` is the stage's time limit, not how long it took.
            if let started = stage.startedAt, let ended = stage.endedAt, ended > started {
                return WorkflowWords.duration(ended.timeIntervalSince(started))
            }
            if let ms = stage.attempts.last?.durationMs { return WorkflowWords.duration(Double(ms) / 1_000) }
            return stage.state.title.lowercased()
        }
    }

    private func currentStageCard(_ stage: WorkflowRunStage) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack(alignment: .firstTextBaseline) {
                Text(stage.title)
                    .font(.bighelp(.headline))
                Text([context.isNerdMode ? stage.attempts.last.map { "attempt \($0.number)" } : nil,
                      context.agentName(stage.agentID),
                      stage.minutes.map { "\(Int($0)) min limit" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
            }
            WorkflowStepLine(state: stage.state)
        }
        .workflowCard(theme)
        .accessibilityIdentifier("workflows.run.current")
    }

    // MARK: Files

    @ViewBuilder
    private var files: some View {
        let files = detail.outputs.filter(\.isFile)
        if !files.isEmpty || detail.approvedFile != nil {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                Text(run.state == .succeeded ? "Approved file" : "Files so far")
                    .font(.bighelp(.headline))
                if let approved = detail.approvedFile {
                    HStack(spacing: BighelpTokens.space12) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(theme.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(WorkflowSignoff.fileName(approved))
                                .font(.bighelp(.subheadline).monospaced())
                            Text("Approved by you. Nothing was published.")
                                .font(.bighelp(.caption))
                                .foregroundStyle(theme.secondaryText)
                        }
                        Spacer(minLength: 0)
                        Button { share() } label: { Image(systemName: "square.and.arrow.up") }
                            .bighelpIconLabel("Share")
                            .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                            .accessibilityIdentifier("workflows.run.share")
                        Button { saveToFiles() } label: { Image(systemName: "folder") }
                            .bighelpIconLabel("Save to Files")
                            .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                            .accessibilityIdentifier("workflows.run.save")
                    }
                } else {
                    ForEach(files) { file in
                        HStack {
                            Image(systemName: "doc.text").foregroundStyle(theme.secondaryText)
                            Text("\(file.stageKey).\(file.name)\(file.iteration > 1 ? " v\(file.iteration)" : "")")
                                .font(.bighelp(.footnote).monospaced())
                            Spacer()
                            if let words = file.wordCount {
                                Text("\(words.formatted()) words")
                                    .font(.bighelp(.caption))
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                    }
                }
            }
            .workflowCard(theme)
            .accessibilityIdentifier("workflows.run.files")
        }
    }

    private func share() {
        Task {
            guard let file = await model.approvedFile() else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
            try? file.data.write(to: url, options: .atomic)
            UsageShareSheet.present(url, title: file.name)
        }
    }

    private func saveToFiles() {
        Task { exporting = await model.approvedFile() }
    }

    // MARK: Nerd Mode

    private var nerdDetails: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text("Details")
                .font(.bighelp(.headline))
            ForEach(detail.stages.filter { !$0.attempts.isEmpty }) { stage in
                ForEach(stage.attempts) { attempt in
                    HStack {
                        Text("\(stage.key) #\(attempt.number)")
                            .font(.bighelp(.caption).monospaced())
                        Spacer()
                        Text("\(attempt.state.rawValue) · \(attempt.tokens.input.formatted()) in · \(attempt.tokens.output.formatted()) out\(attempt.outcomeCode.map { " · \($0)" } ?? "")")
                            .font(.bighelp(.caption).monospaced())
                            .foregroundStyle(theme.secondaryText)
                    }
                }
            }
            if !model.events.isEmpty {
                Divider()
                Text("Events")
                    .font(.bighelp(.subheadline).weight(.semibold))
                ForEach(model.events.suffix(50).reversed()) { event in
                    HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                        Text(event.at?.formatted(date: .omitted, time: .standard) ?? "")
                            .font(.bighelp(.caption).monospacedDigit())
                            .foregroundStyle(theme.tertiaryText)
                        Text(event.text)
                            .font(.bighelp(.caption))
                    }
                }
            }
        }
        .workflowCard(theme)
        .accessibilityIdentifier("workflows.run.nerd")
    }
}

/// Planned → Launched → Running → Checking output → Accepted, with the current step lit.
struct WorkflowStepLine: View {
    let state: WorkflowRunState
    @BighelpThemeReader private var theme

    private static let steps: [(WorkflowRunState, String)] = [
        (.planned, "Planned"), (.launched, "Launched"), (.running, "Running"),
        (.checkingOutput, "Checking output"), (.accepted, "Accepted"),
    ]

    var body: some View {
        let current = Self.steps.firstIndex { $0.0 == state } ?? 0
        ViewThatFits(in: .horizontal) {
            HStack(spacing: BighelpTokens.space8) { items(current: current) }
            VStack(alignment: .leading, spacing: BighelpTokens.space4) { items(current: current) }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func items(current: Int) -> some View {
        ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
            Label(step.1, systemImage: index < current ? "checkmark" : index == current ? "circle.dotted.circle" : "circle")
                .font(.bighelp(.caption).weight(index == current ? .semibold : .regular))
                .foregroundStyle(index < current ? theme.success : index == current ? theme.information : theme.tertiaryText)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
