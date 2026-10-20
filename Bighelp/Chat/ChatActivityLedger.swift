import Foundation

struct ChatActivityLedger: Equatable, Sendable {
    let sessionID: String
    private var entriesByID: [String: ChatActivityEvent] = [:]
    private var keyBySemanticIdentity: [String: String] = [:]
    private var orderedIDs: [String] = []
    private var orderedEvents: [ChatActivityEvent] = []
    private var eventIndexByID: [String: Int] = [:]
    private var orderedIDsByTurn: [String: [String]] = [:]
    private var orderedTurnIDs: [String] = []
    private var turnIndexByID: [String: Int] = [:]
    private(set) var lastMutationWorkCount = 0
    /// While `init` takes a whole history: keys still go in order one by one, exactly as
    /// `receive` would place them, but the ordered events, their positions and the turn
    /// order are laid out once at the end. Keeping those current through each insert made
    /// reopening a long chat (saved thinking first, then the host's tools) quadratic.
    private var isBuilding = false

    init(sessionID: String, events: [ChatActivityEvent] = []) {
        self.sessionID = sessionID
        isBuilding = true
        for event in events where event.sessionID == sessionID {
            if entriesByID[event.id] == nil {
                insert(event, key: event.id)
            } else {
                _ = receive(event)
            }
        }
        isBuilding = false
        orderedEvents = orderedIDs.compactMap { entriesByID[$0] }
        eventIndexByID = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
        rebuildTurnOrder()
    }

    /// Bound a background projection to the same canonical suffix as its store.
    /// Remove retired identities as well as rows so later lifecycle updates do
    /// not resurrect an event through an index the catalog no longer owns.
    mutating func retainLatest(_ maximumCount: Int) {
        let removalCount = orderedIDs.count - max(0, maximumCount)
        guard removalCount > 0 else { return }
        let retiredIDs = Set(orderedIDs.prefix(removalCount))
        for key in retiredIDs {
            if let event = entriesByID.removeValue(forKey: key),
               let identity = event.semanticIdentity,
               keyBySemanticIdentity[identity] == key {
                keyBySemanticIdentity.removeValue(forKey: identity)
            }
            eventIndexByID.removeValue(forKey: key)
        }
        orderedIDs.removeFirst(removalCount)
        orderedEvents.removeFirst(removalCount)
        for (index, key) in orderedIDs.enumerated() { eventIndexByID[key] = index }
        for turnID in orderedTurnIDs {
            let retained = (orderedIDsByTurn[turnID] ?? []).filter { !retiredIDs.contains($0) }
            if retained.isEmpty { orderedIDsByTurn.removeValue(forKey: turnID) }
            else { orderedIDsByTurn[turnID] = retained }
        }
        rebuildTurnOrder()
    }

    @discardableResult
    mutating func receive(_ event: ChatActivityEvent) -> ChatActivityReconciliation {
        lastMutationWorkCount = 1
        guard event.sessionID == sessionID else { return .ignoredWrongSession }
        let key = event.id
        let existingKey: String?
        if entriesByID[key] != nil {
            existingKey = key
        } else {
            lastMutationWorkCount += 1
            existingKey = event.semanticIdentity.flatMap { keyBySemanticIdentity[$0] }
        }
        guard let existingKey, let existing = entriesByID[existingKey] else {
            if event.lifecycle.isTerminal {
                let isRecoverableTerminal = switch event.kind {
                case .tool:
                    event.hasCanonicalToolIdentity
                case .botHandoff:
                    event.hasCanonicalBotHandoffIdentity
                default:
                    false
                }
                guard isRecoverableTerminal else {
                    return .ignoredTerminalWithoutStart
                }
                insert(event, key: key)
                return .recovered
            }
            insert(event, key: key)
            return .inserted
        }
        guard
            existing.kind == event.kind,
            existing.toolCallID == event.toolCallID,
            existing.subagentID == event.subagentID,
            existing.botRunID == event.botRunID,
            existing.memberID == event.memberID,
            existing.fromMemberID == nil || event.fromMemberID == nil
                || existing.fromMemberID == event.fromMemberID
        else { return .ignoredIdentityConflict }
        guard existing != event else { return .duplicate }
        let reconciled = Self.merge(existing, event)
        guard reconciled != existing else { return .stale }
        entriesByID[existingKey] = reconciled
        if let index = eventIndexByID[existingKey] {
            orderedEvents[index] = reconciled
        }
        return .updated
    }

