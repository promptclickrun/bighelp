import SwiftUI

/// Group Settings for a group chat Hermes runs itself: its name and members (the lead marked),
/// who answers a message that names nobody, and what every bot keeps in mind (its purpose and
/// shared notes). It needs only the room store, so any screen can open it
/// (`AppRoute.groupSettings`). Changes save as they're made and when the page closes; an edit
/// Hermes didn't save stays here with the reason, to try again or discard. A room whose state
/// has no settings shows only its name and members.
@MainActor
struct GroupSettingsView: View {
    let roomID: String
    let rooms: BotModeRoomStore
    let agents: AgentDirectoryStore
    /// The group's open chat, for what it shows on this device (tool calls); nil leaves that out.
    let chat: ChatModel?

    @State private var draft = HermesBotModeRoomContext()
    /// The settings the draft started from; the draft follows Hermes while it's untouched.
    @State private var basis: HermesBotModeRoomContext?
    @State private var isLoading = false
    @State private var loadProblem: String?
    @State private var isPickingLead = false
    @State private var isRenaming = false
    @State private var nameDraft = ""
    @State private var renameProblem: String?
    @FocusState private var focus: Field?
    @ScaledMetric(relativeTo: .body) private var faceColumn: CGFloat = 80
    @BighelpThemeReader private var theme

    private enum Field: Hashable { case purpose, notes }

    init(roomID: String, rooms: BotModeRoomStore, agents: AgentDirectoryStore, chat: ChatModel? = nil) {
        self.roomID = roomID
        self.rooms = rooms
        self.agents = agents
        self.chat = chat
        // What this connection already read, so the first frame isn't empty; an edit Hermes
        // didn't save comes back as it was.
        let saved = rooms.nativeRoomSettings[roomID]?.context
        _draft = State(initialValue: rooms.room(id: roomID)?.nativePendingContext?.context
            ?? saved ?? HermesBotModeRoomContext())
        _basis = State(initialValue: saved)
    }

