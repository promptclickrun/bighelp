import SwiftUI

/// Hosts the menu can switch between: connected hosts, or demo mode's sample ones.
struct BighelpMenuHosts {
    struct Host: Identifiable, Equatable {
        let id: String
        let name: String
        let isSelected: Bool
    }

    /// The all-hosts view's switch: every agent on every host in one list.
    struct AllHosts {
        let isOn: Bool
        let toggle: () -> Void
    }

    var hosts: [Host] = []
    var select: (String) -> Void = { _ in }
    var add: (() -> Void)?
    var allHosts: AllHosts?

    @MainActor
    static func current(registry: BighelpHostRegistry?, demoHosts: DemoHosts?) -> BighelpMenuHosts {
        let add: (() -> Void)? = registry.flatMap { registry in
            registry.canConfigureHosts ? { registry.beginSetup() } : nil
        }
        if let registry, !registry.hosts.isEmpty {
            return BighelpMenuHosts(
                hosts: registry.hosts.map {
                    Host(id: $0.id.uuidString, name: $0.name, isSelected: $0.id == registry.selectedHostID)
                },
                select: { id in registry.select(UUID(uuidString: id)) },
                add: add
            )
        }
        if let demoHosts, !demoHosts.hosts.isEmpty {
            return BighelpMenuHosts(
                hosts: demoHosts.hosts.map { Host(id: $0.id, name: $0.name, isSelected: $0.id == demoHosts.selectedHostID) },
                select: { id in _ = demoHosts.selectHost(id) },
                add: add
            )
        }
        return BighelpMenuHosts(add: add)
    }
}

/// Where the menu can go.
struct BighelpMenuDestinations {
    /// The all-hosts view's list, its home while it's on. When set, ☰'s Agents opens it
    /// and the one-host places (Projects, Kanban, Scheduled tasks) stay out of the menu.
    var onAllAgents: (() -> Void)? = nil
    var newChatTitle = "New chat"
    var onNewChat: () -> Void
    var onAllChats: () -> Void
    /// Projects: related chats and folders together.
    var onProjects: (() -> Void)? = nil
    var onAgents: () -> Void
    var onScheduledTasks: () -> Void
    /// Kanban, when the host has Hermes' Kanban plugin.
    var onKanban: (() -> Void)? = nil
    /// Nerd Mode: the Hermes project folder chats run in.
    var folder: (name: String, open: () -> Void)?
    /// Usage: plans, limits and what the agents used. None while no computer is connected.
    var onUsage: (() -> Void)? = nil
    /// Logins, cards and addresses an agent's browser can use (Hermes' vault).
    var onCredentialVault: (() -> Void)? = nil
    var onSettings: () -> Void
}

/// bighelp's one menu (☰). The first screen is short on purpose: New chat (top right),
/// Agents, Projects, Kanban, Scheduled tasks, Usage and Settings, then recent chats
/// with See all. With all hosts showing, Agents is All agents and the one-host
/// places stay out, so each view keeps to its purpose. The host switcher is one
/// compact row on top; the rest (the credential vault, Nerd Mode's folder) waits below the chats.
struct BighelpMenu<Recent: View>: View {

    let hosts: BighelpMenuHosts
    let destinations: BighelpMenuDestinations
    #if os(visionOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.spatialAvatar) private var spatialAvatar
    #endif
    /// Runs before every choice: closes a sheet or drawer; nothing for a sidebar.
    let close: () -> Void
    var hasRecent = true
    @ViewBuilder let recent: () -> Recent

    var body: some View {
        List {
            mainSection
            recentSection
            moreSection
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .tint(theme.action)
        .accessibilityIdentifier("navigation.menu")
    }

    // MARK: Main

    private var mainSection: some View {
        Section {
            if let onAllAgents = destinations.onAllAgents {
                row("Agents", symbol: "person.2", id: "menu.all-agents", action: onAllAgents)
            } else {
                row("Agents", symbol: "person.2", id: "menu.agents", action: destinations.onAgents)
                if let onProjects = destinations.onProjects {
                    row("Projects", symbol: "folder", id: "menu.projects", action: onProjects)
                }
                if let onKanban = destinations.onKanban {
                    row("Kanban", symbol: "rectangle.split.3x1", id: "menu.kanban", action: onKanban)
                }
                row("Scheduled tasks", symbol: "calendar.badge.clock", id: "menu.scheduled-tasks",
                    action: destinations.onScheduledTasks)
            }
            if let onUsage = destinations.onUsage {
                row("Usage", symbol: "gauge.with.dots.needle.50percent", id: "menu.usage", action: onUsage)
            }
            row("Settings", symbol: "gearshape", id: "menu.settings", action: destinations.onSettings)
        } header: {
            HStack(spacing: BighelpTokens.space8) {
                if !hosts.hosts.isEmpty || hosts.add != nil {
                    hostSwitcher
                    if let allHosts = hosts.allHosts { allHostsToggle(allHosts) }
                }
                Spacer(minLength: 0)
                newChatButton
            }
            .padding(.bottom, BighelpTokens.space4)
        }
        .listRowBackground(theme.surface)
    }

    /// Compact rows, so the whole first screen fits without scrolling.
    private static var rowInsets: EdgeInsets { EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16) }

