import SwiftUI

/// What the shell gives a chat it pushed: `onProfile` opens the bot's page, from the header's pill and
/// from ⋯ › Bot page. A chat drawn outside the shell (a fixture, a test) has neither, and no New chat
/// parts.
struct AgentHomeChrome {
    var isPushedChat = false
    var onProfile: @MainActor (String) -> Void = { _ in }

    /// The chrome of every chat the shell pushes.
    static func pushedChat(onProfile: @escaping @MainActor (String) -> Void) -> AgentHomeChrome {
        AgentHomeChrome(isPushedChat: true, onProfile: onProfile)
    }
}

/// Equal when what it shows is the same. Its action is the shell's own, the same every time (it reads
/// live state when tapped). Compared as a whole, every shell update redrew the chat on screen, its
/// header and its message box.
extension AgentHomeChrome: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.isPushedChat == rhs.isPushedChat }
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

/// Every chat's header. Back goes to where the person came from, the middle says who the
/// chat is with (a bot's pill opens its page) and ⋯ holds the chat's options. A new chat with
/// nothing sent says "New chat" there, with its To row under the buttons across the whole lane.
struct ChatPushedHeader: View {
    /// The bot's pill, or a group chat's name.
    let identity: AnyView
    /// A new chat's To row (`ChatNewChatSlot.toRow`), which takes the identity's place.
    var toRow: AnyView? = nil
    let options: AnyView
    let onBack: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Group {
                    if toRow == nil { identity } else { newChatTitle }
                }
                // Clear of Back and ⋯ at every text size: the pill's name truncates instead.
                .padding(.horizontal, HeaderButtonMetrics.glass + 2 * HeaderButtonMetrics.slop)
                .padding(.top, HeaderButtonMetrics.slop)
                .frame(maxWidth: .infinity)
                HStack(alignment: .top) {
                    backButton
                    Spacer(minLength: 0)
                    options
                        .frame(width: HeaderButtonMetrics.glass, height: HeaderButtonMetrics.glass)
                        .bighelpNavigationGlass(in: Circle(), isInteractive: true)
                        .padding(HeaderButtonMetrics.slop)
                        .contentShape(.rect)
                }
            }
            // Only the buttons' row: Back sits where a root screen's top bar puts its first button.
            .bighelpHeaderButtonsPlacement()
            if let toRow {
                // It scrolls sideways inside its own bounds, so large text never pushes the buttons.
                toRow
                    .frame(maxWidth: horizontalSizeClass == .regular ? ChatCanvasLayout.regularLaneMaximumWidth : .infinity)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.bighelp(.title3).weight(.semibold))
                .foregroundStyle(theme.primaryText)
                .frame(width: HeaderButtonMetrics.glass, height: HeaderButtonMetrics.glass)
                .bighelpNavigationGlass(in: Circle(), isInteractive: true)
                .padding(HeaderButtonMetrics.slop)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
        .accessibilityIdentifier("chat.back")
    }

    private var newChatTitle: some View {
        Text("New chat")
            .font(.bighelp(.title3, weight: .semibold))
            .foregroundStyle(theme.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(minHeight: HeaderButtonMetrics.glass)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("new-chat.title")
    }
}

/// The bot a chat is with: its face and name in one bounded glass pill.
struct ChatAgentIdentityPill: View {
    let agentID: String
    let name: String
    let imageURL: URL?
    var sessionTitle: String? = nil
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: BighelpTokens.space8) {
            SimpleBotFace(agentID: agentID, name: name, imageURL: imageURL, size: 28)
            BighelpHuggingWidth(maxWidth: 220) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(.bighelp(.title3, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    if let sessionTitle {
                        Text(sessionTitle)
                            .font(.bighelp(.caption2).weight(.medium))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .accessibilityIdentifier("chat.identity.session-title")
                    }
                }
            }
        }
        .padding(.leading, BighelpTokens.space12)
        .padding(.trailing, BighelpTokens.space16)
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(Capsule())
        .bighelpNavigationGlass(in: Capsule(), isInteractive: true)
    }
}

/// A board opened in a sheet (a bot's Dashboard › See all): Back and New chat, floating over the
/// board so they stay in reach while it scrolls.
struct AgentBoardHeaderButtons: View {
    let agentName: String
    let onBack: () -> Void
    let onNewChat: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Button(action: onBack) { glyph("chevron.left") }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("board.back")
            Spacer()
            Button(action: onNewChat) { glyph("square.and.pencil") }
                .buttonStyle(.plain)
                .accessibilityLabel("New chat with \(agentName)")
                .accessibilityIdentifier("board.new-chat")
        }
        .bighelpHeaderButtonsPlacement()
    }

    private func glyph(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.bighelp(.title3).weight(.semibold))
            .foregroundStyle(theme.primaryText)
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

    /// From the screen's side to the first glass button: where a top bar puts its first button, so
    /// Back and the home's header buttons sit in one place on every screen. Measured on iOS 26:
    /// 16 points on iPhone, 10 on iPad.
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
