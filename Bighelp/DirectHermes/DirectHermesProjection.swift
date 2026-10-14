import Foundation

enum DirectHermesSideTaskKind: String, Equatable, Sendable {
    case background = "background.complete"
    case btw = "btw.complete"
}

struct DirectHermesSideTaskAcceptance: Equatable, Sendable {
    let kind: DirectHermesSideTaskKind
    let taskID: String
    let prompt: String
}

struct DirectHermesSideTaskResult: Equatable, Sendable {
    let kind: DirectHermesSideTaskKind
    let taskID: String
    let text: String
    let question: String?

    init(event: DirectHermesEvent) throws {
        guard let kind = DirectHermesSideTaskKind(rawValue: event.type),
              Set(event.payload.keys).isSubset(of: ["task_id", "text", "question"]),
              let taskID = event.payload["task_id"]?.string,
              taskID.utf8.count <= 4_096,
              let text = event.payload["text"]?.string else {
            throw DirectHermesError.invalidResponse
        }
        if let question = event.payload["question"], question != .null, question.string == nil {
            throw DirectHermesError.invalidResponse
        }
        self.kind = kind
        self.taskID = taskID
        self.text = text
        question = event.payload["question"]?.string
    }
}

struct DirectHermesReviewSummary: Equatable, Sendable {
    let text: String

    init(event: DirectHermesEvent) throws {
        guard event.type == "review.summary", Set(event.payload.keys) == ["text"],
              let text = event.payload["text"]?.string else { throw DirectHermesError.invalidResponse }
        self.text = text
    }
}

struct DirectHermesNotice: Equatable, Sendable {
    let message: String

    init(event: DirectHermesEvent) throws {
        guard event.type == "notice", Set(event.payload.keys) == ["message"],
              let message = event.payload["message"]?.string else { throw DirectHermesError.invalidResponse }
        self.message = message
    }
}

struct DirectHermesStatusUpdate: Equatable, Sendable {
    let kind: String
    let text: String

    init(event: DirectHermesEvent) throws {
        guard event.type == "status.update", Set(event.payload.keys) == ["kind", "text"],
              let kind = event.payload["kind"]?.string,
              let text = event.payload["text"]?.string else { throw DirectHermesError.invalidResponse }
        self.kind = kind
        self.text = text
    }
}

struct DirectHermesThinkingDelta: Equatable, Sendable {
    let text: String
    let rendered: String?
    let verbose: Bool?

    init(event: DirectHermesEvent) throws {
        guard event.type == "thinking.delta",
              Set(event.payload.keys).isSubset(of: ["text", "rendered", "verbose"]),
              event.payload["text"] != nil,
              let text = event.payload["text"]?.string else { throw DirectHermesError.invalidResponse }
        if let rendered = event.payload["rendered"], rendered != .null, rendered.string == nil {
            throw DirectHermesError.invalidResponse
        }
        if let verbose = event.payload["verbose"], verbose != .null, verbose.boolean == nil {
            throw DirectHermesError.invalidResponse
        }
        self.text = text
        rendered = event.payload["rendered"]?.string
        verbose = event.payload["verbose"]?.boolean
    }
}

struct DirectHermesToolGenerating: Equatable, Sendable {
    let name: String

    init(event: DirectHermesEvent) throws {
        guard event.type == "tool.generating", Set(event.payload.keys) == ["name"],
              let name = event.payload["name"]?.string else {
            throw DirectHermesError.invalidResponse
        }
        self.name = name
    }
}

struct DirectHermesToolOutputRisk: Equatable, Sendable {
    let toolID: String
    let name: String
    let risk: String
    let findings: [String]
    let redacted: Bool

    init(event: DirectHermesEvent) throws {
        guard event.type == "tool.output_risk",
              Set(event.payload.keys) == ["tool_id", "name", "risk", "findings", "redacted"],
              let toolID = event.payload["tool_id"]?.string,
              let name = event.payload["name"]?.string,
              let risk = event.payload["risk"]?.string,
              let values = event.payload["findings"]?.array,
              values.count <= 1_024,
              let redacted = event.payload["redacted"]?.boolean else {
            throw DirectHermesError.invalidResponse
        }
        let findings = values.compactMap(\.string)
        guard findings.count == values.count else { throw DirectHermesError.invalidResponse }
        self.toolID = toolID
        self.name = name
        self.risk = risk
        self.findings = findings
        self.redacted = redacted
    }

    var summary: String {
        let riskLabel = risk.isEmpty ? "Unclassified" : risk.capitalized
        let toolLabel = name.isEmpty ? "tool" : name
        var parts = ["\(riskLabel) risk in \(toolLabel) output"]
        if !findings.isEmpty { parts.append(findings.count == 1 ? "1 finding" : "\(findings.count) findings") }
        if redacted { parts.append("sensitive text redacted") }
        return parts.joined(separator: " · ")
    }
}

struct DirectHermesMessageReaction: Equatable, Sendable {
    struct Reaction: Equatable, Sendable {
        let emoji: String
        let author: String
        let at: Double?
        let seen: Bool?
    }

    let rowID: Int
    let role: String
    let reactions: [Reaction]

    init(event: DirectHermesEvent) throws {
        guard event.type == "message.reaction",
              Set(event.payload.keys) == ["row_id", "reactions", "role"],
              let rowID = event.payload["row_id"]?.integer, rowID >= 0,
              let role = event.payload["role"]?.string,
              let values = event.payload["reactions"]?.array, values.count <= 1_024 else {
            throw DirectHermesError.invalidResponse
        }
        var reactions: [Reaction] = []
        for value in values {
            guard let object = value.object,
                  let emoji = object["emoji"]?.string, !emoji.isEmpty,
                  let author = object["author"]?.string,
                  ["user", "agent"].contains(author) else {
                throw DirectHermesError.invalidResponse
            }
            if let at = object["at"], at != .null, at.number == nil { throw DirectHermesError.invalidResponse }
            if let seen = object["seen"], seen != .null, seen.boolean == nil { throw DirectHermesError.invalidResponse }
            reactions.append(Reaction(emoji: emoji, author: author,
                at: object["at"]?.number, seen: object["seen"]?.boolean))
        }
        self.rowID = rowID
        self.role = role
        self.reactions = reactions
    }
}

