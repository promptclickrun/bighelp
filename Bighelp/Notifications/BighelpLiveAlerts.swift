import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// One alert a host gave this device straight away, while bighelp is open: the
/// same sealed alert its push would carry (the plugin's `native-live-alerts-v1`).
struct BighelpLiveAlert: Equatable, Sendable {
    let grantID: String
    let agentID: String
    let eventID: String
    let eventType: String
    let sessionReference: String
    let sealed: [String: BighelpJSONValue]
    /// The encrypted agent picture, when the host sent it along.
    let inlineAvatar: Data?

    static let maximumInlineAvatarBytes = 1_048_576

    init?(_ value: BighelpJSONValue) {
        guard let object = value.object,
              let grantID = object["grantId"]?.string, ManagedNotificationValidation.uuid(grantID),
              let eventID = object["eventId"]?.string, eventID.hasPrefix(grantID + ":"),
              eventID.utf8.count == grantID.utf8.count + 65,
              eventID.utf8.suffix(64).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let eventType = object["eventType"]?.string, ManagedNotificationValidation.eventTypes.contains(eventType),
              let agentID = object["agentId"]?.string, ManagedNotificationValidation.profile(agentID),
              let reference = object["sessionReference"]?.string,
              reference.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              let sealed = object["sealed"]?.object, sealed["eventId"]?.string == eventID,
              sealed["grantId"]?.string == grantID
        else { return nil }
        var avatar: Data?
        if let data = object["avatar"]?.object?["data"]?.string {
            let prefix = "data:application/octet-stream;base64,"
            guard data.hasPrefix(prefix), data.utf8.count <= Self.maximumInlineAvatarBytes * 4 / 3 + 64,
                  let decoded = Data(base64Encoded: String(data.dropFirst(prefix.count))) else { return nil }
            avatar = decoded
        }
        self.grantID = grantID
        self.agentID = agentID
        self.eventID = eventID
        self.eventType = eventType
        sessionReference = reference
        self.sealed = sealed
        inlineAvatar = avatar
    }

    /// The push's own data, so taps, stacks and the chat-on-screen check read both alike.
    var userInfo: [AnyHashable: Any] {
        ["loopdy": [
            "version": 2, "eventId": eventID, "eventType": eventType, "grantId": grantID,
            "agent": ["id": agentID], "sessionReference": sessionReference,
            "sealed": Self.foundation(.object(sealed)),
        ] as [String: Any]]
    }

    private static func foundation(_ value: BighelpJSONValue) -> Any {
        switch value {
        case .string(let value): value
        case .integer(let value): value
        case .number(let value): value
        case .boolean(let value): value
        case .object(let value): value.mapValues(foundation)
        case .array(let value): value.map(foundation)
        case .null: NSNull()
        }
    }
}

/// Shows an instant alert the way its push would show, or decides not to.
@MainActor
struct BighelpLiveAlertPresenter {
    enum Outcome: Equatable, Sendable {
        /// On screen as a banner, or in Notification Center.
        case shown
        /// Not shown on purpose: its chat is on screen, its kind is turned off, or
        /// it was shown already. The host still hears back, so no push follows.
        case kept
        /// Couldn't be opened or shown. The host hears nothing and pushes it.
        case failed
    }

    var recent = BighelpRecentAlerts.shared
    var open: (BighelpSealedNotification) throws -> BighelpSealedAlert.Content = { try $0.open() }
    var isShowing: @MainActor (_ chat: String?, _ agent: String?) -> Bool = {
        BighelpVisibleChats.shared.isShowing(chat: $0, agent: $1)
    }
    var appIsActive: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
    var kindIsOn: @MainActor (_ eventType: String) -> Bool = { _ in true }
    var promptAlreadyRaised: @MainActor (_ eventType: String) -> Bool = {
        BighelpPromptAlerts.shared.alertedRecently(eventType: $0)
    }
    var avatarFile: (BighelpSealedNotification, BighelpSealedAlert.Content) async -> URL? = {
        await $0.avatarFile(for: $1)
    }
    var clearOlder: (UNNotificationContent, _ eventType: String, _ eventID: String) async -> Void = {
        await BighelpSealedAlertPresentation.clearOlder(for: $0, eventType: $1, eventID: $2, keeping: $2)
    }
    var post: (UNNotificationRequest) async throws -> Void = { try await UNUserNotificationCenter.current().add($0) }

