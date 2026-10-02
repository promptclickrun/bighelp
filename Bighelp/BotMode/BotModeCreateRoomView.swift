import SwiftUI

@MainActor
struct BotModeCreateRoomView: View {
    let rooms: BotModeRoomStore
    let agents: AgentDirectoryStore
    let seedProfileID: String?
    let onCreated: (String) -> Void
    /// New chat mode: one agent starts a 1:1 chat, two or more a group.
    let onStartDirect: ((String) -> Void)?
    @State private var presentationOwnerID: String

    init(rooms: BotModeRoomStore, agents: AgentDirectoryStore, seedProfileID: String?,
         onStartDirect: ((String) -> Void)? = nil,
         onCreated: @escaping (String) -> Void) {
        self.rooms = rooms
        self.agents = agents
        self.seedProfileID = seedProfileID
        self.onStartDirect = onStartDirect
        self.onCreated = onCreated
        _presentationOwnerID = State(initialValue: rooms.nativePresentationOwnerID)
    }

    private var startsDirectChat: Bool { onStartDirect != nil && selected.count == 1 }
    private var isGroupSelection: Bool { selected.count >= 2 }

    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<String> = []
    @State private var roomID = "room-\(UUID().uuidString)"
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var isAdvancedExpanded = false

    private var hasPendingCreation: Bool { rooms.room(id: roomID)?.nativePendingCreation != nil }
    private var ownerChanged: Bool { rooms.nativePresentationOwnerID != presentationOwnerID }

