import Foundation

enum ChatTaskStatus: String, Codable, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case cancelled

    var isTerminal: Bool {
        self == .completed || self == .cancelled
    }
}

struct ChatTaskItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let content: String
    let status: ChatTaskStatus
}

struct ChatTaskDrawerState: Equatable, Sendable {
    let turnID: String
    let items: [ChatTaskItem]

    var completedCount: Int {
        items.count { $0.status == .completed }
    }

    /// Matches Hermes Desktop progress: cancelled work is visible in the
    /// expanded list, but it is not counted as completed or outstanding.
    var totalCount: Int {
        items.count { $0.status != .cancelled }
    }

    var isTerminal: Bool {
        !items.isEmpty && items.allSatisfy { $0.status.isTerminal }
    }
}

/// The durable, full todo authority for one transcript owner. An empty `todos`
/// array is an intentional tombstone; absence of this value is not empty state.
struct SessionTodoSnapshot: Codable, Equatable, Sendable {
    /// Stock Hermes revisions belong to one in-memory TodoStore and can restart
    /// on a later message. This coordinate is authored only from the validated,
    /// ordered native event stream and survives local persistence.
    struct NativeObservation: Codable, Equatable, Sendable {
        let epoch: String
        let generation: Int
        let turnSequence: Int
        let eventSequence: Int
    }

    let sessionID: String
    let revision: Int
    let todos: [ChatTaskItem]
    let updatedAt: Int
    let nativeObservation: NativeObservation?

    init(
        sessionID: String,
        revision: Int,
        todos: [ChatTaskItem],
        updatedAt: Int,
        nativeObservation: NativeObservation? = nil
    ) {
        self.sessionID = sessionID
        self.revision = revision
        self.todos = todos
        self.updatedAt = updatedAt
        self.nativeObservation = nativeObservation
    }

    var isValid: Bool {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 4_096,
              revision >= 0, updatedAt > 0, todos.count <= 256,
              Set(todos.map(\.id)).count == todos.count else { return false }
        if let observation = nativeObservation {
            guard !observation.epoch.isEmpty, observation.epoch.utf8.count <= 4_096,
                  observation.generation > 0,
                  observation.turnSequence >= 0,
                  observation.eventSequence > 0,
                  observation.turnSequence <= observation.eventSequence else { return false }
        }
        return todos.allSatisfy { item in
            // TodoStore applies Python str.strip() to IDs before publishing.
            // Accept the remaining opaque literal at any length, including
            // internal whitespace, but reject values the producer normalizes.
            guard let first = item.id.unicodeScalars.first,
                  let last = item.id.unicodeScalars.last,
                  !first.properties.isWhitespace,
                  !last.properties.isWhitespace else { return false }
            return !item.content.isEmpty && item.content.count <= 4_000
                && !item.content.unicodeScalars.contains {
                    CharacterSet.controlCharacters.contains($0) && $0.value != 9 && $0.value != 10
                }
        }
    }

    /// Native event provenance outranks unsequenced replay/catalog state. Within
    /// one epoch, a later message-start coordinate begins a new revision domain;
    /// within one turn, only a larger revision advances. Different epochs are
    /// accepted only through the client that validated and installed that epoch.
    /// Without native provenance, preserve the legacy strict-revision contract.
    func supersedes(_ current: SessionTodoSnapshot?) -> Bool {
        guard isValid else { return false }
        guard let current else { return true }
        guard sessionID.utf8.elementsEqual(current.sessionID.utf8) else { return false }
        guard current.isValid else { return true }
        switch (nativeObservation, current.nativeObservation) {
        case let (.some(incoming), .some(retained)):
            if incoming.generation != retained.generation {
                return incoming.generation > retained.generation
            }
            guard incoming.epoch.utf8.elementsEqual(retained.epoch.utf8) else { return false }
            if incoming.turnSequence != retained.turnSequence {
                return incoming.turnSequence > retained.turnSequence
            }
            return revision > current.revision
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return revision > current.revision
        }
    }

    /// Strict decoder for canonical native snapshots. A nonempty array with any
    /// invalid row is malformed, not an authoritative empty (or partial) list.
    static func canonical(
        sessionID: String,
        revision: Int,
        values: [BighelpJSONValue],
        updatedAt: Int,
        nativeObservation: NativeObservation? = nil
    ) -> SessionTodoSnapshot? {
        guard values.count <= 256 else { return nil }
        var items: [ChatTaskItem] = []
        var ids: Set<String> = []
        for value in values {
            guard let row = value.object,
                  let id = row["id"]?.string,
                  let content = row["content"]?.string,
                  let rawStatus = row["status"]?.string,
                  let status = ChatTaskStatus(rawValue: rawStatus),
                  ids.insert(id).inserted else { return nil }
            items.append(ChatTaskItem(id: id, content: content, status: status))
        }
        let snapshot = SessionTodoSnapshot(
            sessionID: sessionID,
            revision: revision,
            todos: items,
            updatedAt: updatedAt,
            nativeObservation: nativeObservation
        )
        return snapshot.isValid ? snapshot : nil
    }

