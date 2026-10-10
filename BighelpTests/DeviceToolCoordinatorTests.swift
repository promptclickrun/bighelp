import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DeviceToolCoordinatorTests {
    @Test func uncertainNativeMutationFailureRequiresReconciliation() async {
        let fixture = DeviceCoordinatorFixture()
        await fixture.permissions.setEnabled(true, for: .calendar)
        fixture.failure = .nativeFailure
        let result = await fixture.coordinator.handle(fixture.request(), owner: fixture.scope, isCurrent: { true })
        #expect(result.code == "outcome_unknown")
        #expect(fixture.executions == 1)
        let repeated = await fixture.makeCoordinator().handle(fixture.request(), owner: fixture.scope, isCurrent: { true })
        #expect(repeated == result)
        #expect(fixture.executions == 1)
    }

    @Test func failedJournalWriteCannotReachTheMutation() async {
        let fixture = DeviceCoordinatorFixture()
        await fixture.permissions.setEnabled(true, for: .calendar)
        fixture.journal.failWrites = true
        let result = await fixture.coordinator.handle(fixture.request(), owner: fixture.scope, isCurrent: { true })
        #expect(result.code == "persistence_unavailable")
        #expect(fixture.executions == 0)
    }

    @Test func disablingThenReenablingDoesNotReviveAnOldRead() async {
        let fixture = DeviceCoordinatorFixture()
        await fixture.permissions.setEnabled(true, for: .calendar)
        fixture.onExecuteAsync = {
            fixture.permissions.disable(.calendar)
            await fixture.permissions.setEnabled(true, for: .calendar)
        }
        let result = await fixture.coordinator.handle(fixture.request(operation: "calendar.list"), owner: fixture.scope, isCurrent: { true })
        #expect(result.code == "permission_disabled")
        #expect(result.payload.isEmpty)
    }

    @Test func disabledToolsNeverReachAppleAPIs() async {
        let fixture = DeviceCoordinatorFixture()
        let result = await fixture.coordinator.handle(fixture.request(), owner: fixture.scope, isCurrent: { true })
        #expect(result.code == "permission_disabled")
        #expect(fixture.executions == 0)
    }

    @Test func explicitGrantAllowsDirectMutationWithoutAnotherApproval() async {
        let fixture = DeviceCoordinatorFixture()
        await fixture.permissions.setEnabled(true, for: .calendar)
        let result = await fixture.coordinator.handle(fixture.request(), owner: fixture.scope, isCurrent: { true })
        #expect(result.status == "completed")
        #expect(result.payload["id"] == .string("event-1"))
        #expect(fixture.executions == 1)
    }

    @Test func anotherPhoneOrHostCannotUseTheGrant() async {
        let fixture = DeviceCoordinatorFixture()
        await fixture.permissions.setEnabled(true, for: .calendar)
        let other = DeviceToolScope(deviceID: "phone-b", authorizationEpoch: 1, hostID: "host-a")
        let result = await fixture.coordinator.handle(fixture.request(), owner: other, isCurrent: { true })
        #expect(result.code == "owner_changed")
        #expect(fixture.executions == 0)
    }

    @Test func expiredRequestsCannotMutateData() async {
        let fixture = DeviceCoordinatorFixture()
        await fixture.permissions.setEnabled(true, for: .calendar)
        let result = await fixture.coordinator.handle(fixture.request(expiresAt: 999), owner: fixture.scope, isCurrent: { true })
        #expect(result.code == "request_expired")
        #expect(fixture.executions == 0)
    }

    @Test func completedMutationIsNotRepeatedAfterCoordinatorRecreation() async {
        let fixture = DeviceCoordinatorFixture()
        await fixture.permissions.setEnabled(true, for: .calendar)
        let request = fixture.request()
        let first = await fixture.coordinator.handle(request, owner: fixture.scope, isCurrent: { true })
        let second = await fixture.makeCoordinator().handle(request, owner: fixture.scope, isCurrent: { true })
        #expect(first.status == "completed")
        #expect(second == first)
        #expect(fixture.executions == 1)
    }

    @Test func reusedIdentityWithChangedArgumentsIsRejected() async {
        let fixture = DeviceCoordinatorFixture()
        await fixture.permissions.setEnabled(true, for: .calendar)
        _ = await fixture.coordinator.handle(fixture.request(), owner: fixture.scope, isCurrent: { true })
        let result = await fixture.coordinator.handle(fixture.request(title: "different"), owner: fixture.scope, isCurrent: { true })
        #expect(result.code == "request_conflict")
        #expect(fixture.executions == 1)
    }

    @Test func aStartedMutationWithUnknownOutcomeIsNeverBlindlyRepeated() async {
        let fixture = DeviceCoordinatorFixture()
        await fixture.permissions.setEnabled(true, for: .calendar)
        fixture.journal.dropCompletedWrites = true
        _ = await fixture.coordinator.handle(fixture.request(), owner: fixture.scope, isCurrent: { true })
        let result = await fixture.makeCoordinator().handle(fixture.request(), owner: fixture.scope, isCurrent: { true })
        #expect(result.code == "outcome_unknown")
        #expect(fixture.executions == 1)
    }

    @Test func grantRevocationWhileReadingSuppressesThePrivateResult() async {
        let fixture = DeviceCoordinatorFixture()
        await fixture.permissions.setEnabled(true, for: .calendar)
        fixture.onExecute = { fixture.permissions.disable(.calendar) }
        let result = await fixture.coordinator.handle(fixture.request(operation: "calendar.list"), owner: fixture.scope, isCurrent: { true })
        #expect(result.code == "permission_disabled")
        #expect(result.payload.isEmpty)
    }

    @Test func inactivePhoneNeverReadsOrChangesData() async {
        let fixture = DeviceCoordinatorFixture()
        await fixture.permissions.setEnabled(true, for: .calendar)
        fixture.available = false
        let result = await fixture.coordinator.handle(fixture.request(), owner: fixture.scope, isCurrent: { true })
        #expect(result.code == "device_unavailable")
        #expect(fixture.executions == 0)
    }
}

