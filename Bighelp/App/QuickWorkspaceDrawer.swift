import SwiftUI
import UIKit

struct QuickWorkspaceContent: Equatable, Sendable {
    static let recentSessionLimit = 5

    let recentSessions: [SessionSummary]
    let organizeByProjects: Bool
    let sessionGroups: [QuickWorkspaceSessionGroup]
    let allReorderableSectionKeys: [SessionSectionKey]

    init(
        recentSessions: [SessionSummary],
        organizeByProjects: Bool = false,
        projectOrder: [SessionSectionKey] = [],
        includeCronSessions: Bool = false
    ) {
        self.organizeByProjects = organizeByProjects
        let visibleSessions = includeCronSessions
            ? recentSessions
            : recentSessions.filter { !$0.isCronSession }
        let allSections = SessionSectionOrganizer.sections(
            from: visibleSessions,
            organizeByProjects: organizeByProjects,
            projectOrder: projectOrder
        )
        allReorderableSectionKeys = allSections.map(\.key).filter(\.isReorderable)

        // Select the ordinary preview before grouping. A manual project order
        // must not change which recent chats qualify, and priority chats have
        // their own allowance so they cannot hide every project.
        let ordinaryIDs = Set(visibleSessions
            .filter { !$0.isPinned && !$0.isActive }
            .sorted(by: SessionSectionOrganizer.recencySort)
            .prefix(Self.recentSessionLimit)
            .map(\.id))
        sessionGroups = allSections.compactMap { section in
            let sessions = section.sessions.filter {
                $0.isPinned || $0.isActive || ordinaryIDs.contains($0.id)
            }
            guard !sessions.isEmpty else { return nil }
            return QuickWorkspaceSessionGroup(
                key: section.key,
                title: section.title,
                sessions: sessions
            )
        }
        self.recentSessions = sessionGroups.flatMap(\.sessions)
    }
}

struct QuickWorkspaceSessionGroup: Identifiable, Equatable, Sendable {
    let key: SessionSectionKey
    let title: String
    var sessions: [SessionSummary]

    var id: String { key.rawValue }
    var isReorderable: Bool { key.isReorderable }
}

enum QuickWorkspaceSection: Hashable, Sendable {
    case home
    case sessions
    case agents
    case secondaryRoutes
}

enum QuickWorkspaceSectionPresentation {
    static let contentOrder: [QuickWorkspaceSection] = [
        .home,
        .secondaryRoutes,
        .sessions,
        .agents,
    ]
    static var buttonMinimumHeight: CGFloat { BighelpTokens.hitTarget }
    static let sectionContentSpacing: CGFloat = BighelpTokens.space8
}

enum QuickWorkspacePinnedAgentsPresentation {
    static let previewLimit = 2

    /// Quick Workspace is allowed to hold zero pinned agents. The empty state
    /// says so plainly rather than implying the account has no agents at all.
    static let emptyStateText = "No agents currently pinned."

    static func detail(for agent: AgentProfile, isPrimary: Bool) -> String {
        if isPrimary { return "Primary agent" }
        if agent.isDefault { return "Default agent" }
        return agent.role
    }
}

enum WorkspaceHeaderLayout {
    enum Mode: Equatable {
        case regular
        case compact
    }

    enum ControlPlacement: Equatable {
        case singleRow
    }

    // The regular header reserves space for the workspace, session, and action controls.
    // Below this width the secondary actions move to a second row before compression can overlap them.
    static let regularMinimumWidth: CGFloat = 400
    /// Compact chat headers keep the model/reasoning chip and its actions in
    /// the same top row. Stacking an action underneath the chip makes the
    /// active agent identity look like part of the picker and pushes the
    /// canvas content away from the navigation chrome.
    static let compactControlPlacement: ControlPlacement = .singleRow
    static let compactCentersSessionControl = true
    static let compactSessionControlMaximumWidth: CGFloat = 160
    static let compactBotModeSessionControlMaximumWidth: CGFloat = 136
    static let compactTrailingActionSpacing: CGFloat = BighelpTokens.space12
    static let headerTopPadding: CGFloat = BighelpTokens.space8
    static let headerBottomPadding: CGFloat = BighelpTokens.space12

