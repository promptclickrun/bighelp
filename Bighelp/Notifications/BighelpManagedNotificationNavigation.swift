import Foundation
import SwiftUI

private struct BighelpManagedNotificationServiceKey: EnvironmentKey {
    static let defaultValue: BighelpManagedNotificationService? = nil
}
extension EnvironmentValues {
    var managedNotificationService: BighelpManagedNotificationService? {
        get { self[BighelpManagedNotificationServiceKey.self] }
        set { self[BighelpManagedNotificationServiceKey.self] = newValue }
    }
}

extension BighelpManagedNotificationService {
    /// The computer and chat an alert is about, for an answer given on the alert itself. Nil for an
    /// alert that names no single saved chat (a scheduled run, an older alert).
    @MainActor
    func outsideTarget(for open: BighelpProactiveNotificationOpen) -> ChatOutsideTarget? {
        guard let type = open.eventType, let reference = open.sessionReference, let profile = open.agentID,
              let host = host(forEvent: open.eventID, eventType: type),
              // The agent is the one this phone set alerts up for, not only the one the push names.
              ledger.enrollments.contains(where: {
                  $0.enabled && !$0.revokePending && $0.grant?.grantId == open.hostGrantID && $0.profile == profile
              }) else { return nil }
        return ChatOutsideTarget(hostID: host.id, profileID: profile, chat: .reference(reference))
    }

    /// The computer and chat of a Live Activity row, for the island's buttons.
    @MainActor
    func outsideTarget(opaqueSessionID: String) -> ChatOutsideTarget? {
        guard let owner = activityRuntime?.destination(opaqueSessionID: opaqueSessionID),
              let host = registry.hosts.first(where: {
                  $0.hostConnectionID == owner.hostConnectionID && $0.notificationScope == owner.accountScope
              }) else { return nil }
        return ChatOutsideTarget(hostID: host.id, profileID: owner.profile, chat: .stored(owner.storedSessionID))
    }

    /// Activity links identify a local scoped mapping, not a host supplied by URL. The tap hands
    /// the shell its computer, agent and exact chat; the shell opens it from its saved chats.
    /// Asking `session.list` first failed every Bot Chat (Hermes leaves them out) and so every
    /// tap on the Bots view (#571).
    @MainActor
    func openActivity(opaqueSessionID: String, opens: BighelpExternalSessionOpenCenter = .shared) throws {
        guard let owner = activityRuntime?.destination(opaqueSessionID: opaqueSessionID),
              let host = registry.hosts.first(where: { $0.hostConnectionID == owner.hostConnectionID && $0.notificationScope == owner.accountScope }) else {
            throw DirectHermesError.invalidResponse
        }
        _ = try credentials(for: host)
        let previous = registry.selectedHostID
        registry.select(host.id)
        guard registry.selectedHostID == host.id else { throw DirectHermesError.secureStorageChanged }
        // Another computer's card: the shell waits for that computer before it prepares the chat.
        opens.request(hostID: host.id, profileID: owner.profile, storedSessionID: owner.storedSessionID,
                      switchedHost: previous == host.id ? nil : BighelpExternalSessionOpen.HostSwitch(from: previous))
    }
}
