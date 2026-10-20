import Foundation
import Testing
@testable import Bighelp

@MainActor
struct NativeInvalidationAndReactionTests {
    @Test func emptyCanonicalSessionsKeepTheirVerifiedOwnerUntilPublished() {
        var record = SessionRecord(id: "chat", kind: .direct, agentIDs: ["default"], title: "Bot Chat")
        #expect(NativeWorkspaceSessionBridge.preservesUnpublishedCanonical(record, wasCreated: false, durability: .persisted))
        record.hasAcceptedMessage = true
        #expect(!NativeWorkspaceSessionBridge.preservesUnpublishedCanonical(record, wasCreated: false, durability: .persisted))
        #expect(NativeWorkspaceSessionBridge.preservesUnpublishedCanonical(record, wasCreated: true, durability: .persisted))
        #expect(NativeWorkspaceSessionBridge.preservesUnpublishedCanonical(record, wasCreated: false, durability: .draft))
    }

    @Test func sessionInvalidationsCoalesceAndRetainOneTrailingRefresh() async throws {
        let source = try makeSource()
        var refreshes = 0
        var release: CheckedContinuation<Void, Never>?
        let coordinator = NativeWorkspaceInvalidationCoordinator(currentSource: { source }, refreshSessions: { _ in
            refreshes += 1
            if refreshes == 1 { await withCheckedContinuation { release = $0 } }
        }, refreshScheduledTasks: { _ in Issue.record("Sessions event refreshed cron") }, publish: { _, _ in },
            minimumSessionsRefreshGap: .zero)
        defer { coordinator.suspend() }
        let event = try decode(#"{"jsonrpc":"2.0","method":"event","params":{"type":"sessions.changed","session_id":"","payload":{}}}"#)
        #expect(coordinator.receive(event, source: source))
        #expect(coordinator.receive(event, source: source))
        for _ in 0..<100 where release == nil { await Task.yield() }
        guard let held = release else { Issue.record("Initial refresh did not start"); return }
        #expect(refreshes == 1)
        #expect(coordinator.receive(event, source: source))
        held.resume()
        for _ in 0..<100 where refreshes < 2 { await Task.yield() }
        #expect(refreshes == 2)
    }

    @Test func changesArrivingDuringCooldownJoinTheUpcomingRead() async throws {
        let source = try makeSource()
        let clock = InvalidationTestClock()
        var refreshes = 0
        var release: CheckedContinuation<Void, Never>?
        let coordinator = NativeWorkspaceInvalidationCoordinator(currentSource: { source }, refreshSessions: { _ in
            refreshes += 1
            if refreshes == 2 { await withCheckedContinuation { release = $0 } }
        }, refreshScheduledTasks: { _ in }, publish: { _, _ in },
            minimumSessionsRefreshGap: .seconds(5), now: { clock.now }, sleep: { await clock.sleep($0) })
        defer { coordinator.suspend(); release?.resume(); clock.releaseAll() }
        let event = try change("sessions.changed")
        #expect(coordinator.receive(event, source: source))
        try await waitUntil { refreshes == 1 }
        #expect(clock.waits.isEmpty, "The first refresh starts immediately.")
        #expect(coordinator.receive(event, source: source))
        try await waitUntil { clock.waits.count == 1 }
        for _ in 0..<3 { #expect(coordinator.receive(event, source: source)) }
        clock.advanceAndRelease(.seconds(5))
        try await waitUntil { release != nil }
        release?.resume(); release = nil
        for _ in 0..<100 { await Task.yield() }
        #expect(refreshes == 2)
        #expect(clock.waits == [.seconds(5)], "Cooldown arrivals are covered by the read that follows the wait.")
    }

    @Test func changesDuringTheActualReadKeepOnePacedTrailingRead() async throws {
        let source = try makeSource()
        let clock = InvalidationTestClock()
        var refreshes = 0
        var release: CheckedContinuation<Void, Never>?
        let coordinator = NativeWorkspaceInvalidationCoordinator(currentSource: { source }, refreshSessions: { _ in
            refreshes += 1
            if refreshes == 1 { await withCheckedContinuation { release = $0 } }
        }, refreshScheduledTasks: { _ in }, publish: { _, _ in },
            minimumSessionsRefreshGap: .seconds(5), now: { clock.now }, sleep: { await clock.sleep($0) })
        defer { coordinator.suspend(); release?.resume(); clock.releaseAll() }
        let event = try change("sessions.changed")
        #expect(coordinator.receive(event, source: source))
        try await waitUntil { release != nil }
        for _ in 0..<3 { #expect(coordinator.receive(event, source: source)) }
        release?.resume(); release = nil
        try await waitUntil { clock.waits.count == 1 }
        #expect(refreshes == 1)
        clock.advanceAndRelease(.seconds(5))
        try await waitUntil { refreshes == 2 }
        #expect(clock.waits == [.seconds(5)])
    }

    @Test(arguments: [false, true])
    func aRetiredRefreshCannotSetTheNextConnectionsCooldown(switchHost: Bool) async throws {
        let first = try makeSource()
        let next = switchHost ? try makeSource() : first
        var current = first
        let clock = InvalidationTestClock()
        var refreshes = 0
        var release: CheckedContinuation<Void, Never>?
        var oldReadReturned = false
        let coordinator = NativeWorkspaceInvalidationCoordinator(currentSource: { current }, refreshSessions: { _ in
            refreshes += 1
            if refreshes == 1 {
                await withCheckedContinuation { release = $0 }
                oldReadReturned = true
            }
        }, refreshScheduledTasks: { _ in }, publish: { _, _ in },
            minimumSessionsRefreshGap: .seconds(5), now: { clock.now }, sleep: { await clock.sleep($0) })
        defer { coordinator.suspend(); release?.resume(); clock.releaseAll() }
        let event = try change("sessions.changed")
        #expect(coordinator.receive(event, source: first))
        try await waitUntil { release != nil }
        coordinator.suspend()
        current = next
        #expect(coordinator.receive(try change("platforms.changed"), source: next))
        release?.resume(); release = nil
        try await waitUntil { oldReadReturned }
        #expect(coordinator.receive(event, source: next))
        try await waitUntil { refreshes == 2 || !clock.waits.isEmpty }
        #expect(refreshes == 2, "A new connection gets an immediate first refresh.")
        #expect(clock.waits.isEmpty, "An old completion must not write the new connection's clock.")
    }

    @Test func scheduledTasksDoNotWaitForTheSessionCooldown() async throws {
        let source = try makeSource()
        let clock = InvalidationTestClock()
        var sessions = 0
        var scheduled = 0
        let coordinator = NativeWorkspaceInvalidationCoordinator(currentSource: { source },
            refreshSessions: { _ in sessions += 1 }, refreshScheduledTasks: { _ in scheduled += 1 },
            publish: { _, _ in }, minimumSessionsRefreshGap: .seconds(5),
            now: { clock.now }, sleep: { await clock.sleep($0) })
        defer { coordinator.suspend(); clock.releaseAll() }
        let event = try change("sessions.changed")
        #expect(coordinator.receive(event, source: source))
        try await waitUntil { sessions == 1 }
        #expect(coordinator.receive(event, source: source))
        try await waitUntil { clock.waits.count == 1 }
        #expect(coordinator.receive(try change("cron.changed"), source: source))
        for _ in 0..<100 { await Task.yield() }
        #expect(scheduled == 1, "Unrelated management refreshes run while the session clock is held.")
        #expect(sessions == 1)
    }

    @Test func aHostSwitchCancelsTheHeldCooldown() async throws {
        let first = try makeSource()
        let next = try makeSource()
        var current = first
        let clock = InvalidationTestClock()
        var refreshed: [NativeWorkspaceEventSource] = []
        let coordinator = NativeWorkspaceInvalidationCoordinator(currentSource: { current },
            refreshSessions: { refreshed.append($0) }, refreshScheduledTasks: { _ in }, publish: { _, _ in },
            minimumSessionsRefreshGap: .seconds(5), now: { clock.now }, sleep: { await clock.sleep($0) })
        defer { coordinator.suspend(); clock.releaseAll() }
        let event = try change("sessions.changed")
        #expect(coordinator.receive(event, source: first))
        try await waitUntil { refreshed.count == 1 }
        #expect(coordinator.receive(event, source: first))
        try await waitUntil { clock.waits.count == 1 }
        current = next
        #expect(coordinator.receive(event, source: next))
        try await waitUntil { refreshed.count == 2 }
        clock.advanceAndRelease(.seconds(5))
        for _ in 0..<100 { await Task.yield() }
        #expect(refreshed == [first, next])
        #expect(!coordinator.receive(event, source: first))
    }

    private func change(_ type: String) throws -> DirectHermesEvent {
        try decode("{\"jsonrpc\":\"2.0\",\"method\":\"event\",\"params\":{\"type\":\"\(type)\",\"session_id\":\"\",\"payload\":{}}}")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }

    @Test func resumeProgressIsExactSessionTransientStateNotCatalogWork() throws {
        let source = try makeSource()
        var notices: [NativeWorkspaceInvalidationNotice] = []
        let coordinator = NativeWorkspaceInvalidationCoordinator(currentSource: { source },
            refreshSessions: { _ in Issue.record("Resume progress refreshed sessions") },
            refreshScheduledTasks: { _ in Issue.record("Resume progress refreshed cron") },
            publish: { _, notice in notices.append(notice) })
        defer { coordinator.suspend() }
        let loading = try decode(#"{"jsonrpc":"2.0","method":"event","params":{"type":"session.resume_progress","session_id":"runtime-A","payload":{"phase":"history","status":"loading"}}}"#)
        let done = try decode(#"{"jsonrpc":"2.0","method":"event","params":{"type":"session.resume_progress","session_id":"runtime-A","payload":{"phase":"history","status":"complete","message_count":42}}}"#)
        _ = coordinator.receive(loading, source: source)
        _ = coordinator.receive(loading, source: source)
        _ = coordinator.receive(done, source: source)
        #expect(notices.count == 2)
        guard case .resumeProgress(let first) = notices.first, case .resumeProgress(let last) = notices.last else {
            Issue.record("Missing progress pair"); return
        }
        #expect(first.requestID == last.requestID)
        #expect(first.runtimeSessionID == "runtime-A")
        #expect(last.state == .complete(messageCount: 42))
    }

    /// The feed belongs to the connection, not to whichever agent it last opened: a change that names
    /// another agent (a chat opened from a notification switched agents) still reaches the screens.
    @Test func changesFromAnotherAgentStillReachTheScreens() throws {
        let source = try makeSource()
        var notices: [NativeWorkspaceInvalidationNotice] = []
        let coordinator = NativeWorkspaceInvalidationCoordinator(currentSource: { source },
            refreshSessions: { _ in }, refreshScheduledTasks: { _ in },
            publish: { _, notice in notices.append(notice) })
        defer { coordinator.suspend() }
        let platforms = try decode(#"{"jsonrpc":"2.0","method":"event","params":{"type":"platforms.changed","session_id":"","payload":{},"profile":"alfie"}}"#)
        #expect(coordinator.receive(platforms, source: source))
        #expect(notices == [.platformsChanged])
    }

    @Test func reactionIdentityUsesOnlyCanonicalDecimalRowSuffix() {
        #expect(NativeMessageReactionRowIdentity.rowID(from: "saved:row:42") == 42)
        for invalid in ["42", "saved:row:", "saved:row:42:extra", "saved:row:４２", "saved:row:-1"] {
            #expect(NativeMessageReactionRowIdentity.rowID(from: invalid) == nil)
        }
    }

    private func makeSource() throws -> NativeWorkspaceEventSource {
        let owner = WorkspaceOwner(authority: try .direct(endpointIdentity: "https://fixture.example.test", providerID: "test", userID: "invalidation"),
            authenticationGeneration: UUID(), connectionGeneration: UUID())
        return .init(hostID: UUID(), owner: owner, servingProfileID: "default")
    }

    private func decode(_ text: String) throws -> DirectHermesEvent {
        guard case .event(let event) = try DirectHermesWire.decode(Data(text.utf8)).first else {
            throw DirectHermesError.invalidResponse
        }
        return event
    }
}

@MainActor
private final class InvalidationTestClock {
    var now = ContinuousClock.now
    var waits: [Duration] = []
    private var sleepers: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async {
        waits.append(duration)
        await withCheckedContinuation { sleepers.append($0) }
    }

    func advanceAndRelease(_ duration: Duration) {
        now += duration
        sleepers.removeFirst().resume()
    }

    func releaseAll() {
        let pending = sleepers
        sleepers.removeAll()
        for sleeper in pending { sleeper.resume() }
    }
}
