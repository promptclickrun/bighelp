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
    /// Activity links identify a local scoped mapping, not a host supplied by URL.
    @MainActor
    func openActivity(opaqueSessionID: String) async throws {
        guard let owner = activityRuntime?.destination(opaqueSessionID: opaqueSessionID),
              let host = registry.hosts.first(where: { $0.hostConnectionID == owner.hostConnectionID && $0.notificationScope == owner.accountScope }) else {
            throw DirectHermesError.invalidResponse
        }
        let credentials = try self.credentials(for: host)
        registry.select(host.id)
        let generation = registry.generation
        let workspace = registry.workspace(for: host)
        await workspace.reconnect()
        try requireCurrent(host, credentials: credentials)
        guard registry.generation == generation, registry.selectedHostID == host.id else { throw DirectHermesError.secureStorageChanged }
        try await workspace.visiting(profile: owner.profile) {
            await workspace.loadSessions()
            try requireCurrent(host, credentials: credentials)
            guard registry.generation == generation, let session = workspace.sessions.first(where: {
                $0.storedID == owner.storedSessionID && $0.profile == owner.profile && $0.supportsNativeResume
            }) else { throw DirectHermesError.invalidResponse }
            await workspace.openSession(session)
            try requireCurrent(host, credentials: credentials)
            guard registry.generation == generation, workspace.selectedChat?.client.storedID == owner.storedSessionID else {
                throw DirectHermesError.secureStorageChanged
            }
        }
        BighelpExternalSessionOpenCenter.shared.request(profileID: owner.profile, storedSessionID: owner.storedSessionID)
    }
}
