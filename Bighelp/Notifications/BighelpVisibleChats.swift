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
        init(_ model: ChatModel) { self.model = model }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func appeared(_ model: ChatModel) {
        entries[ObjectIdentifier(model)] = Entry(model)
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

    nonisolated static func removeDelivered(chats: Set<String>, conversations: Set<String>) async {
        let center = UNUserNotificationCenter.current()
        let read = await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notes in
                continuation.resume(returning: notes.filter { note in
                    let content = note.request.content
                    if let chat = BighelpNotificationGrouping.chat(of: content.userInfo) { return chats.contains(chat) }
                    if case .chat(let id)? = BighelpPromptAlertLink.url(in: content.userInfo)
                        .flatMap(BighelpIncomingURLRoute.parse) { return conversations.contains(id) }
                    return chats.contains(content.threadIdentifier)
                }.map(\.request.identifier))
            }
        }
        if !read.isEmpty { center.removeDeliveredNotifications(withIdentifiers: read) }
    }

    func disappeared(_ model: ChatModel) {
        entries[ObjectIdentifier(model)] = nil
    }

    /// Notification thread identifiers of the visible chats. Hosts send each
    /// alert with `thread-id` = sessionReference(profile, stored session).
    var threadIdentifiers: Set<String> {
        Set(entries.values.compactMap { entry in
            guard let native = entry.model?.nativeConversationClient else { return nil }
            return ManagedNotificationValidation.sessionReference(profile: native.profile, session: native.storedID)
        })
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
    ///   arrived with). When it has one, only that chat counts.
    /// - `agent`: the agent it's from. An alert without a chat reference (one the
    ///   phone couldn't open, say) is about the chat on screen when that chat is
    ///   the same agent's and its turn is running or just ended.
    func isShowing(chat: String?, agent: String?, now: Date = Date()) -> Bool {
        if let chat, !chat.isEmpty { return threadIdentifiers.contains(chat) }
        guard let agent, !agent.isEmpty else { return false }
        return entries.values.contains { entry in
            guard let model = entry.model, let native = model.nativeConversationClient,
                  native.profile == agent else { return false }
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