struct DirectHermesAffectionReaction: Equatable, Sendable {
    let kind: String

    init(event: DirectHermesEvent) throws {
        guard event.type == "reaction", Set(event.payload.keys) == ["kind"],
              let kind = event.payload["kind"]?.string else {
            throw DirectHermesError.invalidResponse
        }
        self.kind = kind
    }
}

struct DirectHermesSessionReclaim: Equatable, Sendable {
    let runtimeSessionID: String
    let storedSessionID: String
    let reason: String

    init(event: DirectHermesEvent) throws {
        guard event.type == "session.reclaimed",
              Set(event.payload.keys) == ["session_id", "stored_session_id", "reason"],
              let runtimeSessionID = event.payload["session_id"]?.string,
              let storedSessionID = event.payload["stored_session_id"]?.string,
              let reason = event.payload["reason"]?.string else { throw DirectHermesError.invalidResponse }
        self.runtimeSessionID = runtimeSessionID
        self.storedSessionID = storedSessionID
        self.reason = reason
    }
}

/// A stock gateway has runtime IDs, durable row IDs and event sequence numbers;
/// none of those coordinates is interchangeable with a bighelp Link message ID.
struct DirectHermesProjection {
    let conversationID: String
    let profile: String
    var storedID: String
    var epoch: String
    private(set) var lastSequence = 0
    private(set) var items: [TimelineItem] = []
    private(set) var activities: [ChatActivityEvent] = []
    private(set) var todoSnapshot: SessionTodoSnapshot?
    private(set) var sideTaskResults: [DirectHermesSideTaskResult] = []
    private(set) var reviewSummaries: [DirectHermesReviewSummary] = []
    private(set) var notices: [DirectHermesNotice] = []
    private(set) var latestStatusUpdate: DirectHermesStatusUpdate?
    private(set) var toolOutputRisks: [DirectHermesToolOutputRisk] = []
    private(set) var messageReactions: [Int: DirectHermesMessageReaction] = [:]
    private(set) var latestAffectionReaction: DirectHermesAffectionReaction?
    private(set) var controlSnapshot: DirectHermesSessionControlSnapshot?
    private(set) var reclaim: DirectHermesSessionReclaim?
    private var sideTaskTurnIDs: [Data: String] = [:]
    private(set) var running = false
    private(set) var hasLiveEvents = false
    private(set) var turnID = "initial"
    /// The turn Hermes last reported failed (a final with `status: "error"`).
    private(set) var failedTurnID: String?
    private var segment = 0
    private var text = ""
    private var reasoning = ""
    private var reasoningSegment = 0
    private var reasoningSealed = false
    private var segmentID: String?
    private var segmentIndex: Int?
    private var activityIndex: Int?
    private(set) var lastTextLookupWorkCount = 0
    private var arrival = 0
    private var historyAliases: [String: String] = [:]
    private var snapshotTurnKey: String?
    private var todoAuthorityGeneration: Int
    private var todoTurnSequence = 0

    /// Retain the model's optimistic/queued rows in the same ordered ledger as
    /// native rows. Neither their text nor their IDs are submit nonces.
    mutating func retainVisible(items visible: [TimelineItem], activities events: [ChatActivityEvent]) {
        items = visible
        activities = events
        arrival = max(visible.compactMap(\.metadata.sourceOrder).max() ?? 0,
            events.compactMap(\.sourceOrder).max() ?? 0)
    }

    /// Enrich only the unchanged authenticated message row. Preserve newer
    /// duration and ordering metadata received while bytes were in flight.
    mutating func resolveMedia(_ resolved: ResolvedAgentAttachmentItem, replacing source: TimelineItem) -> TimelineItem? {
        // Bytes, or only new words: "couldn't load" in place of a host path.
        guard resolved.id == source.id, !resolved.attachments.isEmpty || source.content != .message(resolved.text),
              let index = items.firstIndex(where: { $0.id == source.id }),
              items[index].role == source.role, items[index].sender == source.sender,
              items[index].content == source.content, items[index].attachments == source.attachments else { return nil }
        let current = items[index]
        let enriched = TimelineItem(id: current.id, role: current.role, sender: current.sender,
            content: .message(resolved.text), metadata: current.metadata, attachments: resolved.attachments)
        items[index] = enriched
        return enriched
    }

