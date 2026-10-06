import Foundation
import WidgetKit

/// Keeps the Workflows widget's snapshot current while bighelp is open: the runs
/// going on now, read every 15 seconds while one runs and every 2 minutes
/// otherwise. Only when a Workflows widget is on the Home Screen.
@MainActor
enum WorkflowsWidgetPublisher {
    static let busyInterval: Duration = .seconds(15)
    static let quietInterval: Duration = .seconds(120)

    private static var pending: Task<Void, Never>?

    /// Reads until cancelled (the app leaves the foreground or the computer changes).
    static func follow(client: any WorkflowsClient) async {
        while !Task.isCancelled {
            let busy = await refresh(client: client)
            try? await Task.sleep(for: busy ? busyInterval : quietInterval)
        }
    }

    /// One read; whether anything is running. A failed read keeps what the widget shows.
    @discardableResult
    static func refresh(client: any WorkflowsClient) async -> Bool {
        do {
            let list = try await client.list(includeArchived: false)
            guard !Task.isCancelled else { return false }
            let snapshot = snapshot(list)
            write(snapshot)
            return !snapshot.runs.isEmpty
        } catch is CancellationError {
            return false
        } catch WorkspaceClientError.unavailable {
            write(BighelpWorkflowsSnapshot(runs: [], isAvailable: false, generatedAt: .now))
            return false
        } catch {
            return !BighelpWorkflowsSnapshot.load().runs.isEmpty
        }
    }

    /// Runs that need the person first, then the rest, newest change first.
    static func snapshot(_ list: WorkflowsList, now: Date = .now) -> BighelpWorkflowsSnapshot {
        var seen = Set<String>()
        let runs = (list.waiting + list.active)
            .filter { !$0.state.isFinished && !$0.sample && seen.insert($0.id).inserted }
            .map(run)
            .sorted { lhs, rhs in
                let left = rank(lhs.phase), right = rank(rhs.phase)
                if left != right { return left < right }
                return (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast)
            }
        return BighelpWorkflowsSnapshot(runs: Array(runs.prefix(BighelpWorkflowsSnapshot.maximumRuns)),
                                        isAvailable: true, generatedAt: now)
    }

    static func run(_ summary: WorkflowRunSummary) -> BighelpWorkflowsSnapshot.Run {
        let phase: BighelpWorkflowsSnapshot.Phase = if summary.paused {
            .paused
        } else if summary.state == .waitingForYou || summary.waiting != nil {
            .waitingForYou
        } else if summary.state == .needsAttention || summary.attention != nil {
            .needsAttention
        } else {
            .working
        }
        return BighelpWorkflowsSnapshot.Run(
            id: summary.id, name: clip(summary.workflowName, 60), number: summary.number, phase: phase,
            step: summary.stageTitle.map { clip($0, 60) }, detail: detail(summary, phase: phase),
            stepsDone: min(summary.stagesDone, summary.stageCount), stepCount: summary.stageCount,
            startedAt: summary.startedAt)
    }

    /// What the step is doing, in the app's words.
    private static func detail(_ summary: WorkflowRunSummary, phase: BighelpWorkflowsSnapshot.Phase) -> String? {
        switch phase {
        case .paused: "Paused"
        case .waitingForYou: summary.waiting?.kind == "signoff" || summary.waiting == nil ? "Waiting for your OK" : "Waiting for you"
        case .needsAttention: summary.attention.map { clip($0.message, 80) } ?? "Needs attention"
        case .working: (summary.stageState ?? summary.state).title
        }
    }

    private static func rank(_ phase: BighelpWorkflowsSnapshot.Phase) -> Int {
        switch phase {
        case .waitingForYou: 0
        case .needsAttention: 1
        case .working: 2
        case .paused: 3
        }
    }

    /// A signed-out or switched computer must not leave its runs on the Home Screen.
    static func clear() {
        write(.empty)
    }

    static func isInstalled() async -> Bool {
        await BighelpWidgetInstalls.contains(kind: BighelpWorkflowsSnapshot.kind)
    }

    private static func write(_ snapshot: BighelpWorkflowsSnapshot) {
        var previous = BighelpWorkflowsSnapshot.load()
        let previousDate = previous.generatedAt
        previous.generatedAt = snapshot.generatedAt
        // Unchanged runs still refresh the time now and then, so the widget doesn't call them stale.
        let refreshesTime = snapshot.generatedAt.timeIntervalSince(previousDate) > BighelpWorkflowsSnapshot.staleAfter / 2
        guard previous != snapshot || (refreshesTime && !snapshot.runs.isEmpty) else { return }
        try? snapshot.save()
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadTimelines(ofKind: BighelpWorkflowsSnapshot.kind)
        }
    }

    private static func clip(_ value: String, _ limit: Int) -> String {
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit - 1)) + "…"
    }
}