    /// New chat, its own button at the top right. Group chats start from its own picker ("Group chat").
    private var newChatButton: some View {
        Button { choose(destinations.onNewChat) } label: {
            Image(systemName: "square.and.pencil")
                .font(.bighelp(.body).weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: BighelpTokens.scaled(40), height: BighelpTokens.scaled(40))
                .background(theme.action, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .bighelpHelp(destinations.newChatTitle, shortcut: "⌘N")
        .accessibilityLabel(destinations.newChatTitle)
        .accessibilityIdentifier("menu.new-chat")
    }

    /// The host you're on, as one row. Hosts and Add host are one tap away.
    private var hostSwitcher: some View {
        Menu {
            Section("Switch host") {
                ForEach(hosts.hosts) { host in
                    Button { choose { hosts.select(host.id) } } label: {
                        if host.isSelected { Label(host.name, systemImage: "checkmark") } else { Text(host.name) }
                    }
                    .accessibilityIdentifier("menu.host.\(host.id)")
                }
            }
            if let add = hosts.add {
                Button { choose(add) } label: { Label("Add host", systemImage: "plus") }
                    .accessibilityIdentifier("menu.host.add")
            }
        } label: {
            HStack(spacing: BighelpTokens.space8) {
                Image(systemName: "desktopcomputer")
                Text(hostTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.bighelp(.caption2).weight(.semibold))
            }
            .font(.bighelp(.subheadline).weight(.semibold))
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, BighelpTokens.space12)
            .frame(minHeight: 34)
            .background(theme.surface, in: .capsule)
            .contentShape(.capsule)
        }
        .textCase(nil)
        .accessibilityLabel("Host: \(hostTitle)")
        .accessibilityHint("Switch hosts or add one.")
        .accessibilityIdentifier("menu.hosts")
    }

    private var hostTitle: String {
        if hosts.allHosts?.isOn == true { return "All hosts" }
        return hosts.hosts.first(where: \.isSelected)?.name ?? "Choose a host"
    }

    /// Shows every agent on every host in one list, or just this host's.
    private func allHostsToggle(_ allHosts: BighelpMenuHosts.AllHosts) -> some View {
        Button { choose(allHosts.toggle) } label: {
            // What a tap shows: every host's bots, or back to one host's.
            Image((allHosts.isOn ? BighelpGlyph.bot : .bots).assetName)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(allHosts.isOn ? theme.actionForeground : theme.primaryText)
                .frame(width: 34, height: 34)
                .background(allHosts.isOn ? theme.action : theme.surface, in: .circle)
                .contentShape(.circle)
        }
        .bighelpPointerButtonStyle(.borderless, outline: .circle)
        .textCase(nil)
        .bighelpIconLabel(allHosts.isOn ? "Show one host" : "Show all hosts")
        .accessibilityHint(allHosts.isOn
            ? "Shows the selected host's agents and chats again."
            : "Shows every agent on every host in one list.")
        .accessibilityAddTraits(allHosts.isOn ? .isSelected : [])
        .accessibilityIdentifier("menu.all-hosts")
    }

    // MARK: Recent

    private var recentSection: some View {
        Section {
            if hasRecent {
                recent()
            } else {
                Text("Your chats show up here.")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
            }
        } header: {
            HStack {
                Text("Recent chats")
                Spacer()
                Button("See all") { choose(destinations.onAllChats) }
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .textCase(nil)
                    .accessibilityLabel("See all chats")
                    .accessibilityIdentifier("menu.chats")
            }
        }
        .listRowBackground(theme.surface)
    }

    // MARK: More

    @ViewBuilder
    private var moreSection: some View {
        if destinations.onCredentialVault != nil || destinations.folder != nil || isVision {
            Section("More") {
                #if os(visionOS)
                row("Simple mode", symbol: "figure.stand", id: "menu.simple-mode") {
                    SpatialSimpleMode.enter(spatialAvatar, openWindow: openWindow)
                }
                #endif
                if let onCredentialVault = destinations.onCredentialVault {
                    row("Secure credential vault", symbol: "lock.shield", id: "menu.vault", action: onCredentialVault)
                }
                if let folder = destinations.folder {
                    row("Folder", detail: folder.name, symbol: "folder.badge.gearshape", id: "menu.folder",
                        action: folder.open)
                }
            }
            .listRowBackground(theme.surface)
        }
    }

    private var isVision: Bool {
        #if os(visionOS)
        true
        #else
        false
        #endif
    }

    private func row(_ title: String, detail: String? = nil, symbol: String, id: String,
                     action: @escaping () -> Void) -> some View {
        Button { choose(action) } label: {
            BighelpMenuRowLabel(title: title, detail: detail, symbol: symbol, trailing: .none)
        }
        .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12), padding: BighelpTokens.space4)
        .listRowInsets(Self.rowInsets)
        .accessibilityIdentifier(id)
    }

    private func choose(_ action: () -> Void) {
        close()
        action()
    }

    @BighelpThemeReader private var theme
}

