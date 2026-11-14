import SwiftUI

enum MentionSuggestionKind: Equatable, Sendable {
    case everyone
    case member
    case outsideAgent
}

struct MentionSuggestion: Identifiable, Equatable, Sendable {
    let kind: MentionSuggestionKind
    let agentID: String?
    let title: String
    let handle: String
    let isEnabled: Bool

    var id: String { "\(kind)-\(agentID ?? handle)" }

    var displayLabel: String { "\(title) @\(handle)" }

    static var everyone: MentionSuggestion {
        MentionSuggestion(kind: .everyone, agentID: nil, title: "Everyone", handle: "everyone", isEnabled: true)
    }

    static func member(profile: AgentProfile, handle: String? = nil) -> MentionSuggestion {
        MentionSuggestion(
            kind: .member,
            agentID: profile.id,
            title: profile.name,
            handle: handle ?? AgentHandle.normalized(profile.name),
            isEnabled: true
        )
    }

    static func outsideAgent(profile: AgentProfile, handle: String? = nil, isEnabled: Bool) -> MentionSuggestion {
        MentionSuggestion(
            kind: .outsideAgent,
            agentID: profile.id,
            title: "Add \(profile.name)",
            handle: handle ?? AgentHandle.normalized(profile.name),
            isEnabled: isEnabled
        )
    }
}

struct MentionSuggestionsView: View {
    let suggestions: [MentionSuggestion]
    /// Resolves agent photos; agents without one show their persona avatar.
    let agents: AgentDirectoryStore?
    let onSelect: (MentionSuggestion) -> Void

    init(
        suggestions: [MentionSuggestion],
        agents: AgentDirectoryStore? = nil,
        onSelect: @escaping (MentionSuggestion) -> Void
    ) {
        self.suggestions = suggestions
        self.agents = agents
        self.onSelect = onSelect
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BighelpTokens.space8) {
                ForEach(suggestions) { suggestion in
                    Button {
                        onSelect(suggestion)
                    } label: {
                        HStack(spacing: BighelpTokens.space8) {
                            leadingMark(for: suggestion)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.title)
                                    .bighelpFont(.label, weight: .semibold)
                                    .foregroundStyle(theme.primaryText)
                                Text("@\(suggestion.handle)")
                                    .bighelpFont(.metadata)
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                        .lineLimit(1)
                        .padding(.leading, BighelpTokens.space4)
                        .padding(.trailing, BighelpTokens.space12)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .background(theme.incomingMessageBackground, in: .capsule)
                        .opacity(suggestion.isEnabled ? 1 : 0.5)
                    }
                    .buttonStyle(.plain)
                    .disabled(!suggestion.isEnabled)
                    .accessibilityLabel(suggestion.isEnabled ? suggestion.displayLabel : "\(suggestion.displayLabel). This chat can include up to 6 bots")
                    .accessibilityHint(suggestion.isEnabled ? "Inserts this mention." : "This chat can include up to 6 bots")
                    .accessibilityIdentifier("chat.mention.\(suggestion.agentID ?? suggestion.handle)")
                }
            }
            .padding(.vertical, BighelpTokens.space4)
        }
        .accessibilityIdentifier("chat.mention-suggestions")
    }

    @ViewBuilder
    private func leadingMark(for suggestion: MentionSuggestion) -> some View {
        if let agentID = suggestion.agentID {
            let profile = agents?.profiles.first { $0.id == agentID }
            AvatarView(
                stableID: agentID,
                displayName: profile?.name ?? suggestion.handle,
                imageURL: profile.flatMap { agents?.avatarURL(for: $0) },
                size: 32
            )
            .overlay(alignment: .bottomTrailing) {
                if suggestion.kind == .outsideAgent {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.action)
                        .background(Circle().fill(theme.surface))
                        .offset(x: 2, y: 2)
                }
            }
            .accessibilityHidden(true)
        } else {
            Image(systemName: icon(for: suggestion.kind))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .frame(width: 32, height: 32)
                .background(theme.surface, in: .circle)
                .accessibilityHidden(true)
        }
    }

    private func icon(for kind: MentionSuggestionKind) -> String {
        switch kind {
        case .everyone: "person.2.fill"
        case .member: "person.fill"
        case .outsideAgent: "person.badge.plus"
        }
    }

    @BighelpThemeReader private var theme

}
