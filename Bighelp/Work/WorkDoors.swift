import SwiftUI

/// A board one tap down from Work: its full page keeps every tool it has. The shell lists only the
/// doors this computer can open (Kanban and Workflows need their features).
struct WorkDoor: Identifiable {
    enum Kind: String, CaseIterable, Sendable {
        case projects, tasks, workflows, schedules

        var title: String {
            switch self {
            case .projects: String(localized: "Projects")
            case .tasks: String(localized: "Tasks")
            case .workflows: String(localized: "Workflows")
            case .schedules: String(localized: "Schedules")
            }
        }

        var systemImage: String {
            switch self {
            case .projects: "folder"
            case .tasks: "checklist"
            case .workflows: "point.3.connected.trianglepath.dotted"
            case .schedules: "clock"
            }
        }
    }

    let kind: Kind
    /// What its store counts (projects, open cards, workflows, scheduled tasks); nil shows none.
    var count: Int? = nil
    let open: () -> Void

    var id: Kind { kind }
}

/// Work filtered to a project: the header's ⋯ (`WorkProjectMenu`).
struct WorkProjectActions {
    let onPullRequests: () -> Void
    let onWorktrees: () -> Void
    /// Nil when this computer has no Dev Factory.
    var onDevFactory: (() -> Void)? = nil
    /// Open pull requests in the project, for the row's value.
    var openPullRequests = 0
}

/// "Open a board": the doors as rows of one card.
struct WorkDoorsSection: View {
    let doors: [WorkDoor]

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text("Open a board")
                .font(.bighelp(.footnote).weight(.semibold))
                .foregroundStyle(theme.secondaryText)
                .padding(.leading, BighelpTokens.space4)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(doors.enumerated()), id: \.element.id) { index, door in
                    if index > 0 {
                        Divider().padding(.leading, BighelpTokens.space48)
                    }
                    row(door)
                }
            }
            .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16))
            .overlay {
                RoundedRectangle(cornerRadius: BighelpTokens.radius16)
                    .stroke(theme.border, lineWidth: BighelpTokens.hairline)
            }
        }
        .padding(.top, BighelpTokens.space12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.doors")
    }

    private func row(_ door: WorkDoor) -> some View {
        Button(action: door.open) {
            HStack(spacing: BighelpTokens.space12) {
                Image(systemName: door.kind.systemImage)
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(theme.action)
                    .frame(width: BighelpTokens.scaled(24))
                Text(door.kind.title)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: BighelpTokens.space8)
                if let count = door.count {
                    Text("\(count)")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.secondaryText)
                }
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(.horizontal, BighelpTokens.space16)
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius16))
        .accessibilityIdentifier("work.door.\(door.kind.rawValue)")
    }

    @BighelpThemeReader private var theme
}

/// ⋯ for Work filtered to a project: Pull requests, Worktrees and Dev Factory. The shell puts it in
/// the header's `trailing` slot.
struct WorkProjectMenu: View {
    let actions: WorkProjectActions

    var body: some View {
        Menu {
            Button(action: actions.onPullRequests) {
                if actions.openPullRequests > 0 {
                    Label("Pull requests (\(actions.openPullRequests))", systemImage: "arrow.triangle.pull")
                } else {
                    Label("Pull requests", systemImage: "arrow.triangle.pull")
                }
            }
            .accessibilityIdentifier("work.project.pull-requests")
            Button("Worktrees", systemImage: "arrow.triangle.branch", action: actions.onWorktrees)
                .accessibilityIdentifier("work.project.worktrees")
            if let onDevFactory = actions.onDevFactory {
                Button("Dev Factory", systemImage: "gearshape.2", action: onDevFactory)
                    .accessibilityIdentifier("work.project.dev-factory")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.bighelp(.title3, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .contentShape(.circle)
                .bighelpNavigationGlass(in: Circle(), isInteractive: true)
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .accessibilityLabel("More")
        .accessibilityIdentifier("work.project.more")
    }
}