    private mutating func insert(_ event: ChatActivityEvent, key: String) {
        entriesByID[key] = event
        if let identity = event.semanticIdentity, keyBySemanticIdentity[identity] == nil {
            keyBySemanticIdentity[identity] = key
        }
        // `entriesByID` holds the same (merged) events as `orderedEvents`, including while building.
        let appendsGlobally = orderedIDs.last.flatMap { lastID in
            entriesByID[lastID].map { !Self.isCanonicallyBefore(event, key: key, than: $0, key: lastID) }
        } ?? true
        let globalIndex = appendsGlobally
            ? orderedIDs.endIndex
            : insertionIndex(for: event, key: key, in: orderedIDs)
        orderedIDs.insert(key, at: globalIndex)
        if !isBuilding {
            orderedEvents.insert(event, at: globalIndex)
            if globalIndex == orderedEvents.count - 1 {
                eventIndexByID[key] = globalIndex
                lastMutationWorkCount += 1
            } else {
                for index in globalIndex..<orderedIDs.count {
                    eventIndexByID[orderedIDs[index]] = index
                    lastMutationWorkCount += 1
                }
            }
        }

        let lastTurnID = orderedIDsByTurn[event.turnID]?.last
        let appendsToTurn = lastTurnID.flatMap { lastID in
            entriesByID[lastID].map {
                !Self.isCanonicallyBefore(event, key: key, than: $0, key: lastID)
            }
        } ?? true
        if appendsToTurn {
            orderedIDsByTurn[event.turnID, default: []].append(key)
            lastMutationWorkCount += 1
        } else {
            var turnIDs = orderedIDsByTurn[event.turnID] ?? []
            let turnIndex = insertionIndex(for: event, key: key, in: turnIDs)
            turnIDs.insert(key, at: turnIndex)
            orderedIDsByTurn[event.turnID] = turnIDs
            lastMutationWorkCount += turnIDs.count
        }

        guard !isBuilding else { return }
        if turnIndexByID[event.turnID] == nil, appendsGlobally {
            turnIndexByID[event.turnID] = orderedTurnIDs.count
            orderedTurnIDs.append(event.turnID)
            lastMutationWorkCount += 1
        } else if !appendsGlobally || turnIndexByID[event.turnID] == nil {
            rebuildTurnOrder()
        }
    }

    private mutating func insertionIndex(
        for event: ChatActivityEvent,
        key: String,
        in ids: [String]
    ) -> Int {
        var lower = 0
        var upper = ids.count
        while lower < upper {
            lastMutationWorkCount += 1
            let middle = lower + (upper - lower) / 2
            guard let existing = entriesByID[ids[middle]] else {
                lower = middle + 1
                continue
            }
            if Self.isCanonicallyBefore(event, key: key, than: existing, key: ids[middle]) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }

    private mutating func rebuildTurnOrder() {
        orderedTurnIDs.removeAll(keepingCapacity: true)
        turnIndexByID.removeAll(keepingCapacity: true)
        for event in orderedEvents where turnIndexByID[event.turnID] == nil {
            turnIndexByID[event.turnID] = orderedTurnIDs.count
            orderedTurnIDs.append(event.turnID)
            lastMutationWorkCount += 1
        }
    }

    private static func isCanonicallyBefore(
        _ lhs: ChatActivityEvent,
        key lhsKey: String,
        than rhs: ChatActivityEvent,
        key rhsKey: String
    ) -> Bool {
        switch (lhs.sourceOrder, rhs.sourceOrder) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            if lhs.occurredAt != rhs.occurredAt {
                return lhs.occurredAt < rhs.occurredAt
            }
            return lhsKey < rhsKey
        }
    }

