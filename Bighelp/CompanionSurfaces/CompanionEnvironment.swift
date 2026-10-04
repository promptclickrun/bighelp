import SwiftUI

private struct CompanionStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue: CompanionStore? = nil
}

private struct CompanionAgentScopeEnvironmentKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var companionStore: CompanionStore? {
        get { self[CompanionStoreEnvironmentKey.self] }
        set { self[CompanionStoreEnvironmentKey.self] = newValue }
    }

    var companionAgentScope: String {
        get { self[CompanionAgentScopeEnvironmentKey.self] }
        set { self[CompanionAgentScopeEnvironmentKey.self] = newValue }
    }
}

enum CompanionSurfaceScope {
    /// Agents' characters and pets on this device are kept per computer, since two
    /// computers can each have an agent with the same ID. Empty with no computer
    /// chosen: then nothing is saved or shown.
    static func computer(_ hostConnectionID: String?) -> String {
        guard let hostConnectionID, !hostConnectionID.isEmpty else { return "" }
        return "computer:" + hostConnectionID
    }

    static func accountHost(
        deviceID: String,
        authorizationEpoch: Int,
        hostID: String
    ) -> String {
        [deviceID, String(authorizationEpoch), hostID]
            .map { "\($0.utf8.count):\($0)" }
            .joined()
    }
}
