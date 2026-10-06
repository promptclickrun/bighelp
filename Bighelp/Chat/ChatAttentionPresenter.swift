import SwiftUI
import UIKit

extension DirectHermesPrompt {
    /// Hermes' own request ID stays the same when it sends a waiting request
    /// again after a reconnect; `id` changes with each connection.
    var attentionKey: String {
        [method, profile, visibleSessionID, wireID].joined(separator: "\0")
    }
}

/// Which waiting questions and approvals pop up by themselves: each one once,
/// when it arrives with the chat in front. Closing the pop-up answers nothing;
/// the request stays waiting and the bar above the chat reopens it.
struct ChatAttentionPopups: Equatable {
    private(set) var shown: [String] = []
    private static let limit = 64

    /// Whether to open the pop-up for `waiting`. Everything it would show
    /// counts as shown, including what arrives while it's already open.
    mutating func shouldPopUp(waiting: [String], canPopUp: Bool, isOpen: Bool) -> Bool {
        let fresh = waiting.filter { !shown.contains($0) }
        guard !fresh.isEmpty, canPopUp || isOpen else { return false }
        shown.append(contentsOf: fresh)
        if shown.count > Self.limit { shown.removeFirst(shown.count - Self.limit) }
        return !isOpen
    }
}

/// The bar above a chat while it waits on you. It's tinted so it doesn't blend
/// into the messages, and it reopens the pop-up.
struct ChatAttentionBar: View {
    let prompts: [DirectHermesPrompt]
    let agentName: String?
    let action: () -> Void

    @BighelpThemeReader private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)
        Button(action: action) {
            HStack(spacing: BighelpTokens.space12) {
                Image(systemName: isApprovalOnly ? "hand.raised.fill" : "questionmark.bubble.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .bighelpFont(.label, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                    if let detail = prompts.first?.detail {
                        Text(detail)
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(isApprovalOnly ? "Review" : "Answer")
                    .bighelpFont(.label, weight: .semibold)
                    .foregroundStyle(theme.actionForeground)
                    .padding(.horizontal, BighelpTokens.space12)
                    .padding(.vertical, 6)
                    .background(theme.action, in: Capsule())
            }
            .padding(.horizontal, BighelpTokens.space12)
            .padding(.vertical, BighelpTokens.space8)
            .frame(minHeight: 52)
            .background {
                shape.fill(theme.canvas)
                shape.fill(theme.warning.opacity(0.16))
            }
            .overlay { shape.strokeBorder(theme.warning.opacity(0.6), lineWidth: 1.5) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, BighelpTokens.space12)
        .padding(.vertical, BighelpTokens.space4)
        .accessibilityLabel(title)
        .accessibilityHint("Opens it so you can answer.")
        .accessibilityIdentifier("direct-hermes.attention")
    }

    private var isApprovalOnly: Bool { prompts.allSatisfy { $0.kind == .approval } }

    private var title: String {
        let name = agentName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let who = name.isEmpty ? "Your agent" : name
        let approvals = prompts.filter { $0.kind == .approval }.count
        let questions = prompts.count - approvals
        switch (approvals, questions) {
        case (0, 1): return "\(who) has a question"
        case (0, _): return "\(who) has \(questions) questions"
        case (1, 0): return "\(who) needs your OK"
        default: return "\(who) needs your response"
        }
    }
}

/// Shows the bar and pops up the chat's waiting questions and approvals.
private struct ChatAttentionPresenter: ViewModifier {
    let client: DirectHermesConversationClient?
    let agentName: String?
    @Binding var isPresented: Bool
    /// The chat is on screen with nothing else over it, and the app is in front.
    let canPopUp: Bool

    @State private var popups = ChatAttentionPopups()

    private var prompts: [DirectHermesPrompt] { client?.prompts ?? [] }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if !prompts.isEmpty {
                    ChatAttentionBar(prompts: prompts, agentName: agentName) { isPresented = true }
                }
            }
            .bighelpSheet(isPresented: $isPresented) {
                if let client { DirectHermesAttentionView(client: client) }
            }
            .onChange(of: prompts.map(\.attentionKey), initial: true) { _, _ in popUpNewArrivals() }
            .onChange(of: canPopUp) { _, _ in popUpNewArrivals() }
    }

    private func popUpNewArrivals() {
        guard popups.shouldPopUp(waiting: prompts.map(\.attentionKey), canPopUp: canPopUp,
                                 isOpen: isPresented) else { return }
        // Close the keyboard so the question isn't hidden behind it.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isPresented = true
    }
}

extension View {
    func chatAttention(client: DirectHermesConversationClient?, agentName: String?,
                       isPresented: Binding<Bool>, canPopUp: Bool) -> some View {
        modifier(ChatAttentionPresenter(client: client, agentName: agentName,
                                        isPresented: isPresented, canPopUp: canPopUp))
    }
}
