import SwiftUI

/// The workflow canvas (iPad and Mac, regular width): every stage left to
/// right at fixed places with the review loop above, and the selected stage's
/// details in an inspector inside the page. Read-only in this version: Edit
/// opens the same stage editor as iPhone.
struct WorkflowCanvasView: View {
    @Bindable var model: WorkflowEditorModel
    let context: WorkflowsContext
    let startsRun: Bool
    @State private var selected: String?
    @State private var editing: WorkflowStage?
    @State private var inspectorTab: WorkflowStageEditor.Tab = .setup
    @State private var isRunSheetPresented = false
    @State private var didOfferRun = false
    @BighelpThemeReader private var theme

    private var definition: WorkflowDefinition? { model.definition }
    private var selectedStage: WorkflowStage? { definition?.stage(selected) }

    var body: some View {
        Group {
            if let definition {
                HStack(spacing: 0) {
                    BighelpDeferredSection { canvas(definition) }
                    if selectedStage != nil {
                        Divider().overlay(theme.separator)
                        BighelpDeferredSection { inspector }
                            .frame(width: 340)
                            .transition(.move(edge: .trailing))
                    }
                }
            } else {
                WorkflowLoadStateView(state: model.state) { Task { await model.load() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflows.canvas")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { WorkflowTitle(model: model) }
            ToolbarItem(placement: .topBarTrailing) {
                Button { isRunSheetPresented = true } label: {
                    Label("Run", systemImage: "play.fill")
                        .bighelpToolbarText()
                }
                .disabled(!model.canRun)
                .accessibilityIdentifier("workflows.canvas.run")
            }
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
            guard loaded else { return }
            if selected == nil { selected = model.definition?.stages.first { $0.kind == .agent }?.key }
            if startsRun, !didOfferRun {
                didOfferRun = true
                if model.canRun { isRunSheetPresented = true }
            }
        }
        .animation(.snappy, value: selected)
    }

    // MARK: Canvas

    private func canvas(_ definition: WorkflowDefinition) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space20) {
            if !model.unboundRoles.isEmpty {
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    Text(model.unboundRoles.count == 1 ? "1 role needs an agent" : "\(model.unboundRoles.count) roles need an agent")
                        .font(.bighelp(.headline))
                        .foregroundStyle(theme.warning)
                    ForEach(definition.roles) { role in
                        WorkflowRolePicker(model: model, context: context, role: role)
                    }
                }
                .workflowCard(theme)
                .frame(maxWidth: 420)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                WorkflowGraph(nodes: nodes(definition), loop: loop(definition), selected: selected) { key in
                    selected = key == "inputs" ? nil : key
                }
                .padding(BighelpTokens.space24)
            }
            HStack(alignment: .top, spacing: BighelpTokens.space16) {
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text("Publishing stays manual.")
                        .font(.bighelp(.subheadline).weight(.semibold))
                    Text("After sign-off the approved file comes to you. No stage in this flow publishes anything.")
                        .font(.bighelp(.footnote))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(theme.primaryText)
                .padding(BighelpTokens.space12)
                .frame(maxWidth: 320, alignment: .leading)
                .background(BighelpTokens.Palette.gold.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous))
                if let issues = model.validation?.issues, !issues.isEmpty {
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        ForEach(issues) { issue in
                            Label(issue.message, systemImage: issue.isError ? "xmark.octagon" : "exclamationmark.triangle")
                                .font(.bighelp(.footnote))
                                .foregroundStyle(issue.isError ? theme.danger : theme.warning)
                        }
                    }
                }
            }
            .padding(.horizontal, BighelpTokens.space24)
            Spacer(minLength: 0)
            Text("One stage at a time · \(definition.stageMinutes) min per stage · Nothing runs until you tap Run")
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, BighelpTokens.space16)
                .padding(.vertical, BighelpTokens.space8)
                .background(theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.border))
                .frame(maxWidth: .infinity)
                .padding(.bottom, BighelpTokens.space16)
        }
        .padding(.top, BighelpTokens.space16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func nodes(_ definition: WorkflowDefinition) -> [WorkflowGraph.Node] {
        [WorkflowGraph.Node(id: "inputs", kind: nil, title: "Inputs",
                            detail: definition.inputs.count == 1 ? "1 field" : "\(definition.inputs.count) fields")]
            + definition.stages.map { stage in
                let detail: String
                switch stage.kind {
                case .agent: detail = context.agentName(model.agentID(for: stage.role)) ?? stage.role ?? ""
                case .check: detail = stage.rules.count == 1 ? "1 rule" : "\(stage.rules.count) rules"
                case .decision: detail = stage.on ?? ""
                case .signoff: detail = "you"
                case .unknown: detail = ""
                }
                return WorkflowGraph.Node(id: stage.key, kind: stage.kind, title: stage.title, detail: detail)
            }
    }

    private func loop(_ definition: WorkflowDefinition) -> (from: String, to: String, label: String)? {
        guard let decision = definition.stages.first(where: { $0.kind == .decision && $0.changesGoTo != nil }),
              let goTo = decision.changesGoTo else { return nil }
        return (decision.key, goTo, "revise · max \(decision.changesMaxRevisions ?? definition.maxRevisions)")
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        if let stage = selectedStage {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                    HStack(spacing: BighelpTokens.space12) {
                        WorkflowStageIcon(kind: stage.kind, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stage.title).font(.bighelp(.headline))
                            Text([stage.kind.title, stage.role.map { "role \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.bighelp(.caption))
                                .foregroundStyle(theme.secondaryText)
                        }
                        Spacer(minLength: 0)
                        Button { selected = nil } label: {
                            Image(systemName: "xmark")
                                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                                .contentShape(Rectangle())
                        }
                        .bighelpPlainButtonStyle()
                        .bighelpIconLabel("Close")
                    }
                    Picker("Part", selection: $inspectorTab) {
                        ForEach(WorkflowStageEditor.Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .bighelpSegmentedPicker()
                    inspectorBody(stage)
                    Button { editing = stage } label: {
                        Text("Edit stage")
                            .font(.bighelp(.body).weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget - 8)
                    }
                    .workflowProminent(theme)
                    .accessibilityIdentifier("workflows.canvas.edit")
                }
                .padding(BighelpTokens.space20)
            }
            .background(theme.surface.opacity(0.5))
            .accessibilityIdentifier("workflows.canvas.inspector")
        }
    }

    @ViewBuilder
    private func inspectorBody(_ stage: WorkflowStage) -> some View {
        switch inspectorTab {
        case .setup:
            if stage.kind == .agent {
                inspectorLabel("Agent")
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    Text(context.agentName(model.agentID(for: stage.role)) ?? "No agent yet")
                        .font(.bighelp(.body).weight(.semibold))
                    if !stage.tools.isEmpty { WorkflowChips(items: stage.tools) }
                    if stage.hasBroadTools {
                        Text("Broad tools. Instructions can't make this stage read-only.")
                            .font(.bighelp(.footnote).weight(.semibold))
                            .foregroundStyle(theme.warning)
                    }
                }
                .workflowCard(theme, padding: BighelpTokens.space12)
                inspectorLabel("Instructions")
                Text(stage.instructions.isEmpty ? "None yet." : stage.instructions)
                    .font(.bighelp(.body))
                    .workflowCard(theme, padding: BighelpTokens.space12)
                if !stage.uses.isEmpty {
                    inspectorLabel("Uses from earlier stages")
                    WorkflowChips(items: stage.uses, monospaced: true)
                }
            } else if stage.kind == .check {
                inspectorLabel("Checks")
                WorkflowChips(items: stage.rules.map(\.summary))
            } else if stage.kind == .decision {
                inspectorLabel("Reads")
                Text(stage.on ?? "").font(.bighelp(.body).monospaced())
                inspectorLabel("Changes go back to")
                Text(definition?.stage(stage.changesGoTo)?.title ?? "")
            } else {
                Text("The run waits for you here, with no agent running.")
                    .font(.bighelp(.body))
            }
        case .output:
            inspectorLabel("Must hand off")
            VStack(spacing: 0) {
                ForEach(stage.outputs) { output in
                    HStack {
                        Text(output.name).font(.bighelp(.callout).monospaced())
                        Spacer()
                        Text(output.typeTitle).font(.bighelp(.footnote)).foregroundStyle(theme.secondaryText)
                    }
                    .padding(BighelpTokens.space12)
                }
                if stage.outputs.isEmpty {
                    Text("Nothing.").foregroundStyle(theme.secondaryText).padding(BighelpTokens.space12)
                }
            }
            .workflowCard(theme, padding: 0)
        case .limits:
            inspectorLabel("Time limit")
            Text("\(stage.minutes ?? definition?.stageMinutes ?? 20) min")
            if stage.kind == .decision {
                inspectorLabel("Rounds of changes")
                Text("\(stage.changesMaxRevisions ?? definition?.maxRevisions ?? 2)")
            }
        }
    }

    private func inspectorLabel(_ text: String) -> some View {
        Text(text)
            .font(.bighelp(.subheadline).weight(.semibold))
            .foregroundStyle(theme.secondaryText)
    }
}
