import Foundation
import SwiftUI

struct ChatCardInteractionScope: Equatable, Sendable {
    let authorityID: String
    let profileID: String
    let conversationID: String

    var isUsable: Bool {
        !authorityID.isEmpty && !profileID.isEmpty && !conversationID.isEmpty
    }

    func exactlyMatches(_ other: Self) -> Bool {
        Self.exact(authorityID, other.authorityID)
            && Self.exact(profileID, other.profileID)
            && Self.exact(conversationID, other.conversationID)
    }

    private static func exact(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }
}

struct ChatCardInteractionIdentity: Sendable {
    let scope: ChatCardInteractionScope
    let messageID: String
    let cardID: String

    var isUsable: Bool {
        scope.isUsable && !messageID.isEmpty && !cardID.isEmpty
    }
}

@MainActor
final class BighelpCardInteractionStore {
    /// Parent integration: add this prefix to
    /// BighelpLocalAccountDataEraser.defaultsKeyPrefixes.
    nonisolated static let defaultsKeyPrefix = "loopdy.chat-card-interactions.v1."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func checklistState(
        for identity: ChatCardInteractionIdentity,
        defaults initial: [String: Bool]
    ) -> [String: Bool] {
        guard identity.isUsable else { return initial }
        let stored = defaults.dictionary(forKey: key(identity, lane: "checklist")) ?? [:]
        var result = initial
        for (itemID, value) in stored where initial.keys.contains(itemID) {
            if let value = value as? Bool { result[itemID] = value }
        }
        return result
    }

    func setChecklistState(
        _ state: [String: Bool],
        for identity: ChatCardInteractionIdentity,
        allowedItemIDs: Set<String>
    ) {
        guard identity.isUsable, allowedItemIDs.count <= 40 else { return }
        let bounded = state.reduce(into: [String: Bool]()) { result, entry in
            guard allowedItemIDs.contains(entry.key) else { return }
            result[entry.key] = entry.value
        }
        defaults.set(bounded, forKey: key(identity, lane: "checklist"))
    }

    func selection(
        for identity: ChatCardInteractionIdentity,
        allowedOptionIDs: Set<String>,
        maximum: Int
    ) -> Set<String> {
        guard identity.isUsable, (1...24).contains(maximum) else { return [] }
        let stored = defaults.stringArray(forKey: key(identity, lane: "selection")) ?? []
        return Set(stored.filter(allowedOptionIDs.contains).prefix(maximum))
    }

    func setSelection(
        _ selection: Set<String>,
        for identity: ChatCardInteractionIdentity,
        allowedOptionIDs: Set<String>,
        maximum: Int
    ) {
        guard identity.isUsable, (1...24).contains(maximum) else { return }
        let bounded = selection.filter(allowedOptionIDs.contains).sorted().prefix(maximum)
        defaults.set(Array(bounded), forKey: key(identity, lane: "selection"))
    }

    /// The answer this card already sent to the agent, if any.
    func reply(for identity: ChatCardInteractionIdentity) -> String? {
        guard identity.isUsable else { return nil }
        return defaults.string(forKey: key(identity, lane: "reply"))
    }

    func setReply(_ reply: String, for identity: ChatCardInteractionIdentity) {
        guard identity.isUsable, reply.utf8.count <= ChatOutgoingMessage.maximumCardReplyBytes else { return }
        defaults.set(reply, forKey: key(identity, lane: "reply"))
    }

    static func eraseAll(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(defaultsKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private func key(_ identity: ChatCardInteractionIdentity, lane: String) -> String {
        let values = [
            identity.scope.authorityID,
            identity.scope.profileID,
            identity.scope.conversationID,
            identity.messageID,
            identity.cardID,
            lane,
        ]
        var bytes = Data()
        for value in values {
            let valueBytes = Data(value.utf8)
            var length = UInt64(valueBytes.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(valueBytes)
        }
        let encoded = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.defaultsKeyPrefix + encoded
    }
}

enum ChatCardComposerMergeStrategy: Sendable {
    case replace
    case append
}

enum ChatCardAutomationAction: String, Sendable {
    case pause
    case resume
    case run
}

struct ChatCardAutomationSnapshot: Sendable {
    let jobID: String
    let profileID: String
    let status: ScheduledTaskStatus
}

enum ChatCardInteractionError: Error, LocalizedError {
    case unavailable
    case notReady
    case ownerChanged
    case snapshotChanged
    case taskMissing
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .unavailable: "This action is unavailable on the current connection."
        case .notReady: "This chat can't send right now. Try again in a moment."
        case .ownerChanged: "This card belongs to a different host, profile, or conversation."
        case .snapshotChanged: "This task changed after the card was created. Refresh before changing it."
        case .taskMissing: "This task is no longer available."
        case .invalidResult: "Hermes did not confirm the requested task state."
        }
    }
}

@MainActor
struct ChatCardScheduledTaskBackend {
    let list: @MainActor (_ profileID: String) async throws -> [ScheduledTask]
    let setPaused: @MainActor (_ paused: Bool, _ jobID: String, _ profileID: String) async throws -> ScheduledTask
    let runNow: @MainActor (_ jobID: String, _ profileID: String) async throws -> ScheduledTask

