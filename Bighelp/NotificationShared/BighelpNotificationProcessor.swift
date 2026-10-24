import Foundation
import UserNotifications

/// What the notification service extension does with each push, apart from the extension class itself so
/// tests can run it with fakes: open a sealed alert, stack it with its agent's, add its picture and action
/// buttons, and hand the system exactly one notification before time runs out.
///
/// The same code shows pushes sent through BuzzKit and pushes sent straight to Apple.
final class BighelpNotificationProcessor: @unchecked Sendable {
    /// Everything that touches the phone or the clock, so tests can replace it.
    struct Services: @unchecked Sendable {
        /// The title and text of a sealed alert, if this phone can read it.
        var open: @Sendable (BighelpSealedNotification) -> BighelpSealedAlert.Content?
        /// The sealed alert's picture as a file: from the phone's cache or downloaded.
        var avatar: @Sendable (BighelpSealedNotification, BighelpSealedAlert.Content) async -> URL?
        /// bighelp was open and showed this alert straight from the host already.
        var alreadyShown: @Sendable (String) -> Bool
        /// Removes the chat's earlier replies. Takes the content, event type, event ID and this request's ID.
        var clearOlder: @Sendable (UNNotificationContent, String, String, String) async -> Void
        /// Tells BuzzKit a push it sent has been delivered. Only called for pushes that carry its message ID.
        var receipt: @Sendable (String) async -> Void
        var categories: any BighelpNotificationCategoryStore
        var download: BighelpPushDisplay.Download
        /// How long a first avatar download may hold the alert back.
        var avatarWait: Duration

        /// `receipt` is BuzzKit's delivered receipt; the app doesn't send one.
        static func live(receipt: @escaping @Sendable (String) async -> Void = { _ in }) -> Self {
            Self(open: { try? $0.open() },
                 avatar: { await $0.avatarFile(for: $1) },
                 alreadyShown: { BighelpRecentAlerts.shared.contains($0) },
                 clearOlder: { content, eventType, eventID, identifier in
                     await BighelpSealedAlertPresentation.clearOlder(for: content, eventType: eventType,
                                                                     eventID: eventID, keeping: identifier)
                 },
                 receipt: receipt,
                 categories: UNUserNotificationCenter.current(),
                 download: BighelpPushDisplay.download,
                 avatarWait: .milliseconds(1500))
        }
    }

    private let services: Services
    private let delivery = BighelpNotificationDelivery()

    init(services: Services = .live()) { self.services = services }

    /// The message ID BuzzKit gave a push it delivered. A push sent straight to Apple has none.
    static func messageID(in userInfo: [AnyHashable: Any]) -> String? {
        let bk = userInfo["bk"] as? [String: Any] ?? [:]
        return bk["messageId"] as? String ?? userInfo["messageId"] as? String
    }

    /// Shows `request` through `contentHandler`, once.
    func didReceive(_ request: UNNotificationRequest,
                    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        // BuzzKit's receipt for a push it delivered goes out beside the work and never holds it back.
        if let messageID = Self.messageID(in: request.content.userInfo) {
            let receipt = services.receipt
            Task { await receipt(messageID) }
        }
        // Anything that isn't a sealed alert, or can't be opened, shows as sent,
        // in its agent's stack (unsealed alerts are titled with the agent's name).
        guard let sealed = BighelpSealedNotification(userInfo: request.content.userInfo),
              let opened = services.open(sealed),
              let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            display(Self.grouped(request), contentHandler)
            return
        }
        // The app keeps alerts for the chat on screen quiet by reading the chat from
        // the push data. Older services send it only as the thread.
        BighelpSealedAlertPresentation.apply(opened, eventType: sealed.eventType, to: content,
                                             arrivedThread: request.content.threadIdentifier)
        let eventID = sealed.envelope.eventID
        // bighelp was open and showed this one straight from the host already.
        if services.alreadyShown(eventID) {
            BighelpSealedAlertPresentation.quietRepeat(content)
        }
        // A Focus filter with Quiet agent alerts on: replies arrive in Notification Center only.
        BighelpFocusFilterState.quiet(content, eventType: sealed.eventType)
        delivery.hold(contentHandler, content.copy() as? UNNotificationContent ?? content)
        let box = UncheckedBox((request: request, content: content))
        // The picture comes from the phone's cache after the first alert. A first
        // download still running after a moment finishes in the background for
        // next time; the alert doesn't wait for it.
        let services = self.services
        let avatar = Task { await services.avatar(sealed, opened) }
        let eventType = sealed.eventType
        let identifier = request.identifier
        Task {
            // This chat's earlier replies are old news now.
            await services.clearOlder(box.value.content, eventType, eventID, identifier)
            if let file = await Self.value(of: avatar, within: services.avatarWait),
               let attachment = try? UNNotificationAttachment(identifier: BighelpPushDisplay.imageIdentifier, url: file) {
                box.value.content.attachments = [attachment]
            }
            // The same hold carries on into the display stage, so there is no moment when time running
            // out could find nothing to show.
            guard self.delivery.replace(content: box.value.content) else { return }
            await self.addButtonsAndPicture(box.value.content)
        }
    }

    /// Out of time before a picture arrived: shows what is ready.
    func timeWillExpire() {
        delivery.finish()
    }

    /// An alert that isn't sealed, placed in its agent's stack.
    static func grouped(_ request: UNNotificationRequest) -> UNNotificationRequest {
        guard let eventType = BighelpNotificationGrouping.eventType(of: request.content.userInfo),
              let content = request.content.mutableCopy() as? UNMutableNotificationContent else { return request }
        // The thread is about to name the agent; keep the chat where the app reads it.
        if !request.content.threadIdentifier.isEmpty, var loopdy = content.userInfo["loopdy"] as? [String: Any],
           loopdy["sessionReference"] == nil {
            loopdy["sessionReference"] = request.content.threadIdentifier
            var userInfo = content.userInfo
            userInfo["loopdy"] = loopdy
            content.userInfo = userInfo
        }
        BighelpNotificationGrouping.apply(to: content, eventType: eventType, agentName: content.title)
        BighelpFocusFilterState.quiet(content, eventType: eventType)
        return UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil)
    }

    /// Holds `request`'s content, adds the push's action buttons and picture, then shows it.
    private func display(_ request: UNNotificationRequest, _ handler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            handler(request.content)
            return
        }
        delivery.hold(handler, content)
        let box = UncheckedBox(content)
        Task { await self.addButtonsAndPicture(box.value) }
    }

    private func addButtonsAndPicture(_ content: UNMutableNotificationContent) async {
        if let display = BighelpPushDisplay(userInfo: content.userInfo) {
            await display.apply(to: content, categories: services.categories, download: services.download)
        }
        delivery.finish()
    }

    /// The task's value, or nil once `limit` passes (the task keeps running).
    private static func value(of task: Task<URL?, Never>, within limit: Duration) async -> URL? {
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            Task { once.resume(await task.value) }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(nil)
            }
        }
    }
}

/// Resumes a continuation with whichever value arrives first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL?, Never>?

    func set(_ continuation: CheckedContinuation<URL?, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ value: URL?) {
        let pending = lock.withLock { () -> CheckedContinuation<URL?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

private final class UncheckedBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
