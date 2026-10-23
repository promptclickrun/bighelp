import Foundation
import UIKit
import UserNotifications

/// Chats on screen right now, so an alert for a conversation you're already
/// looking at isn't also shown as a banner (like Messages), and its earlier
/// alerts leave Notification Center once you're reading it.
@MainActor
final class BighelpVisibleChats {
    static let shared = BighelpVisibleChats()

    private init() {
        // Back in the app on a chat you left open: its alerts are read now too.
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BighelpVisibleChats.shared.clearDelivered() }
        }
    }

    private final class Entry {
        weak var model: ChatModel?
        /// The chat screens showing this model. A screen made again for the same chat
        /// can appear before the old one disappears; the chat stays on screen.
        var screens: Set<AnyHashable> = []
        /// What the chat was last known as. The chat's connection can be made again
        /// (back from the background, a new computer connection) and for a moment
        /// say nothing; the chat is still the one in front of the person.
        var remembered: [String] = []
        init(_ model: ChatModel) { self.model = model }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// `screen` names the chat view that appeared, so one that reports twice counts once.
    func appeared(_ model: ChatModel, screen: AnyHashable = "") {
        if let entry = entries[ObjectIdentifier(model)], entry.model === model {
            entry.screens.insert(screen)
        } else {
            let entry = Entry(model)
            entry.screens = [screen]
            entries[ObjectIdentifier(model)] = entry
        }
        clearDelivered()
    }

    /// A visible chat learned who it is (its connection arrived, or Hermes gave it a new
    /// stored ID): the alerts it already has in Notification Center are read too.
    func identityChanged() {
        guard !entries.isEmpty else { return }
        clearDelivered()
    }

    /// Removes delivered alerts for the chats on screen: replies, questions and
    /// approvals (the chat shows those itself).
    private func clearDelivered() {
        let chats = threadIdentifiers
        let conversations = conversationIDs
        guard !chats.isEmpty || !conversations.isEmpty else { return }
        Task { await Self.removeDelivered(chats: chats, conversations: conversations) }
    }

    /// Whether a delivered alert belongs to a chat that's on screen.
    nonisolated static func isRead(userInfo: [AnyHashable: Any], thread: String,
                                   chats: Set<String>, conversations: Set<String>) -> Bool {
        if let chat = BighelpNotificationGrouping.chat(of: userInfo) { return chats.contains(chat) }
        if case .chat(let id)? = BighelpPromptAlertLink.url(in: userInfo)
            .flatMap(BighelpIncomingURLRoute.parse) { return conversations.contains(id) }
        return chats.contains(thread)
    }

    nonisolated static func removeDelivered(chats: Set<String>, conversations: Set<String>) async {
        let center = UNUserNotificationCenter.current()
        let read = await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notes in
                continuation.resume(returning: notes.filter { note in
                    let content = note.request.content
                    return isRead(userInfo: content.userInfo, thread: content.threadIdentifier,
                                  chats: chats, conversations: conversations)
                }.map(\.request.identifier))
            }
        }
        if !read.isEmpty { center.removeDeliveredNotifications(withIdentifiers: read) }
    }

    func disappeared(_ model: ChatModel, screen: AnyHashable = "") {
        guard let entry = entries[ObjectIdentifier(model)] else { return }
        entry.screens.remove(screen)
        if entry.screens.isEmpty || entry.model == nil { entries[ObjectIdentifier(model)] = nil }
    }

    /// Notification thread identifiers of the visible chats. Hosts send each
    /// alert with `thread-id` = sessionReference(profile, stored session).
    ///
    /// A chat answers to every stored ID it has had: Hermes gives a compacted chat a new
    /// one, and an alert sent before that (a push can take 10 seconds) still names the old
    /// one. A chat whose connection isn't there yet is known from its saved row.
    var threadIdentifiers: Set<String> {
        var all: Set<String> = []
        for entry in entries.values {
            guard let model = entry.model else { continue }
            if let native = model.nativeConversationClient {
                for stored in [native.storedID] + native.formerStoredIDs {
                    remember(ManagedNotificationValidation.sessionReference(profile: native.profile, session: stored),
                             in: entry)
                }
            } else if let session = model.sourceSession, let stored = session.remoteStoredID, !stored.isEmpty,
                      session.agentIDs.count == 1, let profile = session.agentIDs.first {
                remember(ManagedNotificationValidation.sessionReference(profile: profile, session: stored), in: entry)
            }
            all.formUnion(entry.remembered)
        }
        return all
    }

    private static let rememberedLimit = 16

    private func remember(_ reference: String, in entry: Entry) {
        guard !entry.remembered.contains(reference) else { return }
        entry.remembered.append(reference)
        if entry.remembered.count > Self.rememberedLimit {
            entry.remembered.removeFirst(entry.remembered.count - Self.rememberedLimit)
        }
    }

    var conversationIDs: Set<String> {
        Set(entries.values.compactMap { $0.model?.conversationID })
    }

    #if DEBUG
    /// The chats on screen, for the speed checks' autopilot (`ChatPerformanceAutopilot`).
    var models: [ChatModel] { entries.values.compactMap(\.model) }
    #endif

    /// Whether an alert with this thread belongs to a chat that's on screen.
    func isShowing(thread: String) -> Bool {
        !thread.isEmpty && threadIdentifiers.contains(thread)
    }

    /// How long after a chat's turn ends an alert from its agent counts as about
    /// it, when the alert can't say which chat it's for.
    static let recentTurnWindow: TimeInterval = 120

    /// Whether an alert is about a chat you're looking at.
    ///
    /// - `chat`: the chat reference the alert carries (push data, or the thread it
    ///   arrived with). When it has one, only that chat counts, with one exception: a
    ///   chat Hermes just compacted has a new stored ID, and an alert for the turn that
    ///   compacted it can name the new one before the app has heard of it.
    /// - `agent`: the agent it's from. An alert without a chat reference (one the
    ///   phone couldn't open, say) is about the chat on screen when that chat is
    ///   the same agent's and its turn is running or just ended.
    func isShowing(chat: String?, agent: String?, now: Date = Date()) -> Bool {
        if let chat, !chat.isEmpty {
            if threadIdentifiers.contains(chat) { return true }
            return isBusy(withAgent: agent, now: now, afterCompaction: true)
        }
        return isBusy(withAgent: agent, now: now, afterCompaction: false)
    }

    private func isBusy(withAgent agent: String?, now: Date, afterCompaction: Bool) -> Bool {
        guard let agent, !agent.isEmpty else { return false }
        return entries.values.contains { entry in
            guard let model = entry.model, let native = model.nativeConversationClient,
                  native.profile == agent else { return false }
            if afterCompaction {
                guard let compacted = model.lastCompactionAt,
                      now.timeIntervalSince(compacted) < Self.recentTurnWindow else { return false }
            }
            if model.isSending { return true }
            return model.lastTurnEndedAt.map { now.timeIntervalSince($0) < Self.recentTurnWindow } ?? false
        }
    }

    /// For callbacks that don't promise the main thread (BuzzKit's foreground
    /// presentation). The system calls them on main; otherwise this waits for it.
    nonisolated static func isShowingFromAnyThread(chat: String?, agent: String?) -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { shared.isShowing(chat: chat, agent: agent) }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { shared.isShowing(chat: chat, agent: agent) } }
    }
}

