import Foundation
import Observation
import WidgetKit

/// Mirrors the live native workspace into the App Group snapshot the Home
/// Screen and Lock Screen widgets read. Observation-driven and coalesced so a
/// streaming turn does not reload widget timelines on every token.
@MainActor
final class BighelpWidgetSnapshotPublisher {
    private weak var sessions: SessionCatalogStore?
    private weak var scheduledTasks: ScheduledTasksStore?
    private weak var agents: AgentDirectoryStore?
    private let extras: BighelpWidgetExtras
    /// The gateway this workspace is on; widgets set to it keep its data.
    private let hostID: String?
    private var pending: Task<Void, Never>?
    private var lastPublished: BighelpWidgetSnapshot?
    private var retired = false
    private let interval: Duration
    private let write: (BighelpWidgetSnapshot) -> Void
    /// This gateway's saved copy: what the widgets keep of anything this run doesn't know yet.
    private let saved: BighelpWidgetSnapshot?

    init(sessions: SessionCatalogStore, scheduledTasks: ScheduledTasksStore?, agents: AgentDirectoryStore,
         hostID: String? = nil, extras: BighelpWidgetExtras = .shared, interval: Duration = .seconds(2),
         saved: BighelpWidgetSnapshot? = nil,
         write: @escaping (BighelpWidgetSnapshot) -> Void = BighelpWidgetSnapshotPublisher.persist) {
        self.sessions = sessions; self.scheduledTasks = scheduledTasks; self.agents = agents; self.extras = extras
        self.hostID = hostID; self.interval = interval; self.write = write
        self.saved = saved.flatMap { $0.hostID == hostID ? $0 : nil }
        observe()
    }

    /// `next`: the gateway that took over. Widgets that follow the gateway in use show its copy from
    /// its last visit at once, not nothing until it loads. A signed-out host leaves nothing (nil).
    func retire(next: BighelpWidgetSnapshot? = nil) {
        retired = true
        pending?.cancel(); pending = nil
        write(next ?? .empty)
    }

