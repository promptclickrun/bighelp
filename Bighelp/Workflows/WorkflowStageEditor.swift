import SwiftUI

/// One stage: Setup (agent, tools, instructions, what it uses), Output (what
/// it must hand off) and Limits (time, revisions). Done saves the draft.
struct WorkflowStageEditor: View {
    enum Tab: String, CaseIterable, Identifiable {
        case setup = "Setup", output = "Output", limits = "Limits"
        var id: String { rawValue }
    }

    let model: WorkflowEditorModel
    let context: WorkflowsContext
    @State private var stage: WorkflowStage
    @State private var tab: Tab = .setup
    @State private var isSaving = false
    @State private var isNamingRole = false
    @State private var roleName = ""
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    init(model: WorkflowEditorModel, context: WorkflowsContext, stage: WorkflowStage) {
        self.model = model
        self.context = context
        _stage = State(initialValue: stage)
    }

    private var isNew: Bool { model.detail?.definition.stage(stage.key) == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    header
                    Picker("Part", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .bighelpSegmentedPicker()
                    .accessibilityIdentifier("workflows.stage.tabs")
                }
                switch tab {
                case .setup: BighelpDeferredSection { setup }
                case .output: BighelpDeferredSection { output }
                case .limits: BighelpDeferredSection { limits }
                }
                Section {
                    Button("Delete stage", role: .destructive) {
                        model.deleteStage(stage.key)
                        if isNew { dismiss() } else { save(deleting: true) }
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityIdentifier("workflows.stage.delete")
                }
            }
            .scrollContentBackground(.hidden)
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle(stage.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isNew { model.deleteStage(stage.key) }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save(deleting: false) }
                        .disabled(isSaving || stage.title.trimmingCharacters(in: .whitespaces).isEmpty)
                        .bighelpDefaultAction()
                        .accessibilityIdentifier("workflows.stage.done")
                }
            }
        }
        .accessibilityIdentifier("workflows.stage-editor")
        .alert("New role", isPresented: $isNamingRole) {
            TextField("Name", text: $roleName)
            Button("Cancel", role: .cancel) {}
            Button("Add") { addRole() }
        } message: {
            Text("A role is a job in this workflow, like Writer. You choose which agent does it.")
        }
    }

    private func addRole() {
        let label = String(roleName.trimmingCharacters(in: .whitespaces).prefix(200))
        guard !label.isEmpty, model.definition != nil else { return }
        let key = WorkflowInputKey.make(from: label, existing: model.definition?.roles.map(\.key) ?? [])
        model.definition?.roles.append(.init(key: key, label: label))
        stage.role = key
    }

    private var header: some View {
        HStack(spacing: BighelpTokens.space12) {
            WorkflowStageIcon(kind: stage.kind, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Title", text: $stage.title, prompt: Text("Title").bighelpFieldHint(theme))
                    .font(.bighelp(.headline))
                    .accessibilityIdentifier("workflows.stage.title")
                Text([stage.kind.title, stage.role.map { "role \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    // MARK: Setup

    @ViewBuilder
    private var setup: some View {
        switch stage.kind {
        case .agent:
            Section("Agent") {
                if let definition = model.definition {
                    Picker("Role", selection: Binding(get: { stage.role ?? "" }, set: { stage.role = $0.isEmpty ? nil : $0 })) {
                        ForEach(definition.roles) { Text($0.label).tag($0.key) }
                    }
                    .accessibilityIdentifier("workflows.stage.role")
                    Button("New role", systemImage: "person.badge.plus") {
                        roleName = ""
                        isNamingRole = true
                    }
                    if let role = definition.role(stage.role) {
                        WorkflowRolePicker(model: model, context: context, role: role)
                    }
                }
                if !stage.tools.isEmpty {
                    WorkflowChips(items: stage.tools.map(Self.toolName))
                }
                if stage.hasBroadTools {
                    Label("Broad tools. This stage can run commands and change files on \(context.hostName). Instructions can't make it read-only.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.bighelp(.footnote).weight(.semibold))
                        .foregroundStyle(theme.warning)
                        .accessibilityIdentifier("workflows.stage.broad-tools")
                }
            }
            Section("Instructions") {
                TextEditor(text: $stage.instructions)
                    .font(.bighelp(.body))
                    .frame(minHeight: 140)
                    .accessibilityIdentifier("workflows.stage.instructions")
            }
            Section("Uses from earlier stages") {
                ForEach(availableUses, id: \.self) { use in
                    Toggle(isOn: Binding(get: { stage.uses.contains(use) }, set: { on in
                        if on { stage.uses.append(use) } else { stage.uses.removeAll { $0 == use } }
                    })) {
                        Text(use).font(.bighelp(.callout).monospaced())
                    }
                }
            }
        case .check:
            Section {
                ForEach(Array(stage.rules.enumerated()), id: \.offset) { index, rule in
                    ruleRow(index, rule)
                }
                .onDelete { stage.rules.remove(atOffsets: $0) }
                Menu {
                    ForEach(Self.ruleKinds, id: \.kind) { item in
                        Button(item.title) { addRule(item.kind) }
                    }
                } label: {
                    Label("Add a check", systemImage: "plus")
                        .frame(minHeight: BighelpTokens.hitTarget)
                }
                .disabled(checkableOutputs.isEmpty)
            } header: {
                Text("Checks")
            } footer: {
                Text(checkableOutputs.isEmpty
                     ? "Add an agent stage before this one: a check looks at what an earlier stage made."
                     : "The computer checks these itself. No agent runs.")
                    .font(.bighelp(.footnote))
            }
        case .decision:
            Section("Decision") {
                Picker("Reads", selection: Binding(get: { stage.on ?? "" }, set: { stage.on = $0.isEmpty ? nil : $0 })) {
                    ForEach(earlierOutputs(types: ["decision"]) + [stage.on ?? ""].filter { !$0.isEmpty }
                        .filter { !earlierOutputs(types: ["decision"]).contains($0) }, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                LabeledContent("Pass goes to", value: model.definition?.stage(stage.pass)?.title ?? stage.pass ?? "next stage")
                Picker("Changes go back to", selection: Binding(get: { stage.changesGoTo ?? "" },
                                                                 set: { stage.changesGoTo = $0.isEmpty ? nil : $0 })) {
                    ForEach(earlierAgentStages) { Text($0.title).tag($0.key) }
                }
            }
        case .signoff:
            Section("Sign-off") {
                Picker("File you approve", selection: Binding(get: { stage.file ?? "" },
                                                              set: { stage.file = $0.isEmpty ? nil : $0 })) {
                    ForEach(earlierOutputs(types: ["markdown_file"]) + [stage.file ?? ""].filter { !$0.isEmpty }
                        .filter { !earlierOutputs(types: ["markdown_file"]).contains($0) }, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                Text("The run waits for you here, with no agent running. Approving never publishes anything.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
            }
        case .unknown:
            Section {
                Text("This kind of stage needs a newer bighelp.")
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    /// Inputs and every earlier stage's outputs.
    private var availableUses: [String] {
        guard let definition = model.definition else { return [] }
        var uses = definition.inputs.map { "inputs.\($0.key)" }
        for earlier in definition.stages {
            if earlier.key == stage.key { break }
            uses += earlier.outputs.map { "\(earlier.key).\($0.name)" }
        }
        return uses + stage.uses.filter { !uses.contains($0) }
    }

    /// Earlier stages' outputs of some types, as "stage.output".
    private func earlierOutputs(types: Set<String>) -> [String] {
        guard let definition = model.definition else { return [] }
        var result: [String] = []
        for earlier in definition.stages {
            if earlier.key == stage.key { break }
            result += earlier.outputs.filter { types.contains($0.type) }.map { "\(earlier.key).\($0.name)" }
        }
        return result
    }

    private var checkableOutputs: [String] { earlierOutputs(types: ["markdown_file", "text", "number"]) }

    private static let ruleKinds: [(kind: String, title: String)] = [
        ("not_empty", "Not empty"), ("has_title", "Has a title"), ("word_range", "Number of words"),
        ("number_range", "Number in a range"),
    ]

    private func addRule(_ kind: String) {
        guard let of = checkableOutputs.last else { return }
        let ranged = kind == "word_range" || kind == "number_range"
        stage.rules.append(.init(kind: kind, of: of, min: ranged ? 0 : nil, max: ranged ? 1_000 : nil))
    }

    private func ruleRow(_ index: Int, _ rule: WorkflowStage.Rule) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text(Self.ruleKinds.first { $0.kind == rule.kind }?.title ?? rule.kind.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.bighelp(.body).weight(.semibold))
            Picker("Checks", selection: Binding(get: { rule.of }, set: { of in
                stage.rules[index] = .init(kind: rule.kind, of: of, min: rule.min, max: rule.max)
            })) {
                ForEach(checkableOutputs + [rule.of].filter { !checkableOutputs.contains($0) }, id: \.self) {
                    Text($0).tag($0)
                }
            }
            if rule.kind == "word_range" || rule.kind == "number_range" {
                HStack {
                    numberField("Least", rule.min) { stage.rules[index] = .init(kind: rule.kind, of: rule.of, min: $0, max: rule.max) }
                    numberField("Most", rule.max) { stage.rules[index] = .init(kind: rule.kind, of: rule.of, min: rule.min, max: $0) }
                }
            }
        }
        .padding(.vertical, BighelpTokens.space4)
    }

    private func numberField(_ title: String, _ value: Double?, set: @escaping (Double?) -> Void) -> some View {
        LabeledContent(title) {
            TextField(title, value: Binding(get: { value ?? 0 }, set: { set($0) }), format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .bighelpMacField()
        }
    }

    private var earlierAgentStages: [WorkflowStage] {
        guard let definition = model.definition else { return [] }
        return Array(definition.stages.prefix { $0.key != stage.key }.filter { $0.kind == .agent })
    }

    private static func toolName(_ toolset: String) -> String {
        switch toolset {
        case "terminal": "Terminal"
        case "web": "Web"
        case "file": "Files"
        case "code_execution": "Code"
        case "browser": "Browser"
        case "vision": "Vision"
        default: toolset
        }
    }

    // MARK: Output

    @ViewBuilder
    private var output: some View {
        Section {
            if stage.outputs.isEmpty {
                Text(stage.kind == .agent ? "Nothing yet." : "This stage hands off nothing.")
                    .foregroundStyle(theme.secondaryText)
            }
            if stage.kind == .agent {
                // By place, not name: typing a name mustn't make a new row.
                ForEach(stage.outputs.indices, id: \.self) { index in
                    HStack {
                        TextField("Name", text: Binding(get: { stage.outputs[safe: index]?.name ?? "" }, set: { name in
                            if stage.outputs.indices.contains(index) { stage.outputs[index].name = WorkflowInputKey.clean(name) }
                        }))
                        .font(.bighelp(.callout).monospaced())
                        .bighelpMacField()
                        Picker("Kind", selection: Binding(get: { stage.outputs[safe: index]?.type ?? "text" }, set: { type in
                            if stage.outputs.indices.contains(index) { stage.outputs[index].type = type }
                        })) {
                            Text("Markdown file").tag("markdown_file")
                            Text("Text").tag("text")
                            Text("Number").tag("number")
                            Text("Decision").tag("decision")
                            Text("Notes").tag("notes")
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .onDelete { stage.outputs.remove(atOffsets: $0) }
                Button("Add an output", systemImage: "plus") {
                    let name = WorkflowInputKey.make(from: "result", existing: stage.outputs.map(\.name))
                    stage.outputs.append(.init(name: name, type: "markdown_file", values: []))
                }
                .frame(minHeight: BighelpTokens.hitTarget)
            } else {
                ForEach(stage.outputs) { output in
                    LabeledContent {
                        Text(output.typeTitle)
                    } label: {
                        Text(output.name).font(.bighelp(.callout).monospaced())
                    }
                }
            }
        } header: {
            Text("Must hand off")
        } footer: {
            Text("A stage passes when it ends cleanly and hands off all of these, with the right types.")
                .font(.bighelp(.footnote))
        }
    }

    // MARK: Limits

    @ViewBuilder
    private var limits: some View {
        Section {
            if stage.kind == .agent {
                Stepper(value: Binding(get: { stage.minutes ?? model.definition?.stageMinutes ?? 20 },
                                       set: { stage.minutes = $0 }), in: 1...60) {
                    LabeledContent("Time limit", value: "\(stage.minutes ?? model.definition?.stageMinutes ?? 20) min")
                }
                .accessibilityIdentifier("workflows.stage.minutes")
            }
            if stage.kind == .decision {
                Stepper(value: Binding(get: { stage.changesMaxRevisions ?? model.definition?.maxRevisions ?? 2 },
                                       set: { stage.changesMaxRevisions = $0 }), in: 1...5) {
                    LabeledContent("Rounds of changes", value: "\(stage.changesMaxRevisions ?? model.definition?.maxRevisions ?? 2)")
                }
            }
            if stage.kind == .check || stage.kind == .signoff {
                Text("No limits for this stage.")
                    .foregroundStyle(theme.secondaryText)
            }
        } footer: {
            Text("One stage runs at a time. A stage that runs out of time stops, and the run asks you what to do.")
                .font(.bighelp(.footnote))
        }
    }

    private func save(deleting: Bool) {
        if !deleting { model.update(stage) }
        isSaving = true
        Task {
            defer { isSaving = false }
            if await model.save() { dismiss() }
        }
    }
}

/// A wrapping row of chips.
struct WorkflowChips: View {
    let items: [String]
    var tint: Color?
    var monospaced = false
    @BighelpThemeReader private var theme

    var body: some View {
        WorkflowFlowLayout(spacing: BighelpTokens.space8) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(monospaced ? .bighelp(.caption).monospaced() : .bighelp(.caption))
                    .workflowChip(theme, tint: tint)
            }
        }
    }
}

/// Lays children left to right, wrapping to new lines.
struct WorkflowFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in rows.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, widest, y + rowHeight)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
