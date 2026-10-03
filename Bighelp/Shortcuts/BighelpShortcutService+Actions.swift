import Foundation

/// Host features a Shortcut needs beyond the workspace stores. Each one
/// answers for the host in use right now, or nil when it has none.
@MainActor
struct BighelpShortcutHostServices {
    /// The computer's name; nil when none is set up.
    var hostName: @MainActor () -> String? = { nil }
    /// Hermes' version, read from the host. Shown only when it looks like one.
    var hermesVersion: @MainActor () async -> String? = { nil }
    /// Feed, Ideas and Goals (bighelp plugin).
    var boards: @MainActor () -> (any AgentBoardClient)? = { nil }
    /// Hermes' Kanban plugin.
    var kanban: @MainActor () -> (any KanbanService)? = { nil }
}

struct BighelpShortcutScheduledTask: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let jobID: String
    let agentID: String
    let name: String
    let agentName: String
    let schedule: String
    let isPaused: Bool

    /// Job IDs are unique per agent, so the entity carries both.
    static func entityID(agentID: String, jobID: String) -> String { agentID + "\u{1F}" + jobID }
}

struct BighelpShortcutGroupChat: Identifiable, Equatable, Hashable, Sendable {
    /// The chat list's ID for it.
    let id: String
    let name: String
    let memberNames: [String]
    /// Set for groups hosted on the computer; they open through their room.
    let hostedRoomID: String?
}

struct BighelpShortcutContinueResult: Equatable, Sendable {
    let sessionID: String
    let agentName: String
    let isNew: Bool
}

struct BighelpShortcutKanbanResult: Equatable, Sendable {
    let title: String
    let boardName: String
}

enum BighelpShortcutBoardSection: String, CaseIterable, Sendable {
    case feed, ideas, goals

    var title: String {
        switch self {
        case .feed: "Feed"
        case .ideas: "Ideas"
        case .goals: "Goals"
        }
    }

    var kind: AgentBoardItem.Kind {
        switch self {
        case .feed: .feed
        case .ideas: .idea
        case .goals: .goal
        }
    }
}

/// Feed, Ideas or Goals as text for automations: one line per item, the
/// title then a short line from it, newest first (goals still open first).
struct BighelpShortcutBoardResult: Equatable, Sendable {
    static let itemLimit = 10
    let agentName: String
    let section: BighelpShortcutBoardSection
    let lines: [String]

    var text: String {
        lines.isEmpty ? "Nothing in \(agentName)'s \(section.title) yet." : lines.joined(separator: "\n")
    }

    static func lines(_ items: [AgentBoardItem], section: BighelpShortcutBoardSection) -> [String] {
        items
            .filter { $0.kind == section.kind && !$0.dismissed }
            .sorted { lhs, rhs in
                if section == .goals, lhs.isDone != rhs.isDone { return !lhs.isDone }
                return lhs.createdAt > rhs.createdAt
            }
            .prefix(itemLimit)
            .map { item in
                let title = shortened(plain(item.title), to: 80)
                // A goal's note says where it stands; other items lead with their text.
                let detail = shortened(firstLine(item.kind == .goal && !item.note.isEmpty ? item.note : item.body),
                                       to: 150)
                let heading = title.isEmpty ? section.title : title
                return detail.isEmpty ? heading : "\(heading): \(detail)"
            }
    }

    /// The first line with words in it, without Markdown's marks.
    private static func firstLine(_ markdown: String) -> String {
        for line in markdown.split(whereSeparator: \.isNewline) {
            let text = plain(String(line))
            if !text.isEmpty { return text }
        }
        return ""
    }

