import SwiftUI

struct NativeSessionControlsView: View {
    let client: DirectHermesConversationClient
    let connectionGeneration: UUID
    let isSessionRunning: Bool

    @State private var model: NativeSessionControlsModel
    @State private var backgroundText = ""
    @State private var btwText = ""
    @State private var compressionFocus = ""
    @State private var workingDirectory = ""
    @State private var redirectText = ""
    @State private var subgoalText = ""
    @State private var subgoalIndex = 1
    @State private var crossSessionSpawnTrees = false
    @State private var spawnTreeLimit = 50
    @State private var verificationDirectory = ""
    @State private var showsAdvancedControls = false
    @State private var showsContextBreakdown = false
    @State private var rollbackReview: DirectHermesRollbackCheckpoint?
    @State private var spawnTreeReview: DirectHermesSpawnTreeEntry?
    @State private var destructiveAction: NativeSessionDestructiveAction?
    @State private var showsDestructiveReview = false
    @Environment(\.dismiss) private var dismiss

    init(presentation: NativeSessionControlsPresentation) {
        self.init(
            client: presentation.client,
            connectionGeneration: presentation.connectionGeneration,
            isSessionRunning: presentation.isSessionRunning,
            onReconcileHistory: presentation.onReconcileHistory
        )
    }

    init(
        client: DirectHermesConversationClient,
        connectionGeneration: UUID,
        isSessionRunning: Bool,
        onReconcileHistory: @escaping NativeSessionHistoryReconciliationHandler
    ) {
        self.client = client
        self.connectionGeneration = connectionGeneration
        self.isSessionRunning = isSessionRunning
        _model = State(initialValue: NativeSessionControlsModel(
            client: client,
            connectionGeneration: connectionGeneration,
            reconcileHistory: onReconcileHistory
        ))
    }

