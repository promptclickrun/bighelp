import SwiftUI

/// What the Bots view's + offers, in this order, each only where it can work: nothing is gray.
enum SimpleBotsNewItem: String, Identifiable, CaseIterable {
    case bot, groupChat = "group", section

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .bot: "New Bot"
        case .groupChat: "New Group Chat"
        case .section: "New Section"
        }
    }

    var systemImage: String {
        switch self {
        case .bot: "person.crop.circle.badge.plus"
        case .groupChat: "plus.bubble"
        case .section: "folder.badge.plus"
        }
    }

    static func available(canCreateBots: Bool, canCreateGroups: Bool, hasSections: Bool) -> [SimpleBotsNewItem] {
        allCases.filter { item in
            switch item {
            case .bot: canCreateBots
            case .groupChat: canCreateGroups
            case .section: hasSections
            }
        }
    }
}

extension SimpleBotsContext {
    /// On the bot's own computer: the gateway in use through its live list, another through its copy.
    func savePlacement(_ bot: SimpleBotsBot, _ placement: AgentListPlacement) async throws {
        if bot.profile != nil {
            try await agents.setPlacement(placement, profileID: bot.profileID)
        } else if let agent = bot.fleetAgent, let fleet {
            try await fleet.savePlacement(placement, for: agent)
        }
    }

