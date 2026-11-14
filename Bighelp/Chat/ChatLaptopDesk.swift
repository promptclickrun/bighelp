import SwiftUI

/// The half under the fold of a chat on the iPhone Duo, half-folded like a small laptop
/// (`BighelpScreenGeometry.isLaptop`): the chat's bot, large, with what it is doing now, then New
/// chat and Bot page. `ChatView` shows it under the message box while the keyboard is down, in a
/// one-bot chat that has a message. Typing, a blank New chat and a group chat keep the half clear.
///
/// A view of its own, so the bot's live step is read here and not in `ChatView`'s body.
struct ChatLaptopDesk: View {
    let model: ChatModel
    let agentID: String
    let name: String
    let imageURL: URL?
    let onNewChat: () -> Void
    let onBotPage: () -> Void
    @BighelpThemeReader private var theme

    var body: some View {
        let activity = model.liveActivityKind
        VStack(spacing: BighelpTokens.space20) {
            Spacer(minLength: 0)
            // At large text the face moves beside its lines, so the buttons stay on screen.
            ViewThatFits(in: .vertical) {
                VStack(spacing: BighelpTokens.space8) {
                    face(activity, size: 112)
                    lines(activity, alignment: .center)
                }
                HStack(spacing: BighelpTokens.space12) {
                    face(activity, size: 56)
                    lines(activity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.laptop.status")
            // Side by side, or one over the other when the two names don't fit.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: BighelpTokens.space12) { actions }
                VStack(spacing: BighelpTokens.space8) { actions }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.top, BighelpTokens.space12)
        // A container, so its id doesn't replace the buttons' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.laptop.desk")
    }

    private func face(_ activity: AgentActivityKind, size: CGFloat) -> some View {
        AgentLiveAvatar(agentID: agentID, displayName: name, imageURL: imageURL, activity: activity, size: size)
    }

    private func lines(_ activity: AgentActivityKind, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(name)
                .font(.bighelp(.title3, weight: .semibold))
                .foregroundStyle(theme.primaryText)
            // The step it is on, in its own words, else the kind of work. Never a guess.
            Text(model.liveStepPhrase ?? activity.label)
                .bighelpFont(.label)
                .foregroundStyle(theme.secondaryText)
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
    }

    @ViewBuilder
    private var actions: some View {
        action("New chat", systemImage: "square.and.pencil", identifier: "chat.laptop.new-chat", action: onNewChat)
        action("Bot page", systemImage: "person.crop.circle", identifier: "chat.laptop.bot-page", action: onBotPage)
    }

    private func action(_ title: LocalizedStringKey, systemImage: String, identifier: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .bighelpFont(.label, weight: .semibold)
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, BighelpTokens.space16)
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(Capsule())
                .bighelpNavigationGlass(in: Capsule(), isInteractive: true)
        }
        .buttonStyle(.bighelpTilePress)
        .accessibilityIdentifier(identifier)
    }
}