    /// Adopt a display snapshot without assigning fabricated native identities
    /// to lossy history rows. Exact durable IDs win; a complete ordered tail can
    /// adopt row IDs by position/role, never by text equality. If the shapes differ
    /// (e.g. history coalesced live segments), preserve the richer accepted tail
    /// and expose the source snapshot as detail rather than duplicating bubbles.
    mutating func reconcileHistory(_ messages: [BighelpJSONValue]) {
        var history = DirectHermesProjection(conversationID: conversationID, profile: profile,
            storedID: storedID, epoch: epoch)
        history.seedHistory(messages)
        guard !items.isEmpty || !activities.isEmpty else {
            items = history.items
            activities = history.activities
            arrival = history.arrival
            for row in items { historyAliases[row.id] = row.id }
            for event in activities { historyAliases[event.eventID] = event.eventID }
            return
        }
        let known = Set(items.map(\.id))
        // Durable row IDs are profile-DB coordinates. Compression may rotate
        // storedID without changing those rows or the visible model's IDs.
        for row in history.items {
            guard let marker = row.id.range(of: ":row:", options: .backwards) else { continue }
            let suffix = String(row.id[marker.lowerBound...])
            if let old = historyAliases.first(where: { $0.key.hasSuffix(suffix) }) {
                historyAliases[row.id] = old.value
            } else if let retained = items.first(where: { $0.id.hasSuffix(suffix) }) {
                historyAliases[row.id] = retained.id
            }
        }
        let allRowsKnown = history.items.allSatisfy { known.contains(historyAliases[$0.id] ?? $0.id) }
        if allRowsKnown {
            // History's tool rows have no call ID. Preserve their positional
            // aliases only inside an unchanged, durably anchored transcript.
            for event in history.activities {
                guard let marker = event.eventID.range(of: ":position:", options: .backwards) else { continue }
                let suffix = String(event.eventID[marker.lowerBound...])
                if let old = historyAliases.first(where: { $0.key.hasSuffix(suffix) }) {
                    historyAliases[event.eventID] = old.value
                }
            }
        }
        let unseen = history.items.filter { !known.contains(historyAliases[$0.id] ?? $0.id) }
        let bound = Set(historyAliases.values)
        let local = items.filter { !bound.contains($0.id) }
        let knownEvents = Set(activities.map(\.eventID))
        let unseenTools = history.activities.filter {
            $0.kind == .tool && !knownEvents.contains(historyAliases[$0.eventID] ?? $0.eventID)
        }
        let localTools = activities.filter { $0.kind == .tool && $0.toolCallID != nil && !bound.contains($0.eventID) }
        let unseenReasoning = history.activities.filter {
            $0.kind == .reasoning && !knownEvents.contains(historyAliases[$0.eventID] ?? $0.eventID)
        }
        let localReasoning = activities.filter { $0.kind == .reasoning && !bound.contains($0.eventID) }
        if local.isEmpty && localTools.isEmpty && localReasoning.isEmpty {
            // No optimistic/live suffix competes with newly persisted history.
            // Append its actual rows in source order; never reorder retained IDs.
            let unseenIDs = Set(unseen.map(\.id))
            let newEvents = history.activities.filter {
                !knownEvents.contains(historyAliases[$0.eventID] ?? $0.eventID)
            }
            let orders = Set(unseen.compactMap(\.metadata.sourceOrder) + newEvents.compactMap(\.sourceOrder)).sorted()
            for order in orders {
                for row in history.items where unseenIDs.contains(row.id) && row.metadata.sourceOrder == order {
                    arrival += 1
                    items.append(row.ordered(arrival))
                    historyAliases[row.id] = row.id
                }
                for event in newEvents where event.sourceOrder == order {
                    arrival += 1
                    activities.append(event.ordered(arrival))
                    historyAliases[event.eventID] = event.eventID
                }
            }
        }
        let aligns = unseen.count == local.count && zip(unseen, local).allSatisfy { $0.role == $1.role }
            && unseenTools.count == localTools.count && unseenReasoning.count == localReasoning.count
            && zip(unseenTools, localTools).allSatisfy { $0.toolName == $1.toolName }
        if aligns {
            for (incoming, retained) in zip(unseen, local) { historyAliases[incoming.id] = retained.id }
            for (incoming, retained) in zip(unseenTools, localTools) {
                historyAliases[incoming.eventID] = retained.eventID
            }
            for (incoming, retained) in zip(unseenReasoning, localReasoning) {
                historyAliases[incoming.eventID] = retained.eventID
            }
        } else if (!local.isEmpty || !localTools.isEmpty || !localReasoning.isEmpty)
            && (!unseen.isEmpty || !unseenTools.isEmpty || !unseenReasoning.isEmpty) {
            retainSourceDetail(key: "history", title: "Recovered native history",
                detail: Self.jsonText(.array(messages)) ?? "",
                summary: "Saved source detail; the accepted live timeline is retained in its original order.")
        }
        for row in history.items {
            let id = historyAliases[row.id] ?? row.id
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            let old = items[index]
            // A positional alias preserves presentation identity, not exactly-
            // once admission. Keep locally shown human bytes (e.g. a slash
            // expansion) rather than rewriting them with a different source.
            if old.role == .human, old.id != row.id {
                // The local accepted row owns its identity and text, while the
                // persisted row owns the authoritative turn start. Preserve
                // attachments and all local content, but adopt that timestamp
                // so a completed live turn can use the real start/end pair.
                guard let timestamp = row.metadata.timestamp else { continue }
                items[index] = withMetadata(old, timestamp: timestamp)
                continue
            }
            // Adopt final source text in place without moving accepted rows.
            items[index] = item(id: old.id, text: {
                if case .message(let text) = row.content { return text }; return ""
            }(), human: old.role == .human, delivery: "Saved", order: old.metadata.sourceOrder ?? 0,
                timestamp: row.metadata.timestamp?.timeIntervalSince1970 ?? old.metadata.timestamp?.timeIntervalSince1970,
                turnDurationMilliseconds: row.metadata.turnDurationMilliseconds
                    ?? old.metadata.turnDurationMilliseconds)
        }
    }

    /// Fresh active bootstrap: use the complete current-turn replay for typed
    /// assistant/reasoning/tool segments, and only the snapshot's preceding
    /// history. Turn time + ordered roles identify the live suffix; repeated
    /// prompt strings are never a correlation key.
    mutating func seedLiveReplayHistory(_ snapshot: [String: BighelpJSONValue], epoch: String) -> Bool {
        let messages = snapshot["messages"]?.array ?? []
        let started = snapshot["turn_started_at"]?.number
        let currentUser = messages.firstIndex { value in
            guard value.object?["role"]?.string == "user",
                  let time = value.object?["timestamp"]?.number, let started else { return false }
            return time >= started
        }
        // Without a current-user boundary a timestamp-free tool/assistant tail
        // may already represent replayed output. Keep its source snapshot rather
        // than manufacturing a second copy of those rows.
        guard currentUser != nil || messages.isEmpty || messages.last?.object?["role"]?.string == "user" else {
            return false
        }
        if !self.epoch.utf8.elementsEqual(epoch.utf8) {
            installTodoEpoch(epoch)
        } else if todoAuthorityGeneration == 0 {
            todoAuthorityGeneration = 1
        }
        self.epoch = epoch
        lastSequence = 0
        running = false
        segmentID = nil
        text = ""
        reasoning = ""
        historyAliases = [:]
        seedHistory(currentUser.map { Array(messages.prefix($0 + 1)) } ?? messages)
        if currentUser == nil, let user = snapshot["inflight"]?.object?["user"]?.string, !user.isEmpty {
            // Timestamp-free legacy history may already contain the current
            // user. Keep that source in detail instead of guessing by text.
            let trailingUser = messages.last?.object?["role"]?.string == "user"
            if !trailingUser {
                arrival += 1
                items.append(item(id: "\(storedID):inflight-user:\(started ?? 0)", text: user,
                    human: true, delivery: "Received", order: arrival, timestamp: started))
            } else {
                retainSourceDetail(key: "bootstrap-input", title: "Native in-flight input",
                    detail: user, summary: "Input supplied by the native snapshot; history has no turn timestamp to bind another row.")
            }
        }
        for row in items { historyAliases[row.id] = row.id }
        for event in activities { historyAliases[event.eventID] = event.eventID }
        return true
    }

