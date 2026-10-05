import SwiftUI

/// The workflow's inputs: what a run asks for before it starts. Done saves the draft.
struct WorkflowInputsEditor: View {
    let model: WorkflowEditorModel
    @State private var inputs: [WorkflowDefinition.Input]
    @State private var choices: [String: String]
    /// Fields added here: their key follows their name until saved (or until its own field is typed in).
    @State private var added: Set<String> = []
    /// New fields' variable names as typed, by key; a typed one no longer follows the name.
    @State private var typedKeys: [String: String] = [:]
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
                        if added.contains(input.key) {
                            LabeledContent("Variable") {
                                WorkflowKeyField(title: "Variable", key: Binding(
                                    get: { typedKeys[input.key] ?? WorkflowInputKey.clean(input.label) },
                                    set: { typedKeys[input.key] = $0 }),
                                                 prompt: Text("topic").bighelpFieldHint(theme))
                                    .font(.bighelp(.callout).monospaced())
                                    .multilineTextAlignment(.trailing)
                                    .bighelpMacField()
                                    .accessibilityIdentifier("workflows.input.\(input.key).key")
                            }
                        }
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
                        Text("Stages use it as inputs.\(shownKey(input)).")
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

    /// The key a field will have: as it is once saved, or as it will be for a new one.
    private func shownKey(_ input: WorkflowDefinition.Input) -> String {
        guard added.contains(input.key) else { return input.key }
        let others = inputs.map(\.key).filter { $0 != input.key && !added.contains($0) }
        return WorkflowInputKey.finished(typedKeys[input.key] ?? input.label, fallback: "field", existing: others)
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
            let key = WorkflowInputKey.finished(typedKeys[old] ?? result[index].label, fallback: "field", existing: others)
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

/// A name field that fixes itself as it's typed and shows the fixed name at once:
/// "Weekly Chart" becomes "weekly_chart" in the field, never an error.
struct WorkflowKeyField: View {
    let title: String
    @Binding var key: String
    var prompt: Text?
    @State private var text = ""

    var body: some View {
        // The field's own text: a binding that rewrites what's typed leaves the field showing the typing.
        TextField(title, text: $text, prompt: prompt)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .onAppear { text = key }
            .onChange(of: text) { _, value in
                let cleaned = WorkflowInputKey.clean(value)
                if cleaned != value { text = cleaned }
                if key != cleaned { key = cleaned }
            }
            .onChange(of: key) { _, value in
                if value != text { text = value }
            }
    }
}

/// Keys the host accepts: a lowercase letter, then letters, digits and _ (at most 32).
/// Names fix themselves as they're typed, never with an error: capitals become
/// lowercase, spaces become _, accents go and anything else is left out.
enum WorkflowInputKey {
    /// As typed: "Release Notes" is "release_notes", "Café-menu!" is "cafe_menu".
    static func clean(_ text: String) -> String {
        let plain = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        var result = ""
        for character in plain {
            if ("a"..."z").contains(character) || ("0"..."9").contains(character) {
                result.append(character)
            } else if character == " " || character == "_" || character == "-" || character == "." {
                // One _ for a run of spaces, but a name may still end in _ while it's typed.
                if !result.hasSuffix("_") { result.append("_") }
            }
        }
        return String(result.prefix(32))
    }

    /// Ready to save: no _ at either end, a letter first (`fallback` in front of a number) and not one of
    /// `existing` (a number after it instead).
    static func finished(_ text: String, fallback: String, existing: [String] = []) -> String {
        var base = clean(text).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if base.isEmpty { base = fallback } else if base.first.map({ !$0.isLetter }) ?? true { base = "\(fallback)_\(base)" }
        base = String(base.prefix(28)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        var key = base
        var number = 2
        while existing.contains(key) {
            key = "\(base)_\(number)"
            number += 1
        }
        return key
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