    /// Stock Hermes attaches this exact full-state object to `session.activate`.
    /// Missing `todo_state` remains unsupported/unknown; a present empty list at
    /// revision one or later is an authoritative clear.
    static func native(
        sessionID: String,
        state: BighelpJSONValue,
        observedAt: Int? = nil,
        nativeObservation: NativeObservation? = nil
    ) -> SessionTodoSnapshot? {
        guard let object = state.object,
              let revision = object["revision"]?.integer,
              revision >= 0,
              let values = object["todos"]?.array,
              !values.isEmpty || revision > 0 else { return nil }
        return canonical(
            sessionID: sessionID,
            revision: revision,
            values: values,
            updatedAt: observedAt.flatMap { $0 > 0 ? $0 : nil } ?? max(1, revision),
            nativeObservation: nativeObservation
        )
    }

    var taskDrawer: ChatTaskDrawerState? {
        todos.isEmpty ? nil : ChatTaskDrawerState(
            turnID: "session-todos-\(revision)", items: todos
        )
    }

    func routed(to sessionID: String) -> SessionTodoSnapshot {
        SessionTodoSnapshot(
            sessionID: sessionID,
            revision: revision,
            todos: todos,
            updatedAt: updatedAt,
            nativeObservation: nativeObservation
        )
    }
}

struct SessionSubagentSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let sessionID: String
    let parentID: String?
    let role: String
    let goal: String
    let startedAt: Int
}

/// A live native Hermes subagent observation. Hermes can emit the stable
/// subagent identity before the child session exists (or before it is included
/// in a `subagent.list` response), so child navigation remains optional.
struct NativeSubagentRailItem: Identifiable, Equatable, Sendable {
    let id: String
    let childSessionID: String?
    let parentID: String?
    let goal: String
    let lifecycle: ChatActivityLifecycle
    let status: String?
    let model: String?
    let toolCount: Int?
    let startedAt: Int?

    var canNavigate: Bool {
        guard let childSessionID else { return false }
        return !childSessionID.isEmpty
    }

    func merging(_ previous: NativeSubagentRailItem?) -> NativeSubagentRailItem {
        guard let previous else { return self }
        return NativeSubagentRailItem(
            id: id,
            childSessionID: childSessionID ?? previous.childSessionID,
            parentID: parentID ?? previous.parentID,
            goal: goal.isEmpty || goal == "Subagent task" ? previous.goal : goal,
            lifecycle: lifecycle,
            status: status ?? previous.status,
            model: model ?? previous.model,
            toolCount: toolCount ?? previous.toolCount,
            startedAt: startedAt ?? previous.startedAt
        )
    }
}

struct SessionSubagentRosterSnapshot: Codable, Equatable, Sendable {
    let sessionID: String
    let subagents: [SessionSubagentSnapshot]
    let updatedAt: Int

    var isValid: Bool {
        !sessionID.isEmpty && sessionID.utf8.count <= 4_096
            && updatedAt > 0 && subagents.count <= 256
            && Set(subagents.map(\.id)).count == subagents.count
            && subagents.allSatisfy {
                !$0.id.isEmpty && !$0.sessionID.isEmpty
                    && $0.id.utf8.count <= 4_096 && $0.sessionID.utf8.count <= 4_096
                    && $0.startedAt > 0 && !$0.role.isEmpty && !$0.goal.isEmpty
            }
    }

    func supersedes(_ current: SessionSubagentRosterSnapshot?) -> Bool {
        isValid && (current.map {
            sessionID.utf8.elementsEqual($0.sessionID.utf8) && updatedAt > $0.updatedAt
        } ?? true)
    }

    func routed(to sessionID: String) -> SessionSubagentRosterSnapshot {
        SessionSubagentRosterSnapshot(
            sessionID: sessionID,
            subagents: subagents,
            updatedAt: updatedAt
        )
    }
}

enum ChatGoalLifecycle: String, Equatable, Sendable {
    case active
    case paused
}

struct ChatGoalRailState: Equatable, Sendable {
    let summary: String
    let lifecycle: ChatGoalLifecycle
}

