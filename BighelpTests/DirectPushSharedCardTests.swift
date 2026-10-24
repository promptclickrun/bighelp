import Foundation
import Testing
@testable import Bighelp

/// The shared Live Activity card is one physical ActivityKit activity. The notification service looks its
/// push token up by the card's group ID, the `groupId` of the version 3 registration, so that is what the
/// direct push address is registered under, and removed from when the card ends.
@MainActor struct DirectPushSharedCardTests {
    nonisolated private static let token = Data(repeating: 0x7C, count: 32)

    /// A stand-in for ActivityKit: one physical card at a time.
    @MainActor private final class System: BighelpLiveActivityDriving {
        private(set) var physicalIDs: [String] = []
        private var current: LoopdySessionActivityAttributes.ContentState?
        private var attributes: LoopdySessionActivityAttributes?
        private var ended = Set<String>()
        func start(attributes: LoopdySessionActivityAttributes, state: LoopdySessionActivityAttributes.ContentState) throws -> String {
            let id = "system-" + UUID().uuidString.lowercased()
            physicalIDs.append(id); current = state; self.attributes = attributes
            return id
        }
        func update(id: String, state: LoopdySessionActivityAttributes.ContentState) async { current = state }
        func end(id: String, state: LoopdySessionActivityAttributes.ContentState) async { ended.insert(id) }
        func currentPushToken(id: String) -> Data? { DirectPushSharedCardTests.token }
        func pushTokenUpdates(id: String) -> AsyncStream<Data> { AsyncStream { $0.finish() } }
        func existingActivities() -> [BighelpLiveActivitySnapshot] {
            guard let current, let attributes, let id = physicalIDs.last, !ended.contains(id) else { return [] }
            return [.init(nativeActivityID: id, attributes: attributes, state: current, pushToken: nil)]
        }
    }

    private func attributes(_ id: String) -> LoopdySessionActivityAttributes {
        .make(sessionID: id, sessionTitle: "Chat", agentID: "juno", agentName: "Juno")!
    }

    private func state(_ phase: LoopdySessionActivityAttributes.ContentState.Phase) -> LoopdySessionActivityAttributes.ContentState {
        .init(phase: phase, currentAction: "", progress: 0, completedSteps: 0, activeSubagentCount: 0,
              latestTool: nil, timestamp: 100)
    }

    /// The card, wired to a registrar the way the app wires it.
    private func card(_ phone: PushRegistrarTests.Phone) -> (System, BighelpActivityGroupDriver) {
        let system = System()
        var infos: [String: BighelpActivitySessionInfo] = [:]
        let group = BighelpActivityGroupDriver(underlying: system, loadInfos: { infos }, saveInfos: { infos = $0 })
        let registrar = phone.registrar!
        group.onPhysicalEnded = { physicalID in Task { await registrar.sharedCardEnded(physicalID: physicalID) } }
        return (system, group)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aSharedRowIsRegisteredUnderTheCardsGroupIDNotItsOwnAlias() throws {
        let (system, group) = card(PushRegistrarTests.Phone())
        let row = try group.start(attributes: attributes("a"), state: state(.thinking))
        let physical = try #require(system.physicalIDs.last)
        let groupID = BighelpManagedActivityDriver.relayID(physical)
        // The version 3 registration sends `relayID(physicalID(row))` as its groupId.
        #expect(BighelpActivityGroupDriver.physicalID(row) == physical)
        let alias = BighelpManagedActivityDriver.relayID(row)
        #expect(alias != groupID)
        #expect(BighelpPushRegistrar.targetID(nativeActivityID: row, relayActivityID: alias) == groupID)
    }

    @Test func anIndividualRegistrationKeepsItsOwnActivityID() {
        let native = "5E2A9C3C-0000-4000-8000-000000000001"
        let relay = BighelpManagedActivityDriver.relayID(native)
        #expect(BighelpPushRegistrar.targetID(nativeActivityID: native, relayActivityID: relay) == relay)
    }

    @Test func tworowsOfOneCardShareOneAddressAndItGoesWhenTheCardEnds() async throws {
        let phone = PushRegistrarTests.Phone()
        defer { phone.cleanup() }
        let (system, group) = card(phone)
        let a = try group.start(attributes: attributes("a"), state: state(.thinking))
        let b = try group.start(attributes: attributes("b"), state: state(.thinking))
        let physical = try #require(system.physicalIDs.last)
        let groupID = BighelpManagedActivityDriver.relayID(physical)
        // Each row's registration offers the same card token under the same ID.
        for row in [a, b] {
            let id = BighelpPushRegistrar.targetID(nativeActivityID: row, relayActivityID: BighelpManagedActivityDriver.relayID(row))
            await phone.registrar.registerActivity(id: id, token: Self.token)
        }
        #expect(phone.worker.puts.count == 1, "One card, one address")
        #expect(phone.worker.puts.first?.body["activityId"] as? String == groupID)
        #expect(phone.worker.puts.first?.body["kind"] as? String == "liveactivity")
        #expect(phone.worker.targets.keys.sorted() == ["liveactivity:" + groupID])

        // One chat finishing leaves the card, and its address, in place.
        await group.end(id: a, state: state(.completed))
        try? await Task.sleep(for: .milliseconds(40))
        #expect(phone.worker.deletes.isEmpty)
        // The last one ends the card, and the address goes.
        await group.end(id: b, state: state(.completed))
        await waitFor { !phone.worker.deletes.isEmpty }
        let delete = try #require(phone.worker.deletes.first)
        #expect(delete.path == BighelpPushRegistrar.liveActivityTargetPath)
        #expect(delete.body as NSDictionary == ["version": 1, "kind": "liveactivity", "activityId": groupID] as NSDictionary)
        #expect(phone.worker.targets.isEmpty)
        #expect(phone.worker.rateLimited == 0)
    }

    @Test func aDismissedCardAndAnInvalidatedCardRemoveTheirAddressToo() async throws {
        let phone = PushRegistrarTests.Phone()
        defer { phone.cleanup() }
        let (system, group) = card(phone)
        let row = try group.start(attributes: attributes("a"), state: state(.thinking))
        let first = try #require(system.physicalIDs.last)
        await phone.registrar.registerActivity(id: BighelpManagedActivityDriver.relayID(first), token: Self.token)
        await group.dismiss(id: row, state: state(.completed))
        await waitFor { phone.worker.deletes.count == 1 }
        #expect(phone.worker.deletes.first?.body["activityId"] as? String == BighelpManagedActivityDriver.relayID(first))

        // The server ended the card's group: the app drops the card and its address.
        let again = try group.start(attributes: attributes("b"), state: state(.thinking))
        let second = try #require(system.physicalIDs.last)
        #expect(second != first)
        phone.clock.advance(11 * 60)
        await phone.registrar.registerActivity(id: BighelpManagedActivityDriver.relayID(second), token: Self.token)
        await group.invalidate(id: again)
        await waitFor { phone.worker.deletes.count == 2 }
        #expect(phone.worker.deletes.last?.body["activityId"] as? String == BighelpManagedActivityDriver.relayID(second))
    }
}
