import BuzzKit
import UIKit
import UserNotifications

// Primitive bridging is shared; open and wake acceptance policies stay separate.
private enum BighelpNotificationPayloadValue {
    static func dictionary(_ value: Any?) -> [String: Any]? {
        if let value = value as? [String: Any] { return value }
        guard let value = value as? NSDictionary else { return nil }
        var result: [String: Any] = [:]
        for (key, entry) in value {
            guard let key = key as? String else { return nil }
            result[key] = entry
        }
        return result
    }

    static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        guard let value = value as? NSNumber else { return nil }
        let integer = value.intValue
        return value.doubleValue == Double(integer) ? integer : nil
    }
}

/// Bridges APNs delivery, which can arrive before SwiftUI App composition has
/// installed the required managed-notification hook. Only the latest token is
/// relevant; its exact bytes are replayed once when the hook becomes available.
@MainActor
final class BighelpAPNSTokenHookCenter {
    static let shared = BighelpAPNSTokenHookCenter()

    typealias Handler = @MainActor (Data) -> Void

    private var handler: Handler?
    private var pendingToken: Data?

    func install(_ handler: @escaping Handler) {
        self.handler = handler
        guard let pendingToken else { return }
        self.pendingToken = nil
        handler(Data(pendingToken))
    }

    func receive(_ token: Data) {
        let exactToken = Data(token)
        guard let handler else {
            pendingToken = exactToken
            return
        }
        handler(exactToken)
    }

    typealias FailureHandler = @MainActor (any Error) -> Void

    private var failureHandler: FailureHandler?
    private var pendingFailure: (any Error)?

    /// Mirrors the token hook: an APNs registration failure that arrives before
    /// the managed-notification integration exists is replayed once the
    /// failure hook is installed, so didFailToRegisterForRemoteNotifications
    /// always reaches the bighelp runtime.
    func installFailure(_ handler: @escaping FailureHandler) {
        self.failureHandler = handler
        guard let pendingFailure else { return }
        self.pendingFailure = nil
        handler(pendingFailure)
    }

    func receiveFailure(_ error: any Error) {
        guard let failureHandler else {
            pendingFailure = error
            return
        }
        failureHandler(error)
    }
}

struct BighelpProactiveNotificationRequest: Equatable, Sendable {
    static let categoryIdentifier = "BIGHELP_AGENT_UPDATE"

    let identifier: String
    let title: String
    let body: String
    let threadIdentifier: String
    let categoryIdentifier: String
    let userInfo: [String: String]

    init?(event: BighelpLinkNotificationEvent) {
        guard DashboardEventIntentPolicy.isNotificationSurface(
            eventType: event.eventType,
            message: event.body
        ) else {
            return nil
        }
        identifier = event.eventID
        title = event.title
        body = event.body
        threadIdentifier = event.sessionID ?? "agent:\(event.agentID)"
        categoryIdentifier = Self.categoryIdentifier
        var userInfo = [
            "loopdy_notification_version": "1",
            "loopdy_event_id": event.eventID,
            "loopdy_event_type": event.eventType,
            "loopdy_agent_id": event.agentID,
        ]
        if let sessionID = event.sessionID {
            userInfo["loopdy_session_id"] = sessionID
        }
        self.userInfo = userInfo
    }
}

struct BighelpProactiveNotificationOpen: Equatable, Sendable {
    let eventID: String
    let eventType: String?
    let sessionID: String?
    let agentID: String?
    private(set) var hostGrantID: String? = nil

    init?(userInfo: [String: String]) {
        guard
            userInfo["loopdy_notification_version"] == "1",
            let eventID = userInfo["loopdy_event_id"],
            !eventID.isEmpty,
            eventID.count <= 220,
            userInfo["loopdy_event_type"].map(Self.validEventType) ?? true,
            userInfo["loopdy_agent_id"].map(Self.validAgentID) ?? true
        else { return nil }
        self.eventID = eventID
        eventType = userInfo["loopdy_event_type"]
        sessionID = userInfo["loopdy_session_id"]
        agentID = userInfo["loopdy_agent_id"]
    }