    mutating func resetCheckpoint() {
        lastSequence = 0
        running = false
        snapshotTurnKey = nil
    }

    mutating func retainSourceDetail(key: String, title: String, detail: String, summary: String) {
        let id = "\(conversationID):recovery:\(key)"
        let old = activities.first { $0.eventID == id }
        if old == nil { arrival += 1 }
        upsert(ChatActivityEvent(eventID: id, sessionID: conversationID, turnID: turnID,
            kind: .tool, lifecycle: .succeeded, title: title, summary: summary, detail: detail,
            occurredAt: 0, sourceOrder: old?.sourceOrder ?? arrival))
    }

    /// Cumulative inflight output isn't a delta, and may include reasoning or
    /// several sealed segments. Keep it as native source detail when retained
    /// structured output exists, or when no atomic replay boundary is available.
    mutating func seedSnapshot(_ snapshot: [String: BighelpJSONValue], epoch newEpoch: String) {
        let active = snapshot["running"]?.boolean ?? false
        let key = "\(newEpoch):\(snapshot["session_id"]?.string ?? conversationID):\(snapshot["turn_started_at"]?.number ?? 0)"
        let changedEpoch = epoch != newEpoch
        if changedEpoch { lastSequence = 0 }
        if changedEpoch {
            installTodoEpoch(newEpoch)
        }
        epoch = newEpoch
        if active && (!running || changedEpoch || (snapshotTurnKey != nil && snapshotTurnKey != key)) {
            snapshotTurnKey = key
            turnID = key
            text = ""
            reasoning = ""
            segment += 1
            segmentID = nil
        }
        running = active
        if let inflight = snapshot["inflight"]?.object {
            // This is explicitly a source snapshot, not a second user/assistant
            // row inferred by comparing identical prompt or assistant text.
            retainSourceDetail(key: "inflight", title: "Recovered live turn",
                detail: Self.jsonText(.object(inflight)) ?? "",
                summary: "Native cumulative snapshot; new output continues below. Existing live rows are preserved.")
        }
        if let queued = snapshot["queued"], queued.object != nil {
            retainSourceDetail(key: "queue", title: "Hermes accepted queue",
                detail: Self.jsonText(queued) ?? "", summary: "Accepted on Hermes; not a new local submission.")
        }
    }

    init(conversationID: String, profile: String, storedID: String, epoch: String) {
        self.conversationID = conversationID
        self.profile = profile
        self.storedID = storedID
        self.epoch = epoch
        todoAuthorityGeneration = epoch.isEmpty ? 0 : 1
    }

    struct Change {
        var items: [TimelineItem] = []
        var activities: [ChatActivityEvent] = []
        var todoSnapshot: SessionTodoSnapshot?
        var nativeSubagent: NativeSubagentRailItem?
        var sideTaskAcceptance: DirectHermesSideTaskAcceptance?
        var sideTaskResult: DirectHermesSideTaskResult?
        var reviewSummary: DirectHermesReviewSummary?
        var notice: DirectHermesNotice?
        var statusUpdate: DirectHermesStatusUpdate?
        var thinkingDelta: DirectHermesThinkingDelta?
        var toolGenerating: DirectHermesToolGenerating?
        var toolOutputRisk: DirectHermesToolOutputRisk?
        var messageReaction: DirectHermesMessageReaction?
        var affectionReaction: DirectHermesAffectionReaction?
        var controlSnapshot: DirectHermesSessionControlSnapshot?
        var reclaim: DirectHermesSessionReclaim?
        var terminal = false
        var terminalError: String?
        /// How the turn failed, from Hermes' failed final.
        var turnFailure: ChatTurnFailure?
        /// Hermes refused the turn before it started: the failed final is its only event.
        var failedBeforeStart = false
    }

    mutating func seedHistory(_ messages: [BighelpJSONValue]) {
        items = []
        activities = []
        arrival = 0
        var historyTurn = "history"
        for (index, value) in messages.enumerated() {
            guard let row = value.object, let role = row["role"]?.string else { continue }
            let id = row["row_id"]?.integer.map { "row:\($0)" } ?? "position:\(index)"
            let scopedID = "\(storedID):\(id)"
            let raw = row["text"]?.string ?? ""
            let body = role == "user" ? HermesUserMessageDisplay.text(raw) : raw
            if role == "user" { historyTurn = scopedID }
            if role == "tool" {
                arrival += 1
                // Stock session.history intentionally omits tool result and call ID.
                // Preserve its actual summary; never invent a durable tool identity.
                activities.append(ChatActivityEvent(eventID: scopedID,
                    sessionID: conversationID, turnID: historyTurn, kind: .tool,
                    lifecycle: .succeeded, title: row["name"]?.string ?? "Tool",
                    summary: row["context"]?.string, detail: nil, occurredAt: 0,
                    toolName: row["name"]?.string, arguments: Self.jsonText(row["args"]),
                    sourceOrder: arrival))
                continue
            }
            guard role == "user" || role == "assistant" else { continue }
            if role == "assistant",
               let detail = row["reasoning"]?.string ?? row["reasoning_content"]?.string,
               !detail.isEmpty {
                arrival += 1
                activities.append(ChatActivityEvent(eventID: scopedID + ":reasoning",
                    sessionID: conversationID, turnID: historyTurn, kind: .reasoning,
                    lifecycle: .succeeded, title: "Reasoning", summary: nil,
                    detail: detail, occurredAt: 0, sourceOrder: arrival))
            }
            if !body.isEmpty {
                arrival += 1
                items.append(item(id: scopedID, text: body, human: role == "user", delivery: "Saved",
                    order: arrival, timestamp: row["timestamp"]?.number,
                    turnDurationMilliseconds: Self.durationMilliseconds(row["turn_duration_ms"])))
            }
        }
    }

