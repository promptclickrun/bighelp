import CryptoKit
import Foundation
import UIKit
import UserNotifications

/// A question or approval that arrives while its chat isn't on screen gets an
/// alert, and tapping it opens that chat, where the request pops up. The app
/// raises its own while it's connected (in the app, and for a short while
/// after you leave it) because the plugin's pushes need notifications set up
/// for this host, and older plugins never pushed questions from bighelp chats.
@MainActor
final class BighelpPromptAlerts {
    static let shared = BighelpPromptAlerts()

    struct Arrival: Equatable, Sendable {
        let key: String
        let conversationID: String
        let isApproval: Bool
        let agentName: String?
        let detail: String
    }

    private var ledger = BighelpPromptAlertLedger()
    private let startedAt = Date()
    /// When bighelp last raised each kind itself, by the plugin's event type.
    private var lastAlerts: [String: Date] = [:]
    private var questionsAndApprovals: (enabled: Bool, checkedAt: Date)?
    private var preferenceCheck: Task<Void, Never>?

    func receive(_ prompts: [DirectHermesPrompt], agentName: (String) -> String?) {
        let fresh = ledger.arrivals(prompts.map(\.attentionKey))
        // What's already waiting as bighelp opens shows on Home; alert for new arrivals.
        guard !fresh.isEmpty, Date().timeIntervalSince(startedAt) > 10 else { return }
        let visible = BighelpVisibleChats.shared.conversationIDs
        let isActive = UIApplication.shared.applicationState == .active
        for prompt in prompts where fresh.contains(prompt.attentionKey)
            && BighelpPromptAlertLedger.needsAlert(conversationID: prompt.visibleSessionID,
                                                   visibleChats: visible, appIsActive: isActive) {
            let arrival = Arrival(key: prompt.attentionKey, conversationID: prompt.visibleSessionID,
                                  isApproval: prompt.kind == .approval,
                                  agentName: agentName(prompt.profile), detail: prompt.detail)
            Task { await post(arrival) }
        }
    }

    /// The plugin's own alert of the same kind, arriving just after ours, only
    /// goes to Notification Center.
    func alertedRecently(eventType: String) -> Bool {
        lastAlerts[eventType].map { Date().timeIntervalSince($0) < 120 } ?? false
    }

    /// For BuzzKit's foreground presentation, which doesn't promise the main thread.
    nonisolated static func alertedRecentlyFromAnyThread(eventType: String) -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { shared.alertedRecently(eventType: eventType) }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { shared.alertedRecently(eventType: eventType) } }
    }

    /// Settings › Notifications › Questions and approvals applies here too.
    func questionsAndApprovalsChanged(enabled: Bool) {
        questionsAndApprovals = (enabled, Date())
    }

    private func post(_ arrival: Arrival) async {
        guard questionsAndApprovalsEnabled() else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
        let eventType = arrival.isApproval ? "approval.required" : "clarification.required"
        if await Self.pluginAlerted(eventType: eventType) { return }
        let content = UNMutableNotificationContent()
        let name = arrival.agentName ?? "Your agent"
        content.title = arrival.isApproval ? "\(name) needs your OK" : "\(name) has a question"
        content.body = String(arrival.detail.prefix(400))
        content.sound = .default
        content.interruptionLevel = .active
        // In the agent's stack, with its replies from the plugin.
        content.threadIdentifier = BighelpNotificationGrouping.thread(agentName: arrival.agentName)
        content.relevanceScore = 1
        if let link = BighelpPromptAlertLink.url(conversationID: arrival.conversationID) {
            content.userInfo = [BighelpPromptAlertLink.userInfoKey: link.absoluteString]
        }
        do {
            let digest = SHA256.hash(data: Data(arrival.key.utf8)).map { String(format: "%02x", $0) }.joined()
            try await center.add(UNNotificationRequest(identifier: "bighelp.prompt." + digest,
                                                       content: content, trigger: nil))
            lastAlerts[eventType] = Date()
        } catch {
            // An alert is a convenience; the request still waits in the chat and on Home.
        }
    }

    /// The last known choice. It's fetched in the background, and until it's
    /// known the alert goes out, like the plugin's default.
    private func questionsAndApprovalsEnabled() -> Bool {
        let stale = questionsAndApprovals.map { Date().timeIntervalSince($0.checkedAt) > 600 } ?? true
        if stale, preferenceCheck == nil {
            preferenceCheck = Task { [weak self] in
                let preferences = try? await BighelpBuzzKitPreferencesClient().load()
                let topic = preferences?.first { $0.id == BighelpBuzzKitTopic.questionsAndApprovals.rawValue }
                guard let self else { return }
                if let topic { self.questionsAndApprovals = (topic.enabled, Date()) }
                self.preferenceCheck = nil
            }
        }
        return questionsAndApprovals?.enabled ?? true
    }

    private nonisolated static func pluginAlerted(eventType: String) async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { notes in
                let now = Date()
                continuation.resume(returning: notes.contains { note in
                    now.timeIntervalSince(note.date) < 120
                        && BighelpProactiveNotificationOpen(userInfo: note.request.content.userInfo)?.eventType
                            == eventType
                })
            }
        }
    }
}

/// Each question or approval gets one alert, and only when its chat isn't on
/// screen or bighelp isn't in front.
struct BighelpPromptAlertLedger: Equatable {
    private(set) var seen: [String] = []
    private static let limit = 128

    /// The keys not seen before, now remembered.
    mutating func arrivals(_ keys: [String]) -> Set<String> {
        var fresh: [String] = []
        for key in keys where !seen.contains(key) && !fresh.contains(key) { fresh.append(key) }
        seen.append(contentsOf: fresh)
        if seen.count > Self.limit { seen.removeFirst(seen.count - Self.limit) }
        return Set(fresh)
    }

    static func needsAlert(conversationID: String, visibleChats: Set<String>, appIsActive: Bool) -> Bool {
        !appIsActive || !visibleChats.contains(conversationID)
    }
}

/// The chat a question or approval alert opens.
enum BighelpPromptAlertLink {
    static let userInfoKey = "bighelp_prompt_chat_url"

    static func url(conversationID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "loopdy"
        components.host = "chat"
        components.path = "/" + conversationID
        guard let url = components.url,
              BighelpIncomingURLRoute.parse(url) == .chat(sessionID: conversationID) else { return nil }
        return url
    }

    static func url(in userInfo: [AnyHashable: Any]) -> URL? {
        guard let string = userInfo[userInfoKey] as? String, let url = URL(string: string),
              case .chat? = BighelpIncomingURLRoute.parse(url) else { return nil }
        return url
    }
}
