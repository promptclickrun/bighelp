import SwiftUI

@MainActor
struct ScheduledTaskEditorView: View {
    @State private var store: ScheduledTasksStore
    @Environment(\.dismiss) private var dismiss
    let agent: AgentProfile
    let task: ScheduledTask?
    let directory: AgentDirectoryStore?
    let onBrowseIdeas: (() -> Void)?
    @State private var name: String
    @State private var instructions: String
    @State private var selectedAgentID: String
    @State private var cadence: ScheduleCadence
    @State private var descriptionText: String
    @State private var selectedDeliveryID: String
    @State private var manualDeliveryValue: String
    @State private var validationMessage: String?
    @State private var isAdvancedExpanded = false
    @Environment(\.nerdModeEnabled) private var nerdModeEnabled

    init(
        store: ScheduledTasksStore,
        agent: AgentProfile,
        task: ScheduledTask? = nil,
        directory: AgentDirectoryStore? = nil,
        onBrowseIdeas: (() -> Void)? = nil
    ) {
        _store = State(initialValue: store)
        self.agent = agent
        self.task = task
        self.directory = directory
        self.onBrowseIdeas = onBrowseIdeas
        let current = task?.schedule
        let description: String
        switch current {
        case .naturalLanguage(let text, _):
            description = text
        case .hermes(_, let display, _):
            description = display
        default:
            description = ""
        }
        let isDescribed = current?.isNaturalLanguage == true
        let picker = ScheduledTaskEditorPickerState(schedule: current)
        _name = State(initialValue: task?.name ?? "")
        _instructions = State(initialValue: task?.instructions ?? "")
        _selectedAgentID = State(initialValue: task?.agentID ?? agent.id)
        _cadence = State(initialValue: ScheduleCadence(picker: picker, describing: isDescribed))
        _descriptionText = State(initialValue: description)
        let delivery = task?.deliveryTarget ?? "loopdy"
        _selectedDeliveryID = State(initialValue: delivery.contains(":")
            ? ScheduledTaskDeliverySelection.manualID
            : delivery)
        _manualDeliveryValue = State(initialValue: delivery.contains(":") ? delivery : "")
    }

    var body: some View {
        Form {
            if task == nil, onBrowseIdeas != nil {
                ideasSection
            }
            whatSection
            agentSection
            whenSection
            deliverySection
            if nerdModeEnabled { advancedSection }

            if let validationMessage {
                Section {
                    Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("scheduled-task.editor.validation")
                }
                .listRowBackground(theme.surface)
            }
            if let errorMessage = store.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("scheduled-task.editor.error")
                }
                .listRowBackground(theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle(task == nil ? "New task" : "Edit task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .bighelpToolbarText()
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(task == nil ? "Create" : "Save") { Task { await save() } }
                    .fontWeight(.semibold)
                    .disabled(
                        store.isPending(task?.id ?? "create", agentID: task?.agentID)
                            || store.isLoadingDeliveryTargets
                            || store.deliveryTargets.isEmpty
                    )
                    .accessibilityIdentifier("scheduled-task.editor.save")
            }
        }
        .task {
            await store.loadDeliveryTargets()
            reconcileDeliverySelection()
        }
    }

    // MARK: - Ideas

    private var ideasSection: some View {
        Section {
            Button {
                onBrowseIdeas?()
            } label: {
                HStack(spacing: BighelpTokens.space12) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(theme.action)
                        .frame(width: 36, height: 36)
                        .background(theme.action.opacity(0.12), in: .circle)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start from an idea")
                            .bighelpFont(.label)
                            .foregroundStyle(theme.primaryText)
                        Text("Pick a ready-made task and make it yours")
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.bighelp(.footnote).weight(.semibold))
                        .foregroundStyle(theme.tertiaryText)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Browse ready-made task ideas")
            .accessibilityIdentifier("scheduled-task.editor.ideas")
        }
        .listRowBackground(theme.surface)
    }

    // MARK: - What

    private var whatSection: some View {
        Section {
            TextField(
                "For example, summarize my unread email and flag anything urgent",
                text: $instructions,
                axis: .vertical
            )
            .lineLimit(3...6)
            .accessibilityLabel("Instructions")
            .accessibilityIdentifier("scheduled-task.editor.instructions")
            TextField("Give it a short name", text: $name)
                .accessibilityLabel("Task name")
                .accessibilityIdentifier("scheduled-task.editor.name")
        } header: {
            ScheduledTaskSectionCaption(title: "What should it do?")
        }
        .listRowBackground(theme.surface)
    }

