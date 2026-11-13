import SwiftUI

/// Which host a row belongs to, shown only when there's more than one.
struct FleetHostTag: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.bighelp(.caption2).weight(.semibold))
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(theme.secondaryText.opacity(0.12), in: .capsule)
            .accessibilityLabel("on \(name)")
    }

    @BighelpThemeReader private var theme
}

/// A section caption as the Sessions list draws them: small, bold, spaced capitals.
struct FleetSectionCaption: View {
    let title: LocalizedStringKey
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 11
    @BighelpThemeReader private var theme

    var body: some View {
        Text(title)
            .font(.system(size: size, weight: .bold))
            .tracking(size * 0.08)
            .textCase(.uppercase)
            .foregroundStyle(theme.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A scheduled task on a computer that isn't the one in use, as that computer last listed it: its bot,
/// its name with the computer's tag, when it runs and when it runs next.
struct FleetTaskRow: View {
    let task: FleetTask
    let fleet: FleetStore

    var body: some View {
        let agent = fleet.agent(hostID: task.hostID, profileID: task.profileID)
        HStack(spacing: BighelpTokens.space12) {
            AvatarView(stableID: task.profileID, displayName: agent?.name ?? "Agent",
                       imageURL: fleet.avatars.url(for: agent?.avatarFile), size: 44,
                       state: task.status == .failed ? .nudge : nil)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: BighelpTokens.space8) {
                    Text(task.name)
                        .font(.bighelp(.callout).weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    FleetHostTag(name: fleet.hostName(task.hostID))
                }
                Text([agent?.name, task.schedule].compactMap { $0 }.joined(separator: " · "))
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
                Text(ScheduledTaskCopy.shortNextRun(status: task.status, nextRun: task.nextRun))
                    .font(.bighelp(.footnote))
                    .foregroundStyle(task.status == .failed ? theme.danger : theme.tertiaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, BighelpTokens.space4)
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}
