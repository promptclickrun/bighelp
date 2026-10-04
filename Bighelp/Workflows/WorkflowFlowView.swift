import SwiftUI

/// Opens one workflow: the vertical flow on iPhone, the canvas at regular width.
struct WorkflowScreen: View {
    let context: WorkflowsContext
    let startsRun: Bool
    @State private var model: WorkflowEditorModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(context: WorkflowsContext, workflowID: String, startsRun: Bool) {
        self.context = context
        self.startsRun = startsRun
        let hasDraft = context.store.workflows.first { $0.id == workflowID }?.hasDraft ?? false
        _model = State(initialValue: WorkflowEditorModel(workflowID: workflowID, client: context.client, hasDraft: hasDraft))
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                WorkflowCanvasView(model: model, context: context, startsRun: startsRun)
            } else {
                WorkflowFlowView(model: model, context: context, startsRun: startsRun)
            }
        }
        .task { if model.detail == nil { await model.load() } }
    }
}

/// Build the flow (iPhone): inputs, then each stage top to bottom, with the
/// review loop drawn beside them. Tap a stage to change it; Run starts one run.
struct WorkflowFlowView: View {
    @Bindable var model: WorkflowEditorModel
    let context: WorkflowsContext
    let startsRun: Bool
    @State private var editing: WorkflowStage?
    @State private var isRunSheetPresented = false
    @State private var didOfferRun = false
    @BighelpThemeReader private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                if model.definition == nil {
                    WorkflowLoadStateView(state: model.state) { Task { await model.load() } }
                } else {
                    if !model.unboundRoles.isEmpty { BighelpDeferredSection { rolesCard } }
                    BighelpDeferredSection { flow }
                    BighelpDeferredSection { issues }
                }
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.top, BighelpTokens.space8)
            .padding(.bottom, 120)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workflows.flow")
        }
        .scrollIndicators(.hidden)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { if model.definition != nil { bottomBar } }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { WorkflowTitle(model: model) }
            ToolbarItem(placement: .topBarTrailing) { WorkflowMoreMenu(model: model, context: context) }
        }
        .sheet(item: $editing) { stage in
            WorkflowStageEditor(model: model, context: context, stage: stage)
                .bighelpSheetSize(.large)
        }
        .sheet(isPresented: $isRunSheetPresented) {
            WorkflowRunSheet(model: model, context: context)
                .bighelpSheetSize(.standard)
        }
        .alert("Workflow", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
        .onChange(of: model.definition != nil, initial: true) { _, loaded in
            guard loaded, startsRun, !didOfferRun else { return }
            didOfferRun = true
            if model.canRun { isRunSheetPresented = true }
        }
    }

    // MARK: Roles

    private var rolesCard: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Text(model.unboundRoles.count == 1 ? "1 role needs an agent" : "\(model.unboundRoles.count) roles need an agent")
                .font(.bighelp(.headline))
                .foregroundStyle(theme.warning)
            ForEach(model.definition?.roles ?? []) { role in
                WorkflowRolePicker(model: model, context: context, role: role)
            }
        }
        .workflowCard(theme)
        .accessibilityIdentifier("workflows.flow.roles")
    }

    // MARK: Flow

    private var stages: [WorkflowStage] { model.definition?.stages ?? [] }

    private var flow: some View {
        VStack(spacing: 0) {
            inputsNode
            ForEach(Array(stages.enumerated()), id: \.element.key) { index, stage in
                connector(after: index == 0 ? nil : stages[index - 1], before: stage)
                stageNode(stage)
            }
            Rectangle().fill(theme.border).frame(width: 1, height: 16)
            Button { addStage(after: stages.last?.key) } label: {
                Image(systemName: "plus")
                    .font(.bighelp(.body).weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .overlay {
                        RoundedRectangle(cornerRadius: BighelpTokens.radius12)
                            .strokeBorder(theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    .contentShape(Rectangle())
            }
            .bighelpPlainButtonStyle()
            .bighelpIconLabel("Add a stage at the end")
            .accessibilityIdentifier("workflows.flow.add-end")
        }
        .padding(.trailing, hasLoop ? 44 : 0)
        .overlayPreferenceValue(WorkflowNodeFrames.self) { anchors in
            GeometryReader { proxy in loopOverlay(anchors: anchors, proxy: proxy) }
        }
        .frame(maxWidth: .infinity)
    }

    private var inputsNode: some View {
        HStack(spacing: BighelpTokens.space12) {
            WorkflowInputsIcon()
            VStack(alignment: .leading, spacing: 2) {
                Text("Inputs")
                    .font(.bighelp(.headline))
                Text((model.definition?.inputs ?? []).map(\.key).joined(separator: " · "))
                    .font(.bighelp(.caption).monospaced())
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .workflowCard(theme, padding: BighelpTokens.space12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workflows.flow.inputs")
    }

    @ViewBuilder
    private func connector(after previous: WorkflowStage?, before stage: WorkflowStage) -> some View {
        if previous?.kind == .decision {
            // The decision's "pass" leads on.
            HStack(spacing: BighelpTokens.space8) {
                Rectangle().fill(theme.border).frame(width: 1, height: 28)
                Text("pass")
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.secondaryText)
            }
            .offset(x: 14)
        } else if stage.kind == .decision {
            Rectangle().fill(theme.border).frame(width: 1, height: 28)
        } else {
            VStack(spacing: 0) {
                Rectangle().fill(theme.border).frame(width: 1, height: 8)
                Button { addStage(after: previous?.key) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 22, height: 22)
                        .background(theme.surface, in: Circle())
                        .overlay(Circle().strokeBorder(theme.border))
                        .frame(width: BighelpTokens.hitTarget, height: 28)
                        .contentShape(Rectangle())
                }
                .bighelpPlainButtonStyle()
                .bighelpIconLabel("Add a stage before \(stage.title)")
                Rectangle().fill(theme.border).frame(width: 1, height: 8)
            }
        }
    }

    private func stageNode(_ stage: WorkflowStage) -> some View {
        let isDecision = stage.kind == .decision
        return Button { editing = stage } label: {
            HStack(spacing: BighelpTokens.space12) {
                WorkflowStageIcon(kind: stage.kind, size: isDecision ? 30 : 36,
                                  isDashed: stage.kind == .agent && model.agentID(for: stage.role) == nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stage.title)
                        .font(.bighelp(isDecision ? .subheadline : .headline))
                        .foregroundStyle(theme.primaryText)
                    Text(stage.subtitle { context.agentName(model.agentID(for: $0)) })
                        .font(.bighelp(.caption).monospaced())
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !isDecision {
                    Image(systemName: "chevron.right")
                        .font(.bighelp(.footnote).weight(.semibold))
                        .foregroundStyle(theme.tertiaryText)
                }
            }
            .padding(isDecision ? BighelpTokens.space8 : BighelpTokens.space12)
            .frame(maxWidth: isDecision ? 220 : .infinity, alignment: .leading)
            .background(isDecision ? BighelpTokens.Palette.gold.opacity(0.1) : theme.surface,
                        in: RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)
                    .strokeBorder(isDecision ? BighelpTokens.Palette.gold.opacity(0.4) : issueColor(stage) ?? theme.border,
                                  lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .bighelpPlainButtonStyle()
        .anchorPreference(key: WorkflowNodeFrames.self, value: .bounds) { [stage.key: $0] }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editing = stage }
            Button("Add a stage after", systemImage: "plus") { addStage(after: stage.key) }
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.deleteStage(stage.key)
                Task { await model.save() }
            }
        }
        .accessibilityIdentifier("workflows.flow.stage.\(stage.key)")
    }

    private func issueColor(_ stage: WorkflowStage) -> Color? {
        guard let issues = model.validation?.issues.filter({ $0.stageKey == stage.key }), !issues.isEmpty else { return nil }
        return issues.contains(where: \.isError) ? theme.danger : nil
    }

    private var loopStage: WorkflowStage? { stages.first { $0.kind == .decision && $0.changesGoTo != nil } }
    private var hasLoop: Bool { loopStage != nil }

    @ViewBuilder
    private func loopOverlay(anchors: [String: Anchor<CGRect>], proxy: GeometryProxy) -> some View {
        if let decision = loopStage, let goTo = decision.changesGoTo,
           let from = anchors[decision.key], let to = anchors[goTo] {
            let start = proxy[from]
            let end = proxy[to]
            let x = proxy.size.width - 20
            Path { path in
                path.move(to: CGPoint(x: start.maxX, y: start.midY))
                path.addLine(to: CGPoint(x: x, y: start.midY))
                path.addLine(to: CGPoint(x: x, y: end.midY))
                path.addLine(to: CGPoint(x: end.maxX + 4, y: end.midY))
            }
            .stroke(BighelpTokens.Palette.gold, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            Text("max \(decision.changesMaxRevisions ?? model.definition?.maxRevisions ?? 2)")
                .font(.bighelp(.caption2).monospaced())
                .foregroundStyle(BighelpTokens.Palette.gold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(theme.canvas, in: Capsule())
                .overlay(Capsule().strokeBorder(BighelpTokens.Palette.gold.opacity(0.5)))
                .position(x: x, y: (start.midY + end.midY) / 2)
            Text("changes")
                .font(.bighelp(.caption))
                .foregroundStyle(BighelpTokens.Palette.gold)
                .position(x: (start.maxX + x) / 2, y: start.midY + 14)
        }
    }

    // MARK: Issues and Run

    @ViewBuilder
    private var issues: some View {
        if let validation = model.validation, !validation.issues.isEmpty {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                ForEach(validation.issues) { issue in
                    Label(issue.message, systemImage: issue.isError ? "xmark.octagon" : "exclamationmark.triangle")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(issue.isError ? theme.danger : theme.warning)
                }
            }
            .workflowCard(theme, padding: BighelpTokens.space12)
            .accessibilityIdentifier("workflows.flow.issues")
        }
    }

    private var bottomBar: some View {
        HStack(spacing: BighelpTokens.space8) {
            Button { addStage(after: stages.last?.key) } label: {
                Image(systemName: "plus")
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(Rectangle())
            }
            .bighelpPlainButtonStyle()
            .bighelpIconLabel("Add a stage")
            Text("Nothing runs until you tap Run.")
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { isRunSheetPresented = true } label: {
                Label("Run", systemImage: "play.fill")
                    .font(.bighelp(.body).weight(.semibold))
                    .frame(minWidth: 96, minHeight: BighelpTokens.hitTarget - 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canRun)
            .accessibilityIdentifier("workflows.flow.run")
        }
        .padding(BighelpTokens.space8)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius20, style: .continuous).strokeBorder(theme.border)
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.bottom, BighelpTokens.space8)
        .frame(maxWidth: 680)
    }

    private func addStage(after key: String?) {
        if let stage = model.addStage(after: key) { editing = stage }
    }
}

/// The workflow's name, with whether it can run under it.
struct WorkflowTitle: View {
    let model: WorkflowEditorModel
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(spacing: 0) {
            Text(model.name)
                .font(.bighelp(.headline))
                .lineLimit(1)
            if let line = validityLine {
                Label(line.text, systemImage: line.valid ? "checkmark" : "exclamationmark.triangle")
                    .font(.bighelp(.caption))
                    .foregroundStyle(line.valid ? theme.success : theme.warning)
                    .lineLimit(1)
                    .accessibilityIdentifier("workflows.flow.validity")
            }
        }
    }

    private var validityLine: (text: String, valid: Bool)? {
        guard let validation = model.validation, let definition = model.definition else { return nil }
        var parts = [validation.valid ? "Valid" : "Needs fixing",
                     definition.stages.count == 1 ? "1 stage" : "\(definition.stages.count) stages"]
        if let revision = model.detail?.latestRevision {
            parts.append(model.hasUnpublishedDraft || model.isDirty ? "draft of rev \(revision)" : "rev \(revision)")
        } else {
            parts.append("draft")
        }
        return (parts.joined(separator: " · "), validation.valid && model.unboundRoles.isEmpty)
    }
}

/// ⋯ on a workflow: check again, archive.
struct WorkflowMoreMenu: View {
    let model: WorkflowEditorModel
    let context: WorkflowsContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Menu {
            Button("Runs of this workflow", systemImage: "list.bullet") { context.open(.workflowRuns(selected: nil)) }
            if context.isNerdMode {
                Button("Check again", systemImage: "checkmark.seal") { Task { await model.save() } }
            }
            Button("Archive", systemImage: "archivebox", role: .destructive) {
                Task {
                    try? await context.client.archive(workflowID: model.workflowID)
                    await context.store.load()
                    dismiss()
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .bighelpToolbarIcon()
        }
        .bighelpIconLabel("More")
        .accessibilityIdentifier("workflows.flow.more")
    }
}

/// Which agent does one role on this computer.
struct WorkflowRolePicker: View {
    let model: WorkflowEditorModel
    let context: WorkflowsContext
    let role: WorkflowDefinition.Role
    @BighelpThemeReader private var theme

    var body: some View {
        HStack {
            Text(role.label)
                .font(.bighelp(.body))
            Spacer()
            Menu {
                ForEach(context.agents) { agent in
                    Button(agent.name) { Task { await model.bind(role: role.key, agentID: agent.id) } }
                }
                if model.agentID(for: role.key) != nil {
                    Button("No agent", role: .destructive) { Task { await model.bind(role: role.key, agentID: nil) } }
                }
            } label: {
                HStack(spacing: BighelpTokens.space4) {
                    Text(context.agentName(model.agentID(for: role.key)) ?? "Choose an agent")
                    Image(systemName: "chevron.up.chevron.down").font(.bighelp(.caption2))
                }
                .font(.bighelp(.body).weight(.semibold))
                .foregroundStyle(model.agentID(for: role.key) == nil ? theme.action : theme.primaryText)
                .frame(minHeight: BighelpTokens.hitTarget)
            }
            .accessibilityIdentifier("workflows.role.\(role.key)")
        }
    }
}

/// Run: asks for the workflow's inputs, then starts one run on the computer.
struct WorkflowRunSheet: View {
    let model: WorkflowEditorModel
    let context: WorkflowsContext
    @State private var values: [String: String] = [:]
    @State private var isStarting = false
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    private var inputs: [WorkflowDefinition.Input] { model.definition?.inputs ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(inputs) { input in field(input) }
                } footer: {
                    Text("The run happens on \(context.hostName). It keeps going when you close the app, and asks you before anything is final.")
                        .font(.bighelp(.footnote))
                }
            }
            .scrollContentBackground(.hidden)
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle("Run \(model.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") { start() }
                        .disabled(!isComplete || isStarting)
                        .bighelpDefaultAction()
                        .accessibilityIdentifier("workflows.run-sheet.run")
                }
            }
        }
        .onAppear {
            for input in inputs where values[input.key] == nil {
                values[input.key] = input.sample ?? (input.kind == .choice ? input.choices.first : nil) ?? ""
            }
        }
    }

    @ViewBuilder
    private func field(_ input: WorkflowDefinition.Input) -> some View {
        let binding = Binding(get: { values[input.key] ?? "" }, set: { values[input.key] = $0 })
        switch input.kind {
        case .choice:
            Picker(input.label, selection: binding) {
                ForEach(input.choices, id: \.self) { Text($0).tag($0) }
            }
        case .longText:
            VStack(alignment: .leading) {
                Text(input.label).font(.bighelp(.footnote)).foregroundStyle(theme.secondaryText)
                TextEditor(text: binding).frame(minHeight: 120)
            }
        case .number:
            TextField(input.label, text: binding, prompt: Text(input.label).bighelpFieldHint(theme))
                .keyboardType(.numberPad)
        case .text:
            TextField(input.label, text: binding, prompt: Text(input.label).bighelpFieldHint(theme))
                .accessibilityIdentifier("workflows.run-sheet.\(input.key)")
        }
    }

    private var isComplete: Bool {
        inputs.allSatisfy { input in
            let value = (values[input.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if input.kind == .number, !value.isEmpty, Double(value) == nil { return false }
            return !input.required || !value.isEmpty
        }
    }

    private func start() {
        isStarting = true
        var json: WorkflowJSON = [:]
        for input in inputs {
            let value = (values[input.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if input.kind == .number, let number = Double(value) {
                json[input.key] = number.rounded() == number ? .integer(Int(number)) : .number(number)
            } else {
                json[input.key] = .string(String(value.prefix(8_000)))
            }
        }
        Task {
            defer { isStarting = false }
            guard let run = await model.run(inputs: json) else { return }
            dismiss()
            await context.store.load()
            context.openRun(run.id)
        }
    }
}