    func present(_ alert: BighelpLiveAlert) async -> Outcome {
        guard var sealed = BighelpSealedNotification(userInfo: alert.userInfo),
              let opened = try? open(sealed) else { return .failed }
        sealed.inlineAvatar = alert.inlineAvatar
        guard kindIsOn(alert.eventType) else { return .kept }
        // The chat you're looking at shows it already, like Messages. The phone
        // decides this; the host never learns which chat is on screen.
        if false, appIsActive(), isShowing(alert.sessionReference, alert.agentID) {
            recent.insert(alert.eventID)
            return .kept
        }
        let content = UNMutableNotificationContent()
        content.userInfo = alert.userInfo
        content.sound = .default
        BighelpSealedAlertPresentation.apply(opened, eventType: alert.eventType, to: content, arrivedThread: "")
        // bighelp raised this question or approval itself (BighelpPromptAlerts).
        if ["approval.required", "clarification.required"].contains(alert.eventType),
           promptAlreadyRaised(alert.eventType) {
            BighelpSealedAlertPresentation.quietRepeat(content)
        }
        await clearOlder(content, alert.eventType, alert.eventID)
        if let file = await avatarFile(sealed, opened),
           let attachment = try? UNNotificationAttachment(identifier: "bk.image", url: file) {
            content.attachments = [attachment]
        }
        do {
            // The event ID names both copies, so a late push of it takes this one's place.
            try await post(UNNotificationRequest(identifier: alert.eventID, content: content, trigger: nil))
        } catch {
            return .failed
        }
        recent.insert(alert.eventID)
        return .shown
    }
}

/// While bighelp is open, holds a long request on the computer it's connected to
/// for this device's alerts there, shows them at once, and tells the computer.
/// The computer then skips the push, which can take 10 seconds or more. Without
/// an answer in a second, the push goes out as before.
@MainActor
final class BighelpLiveAlertListener {
    static let feature = "native-live-alerts-v1"
    static let longestWait = 25
    /// For a connection that cuts long requests (some proxies): shorter turns.
    static let shortWait = 8
    static let maximumGrants = 8
    static let maximumAlerts = 8

    struct Grant: Equatable, Sendable {
        let grantID: String
        let recipientKeyID: String
    }

    enum Next: Equatable, Sendable {
        case again
        case wait(Duration)
    }

    private let workspace: @MainActor () -> (any WorkspaceOperationPerforming)?
    private let grants: @MainActor () -> [Grant]
    private let present: @MainActor (BighelpLiveAlert) async -> BighelpLiveAlertPresenter.Outcome
    private let knownAvatars: @MainActor () -> [String]
    private let pause: @MainActor (Duration) async throws -> Void
    private let now: @MainActor () -> ContinuousClock.Instant
    /// One per run: a newer listen from this device takes over from an older one.
    let listenerID = UUID().uuidString.lowercased()
    private(set) var waitSeconds = BighelpLiveAlertListener.longestWait
    private var failures = 0
    private var conflicts = 0
    private var listening: (workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner, grants: [Grant])?

    init(workspace: @escaping @MainActor () -> (any WorkspaceOperationPerforming)?,
         grants: @escaping @MainActor () -> [Grant],
         present: @escaping @MainActor (BighelpLiveAlert) async -> BighelpLiveAlertPresenter.Outcome,
         knownAvatars: @escaping @MainActor () -> [String] = { BighelpNotificationAvatarCache.shared.hashes() },
         pause: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.workspace = workspace
        self.grants = grants
        self.present = present
        self.knownAvatars = knownAvatars
        self.pause = pause
        self.now = now
    }

