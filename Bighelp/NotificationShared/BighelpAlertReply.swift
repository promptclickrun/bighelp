import Foundation
import UserNotifications

/// A text field on an alert, the way a messaging app has one: touch and hold the alert, type, send.
/// A reply's alert takes the person's next message; a question's alert takes its answer.
///
/// The phone adds the field itself, from the alert's kind. The push never asks for it, so an app from
/// before this never shows a field whose words it would drop.
enum BighelpAlertReply {
    static let actionID = "bighelp.reply"
    static let openActionID = "open"
    static let replyCategory = "BIGHELP_REPLY"
    static let answerCategory = "BIGHELP_ANSWER"
    static let replyEvent = "session.completed"
    static let questionEvent = "clarification.required"

    /// The category for an alert of this kind about one saved chat, or nil when it takes no words.
    static func categoryID(for userInfo: [AnyHashable: Any]) -> String? {
        guard let loopdy = userInfo["loopdy"] as? [String: Any],
              let reference = loopdy["sessionReference"] as? String, !reference.isEmpty else { return nil }
        switch loopdy["eventType"] as? String {
        case replyEvent: return replyCategory
        case questionEvent: return answerCategory
        default: return nil
        }
    }

    /// Both categories. The words are the person's own, so the phone must be unlocked to send them.
    static var categories: Set<UNNotificationCategory> {
        func category(_ id: String, title: String, placeholder: String) -> UNNotificationCategory {
            UNNotificationCategory(
                identifier: id,
                actions: [
                    UNTextInputNotificationAction(identifier: actionID, title: title, options: [.authenticationRequired],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: placeholder),
                    UNNotificationAction(identifier: openActionID, title: "Open chat", options: [.foreground]),
                ],
                intentIdentifiers: [], options: [.customDismissAction])
        }
        return [category(replyCategory, title: "Reply", placeholder: "Message"),
                category(answerCategory, title: "Answer", placeholder: "Your answer")]
    }

    /// Puts the field on `content` when its alert takes words, registering the categories the first time.
    static func add(to content: UNMutableNotificationContent, categories store: any BighelpNotificationCategoryStore) async {
        guard let id = categoryID(for: content.userInfo) else { return }
        content.categoryIdentifier = id
        let existing = await store.categories()
        let known = Set(existing.map(\.identifier))
        guard !categories.allSatisfy({ known.contains($0.identifier) }) else { return }
        store.setCategories(existing.filter { $0.identifier != replyCategory && $0.identifier != answerCategory }.union(categories))
    }
}