    mutating func acceptSideTask(_ acceptance: DirectHermesSideTaskAcceptance) -> Change {
        guard !sideTaskResults.contains(where: {
            $0.kind == acceptance.kind && Data($0.taskID.utf8) == Data(acceptance.taskID.utf8)
        }) else { return Change() }
        if sideTaskTurnIDs.count == 256, let first = sideTaskTurnIDs.keys.first {
            sideTaskTurnIDs[first] = nil
        }
        sideTaskTurnIDs[sideTaskIdentity(acceptance.kind, acceptance.taskID)] = turnID
        var change = Change()
        change.sideTaskAcceptance = acceptance
        change.activities = [publishActivity(key: sideTaskKey(acceptance.kind, acceptance.taskID),
            kind: .tool,
            title: acceptance.kind == .background ? "Background task" : "BTW question",
            detail: acceptance.prompt,
            payload: ["summary": .string("Accepted by Hermes")], terminal: false)]
        return change
    }

    mutating func accept(_ event: DirectHermesEvent) -> Change {
        if let sequence = event.sequence {
            guard sequence > lastSequence else { return Change() }
            lastSequence = sequence
        }
        if event.type.hasPrefix("message.") || event.type.hasPrefix("tool.") { hasLiveEvents = true }
        let p = event.payload
        let eventKey = "\(epoch):\(event.sequence.map(String.init) ?? UUID().uuidString)"
        var change = Change()
        switch event.type {
        case "message.start":
            running = true
            if let sequence = event.sequence {
                todoTurnSequence = sequence
                let empty = SessionTodoSnapshot(
                    sessionID: conversationID,
                    revision: 0,
                    todos: [],
                    updatedAt: sequence,
                    nativeObservation: .init(
                        epoch: epoch,
                        generation: todoAuthorityGeneration,
                        turnSequence: sequence,
                        eventSequence: sequence
                    )
                )
                if empty.supersedes(todoSnapshot) {
                    todoSnapshot = empty
                    change.todoSnapshot = empty
                }
            }
            snapshotTurnKey = nil
            turnID = eventKey
            text = ""
            reasoning = ""
            reasoningSegment = 0
            reasoningSealed = false
            segment = 0
            segmentID = nil
        case "message.delta":
            if p["text"]?.string?.isEmpty == false { change.activities += finishReasoning() }
            running = true
            text += p["text"]?.string ?? ""
            if !text.isEmpty { change.items = [publishText(text, eventKey: eventKey, complete: false)] }
        case "message.interim":
            change.activities += finishReasoning()
            let interim = p["text"]?.string ?? ""
            if !interim.isEmpty { change.items = [publishText(interim, eventKey: eventKey, complete: true)] }
            text = ""
            reasoning = ""
            segment += 1
            segmentID = nil
        case "message.complete":
            let failure = ChatTurnFailure(completePayload: p)
            if failure != nil, !running {
                // Hermes refuses some turns before message.start (it couldn't build
                // the agent). Its failed final is then a turn of its own, and its end;
                // it must not land in the previous turn's reply.
                turnID = eventKey
                text = ""
                reasoning = ""
                reasoningSegment = 0
                reasoningSealed = false
                segment = 0
                segmentID = nil
                change.terminal = true
                change.failedBeforeStart = true
            }
            if let failure {
                failedTurnID = turnID
                change.turnFailure = failure
            }
            change.activities += finishReasoning()
            let final = p["text"]?.string ?? text
            if !final.isEmpty { change.items = [publishText(final, eventKey: eventKey, complete: true)] }
            // A bare message.complete also comes from child mirrors. It is a
            // segment final, not a turn final. session.info.running=false is the
            // stock prompt_turn.py finally-bookend after goal/loop evaluation.
            if let finalReasoning = p["reasoning"]?.string, !finalReasoning.isEmpty {
                reasoning = finalReasoning
                change.activities = [publishActivity(key: "reasoning:\(reasoningSegment)", kind: .reasoning,
                    title: "Reasoning", detail: reasoning, payload: p, terminal: true)]
            }
            if let failure = p["error"]?.string { change.terminalError = failure }
        case "reasoning.delta":
            let value = p["text"]?.string ?? ""
            if reasoningSealed, !value.isEmpty {
                reasoningSegment += 1
                reasoningSealed = false
                reasoning = ""
            }
            reasoning += value
            if !reasoning.isEmpty {
                change.activities = [publishActivity(key: "reasoning:\(reasoningSegment)", kind: .reasoning,
                    title: "Reasoning", detail: reasoning, payload: p, terminal: false)]
            }
        case "reasoning.available":
            // Stock Hermes emits this from `_relay_thinking` with the assistant
            // message body as a progress preview. It is not a model reasoning
            // field and has no durable reasoning identity. The authoritative
            // reasoning producer is `reasoning.delta`; canonical history uses
            // `reasoning` / `reasoning_content` on the exact assistant row.
            break
        case "thinking.delta":
            // `thinking.delta` is the host's spinner/wait-status callback, not
            // assistant reasoning. Keep the typed status payload available to
            // the client without manufacturing a transcript activity row.
            guard let delta = try? DirectHermesThinkingDelta(event: event) else { break }
            change.thinkingDelta = delta
        case "background.complete", "btw.complete":
            guard let result = try? DirectHermesSideTaskResult(event: event) else { break }
            upsertSideTask(result)
            change.sideTaskResult = result
            let identity = sideTaskIdentity(result.kind, result.taskID)
            let acceptedTurnID = sideTaskTurnIDs.removeValue(forKey: identity)
            change.activities = [publishActivity(key: sideTaskKey(result.kind, result.taskID),
                kind: .tool,
                title: result.kind == .background ? "Background task" : "BTW question",
                detail: result.question ?? (result.text.isEmpty ? "Hermes returned no text for this side task." : nil),
                payload: ["summary": .string("Result received")], terminal: true,
                lifecycleOverride: .recorded,
                turnOverride: acceptedTurnID)]
            if !result.text.isEmpty { change.items = [publishSideTask(result)] }
        case "review.summary":
            guard let summary = try? DirectHermesReviewSummary(event: event) else { break }
            Self.appendBounded(summary, to: &reviewSummaries)
            change.reviewSummary = summary
            change.activities = [publishActivity(key: "review:\(eventKey)", kind: .tool,
                title: "Background review", detail: summary.text,
                payload: ["summary": .string("Background review finished")], terminal: true)]
        case "notice":
            guard let notice = try? DirectHermesNotice(event: event) else { break }
            Self.appendBounded(notice, to: &notices)
            change.notice = notice
            change.activities = [publishActivity(key: "notice:\(eventKey)", kind: .tool,
                title: "Hermes notice", detail: notice.message,
                payload: ["summary": .string(notice.message)], terminal: true,
                lifecycleOverride: .recorded)]
        case "status.update":
            guard let update = try? DirectHermesStatusUpdate(event: event) else { break }
            latestStatusUpdate = update
            change.statusUpdate = update
        case "tool.generating":
            // Name-only pre-announcement with no tool_id. A timeline row here can
            // never be joined to the tool.start/complete that follows, so it would
            // sit "running" forever beside the real call. Surface it as status only.
            guard let generating = try? DirectHermesToolGenerating(event: event) else { break }
            change.toolGenerating = generating
        case "tool.output_risk":
            guard let warning = try? DirectHermesToolOutputRisk(event: event) else { break }
            upsertToolRisk(warning)
            change.toolOutputRisk = warning
            let findings = warning.findings.isEmpty ? warning.summary : warning.findings.joined(separator: "\n")
            change.activities = [publishActivity(key: "tool-risk:\(warning.toolID):\(eventKey)", kind: .tool,
                title: "Safety warning · \(warning.name)", detail: findings,
                payload: ["summary": .string(warning.summary)], terminal: true,
                lifecycleOverride: .recorded)]
        case "message.reaction":
            guard let reaction = try? DirectHermesMessageReaction(event: event) else { break }
            messageReactions[reaction.rowID] = reaction
            change.messageReaction = reaction
        case "reaction":
            guard let reaction = try? DirectHermesAffectionReaction(event: event) else { break }
            latestAffectionReaction = reaction
            change.affectionReaction = reaction
        case "session.control.update":
            guard Set(p.keys) == ["control"], let object = p["control"]?.object,
                  let snapshot = try? DirectHermesSessionControlSnapshot(object: object) else { break }
            controlSnapshot = snapshot
            change.controlSnapshot = snapshot
        case "session.reclaimed":
            guard let value = try? DirectHermesSessionReclaim(event: event) else { break }
            reclaim = value
            running = false
            change.reclaim = value
            change.activities = [publishActivity(key: "reclaimed:\(eventKey)", kind: .tool,
                title: "Session reclaimed", detail: value.reason,
                payload: ["summary": .string("Hermes retired this live session. Reopen it before sending.")],
                terminal: true, lifecycleOverride: .cancelled)]
        case "todo.updated":
            acceptCanonicalTodoSnapshot(
                from: p,
                sequence: event.sequence,
                into: &change
            )
        case "tool.start", "tool.progress", "tool.complete":
            guard let toolID = p["tool_id"]?.string, !toolID.isEmpty else { break }
            if event.type == "tool.start" { change.activities += finishReasoning() }
            change.activities += [publishActivity(key: "tool:\(toolID)", kind: .tool,
                title: p["name"]?.string ?? "Tool", detail: p["context"]?.string,
                payload: p, terminal: event.type == "tool.complete", toolID: toolID)]
            if event.type == "tool.complete",
               Self.isTodoInvocation(name: p["name"]?.string, arguments: p["args"]) {
                acceptCanonicalTodoSnapshot(
                    from: p,
                    sequence: event.sequence,
                    into: &change
                )
            }
        case let type where type.hasPrefix("subagent."):
            // `subagent_id` is the stable delegation identity. Older emitters
            // may omit it while still supplying a real child session, which is
            // safe to use as the temporary event identity. Never manufacture
            // an ID for an event carrying neither coordinate.
            let childSessionID = Self.nonempty(p["child_session_id"]?.string)
            let subagentID = Self.nonempty(p["subagent_id"]?.string) ?? childSessionID
            guard let subagentID else { break }
            let key = "subagent:\(subagentID)"
            let previous = activities.last { $0.eventID == "\(turnID):\(key)" }
            let detail = type == "subagent.thinking" || type == "subagent.text"
                ? (previous?.detail ?? "") + (p["text"]?.string ?? "")
                : p["summary"]?.string ?? p["tool_preview"]?.string ?? p["text"]?.string
            let activity = publishActivity(key: key, kind: .subagent,
                title: Self.nonempty(p["goal"]?.string) ?? previous?.title ?? "Subagent",
                detail: detail, payload: p, terminal: type == "subagent.complete", childID: subagentID)
            change.activities = [activity]
            let startedAt = p["started_at"]?.number.flatMap {
                $0.isFinite && $0 >= 0 && $0 <= Double(Int.max) ? Int($0) : nil
            }
            let toolCount = p["tool_count"]?.integer.flatMap { $0 >= 0 ? $0 : nil }
            change.nativeSubagent = NativeSubagentRailItem(
                id: subagentID,
                childSessionID: childSessionID,
                parentID: Self.nonempty(p["parent_id"]?.string),
                goal: Self.nonempty(p["goal"]?.string) ?? previous?.title ?? "Subagent task",
                lifecycle: activity.lifecycle,
                status: Self.nonempty(p["status"]?.string),
                model: Self.nonempty(p["model"]?.string),
                toolCount: toolCount,
                startedAt: startedAt
            )
        case "session.info":
            if let key = p["stored_session_id"]?.string { storedID = key }
            if let active = p["running"]?.boolean {
                change.terminal = running && !active
                running = active
                if change.terminal {
                    let unfinished = activities.filter { $0.kind != .subagent && $0.lifecycle == .running }
                    for activity in unfinished {
                        let settled = activity.updating(lifecycle: activity.kind == .tool ? .recorded : .succeeded, summary: activity.summary,
                            detail: activity.detail, occurredAt: activity.occurredAt)
                        upsert(settled)
                        change.activities.append(settled)
                    }
                }
            }
        default: break
        }
        return change
    }

