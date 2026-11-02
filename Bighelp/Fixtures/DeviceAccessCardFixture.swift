#if DEBUG
import Foundation
import UIKit

/// Demo mode has no host, so no agent can call a tool that's off. With
/// `-test-device-access-card reminders.list` (or another read, like `health.read`) the first chat opened
/// gets that one call, sent through the real card, switch and coordinator the way the plugin's channel
/// delivers it. Turned on, the tool answers with made-up data, and Device access says how the call
/// came back.
@MainActor
final class DeviceAccessCardFixture {
    static let launchArgument = "-test-device-access-card"
    let operation: String
    private let permissions: DeviceToolPermissions
    private let coordinator: DeviceToolCoordinator
    private let report: (String) -> Void
    private var sent = false

    init?(launchArguments: [String], permissions: DeviceToolPermissions, report: @escaping (String) -> Void) {
        guard let index = launchArguments.firstIndex(of: Self.launchArgument),
              launchArguments.indices.contains(index + 1),
              let entry = DeviceToolCatalog.operations[launchArguments[index + 1]], !entry.journaled
        else { return nil }
        operation = launchArguments[index + 1]
        self.permissions = permissions
        self.report = report
        coordinator = DeviceToolCoordinator(
            permissions: permissions, journal: NoJournal(),
            clock: { Int(Date().timeIntervalSince1970) },
            available: { UIApplication.shared.applicationState != .background },
            execute: { operation, _, _, authorize in
                try authorize()
                return Self.madeUpAnswer(for: operation)
            })
    }

    /// Sends the call once; `isCurrent` is the chat still being open.
    func send(scope: DeviceToolScope, conversationID: String, isCurrent: @escaping @MainActor () -> Bool) async {
        guard !sent else { return }
        sent = true
        let now = Int(Date().timeIntervalSince1970)
        let request = DeviceToolRequest(
            version: 1, type: "device.tool.request", requestId: "demo-access-" + UUID().uuidString.lowercased(),
            deviceId: scope.deviceID, hostId: scope.hostID, authorizationEpoch: scope.authorizationEpoch,
            sessionId: "demo-session", agentId: "default", turnId: "demo-turn",
            operation: operation, arguments: Self.arguments(for: operation),
            sentAt: now, expiresAt: now + NativeDeviceToolSession.askWindow)
        let coordinator = coordinator
        let handle = DeviceAccessAsk.asking({ request, owner, isCurrent in
            await coordinator.handle(request, owner: owner, isCurrent: isCurrent)
        }, cards: .shared, permissions: permissions, conversationID: conversationID)
        let result = await handle(request, scope, isCurrent)
        let count = result.payload["items"]?.array?.count ?? 0
        report(result.status == "completed"
               ? "Demo call \(operation) came back with \(count) items."
               : "Demo call \(operation) was refused: \(result.code ?? "failed").")
    }

    private static func arguments(for operation: String) -> [String: BighelpJSONValue] {
        guard operation == "health.read" else { return [:] }
        let end = Date()
        let format = ISO8601DateFormatter()
        return ["start": .string(format.string(from: end.addingTimeInterval(-7 * 86_400))),
                "end": .string(format.string(from: end)), "timeZone": .string(TimeZone.current.identifier),
                "types": .array([.string("sleep_analysis")])]
    }

    /// Made-up data, never the person's.
    private static func madeUpAnswer(for operation: String) -> [String: BighelpJSONValue] {
        switch operation {
        case "health.read":
            ["items": .array((1...7).map { night -> BighelpJSONValue in
                .object(["type": .string("sleep_analysis"), "value": .string("asleepCore"),
                         "start": .string("2026-10-2\(night)T23:10:00-05:00"),
                         "end": .string("2026-10-2\(night + 1)T06:40:00-05:00")])
            }), "truncated": .boolean(false)]
        case "reminders.list":
            ["items": .array([
                .object(["id": .string("demo-1"), "title": .string("Call Sam at 5"), "completed": .boolean(false)]),
                .object(["id": .string("demo-2"), "title": .string("Buy oat milk"), "completed": .boolean(false)]),
            ]), "truncated": .boolean(false)]
        default:
            ["items": .array([]), "truncated": .boolean(false)]
        }
    }
}

/// Reads are never journaled.
@MainActor
private final class NoJournal: DeviceToolJournal {
    func entry(requestID: String, scope: DeviceToolScope) throws -> DeviceToolJournalEntry? { nil }
    func save(_ entry: DeviceToolJournalEntry, requestID: String, scope: DeviceToolScope) throws {}
}
#endif

/// Demo mode's iOS for the connect cards: each data-sharing tool starts not asked and turns on when
/// asked, with no real permission and no real data. Off (the default), it answers nothing.
final class DemoDeviceGrants {
    private let on: Bool
    private var granted: Set<DeviceToolCapability> = []

    init(on: Bool) { self.on = on }

    func status(_ kind: DeviceToolCapability) -> DeviceToolSystemAccess? {
        guard on, kind.sharesPersonalData, kind.isOfferedOnThisPlatform else { return nil }
        return granted.contains(kind) ? .available : .notRequested
    }

    func request(_ kind: DeviceToolCapability) -> DeviceToolSystemAccess? {
        guard on, kind.sharesPersonalData, kind.isOfferedOnThisPlatform else { return nil }
        granted.insert(kind)
        return .available
    }
}