/// An authenticated projection of Hermes' persisted standing goal, not a turn
/// result or an assistant claim. Keep terminal snapshots as tombstones so a
/// delayed active snapshot cannot resurrect a completed goal after reopening.
struct SessionGoalSnapshot: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case active, paused, done, cleared, none
    }

    let sessionID: String
    let storedSessionID: String
    let status: Status
    let summary: String?
    /// Host observation time in milliseconds, strictly increasing per route.
    let updatedAt: Int

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case storedSessionID = "storedSessionId"
        case status, summary, updatedAt
    }

    var isValid: Bool {
        guard !sessionID.isEmpty, !storedSessionID.isEmpty, updatedAt > 0 else { return false }
        switch status {
        case .active, .paused:
            guard let summary else { return false }
            return !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && summary.utf8.count <= 131_072
                && !summary.unicodeScalars.contains(where: Self.isUnsupportedGoalControl)
        case .done, .cleared, .none:
            return summary == nil
        }
    }

    private static func isUnsupportedGoalControl(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar)
            && scalar != "\n" && scalar != "\r" && scalar != "\t"
    }

    var railState: ChatGoalRailState? {
        guard isValid, let summary else { return nil }
        switch status {
        case .active: return ChatGoalRailState(summary: summary, lifecycle: .active)
        case .paused: return ChatGoalRailState(summary: summary, lifecycle: .paused)
        case .done, .cleared, .none: return nil
        }
    }

    func routed(to sessionID: String) -> SessionGoalSnapshot {
        SessionGoalSnapshot(
            sessionID: sessionID, storedSessionID: storedSessionID,
            status: status, summary: summary, updatedAt: updatedAt
        )
    }

    /// Use this same rule in the durable session catalog before writing. Equal
    /// timestamps are duplicates, never permission to replace a tombstone.
    func supersedes(_ current: SessionGoalSnapshot?) -> Bool {
        isValid && (current.map {
            sessionID == $0.sessionID && storedSessionID == $0.storedSessionID
                && updatedAt > $0.updatedAt
        } ?? true)
    }
}

/// Command preview only. Never restore a live goal from transcript history:
/// commands can fail, history can be partial, and completion is host-owned.
enum ChatGoalProjection {
    static func applying(
        _ message: String,
        to current: ChatGoalRailState?
    ) -> ChatGoalRailState? {
        guard message.hasPrefix("/goal ") else { return current }
        let argument = String(message.dropFirst("/goal ".count))
        guard !argument.isEmpty,
              argument == argument.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return current }
        let lower = argument.lowercased()

        switch lower {
        case "clear", "stop", "done":
            return nil
        case "pause":
            guard let current else { return nil }
            return ChatGoalRailState(summary: current.summary, lifecycle: .paused)
        case "resume":
            guard let current else { return nil }
            return ChatGoalRailState(summary: current.summary, lifecycle: .active)
        case "status", "show", "wait", "unwait", "gate":
            return current
        default:
            if lower.hasPrefix("wait ") || lower.hasPrefix("gate ") {
                return current
            }
            let summary = lower.hasPrefix("draft ")
                ? String(argument.dropFirst("draft ".count))
                : argument
            guard !summary.isEmpty else { return current }
            return ChatGoalRailState(
                summary: String(summary.prefix(2_000)),
                lifecycle: .active
            )
        }
    }
}

struct ProjectChangesRailSummary: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case loading
        case clean
        case dirty
        case failed
        case unavailable
    }

    let state: State
    let fileCount: Int
    let insertions: Int
    let deletions: Int
    let workspaceName: String?
    let branch: String?
    let isRefreshing: Bool

    init(
        state: State = .dirty,
        fileCount: Int,
        insertions: Int,
        deletions: Int,
        workspaceName: String? = nil,
        branch: String? = nil,
        isRefreshing: Bool = false
    ) {
        self.state = state
        self.fileCount = fileCount
        self.insertions = insertions
        self.deletions = deletions
        self.workspaceName = workspaceName
        self.branch = branch
        self.isRefreshing = isRefreshing
    }
}

enum ProjectChangesRailPresentation {
    static func visibleLabels(for summary: ProjectChangesRailSummary) -> [String] {
        switch summary.state {
        case .loading:
            ["Loading changes"]
        case .clean:
            ["Clean"]
        case .failed:
            ["Changes unavailable · Retry"]
        case .unavailable:
            ["N/A"]
        case .dirty:
            [fileCountLabel(summary.fileCount), "+\(summary.insertions)", "−\(summary.deletions)"]
        }
    }

    static func accessibilityLabel(for summary: ProjectChangesRailSummary) -> String {
        switch summary.state {
        case .loading:
            "Project changes, loading"
        case .clean:
            "Project clean"
        case .failed:
            "Project changes unavailable, retry"
        case .unavailable:
            "Project changes, not available"
        case .dirty:
            "Project changes, \(fileCountLabel(summary.fileCount)), "
                + "\(summary.insertions) additions, \(summary.deletions) deletions"
        }
    }