    static func mode(for width: CGFloat) -> Mode {
        width < regularMinimumWidth ? .compact : .regular
    }

    static func compactSessionControlWidth(isBotMode: Bool) -> CGFloat {
        isBotMode
            ? compactBotModeSessionControlMaximumWidth
            : compactSessionControlMaximumWidth
    }
}

struct QuickWorkspaceBackdrop: View {
    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    @Environment(\.colorScheme) private var colorScheme
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if uiV3Enabled {
                dismissButton
                    .background(Color.black.opacity(colorScheme == .dark ? 0.40 : 0.24))
            } else {
                dismissButton
                    .background(.ultraThinMaterial)
                    .overlay {
                        Color.black.opacity(0.48)
                            .allowsHitTesting(false)
                    }
            }
        }
        .ignoresSafeArea()
        .accessibilityLabel("Close Quick Workspace")
        .accessibilityIdentifier("quick-workspace.backdrop")
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
enum BighelpKeyboard {
    /// The composer uses a UIKit text view for Apple's native selection menu.
    /// Resign explicitly before menu and route transitions so its keyboard
    /// cannot remain attached after the input loses focus.
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

struct BighelpMenuIcon: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            line(width: 22)
            line(width: 15)
            line(width: 19)
        }
        .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
        .accessibilityHidden(true)
    }

    private func line(width: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(.primary)
            .frame(width: width, height: 2.5)
    }
}

struct WorkspaceMenuButton: View {
    let accessibilityIdentifier: String
    let action: () -> Void

    init(
        accessibilityIdentifier: String = "workspace.menu",
        action: @escaping () -> Void
    ) {
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "line.3.horizontal")
                .font(.bighelp(.body).weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .bighelpNavigationGlass(in: Circle(), isInteractive: true)
        .accessibilityLabel("Open Quick Workspace")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

@MainActor
struct QuickWorkspaceDrawer: View {
    @State private var draggedSessionSectionKey: SessionSectionKey?
    @State private var lastSessionSectionDropTargetKey: SessionSectionKey?
    let content: QuickWorkspaceContent
    let demoHosts: DemoHosts
    let settings: SettingsStore
    let sessionOrganizationAccountID: String?
    let sessionOrganizationHostID: String?
    let agents: AgentDirectoryStore
    let userIdentity: UserIdentityStore
    let activeWorkspaceName: String
    let selectedTab: AppTab?
    let onDismiss: () -> Void
    let onNewChat: () -> Void
    // NavigationStack destinations do not inherit environment values attached
    // only to its root content. Require navigation at every drawer call site.
    let onOpenSessions: () -> Void
    let onOpenSession: (SessionSummary) -> Void
    let onOpenAgents: () -> Void
    let onOpenScheduledTasks: () -> Void
    var onOpenProjects: (() -> Void)? = nil
    var onOpenKanban: (() -> Void)? = nil
    let onOpenWorkspaces: () -> Void
    let onSelectAgent: (AgentProfile) -> Void
    let onOpenMore: () -> Void
    var isEmbedded = false

    /// Settings has one fixed header affordance in every drawer variant.
    var onOpenSettings: () -> Void { onOpenMore }

    @Environment(\.bighelpHostRegistry) private var hostRegistry
    @Environment(\.providerUsage) private var providerUsage

    var body: some View {
        Group {
            if isEmbedded {
                menu
            } else {
                NavigationStack {
                    menu
                        .navigationTitle("Menu")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done", action: onDismiss)
                                    .accessibilityIdentifier("menu.done")
                            }
                        }
                }
            }
        }
        .onDisappear { resetSectionDrag() }
        .onChange(of: sessionOrganizationAccountID) { _, _ in resetSectionDrag() }
        .onChange(of: sessionOrganizationHostID) { _, _ in resetSectionDrag() }
        .onChange(of: content.organizeByProjects) { _, _ in resetSectionDrag() }
    }

