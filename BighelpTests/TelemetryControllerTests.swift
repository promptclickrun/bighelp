import Foundation
import Testing
@testable import Bighelp

/// The Settings switch: what turning it off or back on does, here and on the hosts.
@MainActor
struct TelemetryControllerTests {
    /// A connected host that records what it was told.
    private final class FakeHost: TelemetryHostEndpoint {
        let supportsTelemetrySwitch: Bool
        var failing = false
        private(set) var told: [Bool] = []
        init(supports: Bool = true) { supportsTelemetrySwitch = supports }
        func setTelemetry(enabled: Bool) async throws {
            if failing { throw WorkspaceClientError.transportUnavailable }
            told.append(enabled)
        }
    }

    private struct Setup {
        let controller: TelemetryController
        let rig: TelemetryTestRig.Rig
        let preference: TelemetryPreference
        let receipts: BighelpDeliveryReceipts
    }

    private func setup(hosts: [FakeHost], startsOn: Bool = true) -> Setup {
        let defaults = UserDefaults(suiteName: "telemetry-\(UUID().uuidString)")!
        let preference = TelemetryPreference(defaults: defaults)
        preference.isEnabled = startsOn
        let rig = TelemetryTestRig.make(enabled: startsOn)
        let directory = FileManager.default.temporaryDirectory.appending(path: "telemetry-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let receipts = BighelpDeliveryReceipts(fileURL: directory.appending(path: "r.json"), defaults: defaults)
        let controller = TelemetryController(preference: preference, client: { rig.client }, receipts: receipts, markEnabled: { _ in },
                                             visitHosts: { body in for host in hosts { await body(host) } })
        return Setup(controller: controller, rig: rig, preference: preference, receipts: receipts)
    }

    @Test func itIsOnUntilSomeoneTurnsItOff() {
        let defaults = UserDefaults(suiteName: "telemetry-\(UUID().uuidString)")!
        #expect(TelemetryPreference(defaults: defaults).isEnabled)
        #expect(TelemetryController(preference: TelemetryPreference(defaults: defaults), client: { nil }, markEnabled: { _ in }).isEnabled)
        TelemetryPreference(defaults: defaults).isEnabled = false
        #expect(!TelemetryController(preference: TelemetryPreference(defaults: defaults), client: { nil }, markEnabled: { _ in }).isEnabled)
    }

    @Test func turningItOffStopsSendingClearsTheQueueAndTheIDAndTellsCapableHosts() async throws {
        let capable = FakeHost(), plain = FakeHost(supports: false), second = FakeHost()
        let setup = setup(hosts: [capable, plain, second])
        await setup.rig.client.record(.appOpened(coldStart: true), at: setup.rig.clock.now)
        await setup.rig.client.flush()
        await setup.rig.client.record(.featureUsed(.chatSent), at: setup.rig.clock.now)
        #expect(setup.rig.identity.current != nil)
        setup.receipts.append(.init(kind: .alert, path: .direct, receivedAt: 1, sentAt: nil, occurredAt: nil))

        await setup.controller.setEnabled(false)

        #expect(!setup.controller.isEnabled && !setup.preference.isEnabled)
        #expect(await setup.rig.client.queuedCount == 0)
        #expect(await !setup.rig.client.enabled)
        #expect(setup.rig.identity.current == nil)
        #expect(capable.told == [false] && second.told == [false])
        #expect(plain.told.isEmpty, "a host without the capability is skipped")
        #expect(!setup.receipts.isRecording && setup.receipts.count == 0, "the extension stops noting pushes")

        let sent = setup.rig.transport.requests.count
        await setup.rig.client.record(.featureUsed(.chatSent), at: setup.rig.clock.now)
        await setup.rig.client.flush()
        #expect(setup.rig.transport.requests.count == sent)
    }

    @Test func turningItBackOnSendsTrueOnceAndOneToggledEvent() async throws {
        let host = FakeHost(), plain = FakeHost(supports: false)
        let setup = setup(hosts: [host, plain], startsOn: false)
        await setup.controller.setEnabled(true)
        #expect(setup.controller.isEnabled && setup.preference.isEnabled && setup.receipts.isRecording)
        #expect(host.told == [true])
        #expect(plain.told.isEmpty)
        #expect(await setup.rig.client.queuedEvents == [.toggled(enabled: true)])

        // Nothing more happens when it's already on, and no other call ever sends true.
        await setup.controller.setEnabled(true)
        await setup.controller.hostConnected(host, connection: UUID())
        #expect(host.told == [true])
        #expect(await setup.rig.client.queuedEvents == [.toggled(enabled: true)])
        await setup.rig.client.flush()
        let events = try #require(setup.rig.transport.batches.first?["events"] as? [[String: Any]])
        #expect(events.compactMap { $0["name"] as? String } == ["telemetry.toggled"])
    }

    @Test func aFullOffThenOnRoundTripTellsHostsFalseThenTrue() async throws {
        let host = FakeHost()
        let setup = setup(hosts: [host])
        await setup.controller.setEnabled(false)
        await setup.controller.setEnabled(true)
        #expect(host.told == [false, true])
    }

    @Test func aHostThatConnectsWhileItIsOffIsToldOncePerConnection() async throws {
        let host = FakeHost(), plain = FakeHost(supports: false)
        let setup = setup(hosts: [], startsOn: false)
        let connection = UUID()
        await setup.controller.hostConnected(host, connection: connection)
        await setup.controller.hostConnected(host, connection: connection)
        #expect(host.told == [false], "a refresh on the same connection doesn't ask again")
        await setup.controller.hostConnected(host, connection: UUID())
        #expect(host.told == [false, false], "a new connection is told")
        await setup.controller.hostConnected(plain, connection: UUID())
        #expect(plain.told.isEmpty)
    }

    @Test func aHostThatConnectsWhileItIsOnIsNeverTold() async throws {
        let host = FakeHost()
        let setup = setup(hosts: [])
        await setup.controller.hostConnected(host, connection: UUID())
        #expect(host.told.isEmpty)
    }

    @Test func aFailedTellIsTriedAgainOnTheNextConnectionRefresh() async throws {
        let host = FakeHost()
        let setup = setup(hosts: [], startsOn: false)
        let connection = UUID()
        host.failing = true
        await setup.controller.hostConnected(host, connection: connection)
        host.failing = false
        await setup.controller.hostConnected(host, connection: connection)
        #expect(host.told == [false])
    }

    /// A host that was about to be told "off" when the person switched back on is not told: the host
    /// stays on, matching the app. And the reverse, so a quick on then off can't leave a host on.
    @Test func quickChangesNeverLeaveAHostDifferentFromTheApp() async throws {
        final class SlowHost: TelemetryHostEndpoint {
            let supportsTelemetrySwitch = true
            private(set) var told: [Bool] = []
            func setTelemetry(enabled: Bool) async throws {
                for _ in 0..<5 { await Task.yield() }
                told.append(enabled)
            }
        }
        let host = SlowHost()
        let defaults = UserDefaults(suiteName: "telemetry-\(UUID().uuidString)")!
        let preference = TelemetryPreference(defaults: defaults)
        let rig = TelemetryTestRig.make()
        var marks: [Bool] = []
        let controller = TelemetryController(preference: preference, client: { rig.client },
                                             receipts: BighelpDeliveryReceipts(fileURL: nil),
                                             markEnabled: { marks.append($0) },
                                             visitHosts: { body in await body(host) })
        // Off, on, off, started without waiting for each other.
        async let first: Void = controller.setEnabled(false)
        async let second: Void = controller.setEnabled(true)
        async let third: Void = controller.setEnabled(false)
        _ = await (first, second, third)
        #expect(!controller.isEnabled && !preference.isEnabled)
        #expect(host.told.last == false, "the host's last word matches the app")
        #expect(!host.told.contains(true), "no PUT of true goes out for a change already undone")
        #expect(await !rig.client.enabled && rig.identity.current == nil)
        #expect(marks == [false, true, false])

        // And ending on: a host told off earlier is told on at the end, and never the other way round.
        let ending = TelemetryController(preference: TelemetryPreference(defaults: UserDefaults(suiteName: "telemetry-\(UUID().uuidString)")!),
                                         client: { rig.client }, receipts: BighelpDeliveryReceipts(fileURL: nil),
                                         markEnabled: { _ in }, visitHosts: { body in await body(host) })
        let before = host.told.count
        async let a: Void = ending.setEnabled(false)
        async let b: Void = ending.setEnabled(true)
        _ = await (a, b)
        #expect(ending.isEnabled)
        #expect(host.told.dropFirst(before).last != false, "never left off while the app is on")
    }

    @Test func aHostThatFailsNeverBlocksTheSwitch() async throws {
        let broken = FakeHost(), fine = FakeHost()
        broken.failing = true
        let setup = setup(hosts: [broken, fine])
        await setup.controller.setEnabled(false)
        #expect(!setup.controller.isEnabled)
        #expect(fine.told == [false])
    }

    @Test func withNoClientTheSwitchStillWorks() async throws {
        let host = FakeHost()
        let defaults = UserDefaults(suiteName: "telemetry-\(UUID().uuidString)")!
        let controller = TelemetryController(preference: TelemetryPreference(defaults: defaults), client: { nil },
                                             receipts: BighelpDeliveryReceipts(fileURL: nil), markEnabled: { _ in },
                                             visitHosts: { body in await body(host) })
        await controller.setEnabled(false)
        await controller.setEnabled(true)
        #expect(host.told == [false, true])
    }

    @Test func demoHostStandsInForAHostWithTheCapability() async throws {
        let demo = DemoTelemetryHosts()
        let defaults = UserDefaults(suiteName: "telemetry-\(UUID().uuidString)")!
        let controller = TelemetryController(preference: TelemetryPreference(defaults: defaults), client: { nil },
                                             receipts: BighelpDeliveryReceipts(fileURL: nil), markEnabled: { _ in },
                                             visitHosts: demo.visitor)
        await controller.setEnabled(false)
        #expect(demo.told == [false])
    }
}

/// `PUT /api/plugins/loopdy/native/telemetry` through the plugin client.
@MainActor
struct TelemetryHostRouteTests {
    private final class Performer: WorkspaceOperationPerforming {
        var owner: WorkspaceOwner?
        var capabilities: WorkspaceCapabilities { .init(owner: owner, values: [:]) }
        var failures: [any Error] = []
        private(set) var calls: [(WorkspaceOperation, [String: BighelpJSONValue])] = []
        init() throws {
            owner = WorkspaceOwner(authority: try .fixture(id: UUID().uuidString), authenticationGeneration: UUID(),
                                   connectionGeneration: UUID())
        }
        func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                     owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
            calls.append((operation, payload))
            if !failures.isEmpty { throw failures.removeFirst() }
            return [:]
        }
    }

