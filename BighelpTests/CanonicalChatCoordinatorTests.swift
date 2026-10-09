import Foundation
import Testing
@testable import Bighelp

@MainActor
struct CanonicalChatCoordinatorTests {
    @Test func opensOnlyTheCanonicalIdentityReturnedForThisProfileAndOwner() async throws {
        let owner = try owner()
        let coordinator = CanonicalChatCoordinator()
        var opened: [String] = []
        let request = coordinator.open(profileID: "studio", owner: owner, resolve: { profile, expected in
            #expect(profile == "studio")
            #expect(expected == owner)
            return "canonical-compressed-successor"
        }, canPresent: { true }, present: { opened.append($0) }, failed: { Issue.record("Unexpected failure") })
        await request.value
        #expect(opened == ["canonical-compressed-successor"])
    }

    @Test func aFailedLookupDoesNotOpenAnOrdinaryChat() async throws {
        let coordinator = CanonicalChatCoordinator()
        var opened: [String] = []
        var failed = false
        let request = coordinator.open(profileID: "studio", owner: try owner(), resolve: { _, _ in
            throw WorkspaceClientError.transportUnavailable
        }, canPresent: { true }, present: { opened.append($0) }, failed: { failed = true })
        await request.value
        #expect(opened.isEmpty)
        #expect(failed)
    }

    @Test(arguments: [false, true])
    func navigationAndHostReplacementRetireLateSuccessAndFailure(fails: Bool) async throws {
        let coordinator = CanonicalChatCoordinator()
        let gate = AsyncOperationTestGate()
        var isCurrent = true
        var opened: [String] = []
        var failureCount = 0
        let request = coordinator.open(profileID: "studio", owner: try owner(), resolve: { _, _ in
            try await gate.wait()
            return "canonical"
        }, canPresent: { isCurrent }, present: { opened.append($0) }, failed: { failureCount += 1 })
        for _ in 0..<100 where !gate.entered { await Task.yield() }
        #expect(gate.entered)
        isCurrent = false
        coordinator.cancelIfSuperseded()
        // Even a return to the exact original route cannot revive the old request.
        isCurrent = true
        gate.finish(error: fails ? WorkspaceClientError.transportUnavailable : nil)
        await request.value
        #expect(opened.isEmpty)
        #expect(failureCount == 0)
    }

    @Test func pickingAnotherAgentSupersedesTheEarlierLookup() async throws {
        let coordinator = CanonicalChatCoordinator()
        let gate = AsyncOperationTestGate()
        var opened: [String] = []
        let first = coordinator.open(profileID: "first", owner: try owner(), resolve: { _, _ in
            try await gate.wait()
            return "first-chat"
        }, canPresent: { true }, present: { opened.append($0) }, failed: { Issue.record("Unexpected failure") })
        for _ in 0..<100 where !gate.entered { await Task.yield() }
        #expect(gate.entered)
        let second = coordinator.open(profileID: "second", owner: try owner(), resolve: { _, _ in "second-chat" },
            canPresent: { true }, present: { opened.append($0) }, failed: { Issue.record("Unexpected failure") })
        await second.value
        gate.finish()
        await first.value
        #expect(opened == ["second-chat"])
    }

    private func owner() throws -> WorkspaceOwner {
        WorkspaceOwner(authority: try .fixture(id: "canonical-chat"),
                       authenticationGeneration: UUID(), connectionGeneration: UUID())
    }
}
