import SwiftUI

/// One bot beside the chat's own in the laptop desk's rail.
struct ChatLaptopDeskBot: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let imageURL: URL?
}

/// The half under the fold of a chat on the iPhone Duo, half-folded like a small laptop
/// (`BighelpScreenGeometry.isLaptop`): the chat's bot in the middle, large, with what it is doing now,
/// and the computer's other bots either side of it, smaller and alternating. A face opens that bot's
/// page; **New chat** starts a chat with it.
///
/// `ChatView` shows it under the message box while the keyboard is down, in a one-bot chat that has a
/// message. Typing, a blank New chat and a group chat keep the half clear.
///
/// A view of its own, so the bot's live step is read here and not in `ChatView`'s body.
struct ChatLaptopDesk: View {
    let model: ChatModel
    let agentID: String
    let name: String
    let imageURL: URL?
    /// The computer's bots other than this chat's: smaller, alternating either side of it.
    var others: [ChatLaptopDeskBot] = []
    /// The bot's page and a new chat with it, from every face here (`AgentHomeChrome`).
    let chrome: AgentHomeChrome
    @BighelpThemeReader private var theme

    /// The chat's own bot: as large as the half allows, with its name and what it is doing.
    private static let currentFaceSize: CGFloat = 96
    private static let otherFaceSize: CGFloat = 48

    var body: some View {
        let activity = model.liveActivityKind
        VStack(spacing: BighelpTokens.space12) {
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: BighelpTokens.space16) {
                ForEach(Array(others.enumerated()), id: \.element.id) { pair in
                    if pair.offset.isMultiple(of: 2) { other(pair.element) }
                }
                current(activity)
                ForEach(Array(others.enumerated()), id: \.element.id) { pair in
                    if !pair.offset.isMultiple(of: 2) { other(pair.element) }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.top, BighelpTokens.space12)
        // A container, so its id doesn't replace the faces' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.laptop.desk")
    }

    private func current(_ activity: AgentActivityKind) -> some View {
        VStack(spacing: BighelpTokens.space8) {
            // It opens its page on a tap, as its pill in the header does.
            face(agentID: agentID, name: name, imageURL: imageURL, size: Self.currentFaceSize,
                 activity: activity, identifier: "chat.laptop.bot.\(agentID)")
            VStack(spacing: 2) {
                Text(name)
                    .font(.bighelp(.title3, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                // The step it is on, in its own words, else the kind of work. Never a guess.
                Text(model.liveStepPhrase ?? activity.label)
                    .bighelpFont(.label)
                    .foregroundStyle(theme.secondaryText)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.laptop.status")
            newChat(for: agentID, title: "New chat", identifier: "chat.laptop.new-chat", compact: false)
        }
    }

    /// One of the computer's other bots: smaller, its face over a New chat of its own.
    private func other(_ bot: ChatLaptopDeskBot) -> some View {
        VStack(spacing: BighelpTokens.space4) {
            face(agentID: bot.id, name: bot.name, imageURL: bot.imageURL, size: Self.otherFaceSize,
                 activity: .idle, identifier: "chat.laptop.bot.\(bot.id)")
            newChat(for: bot.id, title: "New chat with \(bot.name)",
                    identifier: "chat.laptop.bot.\(bot.id).new-chat", compact: true)
        }
    }

    /// The face the chat's header shows, so a bot looks the same above and below the fold. Its name is
    /// VoiceOver's label here: the face itself says nothing.
    private func face(agentID: String, name: String, imageURL: URL?, size: CGFloat,
                      activity: AgentActivityKind, identifier: String) -> some View {
        Button {
            chrome.onProfile(agentID)
        } label: {
            SimpleBotFace(agentID: agentID, name: name, imageURL: imageURL, size: size,
                          activity: activity == .idle ? nil : .working(tool: nil))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityHint("Opens its page")
        .accessibilityIdentifier(identifier)
    }

    /// A face here has no room for words: the small ones wear the symbol alone, and carry the bot's
    /// name in their label.
    private func newChat(for agentID: String, title: LocalizedStringKey, identifier: String,
                         compact: Bool) -> some View {
        Button {
            chrome.onNewChat?(agentID)
        } label: {
            newChatLabel(title, compact: compact)
        }
        .buttonStyle(.bighelpTilePress)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func newChatLabel(_ title: LocalizedStringKey, compact: Bool) -> some View {
        let label = Label(title, systemImage: "square.and.pencil")
            .bighelpFont(.label, weight: .semibold)
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, compact ? BighelpTokens.space8 : BighelpTokens.space16)
            .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
            .contentShape(Capsule())
            .bighelpNavigationGlass(in: Capsule(), isInteractive: true)
        if compact {
            label.labelStyle(.iconOnly)
        } else {
            label.labelStyle(.titleAndIcon)
        }
    }
}