    /// The same menu as ☰, with the sidebar's project groups and pinned agents as its recent list.
    private var menu: some View {
        BighelpMenu(
            hosts: BighelpMenuHosts.current(registry: hostRegistry, demoHosts: demoHosts),
            destinations: BighelpMenuDestinations(
                onNewChat: onNewChat,
                onAllChats: onOpenSessions,
                onProjects: onOpenProjects,
                onAgents: onOpenAgents,
                onScheduledTasks: onOpenScheduledTasks,
                onKanban: onOpenKanban,
                folder: settings.nerdModeEnabled ? (name: activeWorkspaceName, open: onOpenWorkspaces) : nil,
                onUsage: providerUsage?.isAvailable == true ? { [providerUsage, isEmbedded, agents] in
                    Task { @MainActor in
                        // Let the drawer finish closing before Usage opens.
                        if !isEmbedded { try? await Task.sleep(for: .milliseconds(350)) }
                        providerUsage?.show(agentID: agents.selectedAgentID ?? "default")
                    }
                } : nil,
                onSettings: onOpenSettings
            ),
            close: isEmbedded ? {} : onDismiss,
            hasRecent: !content.recentSessions.isEmpty || !agents.pinnedAgents.isEmpty
        ) {
            ForEach(content.sessionGroups) { group in
                if content.organizeByProjects { sessionGroupHeader(group) }
                ForEach(group.sessions) { recentSessionButton($0) }
            }
            ForEach(agents.pinnedAgents) { agent in
                Button { onSelectAgent(agent) } label: {
                    HStack(spacing: BighelpTokens.space12) {
                        AvatarView(stableID: agent.id, displayName: agent.name,
                                   imageURL: agents.avatarURL(for: agent), size: 30)
                        Text(agent.name)
                            .bighelpFont(.body)
                            .foregroundStyle(theme.primaryText)
                        Spacer(minLength: BighelpTokens.space8)
                        Image(systemName: "pin.fill")
                            .font(.bighelp(.caption))
                            .foregroundStyle(theme.secondaryText)
                            .accessibilityLabel("Pinned")
                    }
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("menu.agent.\(agent.id)")
            }
        }
        .accessibilityIdentifier("navigation.menu")
    }

    @ViewBuilder
    private func sessionGroupHeader(_ group: QuickWorkspaceSessionGroup) -> some View {
        if group.isReorderable {
            HStack(spacing: BighelpTokens.space8) {
                Button {
                    setSessionGroupCollapsed(
                        group,
                        collapsed: !isSessionGroupCollapsed(group)
                    )
                } label: {
                    HStack(spacing: BighelpTokens.space8) {
                        Image(systemName: isSessionGroupCollapsed(group) ? "chevron.right" : "chevron.down")
                            .accessibilityHidden(true)
                        Text(group.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .accessibilityValue(isSessionGroupCollapsed(group) ? "Collapsed" : "Expanded")
                .accessibilityIdentifier("quick-workspace.section-toggle.\(group.key.rawValue)")

                sessionGroupReorderMenu(group)
            }
            .onDrop(
                of: SessionSectionDragPayload.contentTypes,
                delegate: SessionSectionDropDelegate(
                    targetKey: group.key,
                    draggedKey: $draggedSessionSectionKey,
                    lastDropTargetKey: $lastSessionSectionDropTargetKey,
                    move: { source, target in
                        moveSessionGroup(source, to: target)
                    }
                )
            )
        } else {
            HStack(spacing: BighelpTokens.space8) {
                Text(group.title)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                if group.key == .active {
                    BighelpThinkingOrb(scenario: .working, scale: .inline, tint: theme.action)
                        .accessibilityHidden(true)
                }
            }
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("quick-workspace.session-group.\(group.id)")
        }
    }

    private func sessionGroupReorderMenu(_ group: QuickWorkspaceSessionGroup) -> some View {
        let keys = visibleReorderableSectionKeys
        let index = keys.firstIndex(of: group.key)
        return SessionSectionReorderHandle(
            title: group.title,
            identifier: "quick-workspace.section-reorder.\(group.key.rawValue)",
            canMoveUp: index.map { $0 > 0 } ?? false,
            canMoveDown: index.map { $0 + 1 < keys.count } ?? false,
            move: { moveSessionGroup(group, direction: $0) },
            drag: {
                draggedSessionSectionKey = group.key
                lastSessionSectionDropTargetKey = nil
                return SessionSectionDragPayload.provider(for: group.key)
            }
        )
    }

    private var visibleReorderableSectionKeys: [SessionSectionKey] {
        content.sessionGroups.map(\.key).filter(\.isReorderable)
    }

    private func resetSectionDrag() {
        draggedSessionSectionKey = nil
        lastSessionSectionDropTargetKey = nil
    }

    private func isSessionGroupCollapsed(_ group: QuickWorkspaceSessionGroup) -> Bool {
        settings.sessionSectionPreferences(
            accountID: sessionOrganizationAccountID,
            hostID: sessionOrganizationHostID
        ).isCollapsed(group.key)
    }

    private func setSessionGroupCollapsed(
        _ group: QuickWorkspaceSessionGroup,
        collapsed: Bool
    ) {
        settings.setSessionSectionCollapsed(
            collapsed,
            sectionKey: group.key,
            accountID: sessionOrganizationAccountID,
            hostID: sessionOrganizationHostID
        )
    }

    private func moveSessionGroup(
        _ group: QuickWorkspaceSessionGroup,
        direction: SessionSectionMoveDirection
    ) {
        settings.moveSessionSection(
            group.key,
            direction: direction,
            availableProjectKeys: visibleReorderableSectionKeys,
            accountID: sessionOrganizationAccountID,
            hostID: sessionOrganizationHostID
        )
    }

    private func moveSessionGroup(
        _ sectionKey: SessionSectionKey,
        to targetKey: SessionSectionKey
    ) {
        settings.moveSessionSection(
            sectionKey,
            to: targetKey,
            availableProjectKeys: visibleReorderableSectionKeys,
            accountID: sessionOrganizationAccountID,
            hostID: sessionOrganizationHostID
        )
    }

    private func recentSessionButton(_ session: SessionSummary) -> some View {
        Button { onOpenSession(session) } label: {
            BighelpMenuChatRow(chat: session) { id in
                agents.profiles.first { $0.id == id }.map { ($0.name, agents.avatarURL(for: $0)) }
            }
        }
        .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12), padding: BighelpTokens.space4)
        .accessibilityIdentifier("menu.chat.\(session.id)")
    }

    @BighelpThemeReader private var theme
}

/// Compose is contextual shell chrome, never a navigation destination.
struct ShellNewChatButton: View {
    let action: () -> Void

    var body: some View {
        Button {
            BighelpKeyboard.dismiss()
            action()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.bighelp(.body).weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .bighelpNavigationGlass(in: Circle(), isInteractive: true)
        .accessibilityLabel("New chat")
        .accessibilityIdentifier("shell.new-chat")
    }
}

struct ShellWorkspaceMenuBarPresentation: Equatable, Sendable {
    static let trailingTitle: String? = nil
}

struct ShellWorkspaceMenuBar: View {
    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    var onNewChat: (() -> Void)? = nil
    let onOpen: () -> Void

    var body: some View {
        BighelpGlassGroup(isEnabled: onNewChat != nil) {
            HStack {
                WorkspaceMenuButton(
                    accessibilityIdentifier: "quick-workspace.menu",
                    action: onOpen
                )
                Spacer(minLength: BighelpTokens.space8)
                if let onNewChat {
                    ShellNewChatButton(action: onNewChat)
                }
            }
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space4)
        .background(uiV3Enabled ? Color.clear : theme.canvas.opacity(0.96))
    }

    @BighelpThemeReader private var theme

}
