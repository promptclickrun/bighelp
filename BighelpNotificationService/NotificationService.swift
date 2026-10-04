import BuzzKitNotificationServiceExtension
import Foundation
import UserNotifications

/// BuzzKit owns rich notification media and receipts. Sealed bighelp alerts are
/// opened here first: only this phone can read their title, text and avatar.
final class NotificationService: BuzzKitNotificationService, @unchecked Sendable {
    override var buzzKitAppGroup: String? { "group.app.loopdy.mobile.buzzkit" }

    private let lock = NSLock()
    private var pending: (handler: (UNNotificationContent) -> Void, content: UNNotificationContent)?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        // Anything that isn't a sealed alert, or can't be opened, shows as sent,
        // in its agent's stack (unsealed alerts are titled with the agent's name).
        guard let sealed = BighelpSealedNotification(userInfo: request.content.userInfo),
              let opened = try? sealed.open(),
              let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            super.didReceive(Self.grouped(request), withContentHandler: contentHandler)
            return
        }
        // The app keeps alerts for the chat on screen quiet by reading the chat from
        // the push data. Older services send it only as the thread.
        BighelpSealedAlertPresentation.apply(opened, eventType: sealed.eventType, to: content,
                                             arrivedThread: request.content.threadIdentifier)
        let eventID = sealed.envelope.eventID
        // bighelp was open and showed this one straight from the host already.
        if BighelpRecentAlerts.shared.contains(eventID) {
            BighelpSealedAlertPresentation.quietRepeat(content)
        }
        setPending((contentHandler, content.copy() as? UNNotificationContent ?? content))
        let box = UncheckedBox((request: request, content: content))
        // The picture comes from the phone's cache after the first alert. A first
        // download still running after a moment finishes in the background for
        // next time; the alert doesn't wait for it.
        let avatar = Task { await sealed.avatarFile(for: opened) }
        let eventType = sealed.eventType
        let identifier = request.identifier
        Task {
            // This chat's earlier replies are old news now.
            await BighelpSealedAlertPresentation.clearOlder(for: box.value.content, eventType: eventType,
                                                            eventID: eventID, keeping: identifier)
            if let file = await Self.value(of: avatar, within: .milliseconds(1500)),
               let attachment = try? UNNotificationAttachment(identifier: "bk.image", url: file) {
                box.value.content.attachments = [attachment]
            }
            guard let handler = self.takePending()?.handler else { return }
            self.forward(UNNotificationRequest(identifier: box.value.request.identifier,
                                               content: box.value.content, trigger: nil), handler)
        }
    }

    /// An alert that isn't sealed, placed in its agent's stack.
    private static func grouped(_ request: UNNotificationRequest) -> UNNotificationRequest {
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
        return UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil)
    }

    override func serviceExtensionTimeWillExpire() {
        // Out of time before the avatar arrived: show the opened text without it.
        if let pending = takePending() { pending.handler(pending.content) }
        super.serviceExtensionTimeWillExpire()
    }

    /// BuzzKit then registers the actions and sends the delivered receipt.
    private func forward(_ request: UNNotificationRequest, _ handler: @escaping (UNNotificationContent) -> Void) {
        super.didReceive(request, withContentHandler: handler)
    }

    private func setPending(_ value: (handler: (UNNotificationContent) -> Void, content: UNNotificationContent)) {
        lock.withLock { pending = value }
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

    private func takePending() -> (handler: (UNNotificationContent) -> Void, content: UNNotificationContent)? {
        lock.withLock {
            defer { pending = nil }
            return pending
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
