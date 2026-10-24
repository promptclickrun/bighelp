import Foundation
import UserNotifications

/// Gives the system one notification, once. The extension's work (opening a sealed alert, a picture)
/// and its time limit race to finish; whichever comes first shows what is ready, and the other finds
/// nothing left to show.
final class BighelpNotificationDelivery: @unchecked Sendable {
    typealias Handler = (UNNotificationContent) -> Void

    private let lock = NSLock()
    private var pending: (handler: Handler, content: UNNotificationContent)?

    /// Keeps what to show if time runs out. Replaces an earlier hold.
    func hold(_ handler: @escaping Handler, _ content: UNNotificationContent) {
        lock.withLock { pending = (handler, content) }
    }

    /// Takes the hold, so nobody shows it again. Nil once it has been shown or taken.
    func take() -> (handler: Handler, content: UNNotificationContent)? {
        lock.withLock {
            defer { pending = nil }
            return pending
        }
    }

    /// Shows what is held, if anything still is.
    func finish() {
        if let held = take() { held.handler(held.content) }
    }
}
