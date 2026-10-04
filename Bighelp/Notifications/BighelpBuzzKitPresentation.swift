import BuzzKit
import UserNotifications

/// BuzzKit, not the app's notification delegate, decides how its pushes show
/// while bighelp is open and where their links go when tapped. This keeps an
/// alert for the chat you're looking at quiet, like Messages. Unsealed alerts
/// carry the chat as `sessionReference`; the notification extension adds it to
/// sealed ones after opening them.
final class BighelpBuzzKitPresentation: BuzzKitDelegate {
    static let shared = BighelpBuzzKitPresentation()

    func buzzKit(_ buzzKit: BuzzKit, willPresent payload: PushPayload) -> UNNotificationPresentationOptions? {
        // Nothing for the chat you're looking at: not a banner, not a sound.
        if BighelpVisibleChats.isShowingFromAnyThread(chat: Self.thread(payload.data), agent: Self.agent(payload.data)) {
            return []
        }
        // bighelp was open and showed this alert straight from the host: the push
        // takes that copy's place in Notification Center, without a second banner.
        if let eventID = Self.eventID(payload.data), BighelpRecentAlerts.shared.contains(eventID) {
            return [.list]
        }
        // bighelp already raised this question or approval itself (BighelpPromptAlerts).
        if let eventType = Self.eventType(payload.data),
           ["approval.required", "clarification.required"].contains(eventType),
           BighelpPromptAlerts.alertedRecentlyFromAnyThread(eventType: eventType) {
            return [.list]
        }
        return nil
    }

    /// The agent (profile) an alert is from: sealed alerts carry only its id.
    static func agent(_ data: [String: JSONValue]) -> String? {
        guard case .object(let loopdy)? = data["loopdy"] else { return nil }
        if case .object(let agent)? = loopdy["agent"], case .string(let id)? = agent["id"], !id.isEmpty { return id }
        if case .string(let profile)? = loopdy["profile"], !profile.isEmpty { return profile }
        return nil
    }

    static func eventID(_ data: [String: JSONValue]) -> String? {
        guard case .object(let loopdy)? = data["loopdy"],
              case .string(let eventID)? = loopdy["eventId"], !eventID.isEmpty else { return nil }
        return eventID
    }

    static func eventType(_ data: [String: JSONValue]) -> String? {
        guard case .object(let loopdy)? = data["loopdy"],
              case .string(let eventType)? = loopdy["eventType"] else { return nil }
        return eventType
    }

    /// Alerts carry `loopdy:///dashboard?eventId=…`, which used to open the
    /// Activity inbox. The app's own tap handler (BuzzKit forwards the tap)
    /// opens the alert's chat, so this link is claimed and goes nowhere.
    func buzzKit(_ buzzKit: BuzzKit, openDeepLink url: URL) -> Bool {
        Self.isManagedEventLink(url)
    }

    static func isManagedEventLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "loopdy" && BighelpIncomingURLRoute.parse(url) == .home
            && URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains { $0.name == "eventId" && !($0.value ?? "").isEmpty } == true
    }

    static func thread(_ data: [String: JSONValue]) -> String? {
        guard case .object(let loopdy)? = data["loopdy"],
              case .string(let thread)? = loopdy["sessionReference"], !thread.isEmpty else { return nil }
        return thread
    }
}
