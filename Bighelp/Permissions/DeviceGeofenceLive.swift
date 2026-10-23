@preconcurrency import CoreLocation
import Foundation
import UIKit
import UserNotifications

// MARK: Core Location

#if !os(visionOS)
/// Core Location's `CLMonitor`. It is not on Vision Pro, which has no Arriving and leaving.
///
/// Places live in iOS under the monitor's name. After bighelp is closed, iOS relaunches it in the
/// background for an event (with Always allowed) and holds the event until a monitor of this name
/// is open and listened to, so `DeviceGeofenceTool.live` starts it at every launch.
actor LiveDeviceGeofenceMonitor: DeviceGeofenceMonitoring {
    static let name = "bighelp.geofences"
    private var opening: Task<CLMonitor, Never>?

    /// One monitor per name: iOS refuses a second one open, so concurrent callers share the first.
    private func monitor() async -> CLMonitor {
        if let opening { return await opening.value }
        let task = Task { await CLMonitor(Self.name) }
        opening = task
        return await task.value
    }

    func identifiers() async -> [String] {
        await monitor().identifiers
    }

    func add(_ region: DeviceGeofenceRegion, assuming state: DeviceGeofenceState) async {
        let condition = CLMonitor.CircularGeographicCondition(
            center: CLLocationCoordinate2D(latitude: region.latitude, longitude: region.longitude),
            radius: region.radiusMeters)
        let assumed: CLMonitor.Event.State
        switch state {
        case .inside: assumed = .satisfied
        case .outside: assumed = .unsatisfied
        case .unknown: assumed = .unknown
        }
        await monitor().add(condition, identifier: region.identifier, assuming: assumed)
    }

    func remove(identifier: String) async {
        await monitor().remove(identifier)
    }

    nonisolated func events() -> AsyncStream<DeviceGeofenceEvent> {
        AsyncStream { continuation in
            let task = Task { [self] in
                let monitor = await self.monitor()
                do {
                    for try await event in await monitor.events {
                        let state: DeviceGeofenceState
                        switch event.state {
                        case .satisfied: state = .inside
                        case .unsatisfied: state = .outside
                        default: state = .unknown
                        }
                        continuation.yield(DeviceGeofenceEvent(identifier: event.identifier, state: state, date: event.date))
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif

/// Asks iOS to upgrade While Using to Always. iOS asks the person once and shows the question
/// when it likes; Settings' own answer shows up in `DeviceLocationProviding.authorization`.
@MainActor
protocol DeviceGeofenceAlwaysRequesting: AnyObject {
    func requestAlways()
}

@MainActor
final class LiveDeviceGeofenceAlwaysRequester: DeviceGeofenceAlwaysRequesting {
    #if !os(visionOS)
    private let manager = CLLocationManager()
    #endif

    func requestAlways() {
        #if !os(visionOS)
        manager.requestAlwaysAuthorization()
        #endif
    }
}

// MARK: Telling the chat

enum DeviceGeofenceDeliveryError: Error, Equatable {
    case unavailable, wrongHost, appInUse, chatGone, notSent
}

/// Which computer bighelp uses now, and a way to change it. The app binds both at launch, from
/// the host registry. Places remember their computer by `WorkspaceOwner.cacheScopeID`.
@MainActor
enum DeviceGeofenceHostRouting {
    static var currentHostID: (@MainActor () -> String?)?
    /// Makes the computer with this ID the one in use. False when it isn't one of the person's.
    static var selectHost: (@MainActor (String) -> Bool)?
}

/// Where a message for a place may go.
enum DeviceGeofenceHostPlan: Equatable {
    case useCurrent, switchHost, refuse

    /// A place's computer that isn't the one in use is switched to only with bighelp in the
    /// background: switching under a person who is using the app would move them without asking.
    static func make(currentHostID: String?, placeHostID: String, appIsActive: Bool, canSwitch: Bool) -> DeviceGeofenceHostPlan {
        guard let currentHostID, currentHostID != placeHostID else { return .useCurrent }
        return !appIsActive && canSwitch ? .switchHost : .refuse
    }
}

/// How the catalog knows a chat: an app ID, a stored ID or a runtime ID, depending on when the
/// agent's call was made.
@MainActor
protocol DeviceGeofenceChatLookup {
    func hasChat(id: String) -> Bool
    func visibleChatID(resolving id: String) -> String?
    func hydrate(id: String) async -> Bool
}

enum DeviceGeofenceChats {
    /// The app's ID for the chat a call named, or nil when this computer has no such chat. A
    /// brand-new chat's call can carry its runtime ID, and a stored ID is the host's name for it.
    @MainActor
    static func resolve(_ sessionID: String, in lookup: some DeviceGeofenceChatLookup) async -> String? {
        if lookup.hasChat(id: sessionID) { return sessionID }
        if let visible = lookup.visibleChatID(resolving: sessionID), lookup.hasChat(id: visible) { return visible }
        if await lookup.hydrate(id: sessionID) { return sessionID }
        return nil
    }

    /// Used when a place is made, in the foreground: the place keeps the ID the app can find again.
    @MainActor
    static func resolveInWorkspace(_ sessionID: String) async -> String? {
        guard let connect = DeviceToolServices.workspace else { return nil }
        let resolved = try? await DeviceLocationDeadline.run(seconds: 5) { () -> String? in
            let workspace = try await connect()
            return await resolve(sessionID, in: CatalogChatLookup(catalog: workspace.catalog))
        }
        return resolved ?? nil
    }
}

@MainActor
struct CatalogChatLookup: DeviceGeofenceChatLookup {
    let catalog: SessionCatalogStore
    func hasChat(id: String) -> Bool { catalog.session(id: id) != nil }
    func visibleChatID(resolving id: String) -> String? { catalog.visibleSessionID(resolvingProtocolSessionID: id) }
    func hydrate(id: String) async -> Bool { (try? await catalog.hydrateSession(id: id)) != nil }
}

/// Sends the message into the chat that made the place, through the Shortcuts host path, which
/// connects with bighelp in the background. It never starts a chat, never switches the person's
/// computer while they are using the app, and never touches what they are typing.
@MainActor
final class LiveDeviceGeofenceSender: DeviceGeofenceMessageSending {
    private let appIsActive: @MainActor () -> Bool

    init(appIsActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }) {
        self.appIsActive = appIsActive
    }

    func send(_ message: String, to place: DeviceGeofencePlace) async throws {
        guard let connect = DeviceToolServices.workspace else { throw DeviceGeofenceDeliveryError.unavailable }
        // The host connection stays open while the message goes, with bighelp in the background.
        let release = BighelpShortcutService.holdHostConnection()
        defer { release() }
        let current = DeviceGeofenceHostRouting.currentHostID?()
        switch DeviceGeofenceHostPlan.make(
            currentHostID: current, placeHostID: place.hostID, appIsActive: appIsActive(),
            canSwitch: DeviceGeofenceHostRouting.selectHost != nil) {
        case .refuse:
            throw appIsActive() ? DeviceGeofenceDeliveryError.appInUse : .wrongHost
        case .switchHost:
            guard DeviceGeofenceHostRouting.selectHost?(place.hostID) == true else {
                throw DeviceGeofenceDeliveryError.wrongHost
            }
        case .useCurrent:
            break
        }
        let workspace = try await connect()
        if current != nil, DeviceGeofenceHostRouting.currentHostID?() != place.hostID {
            throw DeviceGeofenceDeliveryError.wrongHost
        }
        // Never let a message meant for one chat start another.
        guard let chatID = await DeviceGeofenceChats.resolve(place.sessionID, in: CatalogChatLookup(catalog: workspace.catalog)) else {
            throw DeviceGeofenceDeliveryError.chatGone
        }
        let agentID = workspace.catalog.session(id: chatID)?.agentIDs.first ?? place.agentID
        let (_, chat) = try await workspace.readyChat(agentID: agentID, reusing: chatID)

        // Its own message, not the composer's: what the person is typing and any attachments they
        // staged stay where they are. A running turn takes it as a steer.
        guard chat.acceptsCardReply(message) else { throw DeviceGeofenceDeliveryError.notSent }
        let known = Set(chat.items.map(\.id))
        var finished = false
        Task { @MainActor in await chat.sendCardReply(message); finished = true }
        let accepted = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < accepted {
            if chat.failureMessage != nil { break }
            if chat.items.contains(where: { !known.contains($0.id) && $0.role == .human }) { break }
            try await Task.sleep(for: .milliseconds(150))
        }
        guard chat.failureMessage == nil,
              chat.items.contains(where: { !known.contains($0.id) && $0.role == .human }) else {
            throw DeviceGeofenceDeliveryError.notSent
        }
        // The host answers on its own; stay connected a little for the reply to start.
        let grace = ContinuousClock.now + .seconds(20)
        while !finished, ContinuousClock.now < grace { try await Task.sleep(for: .milliseconds(150)) }
        workspace.featureStore.flushChatPersistence()
    }
}

/// A local notification when the chat couldn't be told, so a missed arrival is never silent.
@MainActor
final class LiveDeviceGeofenceNotifier: DeviceGeofenceNotifying {
    func notifyDeliveryFailed(place: DeviceGeofencePlace, arrived: Bool) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default: return
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "bighelp couldn't tell your agent")
        let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = arrived
            ? String(localized: "You arrived at \(name). bighelp couldn't reach your computer to let your agent know.")
            : String(localized: "You left \(name). bighelp couldn't reach your computer to let your agent know.")
        content.threadIdentifier = "bighelp.places"
        try? await center.add(UNNotificationRequest(
            identifier: "bighelp.place.failed.\(UUID().uuidString.lowercased())", content: content, trigger: nil))
    }
}

/// iOS leaves a woken app only a few seconds. This asks for more while a place's message is
/// told, and hands it back when iOS runs out so the app is suspended instead of ended.
@MainActor
enum DeviceGeofenceBackgroundTasks {
    @MainActor private final class Ticket {
        var identifier = UIBackgroundTaskIdentifier.invalid
        func end() {
            guard identifier != .invalid else { return }
            let finished = identifier
            identifier = .invalid
            UIApplication.shared.endBackgroundTask(finished)
        }
    }

    static func begin(_ name: String) -> @MainActor () -> Void {
        let ticket = Ticket()
        ticket.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { ticket.end() }
        }
        return { ticket.end() }
    }
}
