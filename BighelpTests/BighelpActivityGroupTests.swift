import Foundation
import Testing
@testable import Bighelp

@MainActor
struct BighelpActivityGroupTests {
    @Test func multipleChatsShareOneSystemCardAndFinishIndependently() async throws {
        let system = GroupSystemDriver()
        let group = system.makeGroup()
        let a = try group.start(attributes: attributes("a"), state: state(.thinking))
        let b = try group.start(attributes: attributes("b"), state: state(.waiting))
        await group.update(id: b, state: state(.waiting))
        #expect(system.starts == 1)
        #expect(a != b)
        #expect(system.current?.sessions?.map(\.id) == ["b", "a"])
        await group.end(id: b, state: state(.completed))
        #expect(system.ends == 0)
        #expect(system.current?.activeCount == 1)
        await group.end(id: a, state: state(.completed))
        #expect(system.ends == 1)
    }

    @Test func failedStartDoesNotPoisonRetryOrLoseExistingRows() async throws {
        let system = GroupSystemDriver()
        let group = system.makeGroup()
        system.refuseStart = true
        #expect(throws: (any Error).self) { try group.start(attributes: attributes("a"), state: state(.thinking)) }
        system.refuseStart = false
        _ = try group.start(attributes: attributes("a"), state: state(.thinking))
        _ = try group.start(attributes: attributes("b"), state: state(.thinking))
        #expect(system.starts == 1)
        #expect(group.existingActivities().count == 2)
    }

    @Test func restoringSharedCardDoesNotRequestAnotherCard() async throws {
        let system = GroupSystemDriver()
        let original = system.makeGroup()
        _ = try original.start(attributes: attributes("a"), state: state(.thinking))
        let b = try original.start(attributes: attributes("b"), state: state(.waiting))
        await original.update(id: b, state: state(.waiting))
        let restored = system.makeGroup()
        #expect(Set(restored.existingActivities().map { $0.attributes.sessionID }) == ["a", "b"])
        _ = try restored.start(attributes: attributes("c"), state: state(.thinking))
        #expect(system.starts == 1)
    }

    @Test func hiddenChatsSurviveRestorationAndKeepCardAlive() async throws {
        let system = GroupSystemDriver()
        let original = system.makeGroup()
        var ids: [String] = []
        for i in 0..<8 { ids.append(try original.start(attributes: attributes("chat-\(i)"), state: state(.thinking))) }
        await original.update(id: ids[0], state: state(.thinking))
        let restored = system.makeGroup()
        #expect(restored.existingActivities().count == 8)
        for id in ids.prefix(5) { await restored.end(id: id, state: state(.completed)) }
        #expect(system.ends == 0)
        #expect(system.current?.activeCount == 3)
    }

    @Test func hiddenRemoteCompletionAndLocalDismissalDoNotResurrectOnRestore() async throws {
        let system = GroupSystemDriver()
        let group = system.makeGroup()
        var ids: [String] = []
        for i in 0..<8 { ids.append(try group.start(attributes: attributes("chat-\(i)"), state: state(.thinking))) }
        await group.update(id: ids[0], state: state(.thinking))
        // chat-7 finishes remotely outside the five visible rows.
        let remote = BighelpActivitySession.aggregate((0..<7).map {
            .init(id: "chat-\($0)", phase: .thinking, timestamp: 101)
        }, timestamp: 101)
        system.current = remote
        let restored = system.makeGroup()
        #expect(restored.existingActivities().count == 7)
        #expect(!restored.existingActivities().contains { $0.attributes.sessionID == "chat-7" })
        await restored.dismiss(id: ids[6], state: state(.completed))
        // A queued older remote state must not resurrect an explicitly dismissed row.
        system.current = remote
        let again = system.makeGroup()
        #expect(again.existingActivities().count == 6)
        #expect(!again.existingActivities().contains { $0.attributes.sessionID == "chat-6" })
        await again.update(id: ids[0], state: state(.thinking))
        #expect(system.current?.activeCount == 6)
    }