/// How an alert shows while bighelp is in front.
///
/// Nothing shows for the chat you're looking at, whatever the kind: the reply is on
/// screen, and a question or approval pops up in that chat itself (and is also answered
/// in the chat's own request card), so a banner and a sound would only repeat it.
/// Alerts for other chats show as before.
enum BighelpForegroundAlert {
    /// What the decision reads from the alert, so it can cross to the main actor.
    struct Facts: Equatable, Sendable {
        let chat: String?
        let agent: String?
        /// The chat a bighelp question, approval or retry alert names by its app ID.
        let promptConversationID: String?
        let isPassive: Bool

        init(userInfo: [AnyHashable: Any], thread: String, interruptionLevel: UNNotificationInterruptionLevel) {
            // The chat from the push data; the thread names the agent once the
            // notification extension has grouped it.
            chat = BighelpNotificationGrouping.chat(of: userInfo) ?? (thread.hasPrefix("bighelp") ? nil : thread)
            agent = BighelpNotificationGrouping.agent(of: userInfo)
            if case .chat(let id)? = BighelpPromptAlertLink.url(in: userInfo).flatMap(BighelpIncomingURLRoute.parse) {
                promptConversationID = id
            } else {
                promptConversationID = nil
            }
            isPassive = interruptionLevel == .passive
        }
    }

    @MainActor
    static func options(_ facts: Facts, visible: BighelpVisibleChats = .shared,
                        now: Date = Date()) -> UNNotificationPresentationOptions {
        if visible.isShowing(chat: facts.chat, agent: facts.agent, now: now) { return [] }
        if let id = facts.promptConversationID, visible.conversationIDs.contains(id) { return [] }
        // Helper results and repeats of an alert shown already go to Notification Center only.
        return facts.isPassive ? [.list] : [.banner, .list, .sound]
    }
}