    // MARK: - Agent

    private var agentSection: some View {
        Section {
            if canChooseAgent {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: BighelpTokens.space16) {
                        ForEach(availableAgents) { profile in
                            agentChoice(profile)
                        }
                    }
                    .padding(.vertical, BighelpTokens.space8)
                    .padding(.horizontal, BighelpTokens.space4)
                }
                .accessibilityIdentifier("scheduled-task.editor.summary-header")
            } else {
                HStack(spacing: BighelpTokens.space12) {
                    AvatarView(
                        stableID: selectedAgent.id,
                        displayName: selectedAgent.name,
                        imageURL: directory?.avatarURL(for: selectedAgent),
                        size: 36
                    )
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedAgent.name)
                            .bighelpFont(.label)
                            .foregroundStyle(theme.primaryText)
                        if task != nil {
                            Text("Tasks stay with their agent. Use Duplicate on the task to hand it to someone else.")
                                .bighelpFont(.metadata)
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Agent, \(selectedAgent.name)")
                .accessibilityIdentifier("scheduled-task.editor.summary-header")
            }
        } header: {
            ScheduledTaskSectionCaption(title: "Which agent?")
        }
        .listRowBackground(theme.surface)
    }

    private func agentChoice(_ profile: AgentProfile) -> some View {
        let isSelected = profile.id == selectedAgentID
        return Button {
            selectedAgentID = profile.id
        } label: {
            VStack(spacing: BighelpTokens.space8) {
                AvatarView(
                    stableID: profile.id,
                    displayName: profile.name,
                    imageURL: directory?.avatarURL(for: profile),
                    size: 52
                )
                .padding(3)
                .overlay {
                    Circle()
                        .strokeBorder(isSelected ? theme.action : .clear, lineWidth: 2.5)
                }
                Text(profile.name)
                    .bighelpFont(.metadata, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: 72)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(profile.name)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("scheduled-task.editor.agent.\(profile.id)")
    }

    // MARK: - When

    private var whenSection: some View {
        Section {
            ScheduleCadenceRows(cadence: $cadence) { describeControls }
            if let summary {
                Label {
                    Text(summary)
                        .bighelpFont(.body)
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "calendar.badge.checkmark")
                        .foregroundStyle(theme.action)
                }
                .accessibilityIdentifier("scheduled-task.editor.summary")
            }
        } header: {
            ScheduledTaskSectionCaption(title: "When?")
        } footer: {
            Text("Your agent confirms the exact next run after you save.")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
        }
        .listRowBackground(theme.surface)
    }

    private var describeControls: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            TextField("For example, Every weekday at 8 AM", text: $descriptionText, axis: .vertical)
                .lineLimit(2...5)
                .accessibilityIdentifier("scheduled-task.editor.describe")
            Text("You’ll confirm this exact schedule before saving. If Hermes can’t understand it, your text stays here.")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Delivery

    private var deliverySection: some View {
        Section {
            Picker("Send results to", selection: $selectedDeliveryID) {
                ForEach(store.deliveryTargets) { target in
                    Text(target.homeTargetSet
                        ? ScheduledTaskDeliverySelection.displayName(id: target.id, name: target.name)
                        : "\(ScheduledTaskDeliverySelection.displayName(id: target.id, name: target.name)) — home channel not set")
                        .tag(target.id)
                        .disabled(!target.homeTargetSet)
                }
                Text("Other channel…")
                    .tag(ScheduledTaskDeliverySelection.manualID)
            }
            .accessibilityIdentifier("scheduled-task.editor.delivery")

            if selectedDeliveryID == ScheduledTaskDeliverySelection.manualID {
                TextField("platform:channel[:thread]", text: $manualDeliveryValue)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .bighelpFont(.code)
                    .accessibilityIdentifier("scheduled-task.editor.delivery.manual")
            }

            if store.isLoadingDeliveryTargets {
                BighelpThinkingOrb(
                    scenario: .searching,
                    scale: .inline,
                    visibleLabel: "Loading output channels"
                )
            } else if let message = store.deliveryTargetsErrorMessage {
                Text(message)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.danger)
            }
        } header: {
            ScheduledTaskSectionCaption(title: "Where should results go?")
        }
        .listRowBackground(theme.surface)
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                advancedLine("Time zone", timeZoneDisclosure)
                if let hermesExpression {
                    advancedLine("Schedule sent to Hermes", hermesExpression, isCode: true)
                }
                if selectedDeliveryID != ScheduledTaskDeliverySelection.manualID {
                    advancedLine("Delivery target", selectedDeliveryID, isCode: true)
                }
            } label: {
                Text("Advanced")
                    .bighelpFont(.label)
                    .foregroundStyle(theme.primaryText)
                    .frame(minHeight: BighelpTokens.hitTarget)
            }
            .tint(theme.secondaryText)
            .accessibilityIdentifier("scheduled-task.editor.advanced")
        }
        .listRowBackground(theme.surface)
    }

    private func advancedLine(_ title: String, _ value: String, isCode: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .bighelpFont(isCode ? .code : .body)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(minHeight: BighelpTokens.hitTarget, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var isDescribing: Bool { cadence.isDescribing }

    // MARK: - Agents

    private var availableAgents: [AgentProfile] {
        let profiles = directory?.profiles ?? []
        return profiles.contains(where: { $0.id == agent.id }) ? profiles : [agent] + profiles
    }

    private var canChooseAgent: Bool {
        task == nil && availableAgents.count > 1
    }

    private var selectedAgent: AgentProfile {
        availableAgents.first(where: { $0.id == selectedAgentID }) ?? agent
    }

    // MARK: - Schedule

    private var timeZoneID: String {
        cadence.picker.timeZoneID
    }

    private var timeZoneDisclosure: String {
        task?.schedule.timeZoneDisclosure
            ?? "Requested time zone: \(timeZoneID). Hermes does not yet confirm the saved time zone."
    }

    private var schedule: ScheduleInput? {
        if isDescribing {
            if let originalSchedule = task?.schedule {
                switch originalSchedule {
                case .naturalLanguage(let original, _) where descriptionText == original:
                    return originalSchedule
                case .hermes(_, let display, _) where descriptionText == display:
                    return originalSchedule
                default:
                    break
                }
            }
            let trimmed = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return .naturalLanguage(trimmed, timeZoneID: timeZoneID)
        }
        return cadence.picker.schedule()
    }

    /// Human summary without the device's own time zone tacked on.
    private var summary: String? {
        guard let schedule, let text = try? ScheduleRequestBuilder.request(for: schedule) else { return nil }
        let suffix = " \(schedule.timeZoneID)"
        guard schedule.timeZoneID == TimeZone.current.identifier, text.hasSuffix(suffix) else { return text }
        return String(text.dropLast(suffix.count))
    }

    private var hermesExpression: String? {
        guard let schedule else { return nil }
        return try? ScheduleRequestBuilder.hermesRequest(for: schedule)
    }

    // MARK: - Save

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedInstructions.isEmpty, let schedule else {
            validationMessage = "Add what it should do, a short name, and a complete schedule before saving."
            return
        }
        do {
            _ = try ScheduleRequestBuilder.validatedHermesRequest(for: schedule)
            let deliveryTarget = try ScheduledTaskDeliverySelection.resolve(
                selectedID: selectedDeliveryID,
                manualValue: manualDeliveryValue,
                targets: store.deliveryTargets
            )
            validationMessage = nil
            if let task {
                try await store.update(
                    id: task.id,
                    name: trimmedName,
                    instructions: trimmedInstructions,
                    schedule: schedule,
                    deliveryTarget: deliveryTarget,
                    agentID: task.agentID
                )
            } else {
                _ = try await store.create(ScheduledTaskDraft(
                    agentID: selectedAgent.id,
                    name: trimmedName,
                    instructions: trimmedInstructions,
                    schedule: schedule,
                    deliveryTarget: deliveryTarget
                ))
            }
            dismiss()
        } catch let error as ScheduledTasksError {
            validationMessage = error.errorDescription
        } catch {
            // The store retains the draft and exposes recovery guidance in this editor.
        }
    }

    private func reconcileDeliverySelection() {
        let current = task?.deliveryTarget ?? selectedDeliveryID
        if store.deliveryTargets.contains(where: { $0.id == current }) {
            selectedDeliveryID = current
            manualDeliveryValue = ""
            return
        }
        if task != nil || current.contains(":") {
            selectedDeliveryID = ScheduledTaskDeliverySelection.manualID
            manualDeliveryValue = current
            return
        }
        if let target = store.deliveryTargets.first(where: { $0.homeTargetSet }) {
            selectedDeliveryID = target.id
            manualDeliveryValue = ""
        }
    }

    @BighelpThemeReader private var theme
}

private extension ScheduleInput {
    var isNaturalLanguage: Bool {
        switch self {
        case .naturalLanguage, .hermes: true
        default: false
        }
    }
}