@MainActor
private final class DeviceCoordinatorFixture {
    let scope = DeviceToolScope(deviceID: "phone-a", authorizationEpoch: 1, hostID: "host-a")
    let permissions = DeviceToolPermissions(status: { _ in .available }, request: { _ in .available }, isForeground: { true }, readGrants: { _ in [] }, writeGrants: { _, _ in })
    let journal = MemoryDeviceToolJournal()
    var executions = 0
    var available = true
    var failure: AppleDeviceToolError?
    var onExecute: (() -> Void)?
    var onExecuteAsync: (() async -> Void)?
    lazy var coordinator = makeCoordinator()
    init() { permissions.bind(scope) }
    func makeCoordinator() -> DeviceToolCoordinator {
        DeviceToolCoordinator(permissions: permissions, journal: journal, clock: { 1_000 }, available: { self.available }) { _, _, authorize in
            try authorize()
            self.executions += 1
            self.onExecute?()
            await self.onExecuteAsync?()
            if let failure = self.failure { throw failure }
            return ["id": .string("event-1"), "revision": .string("revision-1")]
        }
    }
    func request(title: String = "meeting", expiresAt: Int = 1_120, operation: String = "calendar.create") -> DeviceToolRequest {
        DeviceToolRequest(version: 1, type: "device.tool.request", requestId: "request-1234567890", deviceId: scope.deviceID, hostId: scope.hostID, authorizationEpoch: 1, sessionId: "session-1", agentId: "default", turnId: "turn-1", operation: operation, arguments: ["title": .string(title)], sentAt: 1_000, expiresAt: expiresAt)
    }
}

@MainActor
private final class MemoryDeviceToolJournal: DeviceToolJournal {
    var values: [String: DeviceToolJournalEntry] = [:]
    var dropCompletedWrites = false
    var failWrites = false
    func entry(requestID: String, scope: DeviceToolScope) throws -> DeviceToolJournalEntry? { values[scope.storageKey + requestID] }
    func save(_ entry: DeviceToolJournalEntry, requestID: String, scope: DeviceToolScope) throws {
        if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
        if dropCompletedWrites && entry.result != nil { return }
        values[scope.storageKey + requestID] = entry
    }
}