    var body: some View {
        NavigationStack {
            Group {
                if uiV3Enabled {
                    nativeForm
                } else {
                    legacyForm
                }
            }
            .background(theme.canvas)
            .navigationTitle(onStartDirect == nil ? "New group chat" : "New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
            .onAppear {
                if let seedProfileID, selected.isEmpty { selected.insert(seedProfileID) }
            }
        }
    }

    private var legacyForm: some View {
        Form {
            Section("Group") {
                TextField("Title", text: $name)
                    .disabled(isSubmitting || hasPendingCreation || ownerChanged)
                    .accessibilityIdentifier("bot-mode.create.title")
            }
            Section {
                ForEach(agents.profiles) { profile in
                    Button {
                        toggle(profile)
                    } label: {
                        HStack {
                            Text(profile.name)
                            Spacer()
                            if selected.contains(profile.id) {
                                Image(systemName: "checkmark").accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                    }
                    .disabled(isSubmitting || hasPendingCreation || ownerChanged)
                    .accessibilityIdentifier("bot-mode.create.participant.\(profile.id)")
                    .accessibilityValue(selected.contains(profile.id) ? "Selected" : "Not selected")
                }
            } header: {
                Text("Participants")
            } footer: {
                Text("Choose two to six agents on this host. Hermes fixes the participants when the room is created.")
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(theme.danger)
                        .accessibilityIdentifier("bot-mode.create.error")
                }
                if ownerChanged {
                    Section { Text("The selected host changed. Close this form and reopen it for the current host.") }
                }
            }
            Section {
                Button(hasPendingCreation ? "Check room" : "Create room") {
                    Task { await create() }
                }
                .disabled(isCreateDisabled)
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("bot-mode.create.submit")
                if isSubmitting { ProgressView("Confirming with Hermes") }
            }
        }
    }

    private var nativeForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space24) {
                if onStartDirect == nil || isGroupSelection {
                TextField(onStartDirect == nil ? "Group name" : "Group name (optional)", text: $name)
                    .textInputAutocapitalization(.words)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, BighelpTokens.space16)
                    .frame(minHeight: 52)
                    .background(theme.surface, in: .rect(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(theme.border, lineWidth: BighelpTokens.hairline)
                    }
                    .disabled(isSubmitting || hasPendingCreation || ownerChanged)
                    .accessibilityIdentifier("bot-mode.create.title")
                }

                VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                    HStack(alignment: .firstTextBaseline) {
                        sectionCaption("Who’s in the chat")
                        Spacer(minLength: BighelpTokens.space8)
                        Text("\(selected.count) of \(BotModeRoom.maximumMembers)")
                            .bighelpFont(.metadata)
                            .monospacedDigit()
                            .foregroundStyle(theme.secondaryText)
                    }
                    if agents.profiles.isEmpty {
                        Text("No agents on this host yet.")
                            .bighelpFont(.body)
                            .foregroundStyle(theme.secondaryText)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 88), spacing: BighelpTokens.space8)],
                            spacing: BighelpTokens.space12
                        ) {
                            ForEach(agents.profiles) { profile in
                                participantRow(profile)
                            }
                        }
                    }
                    Text(onStartDirect == nil
                         ? "Pick 2 to \(BotModeRoom.maximumMembers) agents. Members are fixed once the group is created."
                         : "Pick one agent to chat 1:1, or up to \(BotModeRoom.maximumMembers) for a group chat.")
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !rooms.canCreateNativeRoom, onStartDirect == nil || isGroupSelection {
                    Label("This host isn’t ready for group chats yet.", systemImage: "info.circle")
                        .bighelpFont(.label)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("bot-mode.create.unavailable")
                }
                if ownerChanged {
                    Label(
                        "The selected host changed. Close this form and reopen it for the current host.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .bighelpFont(.label)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("bot-mode.create.owner-changed")
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .bighelpFont(.label)
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("bot-mode.create.error")
                }

                if onStartDirect == nil || isGroupSelection { advancedDisclosure }
            }
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.vertical, BighelpTokens.space16)
            .bighelpShellContentWidth()
        }
        .dismissesKeyboardOnScroll(true)
        .safeAreaInset(edge: .bottom) { createBar }
    }

    private var createBar: some View {
        VStack(spacing: BighelpTokens.space8) {
            if isSubmitting {
                ProgressView("Confirming with Hermes")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
            }
            Button {
                Task { await create() }
            } label: {
                Text(hasPendingCreation ? "Check room" : createTitle)
                    .bighelpFont(.body, weight: .semibold)
                    .foregroundStyle(theme.actionForeground)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(theme.action, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .opacity(isCreateDisabled ? 0.45 : 1)
            .disabled(isCreateDisabled)
            .accessibilityIdentifier("bot-mode.create.submit")
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, BighelpTokens.space20)
        .padding(.top, BighelpTokens.space8)
        .padding(.bottom, BighelpTokens.space12)
        .frame(maxWidth: .infinity)
        .background(theme.canvas.opacity(0.94))
    }

    /// Mention handles and hosting details most people never need.
    private var advancedDisclosure: some View {
        DisclosureGroup(isExpanded: $isAdvancedExpanded) {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                if selectedHandles.isEmpty {
                    Text("Pick agents to see how you’ll mention them.")
                        .bighelpFont(.label)
                        .foregroundStyle(theme.secondaryText)
                } else {
                    ForEach(selectedHandles, id: \.profileID) { handle in
                        HStack {
                            Text(agents.profiles.first { $0.id == handle.profileID }?.name ?? handle.profileID)
                                .bighelpFont(.label)
                                .foregroundStyle(theme.primaryText)
                            Spacer(minLength: BighelpTokens.space8)
                            Text("@\(handle.handle)")
                                .bighelpFont(.label)
                                .foregroundStyle(theme.secondaryText)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Label {
                    Text("Hermes hosts this group on the selected host. Mention @handle for one agent or @all for everyone. Earlier direct chats stay private.")
                } icon: {
                    Image(systemName: "lock.shield")
                }
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, BighelpTokens.space12)
        } label: {
            Text("Advanced")
                .bighelpFont(.label, weight: .semibold)
                .foregroundStyle(theme.primaryText)
                .frame(minHeight: BighelpTokens.hitTarget)
        }
        .tint(theme.secondaryText)
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space4)
        .background(theme.surface, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.border, lineWidth: BighelpTokens.hairline)
        }
        .accessibilityIdentifier("bot-mode.create.advanced")
    }

    /// The same handle assignment `createNativeRoom` sends to Hermes.
    private var selectedHandles: [AgentHandle] {
        NativeBotModeHandles.directory(for: agents.profiles.filter { selected.contains($0.id) })
    }

    private func sectionCaption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(theme.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }

    private func participantRow(_ profile: AgentProfile) -> some View {
        let isSelected = selected.contains(profile.id)
        return Button {
            toggle(profile)
        } label: {
            VStack(spacing: BighelpTokens.space8) {
                AvatarView(
                    stableID: profile.id,
                    displayName: profile.name,
                    imageURL: agents.avatarURL(for: profile),
                    size: 44
                )
                .padding(3)
                .overlay {
                    Circle().stroke(isSelected ? theme.action : .clear, lineWidth: 2)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            isSelected ? theme.actionForeground : theme.tertiaryText,
                            isSelected ? theme.action : theme.surface
                        )
                        .background(Circle().fill(isSelected ? theme.action : theme.surface))
                        .offset(x: 3, y: 3)
                }
                .accessibilityHidden(true)
                Text(profile.name)
                    .bighelpFont(.metadata, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, BighelpTokens.space8)
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
            .background(isSelected ? theme.action.opacity(0.08) : .clear, in: .rect(cornerRadius: 14))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting || hasPendingCreation || ownerChanged
            || (!isSelected && selected.count >= BotModeRoom.maximumMembers))
        .accessibilityLabel(profile.role.isEmpty ? profile.name : "\(profile.name), \(profile.role)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Double-tap to select or deselect this agent.")
        .accessibilityIdentifier("bot-mode.create.participant.\(profile.id)")
    }

    private var createTitle: String {
        guard onStartDirect != nil else { return "Create" }
        return isGroupSelection ? "Start group chat" : "Start chat"
    }

    private var isCreateDisabled: Bool {
        if startsDirectChat { return isSubmitting || ownerChanged }
        return isSubmitting || ownerChanged || !rooms.canCreateNativeRoom
            || !(2...BotModeRoom.maximumMembers).contains(selected.count)
            || (onStartDirect == nil && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || name.count > 200
    }

    /// New-chat groups may skip the name.
    private var groupName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.isEmpty else { return typed }
        return Self.automaticName(agents.profiles.filter { selected.contains($0.id) }.map(\.name))
    }

    /// A group named after its agents: "Juno & Alfie", "Juno, Alfie & Nova".
    static func automaticName(_ names: [String]) -> String {
        guard let last = names.last else { return "Group chat" }
        let joined = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " & " + last
        return String(joined.prefix(200))
    }

    @BighelpThemeReader private var theme

    private func toggle(_ profile: AgentProfile) {
        if selected.contains(profile.id) {
            selected.remove(profile.id)
        } else if selected.count < BotModeRoom.maximumMembers {
            selected.insert(profile.id)
        }
    }

    private func create() async {
        guard !isSubmitting else { return }
        if startsDirectChat, let agentID = selected.first, let onStartDirect {
            dismiss()
            onStartDirect(agentID)
            return
        }
        guard !ownerChanged else {
            errorMessage = "The selected host changed. Reopen this form before creating a room."
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let room = try await rooms.createNativeRoom(
                roomID: roomID, name: onStartDirect == nil ? name : groupName,
                profiles: agents.profiles.filter { selected.contains($0.id) }
            )
            guard !ownerChanged, !Task.isCancelled else { throw WorkspaceClientError.ownerChanged }
            errorMessage = nil
            onCreated(room.id)
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = hasPendingCreation
                ? "The room could not be confirmed. Check this same room before creating another."
                : "The room could not be created. Check the host and participants, then try again."
        }
    }
}
