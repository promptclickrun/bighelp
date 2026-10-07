import SwiftUI

/// Hooks the shell gives a chat so it can draw the agent-home look: the
/// big live avatar, the ☰ drawer, New chat, and the bottom bar under the composer.
struct AgentHomeChrome {
    var isEnabled = false
    /// The tab bar under the message box. Every chat on one computer has it,
    /// whether it's the Chat tab's own or opened from the list, Agents or Feed.
    var showsTabBar = false
    var onMenu: @MainActor () -> Void = {}
    var onProfile: @MainActor (String) -> Void = { _ in }
    var onSwitchAgent: @MainActor () -> Void = {}
    /// Opens the New chat picker (one agent, or several for a group).
    var onNewChat: @MainActor (String?) -> Void = { _ in }
    /// Starts a new chat with this agent right away.
    var onStartChat: @MainActor (String) -> Void = { _ in }
    var tabSelection: Binding<AppTab>?
    /// Board tabs with something new, for the dots on the tab bar.
    var unreadTabs: Set<AppTab> = []
    /// The bar's tabs: Chat, then what's pinned (Appearance › App layout).
    var barTabs: [AppTab] = AppTab.allCases
}

private struct AgentHomeChromeKey: EnvironmentKey {
    static var defaultValue: AgentHomeChrome { AgentHomeChrome() }
}

extension EnvironmentValues {
    var agentHomeChrome: AgentHomeChrome {
        get { self[AgentHomeChromeKey.self] }
        set { self[AgentHomeChromeKey.self] = newValue }
    }
}

/// Every chat's header: ☰ on the left, the live avatar and name in the
/// middle, New chat and chat options on the right. ☰ is in the same place as
/// on the other root screens; the edge swipe goes back to where the chat opened from.
struct AgentHomeChatHeader: View {
    let agentID: String
    let displayName: String
    let imageURL: URL?
    let activity: AgentActivityKind
    var status: String? = nil
    /// Group chats show their own identity control instead of one agent.
    let groupIdentity: AnyView?
    let options: AnyView
    let chrome: AgentHomeChrome
    /// Full screen height, for the Auto avatar size.
    var screenHeight: CGFloat = 0
    let beforeAction: () -> Void
    @AppStorage(ChatLayoutPreferences.avatarSizeKey) private var avatarSize: ChatAvatarSize = .automatic
    @AppStorage(ChatLayoutPreferences.showsAgentNameKey) private var showsAgentName = true

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if let groupIdentity {
                    groupIdentity
                } else {
                    AgentHeroHeader(agentID: agentID, displayName: displayName, imageURL: imageURL,
                                    activity: activity,
                                    avatarSize: avatarSize.points(screenHeight: screenHeight),
                                    status: status, showsName: showsAgentName,
                                    onAvatarTap: { beforeAction(); chrome.onProfile(agentID) },
                                    onNameTap: { beforeAction(); chrome.onSwitchAgent() })
                        // Who the chat is with, like the name chip in the iPad header.
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("chat.header-surface")
                }
            }
            .frame(maxWidth: .infinity)
            HStack(alignment: .top) {
                Button {
                    beforeAction()
                    chrome.onMenu()
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.bighelp(.title3).weight(.semibold))
                        // On the glyph, where the top bar's ☰ shows it.
                        .bighelpMenuDot(!chrome.unreadTabs.subtracting(chrome.barTabs).isEmpty)
                        .frame(width: HeaderButtonMetrics.glass, height: HeaderButtonMetrics.glass)
                        .bighelpNavigationGlass(in: Circle(), isInteractive: true)
                        .padding(HeaderButtonMetrics.slop)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Chats and menu")
                .accessibilityIdentifier("chat.menu")
                Spacer()
                HStack(spacing: 0) {
                    newChatButton
                    options
                        .frame(width: HeaderButtonMetrics.glass, height: HeaderButtonMetrics.glass)
                        .bighelpNavigationGlass(in: Circle(), isInteractive: true)
                        .padding(HeaderButtonMetrics.slop)
                        .contentShape(.rect)
                }
            }
        }
    }
}

extension AgentHomeChatHeader {
    /// Tap: a new chat with this agent. Touch and hold: the picker, for another
    /// agent or a group. A group chat has no one agent, so a tap opens the picker.
    var newChatButton: some View {
        let isDirect = groupIdentity == nil
        let pickAgents = {
            beforeAction()
            chrome.onNewChat(isDirect ? agentID : nil)
        }
        return Image(systemName: "square.and.pencil")
            .font(.bighelp(.title3).weight(.semibold))
            .frame(width: HeaderButtonMetrics.glass, height: HeaderButtonMetrics.glass)
            .bighelpNavigationGlass(in: Circle(), isInteractive: true)
            .padding(HeaderButtonMetrics.slop)
            .contentShape(.rect)
            .onTapGesture {
                guard isDirect else { return pickAgents() }
                beforeAction()
                chrome.onStartChat(agentID)
            }
            .onLongPressGesture(minimumDuration: 0.4) {
                BighelpHaptics.tap()
                pickAgents()
            }
            .newChatRightClickMenu(startTitle: isDirect ? "New chat with \(displayName)" : nil,
                                   start: { beforeAction(); chrome.onStartChat(agentID) }, pick: pickAgents)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isDirect ? "New chat with \(displayName)" : "New chat")
            .accessibilityHint(isDirect
                ? NewChatButtonCopy.pickHint
                : "Pick one agent for a chat, or several for a group chat.")
            .accessibilityAction {
                if isDirect { beforeAction(); chrome.onStartChat(agentID) } else { pickAgents() }
            }
            .accessibilityAction(named: "Pick agents") { pickAgents() }
            .accessibilityIdentifier("chat.home.new-chat")
    }
}