    /// Adapts the shipping store without exposing its private client. `load()`
    /// performs the required fresh read; mutations publish only the store's
    /// client-confirmed replacement.
    init(store: ScheduledTasksStore) {
        list = { profileID in
            await store.load()
            guard store.loadState == .loaded else { throw ChatCardInteractionError.unavailable }
            return store.tasks.filter { $0.agentID.utf8.elementsEqual(profileID.utf8) }
        }
        setPaused = { paused, jobID, profileID in
            try await store.setPaused(paused, id: jobID, agentID: profileID)
            guard let task = store.tasks.filter({
                $0.id.utf8.elementsEqual(jobID.utf8)
                    && $0.agentID.utf8.elementsEqual(profileID.utf8)
            }).only else { throw ChatCardInteractionError.invalidResult }
            return task
        }
        runNow = { jobID, profileID in
            try await store.runNow(id: jobID, agentID: profileID)
            guard let task = store.tasks.filter({
                $0.id.utf8.elementsEqual(jobID.utf8)
                    && $0.agentID.utf8.elementsEqual(profileID.utf8)
            }).only else { throw ChatCardInteractionError.invalidResult }
            return task
        }
    }
}

@MainActor
struct ChatCardInteractionHandler {
    let scope: ChatCardInteractionScope
    let store: BighelpCardInteractionStore
    let currentDraft: @MainActor () -> String
    let stageComposer: @MainActor (_ text: String, _ strategy: ChatCardComposerMergeStrategy) -> Void
    /// Sends an answer to the agent as the person's next message. False when
    /// the chat can't send right now; nothing was sent.
    let sendReply: @MainActor (_ text: String) -> Bool
    let scheduledTasks: ChatCardScheduledTaskBackend?
    let currentScope: @MainActor () -> ChatCardInteractionScope?

    init(
        scope: ChatCardInteractionScope,
        store: BighelpCardInteractionStore,
        currentDraft: @escaping @MainActor () -> String,
        stageComposer: @escaping @MainActor (_ text: String, _ strategy: ChatCardComposerMergeStrategy) -> Void,
        sendReply: @escaping @MainActor (_ text: String) -> Bool = { _ in false },
        scheduledTasks: ChatCardScheduledTaskBackend? = nil,
        currentScope: @escaping @MainActor () -> ChatCardInteractionScope?
    ) {
        self.scope = scope
        self.store = store
        self.currentDraft = currentDraft
        self.stageComposer = stageComposer
        self.sendReply = sendReply
        self.scheduledTasks = scheduledTasks
        self.currentScope = currentScope
    }

    /// Sends a card's answer straight to the agent and remembers it, so the
    /// card shows what was sent.
    func reply(_ text: String, for identity: ChatCardInteractionIdentity) throws {
        guard isCurrent, identity.scope.exactlyMatches(scope) else { throw ChatCardInteractionError.ownerChanged }
        guard sendReply(text) else { throw ChatCardInteractionError.notReady }
        store.setReply(text, for: identity)
        Telemetry.featureUsed(.formSubmitted)
    }

    var isCurrent: Bool {
        guard let current = currentScope() else { return false }
        return current.exactlyMatches(scope)
    }

    func stage(_ text: String, strategy: ChatCardComposerMergeStrategy) throws {
        guard isCurrent else { throw ChatCardInteractionError.ownerChanged }
        guard !text.isEmpty, text.utf8.count <= 2_000 else {
            throw ChatCardInteractionError.unavailable
        }
        stageComposer(text, strategy)
    }

    func perform(
        _ action: ChatCardAutomationAction,
        snapshot: ChatCardAutomationSnapshot
    ) async throws -> ScheduledTask {
        guard let current = currentScope(), current.exactlyMatches(scope) else {
            throw ChatCardInteractionError.ownerChanged
        }
        guard snapshot.profileID.utf8.elementsEqual(scope.profileID.utf8) else {
            throw ChatCardInteractionError.ownerChanged
        }
        guard let scheduledTasks else { throw ChatCardInteractionError.unavailable }

        // Every mutation starts from a fresh typed read. The historical card is
        // never treated as current task authority.
        let matches = try await scheduledTasks.list(snapshot.profileID).filter {
            $0.id.utf8.elementsEqual(snapshot.jobID.utf8)
                && $0.agentID.utf8.elementsEqual(snapshot.profileID.utf8)
        }
        guard isCurrent, !Task.isCancelled else { throw ChatCardInteractionError.ownerChanged }
        guard let currentTask = matches.only else {
            throw matches.isEmpty ? ChatCardInteractionError.taskMissing : ChatCardInteractionError.invalidResult
        }
        guard currentTask.status == snapshot.status else {
            throw ChatCardInteractionError.snapshotChanged
        }

        let confirmed: ScheduledTask
        switch action {
        case .pause:
            guard currentTask.status == .active else { throw ChatCardInteractionError.snapshotChanged }
            confirmed = try await scheduledTasks.setPaused(true, snapshot.jobID, snapshot.profileID)
            guard confirmed.status == .paused else { throw ChatCardInteractionError.invalidResult }
        case .resume:
            guard currentTask.status == .paused else { throw ChatCardInteractionError.snapshotChanged }
            confirmed = try await scheduledTasks.setPaused(false, snapshot.jobID, snapshot.profileID)
            guard confirmed.status == .active else { throw ChatCardInteractionError.invalidResult }
        case .run:
            confirmed = try await scheduledTasks.runNow(snapshot.jobID, snapshot.profileID)
        }
        guard isCurrent, !Task.isCancelled else { throw ChatCardInteractionError.ownerChanged }
        guard confirmed.id.utf8.elementsEqual(snapshot.jobID.utf8),
              confirmed.agentID.utf8.elementsEqual(snapshot.profileID.utf8) else {
            throw ChatCardInteractionError.invalidResult
        }
        return confirmed
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}

private struct ChatCardInteractionsKey: EnvironmentKey {
    static let defaultValue: ChatCardInteractionHandler? = nil
}

extension EnvironmentValues {
    var chatCardInteractions: ChatCardInteractionHandler? {
        get { self[ChatCardInteractionsKey.self] }
        set { self[ChatCardInteractionsKey.self] = newValue }
    }
}
