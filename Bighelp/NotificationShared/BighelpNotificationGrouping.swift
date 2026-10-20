import CryptoKit
import Foundation
import UserNotifications

/// How bighelp's alerts sit in Notification Center without piling up.
///
/// - One stack per agent, not one per chat, so a busy day is a stack or two
///   instead of dozens to clear one at a time.
/// - A chat keeps only its newest reply: the earlier ones are old news once a
///   newer one arrives. Questions and approvals stay until they're dealt with.
/// - A helper (subagent) finishing arrives quietly, in Notification Center only.
/// - Opening a chat clears its alerts, like Messages.
enum BighelpNotificationGrouping {
    /// Kinds a newer alert for the same chat replaces. Not scheduled tasks: each alert is a run's
    /// only copy of its result (the chat it names doesn't show it), and jobs made in one chat share it.
    static let replaceable: Set<String> = [
        "session.completed", "session.failed", "subagent.completed", "subagent.failed",
    ]
    /// Kinds that don't need a banner or sound.
    static let quiet: Set<String> = ["subagent.completed", "subagent.failed"]

    /// The stack an alert goes in: its agent's.
    static func thread(agentName: String?) -> String {
        let name = (agentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, name != "bighelp" else { return "bighelp" }
        let digest = SHA256.hash(data: Data(name.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "bighelp.agent." + digest
    }

    static func apply(to content: UNMutableNotificationContent, eventType: String, agentName: String?) {
        content.threadIdentifier = thread(agentName: agentName)
        if quiet.contains(eventType) {
            content.interruptionLevel = .passive
            content.relevanceScore = 0.2
        } else if eventType == "approval.required" || eventType == "clarification.required" {
            content.relevanceScore = 1
        } else {
            content.relevanceScore = 0.6
        }
    }

    /// The chat an alert belongs to: the push's `loopdy.sessionReference`.
    static func chat(of userInfo: [AnyHashable: Any]) -> String? {
        ((userInfo["loopdy"] as? [String: Any])?["sessionReference"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The agent (profile) an alert is from.
    static func agent(of userInfo: [AnyHashable: Any]) -> String? {
        guard let loopdy = userInfo["loopdy"] as? [String: Any] else { return nil }
        if let id = (loopdy["agent"] as? [String: Any])?["id"] as? String, !id.isEmpty { return id }
        return (loopdy["profile"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func eventType(of userInfo: [AnyHashable: Any]) -> String? {
        (userInfo["loopdy"] as? [String: Any])?["eventType"] as? String
    }

    struct Delivered: Equatable, Sendable {
        let identifier: String
        let chat: String?
        let eventType: String?
    }

    /// Delivered alerts a new one of `eventType` for `chat` makes old news.
    static func superseded(by eventType: String, chat: String, among delivered: [Delivered],
                           except identifier: String) -> [String] {
        guard replaceable.contains(eventType) else { return [] }
        return delivered.filter {
            $0.identifier != identifier && $0.chat == chat && $0.eventType.map(replaceable.contains) == true
        }.map(\.identifier)
    }

    /// Removes a chat's earlier replies once a newer one is on its way.
    static func removeSuperseded(by eventType: String, chat: String, keeping identifier: String) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notes in
                continuation.resume(returning: notes.map {
                    Delivered(identifier: $0.request.identifier, chat: Self.chat(of: $0.request.content.userInfo),
                              eventType: Self.eventType(of: $0.request.content.userInfo))
                })
            }
        }
        let old = superseded(by: eventType, chat: chat, among: delivered, except: identifier)
        if !old.isEmpty { center.removeDeliveredNotifications(withIdentifiers: old) }
    }
}