    init?(userInfo: [AnyHashable: Any]) {
        var strings: [String: String] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String, let value = value as? String else { continue }
            strings[key] = value
        }
        if let local = Self(userInfo: strings) {
            self = local
            return
        }
        if let payload = BighelpNotificationPayloadValue.dictionary(userInfo["loopdy"]),
           BighelpNotificationPayloadValue.integer(payload["version"]) == 2,
           let eventID = payload["eventId"] as? String,
           let eventType = payload["eventType"] as? String,
           let grantID = payload["grantId"] as? String,
           Self.validEventType(eventType),
           ManagedNotificationValidation.uuid(grantID),
           eventID.hasPrefix(grantID + ":"),
           eventID.utf8.count == grantID.utf8.count + 65,
           eventID.dropFirst(grantID.count + 1).utf8.allSatisfy({
               (48...57).contains($0) || (97...102).contains($0)
           }) {
            self.eventID = eventID
            self.eventType = eventType
            sessionID = nil
            agentID = BighelpNotificationPayloadValue.dictionary(payload["agent"])?["id"] as? String
            hostGrantID = grantID
            return
        }
        return nil
    }

    private static func validEventType(_ value: String) -> Bool {
        DashboardEventIntentPolicy.supportedEventTypes.contains(value)
            || ManagedNotificationValidation.eventTypes.contains(value)
    }

    private static func validAgentID(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 96
            && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
            }
    }
}

/// The app icon badge means "something arrived while you were away". A push
/// sets it; opening bighelp clears it. The app never sets a count of its own
/// (it used to mirror the Activity inbox, which is now tucked away), so nothing
/// can leave it stuck.
@MainActor
enum BighelpAppBadge {
    static func clear(center: UNUserNotificationCenter = .current()) async {
        try? await center.setBadgeCount(0)
    }
}

@MainActor
final class BighelpProactiveNotificationOpenCenter {
    static let shared = BighelpProactiveNotificationOpenCenter()

    typealias Handler = @MainActor @Sendable (BighelpProactiveNotificationOpen) async -> Void
    private var handler: Handler?
    private var managedHandler: Handler?
    func installManaged(_ handler: @escaping Handler) { managedHandler = handler }
    private var isActive = false
    private var pending: [BighelpProactiveNotificationOpen] = []

    func install(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func activate() async {
        isActive = true
        guard let handler else { return }
        let queued = pending
        pending.removeAll()
        for open in queued { await receive(open) }
    }

    func receive(_ userInfo: [AnyHashable: Any]) async {
        guard let open = BighelpProactiveNotificationOpen(userInfo: userInfo) else { return }
        await receive(open)
    }

    func receive(_ userInfo: [String: String]) async {
        guard let open = BighelpProactiveNotificationOpen(userInfo: userInfo) else { return }
        await receive(open)
    }

    func receive(_ open: BighelpProactiveNotificationOpen) async {
        let selectedHandler = open.hostGrantID == nil ? handler : managedHandler
        guard isActive, let selectedHandler else {
            pending.removeAll { $0.eventID == open.eventID }
            pending.append(open)
            if pending.count > 16 { pending.removeFirst(pending.count - 16) }
            return
        }
        await selectedHandler(open)
    }
}

enum BighelpBuzzKitWakePayload {
    static func isWake(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard
            let aps = BighelpNotificationPayloadValue.dictionary(userInfo["aps"]),
            BighelpNotificationPayloadValue.integer(aps["content-available"]) == 1,
            aps["alert"] == nil,
            let marker = BighelpNotificationPayloadValue.dictionary(userInfo["loopdy_link"]),
            BighelpNotificationPayloadValue.integer(marker["version"]) == 2,
            marker["type"] as? String == "wake",
            let frameID = marker["frameId"] as? String,
            frameID.range(of: "^[A-Za-z0-9_-]{16,128}$", options: .regularExpression) != nil
        else { return false }
        return true
    }
}

/// The quiet push the host's plugin sends every few hours so the phone renews its
/// sign-in while bighelp is closed. It carries nothing but what it asks for.
enum BighelpSignInWake {
    static func isRenewal(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let aps = BighelpNotificationPayloadValue.dictionary(userInfo["aps"]),
              BighelpNotificationPayloadValue.integer(aps["content-available"]) == 1,
              aps["alert"] == nil,
              let wake = BighelpNotificationPayloadValue.dictionary(userInfo["bighelp_wake"]),
              BighelpNotificationPayloadValue.integer(wake["version"]) == 1,
              wake["type"] as? String == "renew-sign-in" else { return false }
        return true
    }
}

@MainActor
final class BighelpLinkWakeCenter {
    static let shared = BighelpLinkWakeCenter()

    typealias Handler = @MainActor @Sendable () async throws -> Bool
    private var handler: Handler?

