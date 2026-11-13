import SwiftUI

/// The Bots view's New Group Chat: a section to put the new group chat in.
struct BotModeCreateSectionChoice {
    let sections: [FleetSection]
    /// Files the made group chat (its room ID) in the picked section.
    let file: @MainActor (_ roomID: String, _ sectionID: String) -> Void
}

@MainActor
struct BotModeCreateRoomView: View {
    let rooms: BotModeRoomStore
    let agents: AgentDirectoryStore
    let seedProfileID: String?
    let onCreated: (String) -> Void
    /// An optional Section row.
    let sectionChoice: BotModeCreateSectionChoice?
    @State private var presentationOwnerID: String

    init(rooms: BotModeRoomStore, agents: AgentDirectoryStore, seedProfileID: String?,
         sectionChoice: BotModeCreateSectionChoice? = nil,
         onCreated: @escaping (String) -> Void) {
        self.rooms = rooms
        self.agents = agents
        self.seedProfileID = seedProfileID
        self.sectionChoice = sectionChoice

        self.onCreated = onCreated
        _presentationOwnerID = State(initialValue: rooms.nativePresentationOwnerID)
    }

    private var isGroupSelection: Bool { selected.count >= 2 }

    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<String> = []
    @State private var roomID = "room-\(UUID().uuidString)"
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var isAdvancedExpanded = false
    @State private var routing: HermesBotModeRoomContext.Routing = .everyone
    @State private var leadProfileID: String?
    @State private var purpose = ""
    @FocusState private var isPurposeFocused: Bool
    @State private var sectionID: String?

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
            .navigationTitle("New group chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
            .onAppear {
                if let seedProfileID, selected.isEmpty, pickableProfiles.contains(where: { $0.id == seedProfileID }) {
                    selected.insert(seedProfileID)
                }
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
                ForEach(pickableProfiles) { profile in
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
                Text("Choose two to six bots on this computer. Hermes fixes the participants when the room is created.")
            }
            if let sectionChoice {
                Section { sectionPicker(sectionChoice) }
            }
            if let unseatableNote {
                Section { Text(unseatableNote).accessibilityIdentifier("bot-mode.create.unseatable") }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(theme.danger)
                        .accessibilityIdentifier("bot-mode.create.error")
                }
                if ownerChanged {
                    Section { Text("The selected computer changed. Close this form and reopen it for the current computer.") }
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
                TextField("Group name", text: $name)
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

                VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                    HStack(alignment: .firstTextBaseline) {
                        sectionCaption("Who’s in the chat")
                        Spacer(minLength: BighelpTokens.space8)
                        Text("\(selected.count) of \(BotModeRoom.maximumMembers)")
                            .bighelpFont(.metadata)
                            .monospacedDigit()
                            .foregroundStyle(theme.secondaryText)
                    }
                    if pickableProfiles.isEmpty {
                        Text("No bots on this computer yet.")
                            .bighelpFont(.body)
                            .foregroundStyle(theme.secondaryText)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 88), spacing: BighelpTokens.space8)],
                            spacing: BighelpTokens.space12
                        ) {
                            ForEach(pickableProfiles) { profile in
                                participantRow(profile)
                            }
                        }
                    }
                    Text("Pick 2 to \(BotModeRoom.maximumMembers) bots. Members are fixed once the group is created.")
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if offersRoomSettings { roomSettings }
                if let sectionChoice {
                    sectionPicker(sectionChoice)
                        .padding(.horizontal, BighelpTokens.space16)
                        .frame(minHeight: 52)
                        .background(theme.surface, in: .rect(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(theme.border, lineWidth: BighelpTokens.hairline)
                        }
                }

                if !rooms.canCreateNativeRoom {
                    Label("This computer isn’t ready for group chats yet.", systemImage: "info.circle")
                        .bighelpFont(.label)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("bot-mode.create.unavailable")
                }
                if let unseatableNote {
                    Label(unseatableNote, systemImage: "info.circle")
                        .bighelpFont(.label)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("bot-mode.create.unseatable")
                }
                if ownerChanged {
                    Label(
                        "The selected computer changed. Close this form and reopen it for the current computer.",
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

                advancedDisclosure
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
                Text(hasPendingCreation ? "Check room" : "Create")
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

    /// Hermes keeps a group's settings where it advertises `groups.context`; they're saved
    /// right after the room exists.
    private var offersRoomSettings: Bool {
        rooms.nativeCapabilities?.supports("groups.context") == true
    }

    private var selectedProfiles: [AgentProfile] {
        pickableProfiles.filter { selected.contains($0.id) }
    }

    private var roomSettings: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            sectionCaption("When a message names nobody")
            VStack(spacing: 0) {
                routingOption(.everyone, title: "Everyone answers", hint: "Every bot gets a turn.")
                if rooms.offersAutomaticRoutingForNewRooms {
                    Divider()
                    routingOption(.auto, title: "Pick who answers", hint: "A quick check picks who the message is for.")
                }
                if !selectedProfiles.isEmpty {
                    Divider()
                    leadOption
                }
            }
            .padding(.horizontal, BighelpTokens.space16)
            .background(theme.surface, in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(theme.border, lineWidth: BighelpTokens.hairline)
            }
            .disabled(isSubmitting || hasPendingCreation || ownerChanged)
            Text("@mentions and @everyone always go straight to the bots you name.")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Purpose (optional)", text: $purpose, axis: .vertical)
                .bighelpFont(.body)
                .foregroundStyle(theme.primaryText)
                .lineLimit(1...6)
                .submitLabel(.done)
                .padding(.horizontal, BighelpTokens.space16)
                .padding(.vertical, BighelpTokens.space12)
                .frame(minHeight: 52)
                .background(theme.surface, in: .rect(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(theme.border, lineWidth: BighelpTokens.hairline)
                }
                .disabled(isSubmitting || hasPendingCreation || ownerChanged)
                .focused($isPurposeFocused)
                .accessibilityIdentifier("bot-mode.create.purpose")
                .onChange(of: purpose) { _, value in
                    // One line, as Hermes keeps it, so Return ends the edit.
                    if value.contains("\n") { isPurposeFocused = false }
                    let line = value.replacingOccurrences(of: "\n", with: " ")
                    let limited = String(String.UnicodeScalarView(
                        line.unicodeScalars.prefix(HermesBotModeRoomContext.maximumPurposeCharacters)))
                    if limited != value { purpose = limited }
                }
        }
        .onChange(of: selected) { _, members in
            // A lead who leaves the selection takes lead routing with it.
            if routing == .lead, leadProfileID.map(members.contains) != true {
                routing = .everyone
                leadProfileID = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bot-mode.create.routing")
    }

    private func routingOption(_ option: HermesBotModeRoomContext.Routing, title: String, hint: String) -> some View {
        Button {
            routing = option
            leadProfileID = nil
        } label: {
            GroupRoutingOptionLabel(title: title, hint: hint, isSelected: routing == option)
                .padding(.vertical, BighelpTokens.space4)
        }
        .bighelpPlainButtonStyle()
        .accessibilityAddTraits(routing == option ? .isSelected : [])
        .accessibilityIdentifier("bot-mode.create.routing.\(option.rawValue)")
    }

    private var leadOption: some View {
        let lead = routing == .lead ? selectedProfiles.first { $0.id == leadProfileID } : nil
        return Menu {
            ForEach(selectedProfiles) { profile in
                Button(profile.name) {
                    routing = .lead
                    leadProfileID = profile.id
                }
            }
        } label: {
            GroupRoutingOptionLabel(title: "A lead passes it on", hint: "The lead picks who takes it.",
                                    isSelected: routing == .lead, detail: lead?.name, showsChevron: true)
                .padding(.vertical, BighelpTokens.space4)
        }
        .bighelpPlainButtonStyle()
        .accessibilityAddTraits(routing == .lead ? .isSelected : [])
        .accessibilityValue(lead.map { "Lead: \($0.name)" } ?? "")
        .accessibilityIdentifier("bot-mode.create.routing.lead")
    }

    /// What the new room starts with, or nil to keep Hermes' defaults (everyone answers).
    private var newRoomContext: HermesBotModeRoomContext? {
        guard offersRoomSettings else { return nil }
        let context = HermesBotModeRoomContext(purpose: purpose, routing: routing,
                                               leadMemberID: routing == .lead ? leadProfileID : nil)
        guard context.isSavable, routing != .everyone || !HermesBotModeRoomContext.savedPurpose(purpose).isEmpty else {
            return nil
        }
        return context
    }

    /// Mention handles and hosting details most people never need.
    private var advancedDisclosure: some View {
        DisclosureGroup(isExpanded: $isAdvancedExpanded) {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                if selectedHandles.isEmpty {
                    Text("Pick bots to see how you’ll mention them.")
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
                    Text("Hermes hosts this group on the selected computer. Mention @handle for one bot or @all for everyone. Earlier direct chats stay private.")
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

    /// Section: none, or one of the person's sections.
    private func sectionPicker(_ choice: BotModeCreateSectionChoice) -> some View {
        Picker(selection: $sectionID) {
            Text("None").tag(String?.none)
            ForEach(choice.sections) { section in
                Text(section.name).tag(Optional(section.id))
            }
        } label: {
            Text("Section")
                .bighelpFont(.body)
                .foregroundStyle(theme.primaryText)
        }
        .pickerStyle(.menu)
        .disabled(isSubmitting || hasPendingCreation || ownerChanged)
        .accessibilityIdentifier("bot-mode.create.section")
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
        .accessibilityHint("Double-tap to select or deselect this bot.")
        .accessibilityIdentifier("bot-mode.create.participant.\(profile.id)")
    }

    private var isCreateDisabled: Bool {
        isSubmitting || ownerChanged || !rooms.canCreateNativeRoom
            || !(2...BotModeRoom.maximumMembers).contains(selected.count)
            || unseatableNote != nil
            || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || name.count > 200
    }

    /// Hermes says which agents it can seat in a group (`seatable_profiles`): only those are listed.
    private var pickableProfiles: [AgentProfile] {
        guard let capabilities = rooms.nativeCapabilities else { return agents.profiles }
        return agents.profiles.filter { capabilities.canSeat(profile: $0.id) }
    }

    private var unseatableNote: String? {
        guard isGroupSelection, let capabilities = rooms.nativeCapabilities else { return nil }
        let names = agents.profiles.filter { selected.contains($0.id) && !capabilities.canSeat(profile: $0.id) }
            .map(\.name)
        guard !names.isEmpty else { return nil }
        return names.count == 1
            ? "\(names[0]) can’t join group chats on this computer."
            : "\(ListFormatter.localizedString(byJoining: names)) can’t join group chats on this computer."
    }

    /// A group named after its agents: "Juno & Alfie", "Juno, Alfie & Nova". New chat names the group
    /// it makes this way.
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
        guard !ownerChanged else {
            errorMessage = "The selected computer changed. Reopen this form before creating a room."
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let room = try await rooms.createNativeRoom(
                roomID: roomID, name: name,
                profiles: agents.profiles.filter { selected.contains($0.id) }
            )
            guard !ownerChanged, !Task.isCancelled else { throw WorkspaceClientError.ownerChanged }
            // A save Hermes doesn't confirm stays with the room, in its Group Settings.
            if let newRoomContext { await rooms.saveNativeRoomContext(roomID: room.id, newRoomContext) }
            errorMessage = nil
            if let sectionChoice, let sectionID { sectionChoice.file(room.id, sectionID) }
            onCreated(room.id)
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = hasPendingCreation
                ? "The room could not be confirmed. Check this same room before creating another."
                : "The room could not be created. Check the computer and participants, then try again."
        }
    }
}
