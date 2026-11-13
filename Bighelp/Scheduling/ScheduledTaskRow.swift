import SwiftUI

/// A task in the Tasks list, styled like a conversation row: the agent's
/// avatar carries the live status, the name leads, the schedule follows.
struct ScheduledTaskRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let task: ScheduledTask
    let agent: AgentProfile?
    var avatarURL: URL? = nil
    /// True when Hermes reports an active run for this task.
    var isRunning = false

    var body: some View {
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: BighelpTokens.space12) {
            AvatarView(
                stableID: agent?.id ?? "unavailable-\(task.agentID)",
                displayName: agent?.name ?? "Unavailable bot",
                imageURL: avatarURL,
                size: 44,
                state: liveState
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.displayName)
                    .font(.bighelp(.callout).weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                Text(ScheduledTaskCopy.friendlySchedule(task))
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Text(ScheduledTaskCopy.shortNextRun(task, isRunning: isRunning))
                    .font(.bighelp(.footnote))
                    .foregroundStyle(task.status == .failed ? theme.danger : theme.tertiaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, BighelpTokens.space8)
        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.rowAccessibilityLabel)
        .accessibilityIdentifier("scheduled-task.row.\(task.identity.accessibilitySuffix)")
    }

    private var liveState: AgentLiveState {
        ScheduledTaskCopy.liveState(for: task, isRunning: isRunning)
    }

    private var presentation: ScheduledTaskPresentation {
        ScheduledTaskPresentation(task: task, agentName: agent?.name)
    }

    @BighelpThemeReader private var theme
}

extension ScheduledTaskStatus {
    var badgeStatus: StatusBadge.Status {
        switch self {
        case .active: .success
        case .paused: .warning
        case .completed: .information
        case .failed: .danger
        }
    }
}

/// Friendly, consumer-facing copy shared by the Tasks list, detail and editor.
/// Derived only from real task data; never invents status.
enum ScheduledTaskCopy {
    static func liveState(for task: ScheduledTask, isRunning: Bool) -> AgentLiveState {
        if isRunning { return .thinking }
        if task.status == .failed || task.lastError?.isEmpty == false { return .nudge }
        return .idle
    }

    /// The schedule without a trailing time zone when it matches this device.
    static func friendlySchedule(_ task: ScheduledTask) -> String {
        let description = task.scheduleDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let zoneID = task.schedule.timeZoneID
        let suffix = " \(zoneID)"
        guard zoneID == TimeZone.current.identifier, description.hasSuffix(suffix) else {
            return description.isEmpty ? "Custom schedule" : description
        }
        return String(description.dropLast(suffix.count))
    }

    /// Compact next-run line, e.g. "Next: Tue 8:00 AM".
    static func shortNextRun(_ task: ScheduledTask, isRunning: Bool = false, now: Date = .now) -> String {
        shortNextRun(status: task.status, nextRun: task.nextRun, isRunning: isRunning, now: now)
    }

    static func shortNextRun(status: ScheduledTaskStatus, nextRun: Date?, isRunning: Bool = false,
                             now: Date = .now) -> String {
        if isRunning { return "Working on it now" }
        switch status {
        case .completed: return "Finished"
        case .failed: return "Needs a look"
        case .paused: return "Paused"
        case .active: break
        }
        guard let nextRun else { return "Next run confirmed by your bot" }
        return "Next: \(shortDate(nextRun, now: now))"
    }

    static func shortDate(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        if date > now, let week = calendar.date(byAdding: .day, value: 6, to: now), date < week {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }
}

/// Uppercase, letterspaced section caption ("UP NEXT", "PAUSED").
struct ScheduledTaskSectionCaption: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: BighelpTokens.space8) {
            Text(title.uppercased())
                .font(.bighelp(.caption2).weight(.bold))
                .tracking(0.88)
            if let count {
                Text(count.formatted())
                    .font(.bighelp(.caption2).weight(.bold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(theme.secondaryText)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @BighelpThemeReader private var theme
}
