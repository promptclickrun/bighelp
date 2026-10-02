import Foundation
import Testing
@testable import Bighelp

/// bighelp closes the host connection soon after you leave and reconnects when
/// you're back. Every reconnect is a new owner; it used to close whatever was
/// open, as if you'd switched computers.
struct WorkspaceReconnectTests {
    @Test func aReconnectIsTheSameSignIn() throws {
        let computer = try WorkspaceAuthority.fixture(id: "computer-1")
        let signIn = UUID()
        let before = WorkspaceOwner(authority: computer, authenticationGeneration: signIn, connectionGeneration: UUID())
        let after = WorkspaceOwner(authority: computer, authenticationGeneration: signIn, connectionGeneration: UUID())
        #expect(before != after)
        #expect(WorkspaceReconnect.classify(after.signIn, previous: before.signIn) == .sameSignIn)
    }

    @Test func anotherComputerOrSignInIsABoundary() throws {
        let computer = try WorkspaceAuthority.fixture(id: "computer-1")
        let other = try WorkspaceAuthority.fixture(id: "computer-2")
        let signIn = UUID()
        let before = WorkspaceOwner(authority: computer, authenticationGeneration: signIn, connectionGeneration: UUID())
        let signedInAgain = WorkspaceOwner(authority: computer, authenticationGeneration: UUID(), connectionGeneration: UUID())
        let switched = WorkspaceOwner(authority: other, authenticationGeneration: signIn, connectionGeneration: UUID())
        #expect(WorkspaceReconnect.classify(signedInAgain.signIn, previous: before.signIn) == .boundary)
        #expect(WorkspaceReconnect.classify(switched.signIn, previous: before.signIn) == .boundary)
        #expect(WorkspaceReconnect.classify(before.signIn, previous: nil) == .boundary)
    }
}

/// The pill under the Dynamic Island says what the connection is doing,
/// without getting in the way.
struct ConnectionIslandRulesTests {
    private func next(from phase: ConnectionIslandPhase, _ state: WorkspaceConnectionState,
                      hasConnected: Bool = true, hasNetwork: Bool = true, isActive: Bool = true,
                      isRecovering: Bool = false) -> (phase: ConnectionIslandPhase, after: Duration?) {
        ConnectionIslandRules.next(from: phase, state: state, hasConnected: hasConnected, hasNetwork: hasNetwork,
                                   isActive: isActive, isRecovering: isRecovering)
    }

    @Test func theFirstConnectionSaysConnecting() {
        let first = next(from: .hidden, .reconnecting, hasConnected: false)
        #expect(first.phase == .connecting)
        #expect(first.after == ConnectionIslandRules.showDelay)
        #expect(next(from: .connecting, .connected).phase == .connected)
    }

    @Test func aDropShowsAfterAMoment() {
        let drop = next(from: .hidden, .reconnecting)
        #expect(drop.phase == .reconnecting)
        #expect(drop.after == ConnectionIslandRules.showDelay)
        let worse = next(from: .reconnecting, .disconnected)
        #expect(worse.phase == .disconnected)
        #expect(worse.after == nil)
    }

    @Test func noNetworkAtAllSaysNoInternet() {
        #expect(next(from: .reconnecting, .disconnected, hasNetwork: false).phase == .noInternet)
    }

    @Test func comingBackSaysConnected() {
        #expect(next(from: .reconnecting, .connected).phase == .connected)
        #expect(next(from: .noInternet, .connected).phase == .connected)
        // A blip too quick to show stays quiet.
        #expect(next(from: .hidden, .connected).phase == .hidden)
        // Tucked away during a long outage, it still says so when it's back.
        #expect(next(from: .hidden, .connected, isRecovering: true).phase == .connected)
    }

    /// The pill is the only place a chat says the connection is down, so it stays
    /// until it's back; only "Connected!" goes away by itself.
    @Test func theConnectionStaysShownUntilItsBack() {
        for phase: ConnectionIslandPhase in [.connecting, .reconnecting, .disconnected, .noInternet] {
            #expect(ConnectionIslandRules.hideDelay(after: phase) == nil, "\(phase)")
        }
        #expect(ConnectionIslandRules.hideDelay(after: .connected) == ConnectionIslandRules.connectedHold)
        #expect(next(from: .disconnected, .disconnected).phase == .disconnected)
    }

    @Test func nothingShowsInTheBackground() {
        let away = next(from: .reconnecting, .reconnecting, isActive: false)
        #expect(away.phase == .hidden)
        #expect(away.after == nil)
    }

    @Test func eachStatusHasItsOwnMarkAndWords() {
        let shown: [ConnectionIslandPhase] = [.connecting, .reconnecting, .connected, .disconnected, .noInternet]
        let statuses = shown.compactMap { HostConnectionStatus(island: $0) }
        #expect(statuses.map(\.label) == ["Connecting…", "Reconnecting…", "Connected!", "Not connected", "No internet"])
        // The shared indicator: dots, an arc, a dot that pings once, a still ring.
        #expect(statuses.map(\.phase) == [.connecting, .reconnecting, .connected, .disconnected, .disconnected])
        #expect(Set(shown.map(\.spokenStatus)).count == shown.count)
    }
}