    var body: some View {
        List {
            identitySection
            if let problem = pendingEdit?.problem { problemSection(problem) }
            if canChangeSettings {
                if draft.routing != nil { routingSection }
                mindSection
            } else if settings == nil, isLoading {
                Section {
                    ProgressView("Loading settings")
                        .frame(maxWidth: .infinity)
                }
                .listRowBackground(theme.surface)
            } else if settings == nil, let loadProblem {
                Section {
                    Text(loadProblem)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again") { Task { await load() } }
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .accessibilityIdentifier("group-settings.reload")
                }
                .listRowBackground(theme.surface)
            }
            if let chat { displaySection(chat) }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .dismissesKeyboardOnScroll(true)
        .background(theme.canvas.ignoresSafeArea())
        .tint(theme.action)
        .navigationTitle("Group Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isPickingLead) { leadPicker }
        .toolbar {
            #if !os(visionOS) // Vision Pro's keyboard has its own dismiss key.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
                    .accessibilityLabel("Dismiss keyboard")
            }
            #endif
        }
        .task { await load() }
        .onChange(of: settings?.context) { _, context in follow(context) }
        .onChange(of: focus) { old, new in
            if old != nil, new != old { save() }
        }
        .onDisappear { save() }
        .alert("Rename group", isPresented: $isRenaming) {
            TextField("Group name", text: $nameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await rename() } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("group-settings")
    }

    // MARK: Sections

    private var identitySection: some View {
        Section {
            VStack(spacing: BighelpTokens.space12) {
                VStack(spacing: BighelpTokens.space4) {
                    Text(room?.title ?? "Group chat")
                        .font(.bighelp(.title2).weight(.bold))
                        .foregroundStyle(theme.primaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(participants.count == 1 ? "1 bot" : "\(participants.count) bots")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                }
                if rooms.nativeCapabilities?.supports("groups.rename") == true {
                    Button {
                        // A name Hermes didn't confirm goes again as it was.
                        nameDraft = room?.nativePendingRename?.name ?? room?.title ?? ""
                        isRenaming = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                            .font(.bighelp(.subheadline))
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityIdentifier("group-settings.rename")
                }
                if let renameProblem {
                    Text(renameProblem)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.danger)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: faceColumn), spacing: BighelpTokens.space8, alignment: .top)],
                          spacing: BighelpTokens.space12) {
                    ForEach(participants) { participant in face(participant) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("group-settings.members")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BighelpTokens.space8)
        }
        .listRowBackground(Color.clear)
    }

    private func face(_ participant: HermesBotModeParticipant) -> some View {
        let isLead = draft.routing == .lead && draft.leadMemberID == participant.memberID && canChangeSettings
        return VStack(spacing: BighelpTokens.space4) {
            avatar(participant, size: 52)
                .opacity(participant.availability == .profileUnavailable ? 0.5 : 1)
            Text(participant.displayName)
                .font(.bighelp(.caption))
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if isLead {
                Text("Lead")
                    .font(.bighelp(.caption2).weight(.semibold))
                    .foregroundStyle(theme.actionForeground)
                    .padding(.horizontal, BighelpTokens.space8)
                    .padding(.vertical, 2)
                    .background(theme.action, in: .capsule)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isLead ? "\(participant.displayName), lead" : participant.displayName)
        .accessibilityIdentifier("group-settings.member.\(participant.memberID)")
    }

    private var routingSection: some View {
        Section {
            routingRow(.everyone, title: "Everyone answers", hint: "Every bot gets a turn.")
            if settings?.offersAutomaticRouting == true {
                routingRow(.auto, title: "Pick who answers", hint: "A quick check picks who the message is for.")
            }
            leadRow
        } header: {
            Text("When a message names nobody")
                .textCase(.uppercase)
        } footer: {
            Text("@mentions and @everyone always go straight to the bots you name.")
        }
        .listRowBackground(theme.surface)
    }

    private func routingRow(_ routing: HermesBotModeRoomContext.Routing, title: String, hint: String) -> some View {
        Button {
            focus = nil
            draft.routing = routing
            draft.leadMemberID = nil
            save()
        } label: {
            GroupRoutingOptionLabel(title: title, hint: hint, isSelected: draft.routing == routing)
        }
        .bighelpPlainButtonStyle()
        .accessibilityAddTraits(draft.routing == routing ? .isSelected : [])
        .accessibilityIdentifier("group-settings.routing.\(routing.rawValue)")
    }

    private var leadRow: some View {
        let isSelected = draft.routing == .lead
        let lead = isSelected ? participants.first { $0.memberID == draft.leadMemberID } : nil
        return Button {
            focus = nil
            isPickingLead = true
        } label: {
            GroupRoutingOptionLabel(title: "A lead passes it on", hint: "The lead picks who takes it.",
                                    isSelected: isSelected, detail: lead?.displayName, showsChevron: true)
        }
        .bighelpPlainButtonStyle()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(lead.map { "Lead: \($0.displayName)" } ?? "")
        .accessibilityHint("Opens the list of bots to pick the lead.")
        .accessibilityIdentifier("group-settings.routing.lead")
    }

    private var mindSection: some View {
        Section {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text("Purpose")
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                TextField("Purpose", text: $draft.purpose,
                          prompt: Text("What this group is for").bighelpFieldHint(theme))
                    .font(.bighelp(.body))
                    .submitLabel(.done)
                    .focused($focus, equals: .purpose)
                    .onSubmit { focus = nil }
                    .bighelpMacField()
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityIdentifier("group-settings.purpose")
            }
            .onChange(of: draft.purpose) { _, purpose in
                // One line, as Hermes keeps it; longer ones stop at its limit.
                let line = purpose.replacingOccurrences(of: "\n", with: " ")
                let limited = String(String.UnicodeScalarView(
                    line.unicodeScalars.prefix(HermesBotModeRoomContext.maximumPurposeCharacters)))
                if limited != purpose { draft.purpose = limited }
            }
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text("Shared notes")
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                TextEditor(text: $draft.notes)
                    .font(.bighelp(.body))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .notes)
                    .overlay(alignment: .topLeading) {
                        if draft.notes.isEmpty {
                            Text("Facts every bot should know")
                                .font(.bighelp(.body))
                                .foregroundStyle(theme.tertiaryText)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .bighelpMacFieldArea()
                    .accessibilityLabel("Shared notes")
                    .accessibilityIdentifier("group-settings.notes")
                HStack(alignment: .firstTextBaseline) {
                    if notesTooLong {
                        Text("Shorten the notes to save them.")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: BighelpTokens.space8)
                    Text("\(notesBytes.formatted()) of \(HermesBotModeRoomContext.maximumNotesBytes.formatted())")
                        .font(.bighelp(.footnote))
                        .monospacedDigit()
                        .foregroundStyle(notesTooLong ? theme.danger : theme.secondaryText)
                        .accessibilityLabel("\(notesBytes) of \(HermesBotModeRoomContext.maximumNotesBytes) bytes used")
                        .accessibilityIdentifier("group-settings.notes-count")
                }
            }
        } header: {
            Text("What every bot keeps in mind")
                .textCase(.uppercase)
        } footer: {
            if rooms.nativeRoomSettingsSaving.contains(roomID) {
                Text("Saving…")
                    .accessibilityIdentifier("group-settings.saving")
            }
        }
        .listRowBackground(theme.surface)
    }

    private func displaySection(_ chat: ChatModel) -> some View {
        Section {
            Toggle("Show tool calls", isOn: Binding(
                get: { chat.activityVisibility.showToolCalls },
                set: { chat.setToolCallsVisible($0) }
            ))
            .frame(minHeight: BighelpTokens.hitTarget)
            .accessibilityIdentifier("group-settings.tools")
        } header: {
            Text("On this device")
                .textCase(.uppercase)
        } footer: {
            Text("Shows what the bots do while they work, when Hermes shares it.")
        }
        .listRowBackground(theme.surface)
    }

    private func problemSection(_ problem: String) -> some View {
        Section {
            Label {
                Text(problem)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.warning)
            }
            .accessibilityIdentifier("group-settings.problem")
            Button("Try again") {
                focus = nil
                Task { await rooms.saveNativeRoomContext(roomID: roomID, draft) }
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .disabled(!draft.isSavable || rooms.nativeRoomSettingsSaving.contains(roomID))
            .accessibilityIdentifier("group-settings.retry")
            Button("Discard changes", role: .destructive) {
                focus = nil
                try? rooms.discardNativeRoomContextEdit(roomID: roomID)
                if let context = settings?.context {
                    draft = context
                    basis = context
                }
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .accessibilityIdentifier("group-settings.discard")
        }
        .listRowBackground(theme.surface)
    }

    private var leadPicker: some View {
        List {
            Section {
                ForEach(participants) { participant in
                    Button {
                        draft.routing = .lead
                        draft.leadMemberID = participant.memberID
                        isPickingLead = false
                        save()
                    } label: {
                        HStack(spacing: BighelpTokens.space12) {
                            avatar(participant, size: 40)
                            Text(participant.displayName)
                                .font(.bighelp(.body))
                                .foregroundStyle(theme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: BighelpTokens.space8)
                            if draft.routing == .lead, draft.leadMemberID == participant.memberID {
                                Image(systemName: "checkmark")
                                    .font(.bighelp(.body).weight(.semibold))
                                    .foregroundStyle(theme.action)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                    }
                    .bighelpPlainButtonStyle()
                    .accessibilityAddTraits(draft.leadMemberID == participant.memberID ? .isSelected : [])
                    .accessibilityIdentifier("group-settings.lead.\(participant.memberID)")
                }
            } footer: {
                Text("A message that names nobody goes to the lead first. The lead picks who takes it.")
            }
            .listRowBackground(theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .tint(theme.action)
        .navigationTitle("Lead")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("group-settings.lead-picker")
    }

    private func avatar(_ participant: HermesBotModeParticipant, size: CGFloat) -> some View {
        // The member's ID, as the chat's header and messages draw it.
        AvatarView(
            stableID: participant.memberID, displayName: participant.displayName,
            imageURL: participant.peerImageURL ?? participant.profile.flatMap { agents.avatarURL(for: $0) },
            size: size
        )
        .accessibilityHidden(true)
    }

    // MARK: State

    private var room: BotModeRoom? { rooms.room(id: roomID) }
    private var settings: HermesBotModeRoomSettings? { rooms.nativeRoomSettings[roomID] }
    private var pendingEdit: HermesBotModeContextIntent? { room?.nativePendingContext }
    /// The settings show only where Hermes keeps them for this room and this connection can save them.
    private var canChangeSettings: Bool {
        settings != nil && rooms.nativeCapabilities?.supports("groups.context") == true
    }
    private var participants: [HermesBotModeParticipant] {
        (room?.nativeState?.members ?? []).map {
            HermesBotModeParticipant(member: $0, profiles: agents.profiles, peers: rooms.peerHosts)
        }
    }
    private var notesBytes: Int { HermesBotModeRoomContext.notesBytes(draft.notes) }
    private var notesTooLong: Bool { notesBytes > HermesBotModeRoomContext.maximumNotesBytes }

    /// Reads the settings again each time the page shows (also back from the lead list). The
    /// draft stays: it follows Hermes only while untouched (`follow`).
    private func load() async {
        isLoading = true
        let problem = await rooms.refreshNativeRoomSettings(roomID: roomID)
        isLoading = false
        loadProblem = problem
        // The first read of a room this connection hadn't read yet.
        if basis == nil, let settings {
            basis = settings.context
            if pendingEdit == nil { draft = settings.context }
        }
    }

    /// Another device's change shows here while the person hasn't changed anything.
    private func follow(_ context: HermesBotModeRoomContext?) {
        guard let context else { return }
        let untouched = basis.map { HermesBotModeContextIntent(eventID: "", context: $0).isSameEdit(as: draft) } ?? true
        if untouched, pendingEdit == nil, focus == nil { draft = context }
        if untouched { basis = context }
    }

    /// Saves the draft when it differs from what Hermes has. An edit Hermes didn't save goes
    /// again only from Try again.
    private func save() {
        guard canChangeSettings, draft.isSavable, let settings else { return }
        if let pendingEdit, pendingEdit.isSameEdit(as: draft) { return }
        if pendingEdit == nil, HermesBotModeContextIntent(eventID: "", context: settings.context).isSameEdit(as: draft) {
            return
        }
        let edit = draft
        basis = edit
        Task { await rooms.saveNativeRoomContext(roomID: roomID, edit) }
    }

    private func rename() async {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != room?.title || room?.nativePendingRename != nil else { return }
        do {
            try await rooms.renameNativeRoom(roomID: roomID, name: name)
            renameProblem = nil
        } catch is CancellationError {
            return
        } catch {
            renameProblem = "The new name wasn’t confirmed. Check the connection, then try again."
        }
    }
}

/// A radio row for who answers a message that names nobody, here and in New Group Chat.
struct GroupRoutingOptionLabel: View {
    let title: String
    let hint: String
    let isSelected: Bool
    var detail: String? = nil
    var showsChevron = false

    var body: some View {
        HStack(alignment: .center, spacing: BighelpTokens.space12) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.bighelp(.title3))
                .foregroundStyle(isSelected ? theme.action : theme.tertiaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(hint)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: BighelpTokens.space8)
            if let detail {
                Text(detail)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(.rect)
    }

    @BighelpThemeReader private var theme
}