    private static func plain(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        // Headings, quotes, list bullets and numbers at the start of a line.
        while let first = text.first, "#>-*+".contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if let dot = text.firstIndex(of: "."), text[..<dot].allSatisfy(\.isNumber), !text[..<dot].isEmpty {
            text = String(text[text.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        for mark in ["**", "__", "`", "~~"] { text = text.replacingOccurrences(of: mark, with: "") }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func shortened(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension BighelpShortcutService {
    /// Lists offered to Shortcuts stay short; Shortcuts shows them as menus and tiles.
    nonisolated static let listLimit = 50

    // MARK: Agents

    /// Makes the agent the one bighelp opens on, as picking it in the app does.
    func switchAgent(to agentID: String) async throws -> BighelpShortcutAgent {
        let workspace = try await liveWorkspace()
        guard let profile = workspace.agents.profiles.first(where: { $0.id == agentID }) else {
            throw BighelpShortcutServiceError.agentUnavailable
        }
        workspace.agents.makeHomeAgent(agentID)
        return BighelpShortcutAgent(id: profile.id, name: profile.name, role: profile.role, isDefault: profile.isDefault)
    }

    func openAgentHome(agentID: String) {
        openLink(BighelpShortcutLinks.agentHome(agentID))
    }

    func open(_ destination: BighelpShortcutDestination) {
        openLink(destination.url)
    }

    // MARK: Chats

    /// The agent's most recent chat, or a new one when it has none.
    func continueLastChat(agentID: String?) async throws -> BighelpShortcutContinueResult {
        let workspace = try await liveWorkspace()
        let known = agentID.flatMap { id in workspace.agents.profiles.contains { $0.id == id } ? id : nil }
        let agent = try resolveAgent(explicitID: known, in: workspace)
        if !workspace.catalog.hasLoadedState { try? await workspace.catalog.load() }
        // The same chat the agent's home opens.
        if let latest = workspace.catalog.recentSummaries(includeCronSessions: false)
            .first(where: { $0.kind == .direct && $0.agentIDs.first == agent.id }) {
            openLink(BighelpShortcutLinks.chat(latest.id))
            return BighelpShortcutContinueResult(sessionID: latest.id, agentName: agent.name, isNew: false)
        }
        let (_, opened) = try await openChat(agentID: agent.id)
        return BighelpShortcutContinueResult(sessionID: opened.sessionID, agentName: opened.agentName, isNew: true)
    }

    func availableGroupChats() async throws -> [BighelpShortcutGroupChat] {
        let workspace = try await liveWorkspace()
        return await groupChats(in: workspace)
    }

    func openGroupChat(id: String) async throws -> BighelpShortcutGroupChat {
        let workspace = try await liveWorkspace()
        guard let group = await groupChats(in: workspace).first(where: { $0.id == id }) else {
            throw BighelpShortcutServiceError.groupChatUnavailable
        }
        openLink(group.hostedRoomID.map(BighelpShortcutLinks.group) ?? BighelpShortcutLinks.chat(group.id))
        return group
    }

    /// Group chats saved with the chats, plus the host's own rooms, as the
    /// chat list shows them.
    private func groupChats(in workspace: BighelpShortcutWorkspace) async -> [BighelpShortcutGroupChat] {
        if !workspace.catalog.hasLoadedState { try? await workspace.catalog.load() }
        if let rooms = workspace.rooms, rooms.catalogState != .loaded || rooms.isCatalogStale {
            await rooms.refreshNativeRoomCatalog()
        }
        let saved = workspace.catalog.presentedRecords.filter { $0.kind == .botMode && !$0.isSubagentSession }
        let records = HostedRoomSessionProjection.records(
            catalogRecords: saved, hostedRooms: workspace.rooms?.catalogRooms ?? []
        ).filter { $0.kind == .botMode }
        let names = Dictionary(workspace.agents.profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return records
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { record -> BighelpShortcutGroupChat? in
                guard seen.insert(record.id).inserted else { return nil }
                return BighelpShortcutGroupChat(
                    id: record.id,
                    name: record.title.isEmpty ? "Group chat" : record.title,
                    memberNames: record.agentIDs.compactMap { names[$0] },
                    hostedRoomID: record.summary.hostedRoomID
                )
            }
            .prefix(Self.listLimit)
            .map { $0 }
    }

    // MARK: Scheduled tasks

    func availableScheduledTasks() async throws -> [BighelpShortcutScheduledTask] {
        let workspace = try await liveWorkspace()
        let store = try await loadedScheduledTasks(in: workspace)
        return store.tasks.prefix(Self.listLimit).map { scheduledTask($0, in: workspace) }
    }

    /// Runs a scheduled task now, the same as Run now on its page.
    func runScheduledTask(id: String) async throws -> BighelpShortcutScheduledTask {
        try await Self.holdingHostConnection(named: "bighelp Shortcut") {
            let workspace = try await liveWorkspace()
            let store = try await loadedScheduledTasks(in: workspace)
            guard let task = store.tasks.first(where: {
                BighelpShortcutScheduledTask.entityID(agentID: $0.agentID, jobID: $0.id) == id
            }) else { throw BighelpShortcutServiceError.scheduledTaskUnavailable }
            do {
                try await store.runNow(id: task.id, agentID: task.agentID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw BighelpShortcutServiceError.scheduledTaskFailed
            }
            return scheduledTask(store.task(id: task.id, agentID: task.agentID) ?? task, in: workspace)
        }
    }

    private func loadedScheduledTasks(in workspace: BighelpShortcutWorkspace) async throws -> ScheduledTasksStore {
        guard let store = workspace.featureStore.scheduledTasks else {
            throw BighelpShortcutServiceError.scheduledTaskUnavailable
        }
        await store.load()
        if case .failed = store.loadState { throw BighelpShortcutServiceError.connectionUnavailable }
        return store
    }

    private func scheduledTask(_ task: ScheduledTask, in workspace: BighelpShortcutWorkspace) -> BighelpShortcutScheduledTask {
        BighelpShortcutScheduledTask(
            id: BighelpShortcutScheduledTask.entityID(agentID: task.agentID, jobID: task.id),
            jobID: task.id,
            agentID: task.agentID,
            name: task.name,
            agentName: workspace.agents.profiles.first { $0.id == task.agentID }?.name ?? task.agentID,
            schedule: task.scheduleDescription,
            isPaused: task.isPaused
        )
    }

    // MARK: Feed, Ideas and Goals

    func boardItems(_ section: BighelpShortcutBoardSection, agentID: String?) async throws -> BighelpShortcutBoardResult {
        try await Self.holdingHostConnection(named: "bighelp Shortcut") {
            let workspace = try await liveWorkspace()
            let agent = try resolveAgent(explicitID: agentID, in: workspace)
            guard let client = hostServices.boards() else { throw BighelpShortcutServiceError.boardUnavailable }
            let items: [AgentBoardItem]
            do {
                items = try await client.items(agentID: agent.id)
            } catch WorkspaceClientError.unavailable {
                throw BighelpShortcutServiceError.boardUnavailable
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw BighelpShortcutServiceError.connectionUnavailable
            }
            return BighelpShortcutBoardResult(agentName: agent.name, section: section,
                                              lines: BighelpShortcutBoardResult.lines(items, section: section))
        }
    }

    // MARK: Kanban

    /// A new card in Later, which no agent picks up by itself, on the board
    /// Kanban last showed. The same path as New card in the app.
    func addKanbanTask(title: String, notes: String, assigneeID: String?) async throws -> BighelpShortcutKanbanResult {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw BighelpShortcutServiceError.emptyTitle }
        let notes = String(notes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8_000))
        return try await Self.holdingHostConnection(named: "bighelp Shortcut") {
            let workspace = try await liveWorkspace()
            if let assigneeID, !workspace.agents.profiles.contains(where: { $0.id == assigneeID }) {
                throw BighelpShortcutServiceError.agentUnavailable
            }
            guard let service = hostServices.kanban() else { throw BighelpShortcutServiceError.kanbanUnavailable }
            let board = KanbanBoardModel(service: service, agents: [], defaults: kanbanDefaults, publishWidget: { _ in })
            await board.start()
            switch board.phase {
            case .unavailable: throw BighelpShortcutServiceError.kanbanUnavailable
            case .failed: throw BighelpShortcutServiceError.kanbanFailed
            case .loading, .ready: break
            }
            guard let name = board.snapshot?.board.name else { throw BighelpShortcutServiceError.kanbanNoBoard }
            let added = await board.create(title: String(title.prefix(200)), details: notes, lane: .later,
                                           assignee: assigneeID)
            guard added else { throw BighelpShortcutServiceError.kanbanFailed }
            return BighelpShortcutKanbanResult(title: String(title.prefix(200)), boardName: name)
        }
    }

    // MARK: Host status

    /// A few plain lines about the computer. Never keys, tokens or paths.
    func hostStatus() async -> String {
        guard let hostName = hostServices.hostName()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hostName.isEmpty else { return "No computer is set up in bighelp yet." }
        let name = String(hostName.prefix(80))
        let workspace: BighelpShortcutWorkspace
        do {
            workspace = try await liveWorkspace()
        } catch {
            return "bighelp can't reach \(name) right now."
        }
        if !workspace.catalog.hasLoadedState { try? await workspace.catalog.load() }
        let agents = workspace.agents.profiles.count
        let working = workspace.catalog.recentSummaries(includeCronSessions: true).filter { summary in
            summary.isActive || workspace.featureStore.preparedChatModel(id: summary.id)?.isSending == true
        }.count
        let workingLine = switch working {
        case 0: "Nothing is working right now."
        case 1: "1 chat working right now."
        default: "\(working) chats working right now."
        }
        var lines = ["Connected to \(name).", agents == 1 ? "1 agent." : "\(agents) agents.", workingLine]
        if let version = Self.plainVersion(await hostServices.hermesVersion()) { lines.append("Hermes \(version).") }
        return lines.joined(separator: "\n")
    }

    /// Only something shaped like "0.21.4" reaches the summary.
    private static func plainVersion(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              (1...32).contains(value.count), value.first?.isNumber == true,
              value.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isLetter || ".-+".contains($0)) }) else { return nil }
        return value
    }
}
