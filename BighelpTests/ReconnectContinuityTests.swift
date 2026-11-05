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

/// Settings › Default model said "Reopen this feature after connecting to the
/// selected host and profile." after Provider Keys and back, or after leaving
/// the app: it judged its page by the whole connection, and kept one page slot.
struct WorkspaceScreenAvailabilityTests {
    private let signIn = UUID()
    private func owner(_ computer: String = "computer-1", signIn: UUID? = nil) throws -> WorkspaceOwner {
        WorkspaceOwner(authority: try .fixture(id: computer), authenticationGeneration: signIn ?? self.signIn,
                       connectionGeneration: UUID())
    }

    @Test func aReconnectKeepsThePage() throws {
        let opened = try owner()
        let reconnected = WorkspaceOwner(authority: opened.authority, authenticationGeneration: signIn,
                                         connectionGeneration: UUID())
        #expect(opened != reconnected, "A reconnect is a new owner")
        let availability = WorkspaceScreenAvailability.of(openedFor: opened, current: reconnected, signIn: opened.signIn)
        #expect(availability == .reconnecting)
        #expect(availability.keepsScreen)
    }

    @Test func whileTheConnectionIsAwayThePageWaits() throws {
        let opened = try owner()
        let availability = WorkspaceScreenAvailability.of(openedFor: opened, current: nil, signIn: opened.signIn)
        #expect(availability == .reconnecting)
        #expect(availability.keepsScreen)
    }

    @Test func theSameConnectionIsCurrent() throws {
        let opened = try owner()
        #expect(WorkspaceScreenAvailability.of(openedFor: opened, current: opened, signIn: opened.signIn) == .current)
    }

    @Test func anotherComputerOrSignInIsNot() throws {
        let opened = try owner()
        let otherComputer = try owner("computer-2")
        let signedInAgain = try owner(signIn: UUID())
        for current in [otherComputer, signedInAgain] {
            let availability = WorkspaceScreenAvailability.of(openedFor: opened, current: current, signIn: current.signIn)
            #expect(availability == .unavailable)
            #expect(!availability.keepsScreen)
        }
        #expect(WorkspaceScreenAvailability.of(openedFor: opened, current: nil, signIn: nil) == .unavailable)
    }

    @Test func providerKeysOnTopKeepsDefaultModelBeneath() {
        var screens = WorkspaceOpenScreens<String>()
        #expect(screens.open("models page", for: .models) == nil)
        #expect(screens.open("keys page", for: .keys) == nil, "Opening Provider Keys replaces nothing")
        #expect(screens[.models] == "models page", "Default model is still there to go back to")
        #expect(screens.keep(only: [.models]) == ["keys page"], "Going back retires Provider Keys only")
        #expect(screens[.models] == "models page")
        #expect(screens.open("new models page", for: .models) == "models page", "A reconnect replaces it in place")
        #expect(screens.removeAll() == ["new models page"])
        #expect(screens.destinations.isEmpty)
    }
}

/// The pill under the Dynamic Island: the app connects and reconnects behind
/// what's on screen, so it shows only a connection that failed, and its return.
struct ConnectionIslandRulesTests {
    private func next(from phase: ConnectionIslandPhase, _ state: WorkspaceConnectionState,
                      hasNetwork: Bool = true, isActive: Bool = true,
                      isRecovering: Bool = false) -> (phase: ConnectionIslandPhase, after: Duration?) {
        ConnectionIslandRules.next(from: phase, state: state, hasNetwork: hasNetwork,
                                   isActive: isActive, isRecovering: isRecovering)
    }

    @Test func connectingAndReconnectingShowNothing() {
        let quiet = next(from: .hidden, .reconnecting)
        #expect(quiet.phase == .hidden)
        #expect(quiet.after == nil)
        #expect(next(from: .hidden, .connected).phase == .hidden, "Connected without a failure says nothing")
    }

    @Test func aFailureShowsAfterAMoment() {
        let failed = next(from: .hidden, .disconnected)
        #expect(failed.phase == .disconnected)
        #expect(failed.after == ConnectionIslandRules.showDelay)
        #expect(next(from: .hidden, .disconnected, hasNetwork: false).phase == .noInternet)
        let worse = next(from: .disconnected, .disconnected, hasNetwork: false)
        #expect(worse.phase == .noInternet)
        #expect(worse.after == nil)
    }

    /// The pill is the only place a chat says the connection is down, so it stays
    /// until it's back, through each new try; only "Connected!" goes away by itself.
    @Test func aFailureStaysShownUntilTheConnectionIsBack() {
        #expect(next(from: .disconnected, .reconnecting).phase == .disconnected)
        #expect(next(from: .noInternet, .reconnecting).phase == .noInternet)
        for phase: ConnectionIslandPhase in [.disconnected, .noInternet] {
            #expect(ConnectionIslandRules.hideDelay(after: phase) == nil, "\(phase)")
        }
        #expect(ConnectionIslandRules.hideDelay(after: .connected) == ConnectionIslandRules.connectedHold)
    }

    @Test func comingBackAfterAFailureSaysConnected() {
        #expect(next(from: .disconnected, .connected).phase == .connected)
        #expect(next(from: .noInternet, .connected).phase == .connected)
        // Tucked away during a long outage, it still says so when it's back.
        #expect(next(from: .hidden, .connected, isRecovering: true).phase == .connected)
    }

    @Test func nothingShowsInTheBackground() {
        let away = next(from: .disconnected, .disconnected, isActive: false)
        #expect(away.phase == .hidden)
        #expect(away.after == nil)
    }

    @Test func eachStatusHasItsOwnMarkAndWords() {
        let shown: [ConnectionIslandPhase] = [.connected, .disconnected, .noInternet]
        let statuses = shown.compactMap { HostConnectionStatus(island: $0) }
        #expect(statuses.map(\.label) == ["Connected!", "Not connected", "No internet"])
        // The shared indicator: a dot that pings once, a still ring.
        #expect(statuses.map(\.phase) == [.connected, .disconnected, .disconnected])
        #expect(Set(shown.map(\.spokenStatus)).count == shown.count)
    }
}
