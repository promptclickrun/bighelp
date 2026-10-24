import Observation
import SwiftUI

/// Reader choices belong to the prepared conversation, not disposable timeline rows.
/// This stores only explicit gestures, never remote execution state or transcript data.
@MainActor
@Observable
final class ChatActivityDisclosureStore {
    private struct Key: Hashable {
        let sessionID: String
        let turnID: String
        let kind: String
        let identity: String
    }

    /// Choices on a turn's "Worked for…" and on the running turn's block, by their row IDs. The two
    /// IDs differ, so a block opened while the agent works closes in place when the answer comes.
    private var turnChoices: [String: Bool] = [:] {
        didSet { revision &+= 1 }
    }
    /// Bumped by every choice, so the chat's rows can be kept until one changes.
    private(set) var revision: UInt64 = 0

    /// The chat's `ChatWorkStyle`; nil in a group chat. Full opens every folder and thought.
    private(set) var style: ChatWorkStyle?

    func configure(style: ChatWorkStyle?) {
        guard self.style != style else { return }
        self.style = style
        revision &+= 1
    }

    /// A "Worked for…" (`ChatCompletedTurn`) or running block (`ChatLiveWork`), by its ID: closed until opened.
    func isWorkExpanded(_ id: String) -> Bool {
        turnChoices[id] ?? false
    }

    func setWorkExpanded(_ expanded: Bool, id: String) {
        turnChoices[id] = expanded
    }

    private var eventChoices: [Key: Bool] = [:] {
        didSet { revision &+= 1 }
    }
    private var trailChoices: [Key: Bool] = [:] {
        didSet { revision &+= 1 }
    }

    func isExpanded(_ event: ChatActivityEvent) -> Bool {
        eventChoices[key(for: event)] ?? (event.kind == .reasoning && event.lifecycle == .running)
    }

    func setExpanded(_ expanded: Bool, for event: ChatActivityEvent) {
        eventChoices[key(for: event)] = expanded
    }

    /// Back-to-back reasoning opens and closes as one row. A choice made on any
    /// entry holds as more thinking arrives; otherwise it's open while thinking, and always in Full.
    func isExpanded(reasoning events: [ChatActivityEvent]) -> Bool {
        let choices = events.compactMap { eventChoices[key(for: $0)] }
        if choices.contains(true) { return true }
        if choices.contains(false) { return false }
        return style == .full || events.contains { $0.lifecycle == .running }
    }

    func setExpanded(_ expanded: Bool, reasoning events: [ChatActivityEvent]) {
        for event in events {
            eventChoices[key(for: event)] = expanded
        }
    }

    /// A folder the agent is still working on (`isLive`) lists its calls as
    /// they happen, then closes once it's finished, unless the reader chose.
    /// Full keeps every folder open.
    func isExpanded(_ turn: ChatActivityTurn, isLive: Bool = false) -> Bool {
        let choices = turn.events.compactMap { trailChoices[key(for: $0)] }
        // Event-keyed choices survive segment regrouping and canonical event-ID changes.
        if choices.contains(true) { return true }
        if choices.contains(false) { return false }
        return style == .full || isLive || turn.events.contains { isExpanded($0) }
    }

    func setExpanded(_ expanded: Bool, for turn: ChatActivityTurn) {
        for event in turn.events {
            trailChoices[key(for: event)] = expanded
        }
    }

    private func key(for event: ChatActivityEvent) -> Key {
        if event.kind == .tool, let callID = event.toolCallID, !callID.isEmpty {
            return Key(sessionID: event.sessionID, turnID: event.turnID,
                       kind: "tool", identity: callID)
        }
        return Key(sessionID: event.sessionID, turnID: event.turnID,
                   kind: "event", identity: event.eventID)
    }
}

private struct ChatActivityDisclosureStoreKey: EnvironmentKey {
    static let defaultValue: ChatActivityDisclosureStore? = nil
}

extension EnvironmentValues {
    var chatActivityDisclosureStore: ChatActivityDisclosureStore? {
        get { self[ChatActivityDisclosureStoreKey.self] }
        set { self[ChatActivityDisclosureStoreKey.self] = newValue }
    }
}