/// A branded menu row: icon tile, title, optional detail, and a trailing mark.
struct BighelpMenuRowLabel: View {
    enum Trailing { case chevron, selected, none }

    let title: String
    var detail: String?
    let symbol: String
    var trailing: Trailing = .chevron

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            BighelpIconTile(systemName: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: BighelpTokens.space8)
            switch trailing {
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            case .selected:
                Image(systemName: "checkmark.circle.fill")
                    .font(.bighelp(.title3))
                    .foregroundStyle(theme.action)
                    .accessibilityHidden(true)
            case .none:
                EmptyView()
            }
        }
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}

/// A recent chat in the menu: who it's with, its title and when it last moved.
struct BighelpMenuChatRow: View {
    let chat: SessionSummary
    let agent: (String) -> (name: String, imageURL: URL?)?

    var body: some View {
        let lead = chat.kind == .direct ? chat.agentIDs.first.flatMap(agent) : nil
        HStack(spacing: BighelpTokens.space12) {
            if let lead, let id = chat.agentIDs.first {
                AvatarView(stableID: id, displayName: lead.name, imageURL: lead.imageURL, size: 30)
            } else {
                Image(systemName: "person.3.fill")
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.action)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(theme.action.opacity(0.14)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title.isEmpty ? "New chat" : chat.title)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(lead?.name ?? "Group chat")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: BighelpTokens.space8)
            if chat.isActive {
                Circle().fill(theme.action).frame(width: 8, height: 8)
                    .accessibilityLabel("Working")
            }
            Text(chat.updatedAt, format: .relative(presentation: .named, unitsStyle: .narrow))
                .font(.bighelp(.caption))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}

/// The bighelp lockup in the top bar. Touch and hold it to switch hosts; on
/// the Mac, click it.
struct EmberHostSwitcherLockup: View {
    var demoHosts: DemoHosts?
    @Environment(\.bighelpHostRegistry) private var registry

    var body: some View {
        let hosts = BighelpMenuHosts.current(registry: registry, demoHosts: demoHosts)
        if hosts.hosts.count + (hosts.add == nil ? 0 : 1) > 0 {
            #if targetEnvironment(macCatalyst)
            // A click that does nothing reads as broken on a Mac, where holding is rare.
            Menu { hostItems(hosts) } label: { EmberLockup(markSize: 28) }
                .accessibilityLabel(EmberBrand.appName)
                .accessibilityHint("Switch hosts.")
                .accessibilityIdentifier("brand.host-switcher")
            #else
            Menu { hostItems(hosts) } label: {
                EmberLockup(markSize: 28)
            } primaryAction: {}
            .accessibilityLabel(EmberBrand.appName)
            .accessibilityHint("Touch and hold to switch hosts.")
            .accessibilityIdentifier("brand.host-switcher")
            #endif
        } else {
            EmberLockup(markSize: 28)
        }
    }

    @ViewBuilder
    private func hostItems(_ hosts: BighelpMenuHosts) -> some View {
        Section("Switch host") {
            ForEach(hosts.hosts) { host in
                Button { hosts.select(host.id) } label: {
                    if host.isSelected { Label(host.name, systemImage: "checkmark") } else { Text(host.name) }
                }
                .accessibilityIdentifier("brand.host.\(host.id)")
            }
        }
        if let add = hosts.add {
            Button(action: add) { Label("Add host", systemImage: "plus") }
                .accessibilityIdentifier("brand.host.add")
        }
    }
}
