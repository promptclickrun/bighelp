import SwiftUI

/// The workflow canvas (iPad, Mac and Vision Pro at regular width): a free,
/// dotted canvas with every node where the person put it and curved wires
/// between them (`WorkflowCanvasBoard`), and the selected stage's details in
/// an inspector inside the page. Older plugins show the flow as it is.
struct WorkflowCanvasView: View {
    @Bindable var model: WorkflowEditorModel
    let context: WorkflowsContext
    let startsRun: Bool
    @State private var selected: String?
    @State private var editing: WorkflowStage?
    @State private var inspectorTab: WorkflowStageEditor.Tab = .setup
    @State private var isRunSheetPresented = false
    @State private var isInputsPresented = false
    @State private var templateSource: WorkflowSummary?
    @State private var didOfferRun = false
    @BighelpThemeReader private var theme

    private var definition: WorkflowDefinition? { model.definition }
    private var selectedStage: WorkflowStage? { definition?.stage(selected) }

    var body: some View {
        Group {
            if definition != nil {
                HStack(spacing: 0) {
                    BighelpDeferredSection { canvas }
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
                Menu {
                    WorkflowAddStageButtons { addStage($0, after: selected) }
                    Divider()
                    Button("Inputs", systemImage: "arrow.right.to.line") { isInputsPresented = true }
                } label: {
                    Image(systemName: "plus")
                        .bighelpToolbarIcon()
                }
                .bighelpIconLabel("Add a stage")
                .disabled(definition == nil)
                .accessibilityIdentifier("workflows.canvas.add")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { isRunSheetPresented = true } label: {
                    Label("Run", systemImage: "play.fill")
                        .bighelpToolbarText()
                }
                .disabled(!model.canRun)
                .accessibilityIdentifier("workflows.canvas.run")
            }
            ToolbarItem(placement: .topBarTrailing) {
                WorkflowMoreMenu(model: model, context: context, templateSource: $templateSource,
                                 editInputs: { isInputsPresented = true })
            }
        }
        .sheet(item: $editing) { stage in
            WorkflowStageEditor(model: model, context: context, stage: stage)
                .bighelpSheetSize(.large)
        }
        .sheet(isPresented: $isRunSheetPresented) {
            WorkflowRunSheet(model: model, context: context)
                .bighelpSheetSize(.standard)
        }
        .sheet(isPresented: $isInputsPresented) {
            WorkflowInputsEditor(model: model)
                .bighelpSheetSize(.large)
        }
        // Its own view: two alerts on one view and only one of them shows.
        .background {
            Color.clear
                .modifier(WorkflowSaveTemplatePrompt(store: context.store, source: $templateSource,
                                                     prepare: { await model.flushSave() }) { saved in
                    model.message = saved ? WorkflowWords.templateSaved : context.store.message
                    context.store.message = nil
                })
                .allowsHitTesting(false)
        }
        .alert("Workflow", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
        .onChange(of: model.definition != nil, initial: true) { _, loaded in
            guard loaded else { return }
            if startsRun, !didOfferRun {
                didOfferRun = true
                if model.canRun { isRunSheetPresented = true }
            }
        }
        .onDisappear { Task { await model.flushSave() } }
        .animation(.snappy, value: selected)
    }

    // MARK: Canvas

    private var canvas: some View {
        WorkflowCanvasBoard(model: model, context: context, selected: $selected,
                            edit: { editing = $0 }, add: { addStage($0, after: $1) },
                            editInputs: { isInputsPresented = true })
            .overlay(alignment: .topLeading) {
                if !model.unboundRoles.isEmpty, let definition {
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        Text(model.unboundRoles.count == 1 ? "1 role needs an agent"
                             : "\(model.unboundRoles.count) roles need an agent")
                            .font(.bighelp(.headline))
                            .foregroundStyle(theme.warning)
                        ForEach(definition.roles) { role in
                            WorkflowRolePicker(model: model, context: context, role: role)
                        }
                    }
                    .workflowCard(theme)
                    .frame(maxWidth: 360)
                    .padding(BighelpTokens.space16)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                WorkflowIssuesCard(issues: model.issues)
                    .frame(maxWidth: 360)
                    .padding(BighelpTokens.space16)
            }
    }

    private func addStage(_ kind: WorkflowStage.Kind, after key: String?) {
        guard let stage = model.addStage(kind, after: key) else { return }
        selected = stage.key
        editing = stage
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
