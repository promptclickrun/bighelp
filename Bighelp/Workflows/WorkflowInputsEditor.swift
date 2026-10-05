import SwiftUI

/// The workflow's inputs: what a run asks for before it starts. Done saves the draft.
struct WorkflowInputsEditor: View {
    let model: WorkflowEditorModel
    @State private var inputs: [WorkflowDefinition.Input]
    @State private var choices: [String: String]
    /// Fields added here: their key follows their name until saved.
    @State private var added: Set<String> = []
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    init(model: WorkflowEditorModel) {
        self.model = model
        let inputs = model.definition?.inputs ?? []
        _inputs = State(initialValue: inputs)
        _choices = State(initialValue: Dictionary(inputs.map { ($0.key, $0.choices.joined(separator: ", ")) },
                                                  uniquingKeysWith: { first, _ in first }))
    }

    var body: some View {
        NavigationStack {
            Form {
                if inputs.isEmpty {
                    Section {
                        Text("No fields yet. A run asks for these before it starts, and stages can use them.")
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                ForEach($inputs) { $input in
                    Section {
                        TextField("Name", text: $input.label, prompt: Text("Name").bighelpFieldHint(theme))
                            .bighelpMacField()
                            .accessibilityIdentifier("workflows.input.\(input.key).label")
                        Picker("Kind", selection: $input.type) {
                            Text("Text").tag("text")
                            Text("Long text").tag("long_text")
                            Text("Number").tag("number")
                            Text("Choice").tag("choice")
                        }
                        if input.kind == .choice {
                            TextField("Choices", text: Binding(get: { choices[input.key] ?? "" },
                                                                set: { choices[input.key] = $0 }),
                                      prompt: Text("Short, Medium, Long").bighelpFieldHint(theme))
                                .bighelpMacField()
                        }
                        Toggle("Required", isOn: $input.required)
                        Button("Delete field", role: .destructive) {
                            inputs.removeAll { $0.key == input.key }
                        }
                    } footer: {
                        Text("Stages use it as inputs.\(input.key).")
                            .font(.bighelp(.footnote).monospaced())
                    }
                }
                Section {
                    Button("Add a field", systemImage: "plus") { addField() }
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .accessibilityIdentifier("workflows.inputs.add")
                }
            }
            .scrollContentBackground(.hidden)
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle("Inputs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .disabled(isSaving || inputs.contains { $0.label.trimmingCharacters(in: .whitespaces).isEmpty })
                        .bighelpDefaultAction()
                        .accessibilityIdentifier("workflows.inputs.done")
                }
            }
        }
        .accessibilityIdentifier("workflows.inputs-editor")
    }

    private func addField() {
        let number = inputs.count + 1
        let key = WorkflowInputKey.make(from: "field \(number)", existing: inputs.map(\.key))
        inputs.append(.init(key: key, label: "Field \(number)", type: "text", required: false, choices: [],
                            sampleValue: nil))
        added.insert(key)
    }

    private func save() {
        var result = inputs
        for index in result.indices where added.contains(result[index].key) {
            let old = result[index].key
            let others = result.map(\.key).filter { $0 != old }
            let key = WorkflowInputKey.make(from: result[index].label, existing: others)
            result[index].key = key
            choices[key] = choices[old]
        }
        for index in result.indices {
            result[index].label = String(result[index].label.trimmingCharacters(in: .whitespaces).prefix(200))
            result[index].choices = result[index].kind == .choice
                ? (choices[result[index].key] ?? "").split(separator: ",")
                    .map { String($0.trimmingCharacters(in: .whitespaces).prefix(200)) }
                    .filter { !$0.isEmpty }.prefix(20).map { $0 }
                : []
        }
        model.definition?.inputs = Array(result.prefix(20))
        isSaving = true
        Task {
            defer { isSaving = false }
            if await model.save() { dismiss() }
        }
    }
}

/// Keys the host accepts: a lowercase letter, then letters, digits and _ (at most 32).
enum WorkflowInputKey {
    /// As typed: lowercase letters, digits and _, at most 32.
    static func clean(_ text: String) -> String {
        String(text.lowercased().map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? $0 : "_" }.prefix(32))
    }

    static func make(from label: String, existing: [String]) -> String {
        var base = String(label.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
            .filter { $0.isASCII }
            .split(separator: "_").joined(separator: "_")
        if base.first.map({ !$0.isLetter }) ?? true { base = "field" + (base.isEmpty ? "" : "_\(base)") }
        base = String(base.prefix(28))
        var key = base
        var number = 2
        while existing.contains(key) {
            key = "\(base)_\(number)"
            number += 1
        }
        return key
    }
}