    /// Listens until the task is cancelled (bighelp left the front), then tells the
    /// computer, so its next alerts push at once.
    func run() async {
        while !Task.isCancelled {
            guard case .wait(let duration) = await listenOnce() else { continue }
            do { try await pause(duration) } catch { break }
        }
        guard let listening else { return }
        self.listening = nil
        let payload = Self.stopPayload(listenerID: listenerID, grants: listening.grants)
        Task { @MainActor in
            let background = UIApplication.shared.beginBackgroundTask(withName: "bighelp instant alerts")
            _ = try? await listening.workspace.perform(.liveAlertsStop, payload: payload, owner: listening.owner)
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
    }

    /// One listen, and the alerts it brought.
    func listenOnce() async -> Next {
        guard let workspace = workspace(), let owner = workspace.owner else { return .wait(.seconds(10)) }
        let grants = Array(grants().prefix(Self.maximumGrants))
        guard !grants.isEmpty else { return .wait(.seconds(30)) }
        let started = now()
        let response: [String: BighelpJSONValue]
        do {
            response = try await workspace.perform(.liveAlertsListen, payload: listenPayload(grants), owner: owner)
        } catch {
            return next(after: error, heldFor: now() - started)
        }
        failures = 0
        conflicts = 0
        listening = (workspace, owner, grants)
        let alerts = (response["alerts"]?.array ?? []).prefix(Self.maximumAlerts).compactMap(BighelpLiveAlert.init)
        var handled: [String] = []
        for alert in alerts where grants.contains(where: { $0.grantID == alert.grantID }) {
            if await present(alert) != .failed { handled.append(alert.eventID) }
        }
        if !handled.isEmpty {
            // Lost acks are fine: the push follows, and takes the shown copy's place.
            _ = try? await workspace.perform(.liveAlertsAck, payload: Self.ackPayload(grants: grants, eventIDs: handled),
                                             owner: owner)
        }
        return .again
    }

    private func next(after error: any Error, heldFor elapsed: Duration) -> Next {
        switch error {
        case WorkspaceClientError.unavailable:
            // An older plugin, or one that can't do this here: pushes as before.
            return .wait(.seconds(300))
        case WorkspaceClientError.rejected(let code) where code == "live_alerts_not_enrolled":
            return .wait(.seconds(300))
        case WorkspaceClientError.rejected(let code) where code == "live_alerts_busy":
            return .wait(.seconds(60))
        case WorkspaceClientError.conflict:
            // The plugin's context changed: the next listen loads it again. Once.
            conflicts += 1
            if conflicts == 1 { return .again }
        default:
            break
        }
        // Something on the way cut a long request: listen in shorter turns.
        if elapsed >= .seconds(10), waitSeconds > Self.shortWait { waitSeconds = Self.shortWait }
        failures += 1
        let seconds = min(30, 1 << min(failures - 1, 5))
        return .wait(.milliseconds(seconds * 1_000 + Int.random(in: 0...(seconds * 200))))
    }

    func listenPayload(_ grants: [Grant]) -> [String: BighelpJSONValue] {
        ["listenerId": .string(listenerID), "grants": Self.grantValues(grants), "waitSeconds": .integer(waitSeconds),
         "knownAvatars": .array(knownAvatars().prefix(32).map(BighelpJSONValue.string))]
    }

    static func ackPayload(grants: [Grant], eventIDs: [String]) -> [String: BighelpJSONValue] {
        ["grants": grantValues(grants), "eventIds": .array(eventIDs.prefix(32).map(BighelpJSONValue.string))]
    }

    static func stopPayload(listenerID: String, grants: [Grant]) -> [String: BighelpJSONValue] {
        ["listenerId": .string(listenerID), "grants": grantValues(grants)]
    }

    private static func grantValues(_ grants: [Grant]) -> BighelpJSONValue {
        .array(grants.map { .object(["grantId": .string($0.grantID), "recipientKeyId": .string($0.recipientKeyID)]) })
    }
}

/// Settings › Notifications kinds (BuzzKit topics) apply to instant alerts too:
/// a kind turned off there doesn't show here either.
@MainActor
final class BighelpLiveAlertKinds {
    private var off: Set<String> = []
    private var checkedAt: Date?
    private var check: Task<Void, Never>?

    func isOn(_ eventType: String) -> Bool {
        if checkedAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true, check == nil {
            check = Task { [weak self] in
                let preferences = try? await BighelpBuzzKitPreferencesClient().load()
                guard let self else { return }
                if let preferences {
                    self.off = Set(preferences.filter { !$0.enabled }.map(\.id))
                    self.checkedAt = Date()
                }
                self.check = nil
            }
        }
        guard let topic = Self.topic(for: eventType) else { return true }
        return !off.contains(topic.rawValue)
    }

    static func topic(for eventType: String) -> BighelpBuzzKitTopic? {
        switch eventType {
        case "session.completed", "session.failed": .chatRepliesAndCompletions
        case "scheduled.completed", "scheduled.failed": .scheduledTasksAndDeliveries
        case "approval.required", "clarification.required": .questionsAndApprovals
        case "subagent.completed", "subagent.failed": .subagentCompletions
        default: nil
        }
    }
}

extension BighelpLiveAlertListener {
    /// The listener for the computer bighelp is connected to, while this task runs.
    static func listen(connections: WorkspaceConnectionStore, service: BighelpManagedNotificationService) async {
        let kinds = BighelpLiveAlertKinds()
        let presenter = BighelpLiveAlertPresenter(kindIsOn: { kinds.isOn($0) })
        let listener = BighelpLiveAlertListener(
            workspace: { connections.workspace },
            grants: { connections.selectedDirectHost.map(service.liveAlertGrants(host:)) ?? [] },
            present: { await presenter.present($0) }
        )
        await listener.run()
    }
}

/// Instant alerts run while bighelp is in front (on a Mac, while it runs) and
/// connected to a computer where this device has notifications on.
struct BighelpLiveAlertsWhileOpen: ViewModifier {
    let isOpen: Bool
    let isEnabled: Bool
    let connections: WorkspaceConnectionStore
    let composition: BighelpManagedNotificationComposition

    func body(content: Content) -> some View {
        content.task(id: key) {
            guard isOpen, isEnabled, connections.owner != nil, let service = composition.service else { return }
            await BighelpLiveAlertListener.listen(connections: connections, service: service)
        }
    }

    private var key: String {
        let connection = connections.owner.map { "\($0.authenticationGeneration):\($0.connectionGeneration)" } ?? "none"
        return "\(isOpen):\(isEnabled):\(connection):\(composition.revision)"
    }
}
