import SwiftUI

struct BotModeRoomHeader: View {
    let theme: BighelpTheme
    let title: String
    let participants: [HermesBotModeParticipant]
    let agents: AgentDirectoryStore?
    let onOpenSettings: () -> Void

    var body: some View {
        Button(action: onOpenSettings) {
            ChatConversationIdentityLabel(
                title: title,
                subtitle: participantNames,
                participants: participants.map { participant in
                    ChatIdentityParticipant(
                        stableID: participant.id,
                        displayName: participant.displayName,
                        imageURL: participant.peerImageURL ?? participant.profile.flatMap { agents?.avatarURL(for: $0) }
                    )
                },
                theme: theme,
                disclosureSymbol: "chevron.down"
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(participants.count) participants")
        .accessibilityHint("Opens Chat Settings.")
        .accessibilityIdentifier("chat.people")
    }

    /// "Juniper, Sage, Nova +2" — first names stay readable, the rest count.
    private var participantNames: String {
        let names = participants.prefix(3).map(\.displayName).joined(separator: ", ")
        let remaining = participants.count - 3
        return remaining > 0 ? "\(names) +\(remaining)" : names
    }
}
