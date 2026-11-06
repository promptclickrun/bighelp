import SwiftUI

@MainActor
struct PeopleAndChatView: View {
    let model: ChatModel
    let agents: AgentDirectoryStore
    let nativeSessionControls: NativeSessionControlsPresentation?
    let filesAction: ChatSessionFilesAction?

    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    @State private var errorMessage: String?

    init(
        model: ChatModel,
        agents: AgentDirectoryStore,
        nativeSessionControls: NativeSessionControlsPresentation? = nil,
        filesAction: ChatSessionFilesAction? = nil
    ) {
        self.model = model
        self.agents = agents
        self.nativeSessionControls = nativeSessionControls
        self.filesAction = filesAction
    }

    var body: some View {
        let _ = model.botModeRoomStore?.rooms
        ChatSessionSettingsView(
            model: model,
            agents: agents,
            nativeSessionControls: nativeSessionControls,
            filesAction: filesAction,
            managementDestination: managementDestination
        )
        .accessibilityIdentifier("chat.people-and-chat")
    }

    private var managementDestination: ChatSessionSettingsDestination? {
        guard model.isBotMode else { return nil }
        if model.botModeRoom?.hasNativeRoom == true {
            return ChatSessionSettingsDestination(
                title: "Group Settings",
                subtitle: model.botModeRoomSettings == nil ? "Name and members" : "Who answers, purpose and shared notes",
                systemImage: "person.2"
            ) {
                if let roomID = model.botModeRoom?.nativeRoomID, let rooms = model.botModeRoomStore {
                    GroupSettingsView(roomID: roomID, rooms: rooms, agents: agents, chat: model)
                }
            }
        }
        return ChatSessionSettingsDestination(
            title: "People & Chat",
            subtitle: "Members and shared-history permissions",
            systemImage: "person.2"
        ) {
            uiV3Enabled ? AnyView(nativeEditableList) : AnyView(legacyList)
        }
    }

    private var nativeEditableList: some View {
        List {
            Section {
                ForEach(model.memberProfiles) { profile in
                    memberRow(profile)
                        .frame(minHeight: BighelpTokens.hitTarget)
                }
            } header: {
                HStack {
                    Text("Agents in this chat")
                    Spacer()
                    Text(memberCountTitle)
                }
            } footer: {
                Text(membershipExplanation)
                    .accessibilityIdentifier("chat.people.summary")
            }

            if !availableProfiles.isEmpty {
                Section {
                    ForEach(availableProfiles) { profile in
                        Button { add(profile) } label: {
                            HStack(spacing: BighelpTokens.space12) {
                                AvatarView(
                                    stableID: profile.id,
                                    displayName: profile.name,
                                    imageURL: agents.avatarURL(for: profile),
                                    size: 44
                                )
                                .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name)
                                        .bighelpFont(.body, weight: .semibold)
                                        .foregroundStyle(theme.primaryText)
                                    if !profile.role.isEmpty {
                                        Text(profile.role)
                                            .bighelpFont(.label)
                                            .foregroundStyle(theme.secondaryText)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: BighelpTokens.space8)
                                Image(systemName: "person.badge.plus")
                                    .foregroundStyle(theme.action)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: BighelpTokens.hitTarget)
                            .contentShape(.rect)
                        }
                        .disabled(model.memberIDs.count >= BotModeRoom.maximumMembers)
                        .accessibilityLabel("Add \(profile.name)")
                        .accessibilityIdentifier("chat.people.add.\(profile.id)")
                    }
                } header: {
                    Text("Add an agent")
                } footer: {
                    Text("This chat can include up to \(BotModeRoom.maximumMembers) agents.")
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("chat.people.error")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }


    private var legacyList: some View {
        List {
            Section {
                Text(membershipExplanation)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(theme.raisedSurface)
            }

            Section("Agents in this chat") {
                ForEach(model.memberProfiles) { profile in
                    memberRow(profile)
                }
            }

            if !availableProfiles.isEmpty {
                Section {
                    ForEach(availableProfiles) { profile in
                        Button {
                            add(profile)
                        } label: {
                            Label("Add \(profile.name)", systemImage: "person.badge.plus")
                                .frame(minHeight: BighelpTokens.hitTarget, alignment: .leading)
                        }
                        .disabled(model.memberIDs.count >= BotModeRoom.maximumMembers)
                        .accessibilityIdentifier("chat.people.add.\(profile.id)")
                    }
                } header: {
                    Text("Add an agent")
                } footer: {
                    Text("This chat can include up to 6 agents")
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func memberRow(_ profile: AgentProfile) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            AvatarView(
                stableID: profile.id,
                displayName: profile.name,
                imageURL: agents.avatarURL(for: profile),
                size: 44
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .bighelpFont(.body, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                Text("@\(model.memberHandle(for: profile.id) ?? AgentHandle.normalized(profile.name))")
                    .bighelpFont(.label)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: BighelpTokens.space8)
            if model.canEditBotModeMembership { removeButton(profile) }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func removeButton(_ profile: AgentProfile) -> some View {
        if uiV3Enabled {
            Button { remove(profile) } label: {
                Image(systemName: "minus")
                    .bighelpFont(.label, weight: .semibold)
                    .foregroundStyle(theme.danger)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(.circle)
                    .bighelpSurface(.circularControl, isInteractive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(profile.name)")
            .disabled(model.memberIDs.count <= 1)
            .accessibilityHint(model.memberIDs.count <= 1 ? "A chat must keep one agent." : "Removes this agent from the chat.")
            .accessibilityIdentifier("chat.people.remove.\(profile.id)")
        } else {
            Button {
                remove(profile)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
            }
            .buttonStyle(.plain)
            .disabled(model.memberIDs.count <= 1)
            .accessibilityLabel("Remove \(profile.name)")
            .accessibilityHint(model.memberIDs.count <= 1 ? "A chat must keep one agent." : "Removes this agent from the chat.")
            .accessibilityIdentifier("chat.people.remove.\(profile.id)")
        }
    }

    private func add(_ profile: AgentProfile) {
        do {
            try model.addMember(agentID: profile.id)
            errorMessage = nil
        } catch {
            errorMessage = "Agent could not be added. Try again."
        }
    }

    private func remove(_ profile: AgentProfile) {
        do {
            try model.removeMember(agentID: profile.id)
            errorMessage = nil
        } catch {
            errorMessage = BotModeMemberRemovalPresentation.errorMessage(for: error)
        }
    }

    private var membershipExplanation: String {
        if !model.botModeExecutionEnabled {
            return model.botModeStatus ?? "Connect to a compatible Hermes host to start a group chat. Existing shared history stays available."
        }
        if model.botModeRoom?.hasNativeRoom == true {
            return "Hermes runs this shared room. Members are fixed after its first message. Earlier direct history stays private to the original agent."
        }
        return "Members can see new shared turns. Earlier direct history stays private to the original agent."
    }

    private var availableProfiles: [AgentProfile] {
        guard model.canEditBotModeMembership else { return [] }
        let members = Set(model.memberIDs)
        return agents.profiles.filter { !members.contains($0.id) }
    }

    private var memberCountTitle: String {
        "\(model.memberIDs.count) of \(BotModeRoom.maximumMembers) agents"
    }

    @BighelpThemeReader private var theme

}

enum BotModeMemberRemovalPresentation {
    static func errorMessage(for error: any Error) -> String {
        if error as? BotModeRoomError == .sharedHistoryRequiresBotMode {
            return "Group chats with shared messages must keep at least two agents."
        }
        return "Agent could not be removed. Keep at least one agent in this chat."
    }
}
