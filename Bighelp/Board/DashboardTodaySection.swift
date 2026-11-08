import SwiftUI

/// Activities, at the top of a bot's Dashboard: one line until the person opens it, so Feed, Ideas
/// and Goals stay where they were. Open, the subagents and background commands of the last days by
/// day (Today, Yesterday, …), running first; routines too when ⋯ › Show routines is on. It reads
/// again while the Dashboard shows: often while something runs, rarely otherwise.
struct DashboardTodaySection: View {
    @Bindable var today: AgentTodayModel
    let agentID: String
    let agentName: String
    @AppStorage(AgentTodayModel.showsRoutinesKey) private var showsRoutines = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @BighelpThemeReader private var theme

    private struct RefreshKey: Equatable {
        let agentID: String
        let connection: Int
        let isActive: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            header
            if today.isExpanded {
                content
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard.today")
        .task(id: RefreshKey(agentID: agentID, connection: today.connection, isActive: scenePhase == .active)) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await today.refresh(agentID: agentID)
                try? await Task.sleep(for: today.hasRunning ? AgentTodayModel.runningInterval
                                                            : AgentTodayModel.quietInterval)
            }
        }
    }

    private var summary: String { AgentTodayModel.summary(today.phase, showsRoutines: showsRoutines) }

    private var header: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy) { today.isExpanded.toggle() }
        } label: {
            HStack(spacing: BighelpTokens.space8) {
                // The summary goes under the title when larger text can't fit both on one line.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) { title; summaryText }
                    VStack(alignment: .leading, spacing: 2) { title; summaryText }
                }
                Spacer(minLength: BighelpTokens.space8)
                Image(systemName: today.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.bighelp(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .accessibilityLabel("Activities, \(summary)")
        .accessibilityValue(today.isExpanded ? "Open" : "Closed")
        .accessibilityHint("Shows the work \(agentName) ran in the background, by day")
        .driveTarget("dashboard.today.toggle")
        .accessibilityIdentifier("dashboard.today.toggle")
    }

    private var title: some View {
        Text("Activities")
            .font(.bighelp(.title3, weight: .bold))
            .foregroundStyle(theme.primaryText)
    }

    private var summaryText: some View {
        Text(summary)
            .font(.bighelp(.subheadline, weight: .medium))
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
    }

    @ViewBuilder
    private var content: some View {
        switch today.phase {
        case .loading:
            note(String(localized: "Loading…"))
        case .unsupported:
            note(String(localized: "Update the bighelp plugin on this computer to see what \(agentName) runs in the background."))
        case .failed:
            note(String(localized: "Today's work didn't load. It tries again in a moment."))
        case .loaded(let all):
            let days = AgentTodayModel.days(AgentTodayModel.visible(all, showsRoutines: showsRoutines))
            if days.isEmpty {
                note(String(localized: "Nothing yet. Subagents and background commands show here while they run and after they finish."))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(days) { day in
                        Text(day.title)
                            .font(.bighelp(.subheadline, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.top, BighelpTokens.space8)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(day.items) { DashboardTodayRow(item: $0) }
                    }
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.bighelp(.subheadline))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, BighelpTokens.space8)
            .accessibilityIdentifier("dashboard.today.note")
    }
}

/// One piece of today's work: what it is, how it went, and when.
private struct DashboardTodayRow: View {
    let item: AgentTodayItem
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: symbol)
                .font(.bighelp(.subheadline, weight: .semibold))
                .foregroundStyle(item.state == .running ? theme.actionForeground
                                 : item.state == .failed ? theme.danger : theme.primaryText)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(item.state == .running ? theme.action : theme.secondaryText.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(item.kind == .command ? .bighelp(.body, weight: .semibold).monospaced()
                                                : .bighelp(.body, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                Text(Self.detail(item))
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
                // Once a minute, so "Running · 3 min" keeps up without redrawing all the time.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if let when = Self.when(item, now: context.date) {
                        Text(when)
                            .font(.bighelp(.caption))
                            .foregroundStyle(theme.secondaryText)
                            .monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, BighelpTokens.space8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dashboard.today.item.\(item.id)")
    }

    private var symbol: String {
        switch item.state {
        case .running:
            switch item.kind {
            case .subagent: "person.2"
            case .command: "terminal"
            case .scheduled: "calendar.badge.clock"
            }
        case .done: "checkmark.circle"
        case .failed: "xmark.circle"
        case .stopped: "stop.circle"
        case .unknown: "questionmark.circle"
        }
    }

    /// What it is, then how it went: "Command · Didn't finish: Exit 1".
    static func detail(_ item: AgentTodayItem) -> String {
        let kind = switch item.kind {
        case .subagent: String(localized: "Subagent")
        case .command: String(localized: "Command")
        case .scheduled: String(localized: "Scheduled task")
        }
        let outcome: String? = switch item.state {
        case .running: nil
        case .done: item.detail
        case .failed: item.detail.map { String(localized: "Didn't finish: \($0)") } ?? String(localized: "Didn't finish")
        case .stopped: String(localized: "Stopped")
        case .unknown: String(localized: "Didn't report back")
        }
        return outcome.map { "\(kind) · \($0)" } ?? kind
    }

    /// "Running · 3 min" while it runs, else the time it ended (or started).
    static func when(_ item: AgentTodayItem, now: Date) -> String? {
        if item.state == .running {
            guard let started = item.startedAt else { return String(localized: "Running") }
            let seconds = max(0, now.timeIntervalSince(started))
            guard seconds >= 60 else { return String(localized: "Running · just started") }
            let length = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
            return String(localized: "Running · \(length)")
        }
        return (item.endedAt ?? item.startedAt)?.formatted(date: .omitted, time: .shortened)
    }
}
