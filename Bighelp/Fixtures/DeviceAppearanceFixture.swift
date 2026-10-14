#if DEBUG
import Foundation
import UIKit

/// Demo mode has no host, so no agent can call `iphone_appearance`. With
/// `-test-agent-appearance '{"mode":"dark","color":"rose"}'` the first chat opened gets that one call,
/// sent through the real coordinator, switch and tool the way the plugin's channel delivers it.
@MainActor
final class DeviceAppearanceFixture {
    static let launchArgument = "-test-agent-appearance"
    private let arguments: [String: BighelpJSONValue]
    private let coordinator: DeviceToolCoordinator
    private var sent = false

    init?(launchArguments: [String], permissions: DeviceToolPermissions, tool: DeviceAppearanceTool) {
        guard let index = launchArguments.firstIndex(of: Self.launchArgument),
              launchArguments.indices.contains(index + 1),
              let arguments = try? JSONDecoder().decode([String: BighelpJSONValue].self,
                                                        from: Data(launchArguments[index + 1].utf8))
        else { return nil }
        self.arguments = arguments
        coordinator = DeviceToolCoordinator(
            permissions: permissions, journal: UnusedJournal(),
            clock: { Int(Date().timeIntervalSince1970) },
            available: { UIApplication.shared.applicationState == .active },
            execute: { operation, arguments, authorize in
                try tool.execute(operation: operation, arguments: arguments, authorize: authorize)
            })
    }

    /// Sends the call once; `isCurrent` is the chat still being open.
    func send(scope: DeviceToolScope, isCurrent: @escaping @MainActor () -> Bool) async {
        guard !sent else { return }
        sent = true
        let now = Int(Date().timeIntervalSince1970)
        let request = DeviceToolRequest(
            version: 1, type: "device.tool.request", requestId: "demo-appearance-" + UUID().uuidString.lowercased(),
            deviceId: scope.deviceID, hostId: scope.hostID, authorizationEpoch: scope.authorizationEpoch,
            sessionId: "demo-session", agentId: "default", turnId: "demo-turn",
            operation: "appearance.set", arguments: arguments, sentAt: now, expiresAt: now + 30)
        _ = await coordinator.handle(request, owner: scope, isCurrent: isCurrent)
    }
}

/// Appearance calls are never journaled.
@MainActor
private final class UnusedJournal: DeviceToolJournal {
    func entry(requestID: String, scope: DeviceToolScope) throws -> DeviceToolJournalEntry? { nil }
    func save(_ entry: DeviceToolJournalEntry, requestID: String, scope: DeviceToolScope) throws {}
}
#endif
