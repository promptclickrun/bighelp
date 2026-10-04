import Foundation
import UserNotifications

/// What an opened sealed alert shows. Pushes (the notification extension) and
/// instant alerts (the app, while it's open) both come through here, so they read,
/// stack, ring and open the same way, and a chat keeps only its newest reply.
enum BighelpSealedAlertPresentation {
    /// Fills in the opened title and text, keeps the chat where the app reads it,
    /// and puts the alert in its agent's stack. `arrivedThread` is the push's
    /// thread: older services send the chat only there. Instant alerts have none.
    static func apply(_ opened: BighelpSealedAlert.Content, eventType: String,
                      to content: UNMutableNotificationContent, arrivedThread: String) {
        content.title = opened.title
        content.body = opened.body
        if !arrivedThread.isEmpty, var loopdy = content.userInfo["loopdy"] as? [String: Any],
           (loopdy["sessionReference"] as? String)?.isEmpty ?? true {
            loopdy["sessionReference"] = arrivedThread
            var userInfo = content.userInfo
            userInfo["loopdy"] = loopdy
            content.userInfo = userInfo
        }
        BighelpNotificationGrouping.apply(to: content, eventType: eventType, agentName: opened.title)
    }

    /// A push of an alert this device already showed straight from the host: it
    /// takes the first copy's place in Notification Center without a banner or sound.
    static func quietRepeat(_ content: UNMutableNotificationContent) {
        content.interruptionLevel = .passive
        content.sound = nil
    }

    /// Makes room for a new alert: its chat's earlier replies are old news, and a
    /// copy of the same alert shown straight from the host (whose identifier is the
    /// event ID) gives way to the pushed one.
    static func clearOlder(for content: UNNotificationContent, eventType: String, eventID: String,
                           keeping identifier: String) async {
        if let chat = BighelpNotificationGrouping.chat(of: content.userInfo) {
            await BighelpNotificationGrouping.removeSuperseded(by: eventType, chat: chat, keeping: identifier)
        }
        if identifier != eventID {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [eventID])
        }
    }
}
