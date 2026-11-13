import SwiftUI

/// An agent's app in the chat (DESIGN.md › Agents' apps): an icon, the title, the agent's
/// description, what the app does ("Sends answers", "Live data"), and Open App. The chat only ever
/// draws this card; the page loads when the person opens it.
@MainActor
struct HTMLAppCardView: View {
    let app: HTMLAppCard
    /// The card's own ID, which keeps the answer it sent apart from other cards'.
    let cardID: String

    @Environment(\.chatCardInteractions) private var interactions
    @State private var isOpen = false
    @State private var hasAnswered = false
    @BighelpThemeReader private var theme

    /// The chat this card is in, on the computer in use. Open App waits for it.
    private var identity: ChatCardInteractionIdentity? {
        guard let interactions else { return nil }
        let identity = ChatCardInteractionIdentity(scope: interactions.scope, messageID: cardID, cardID: cardID)
        return identity.isUsable ? identity : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: BighelpTokens.space12) {
                Image(systemName: "apps.iphone")
                    .font(.bighelp(.title3, weight: .semibold))
                    .foregroundStyle(theme.actionForeground)
                    .frame(width: 44, height: 44)
                    .background(theme.action, in: .rect(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.title)
                        .font(.bighelp(.headline))
                        .foregroundStyle(theme.primaryText)
                    Text(app.description)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(4)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if app.sendsAnswers || app.isLive {
                HStack(spacing: BighelpTokens.space8) {
                    if app.sendsAnswers { tag("Sends answers", symbol: "arrowshape.turn.up.left") }
                    if app.isLive { tag("Live data", symbol: nil) }
                }
            }
            if hasAnswered {
                Label("You sent an answer", systemImage: "checkmark")
                    .font(.bighelp(.subheadline, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            Button {
                isOpen = true
            } label: {
                Text("Open App")
                    .font(.bighelp(.body, weight: .semibold))
                    .foregroundStyle(theme.actionForeground)
                    .frame(maxWidth: .infinity, minHeight: max(46, BighelpTokens.hitTarget))
                    .background(theme.action, in: .rect(cornerRadius: 14, style: .continuous))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(identity == nil)
            .accessibilityIdentifier("html-app.open")
        }
        .padding(BighelpTokens.space16)
        .frame(maxWidth: 420, alignment: .leading)
        .background(theme.surface, in: .rect(cornerRadius: BighelpCardDesignTokens.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpCardDesignTokens.cornerRadius, style: .continuous)
                .stroke(theme.border, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("html-app.card")
        .onAppear(perform: readAnswered)
        .bighelpFullScreenCover(isPresented: $isOpen, onDismiss: readAnswered) {
            if let interactions, let identity {
                HTMLAppScreen(app: app, agentID: interactions.scope.profileID, send: { message in
                    try interactions.reply(message, for: identity)
                })
            }
        }
    }

    private func readAnswered() {
        guard let interactions, let identity else { return }
        hasAnswered = interactions.store.reply(for: identity) != nil
    }

    private func tag(_ title: String, symbol: String?) -> some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).accessibilityHidden(true)
            } else {
                Circle().fill(Color.green).frame(width: 8, height: 8).accessibilityHidden(true)
            }
            Text(title)
        }
        .font(.bighelp(.footnote, weight: .medium))
        .foregroundStyle(theme.primaryText.opacity(0.8))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(theme.canvas, in: .capsule)
        .overlay { Capsule().stroke(theme.border, lineWidth: 0.5) }
    }
}