    private func observe() {
        guard !retired else { return }
        withObservationTracking { _ = makeSnapshot() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.changed() }
        }
    }

    private func changed() {
        guard !retired else { return }
        observe()
        guard pending == nil else { return }
        pending = Task { @MainActor [weak self, interval] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled, !self.retired else { return }
            self.pending = nil
            self.publishNow()
        }
    }

    func publishNow() {
        // Until the gateway's agents are known (a launch, or bighelp woken in the background, before
        // the computer answers), the widgets keep what they show.
        guard !retired, agents?.knowsProfiles == true else { return }
        var snapshot = makeSnapshot()
        if var previous = lastPublished {
            previous.generatedAt = snapshot.generatedAt
            guard previous != snapshot else { return }
        }
        snapshot.generatedAt = .now
        lastPublished = snapshot
        write(snapshot)
    }

    func makeSnapshot() -> BighelpWidgetSnapshot {
        let profiles = agents?.profiles ?? []
        let names = Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let defaultAgent = agents?.resolvedAgent(explicitID: nil) ?? profiles.first
        let records = (sessions?.presentedRecords ?? [])
            .filter { $0.parentSessionID == nil && !$0.isWorkflowSession && ($0.hasAcceptedMessage || $0.hasActiveWork) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(12)
        let sessionRows = records.map { record -> BighelpWidgetSnapshot.Session in
            let agentName = record.agentIDs.first.flatMap { names[$0] } ?? defaultAgent?.name ?? "Agent"
            let running = record.hasActiveWork
            return .init(id: record.id, title: Self.clip(record.title, 60) ?? "Chat", agentName: agentName,
                         status: running ? Self.status(for: record) : "Replied",
                         preview: Self.clip(Self.preview(for: record), 140),
                         isRunning: running, updatedAt: record.updatedAt,
                         agentID: record.agentIDs.first,
                         activity: running ? Self.activity(for: record) : nil)
        }
        let taskRows = (scheduledTasks?.tasks ?? [])
            .filter { $0.status == .active }
            .prefix(12)
            .map { task in
                BighelpWidgetSnapshot.Task(id: task.id, name: Self.clip(task.name, 60) ?? "Task",
                    agentName: names[task.agentID] ?? "Agent", schedule: Self.clip(task.scheduleDescription, 60) ?? "",
                    nextRun: task.nextRun, lastResult: Self.clip(task.lastResult, 100))
            }
        // Only agents on this computer, so another host's boards never reach the Home Screen.
        let agentRows = profiles.prefix(50).map { BighelpWidgetSnapshot.Agent(id: $0.id, name: Self.clip($0.name, 40) ?? "Agent") }
        let boards = extras.agentBoards.values.filter { names[$0.agentID] != nil }.sorted { $0.agentID < $1.agentID }
        let limit = BighelpWidgetSnapshot.maximumPinnedAgents
        var snapshot = BighelpWidgetSnapshot(defaultAgentID: defaultAgent?.id, defaultAgentName: defaultAgent?.name,
                                    sessions: Array(sessionRows), tasks: Array(taskRows), generatedAt: .now,
                                    feed: extras.feed, goals: extras.goals, ideas: extras.ideas,
                                    agents: Array(agentRows), boards: boards,
                                    lightPalette: extras.lightPalette, darkPalette: extras.darkPalette,
                                    // The same check for pins: a switched computer's never show as this one's.
                                    pinnedAgents: Array(extras.pinnedAgents.filter { names[$0.agentID] != nil }.prefix(limit)),
                                    allPinnedAgents: Array(extras.allPinnedAgents.prefix(limit)),
                                    hostID: hostID)
        // What this run hasn't read or filled in yet stays as the widgets last showed it.
        if let saved {
            // Chats and tasks not loaded yet (the chats load first, with the tasks right behind).
            if sessions?.hasLoadedState != true, sessionRows.isEmpty {
                snapshot.sessions = saved.sessions
                if taskRows.isEmpty { snapshot.tasks = saved.tasks }
            }
            let filled = extras.filled
            if !filled.contains(.board) { snapshot.feed = saved.feed; snapshot.goals = saved.goals; snapshot.ideas = saved.ideas }
            if !filled.contains(.boards) { snapshot.boards = saved.boards }
            if !filled.contains(.palettes) {
                snapshot.lightPalette = saved.lightPalette
                snapshot.darkPalette = saved.darkPalette
            }
            if !filled.contains(.pins) {
                snapshot.pinnedAgents = saved.pinnedAgents
                snapshot.allPinnedAgents = saved.allPinnedAgents
            }
        }
        return snapshot
    }

    private static func status(for record: SessionRecord) -> String {
        if let count = record.sessionSubagents?.subagents.count, count > 0 {
            return count == 1 ? "1 subagent working" : "\(count) subagents working"
        }
        if let last = record.activityEvents.last, !last.lifecycle.isTerminal {
            let title = last.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return clip(title, 60) ?? "Working" }
        }
        return "Working"
    }

    /// A fixed category for the widget's activity icon, never the tool's text.
    private static func activity(for record: SessionRecord) -> String {
        guard let last = record.activityEvents.last, !last.lifecycle.isTerminal else {
            return BighelpActivityPose.thinking.rawValue
        }
        if last.kind == .subagent { return BighelpActivityPose.delegating.rawValue }
        return BighelpActivityPose(tool: last.toolName ?? last.title).rawValue
    }

    private static func preview(for record: SessionRecord) -> String? {
        for item in record.items.reversed() where item.role == .assistant {
            if case .message(let text) = item.content {
                let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            }
        }
        return record.catalogPreview
    }

    private static func clip(_ value: String?, _ limit: Int) -> String? {
        guard let value else { return nil }
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit - 1)) + "…"
    }

    nonisolated static func persist(_ snapshot: BighelpWidgetSnapshot) {
        do { try snapshot.save() } catch { return }
        for kind in BighelpWidgetSnapshot.widgetKinds {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }
}
