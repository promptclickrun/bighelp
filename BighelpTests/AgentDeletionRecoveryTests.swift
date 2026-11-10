import Foundation
import Testing
@testable import Bighelp

/// Delete Agent, when its answer is lost. Hermes takes up to ten seconds to stop an agent before it
/// removes it, and the app's connection can change in that time. The agent is then gone on the
/// computer while the app said "The selected host or connection changed" and left its pages up.
@MainActor
struct AgentDeletionRecoveryTests {
    /// A computer as the recovery sees it, counting how often its agent list was read.
    @MainActor private final class Computer {
        var isSame = true
        var readyAfterReads = 0
        var hasAgent = false
        var reads = 0
        var checks = 0

        var host: AgentDeletionRecovery.Host {
            .init(isSameComputer: { self.isSame },
                  isReady: {
                      self.checks += 1
                      return self.checks > self.readyAfterReads
                  },
                  reloadAgents: { self.reads += 1 },
                  hasAgent: { self.hasAgent })
        }
    }

    @Test func aChangedOrLostConnectionLeavesTheOutcomeOpenAndARefusalDoesNot() {
        let open: [any Error] = [
            HermesProfileLifecycleError.ownerChanged, HermesProfileLifecycleError.outcomeUnknown,
            NativeWorkspaceLifecycleError.ownerChanged, WorkspaceClientError.ownerChanged,
            WorkspaceClientError.unavailable(.notConnected), DirectHermesError.disconnected(outcomeUnknown: true),
            DirectHermesError.timedOut(outcomeUnknown: true), DirectHermesError.notConnected,
        ]
        for error in open { #expect(AgentDeletionRecovery.leavesOutcomeOpen(error), "\(error)") }
        let refusals: [any Error] = [
            HermesProfileLifecycleError.currentProfileProtected, HermesProfileLifecycleError.activeDefaultProtected,
            NativeWorkspaceLifecycleError.profileInGroups(profileID: "travel", groupTitles: ["Trip"]),
            NativeWorkspaceLifecycleError.profileBusy(profileID: "travel"),
            WorkspaceClientError.authenticationRequired, CancellationError(),
        ]
        for error in refusals { #expect(!AgentDeletionRecovery.leavesOutcomeOpen(error), "\(error)") }
    }

    @Test func theComputersOwnAgentListSaysWhetherTheAgentIsGone() async {
        let gone = Computer()
        #expect(await AgentDeletionRecovery.confirmsDeleted(gone.host))
        #expect(gone.reads == 1)

        // Still there: the deletion never reached Hermes, so the error stands.
        let kept = Computer()
        kept.hasAgent = true
        #expect(await AgentDeletionRecovery.confirmsDeleted(kept.host) == false)
    }

    @Test func itWaitsForTheNewConnectionAndGivesUpWhenThereIsNone() async {
        // The computer comes back after a moment: the list is read only then.
        let late = Computer()
        late.readyAfterReads = 3
        #expect(await AgentDeletionRecovery.confirmsDeleted(late.host, timeout: .seconds(5), step: .milliseconds(5)))
        #expect(late.reads == 1 && late.checks == 4)

        let never = Computer()
        never.readyAfterReads = .max
        #expect(await AgentDeletionRecovery.confirmsDeleted(never.host, timeout: .milliseconds(40),
                                                             step: .milliseconds(5)) == false)
        #expect(never.reads == 0)

        // Another computer went in use: its list says nothing about this agent.
        let other = Computer()
        other.isSame = false
        #expect(await AgentDeletionRecovery.confirmsDeleted(other.host) == false)
        #expect(other.reads == 0)
    }
}