    func install(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func receive(_ userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard BighelpBuzzKitWakePayload.isWake(userInfo) || BighelpSignInWake.isRenewal(userInfo) else { return .noData }
        guard let handler else { return .failed }
        do {
            return try await handler() ? .newData : .noData
        } catch {
            return .failed
        }
    }
}

@MainActor
final class BighelpLinkApplicationDelegate: NSObject, UIApplicationDelegate,
    UNUserNotificationCenterDelegate
{
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: BighelpProactiveNotificationRequest.categoryIdentifier,
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
        ])
        // Configure only after bighelp installs its delegate so BuzzKit captures and
        // forwards to it. Missing injected configuration remains a truthful state.
        _ = BighelpBuzzKitRuntime.shared.configureIfPossible()
        #if targetEnvironment(macCatalyst)
        BighelpMacUpdates.shared.start()
        #endif
        return true
    }

    // UIKit wants both answers below on the main thread. The async forms of
    // these methods answered from wherever their work finished, and clearing
    // a notification (which wakes the app in the background) then aborted it.

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        // The chat from the push data; the thread names the agent once the
        // notification extension has grouped it.
        let chat = BighelpNotificationGrouping.chat(of: content.userInfo)
            ?? (content.threadIdentifier.hasPrefix("bighelp") ? nil : content.threadIdentifier)
        let agent = BighelpNotificationGrouping.agent(of: content.userInfo)
        Task { @MainActor in
            // Stay quiet for the chat you're already looking at; the reply is on screen.
            let showing = BighelpVisibleChats.shared.isShowing(chat: chat, agent: agent)
            completionHandler(showing ? [] : [.banner, .list, .sound])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        // A question or approval alert opens its chat, where the request pops up.
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let url = BighelpPromptAlertLink.url(in: response.notification.request.content.userInfo) {
            Task { @MainActor in
                completionHandler()
                await UIApplication.shared.open(url)
            }
            return
        }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        // "Open on iPhone" from the Watch carries one of bighelp's own links.
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let url = WatchOpenRequest.url(in: response.notification.request.content.userInfo) {
            Task { @MainActor in
                completionHandler()
                await UIApplication.shared.open(url)
            }
            return
        }
        #endif
        Self.respond(
            to: BighelpProactiveNotificationOpen(userInfo: response.notification.request.content.userInfo),
            dismissed: response.actionIdentifier == UNNotificationDismissActionIdentifier,
            completion: completionHandler
        )
    }

    /// Answers iOS on the main thread right away; a tap's chat opens after.
    /// Clearing a notification isn't opening it.
    nonisolated static func respond(to open: BighelpProactiveNotificationOpen?, dismissed: Bool,
                                    completion: @escaping @Sendable () -> Void) {
        Task { @MainActor in
            if let open, !dismissed {
                Task { await BighelpProactiveNotificationOpenCenter.shared.receive(open) }
            }
            completion()
        }
    }

    nonisolated func receiveNotificationTap(userInfo: [AnyHashable: Any]) async {
        guard let open = BighelpProactiveNotificationOpen(userInfo: userInfo) else { return }
        await BighelpProactiveNotificationOpenCenter.shared.receive(open)
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let exactToken = Data(deviceToken)
        BighelpAPNSTokenHookCenter.shared.receive(exactToken)
        BuzzKit.didRegisterForRemoteNotifications(deviceToken: exactToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        BuzzKit.didFailToRegisterForRemoteNotifications(error: error)
        // Inform the bighelp runtime as well: it wakes any in-flight APNs token
        // wait with the real failure instead of letting it time out.
        BighelpAPNSTokenHookCenter.shared.receiveFailure(error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let link = await BighelpLinkWakeCenter.shared.receive(userInfo)
            let data = try? JSONSerialization.data(withJSONObject: userInfo)
            let buzzKit = await Self.receiveBuzzKit(data: data)
            completionHandler(Self.mergeFetchResults(link, buzzKit))
        }
    }

    private nonisolated static func receiveBuzzKit(data: Data?) async -> UIBackgroundFetchResult {
        guard let data,
              let userInfo = try? JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any] else { return .failed }
        switch await BuzzKit.didReceiveRemoteNotification(userInfo: userInfo) {
        case .newData: return .newData
        case .noData: return .noData
        @unknown default: return .noData
        }
    }

    private static func mergeFetchResults(
        _ first: UIBackgroundFetchResult,
        _ second: UIBackgroundFetchResult
    ) -> UIBackgroundFetchResult {
        if first == .failed || second == .failed { return .failed }
        if first == .newData || second == .newData { return .newData }
        return .noData
    }
}