    @Test func theEndpointSendsOnlyTheEnabledFlag() async throws {
        let performer = try Performer()
        let host = WorkspaceTelemetryHostEndpoint(workspace: performer, owner: try #require(performer.owner),
                                                  features: { ["native-context-v1", "native-host-telemetry-v1"] })
        #expect(host.supportsTelemetrySwitch)
        try await host.setTelemetry(enabled: false)
        #expect(performer.calls.count == 1)
        #expect(performer.calls[0].0 == .telemetrySet)
        #expect(performer.calls[0].1 == ["enabled": .boolean(false)])
    }

    @Test func theCapabilityDecidesWhetherAHostSupportsIt() throws {
        let performer = try Performer()
        let owner = try #require(performer.owner)
        #expect(!WorkspaceTelemetryHostEndpoint(workspace: performer, owner: owner, features: { [] }).supportsTelemetrySwitch)
        #expect(!WorkspaceTelemetryHostEndpoint(workspace: performer, owner: owner,
                                                features: { ["native-context-v1", "native-people-v1"] }).supportsTelemetrySwitch)
        #expect(WorkspaceTelemetryHostEndpoint.feature == "native-host-telemetry-v1")
    }

    @Test func aChangedContextIsRetriedOnce() async throws {
        let performer = try Performer()
        performer.failures = [WorkspaceClientError.conflict]
        let host = WorkspaceTelemetryHostEndpoint(workspace: performer, owner: try #require(performer.owner), features: { [] })
        try await host.setTelemetry(enabled: true)
        #expect(performer.calls.count == 2)
        performer.failures = [WorkspaceClientError.conflict, WorkspaceClientError.conflict]
        await #expect(throws: WorkspaceClientError.conflict) { try await host.setTelemetry(enabled: true) }
    }

    @Test func theNativeGuardAllowsTheTelemetryPutAndNoOtherPut() {
        let base = "/api/plugins/loopdy/native/"
        #expect(DirectHermesHTTP.allowsNativeGuard(route: base + "telemetry", method: "PUT"))
        #expect(DirectHermesHTTP.allowsNativeGuard(route: base + "people/speaking", method: "POST"))
        #expect(!DirectHermesHTTP.allowsNativeGuard(route: base + "people/speaking", method: "PUT"))
        #expect(!DirectHermesHTTP.allowsNativeGuard(route: base + "telemetry", method: "GET"))
        #expect(!DirectHermesHTTP.allowsNativeGuard(route: base + "telemetry", method: "DELETE"))
        #expect(!DirectHermesHTTP.allowsNativeGuard(route: "/api/other/telemetry", method: "PUT"))
        #expect(DirectHermesNativePluginClient.supports(.telemetrySet))
    }
}
