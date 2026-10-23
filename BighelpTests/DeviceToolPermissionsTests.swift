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
        #expect(DeviceToolCapability.allCases.filter { $0.sharesPersonalData }.allSatisfy { !store.isEnabled($0) })
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
    }

    /// An approval belongs to this phone: every computer and every agent on it can use it, and
    /// it stays after updates, reconnects and new sign-ins until the person turns it off.
    @Test func anApprovalFollowsThePhoneToEveryHost() async {
        let fixture = DevicePermissionFixture()
        let store = fixture.makeStore()
        store.bind(scope)
        await store.setEnabled(true, for: .reminders)
        let reopened = fixture.makeStore()
        #expect(reopened.isEnabled(.reminders), "Saved before any host connects")
        reopened.bind(.init(deviceID: "phone-a", authorizationEpoch: 1, hostID: "host-b"))
        #expect(reopened.isEnabled(.reminders))
        reopened.bind(nil)
        reopened.bind(scope)
        #expect(reopened.isEnabled(.reminders))
        reopened.disable(.reminders)
        #expect(!fixture.makeStore().isEnabled(.reminders), "Only turning it off takes it away")
    }

    /// Approvals saved for each host before 2.6.15 come along: one approved anywhere is approved.
    @Test func approvalsSavedForEachHostMoveToThePhone() {
        let fixture = DevicePermissionFixture()
        let hostA = DeviceToolScope(deviceID: "phone-a", authorizationEpoch: 1, hostID: "host-a").storageKey
        let hostB = DeviceToolScope(deviceID: "phone-a", authorizationEpoch: 1, hostID: "host-b").storageKey
        fixture.grants = [hostA: ["calendar"], hostB: ["reminders", "teleporter"]]
        let store = fixture.makeStore()
        #expect(store.isEnabled(.calendar) && store.isEnabled(.reminders))
        #expect(!store.isEnabled(.contacts))
        #expect(Set(fixture.grants[DeviceToolPermissions.grantsKey] ?? []) == ["calendar", "reminders"])
        fixture.grants[hostA] = ["contacts"]
        #expect(!fixture.makeStore().isEnabled(.contacts), "Moved once; the phone's list decides after that")
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

    /// The person said yes to iOS: the switch is the phone's, so a host switch meanwhile doesn't undo it.
    /// It still retires work started for the old host (the revision moves on).
    @Test func aPromptAnsweredDuringAHostSwitchStillTurnsTheSwitchOn() async {
        let fixture = DevicePermissionFixture()
        let pending = PendingDevicePermission()
        fixture.request = { await pending.value() }
        let store = fixture.makeStore()
        store.bind(scope)
        let enabling = Task { await store.setEnabled(true, for: .reminders) }
        while !pending.isWaiting { await Task.yield() }
        let revision = store.revision
        store.bind(.init(deviceID: "phone-a", authorizationEpoch: 1, hostID: "host-b"))
        #expect(store.revision != revision)
        pending.resolve(.available)
        await enabling.value
        #expect(store.isEnabled(.reminders))
    }

    /// iOS saying no (or Location Services off for a moment) pauses the tool; it never turns the
    /// switch off. Allowing it again in iOS Settings brings the tool back without touching bighelp.
    @Test func iOSSayingNoPausesTheToolButKeepsTheSwitchOn() async {
        let fixture = DevicePermissionFixture()
        let store = fixture.makeStore()
        store.bind(scope)
        await store.setEnabled(true, for: .calendar)
        await store.refresh()
        #expect(store.isUsable(.calendar))
        let before = store.revision
        fixture.result = .denied
        await store.refresh()
        #expect(store.isEnabled(.calendar))
        #expect(!store.isUsable(.calendar))
        #expect(store.status(for: .calendar) == .denied)
        #expect(store.revision != before, "Work started under the old answer is retired")
        #expect(fixture.makeStore().isEnabled(.calendar))
        fixture.result = .unavailable
        await store.refresh()
        #expect(store.isEnabled(.calendar))
        fixture.result = .available
        await store.refresh()
        #expect(store.isUsable(.calendar))
    }

    @Test func theFirstReadOfIOSDoesNotRetireWork() async {
        let fixture = DevicePermissionFixture()
        fixture.grants[DeviceToolPermissions.grantsKey] = ["calendar"]
        let store = fixture.makeStore()
        store.bind(scope)
        let revision = store.revision
        #expect(!store.isUsable(.calendar), "Not before iOS has been asked how it stands")
        await store.refresh()
        #expect(store.revision == revision)
        #expect(store.isUsable(.calendar))
        store.bind(nil)
        #expect(!store.isUsable(.calendar), "No computer, nothing to use it")
    }

    @Test func theBackgroundCannotRequestPermissions() async {
        let fixture = DevicePermissionFixture()
        let store = fixture.makeStore()
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
            readGrants: { self.grants[$0] },
            writeGrants: { self.grants[$0] = $1 },
            legacyGrants: {
                self.grants.filter { $0.key.hasPrefix(DeviceToolPermissions.legacyGrantsPrefix) }.map(\.value)
            }
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