/// Feed, Ideas, Goals and Apps: the Chat tab's ☰, New chat and ⋯, floating
/// over the board so they stay in reach while it scrolls.
struct AgentBoardHeaderButtons: View {
    let context: AgentBoardContext

    var body: some View {
        HStack(alignment: .top) {
            if let onBack = context.onBack {
                Button(action: onBack) { glyph("chevron.left") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("board.back")
            } else {
                Button(action: context.onMenu) { glyph("line.3.horizontal", dot: context.menuHasUnread) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Chats and menu")
                    .accessibilityIdentifier("home.drawer.open")
            }
            Spacer()
            HStack(spacing: 0) {
                newChatButton
                Menu {
                    Button("Agent profile", systemImage: "person.crop.circle", action: context.onProfile)
                    Divider()
                    ForEach(Array(context.tools.enumerated()), id: \.offset) { _, tool in
                        Button(tool.title, systemImage: tool.systemImage, action: tool.action)
                    }
                } label: {
                    // Glass goes around the menu, not in its label, or it takes the tap.
                    Image(systemName: "ellipsis")
                        .font(.bighelp(.title3).weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .frame(width: HeaderButtonMetrics.glass, height: HeaderButtonMetrics.glass)
                        .contentShape(.rect)
                }
                .frame(width: HeaderButtonMetrics.glass, height: HeaderButtonMetrics.glass)
                .bighelpNavigationGlass(in: Circle(), isInteractive: true)
                .padding(HeaderButtonMetrics.slop)
                .contentShape(.rect)
                .accessibilityLabel("More for \(context.agentName)")
                .accessibilityIdentifier("board.more")
            }
        }
        .bighelpHeaderButtonsPlacement()
    }

    /// Tap: a new chat with this agent. Touch and hold: the picker, for another agent or a group.
    private var newChatButton: some View {
        glyph("square.and.pencil")
            .onTapGesture(perform: context.onNewChat)
            .onLongPressGesture(minimumDuration: 0.4) {
                BighelpHaptics.tap()
                context.onPickAgents()
            }
            .newChatRightClickMenu(startTitle: "New chat with \(context.agentName)",
                                   start: context.onNewChat, pick: context.onPickAgents)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("New chat with \(context.agentName)")
            .accessibilityHint(NewChatButtonCopy.pickHint)
            .accessibilityAction { context.onNewChat() }
            .accessibilityAction(named: "Pick agents") { context.onPickAgents() }
            .accessibilityIdentifier("board.new-chat")
    }

    private func glyph(_ systemImage: String, dot: Bool = false) -> some View {
        Image(systemName: systemImage)
            .font(.bighelp(.title3).weight(.semibold))
            .foregroundStyle(theme.primaryText)
            .bighelpMenuDot(dot)
            .frame(width: HeaderButtonMetrics.glass, height: HeaderButtonMetrics.glass)
            .bighelpNavigationGlass(in: Circle(), isInteractive: true)
            .padding(HeaderButtonMetrics.slop)
            .contentShape(.rect)
    }

    @BighelpThemeReader private var theme
}

/// The chat header's round buttons: the glass circle people see, and a
/// larger square around it that still takes the tap. Taps near a circle's
/// edge used to miss and needed a second try.
enum HeaderButtonMetrics {
    #if os(visionOS)
    /// Eyes need bigger targets than fingers (60pt, per visionOS guidance).
    static var glass: CGFloat { BighelpTokens.scaled(52) }
    static let slop: CGFloat = 6
    #else
    /// Follows Settings › Appearance › Button size.
    static var glass: CGFloat { BighelpTokens.scaled(44) }
    static let slop: CGFloat = 5
    #endif

    /// From the screen's side to the first glass button: where the top bar puts ☰ on
    /// Agents and the other root screens, so ☰ never moves between them and Chat, Feed,
    /// Ideas, Goals and Files. Measured on iOS 26: 16 points on iPhone, 10 on iPad.
    static func edgeInset(regularWidth: Bool) -> CGFloat {
        if BighelpPlatform.usesTabOrnament { return 22 }
        if BighelpPlatform.isMac { return 12 }
        return regularWidth ? 10 : 16
    }

    /// From the top of the safe area to the glass: centered in the 44-point top bar.
    static var topInset: CGFloat {
        if BighelpPlatform.usesTabOrnament { return 18 }
        if BighelpPlatform.isMac { return slop }
        return max(0, (44 - glass) / 2)
    }
}

extension View {
    /// Places a row of header glass buttons (each with `HeaderButtonMetrics.slop` around it)
    /// where a root screen's top bar puts its buttons.
    func bighelpHeaderButtonsPlacement() -> some View {
        modifier(HeaderButtonsPlacement())
    }
}

private struct HeaderButtonsPlacement: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, HeaderButtonMetrics.edgeInset(regularWidth: horizontalSizeClass == .regular)
                     - HeaderButtonMetrics.slop)
            .padding(.top, HeaderButtonMetrics.topInset - HeaderButtonMetrics.slop)
    }
}

private enum NewChatButtonCopy {
    static var pickHint: String {
        BighelpPlatform.isMac
            ? "Right-click to pick other agents or start a group."
            : "Touch and hold to pick other agents or start a group."
    }
}

private extension View {
    /// The Mac has no touch and hold: right-click offers the same choices.
    @ViewBuilder
    func newChatRightClickMenu(startTitle: String?, start: @escaping () -> Void,
                               pick: @escaping () -> Void) -> some View {
        #if targetEnvironment(macCatalyst)
        contextMenu {
            if let startTitle { Button(startTitle, systemImage: "square.and.pencil", action: start) }
            Button("Pick Agents or Start a Group…", systemImage: "person.2", action: pick)
        }
        #else
        self
        #endif
    }
}
