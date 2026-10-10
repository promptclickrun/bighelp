import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DeviceToolPermissionsTests {
    private let scope = DeviceToolScope(deviceID: "phone-a", authorizationEpoch: 1, hostID: "host-a")

    @Test func systemPermissionAloneDoesNotEnableAgentAccess() async {
        let fixture = DevicePermissionFixture()
        let store = fixture.makeStore()
        store.bind(scope)
        await store.refresh()
        #expect(DeviceToolCapability.allCases.allSatisfy { !store.isEnabled($0) })
        #expect(fixture.requests.isEmpty)
    }

    @Test func explicitEnableRequestsOnlyChosenPermissionAndPersistsItsGrant() async {
        let fixture = DevicePermissionFixture()
        let store = fixture.makeStore()
        store.bind(scope)
        await store.setEnabled(true, for: .calendar)
        #expect(store.isEnabled(.calendar))
        #expect(!store.isEnabled(.reminders))
        #expect(!store.isEnabled(.location))
        #expect(fixture.requests == [.calendar])
        let reopened = fixture.makeStore()
        reopened.bind(scope)
        #expect(reopened.isEnabled(.calendar))
        reopened.bind(.init(deviceID: "phone-a", authorizationEpoch: 1, hostID: "host-b"))
        #expect(!reopened.isEnabled(.calendar))
    }

    @Test func deniedPermissionCannotEnableAgentAccess() async {
        let fixture = DevicePermissionFixture()
        fixture.result = .denied
        let store = fixture.makeStore()
        store.bind(scope)
        await store.setEnabled(true, for: .reminders)
        #expect(!store.isEnabled(.reminders))
        #expect(store.status(for: .reminders) == .denied)
    }

    @Test func disablingWhilePromptIsPendingCannotBeUndoneByItsCompletion() async {
        let fixture = DevicePermissionFixture()
        let pending = PendingDevicePermission()
        fixture.request = { await pending.value() }
        let store = fixture.makeStore()
        store.bind(scope)
        let enabling = Task { await store.setEnabled(true, for: .calendar) }
        while !pending.isWaiting { await Task.yield() }
        await store.setEnabled(false, for: .calendar)
        pending.resolve(.available)
        await enabling.value
        #expect(!store.isEnabled(.calendar))
        let reopened = fixture.makeStore()
        reopened.bind(scope)
        #expect(!reopened.isEnabled(.calendar))
    }

    @Test func aLatePermissionPromptCannotGrantAccessToAnotherHost() async {
        let fixture = DevicePermissionFixture()
        let pending = PendingDevicePermission()
        fixture.request = { await pending.value() }
        let store = fixture.makeStore()
        store.bind(scope)
        let enabling = Task { await store.setEnabled(true, for: .reminders) }
        while !pending.isWaiting { await Task.yield() }
        store.bind(.init(deviceID: "phone-a", authorizationEpoch: 2, hostID: "host-b"))
        pending.resolve(.available)
        await enabling.value
        #expect(!store.isEnabled(.reminders))
        store.bind(scope)
        #expect(!store.isEnabled(.reminders))
    }

    @Test func revokingSystemCalendarAccessDisablesPreviouslyEnabledTools() async {
        let fixture = DevicePermissionFixture()
        let store = fixture.makeStore()
        store.bind(scope)
        await store.setEnabled(true, for: .calendar)
        fixture.result = .denied
        await store.refresh()
        #expect(!store.isEnabled(.calendar))
        #expect(store.status(for: .calendar) == .denied)
    }

    @Test func backgroundOrMissingScopeCannotRequestPermissions() async {
        let fixture = DevicePermissionFixture()
        let store = fixture.makeStore()
        await store.setEnabled(true, for: .calendar)
        store.bind(scope)
        fixture.foreground = false
        await store.setEnabled(true, for: .location)
        #expect(fixture.requests.isEmpty)
        #expect(!store.isEnabled(.location))
    }

    @Test func unrelatedDeniedPermissionsDoNotCancelTheChosenPrompt() async {
        let fixture = DevicePermissionFixture()
        let pending = PendingDevicePermission()
        fixture.request = { await pending.value() }
        let store = fixture.makeStore()
        store.bind(scope)
        let enabling = Task { await store.setEnabled(true, for: .location) }
        while !pending.isWaiting { await Task.yield() }
        fixture.result = .denied
        await store.refresh()
        pending.resolve(.available)
        await enabling.value
        #expect(store.isEnabled(.location))
        #expect(!store.isEnabled(.calendar))
        #expect(!store.isEnabled(.reminders))
    }
}

@MainActor
private final class DevicePermissionFixture {
    var requests: [DeviceToolCapability] = []
    var result: DeviceToolSystemAccess = .available
    var foreground = true
    var request: (() async -> DeviceToolSystemAccess)?
    var grants: [String: [String]] = [:]
    func makeStore() -> DeviceToolPermissions {
        DeviceToolPermissions(
            status: { _ in self.result },
            request: { kind in self.requests.append(kind); return await self.request?() ?? self.result },
            isForeground: { self.foreground },
            readGrants: { self.grants[$0] ?? [] },
            writeGrants: { self.grants[$0] = $1 }
        )
    }
}

@MainActor
private final class PendingDevicePermission {
    private var continuation: CheckedContinuation<DeviceToolSystemAccess, Never>?
    var isWaiting: Bool { continuation != nil }
    func value() async -> DeviceToolSystemAccess {
        await withCheckedContinuation { continuation = $0 }
    }
    func resolve(_ value: DeviceToolSystemAccess) { continuation?.resume(returning: value); continuation = nil }
}
