import SwiftUI

/// iMessage-style group chat row: an overlapping avatar cluster in the same
/// 52pt slot as agent rows, the group name with its last activity, and the
/// member names underneath.
struct AgentGroupRowView: View {
    let group: HermesBotModeRoomSummary
    let profiles: [AgentProfile]
    let avatarDirectory: URL?
    /// Agents on other computers: their own names and pictures.
    var peers: (any HermesBotModePeerHosts)? = nil
    var isPinned = false
    var liveState: AgentLiveState? = nil
    let onSelect: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var nameSize: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var detailSize: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var timeSize: CGFloat = 13

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: BighelpTokens.space12) {
                AgentGroupAvatarCluster(avatars: clusterAvatars, outlineColor: theme.canvas)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                        Text(group.name)
                            .font(.system(size: nameSize, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        if isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: timeSize * 0.85, weight: .semibold))
                                .foregroundStyle(theme.tertiaryText)
                                .accessibilityHidden(true)
                        }
                        Spacer(minLength: BighelpTokens.space4)
                        Text(group.updatedAt, format: .relative(presentation: .named))
                            .font(.system(size: timeSize))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                    Text(memberNames)
                        .font(.system(size: detailSize))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    if let liveState {
                        AgentLiveStateLabel(state: liveState, font: .system(size: timeSize))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
            .padding(.vertical, 10)
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.name), \(group.memberCount) agents")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Opens the group chat. Long press for options.")
        .accessibilityIdentifier("agents.group.\(group.roomID)")
    }

    private var participants: [HermesBotModeParticipant] { group.participants(profiles: profiles, peers: peers) }

    private var clusterAvatars: [AvatarStack.Avatar] {
        participants.prefix(2).map {
            AvatarStack.Avatar(
                stableID: $0.memberID, displayName: $0.displayName,
                imageURL: $0.peerImageURL ?? AvatarFileURL.resolve(fileName: $0.profile?.avatarFileName, in: avatarDirectory)
            )
        }
    }

    private var memberNames: String {
        let names = participants.map(\.displayName)
        guard !names.isEmpty else { return "\(group.memberCount) agents" }
        return names.formatted(.list(type: .and))
    }

    private var accessibilityValue: String {
        [isPinned ? "Pinned" : nil, liveState?.label, memberNames]
            .compactMap { $0 }.joined(separator: ", ")
    }

    @BighelpThemeReader private var theme
}

/// Two overlapping avatars inside a single 52pt slot, like an iMessage group.
private struct AgentGroupAvatarCluster: View {
    let avatars: [AvatarStack.Avatar]
    let outlineColor: Color

    private let slot = AgentRowView.avatarSize
    private let member: CGFloat = 36

    var body: some View {
        ZStack {
            if avatars.count >= 2 {
                avatar(avatars[1])
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                avatar(avatars[0])
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let only = avatars.first {
                AvatarView(stableID: only.stableID, displayName: only.displayName, imageURL: only.imageURL, size: slot)
            } else {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: slot, height: slot)
    }

    private func avatar(_ avatar: AvatarStack.Avatar) -> some View {
        AvatarView(stableID: avatar.stableID, displayName: avatar.displayName, imageURL: avatar.imageURL, size: member)
            .background(Circle().fill(outlineColor).padding(-2))
    }
}
