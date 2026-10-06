import SwiftUI

@MainActor
struct ScheduledTaskDetailView: View {
    @State private var store: ScheduledTasksStore
    @State private var isEditorPresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var isRunConfirmationPresented = false
    @State private var isDuplicatePickerPresented = false
    @State private var isAdvancedExpanded = false
    @Environment(\.nerdModeEnabled) private var nerdModeEnabled
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let taskID: String
    let agents: AgentDirectoryStore
    let owningAgentID: String?
    let onOpenRun: ((String) -> Void)?

    init(
        store: ScheduledTasksStore,
        taskID: String,
        agents: AgentDirectoryStore,
        agentID: String? = nil,
        onOpenRun: ((String) -> Void)? = nil
    ) {
        _store = State(initialValue: store)
        self.taskID = taskID
        self.agents = agents
        owningAgentID = agentID
        self.onOpenRun = onOpenRun
    }

    var body: some View {
        Group {
            if let task = store.task(id: taskID, agentID: owningAgentID) {
                List {
                    header(task)
                    detailStatus(task)
                    feedback(task)
                    about(task)
                    ScheduledTaskRunsView(store: store, task: task, onOpenSession: onOpenRun)
                    advanced(task)
                    dangerZone(task)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .bighelpSheet(isPresented: $isEditorPresented) {
                    if let agent = agent(for: task) {
                        NavigationStack {
                            ScheduledTaskEditorView(store: store, agent: agent, task: task, directory: agents)
                        }
                        .bighelpSheetSize(.standard)
                    }
                }
                .bighelpSheet(isPresented: $isDuplicatePickerPresented) {
                    NavigationStack {
                        AgentSelectionView(
                            title: "Duplicate for another agent",
                            detail: "Choose the agent that should own the new task.",
                            agents: agents.profiles,
                            avatarURL: agents.avatarURL(for:)
                        ) { destination in
                            isDuplicatePickerPresented = false
                            Task { await duplicate(task, for: destination) }
                        }
                    }
                    .bighelpSheetSize(.compact)
                }
                .confirmationDialog(presentation(for: task).deleteConfirmationTitle, isPresented: $isDeleteConfirmationPresented, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { Task { await delete(task) } }
                } message: {
                    Text(presentation(for: task).deleteConfirmationMessage)
                }
                .confirmationDialog("Run and resume this task?", isPresented: $isRunConfirmationPresented, titleVisibility: .visible) {
                    Button("Run and resume") { Task { try? await store.runNow(id: task.id, agentID: task.agentID) } }
                } message: {
                    Text("Hermes resumes a paused schedule when it runs now. Future scheduled runs will be enabled too.")
                }
            } else {
                ContentUnavailableView("Task unavailable", systemImage: "exclamationmark.triangle",
                    description: Text(store.taskLookupMessage(id: taskID, agentID: owningAgentID)))
            }
        }
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: detailIdentitySuffix) {
            guard let task = store.task(id: taskID, agentID: owningAgentID) else { return }
            await store.loadDetail(id: task.id, agentID: task.agentID)
        }
        .refreshable {
            guard let task = store.task(id: taskID, agentID: owningAgentID) else { return }
            await store.loadDetail(id: task.id, agentID: task.agentID)
            await store.loadRuns(id: task.id, agentID: task.agentID)
        }
        .accessibilityIdentifier("scheduled-task.detail.\(detailIdentitySuffix)")
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ task: ScheduledTask) -> some View {
        let profile = agent(for: task)
        let state = ScheduledTaskCopy.liveState(for: task, isRunning: isRunning(task))
        Section {
            VStack(spacing: BighelpTokens.space12) {
                AvatarView(
                    stableID: profile?.id ?? "unavailable-\(task.agentID)",
                    displayName: profile?.name ?? "Unavailable agent",
                    imageURL: profile.flatMap(agents.avatarURL(for:)),
                    size: 80,
                    state: state
                )
                .accessibilityHidden(true)
                VStack(spacing: BighelpTokens.space4) {
                    Text(task.displayName)
                        .bighelpFont(.screenTitle)
                        .foregroundStyle(theme.primaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(profile?.name ?? "Agent unavailable")
                        .bighelpFont(.label)
                        .foregroundStyle(theme.secondaryText)
                    Text(ScheduledTaskCopy.friendlySchedule(task))
                        .bighelpFont(.body)
                        .foregroundStyle(theme.primaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ScheduledTaskCopy.shortNextRun(task, isRunning: isRunning(task)))
                        .bighelpFont(.metadata)
                        .foregroundStyle(task.status == .failed ? theme.danger : theme.tertiaryText)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("scheduled-task.detail.summary")
                actionButtons(task)
                    .padding(.top, BighelpTokens.space4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BighelpTokens.space8)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
    }

    private func actionButtons(_ task: ScheduledTask) -> some View {
        let presentation = presentation(for: task)
        let isPending = store.isPending(task.id, agentID: task.agentID)
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: BighelpTokens.space8))
            : AnyLayout(HStackLayout(spacing: BighelpTokens.space12))
        return layout {
            actionTile("Run now", systemImage: "play.fill") { requestRun(task) }
                .disabled(!presentation.action(.runNow).isEnabled || isPending)
                .accessibilityHint(presentation.action(.runNow).reason ?? "")
                .accessibilityIdentifier("scheduled-task.run-now")
            actionTile(task.isPaused ? "Resume" : "Pause",
                       systemImage: task.isPaused ? "play.circle" : "pause.fill") {
                Task { try? await store.setPaused(!task.isPaused, id: task.id, agentID: task.agentID) }
            }
            .disabled(!presentation.action(.pauseOrResume).isEnabled || isPending)
            .accessibilityHint(presentation.action(.pauseOrResume).reason ?? "")
            .accessibilityIdentifier("scheduled-task.pause-resume")
            actionTile("Edit", systemImage: "pencil") {
                isEditorPresented = true
            }
            .disabled(!presentation.action(.edit).isEnabled || isPending)
            .accessibilityHint(presentation.action(.edit).reason ?? "")
            .accessibilityIdentifier("scheduled-task.edit")
        }
        .padding(.horizontal, BighelpTokens.space16)
    }

    private func actionTile(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ScheduledTaskActionTileLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - Status and feedback

    @ViewBuilder
    private func detailStatus(_ task: ScheduledTask) -> some View {
        switch store.detailLoadState(for: task) {
        case .loading:
            ProgressView("Refreshing task details")
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowBackground(theme.surface)
                .accessibilityIdentifier("scheduled-task.detail.loading")
        case .failed(let message):
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry task details") {
                    Task { await store.loadDetail(id: task.id, agentID: task.agentID) }
                }
                .frame(minHeight: BighelpTokens.hitTarget)
            }
            .listRowBackground(theme.surface)
            .accessibilityIdentifier("scheduled-task.detail.error")
        case .idle, .loaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private func feedback(_ task: ScheduledTask) -> some View {
        let presentation = presentation(for: task)
        let isPending = store.isPending(task.id, agentID: task.agentID)
        let unavailableReason = presentation.action(.edit).reason
        if isPending || unavailableReason != nil || store.errorMessage != nil || agent(for: task) == nil {
            Section {
                if isPending {
                    ProgressView("Updating task")
                        .accessibilityIdentifier("scheduled-task.pending")
                }
                if agent(for: task) == nil {
                    Label(
                        "Agent unavailable. You can keep this history, delete it, or duplicate it for an available agent.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("scheduled-task.agent-unavailable")
                } else if let unavailableReason {
                    Label(unavailableReason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("scheduled-task.action-unavailable")
                }
                if let message = store.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("scheduled-task.error")
                }
            }
            .bighelpFont(.metadata)
            .listRowBackground(theme.surface)
        }
    }

    // MARK: - About

    @ViewBuilder
    private func about(_ task: ScheduledTask) -> some View {
        Section {
            Text(task.instructions)
                .bighelpFont(.body)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .listRowBackground(theme.surface)
        } header: {
            ScheduledTaskSectionCaption(title: "What it does")
        }

        Section {
            detailLine("When", ScheduledTaskCopy.friendlySchedule(task), systemImage: "calendar")
            detailLine("Next run", nextRunValue(task), systemImage: "clock")
            detailLine("Results go to", deliveryName(task), systemImage: "paperplane")
            detailLine(
                "Last run",
                task.lastRun?.formatted(date: .abbreviated, time: .shortened) ?? "No runs yet",
                systemImage: "clock.arrow.circlepath"
            )
            if let lastResult = task.lastResult {
                detailLine("Last status", lastResult, systemImage: "checkmark.message")
            }
            if let lastError = task.lastError {
                detailLine("Last error", lastError, systemImage: "exclamationmark.triangle", isError: true)
            }
        } header: {
            ScheduledTaskSectionCaption(title: "Schedule")
        }
    }

    private func detailLine(_ title: String, _ value: String, systemImage: String, isError: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space12) {
            Image(systemName: systemImage)
                .bighelpFont(.label, weight: .regular)
                .foregroundStyle(isError ? theme.danger : theme.secondaryText)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                Text(value)
                    .bighelpFont(.body)
                    .foregroundStyle(isError ? theme.danger : theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: BighelpTokens.hitTarget)
        .accessibilityElement(children: .combine)
        .listRowBackground(theme.surface)
    }

    // MARK: - Advanced and delete

    @ViewBuilder
    private func advanced(_ task: ScheduledTask) -> some View {
        if nerdModeEnabled {
            Section {
                DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                    if let model = modelValue(task) {
                        detailLine("Model", model, systemImage: "cpu")
                    }
                    detailLine("Delivery target", task.deliveryTarget, systemImage: "point.3.connected.trianglepath.dotted")
                    detailLine("Time zone", task.schedule.timeZoneDisclosure, systemImage: "globe")
                    if task.usesHostManagedExecution {
                        detailLine("Execution", "Uses host-managed scripts or skills", systemImage: "terminal")
                    }
                    duplicateButton(task)
                } label: {
                    Text("Advanced")
                        .bighelpFont(.label)
                        .foregroundStyle(theme.primaryText)
                        .frame(minHeight: BighelpTokens.hitTarget)
                }
                .tint(theme.secondaryText)
                .listRowBackground(theme.surface)
                .accessibilityIdentifier("scheduled-task.advanced")
            }
        } else {
            // Host details stay behind Nerd Mode; duplicating is an everyday action.
            Section { duplicateButton(task) }
        }
    }

    private func duplicateButton(_ task: ScheduledTask) -> some View {
        let presentation = presentation(for: task)
        return Button("Duplicate for another agent", systemImage: "doc.on.doc") {
            isDuplicatePickerPresented = true
        }
        .frame(minHeight: BighelpTokens.hitTarget)
        .disabled(!presentation.action(.duplicate).isEnabled || agents.profiles.isEmpty || store.isPending("create"))
        .listRowBackground(theme.surface)
        .accessibilityIdentifier("scheduled-task.duplicate")
    }

    private func dangerZone(_ task: ScheduledTask) -> some View {
        Section {
            Button(role: .destructive) {
                isDeleteConfirmationPresented = true
            } label: {
                Label("Delete task", systemImage: "trash")
                    .foregroundStyle(theme.danger)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            }
            .disabled(store.isPending(task.id, agentID: task.agentID))
            .listRowBackground(theme.surface)
            .accessibilityIdentifier("scheduled-task.delete")
        }
    }

    // MARK: - Helpers

    private func requestRun(_ task: ScheduledTask) {
        if task.isPaused {
            isRunConfirmationPresented = true
        } else {
            Task { try? await store.runNow(id: task.id, agentID: task.agentID) }
        }
    }

    private var detailIdentitySuffix: String {
        guard let owningAgentID else { return taskID }
        return ScheduledTaskIdentity(profileID: owningAgentID, jobID: taskID).accessibilitySuffix
    }

    private func isRunning(_ task: ScheduledTask) -> Bool {
        store.runs(for: task).contains(where: \.isActive)
    }

    private func nextRunValue(_ task: ScheduledTask) -> String {
        if task.status == .completed || task.status == .failed {
            return presentation(for: task).nextRunCopy
        }
        let date = task.nextRun?.formatted(date: .complete, time: .shortened) ?? "Will be confirmed by the agent"
        return task.isPaused ? "Paused · \(date)" : date
    }

    private func deliveryName(_ task: ScheduledTask) -> String {
        let name = store.deliveryTargets.first(where: { $0.id == task.deliveryTarget })?.name
        return ScheduledTaskDeliverySelection.displayName(id: task.deliveryTarget, name: name ?? task.deliveryTarget)
    }

    private func modelValue(_ task: ScheduledTask) -> String? {
        guard let model = task.model, !model.isEmpty else { return nil }
        guard let provider = task.provider, !provider.isEmpty else { return model }
        return "\(provider) · \(model)"
    }

    private func agent(for task: ScheduledTask) -> AgentProfile? {
        agents.profiles.first(where: { $0.id == task.agentID })
    }

    private func presentation(for task: ScheduledTask) -> ScheduledTaskPresentation {
        ScheduledTaskPresentation(task: task, agentName: agent(for: task)?.name)
    }

    private func duplicate(_ task: ScheduledTask, for agent: AgentProfile) async {
        _ = try? await store.create(ScheduledTaskDraft(
            agentID: agent.id,
            name: task.name,
            instructions: task.instructions,
            schedule: task.schedule,
            deliveryTarget: task.deliveryTarget
        ))
    }

    private func delete(_ task: ScheduledTask) async {
        guard (try? await store.delete(id: task.id, agentID: task.agentID)) != nil else { return }
        dismiss()
    }

    @BighelpThemeReader private var theme
}

/// Rounded tile used for the detail header's primary actions.
private struct ScheduledTaskActionTileLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: BighelpTokens.space4) {
            Image(systemName: systemImage)
                .font(.bighelp(.body).weight(.semibold))
                .accessibilityHidden(true)
            Text(title)
                .bighelpFont(.metadata, weight: .semibold)
        }
        .foregroundStyle(isEnabled ? theme.action : theme.tertiaryText)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16)
                .strokeBorder(theme.border, lineWidth: 1)
        }
        .contentShape(.rect(cornerRadius: BighelpTokens.radius16))
    }

    @BighelpThemeReader private var theme
}
