import Foundation
import UserNotifications

/// Every alert shows here, whether the notification service sent it through BuzzKit or straight to
/// Apple. The work is in `BighelpNotificationProcessor`; bighelp sends no delivery receipts from here.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let processor = BighelpNotificationProcessor()

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        processor.didReceive(request, withContentHandler: contentHandler)
    }

    override func serviceExtensionTimeWillExpire() {
        processor.timeWillExpire()
    }
}
