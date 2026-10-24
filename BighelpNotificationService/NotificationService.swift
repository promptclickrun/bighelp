@_spi(BuzzKitInternal) import BuzzKit
import Foundation
import UserNotifications

/// Every alert shows here, whether the notification service sent it through BuzzKit or straight to
/// Apple. The work is in `BighelpNotificationProcessor`. For this release a push BuzzKit delivered also
/// gets BuzzKit's delivered receipt, as before; a push sent straight to Apple has no message ID and gets none.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private static let buzzKitAppGroup = "group.app.loopdy.mobile.buzzkit"

    private let processor = BighelpNotificationProcessor(services: .live(receipt: { messageID in
        await BuzzKitExtensionSupport.trackDelivered(messageId: messageID, appGroup: NotificationService.buzzKitAppGroup)
    }))

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        processor.didReceive(request, withContentHandler: contentHandler)
    }

    override func serviceExtensionTimeWillExpire() {
        processor.timeWillExpire()
    }
}