    /// What the sections sheets work on, for these bots and group chats; nil without sections.
    func sectionsModel(bots: [SimpleBotsBot], groups: [SimpleBotsGroup]) -> SimpleBotsSectionsModel? {
        guard let fleet else { return nil }
        let sectioning = SimpleBotsSectioning(fleet: fleet)
        let byName = { (left: SimpleBotsItem, right: SimpleBotsItem) in
            left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        let candidates = bots.filter { !$0.isHidden }
            .map { SimpleBotsItem(kind: .bot($0), preview: nil, date: nil, isPinned: false) }.sorted(by: byName)
            + groups.filter { $0.key != nil && !sectioning.isHidden($0) }
            .map { SimpleBotsItem(kind: .group($0), preview: nil, date: nil, isPinned: false) }.sorted(by: byName)
        let editor = SimpleBotsSectionEditor(fleet: fleet, bots: bots, groups: groups) { bot, placement in
            try await savePlacement(bot, placement)
        }
        return SimpleBotsSectionsModel(
            editor: editor, candidates: candidates,
            hostNames: gateways == nil ? nil
                : Dictionary(fleet.hosts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
    }

    /// The gateway in use's bots and group chats (hidden ones too), as the Bots view lists them with one computer shown.
    var oneGatewayBots: [SimpleBotsBot] {
        agents.profiles.map { SimpleBotsBot($0, imageURL: agents.avatarURL(for: $0)) }
    }

    var oneGatewayGroups: [SimpleBotsGroup] {
        SimpleBotsHomeProjection.groups(catalog.recentSummaries(includeCronSessions: false), rooms: rooms,
                                        hostID: fleet?.selectedHostID, bots: oneGatewayBots)
    }
}

// Sections and group chats on the Bots view, and a section's own page.
extension SimpleBotsHomeView {
    // MARK: Sections

    /// Every bot the home can file, hidden ones too, on the gateways it shows.
    var sectionBots: [SimpleBotsBot] {
        guard let gateways = context.gateways else { return context.oneGatewayBots }
        let shown = filteredGateway
        return gateways.bots.filter { shown == nil || $0.hostID == shown }
    }

    /// Every group chat the home can show, hidden ones too.
    var sectionGroups: [SimpleBotsGroup] {
        guard let gateways = context.gateways else { return context.oneGatewayGroups }
        let shown = filteredGateway
        return gateways.groups.filter { shown == nil || $0.hostID == shown }
    }

    var hiddenGroups: [SimpleBotsGroup] {
        let sectioning = sectioning
        return sectionGroups.filter(sectioning.isHidden)
    }

    /// What the sections sheets work on; nil without sections here.
    var sectionsModel: SimpleBotsSectionsModel? {
        context.sectionsModel(bots: sectionBots, groups: sectionGroups)
    }

    func sectionGrid(_ home: SimpleBotsHomeProjection.Home) -> some View {
        SimpleBotsSectionGrid(cards: home.sections, isUnread: isUnread, open: { context.onOpenSection?($0.id) },
                              prompt: { sectionPrompt = $0 })
    }

    func isUnread(_ card: SimpleBotsSectionCard) -> Bool {
        card.members.contains { item in
            switch item.kind {
            case .bot(let bot): isUnread(bot)
            case .group(let group): isUnread(group)
            }
        }
    }

    /// Move to Section: each section (a check on its own), No section, and New Section….
    @ViewBuilder
    func moveToSectionMenu(_ kind: SimpleBotsItem.Kind) -> some View {
        if let fleet = context.fleet, Self.canFile(kind) {
            let current = SimpleBotsSectioning(fleet: fleet).section(of: kind)?.id
            Menu {
                ForEach(fleet.sections) { section in
                    Button { move(kind, to: section.id) } label: {
                        if current == section.id { Label(section.name, systemImage: "checkmark") } else { Text(section.name) }
                    }
                }
                Button { move(kind, to: nil) } label: {
                    if current == nil { Label("No section", systemImage: "checkmark") } else { Text("No section") }
                }
                Divider()
                Button("New Section…", systemImage: "folder.badge.plus") {
                    sectionPrompt = .new(picked: [SimpleBotsItem(kind: kind, preview: nil, date: nil, isPinned: false).id])
                }
            } label: {
                Label("Move to Section", systemImage: "folder")
            }
        }
    }

    /// The editor is made at the tap, so a menu costs only its rows.
    private func move(_ kind: SimpleBotsItem.Kind, to sectionID: String?) {
        guard let editor = sectionsModel?.editor else { return }
        Task { await editor.move(kind, to: sectionID) }
    }

    /// A group chat needs its gateway to keep a section.
    static func canFile(_ kind: SimpleBotsItem.Kind) -> Bool {
        if case .group(let group) = kind { return group.key != nil }
        return true
    }

    // MARK: A section's page

    func sectionPage(_ home: SimpleBotsHomeProjection.Home, sectionID: String) -> some View {
        let card = home.sections.first { $0.id == sectionID }
        let spans = (card?.hostIDs.count ?? 0) > 1
        return Group {
            if let card {
                if arranging != nil {
                    arrangeList(home, rows: card.members, showsTop: false)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            SimpleBotsFolderFaces(members: card.members, cell: 64)
                                .padding(BighelpTokens.space24)
                                .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius28, style: .continuous))
                                .padding(.top, BighelpTokens.space16)
                                .padding(.bottom, BighelpTokens.space24)
                            ForEach(card.members) { item in
                                row(item, home: home, hostName: spans ? item.hostID.flatMap { context.fleet?.hostName($0) } : nil)
                            }
                            addMembersRow(card.section)
                        }
                        .padding(.bottom, BighelpTokens.space32)
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            } else {
                ContentUnavailableView("Nothing to show here", systemImage: "folder",
                                       description: Text("This section's bots and group chats are on other computers."))
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // Deleted, here or on another device: back to where it opened from.
        .onChange(of: context.fleet?.section(id: sectionID) == nil) { _, gone in if gone { dismiss() } }
    }

    /// Back, the section's name (and its computers when it has several), and its actions.
    func sectionHeader(_ sectionID: String, home: SimpleBotsHomeProjection.Home) -> some View {
        let section = context.fleet?.section(id: sectionID)
        let hosts = home.sections.first { $0.id == sectionID }?.hostIDs ?? []
        return VStack(spacing: BighelpTokens.space4) {
            HStack(spacing: BighelpTokens.space8) {
                SimpleBotsCircleButton(systemImage: "chevron.left", label: "Back", identifier: "simple-bots.section.back") {
                    dismiss()
                }
                Spacer(minLength: BighelpTokens.space8)
                Text(section?.name ?? "")
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("simple-bots.section.title")
                Spacer(minLength: BighelpTokens.space8)
                if let section {
                    Menu {
                        SimpleBotsSectionMenu(section: section, prompt: { sectionPrompt = $0 })
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.bighelp(.title3, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                            .contentShape(.circle)
                            .bighelpNavigationGlass(in: Circle(), isInteractive: true)
                    }
                    .menuOrder(.fixed)
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(section.name) options")
                    .accessibilityIdentifier("simple-bots.section.more")
                }
            }
            if hosts.count > 1 {
                Text("On \(ListFormatter.localizedString(byJoining: hosts.compactMap { context.fleet?.hostName($0) }))")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("simple-bots.section.computers")
            }
        }
        .padding(.horizontal, BighelpTokens.space20)
        .padding(.top, BighelpTokens.space4)
        .padding(.bottom, BighelpTokens.space8)
        .background { SimpleBotsHeaderFade() }
    }

    private func addMembersRow(_ section: FleetSection) -> some View {
        Button { sectionPrompt = .members(section) } label: {
            HStack(spacing: BighelpTokens.space16) {
                Image(systemName: "plus")
                    .font(.bighelp(.title3, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .frame(width: 56, height: 56)
                    .background(theme.surface, in: .circle)
                    .accessibilityHidden(true)
                Text("Add Bots or Group Chats")
                    .font(.bighelp(.title3, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.vertical, BighelpTokens.space12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .accessibilityIdentifier("simple-bots.section.add")
    }

    // MARK: Group chats

    /// Kept by its catalog row on the gateway in use, by its gateway's copy on another.
    private func unreadKey(_ group: SimpleBotsGroup) -> (id: String, scope: String) {
        if group.isOnGatewayInUse { return (group.summary?.id ?? SimpleBotsGroup.catalogID(group.roomID), context.scope) }
        return (group.id, "multi-gateway")
    }

    /// Hermes' read state when its catalog row carries one (`tracksUnread`), else this device's mark.
    func isUnread(_ group: SimpleBotsGroup) -> Bool {
        if let summary = group.summary, summary.tracksUnread { return summary.isUnread }
        let key = unreadKey(group)
        return unread.isUnread(key.id, scope: key.scope)
    }

    func setUnread(_ group: SimpleBotsGroup, _ value: Bool) {
        if let summary = group.summary, summary.tracksUnread {
            markOnHermes(summary.id, value)
            return
        }
        let key = unreadKey(group)
        unread.set(value, id: key.id, scope: key.scope)
    }

    func openGroup(_ group: SimpleBotsGroup) {
        // This device's mark; Hermes' clears once the chat shows (`BighelpVisibleChats`).
        let key = unreadKey(group)
        unread.set(false, id: key.id, scope: key.scope)
        if let summary = group.summary {
            context.onOpenSession(summary)
        } else if group.isOnGatewayInUse {
            context.onOpenGroup?(group.roomID)
        } else if let gateways = context.gateways, let host = group.hostID {
            gateways.open(.group(roomID: group.roomID), host)
        }
    }

    /// Group Settings, on the group chat's own gateway.
    private func groupSettings(_ group: SimpleBotsGroup) -> (() -> Void)? {
        if group.isOnGatewayInUse, let settings = context.onGroupSettings { return { settings(group.roomID) } }
        if group.fleetGroup != nil, let gateways = context.gateways, let host = group.hostID {
            return { gateways.open(.groupSettings(roomID: group.roomID), host) }
        }
        return nil
    }

    /// Like a bot's (`SimpleBotsMenuAction.group`); each only where it can work.
    @ViewBuilder
    func groupMenu(_ group: SimpleBotsGroup, home: SimpleBotsHomeProjection.Home) -> some View {
        let fleet = group.key == nil ? nil : context.fleet
        let settings = groupSettings(group)
        let actions = SimpleBotsMenuAction.group(
            isPinned: group.key.map { fleet?.pinnedGroupIDs.contains($0) ?? false } ?? false,
            canPin: fleet != nil && SimpleBotsHomeProjection.canPin(group, home: home),
            canFile: context.fleet != nil && Self.canFile(.group(group)), isUnread: isUnread(group),
            hasSettings: settings != nil, canHide: fleet != nil,
            canDelete: group.isOnGatewayInUse && context.onDeleteGroup != nil)
        ForEach(actions, id: \.self) { action in
            if action == .deleteGroupChat, !actions.contains(.hide) { Divider() } else if action == .hide { Divider() }
            switch action {
            case .pin: Button("Pin", systemImage: "pin") { if let key = group.key { fleet?.setPinned(groupKey: key, true) } }
            case .unpin:
                Button("Unpin", systemImage: "pin.slash") { if let key = group.key { fleet?.setPinned(groupKey: key, false) } }
            case .rearrange: rearrangeButton
            case .moveToSection: moveToSectionMenu(.group(group))
            case .markRead, .markUnread: unreadButton(group)
            case .groupSettings: if let settings { Button("Group Settings", systemImage: "gearshape") { settings() } }
            case .hide:
                Button("Hide", systemImage: "eye.slash", role: .destructive) {
                    if let key = group.key { fleet?.setHidden(groupKey: key, true) }
                }
            case .deleteGroupChat:
                Button("Delete Group Chat", systemImage: "trash", role: .destructive) { deletingGroup = group }
            case .newChat, .botProfile: EmptyView()
            }
        }
    }

    /// A pinned group chat on top: up to three of its members' faces, its name under them.
    func topGroupTile(_ group: SimpleBotsGroup, size: CGFloat, home: SimpleBotsHomeProjection.Home) -> some View {
        Button {
            openGroup(group)
        } label: {
            VStack(spacing: BighelpTokens.space12) {
                SimpleBotsGroupFace(members: group.members, size: size, limit: 3)
                HStack(spacing: BighelpTokens.space4) {
                    Text(group.title)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                    if isUnread(group) { unreadDot }
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            groupMenu(group, home: home)
        } preview: {
            SimpleBotsGroupPreview(group: group)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("\(group.title), pinned group chat")
        .accessibilityHint("Opens the group chat")
        .accessibilityIdentifier("simple-bots.pinned.\(group.itemID)")
    }
}

/// Touch and hold a group chat: its latest message.
struct SimpleBotsGroupPreview: View {
    let group: SimpleBotsGroup
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: BighelpTokens.space12) {
                SimpleBotsGroupFace(members: group.members, size: 36)
                Text(group.title).font(.bighelp(.title3, weight: .semibold))
            }
            .padding(BighelpTokens.space20)
            Rectangle().fill(theme.separator).frame(height: BighelpTokens.hairline)
            Group {
                if let message = group.preview.map(SessionPreviewText.plain), !message.isEmpty {
                    Text(message)
                        .font(.bighelp(.body))
                        .lineLimit(6)
                        .padding(.horizontal, BighelpTokens.space16)
                        .padding(.vertical, BighelpTokens.space12)
                        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 20))
                } else {
                    Text("No messages yet")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(BighelpTokens.space20)
        }
        .frame(width: 320, alignment: .leading)
        // A preview is drawn outside the app's own colors; the system's match the Bots view.
        .background(Color(uiColor: .systemBackground))
    }
}

/// Delete Group Chat asks first, in the words the Agents screen uses.
struct SimpleBotsGroupDeletion: ViewModifier {
    @Binding var group: SimpleBotsGroup?
    let delete: ((String) -> Void)?

    func body(content: Content) -> some View {
        content.confirmationDialog(group.map { String(localized: "Delete “\($0.title)”?") } ?? "",
                                   isPresented: Binding(get: { group != nil }, set: { if !$0 { group = nil } }),
                                   titleVisibility: .visible) {
            Button("Delete Group Chat", role: .destructive) {
                if let group { delete?(group.roomID) }
                group = nil
            }
            .accessibilityIdentifier("simple-bots.group.delete.confirm")
            Button("Cancel", role: .cancel) { group = nil }
        } message: {
            Text("This permanently deletes the group on Hermes and stops its active work.")
        }
    }
}
