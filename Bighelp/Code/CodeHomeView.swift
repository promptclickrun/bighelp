import SwiftUI

/// What the Code home needs from the shell.
@MainActor
struct CodeHomeContext {
    let store: CodeHomeStore
    let status: any CodeSessionStatusReading
    let agents: [AgentProfile]
    var avatarURL: (AgentProfile) -> URL? = { _ in nil }
    let onOpenSession: (CodeSessionRecord) -> Void
    let onOpenChanges: (CodeSessionRecord) -> Void
    var onOpenBatch: (CodeBatch) -> Void = { _ in }
    let onPullRequests: () -> Void
    let onWorktrees: () -> Void
    /// Asks Hermes which sessions are running, for cards whose chat isn't open.
    let onRefreshActivity: () async -> Void
    /// Changes with each connection to the computer, so the home reloads once it's up.
    let connectionKey: String?
}

/// Bighelp IDE's home (the Launchpad): this project's coding sessions with their
/// live status, and the message box that starts a new one with each send.
struct CodeHomeView: View {
    let context: CodeHomeContext
    @State private var renaming: CodeBatch?
    @State private var newTitle = ""

    var body: some View {
        let store = context.store
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BighelpTokens.space12) {
                filterChips
                if let message = store.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityIdentifier("code.error")
                }
                ForEach(store.projectLaunches) { launch in
                    CodeLaunchCard(launch: launch) { store.dismiss(launch) }
                }
                ForEach(visibleBatches) { batch in
                    batchCard(batch)
                }
                ForEach(visibleSessions) { session in
                    sessionCard(session)
                }
                if store.projectLaunches.isEmpty && store.projectSessions.isEmpty && store.projectBatches.isEmpty
                    && !store.isLoading {
                    empty
                }
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.top, BighelpTokens.space4)
            .padding(.bottom, BighelpTokens.space16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .dismissesKeyboardOnScroll(true)
        // A tap anywhere outside the message box puts the keyboard away, as in
        // Messages. Simultaneous, so cards and chips still take their taps.
        .simultaneousGesture(TapGesture().onEnded { BighelpKeyboard.dismiss() })
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CodeComposer(store: store, agents: context.agents, avatarURL: context.avatarURL, onWorktrees: context.onWorktrees)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
        }
        .toolbar {
            #if targetEnvironment(macCatalyst)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
                    .keyboardShortcut("r")
                    .accessibilityIdentifier("code.refresh")
            }
            #endif
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: context.onPullRequests) {
                    Image(systemName: "arrow.triangle.pull").bighelpToolbarIcon()
                }
                .bighelpIconLabel(openPullRequests == 1 ? "1 open pull request" : "\(openPullRequests) open pull requests")
                .accessibilityIdentifier("code.pull-requests")
            }
        }
        .bighelpRefreshable { await reload() }
        .task(id: context.connectionKey) { await reload() }
        .alert("Rename batch", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newTitle)
                .accessibilityIdentifier("code.batch.rename")
            Button("Save") {
                if let renaming { context.store.rename(renaming, to: newTitle) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.screen")
    }

    private func reload() async {
        await context.store.load()
        await context.onRefreshActivity()
    }

    private var openPullRequests: Int {
        context.store.git?.pullRequests.filter { $0.state == "open" }.count ?? 0
    }

    private var visibleSessions: [CodeSessionRecord] {
        let store = context.store
        guard store.filter != .all else { return store.projectSingleSessions }
        return store.projectSingleSessions.filter { status(of: $0).filter == store.filter }
    }

    /// A batch shows under a filter when any of its sessions matches it.
    private var visibleBatches: [CodeBatch] {
        let store = context.store
        guard store.filter != .all else { return store.projectBatches }
        return store.projectBatches.filter { batch in
            batch.sessionIDs.contains { id in
                store.sessions.first { $0.id == id }.map { status(of: $0).filter == store.filter } ?? false
            }
        }
    }

    private func batchCard(_ batch: CodeBatch) -> some View {
        let store = context.store
        let members = CodeBatchMember.members(of: batch, sessions: store.sessions)
        let pending = store.pendingLaunches(of: batch).reversed()
        let lines = members.map { member in
            CodeBatchCard.Line(id: member.id, title: member.title, color: member.color,
                               status: store.sessions.first { $0.id == member.id }.map(status(of:)) ?? .ready)
        } + pending.enumerated().map { offset, launch in
            CodeBatchCard.Line(id: launch.id.uuidString, title: launch.title,
                               color: CodeSessionColor.color(at: members.count + offset),
                               status: launch.step.isFailed ? .failed("Couldn't start") : .starting("Setting up"))
        }
        return Button { context.onOpenBatch(batch) } label: {
            CodeBatchCard(batch: batch, lines: lines, startedCount: members.count)
        }
        .buttonStyle(.bighelpTilePress)
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                renaming = batch
                newTitle = batch.title
            }
            Button("Remove from list", systemImage: "eye.slash") { store.forget(batch) }
        }
        .accessibilityIdentifier("code.batch-card")
    }

    private func status(of session: CodeSessionRecord) -> CodeSessionStatus {
        if let launch = context.store.launch(for: session) {
            if case .failed(let reason) = launch.step { return .failed(reason) }
            return .starting("Sending your message…")
        }
        return context.status.status(of: session.id)
    }

    private var filterChips: some View {
        let store = context.store
        let counts = Dictionary(grouping: store.projectSessions.map { status(of: $0).filter }, by: { $0 })
            .mapValues(\.count)
        return ScrollView(.horizontal) {
            HStack(spacing: BighelpTokens.space8) {
                ForEach(CodeSessionFilter.allCases) { filter in
                    let count = filter == .all ? store.projectSessions.count : counts[filter] ?? 0
                    Button { store.filter = filter } label: {
                        HStack(spacing: BighelpTokens.space4) {
                            Text(filter.title)
                            Text("\(count)").foregroundStyle(store.filter == filter ? theme.canvas.opacity(0.7) : theme.secondaryText)
                        }
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .foregroundStyle(store.filter == filter ? theme.canvas : theme.primaryText)
                        .padding(.horizontal, BighelpTokens.space12)
                        .frame(minHeight: 34)
                        .background(store.filter == filter ? theme.primaryText : theme.surface, in: .capsule)
                        .contentShape(.capsule)
                    }
                    .bighelpPlainButtonStyle(.capsule)
                    .accessibilityAddTraits(store.filter == filter ? .isSelected : [])
                    .accessibilityIdentifier("code.filter.\(filter.rawValue)")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func sessionCard(_ session: CodeSessionRecord) -> some View {
        let pullRequest = session.branch.flatMap { branch in
            context.store.git?.pullRequests.first { $0.branch == branch }
        }
        return Button { context.onOpenSession(session) } label: {
            CodeSessionCard(session: session, status: status(of: session), pullRequest: pullRequest)
        }
        .buttonStyle(.bighelpTilePress)
        .contextMenu {
            Button("Changes", systemImage: "plus.forwardslash.minus") { context.onOpenChanges(session) }
            Button("Remove from list", systemImage: "eye.slash") { context.store.forget(session) }
        }
        .accessibilityIdentifier("code.session.\(session.id)")
    }

    private var empty: some View {
        VStack(spacing: BighelpTokens.space12) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(theme.action)
            Text(context.store.projects.isEmpty ? "No projects yet" : "Describe a change")
                .font(.bighelp(.title3).weight(.semibold))
                .foregroundStyle(theme.primaryText)
            Text(context.store.projects.isEmpty
                 ? "Add a git folder from your computer as a project, then send what you want changed."
                 : "Each message you send starts its own session. Send another while the first one works.")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BighelpTokens.space32)
        .accessibilityIdentifier("code.empty")
    }

    @BighelpThemeReader private var theme
}

/// One session: its status dot, name, where it works and what it's doing now.
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