    mutating func seedRunning(_ value: Bool) { running = value }

    @discardableResult
    mutating func adoptTodoSnapshot(_ snapshot: SessionTodoSnapshot) -> Bool {
        guard snapshot.supersedes(todoSnapshot) else { return false }
        todoSnapshot = snapshot
        if let observation = snapshot.nativeObservation,
           observation.epoch.utf8.elementsEqual(epoch.utf8) {
            todoAuthorityGeneration = max(todoAuthorityGeneration, observation.generation)
            todoTurnSequence = observation.turnSequence
        }
        return true
    }

    /// Creates provenance only after the conversation client validates the
    /// activation/replay bracket. Replayed events applied afterward remain the
    /// newer authority within this recovery epoch.
    mutating func validatedRecoveryTodoSnapshot(
        state: BighelpJSONValue,
        epoch newEpoch: String,
        through sequence: Int
    ) -> SessionTodoSnapshot? {
        if !epoch.utf8.elementsEqual(newEpoch.utf8) {
            installTodoEpoch(newEpoch)
        } else if todoAuthorityGeneration == 0 {
            todoAuthorityGeneration = 1
        }
        let recoverySequence = max(sequence, 1)
        return SessionTodoSnapshot.native(
            sessionID: conversationID,
            state: state,
            observedAt: recoverySequence,
            nativeObservation: .init(
                epoch: newEpoch,
                generation: todoAuthorityGeneration,
                turnSequence: todoTurnSequence,
                eventSequence: recoverySequence
            )
        )
    }

