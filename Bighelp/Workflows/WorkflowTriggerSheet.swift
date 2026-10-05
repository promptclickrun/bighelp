import SwiftUI

/// How a workflow starts. Manual: someone (or an agent) starts each run. Scheduled: Save
/// makes and turns on a scheduled job on the computer that starts each run with these inputs.
struct WorkflowTriggerSheet: View {
    let model: WorkflowEditorModel
    let context: WorkflowsContext
    @State private var isScheduled: Bool
    @State private var cadence: ScheduleCadence
    @State private var values: [String: String]
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    init(model: WorkflowEditorModel, context: WorkflowsContext) {
        self.model = model
        self.context = context
        let zone = TimeZone.current.identifier
        var saved: ScheduleInput?
        var inputs: WorkflowJSON = [:]
        if case .schedule(let expression, let savedInputs)? = model.trigger {
            saved = ScheduleRequestBuilder.input(forCron: expression, timeZoneID: zone)
            inputs = savedInputs
        }
        _isScheduled = State(initialValue: model.trigger?.isScheduled == true)
        var cadence = ScheduleCadence(picker: ScheduledTaskEditorPickerState(schedule: saved ?? .repeating(
            days: ScheduleCadence.weekdaySet, time: DateComponents(hour: 9, minute: 0), timeZoneID: zone)))
        if saved == nil { cadence.apply(.weekdays) }
        _cadence = State(initialValue: cadence)
        _values = State(initialValue: WorkflowInputFields.values(for: model.definition?.inputs ?? [], saved: inputs))
    }

    private var inputs: [WorkflowDefinition.Input] { model.definition?.inputs ?? [] }

    private var schedule: String? {
        guard let input = cadence.picker.schedule() else { return nil }
        return try? ScheduleRequestBuilder.hermesRequest(for: input)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Starts", selection: $isScheduled) {
                        Text("Manual").tag(false)
                        Text("Scheduled").tag(true)
                    }
                    .bighelpSegmentedPicker()
                    .accessibilityIdentifier("workflows.trigger.kind")
                } footer: {
                    Text(isScheduled
                         ? "\(context.hostName) starts a run on this schedule, even when the app is closed. Each run spends what a run spends."
                         : "A run starts only when you tap Run, or when you ask an agent to start one.")
                        .font(.bighelp(.footnote))
                }
                if isScheduled {
                    Section {
                        ScheduleCadenceRows(cadence: $cadence, frequencies: [.daily, .weekdays, .weekly, .custom],
                                            customModes: [.days, .monthly], identifier: "workflows.trigger")
                        if let schedule {
                            Label(ScheduleRequestBuilder.display(forHermesRequest: schedule),
                                  systemImage: "calendar.badge.checkmark")
                                .font(.bighelp(.body))
                                .accessibilityIdentifier("workflows.trigger.summary")
                        }
                    } header: {
                        Text("When?")
                    } footer: {
                        Text("Times are on \(context.hostName)'s clock.")
                            .font(.bighelp(.footnote))
                    }
                    if !inputs.isEmpty {
                        Section {
                            WorkflowInputFields(inputs: inputs, values: $values, identifier: "workflows.trigger")
                        } header: {
                            Text("Each run uses")
                        } footer: {
                            if !WorkflowInputFields.isComplete(inputs, values) {
                                Text("Fill in what each run needs to save the schedule.")
                                    .font(.bighelp(.footnote))
                                    .foregroundStyle(theme.warning)
                                    .accessibilityIdentifier("workflows.trigger.needs-inputs")
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle("Trigger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving || (isScheduled && (schedule == nil
                                                               || !WorkflowInputFields.isComplete(inputs, values))))
                        .bighelpDefaultAction()
                        .accessibilityIdentifier("workflows.trigger.save")
                }
            }
        }
        .accessibilityIdentifier("workflows.trigger")
    }

    private func save() {
        let trigger: WorkflowTrigger
        if isScheduled, let schedule {
            trigger = .schedule(schedule, inputs: WorkflowInputFields.json(inputs, values))
        } else {
            trigger = .manual
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            if await model.setTrigger(trigger) {
                await context.store.load()
                dismiss()
            }
        }
    }
}

/// A workflow's trigger in a few words, for its page.
enum WorkflowTriggerWords {
    static func text(_ trigger: WorkflowTrigger?) -> String {
        switch trigger {
        case .schedule(let expression, _)?: ScheduleRequestBuilder.display(forHermesRequest: expression)
        default: "Manual"
        }
    }
}

/// A workflow's inputs as a form: what a run, or each scheduled run, uses.
struct WorkflowInputFields: View {
    let inputs: [WorkflowDefinition.Input]
    @Binding var values: [String: String]
    var identifier = "workflows.run-sheet"
    @BighelpThemeReader private var theme

    var body: some View {
        ForEach(inputs) { input in field(input) }
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
            LabeledContent(input.label) {
                TextField(input.label, text: binding, prompt: Text("Number").bighelpFieldHint(theme))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
        case .text:
            LabeledContent(input.label) {
                TextField(input.label, text: binding, prompt: Text(input.required ? "Required" : "Optional")
                    .bighelpFieldHint(theme))
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("\(identifier).\(input.key)")
            }
        }
    }

    /// Saved values first, then each input's sample (or first choice).
    static func values(for inputs: [WorkflowDefinition.Input], saved: WorkflowJSON = [:]) -> [String: String] {
        var values: [String: String] = [:]
        for input in inputs {
            values[input.key] = saved[input.key]?.displayText
                ?? input.sample ?? (input.kind == .choice ? input.choices.first : nil) ?? ""
        }
        return values
    }

    static func isComplete(_ inputs: [WorkflowDefinition.Input], _ values: [String: String]) -> Bool {
        inputs.allSatisfy { input in
            let value = (values[input.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if input.kind == .number, !value.isEmpty, Double(value) == nil { return false }
            return !input.required || !value.isEmpty
        }
    }

    static func json(_ inputs: [WorkflowDefinition.Input], _ values: [String: String]) -> WorkflowJSON {
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
        return json
    }
}

/// "Starts: Manual" or the schedule, on the workflow's page. Tap to change it.
struct WorkflowTriggerCard: View {
    let trigger: WorkflowTrigger?
    let edit: () -> Void
    @BighelpThemeReader private var theme

    var body: some View {
        Button(action: edit) {
            HStack(spacing: BighelpTokens.space12) {
                Image(systemName: trigger?.isScheduled == true ? "calendar.badge.clock" : "hand.tap")
                    .foregroundStyle(theme.action)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Starts")
                        .font(.bighelp(.caption))
                        .foregroundStyle(theme.secondaryText)
                    Text(WorkflowTriggerWords.text(trigger))
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .foregroundStyle(theme.primaryText)
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
        .workflowCard(theme, padding: BighelpTokens.space12)
        .accessibilityIdentifier("workflows.trigger.card")
    }
}