    private static func fileCountLabel(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }
}

enum SessionStatusRailKind: String, Equatable, Sendable {
    case goal
    /// Subagents and background commands: what the agent runs beside, or after, its turn.
    case background
    case tasks
}

struct SessionStatusRailItem: Identifiable, Equatable, Sendable {
    let kind: SessionStatusRailKind
    var id: SessionStatusRailKind { kind }
}

enum SessionStatusRailPresentation {
    static let showsScrollIndicators = false

    static func items(
        goal: ChatGoalRailState?,
        subagents: [SessionSubagentSnapshot],
        nativeSubagents: [NativeSubagentRailItem] = [],
        runningCommands: Int = 0,
        tasks: ChatTaskDrawerState?
    ) -> [SessionStatusRailItem] {
        var result: [SessionStatusRailItem] = []
        if goal != nil {
            result.append(SessionStatusRailItem(kind: .goal))
        }
        if !subagents.isEmpty || !nativeSubagents.isEmpty || runningCommands > 0 {
            result.append(SessionStatusRailItem(kind: .background))
        }
        if tasks != nil {
            result.append(SessionStatusRailItem(kind: .tasks))
        }
        return result
    }
}

/// Projects legacy todo tool lifecycle into the composer task drawer. Running
/// arguments may be a partial merge; successful legacy results can seed visible
/// rows, while revisioned `SessionTodoSnapshot` remains the clearing authority.
enum ChatTodoProjection {
    static func applying(
        _ event: ChatActivityEvent,
        to current: ChatTaskDrawerState?
    ) -> ChatTaskDrawerState? {
        guard event.kind == .tool,
              event.toolName == "todo" || event.toolName == "todo_list"
        else { return current }

        if event.lifecycle == .succeeded,
           let payload = payload(from: event.result) {
            let items = payload.patches.compactMap(completeItem)
            // Canonical revisioned snapshots own clearing. A legacy tool result
            // may still present valid rows, but missing/malformed/all-invalid
            // data must not erase a newer retained drawer.
            guard !items.isEmpty else { return current }
            return ChatTaskDrawerState(turnID: event.turnID, items: items)
        }

        guard event.lifecycle == .running,
              let payload = payload(from: event.arguments)
        else { return current }

        if payload.merge, current?.turnID == event.turnID, let current {
            var items = current.items
            for patch in payload.patches {
                if let index = items.firstIndex(where: { $0.id == patch.id }) {
                    let existing = items[index]
                    items[index] = ChatTaskItem(
                        id: existing.id,
                        content: patch.content ?? existing.content,
                        status: patch.status ?? existing.status
                    )
                } else if let item = completeItem(patch) {
                    items.append(item)
                }
            }
            return items.isEmpty ? current : ChatTaskDrawerState(turnID: event.turnID, items: items)
        }

        let items = payload.patches.compactMap(completeItem)
        return items.isEmpty ? current : ChatTaskDrawerState(turnID: event.turnID, items: items)
    }

    private struct Patch {
        let id: String
        let content: String?
        let status: ChatTaskStatus?
    }

    private struct Payload {
        let patches: [Patch]
        let merge: Bool
    }

    private static func payload(from text: String?) -> Payload? {
        guard let object = jsonObject(from: text, depth: 0),
              let values = object["todos"] as? [Any]
        else { return nil }
        guard values.count <= 256 else { return nil }
        let patches = values.compactMap { value -> Patch? in
            guard let value = value as? [String: Any] else { return nil }
            let id = (value["id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !id.isEmpty, id.count <= 256 else { return nil }
            let content = (value["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedContent = content.flatMap { value in
                value.isEmpty ? nil : String(value.prefix(4_000))
            }
            let status = (value["status"] as? String).flatMap(ChatTaskStatus.init(rawValue:))
            return Patch(id: id, content: normalizedContent, status: status)
        }
        guard values.isEmpty || !patches.isEmpty else { return nil }
        return Payload(patches: patches, merge: object["merge"] as? Bool == true)
    }

    private static func completeItem(_ patch: Patch) -> ChatTaskItem? {
        guard let content = patch.content, let status = patch.status else { return nil }
        return ChatTaskItem(id: patch.id, content: content, status: status)
    }

    private static func jsonObject(from text: String?, depth: Int) -> [String: Any]? {
        guard depth <= 2,
              let text,
              let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        if let object = value as? [String: Any] { return object }
        if let nested = value as? String {
            return jsonObject(from: nested, depth: depth + 1)
        }
        return nil
    }
}
