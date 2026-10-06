import SwiftUI

struct ChatSessionSettingsDestination {
    let title: String
    let subtitle: String
    let systemImage: String
    let content: AnyView

    init<Content: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = AnyView(content())
    }
}

struct ChatSessionFilesAction {
    let title: String
    let subtitle: String
    let action: @MainActor () -> Void

    init(
        title: String = "Files",
        subtitle: String = "Browse files available to this chat",
        action: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }
}

@MainActor
struct ChatSessionSettingsView: View {
    let model: ChatModel
    let agents: AgentDirectoryStore
    let appearanceStore: SessionAppearanceStore?
    let nativeSessionControls: NativeSessionControlsPresentation?
    let filesAction: ChatSessionFilesAction?
    let managementDestination: ChatSessionSettingsDestination?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.nerdModeEnabled) private var nerdModeEnabled
    @BighelpThemeReader private var theme
    @State private var destination: Destination?
    @State private var isFilesPresented = false

    private enum Destination: Hashable { case appearance, session }

    init(
        model: ChatModel,
        agents: AgentDirectoryStore,
        appearanceStore: SessionAppearanceStore? = nil,
        nativeSessionControls: NativeSessionControlsPresentation? = nil,
        filesAction: ChatSessionFilesAction? = nil,
        managementDestination: ChatSessionSettingsDestination? = nil
    ) {
        self.model = model
        self.agents = agents
        self.appearanceStore = appearanceStore
        self.nativeSessionControls = nativeSessionControls
        self.filesAction = filesAction
        self.managementDestination = managementDestination
    }

    var body: some View {
        NavigationStack {
            List {
                identitySection
                quickActionsSection
                modelSection
                // Per-chat reasoning/tool visibility is a technical knob: Nerd Mode only.
                if nerdModeEnabled { conversationSection }
                sessionSection
                if let managementDestination {
                    managementSection(managementDestination)
                }
                privacySection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .tint(theme.action)
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $destination) { destination in
                switch destination {
                case .appearance:
                    if let appearanceStore { SessionAppearanceView(store: appearanceStore) }
                case .session:
                    if let nativeSessionControls {
                        NativeSessionControlsView(presentation: nativeSessionControls)
                            .id(nativeSessionControls.clientIdentity)
                    }
                }
            }
            .bighelpSheet(isPresented: $isFilesPresented) { ChatSessionFilesView(model: model) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .frame(minHeight: BighelpTokens.toolbarHitTarget)
                }
            }
            .accessibilityIdentifier("chat.session-info")
        }
        .presentationBackground(theme.canvas)
    }

    private var identitySection: some View {
        Section {
            VStack(spacing: BighelpTokens.space12) {
                participantCluster(size: 76)
                VStack(spacing: BighelpTokens.space4) {
                    Text(sessionTitle)
                        .font(.bighelp(.title2).weight(.bold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(participantSummary)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BighelpTokens.space12)
            .accessibilityElement(children: .combine)
        }
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var quickActionsSection: some View {
        if appearanceStore != nil || filesAction != nil || (nerdModeEnabled && nativeSessionControls != nil) {
            Section {
                HStack(alignment: .top, spacing: BighelpTokens.space8) {
                    if appearanceStore != nil {
                        Button { destination = .appearance } label: {
                            quickActionLabel("Appearance", systemImage: "photo.on.rectangle.angled")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.session-info.appearance")
                    }
                    if let filesAction {
                        Button { isFilesPresented = true } label: {
                            quickActionLabel(filesAction.title, systemImage: "folder")
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(filesAction.subtitle)
                        .accessibilityIdentifier("chat.session-info.files")
                    }
                    if nerdModeEnabled, nativeSessionControls != nil {
                        Button { destination = .session } label: {
                            quickActionLabel("Session", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.session-info.controls")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, BighelpTokens.space4)
            }
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        if let controls = model.runtimeControls {
            Section {
                ChatModelSummaryRow(controls: controls) {
                    dismiss()
                    model.requestSessionControls()
                }
            } header: {
                Text("Model")
            }
            .listRowBackground(theme.surface)
        }
    }

    private var conversationSection: some View {
        Section {
            Toggle("Show thinking", isOn: reasoningVisibility)
                .accessibilityHint("Shows or hides the reasoning Hermes provided for this chat.")
                .accessibilityIdentifier("chat.session-info.reasoning")
            Toggle("Show tool calls", isOn: toolVisibility)
                .accessibilityHint("Shows or hides tool activity Hermes provided for this chat.")
                .accessibilityIdentifier("chat.session-info.tools")
        } header: {
            Text("Conversation")
        } footer: {
            Text("These visibility choices stay with this chat on this device.")
        }
        .listRowBackground(theme.surface)
    }

    private var sessionSection: some View {
        Section {
            participantsRow
            // Host details (project folder, connection, profile) are for Nerd Mode.
            if nerdModeEnabled {
                if let workspace = model.sessionWorkspaceName, !workspace.isEmpty {
                    LabeledContent("Workspace", value: workspace)
                }
                if let native = model.nativeConversationClient {
                    LabeledContent("Connection", value: native.isReadyForSubmission ? "Ready" : "Recovering")
                    LabeledContent("Profile", value: native.profile)
                }
            }
        } header: {
            Text("In this chat")
        }
        .listRowBackground(theme.surface)
    }

    private var participantsRow: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: BighelpTokens.space16) {
                ForEach(participants) { participant in
                    VStack(spacing: BighelpTokens.space4) {
                        AvatarView(
                            stableID: participant.id,
                            displayName: participant.name,
                            imageURL: participant.imageURL,
                            size: 52
                        )
                        Text(participant.name)
                            .font(.bighelp(.caption))
                            .lineLimit(1)
                            .frame(maxWidth: 76)
                        if let detail = participant.detail {
                            Text(detail)
                                .font(.bighelp(.caption2))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: 76)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, BighelpTokens.space4)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("chat.session-info.participants")
    }

    private func managementSection(_ destination: ChatSessionSettingsDestination) -> some View {
        Section {
            NavigationLink {
                destination.content
                    .navigationTitle(destination.title)
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        Text(destination.title)
                        Text(destination.subtitle)
                            .font(.bighelp(.caption))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: destination.systemImage)
                        .foregroundStyle(.tint)
                }
            }
        } header: {
            Text("Group")
        }
        .listRowBackground(theme.surface)
    }

    private var privacySection: some View {
        Section {
            Label("Conversation appearance stays on this device", systemImage: "iphone")
            if model.isBotMode {
                Label("Earlier direct chats stay private to their original agent", systemImage: "lock.shield")
            }
        } header: {
            Text("Privacy")
        }
        .listRowBackground(theme.surface)
    }

    private func quickActionLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: BighelpTokens.space8) {
            Image(systemName: systemImage)
                .font(.bighelp(.title3))
                .foregroundStyle(theme.action)
                .frame(width: 48, height: 48)
                .background(theme.surface, in: .circle)
            Text(title)
                .font(.bighelp(.caption))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 76)
        .contentShape(.rect)
    }

    @ViewBuilder
    private func participantCluster(size: CGFloat) -> some View {
        if participants.count > 1 {
            HStack(spacing: -size * 0.28) {
                ForEach(participants.prefix(4)) { participant in
                    AvatarView(
                        stableID: participant.id,
                        displayName: participant.name,
                        imageURL: participant.imageURL,
                        size: size * 0.72
                    )
                    .overlay { Circle().stroke(Color(uiColor: .systemGroupedBackground), lineWidth: 3) }
                }
            }
            .accessibilityHidden(true)
        } else if let participant = participants.first {
            AvatarView(
                stableID: participant.id,
                displayName: participant.name,
                imageURL: participant.imageURL,
                size: size
            )
            .accessibilityHidden(true)
        } else {
            Image(systemName: "person.crop.circle")
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var reasoningVisibility: Binding<Bool> {
        Binding(
            get: { model.activityVisibility.showReasoning },
            set: { model.setReasoningVisible($0) }
        )
    }

    private var toolVisibility: Binding<Bool> {
        Binding(
            get: { model.activityVisibility.showToolCalls },
            set: { model.setToolCallsVisible($0) }
        )
    }

    private var sessionTitle: String {
        model.isBotMode ? model.botModeRoomTitle : model.sessionTitle
    }

    private var participantSummary: String {
        let count = participants.count
        if count == 0 { return "No participant details available" }
        return "\(count) \(count == 1 ? "agent" : "agents")"
    }

    private var participants: [ChatSessionDetailsParticipant] {
        if model.botModeRoom?.hasNativeRoom == true {
            return model.nativeRoomParticipants.map { participant in
                ChatSessionDetailsParticipant(
                    id: participant.id,
                    name: participant.displayName,
                    detail: participant.availability == .available ? "@\(participant.handle)" : "Unavailable",
                    imageURL: participant.profile.flatMap { agents.avatarURL(for: $0) }
                )
            }
        }
        return model.memberProfiles.map { profile in
            ChatSessionDetailsParticipant(
                id: profile.id,
                name: profile.name,
                detail: profile.role,
                imageURL: agents.avatarURL(for: profile)
            )
        }
    }
}

private struct ChatSessionDetailsParticipant: Identifiable {
    let id: String
    let name: String
    let detail: String?
    let imageURL: URL?
}