    private mutating func finishReasoning() -> [ChatActivityEvent] {
        guard !reasoningSealed, !reasoning.isEmpty else { return [] }
        let unfinished = activities.filter { $0.turnID == turnID && $0.kind == .reasoning && $0.lifecycle == .running }
        guard !unfinished.isEmpty else { return [] }
        reasoningSealed = true
        var settledEvents: [ChatActivityEvent] = []
        for activity in unfinished {
            let settled = activity.updating(lifecycle: .succeeded, summary: activity.summary,
                detail: activity.detail, occurredAt: activity.occurredAt)
            upsert(settled)
            settledEvents.append(settled)
        }
        return settledEvents
    }
    mutating func reserveOrder(_ order: Int) { arrival = max(arrival, order) }
    mutating func seedCheckpoint(_ sequence: Int) { lastSequence = max(lastSequence, sequence) }

    /// Applies the client-observed elapsed time to the final live assistant
    /// segment. The caller supplies the non-replay turn owner; this reducer
    /// never derives timing from tool rows or render timestamps.
    mutating func applyObservedTurnDuration(_ duration: Int, turnID: String) -> TimelineItem? {
        guard self.turnID == turnID, let segmentID,
              (0...86_400_000).contains(duration),
              let index = items.firstIndex(where: { $0.id == segmentID }),
              items[index].role == .assistant else { return nil }
        let updated = withMetadata(items[index], turnDurationMilliseconds: duration)
        items[index] = updated
        return updated
    }

    private mutating func publishText(_ value: String, eventKey: String, complete: Bool) -> TimelineItem {
        if segmentID == nil { segmentID = "\(storedID):live:\(turnID):\(segment):\(eventKey)" }
        let id = segmentID!
        lastTextLookupWorkCount = 1
        let index: Int?
        if let retained = segmentIndex, items.indices.contains(retained), items[retained].id == id {
            index = retained
        } else {
            index = items.firstIndex { candidate in
                lastTextLookupWorkCount += 1
                return candidate.id == id
            }
        }
        let old = index.map { items[$0] }
        if old == nil { arrival += 1 }
        let row = item(id: id, text: value, human: false, delivery: complete ? "Received" : "Streaming",
            order: old?.metadata.sourceOrder ?? arrival)
        if let index { items[index] = row; segmentIndex = index }
        else { segmentIndex = items.count; items.append(row) }
        return row
    }

    private mutating func publishActivity(key: String, kind: ChatActivityKind, title: String,
        detail: String?, payload: [String: BighelpJSONValue], terminal: Bool,
        toolID: String? = nil, childID: String? = nil,
        lifecycleOverride: ChatActivityLifecycle? = nil,
        turnOverride: String? = nil) -> ChatActivityEvent {
        let activityTurnID = turnOverride ?? turnID
        let id = "\(activityTurnID):\(key)"
        let index: Int?
        if let retained = activityIndex, activities.indices.contains(retained), activities[retained].eventID == id {
            index = retained
        } else { index = activities.firstIndex { $0.eventID == id } }
        let old = index.map { activities[$0] }
        if old == nil { arrival += 1 }
        let status = payload["status"]?.string
        // A provider can supply reasoning only on its segment-final receipt.
        // This is recorded content, not an invented start event. Preserve the
        // generic ledger's terminal-without-start guard for lifecycle notices.
        let finalOnlyReasoning = terminal && kind == .reasoning && old == nil
        let lifecycle: ChatActivityLifecycle = lifecycleOverride
            ?? (status == "failed" || status == "error" ? .failed
            : status == "cancelled" || status == "interrupted" ? .cancelled
            : finalOnlyReasoning ? .recorded
            : terminal ? .succeeded : old?.lifecycle.isTerminal == true ? old!.lifecycle : .running)
        let event = ChatActivityEvent(eventID: id, sessionID: conversationID, turnID: activityTurnID,
            kind: kind, lifecycle: lifecycle, title: old?.title ?? title,
            summary: payload["summary"]?.string ?? old?.summary,
            detail: detail ?? old?.detail, occurredAt: old?.occurredAt ?? Int(Date.now.timeIntervalSince1970),
            durationMilliseconds: (payload["duration_s"]?.number ?? payload["duration_seconds"]?.number)
                .map { Int($0 * 1_000) },
            toolCallID: toolID, toolName: payload["name"]?.string ?? old?.toolName,
            arguments: Self.jsonText(payload["args"]) ?? old?.arguments,
            result: Self.jsonText(payload["result"]) ?? old?.result,
            subagentID: childID, sourceOrder: old?.sourceOrder ?? arrival)
        if let index { activities[index] = event; activityIndex = index }
        else { activityIndex = activities.count; activities.append(event) }
        return event
    }

    private mutating func publishSideTask(_ result: DirectHermesSideTaskResult) -> TimelineItem {
        let opaqueID = Data(result.taskID.utf8).base64EncodedString()
        let id = "\(storedID):side-task:\(result.kind.rawValue):\(opaqueID)"
        let index = items.firstIndex { $0.id == id }
        let old = index.map { items[$0] }
        if old == nil { arrival += 1 }
        let row = item(id: id, text: result.text, human: false, delivery: "Received",
            order: old?.metadata.sourceOrder ?? arrival)
        if let index { items[index] = row } else { items.append(row) }
        return row
    }

