import SwiftUI

/// The short form a template with fill-in fields opens with: the agent's name, then the template's
/// own fields in order. Continue fills its instructions and hands the editor back; nothing reaches
/// Hermes until Create.
struct AgentTemplateFillView: View {
    let template: AgentSoulTemplate
    let onContinue: (TemplateForm) -> Void
    let onCancel: () -> Void
    @State private var form: TemplateForm
    /// Choice fields set to "Other", whose value is typed.
    @State private var typingOther: Set<String> = []
    @FocusState private var focusedKey: String?

    init(request: AgentTemplateFormRequest, onContinue: @escaping (TemplateForm) -> Void,
         onCancel: @escaping () -> Void) {
        template = request.template
        self.onContinue = onContinue
        self.onCancel = onCancel
        _form = State(initialValue: request.form)
        _typingOther = State(initialValue: Set(request.form.fields.filter { field in
            field.kind == .choice && field.allowsOther
                && !(request.form.values[field.key] ?? "").isEmpty
                && !field.options.contains(request.form.values[field.key] ?? "")
        }.map(\.key)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    intro
                }
                .listRowBackground(Color.clear)
                ForEach(form.fields) { field in
                    Section {
                        row(field)
                    }
                    .listRowBackground(theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            #if !os(visionOS) && !targetEnvironment(macCatalyst)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .navigationTitle(template.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .bighelpToolbarText()
                        .accessibilityIdentifier("agent.template-form.cancel")
                }
                // In the bar, so it stays in view above the keyboard and below a long form.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue", action: finish)
                        .fontWeight(.semibold)
                        .bighelpProminentButtonStyle()
                        .buttonBorderShape(.capsule)
                        .tint(theme.action)
                        .foregroundStyle(theme.actionForeground)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .disabled(!form.canContinue)
                        .accessibilityHint(form.canContinue ? "" : "Fill in the required fields first.")
                        .accessibilityIdentifier("agent.template-form.continue")
                }
            }
            .onAppear {
                if (form.values[TemplateVariables.agentName] ?? "").isEmpty { focusedKey = TemplateVariables.agentName }
            }
        }
        .accessibilityIdentifier("agent.template-form")
    }

    private var intro: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: template.systemImage)
                .font(.bighelp(.title2))
                .foregroundStyle(theme.action)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(verbatim: headline)
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                Text("Fill in a few details. They go into its instructions, and you can change anything after.")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// What the template is for. Its role can be one of the fields, so it isn't used here.
    private var headline: String {
        template.cardStrength.isEmpty ? template.about : template.cardStrength
    }

    private func row(_ field: TemplateVariable) -> some View {
        let problem = form.problem(for: field)
        return VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: field.label)
                    .font(.bighelp(.caption).weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: BighelpTokens.space8)
                Text(field.isRequired ? "Required" : "Optional")
                    .font(.bighelp(.caption2))
                    .foregroundStyle(theme.tertiaryText)
            }
            .accessibilityHidden(true)
            control(field)
            if let help = field.help {
                Text(verbatim: help)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = problem?.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("agent.template-form.problem.\(field.key)")
            } else if showsCount(field) {
                Text(verbatim: "\(form.cleanedValue(for: field).count)/\(field.lengthLimit)")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        .padding(.vertical, BighelpTokens.space4)
    }

    @ViewBuilder
    private func control(_ field: TemplateVariable) -> some View {
        switch field.kind {
        case .text, .number:
            TextField(field.label, text: binding(field), prompt: hint(field))
                .font(.bighelp(.body))
                #if !os(visionOS)
                .keyboardType(field.kind == .number ? .numbersAndPunctuation : .default)
                #endif
                .textInputAutocapitalization(field.key == TemplateVariables.agentName
                                             || field.key == TemplateVariables.userName ? .words : .sentences)
                .submitLabel(.next)
                .onSubmit { focusField(after: field) }
                .focused($focusedKey, equals: field.key)
                .accessibilityLabel(accessibilityLabel(field))
                .accessibilityIdentifier("agent.template-form.field.\(field.key)")
        case .longText:
            TextField(field.label, text: binding(field), prompt: hint(field), axis: .vertical)
                .font(.bighelp(.body))
                .lineLimit(3...8)
                .focused($focusedKey, equals: field.key)
                .accessibilityLabel(accessibilityLabel(field))
                .accessibilityIdentifier("agent.template-form.field.\(field.key)")
        case .choice:
            choice(field)
        }
    }

    @ViewBuilder
    private func choice(_ field: TemplateVariable) -> some View {
        let other = "\u{0}other"
        Picker(field.label, selection: Binding(
            get: { typingOther.contains(field.key) ? other : (form.values[field.key] ?? "") },
            set: { picked in
                if picked == other {
                    typingOther.insert(field.key)
                    form.values[field.key] = ""
                    focusedKey = field.key
                } else {
                    typingOther.remove(field.key)
                    form.values[field.key] = picked
                }
            }
        )) {
            if (form.values[field.key] ?? "").isEmpty, !typingOther.contains(field.key) {
                Text("Choose").tag("")
            }
            ForEach(field.options, id: \.self) { Text(verbatim: $0).tag($0) }
            if field.allowsOther { Text("Other").tag(other) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(theme.action)
        .accessibilityLabel(accessibilityLabel(field))
        .accessibilityIdentifier("agent.template-form.field.\(field.key)")
        if typingOther.contains(field.key) {
            TextField("Other", text: binding(field), prompt: Text("Your own").bighelpFieldHint(theme))
                .font(.bighelp(.body))
                .focused($focusedKey, equals: field.key)
                .accessibilityLabel("\(field.label), other")
                .accessibilityIdentifier("agent.template-form.other.\(field.key)")
        }
    }

    private func binding(_ field: TemplateVariable) -> Binding<String> {
        Binding(get: { form.values[field.key] ?? "" }, set: { form.values[field.key] = $0 })
    }

    private func hint(_ field: TemplateVariable) -> Text {
        Text(verbatim: field.example ?? field.label).bighelpFieldHint(theme)
    }

    private func accessibilityLabel(_ field: TemplateVariable) -> String {
        field.isRequired ? "\(field.label), required" : "\(field.label), optional"
    }

    /// The count shows once a field is most of the way to its limit.
    private func showsCount(_ field: TemplateVariable) -> Bool {
        guard field.kind == .text || field.kind == .longText else { return false }
        return form.cleanedValue(for: field).count * 5 >= field.lengthLimit * 4
    }

    /// Return moves on to the next field that's typed in.
    private func focusField(after field: TemplateVariable) {
        guard let index = form.fields.firstIndex(of: field) else { return }
        focusedKey = form.fields[(index + 1)...].first { $0.kind != .choice }?.key
    }

    private func finish() {
        guard form.canContinue else { return }
        onContinue(form)
    }

    @BighelpThemeReader private var theme
}

extension View {
    /// Shows a template's form when the editor's model asks for one. Hang it on the editor's root:
    /// a sheet from a form's section header shows, but its fields never get the keyboard.
    func agentTemplateForm(_ model: AgentEditorModel) -> some View {
        modifier(AgentTemplateFormPresenter(model: model))
    }
}

private struct AgentTemplateFormPresenter: ViewModifier {
    let model: AgentEditorModel

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { model.templateForm },
                                    set: { if $0 == nil { model.cancelTemplateForm() } })) { request in
            AgentTemplateFillView(request: request, onContinue: { model.finishTemplateForm($0) },
                                  onCancel: { model.cancelTemplateForm() })
                .presentationDragIndicator(.visible)
                .bighelpSheetSize(.standard)
        }
    }
}