    @Test func newTurnCannotReuseCardWhileEndIsSuspended() async throws {
        let system = GroupSystemDriver()
        let group = system.makeGroup()
        let old = try group.start(attributes: attributes("a"), state: state(.thinking))
        await group.update(id: old, state: state(.thinking))
        system.holdEnd = true
        let ending = Task { await group.end(id: old, state: state(.completed)) }
        while system.endContinuation == nil { await Task.yield() }
        let next = try group.start(attributes: attributes("b"), state: state(.thinking))
        #expect(BighelpActivityGroupDriver.physicalID(old) != BighelpActivityGroupDriver.physicalID(next))
        system.endContinuation?.resume(); system.endContinuation = nil
        await ending.value
        await group.update(id: next, state: state(.thinking))
        #expect(group.existingActivities().map { $0.attributes.sessionID } == ["b"])
    }

    @Test func sharedPayloadIsBoundedAndOldPayloadStillDecodes() throws {
        let rows = (0..<40).map { i in BighelpActivitySession(id: "session-\(i)", phase: i == 39 ? .waiting : .thinking, timestamp: 100) }
        let aggregate = BighelpActivitySession.aggregate(rows, timestamp: 100)
        #expect(aggregate.sessions?.count == 5)
        #expect(aggregate.sessions?.first?.id == "session-39")
        #expect(aggregate.activeCount == 40)
        #expect(try JSONEncoder().encode(aggregate).count < 3500)
        let old = state(.thinking)
        let decoded = try JSONDecoder().decode(LoopdySessionActivityAttributes.ContentState.self, from: JSONEncoder().encode(old))
        #expect(decoded.sessions == nil)
    }

    private func attributes(_ id: String) -> LoopdySessionActivityAttributes {
        .make(sessionID: id, sessionTitle: "Chat", agentID: "juno", agentName: "Juno")!
    }
    private func state(_ phase: LoopdySessionActivityAttributes.ContentState.Phase) -> LoopdySessionActivityAttributes.ContentState {
        .init(phase: phase, currentAction: "", progress: 0, completedSteps: 0, activeSubagentCount: 0, latestTool: nil, timestamp: 100)
    }
}

@MainActor
private final class GroupSystemDriver: BighelpLiveActivityDriving {
    enum Failure: Error { case background }
    var infos: [String: BighelpActivitySessionInfo] = [:]
    func makeGroup() -> BighelpActivityGroupDriver {
        BighelpActivityGroupDriver(underlying: self, loadInfos: { self.infos }, saveInfos: { self.infos = $0 })
    }
    var refuseStart = false
    var holdEnd = false
    var endContinuation: CheckedContinuation<Void, Never>?
    private var physicalID = UUID().uuidString
    private var endedIDs = Set<String>()
    var starts = 0
    var ends = 0
    var current: LoopdySessionActivityAttributes.ContentState?
    var attributes: LoopdySessionActivityAttributes?
    func start(attributes: LoopdySessionActivityAttributes, state: LoopdySessionActivityAttributes.ContentState) throws -> String {
        if refuseStart { throw Failure.background }
        starts += 1; current = state; self.attributes = attributes
        physicalID = UUID().uuidString
        return physicalID
    }
    func update(id: String, state: LoopdySessionActivityAttributes.ContentState) async { current = state }
    func end(id: String, state: LoopdySessionActivityAttributes.ContentState) async {
        if holdEnd { await withCheckedContinuation { endContinuation = $0 } }
        if id == physicalID { current = state }
        endedIDs.insert(id); ends += 1
    }
    func currentPushToken(id: String) -> Data? { nil }
    func pushTokenUpdates(id: String) -> AsyncStream<Data> { AsyncStream { $0.finish() } }
    func existingActivities() -> [BighelpLiveActivitySnapshot] {
        guard let current, let attributes, !endedIDs.contains(physicalID) else { return [] }
        return [.init(nativeActivityID: physicalID, attributes: attributes, state: current, pushToken: nil)]
    }
}