    private func sideTaskKey(_ kind: DirectHermesSideTaskKind, _ taskID: String) -> String {
        "side-task:\(kind.rawValue):\(Data(taskID.utf8).base64EncodedString())"
    }

    private func sideTaskIdentity(_ kind: DirectHermesSideTaskKind, _ taskID: String) -> Data {
        Data(kind.rawValue.utf8) + Data([0]) + Data(taskID.utf8)
    }

    private mutating func upsertSideTask(_ result: DirectHermesSideTaskResult) {
        if let index = sideTaskResults.firstIndex(where: {
            $0.kind == result.kind && Data($0.taskID.utf8) == Data(result.taskID.utf8)
        }) {
            sideTaskResults[index] = result
        } else {
            Self.appendBounded(result, to: &sideTaskResults)
        }
    }

    private mutating func upsertToolRisk(_ warning: DirectHermesToolOutputRisk) {
        if !warning.toolID.isEmpty, let index = toolOutputRisks.firstIndex(where: {
            Data($0.toolID.utf8) == Data(warning.toolID.utf8)
        }) {
            toolOutputRisks[index] = warning
        } else {
            Self.appendBounded(warning, to: &toolOutputRisks)
        }
    }

    private static func appendBounded<Value>(_ value: Value, to values: inout [Value]) {
        if values.count == 256 { values.removeFirst() }
        values.append(value)
    }

    private mutating func upsert(_ event: ChatActivityEvent) {
        if let index = activities.firstIndex(where: { $0.eventID == event.eventID }) { activities[index] = event }
        else { activities.append(event) }
    }

    private func item(id: String, text: String, human: Bool, delivery: String, order: Int,
        timestamp: Double? = nil, turnDurationMilliseconds: Int? = nil) -> TimelineItem {
        TimelineItem(id: id, role: human ? .human : .assistant,
            sender: human ? .user(snapshot: .init(name: "You")) : .agent(id: profile, snapshot: .init(name: "Hermes")),
            content: .message(text), metadata: .init(source: "Direct Hermes", delivery: delivery,
                timestamp: timestamp.map { Date(timeIntervalSince1970: $0) }, sourceOrder: order,
                turnDurationMilliseconds: turnDurationMilliseconds))
    }

    private func withMetadata(_ item: TimelineItem, timestamp: Date? = nil,
                              turnDurationMilliseconds: Int? = nil) -> TimelineItem {
        TimelineItem(id: item.id, role: item.role, sender: item.sender, content: item.content,
            metadata: TimelineMetadata(source: item.metadata.source, freshness: item.metadata.freshness,
                delivery: item.metadata.delivery, timestamp: timestamp ?? item.metadata.timestamp,
                sourceOrder: item.metadata.sourceOrder,
                platformMessageID: item.metadata.platformMessageID,
                turnDurationMilliseconds: turnDurationMilliseconds ?? item.metadata.turnDurationMilliseconds,
                contentReference: item.metadata.contentReference), attachments: item.attachments)
    }

    private static func durationMilliseconds(_ value: BighelpJSONValue?) -> Int? {
        guard let duration = value?.integer, (0...86_400_000).contains(duration) else { return nil }
        return duration
    }

    static func jsonText(_ value: BighelpJSONValue?) -> String? {
        guard let value else { return nil }
        if let string = value.string { return string }
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func canonicalTodoSnapshot(
        from payload: [String: BighelpJSONValue],
        sequence: Int?
    ) -> SessionTodoSnapshot? {
        let state: [String: BighelpJSONValue]
        if payload["todos"]?.array != nil {
            state = payload
        } else {
            guard Self.isTodoInvocation(name: payload["name"]?.string, arguments: payload["args"]),
                  let result = payload["result"] else { return nil }
            if let response = result.object?["response"]?.object {
                state = response
            } else if let object = result.object {
                state = object
            } else if let text = result.string,
                      text.utf8.count <= 512_000,
                      let data = text.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(BighelpJSONValue.self, from: data),
                      let object = decoded.object {
                state = object
            } else {
                return nil
            }
        }
        // Share activation/history semantics: an unused revision-zero read is
        // unknown, not a canonical empty list that suppresses live activity.
        return SessionTodoSnapshot.native(
            sessionID: conversationID,
            state: .object(state),
            observedAt: sequence,
            nativeObservation: sequence.flatMap { sequence in
                guard sequence > 0, !epoch.isEmpty else { return nil }
                return .init(
                    epoch: epoch,
                    generation: todoAuthorityGeneration,
                    turnSequence: todoTurnSequence,
                    eventSequence: sequence
                )
            }
        )
    }

    private static func isTodoInvocation(
        name: String?,
        arguments: BighelpJSONValue?
    ) -> Bool {
        if name == "todo" || name == "todo_list" { return true }
        guard name == "tool_call", let object = arguments?.object else { return false }
        let calls: [BighelpJSONValue]
        if let values = object["calls"]?.array {
            calls = values
        } else if object["name"] != nil {
            calls = [.object(object)]
        } else {
            return false
        }
        guard calls.count == 1, let nested = calls.first?.object?["name"]?.string else {
            return false
        }
        return nested == "todo" || nested == "todo_list"
    }

    private mutating func acceptCanonicalTodoSnapshot(
        from payload: [String: BighelpJSONValue],
        sequence: Int?,
        into change: inout Change
    ) {
        guard let snapshot = canonicalTodoSnapshot(from: payload, sequence: sequence),
              snapshot.supersedes(todoSnapshot) else { return }
        todoSnapshot = snapshot
        change.todoSnapshot = snapshot
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Epoch changes arrive here only after the conversation client validates
    /// the recovery bracket. A persisted matching epoch keeps its generation;
    /// a different validated epoch advances the local durable generation once.
    private mutating func installTodoEpoch(_ newEpoch: String) {
        if let retained = todoSnapshot?.nativeObservation,
           retained.epoch.utf8.elementsEqual(newEpoch.utf8) {
            todoAuthorityGeneration = retained.generation
            todoTurnSequence = retained.turnSequence
            return
        }
        let retainedGeneration = todoSnapshot?.nativeObservation?.generation ?? 0
        let base = max(todoAuthorityGeneration, retainedGeneration)
        todoAuthorityGeneration = base == Int.max ? Int.max : base + 1
        todoTurnSequence = 0
    }
}
