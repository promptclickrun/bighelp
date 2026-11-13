import SwiftUI

// Work's cards for coding sessions: a batch, a session, a launch on its way, and their parts.

/// A batch sent with Send all: one card, one line per session with its live status.
struct CodeBatchCard: View {
    struct Line: Identifiable {
        let id: String
        let title: String
        let color: Color
        let status: CodeSessionStatus
    }

    let batch: CodeBatch
    let lines: [Line]
    let startedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(spacing: BighelpTokens.space12) {
                Image(systemName: "square.stack.3d.up")
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(theme.action)
                    .frame(width: BighelpTokens.scaled(30), height: BighelpTokens.scaled(30))
                    .background(theme.action.opacity(0.14), in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(batch.title)
                        .font(.bighelp(.headline))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.bighelp(.caption))
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
                if needsYou > 0 {
                    CodePill(text: needsYou == 1 ? "1 needs you" : "\(needsYou) need you", tint: theme.warning)
                }
            }
            ForEach(lines) { line in
                HStack(spacing: BighelpTokens.space8) {
                    Circle().fill(line.color).frame(width: 8, height: 8)
                    Text(line.title)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(line.status.shortTitle)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(color(for: line.status))
                }
            }
            if startedCount < batch.jobCount {
                Text("Starting \(min(startedCount + 1, batch.jobCount)) of \(batch.jobCount). "
                     + "Sessions start one at a time, then run side by side.")
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(BighelpTokens.space16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16)
                .stroke(theme.border, lineWidth: BighelpTokens.hairline)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var needsYou: Int { lines.filter { $0.status.filter == .needsYou }.count }

    private var subtitle: String {
        let count = batch.jobCount == 1 ? "1 session" : "\(batch.jobCount) sessions"
        return count + " · " + batch.createdAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    private func color(for status: CodeSessionStatus) -> Color {
        switch status {
        case .needsYou: theme.warning
        case .running, .starting: theme.action
        case .failed: theme.danger
        case .ready: theme.secondaryText
        }
    }

    @BighelpThemeReader private var theme
}

/// One session: its status dot, name, where it works and what it's doing now.
struct CodeSessionCard: View {
    let session: CodeSessionRecord
    let status: CodeSessionStatus
    let pullRequest: StockGitPullRequest?

    var body: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            CodeStatusDot(status: status)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(session.title)
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                CodeWhereLine(placement: session.placement, branch: session.branch)
                statusLine
                    .padding(.top, BighelpTokens.space4)
            }
            Spacer(minLength: 0)
        }
        .padding(BighelpTokens.space16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16)
                .stroke(theme.border, lineWidth: BighelpTokens.hairline)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: BighelpTokens.space8) {
            switch status {
            case .starting(let step):
                CodePill(text: "Starting", tint: theme.action)
                Text(step).foregroundStyle(theme.primaryText)
            case .running(let step):
                Image(systemName: "gearshape.2")
                Text(step ?? "Working").foregroundStyle(theme.primaryText).lineLimit(1)
            case .needsYou(let ask):
                CodePill(text: ask, tint: theme.warning, systemImage: "hand.raised")
            case .ready:
                if let pullRequest {
                    CodePill(text: "PR #\(pullRequest.number) \(pullRequest.state)", tint: theme.success,
                             systemImage: "arrow.triangle.pull")
                } else {
                    CodePill(text: "Ready", tint: theme.success)
                }
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.danger)
                Text(reason).foregroundStyle(theme.secondaryText).lineLimit(2)
            }
            if let mode = session.mode, mode != .standard {
                CodePill(text: mode.title, tint: mode == .yolo ? theme.warning : theme.action, systemImage: mode.systemImage)
            }
            Spacer(minLength: 0)
            // Worked out when the card draws; no ticking timer.
            Text(session.startedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                .foregroundStyle(theme.secondaryText)
        }
        .font(.bighelp(.subheadline))
    }

    @BighelpThemeReader private var theme
}

/// A send that's still making its worktree or session, or couldn't.
struct CodeLaunchCard: View {
    let launch: CodeLaunch
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            CodeStatusDot(status: isFailed ? .failed("") : .starting(""))
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(launch.title)
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                CodeWhereLine(placement: launch.placement, branch: launch.branch)
                HStack(spacing: BighelpTokens.space8) {
                    if case .failed(let reason) = launch.step {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.danger)
                        Text(reason).foregroundStyle(theme.secondaryText)
                        Spacer(minLength: 0)
                        Button("Dismiss", action: onDismiss)
                            .font(.bighelp(.subheadline).weight(.semibold))
                            .accessibilityIdentifier("code.launch.dismiss")
                    } else {
                        CodePill(text: "Starting", tint: theme.action)
                        Text(stepText).foregroundStyle(theme.primaryText)
                    }
                }
                .font(.bighelp(.subheadline))
                .padding(.top, BighelpTokens.space4)
            }
            Spacer(minLength: 0)
        }
        .padding(BighelpTokens.space16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16)
                .stroke(isFailed ? theme.border : theme.action.opacity(0.5), lineWidth: isFailed ? BighelpTokens.hairline : 1.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("code.launch")
    }

    private var isFailed: Bool {
        if case .failed = launch.step { return true }
        return false
    }

    private var stepText: String {
        switch launch.step {
        case .makingWorktree: "Making the worktree…"
        case .switchingBranch: "Switching the branch…"
        case .startingSession: "Starting the session…"
        case .sending, .failed: "Sending your message…"
        }
    }

    @BighelpThemeReader private var theme
}

/// The worktree or local folder, and its branch, in code type.
struct CodeWhereLine: View {
    let placement: CodePlacement
    let branch: String?

    var body: some View {
        HStack(spacing: BighelpTokens.space4) {
            Image(systemName: placement == .newWorktree ? "arrow.triangle.branch" : "laptopcomputer")
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(.footnote, design: .monospaced))
        .foregroundStyle(theme.secondaryText)
    }

    private var text: String {
        switch placement {
        case .newWorktree: branch ?? "new worktree"
        case .local: ["local", branch].compactMap { $0 }.joined(separator: " · ")
        }
    }

    @BighelpThemeReader private var theme
}

/// A session's status as a still dot: working, waiting on you, ready. When a session
/// finishes while you watch, the kit's done plays once in its place.
struct CodeStatusDot: View {
    let status: CodeSessionStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .background(Circle().fill(color.opacity(0.22)).frame(width: 18, height: 18))
            .frame(width: 18, height: 18)
            .bighelpNoodleMoment(.done, when: isReady, size: 22)
            .padding(.top, 2)
            .accessibilityHidden(true)
    }

    private var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    private var color: Color {
        switch status {
        case .starting, .running: theme.action
        case .needsYou: theme.warning
        case .ready: theme.success
        case .failed: theme.danger
        }
    }

    @BighelpThemeReader private var theme
}

struct CodePill: View {
    let text: String
    let tint: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: BighelpTokens.space4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text).lineLimit(1)
        }
        .font(.bighelp(.footnote).weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, BighelpTokens.space8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: .capsule)
    }
}