    private static func merge(
        _ existing: ChatActivityEvent,
        _ incoming: ChatActivityEvent
    ) -> ChatActivityEvent {
        let arguments = richestToolDetail(
            existing.arguments,
            incoming.arguments,
            requiresJSON: existing.kind == .tool
        )
        let result = richestToolDetail(existing.result, incoming.result)
        let lifecycle = preferredLifecycle(
            existing,
            incoming,
            mergedArguments: arguments,
            mergedResult: result
        )
        let lifecycleSource = [existing, incoming]
            .filter { $0.lifecycle == lifecycle }
            .max { $0.occurredAt < $1.occurredAt }
            ?? existing
        return ChatActivityEvent(
            eventID: lifecycleSource.eventID,
            sessionID: existing.sessionID,
            turnID: existing.turnID,
            kind: existing.kind,
            lifecycle: lifecycle,
            title: richestText(existing.title, incoming.title) ?? existing.title,
            summary: richestText(
                existing.lifecycle == lifecycle ? existing.summary : nil,
                incoming.lifecycle == lifecycle ? incoming.summary : nil
            ),
            detail: richestText(existing.detail, incoming.detail),
            occurredAt: max(existing.occurredAt, incoming.occurredAt),
            durationMilliseconds: maxOptional(
                existing.durationMilliseconds,
                incoming.durationMilliseconds
            ),
            toolCallID: existing.toolCallID,
            toolName: richestText(existing.toolName, incoming.toolName),
            arguments: arguments,
            result: result,
            generatedMedia: incoming.generatedMedia ?? existing.generatedMedia,
            subagentID: existing.subagentID,
            botRunID: existing.botRunID,
            memberID: existing.memberID,
            fromMemberID: incoming.fromMemberID ?? existing.fromMemberID,
            sourceOrder: minOptional(existing.sourceOrder, incoming.sourceOrder),
            contentReference: incoming.contentReference ?? existing.contentReference
        )
    }

    private static func preferredLifecycle(
        _ existing: ChatActivityEvent,
        _ incoming: ChatActivityEvent,
        mergedArguments: String?,
        mergedResult: String?
    ) -> ChatActivityLifecycle {
        let lifecycles = [existing.lifecycle, incoming.lifecycle]
        if lifecycles.contains(.succeeded),
           canonicalArguments(mergedArguments),
           nonempty(mergedResult) != nil {
            return .succeeded
        }
        if lifecycles.contains(.failed) { return .failed }
        if lifecycles.contains(.cancelled) { return .cancelled }
        if lifecycles.contains(.succeeded) { return .succeeded }
        if lifecycles.contains(.running) { return .running }
        // Re-reading neutral recorded history must not invent active work.
        return .recorded
    }

    private static func richestToolDetail(
        _ lhs: String?,
        _ rhs: String?,
        requiresJSON: Bool = false
    ) -> String? {
        let values = [lhs, rhs].compactMap(nonempty)
        guard requiresJSON else { return values.max(by: { $0.count < $1.count }) }
        let valid = values.filter(canonicalArguments)
        return (valid.isEmpty ? values : valid).max(by: { $0.count < $1.count })
    }

    private static func richestText(_ lhs: String?, _ rhs: String?) -> String? {
        [lhs, rhs]
            .compactMap(nonempty)
            .max { $0.count < $1.count }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private static func canonicalArguments(_ value: String?) -> Bool {
        guard
            let value = nonempty(value),
            let data = value.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            object is [String: Any] || object is [Any]
        else { return false }
        return true
    }

    private static func maxOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)): max(lhs, rhs)
        case (.some(let value), .none), (.none, .some(let value)): value
        case (.none, .none): nil
        }
    }

    private static func minOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)): min(lhs, rhs)
        case (.some(let value), .none), (.none, .some(let value)): value
        case (.none, .none): nil
        }
    }

    func event(id: String) -> ChatActivityEvent? {
        entriesByID[id]
    }

    func events(for turnID: String) -> [ChatActivityEvent] {
        orderedIDsByTurn[turnID, default: []].compactMap { entriesByID[$0] }
    }

    func visibleEvents(
        for turnID: String,
        visibility: ChatActivityVisibility
    ) -> [ChatActivityEvent] {
        events(for: turnID).filter { event in
            event.isVisible(using: visibility)
        }
    }

    var turnIDs: [String] {
        orderedTurnIDs
    }

    var allEvents: [ChatActivityEvent] {
        orderedEvents
    }
}

private extension ChatActivityEvent {
    var hasCanonicalToolIdentity: Bool {
        guard let toolCallID else { return false }
        return !toolCallID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasCanonicalBotHandoffIdentity: Bool {
        guard let botRunID, let memberID else { return false }
        return !botRunID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !memberID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
