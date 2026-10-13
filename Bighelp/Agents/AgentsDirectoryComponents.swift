import SwiftUI

/// Uppercase, letterspaced section caption ("PINNED", "GROUP CHATS").
struct AgentsSectionCaption: View {
    let title: String

    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 11

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: size, weight: .bold))
            .tracking(size * 0.08)
            .foregroundStyle(theme.secondaryText)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
    }

    @BighelpThemeReader private var theme
}

/// The big pinned-agent look Agents and All agents share: a large avatar,
/// the name, and one short line under it.
enum PinnedAgentsLayout {
    static let avatarSize: CGFloat = 88
    static let columns = [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: BighelpTokens.space8,
                                   alignment: .top)]
}

/// A pinned tile's picture, name and line under it; the grid adds the gestures.
struct PinnedAgentTileLabel<Avatar: View, Detail: View>: View {
    let name: String
    var isLifted = false
    /// The New agent slot's label is quieter than an agent's name.
    var isPlaceholder = false
    @ViewBuilder let avatar: () -> Avatar
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        VStack(spacing: 6) {
            avatar()
                .frame(width: PinnedAgentsLayout.avatarSize, height: PinnedAgentsLayout.avatarSize)
                .scaleEffect(isLifted ? 1.08 : 1)
                .shadow(color: .black.opacity(isLifted ? 0.22 : 0), radius: 12, y: 6)
            Text(name)
                .font(.bighelp(.subheadline).weight(.semibold))
                .foregroundStyle(isPlaceholder ? theme.secondaryText : theme.primaryText)
                .lineLimit(1)
            detail()
                .font(.bighelp(.caption))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
        .padding(.vertical, BighelpTokens.space4)
        .contentShape(.rect)
    }

    @BighelpThemeReader private var theme
}

/// A grid tile for a pinned or featured agent: large live avatar, name, and
/// underneath what it's doing, or its role when it's idle. `AgentPinnedGrid`
/// handles taps, lifting and moving.
struct AgentFeaturedTile: View {
    let agent: AgentProfile
    let imageURL: URL?
    let liveState: AgentLiveState
    let isPrimary: Bool
    var isLifted = false

    /// The role on one short line; the tile trails off if it's still too wide.
    static func roleLine(_ role: String, limit: Int = 28) -> String? {
        let line = role.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return nil }
        guard line.count > limit else { return line }
        return String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    var body: some View {
        PinnedAgentTileLabel(name: agent.name, isLifted: isLifted) {
            AvatarView(
                stableID: agent.id, displayName: agent.name,
                imageURL: imageURL, size: PinnedAgentsLayout.avatarSize, state: liveState
            )
            .accessibilityHidden(true)
        } detail: {
            if liveState != .idle {
                AgentLiveStateLabel(state: liveState, font: .caption)
            } else if let role = Self.roleLine(agent.role) {
                Text(role).truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agent.name)
        .accessibilityValue([liveState == .idle ? Self.roleLine(agent.role) : liveState.label,
                             isPrimary ? "Primary agent" : nil].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Dashed "New" slot that trails the featured grid when creation is allowed.
struct AgentNewTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PinnedAgentTileLabel(name: "New agent", isPlaceholder: true) {
                AgentDashedPlusCircle(size: PinnedAgentsLayout.avatarSize)
            } detail: {
                EmptyView()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Create agent")
    }
}

/// The "start a group chat" row at the top of the group chats section.
struct AgentNewGroupRow: View {
    let action: () -> Void

    @ScaledMetric(relativeTo: .callout) private var titleSize: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var detailSize: CGFloat = 14

    var body: some View {
        Button(action: action) {
            HStack(spacing: BighelpTokens.space12) {
                AgentDashedPlusCircle(size: AgentRowView.avatarSize, tint: theme.action)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New group chat")
                        .font(.system(size: titleSize, weight: .semibold))
                        .foregroundStyle(theme.action)
                    Text("Bring a few agents into one conversation")
                        .font(.system(size: detailSize))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
            .padding(.vertical, 10)
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New group")
        .accessibilityHint("Starts a group chat with several agents.")
    }

    @BighelpThemeReader private var theme
}

struct AgentDashedPlusCircle: View {
    let size: CGFloat
    var tint: Color? = nil

    var body: some View {
        Circle()
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .foregroundStyle(tint ?? theme.tertiaryText)
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: size * 0.3, weight: .semibold))
                    .foregroundStyle(tint ?? theme.secondaryText)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @BighelpThemeReader private var theme
}

/// Friendly first-run state for a host with no agents yet.
struct AgentsEmptyStateView: View {
    let canCreate: Bool
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: BighelpTokens.space12) {
            BighelpNoodleView(motion: .idle, size: 72)
            Text("No agents yet")
                .bighelpFont(.screenTitle)
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text(canCreate
                 ? "Create a personal assistant and it will show up here, ready to chat."
                 : "Agents on this host appear here.")
                .bighelpFont(.body)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if canCreate {
                Button(action: onCreate) {
                    Label("Create an agent", systemImage: "plus")
                        .bighelpFont(.label)
                        .frame(maxWidth: 280, minHeight: BighelpTokens.hitTarget)
                }
                .bighelpProminentButtonStyle()
                .buttonBorderShape(.capsule)
                .tint(theme.action)
                .foregroundStyle(theme.actionForeground)
                .padding(.top, BighelpTokens.space8)
                .accessibilityIdentifier("agents.empty.create")
            }
        }
        .padding(.horizontal, BighelpTokens.space32)
        .padding(.vertical, BighelpTokens.space40)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    @BighelpThemeReader private var theme
}