    var body: some View {
        Group {
            if model.ownsOriginalClient {
                controlsForm
            } else {
                ContentUnavailableView(
                    "Session changed",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Close these controls and reopen them from the current chat.")
                )
            }
        }
        .navigationTitle("Session controls")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task(id: connectionGeneration) {
            guard model.refreshActions(
                client: client,
                connectionGeneration: connectionGeneration
            ) else { return }
            let observedBeforeRead = client.model?.sessionGoal?.updatedAt ?? 0
            await model.loadInitialState()
            adoptGoalControlIfAvailable(afterObservation: observedBeforeRead)
        }
        .bighelpSheet(isPresented: $showsContextBreakdown) {
            NavigationStack {
                if let breakdown = model.contextBreakdown {
                    SessionContextBreakdownView(breakdown: breakdown)
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .bighelpSheet(item: $rollbackReview, onDismiss: model.closeRollbackReview) { checkpoint in
            NavigationStack {
                NativeSessionRollbackReviewView(
                    checkpoint: checkpoint,
                    model: model,
                    isSessionRunning: isSessionRunning
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .bighelpSheet(item: $spawnTreeReview, onDismiss: model.closeSpawnTree) { entry in
            NavigationStack {
                NativeSessionSpawnTreeView(entry: entry, model: model)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            destructiveAction?.title ?? "Review session change",
            isPresented: $showsDestructiveReview,
            presenting: destructiveAction
        ) { action in
            Button(action.confirmationLabel, role: .destructive) {
                performDestructiveAction(action)
            }
            Button("Cancel", role: .cancel) {
                destructiveAction = nil
            }
        } message: { action in
            Text(action.explanation)
        }
        .accessibilityIdentifier("chat.native-session-controls")
    }

    private var controlsForm: some View {
        Form {
            feedbackSection
            conversationPresentationSection
            overviewSection
            enabledCapabilitiesSection
            sideTasksSection
            advancedControlsSection
            if showsAdvancedControls {
                skillsSection
                toolsSection
                maintenanceSection
                controlSection
                redirectSection
                rollbackSection
                delegationSection
                spawnTreesSection
                verificationSection
            }
        }
        .formStyle(.grouped)
        .refreshable { await model.loadInitialState() }
    }

    @ViewBuilder
    private var feedbackSection: some View {
        if let pending = model.pendingHistoryReconciliation {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        Text("Chat refresh required")
                            .font(.bighelp(.headline))
                        Text(pending.confirmation == .acknowledged
                             ? "\(pending.kind.label) was acknowledged. The operation will not run again while canonical history still needs refresh."
                             : "The \(pending.kind.label.lowercased()) result is unknown. The operation will not run again while canonical history still needs refresh.")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.clockwise.circle")
                        .foregroundStyle(.orange)
                }
                Button("Retry chat refresh", systemImage: "arrow.clockwise") {
                    Task { await model.retryHistoryReconciliation() }
                }
                .disabled(model.isBusy(.historyReconciliation))
            }
        }

        if let error = model.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("chat.native-session-controls.error")
                Button("Dismiss") { model.clearFeedback() }
            }
        } else if let notice = model.noticeMessage {
            Section {
                Label(notice, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Dismiss") { model.clearFeedback() }
            }
        }
    }

    @ViewBuilder
    private var conversationPresentationSection: some View {
        if client.model != nil {
            Section {
                Toggle("Show thinking", isOn: reasoningVisibility)
                    .accessibilityHint("Shows or hides reasoning Hermes provided for this chat.")
                    .accessibilityIdentifier("chat.native-session-controls.show-thinking")
                Toggle("Show tool calls", isOn: toolVisibility)
                    .accessibilityHint("Shows or hides tool activity Hermes provided for this chat.")
                    .accessibilityIdentifier("chat.native-session-controls.show-tools")
            } header: {
                Text("Conversation")
            } footer: {
                Text("These visibility choices change only this chat on this device.")
            }
        }
    }

    @ViewBuilder
    private var enabledCapabilitiesSection: some View {
        Section {
            switch model.toolsetLoadState {
            case .notLoaded:
                Text("Enabled tools haven’t been loaded yet.").foregroundStyle(.secondary)
                Button("Load enabled tools") { Task { await model.refreshToolsets() } }
            case .loading:
                ProgressView("Reading enabled tools…")
            case .failed:
                Text("Enabled tools could not be refreshed.").foregroundStyle(.secondary)
                Button("Try again") { Task { await model.refreshToolsets() } }
            case .loaded:
                if enabledToolsets.isEmpty {
                    Text("No enabled configurable toolsets were reported by this live session.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(enabledToolsets) { toolset in
                        Label {
                            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                Text(toolset.name)
                                Text("\(toolset.toolCount.formatted()) tools enabled")
                                    .font(.bighelp(.caption)).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.tint)
                        }
                    }
                }
            }
        } header: {
            Text("Enabled tools")
        }
        if let skills = model.lastSkillsReload {
            Section {
                LabeledContent("Available", value: skills.total.formatted())
                LabeledContent("Commands", value: skills.commands.formatted())
            } header: {
                Text("Last installed-skill reload")
            } footer: {
                Text("Installed skills are not a per-session enabled list.")
            }
        }
    }

    private var overviewSection: some View {
        Section {
            if model.isBusy(.overview), model.status == nil {
                ProgressView("Loading session details…")
            }
            if let status = model.status {
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text("Status")
                        .font(.bighelp(.caption).weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(status.output)
                        .font(.bighelp(.body).monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let usage = model.usage {
                NativeSessionUsageView(usage: usage)
            }
            if let breakdown = model.contextBreakdown {
                Button {
                    showsContextBreakdown = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            Text("Context")
                            Text("\(breakdown.contextUsed.formatted()) of \(breakdown.contextMax.formatted()) tokens · \(breakdown.contextPercent)%")
                                .font(.bighelp(.caption))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: BighelpTokens.space8)
                        Image(systemName: "chevron.right")
                            .font(.bighelp(.caption).weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the exact context category breakdown.")
            }
            Button("Refresh session details", systemImage: "arrow.clockwise") {
                Task { await model.refreshOverview() }
            }
            .disabled(model.isBusy(.overview))
        } header: {
            Text("Overview")
        }
    }

    private var sideTasksSection: some View {
        Section {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                TextField("Background task", text: $backgroundText, axis: .vertical)
                    .lineLimit(2...6)
                Button("Start background task", systemImage: "square.stack.3d.up") {
                    let submitted = backgroundText
                    Task {
                        if await model.startBackgroundTask(submitted), backgroundText == submitted {
                            backgroundText = ""
                        }
                    }
                }
                .disabled(!hasText(backgroundText) || model.isBusy(.background))
            }

            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                TextField("BTW question", text: $btwText, axis: .vertical)
                    .lineLimit(2...6)
                Button("Ask BTW", systemImage: "questionmark.bubble") {
                    let submitted = btwText
                    Task {
                        if await model.askBTW(submitted), btwText == submitted {
                            btwText = ""
                        }
                    }
                }
                .disabled(!hasText(btwText) || model.isBusy(.btw))
            }
        } header: {
            Text("Work alongside this chat")
        } footer: {
            Text("Accepted progress and results appear in the chat.")
        }
    }

    private var advancedControlsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsAdvancedControls) {
                Text("Skills, tools, maintenance, goal control, redirect, rollback, delegation, spawn trees, and verification.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(.secondary)
                    .padding(.top, BighelpTokens.space4)
            } label: {
                Label("Advanced session tools", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier("chat.native-session-controls.advanced")
        } header: {
            Text("Advanced")
        } footer: {
            Text("Host-level controls and inspection tools for this session.")
        }
    }

    private var skillsSection: some View {
        Section {
            Button("Reload installed skills", systemImage: "arrow.clockwise.circle") {
                Task { await model.reloadSkills() }
            }
            .disabled(idleActionDisabled || liveConfigurationIsBusy)
            .accessibilityIdentifier("chat.native-session-controls.reload-skills")

            if model.isBusy(.skillsReload) {
                ProgressView("Reloading live skills…")
            }
            if let result = model.lastSkillsReload {
                LabeledContent("Available skills", value: result.total.formatted())
                LabeledContent("Skill commands", value: result.commands.formatted())
                if let count = model.reloadedCommandCount {
                    LabeledContent("Live commands read back", value: count.formatted())
                }
                if !result.added.isEmpty {
                    LabeledContent("Added", value: result.added.map(\.name).joined(separator: ", "))
                }
                if !result.removed.isEmpty {
                    LabeledContent("Removed", value: result.removed.map(\.name).joined(separator: ", "))
                }
            }
        } header: {
            Text("Skills")
        } footer: {
            Text("Reloads installed skills and refreshes this chat’s command list without resetting the session.")
        }
    }

    private var toolsSection: some View {
        Section {
            if model.isBusy(.toolsetsRead), model.toolsets.isEmpty {
                ProgressView("Reading live-session tools…")
            }
            if model.toolsets.isEmpty, !model.isBusy(.toolsetsRead) {
                Text("No configurable toolsets were reported by this Hermes session.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.toolsets) { toolset in
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            Text(toolset.name)
                                .font(.bighelp(.body).monospaced())
                            if !toolset.description.isEmpty {
                                Text(toolset.description)
                                    .font(.bighelp(.caption))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("\(toolset.toolCount.formatted()) tools · \(toolset.enabled ? "Enabled" : "Disabled")")
                                .font(.bighelp(.caption))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: BighelpTokens.space8)
                        Button(toolset.enabled ? "Disable" : "Enable") {
                            review(.toolset(name: toolset.name, enabled: !toolset.enabled))
                        }
                        .buttonStyle(.bordered)
                        .disabled(idleActionDisabled || model.toolsetReadbackRequired
                            || liveConfigurationIsBusy)
                        .accessibilityLabel("\(toolset.enabled ? "Disable" : "Enable") \(toolset.name) toolset")
                    }
                }
            }
            if model.toolsetReadbackRequired {
                Label("Refresh the live tool state before another change.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            }
            Button("Refresh tool configuration", systemImage: "arrow.clockwise") {
                Task { await model.refreshToolsets() }
            }
            .disabled(liveConfigurationIsBusy)
            .accessibilityIdentifier("chat.native-session-controls.refresh-tools")
        } header: {
            Text("Tools")
        } footer: {
            Text(isSessionRunning
                 ? "Tool changes require an idle session."
                 : "A change rebuilds the live agent and clears its process-local visible history. bighelp preserves the canonical transcript and confirms the new tool state before another change.")
        }
    }

    private var maintenanceSection: some View {
        Section {
            TextField("Optional compression focus", text: $compressionFocus, axis: .vertical)
                .lineLimit(1...4)
            Button("Compress session", systemImage: "arrow.down.right.and.arrow.up.left") {
                review(.compression)
            }
            .disabled(idleHistoryActionDisabled || model.isBusy(.compression))

            Button("Undo latest message", systemImage: "arrow.uturn.backward") {
                review(.undo)
            }
            .disabled(idleHistoryActionDisabled || model.isBusy(.undo))

            Button("Save session", systemImage: "square.and.arrow.down") {
                Task { await model.save() }
            }
            .disabled(idleActionDisabled || model.isBusy(.save))

            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                TextField("Working directory path", text: $workingDirectory)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Set working directory", systemImage: "folder") {
                    let submitted = workingDirectory
                    Task {
                        if await model.setWorkingDirectory(submitted), workingDirectory == submitted {
                            workingDirectory = ""
                        }
                    }
                }
                .disabled(!hasText(workingDirectory) || idleActionDisabled || model.isBusy(.workingDirectory))
            }

            if let result = model.lastCompression {
                NativeSessionCompressionResultView(result: result)
            }
            if let result = model.lastUndo {
                LabeledContent("Messages removed", value: result.removed.formatted())
            }
            if let result = model.lastSave, let file = result.file {
                LabeledContent("Saved file", value: file)
                    .textSelection(.enabled)
            }
            if let result = model.lastWorkingDirectory {
                LabeledContent("Current directory", value: result.workingDirectory)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Maintenance")
        } footer: {
            Text(isSessionRunning
                 ? "Compression, undo, save, working-directory changes, and rollback restore require an idle session."
                 : "History-changing actions require an explicit review and a successful canonical chat refresh before another history change.")
        }
    }

    private var controlSection: some View {
        Section {
            if model.isBusy(.controlRead), model.control == nil {
                ProgressView("Loading control state…")
            }
            if let control = model.control {
                NativeSessionControlSnapshotView(snapshot: control)
            }
            if let dispatch = model.lastControlDispatch {
                NativeSessionControlDispatchView(dispatch: dispatch)
            }

            controlButtons(
                title: "Goal",
                actions: [
                    ("Pause", .goalPause),
                    ("Resume", .goalResume),
                    ("Unwait", .goalUnwait),
                ]
            )
            Button("Clear goal", systemImage: "trash", role: .destructive) {
                review(.goalClear)
            }
            .disabled(model.isBusy(.controlMutation))

            controlButtons(
                title: "Loop",
                actions: [
                    ("Pause", .loopPause),
                    ("Resume", .loopResume),
                ]
            )
            Button("Stop loop", systemImage: "stop.circle", role: .destructive) {
                review(.loopStop)
            }
            .disabled(model.isBusy(.controlMutation))

            controlButtons(
                title: "Heartbeat",
                actions: [
                    ("Pause", .heartbeatPause),
                    ("Resume", .heartbeatResume),
                ]
            )
            Button("Clear heartbeat", systemImage: "trash", role: .destructive) {
                review(.heartbeatClear)
            }
            .disabled(model.isBusy(.controlMutation))

            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                TextField("New subgoal", text: $subgoalText, axis: .vertical)
                    .lineLimit(1...4)
                Button("Add subgoal", systemImage: "plus") {
                    let submitted = subgoalText
                    Task {
                        if await model.applyControl(.subgoalAdd(submitted)), subgoalText == submitted {
                            subgoalText = ""
                        }
                    }
                }
                .disabled(!hasText(subgoalText) || model.isBusy(.controlMutation))
            }

            Stepper("Subgoal index: \(subgoalIndex)", value: $subgoalIndex, in: 1...4_096)
            Button("Remove selected subgoal", systemImage: "minus.circle", role: .destructive) {
                review(.subgoalRemove(subgoalIndex))
            }
            .disabled(model.isBusy(.controlMutation))
            Button("Clear all subgoals", systemImage: "trash", role: .destructive) {
                review(.subgoalClear)
            }
            .disabled(model.isBusy(.controlMutation))

            Button("Refresh control state", systemImage: "arrow.clockwise") {
                Task {
                    let observedBeforeRead = client.model?.sessionGoal?.updatedAt ?? 0
                    await model.refreshControl()
                    adoptGoalControlIfAvailable(afterObservation: observedBeforeRead)
                }
            }
            .disabled(model.isBusy(.controlRead))
        } header: {
            Text("Goal, loop, and heartbeat")
        } footer: {
            Text("Clear removes the standing goal; it does not delete chat history.")
        }
    }

    private var redirectSection: some View {
        Section {
            TextField("Correction for the active turn", text: $redirectText, axis: .vertical)
                .lineLimit(2...8)
            Button("Submit redirect", systemImage: "arrow.turn.up.right") {
                let submitted = redirectText
                Task {
                    if await model.redirect(submitted), redirectText == submitted {
                        redirectText = ""
                    }
                }
            }
            .disabled(!hasText(redirectText) || model.isBusy(.redirect))
            if let result = model.lastRedirect {
                LabeledContent("Last result", value: result.status.rawValue)
                Text(result.text)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Redirect")
        } footer: {
            Text("Sends a correction to the active turn. Rejected text stays in the field.")
        }
    }

    private var rollbackSection: some View {
        Section {
            if model.isBusy(.rollbackList), model.rollbackList == nil {
                ProgressView("Loading checkpoints…")
            }
            if let list = model.rollbackList {
                if !list.enabled {
                    ContentUnavailableView(
                        "Rollback unavailable",
                        systemImage: "arrow.uturn.backward.circle",
                        description: Text("This Hermes session reports rollback as disabled.")
                    )
                } else if list.checkpoints.isEmpty {
                    Text("No rollback checkpoints.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(list.checkpoints) { checkpoint in
                        Button {
                            rollbackReview = checkpoint
                            Task { await model.loadRollbackDiff(checkpoint) }
                        } label: {
                            NativeSessionRollbackCheckpointRow(checkpoint: checkpoint)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let result = model.lastRollbackRestore {
                NativeSessionRollbackRestoreResultView(result: result)
            }
            Button("Refresh checkpoints", systemImage: "arrow.clockwise") {
                Task { await model.refreshRollbacks() }
            }
            .disabled(model.isBusy(.rollbackList))
        } header: {
            Text("Rollback")
        } footer: {
            Text("Open a checkpoint to review its exact diff before choosing a full or single-file restore.")
        }
    }

    private var delegationSection: some View {
        Section {
            if model.isBusy(.delegationRead), model.delegationStatus == nil {
                ProgressView("Loading delegation…")
            }
            if let status = model.delegationStatus {
                LabeledContent("New delegation", value: status.paused ? "Paused" : "Allowed")
                LabeledContent("Active agents", value: status.active.count.formatted())
                LabeledContent("Maximum depth", value: status.maxSpawnDepth.formatted())
                LabeledContent("Maximum concurrent children", value: status.maxConcurrentChildren.formatted())

                Button(status.paused ? "Resume delegation" : "Pause delegation",
                       systemImage: status.paused ? "play" : "pause") {
                    Task { await model.setDelegationPaused(!status.paused) }
                }
                .disabled(model.isBusy(.delegationMutation))

                ForEach(status.active) { delegation in
                    NativeSessionDelegationRow(delegation: delegation)
                }
            }
            Button("Refresh delegation", systemImage: "arrow.clockwise") {
                Task { await model.refreshDelegation() }
            }
            .disabled(model.isBusy(.delegationRead))
        } header: {
            Text("Delegation")
        }
    }

    private var spawnTreesSection: some View {
        Section {
            Toggle("Include other sessions", isOn: $crossSessionSpawnTrees)
            Stepper("Maximum results: \(spawnTreeLimit)", value: $spawnTreeLimit, in: 1...500, step: 10)
            Button("Load spawn trees", systemImage: "arrow.clockwise") {
                Task {
                    await model.refreshSpawnTrees(
                        crossSession: crossSessionSpawnTrees,
                        limit: spawnTreeLimit
                    )
                }
            }
            .disabled(model.isBusy(.spawnTreeList))

            if model.spawnTrees.isEmpty, !model.isBusy(.spawnTreeList) {
                Text("No saved spawn trees in this scope.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.spawnTrees) { entry in
                Button {
                    spawnTreeReview = entry
                    Task { await model.loadSpawnTree(path: entry.path) }
                } label: {
                    NativeSessionSpawnTreeRow(entry: entry)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Spawn trees")
        } footer: {
            Text("Inspect a typed snapshot or save a labeled copy. Arbitrary JSON cannot be submitted.")
        }
    }

    private var verificationSection: some View {
        Section {
            if model.verificationIsUnsupported {
                ContentUnavailableView(
                    "Verification status unavailable",
                    systemImage: "checkmark.seal",
                    description: Text("This Hermes host does not support the typed verification-status method.")
                )
            } else {
                TextField("Optional working directory", text: $verificationDirectory)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Check verification status", systemImage: "checkmark.seal") {
                    let value = hasText(verificationDirectory) ? verificationDirectory : nil
                    Task { await model.refreshVerification(workingDirectory: value) }
                }
                .disabled(model.isBusy(.verification))
                if model.isBusy(.verification), model.verificationStatus == nil {
                    ProgressView("Checking verification…")
                }
                if let status = model.verificationStatus {
                    NativeSessionVerificationStatusView(status: status)
                }
            }
        } header: {
            Text("Verification")
        } footer: {
            Text("Read-only host evidence. Commands shown here cannot run from this screen.")
        }
    }

    private func controlButtons(
        title: String,
        actions: [(String, DirectHermesSessionControlAction)]
    ) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text(title)
                .font(.bighelp(.caption).weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: BighelpTokens.space8) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, entry in
                    Button(entry.0) {
                        Task { await performControl(entry.1) }
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(model.isBusy(.controlMutation))
                }
            }
        }
    }

    private var enabledToolsets: [DirectHermesToolset] {
        model.toolsets.filter(\.enabled).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var reasoningVisibility: Binding<Bool> {
        Binding(
            get: { client.model?.activityVisibility.showReasoning ?? false },
            set: { client.model?.setReasoningVisible($0) }
        )
    }

    private var toolVisibility: Binding<Bool> {
        Binding(
            get: { client.model?.activityVisibility.showToolCalls ?? false },
            set: { client.model?.setToolCallsVisible($0) }
        )
    }

    private var idleActionDisabled: Bool {
        isSessionRunning || !model.ownsOriginalClient
    }

    private var idleHistoryActionDisabled: Bool {
        idleActionDisabled || !model.canRunHistoryMutation
    }

    private var liveConfigurationIsBusy: Bool {
        model.isBusy(.skillsReload)
            || model.isBusy(.toolsetsRead)
            || model.isBusy(.toolConfiguration)
    }

    private func hasText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func review(_ action: NativeSessionDestructiveAction) {
        destructiveAction = action
        showsDestructiveReview = true
    }

    private func performDestructiveAction(_ action: NativeSessionDestructiveAction) {
        destructiveAction = nil
        Task {
            switch action {
            case .compression:
                let focus = hasText(compressionFocus) ? compressionFocus : nil
                await model.compress(focusTopic: focus)
            case .undo:
                await model.undo()
            case .goalClear:
                await performControl(.goalClear)
            case .loopStop:
                _ = await model.applyControl(.loopStop)
            case .heartbeatClear:
                _ = await model.applyControl(.heartbeatClear)
            case .subgoalRemove(let index):
                _ = await model.applyControl(.subgoalRemove(index))
            case .subgoalClear:
                _ = await model.applyControl(.subgoalClear)
            case .toolset(let name, let enabled):
                await model.configureToolset(name, enabled: enabled)
            }
        }
    }

    private func performControl(_ action: DirectHermesSessionControlAction) async {
        let observedBeforeAction = client.model?.sessionGoal?.updatedAt ?? 0
        guard await model.applyControl(action) else { return }
        adoptGoalControlIfAvailable(afterObservation: observedBeforeAction)
    }

    private func adoptGoalControlIfAvailable(afterObservation: Int) {
        guard let control = model.control else { return }
        client.model?.reconcileNativeGoalControl(
            control,
            from: client,
            connectionGeneration: connectionGeneration,
            afterObservation: afterObservation
        )
    }
}

private enum NativeSessionDestructiveAction {
    case compression
    case undo
    case goalClear
    case loopStop
    case heartbeatClear
    case subgoalRemove(Int)
    case subgoalClear
    case toolset(name: String, enabled: Bool)

    var title: String {
        switch self {
        case .compression: "Review session compression"
        case .undo: "Review undo"
        case .goalClear: "Clear the current goal?"
        case .loopStop: "Stop the current loop?"
        case .heartbeatClear: "Clear heartbeat state?"
        case .subgoalRemove(let index): "Remove subgoal \(index)?"
        case .subgoalClear: "Clear all subgoals?"
        case .toolset(let name, let enabled):
            "\(enabled ? "Enable" : "Disable") \(name)?"
        }
    }

    var confirmationLabel: String {
        switch self {
        case .compression: "Compress session"
        case .undo: "Undo latest message"
        case .goalClear: "Clear goal"
        case .loopStop: "Stop loop"
        case .heartbeatClear: "Clear heartbeat"
        case .subgoalRemove: "Remove subgoal"
        case .subgoalClear: "Clear subgoals"
        case .toolset(_, let enabled): enabled ? "Enable toolset" : "Disable toolset"
        }
    }

    var explanation: String {
        switch self {
        case .compression:
            "Hermes may replace older session history with a compressed summary. bighelp will refresh canonical chat history after Hermes acknowledges the change."
        case .undo:
            "Hermes will remove the latest session message. bighelp will refresh canonical chat history after Hermes acknowledges the change."
        case .goalClear:
            "Hermes Clear removes the current standing goal. Hermes has no separate goal-delete action, and this does not delete chat messages or session history."
        case .loopStop:
            "This stops the current managed loop."
        case .heartbeatClear:
            "This removes the current heartbeat control state."
        case .subgoalRemove(let index):
            "This removes subgoal \(index) from the current goal."
        case .subgoalClear:
            "This removes every current subgoal."
        case .toolset(let name, let enabled):
            "Hermes will \(enabled ? "enable" : "disable") \(name), persist the CLI tool configuration, and rebuild this idle live session. Stock Hermes clears process-local visible history, attachments, edit snapshots, and session-scoped model, reasoning, and service-tier overrides before re-deriving them from config, then emits fresh session info. bighelp preserves the canonical transcript and requires live tool-state readback before another change."
        }
    }
}
