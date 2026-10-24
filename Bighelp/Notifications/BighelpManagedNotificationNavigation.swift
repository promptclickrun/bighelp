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
    /// Activity links identify a local scoped mapping, not a host supplied by URL. The tap hands
    /// the shell its computer, agent and exact chat; the shell opens it from its saved chats.
    /// Asking `session.list` first failed every Bot Chat (Hermes leaves them out) and so every
    /// tap in Bots mode (#571).
    @MainActor
    func openActivity(opaqueSessionID: String, opens: BighelpExternalSessionOpenCenter = .shared) throws {
        guard let owner = activityRuntime?.destination(opaqueSessionID: opaqueSessionID),
              let host = registry.hosts.first(where: { $0.hostConnectionID == owner.hostConnectionID && $0.notificationScope == owner.accountScope }) else {
            throw DirectHermesError.invalidResponse
        }
        _ = try credentials(for: host)
        registry.select(host.id)
        guard registry.selectedHostID == host.id else { throw DirectHermesError.secureStorageChanged }
        opens.request(hostID: host.id, profileID: owner.profile, storedSessionID: owner.storedSessionID)
    }
}
