import Foundation
import Testing
@testable import Bighelp

/// An agent tapped on a computer that doesn't answer: the app goes back to the computer the tap
/// came from instead of staying (and relaunching) on the dead one.
struct FleetSwitchFallbackTests {
    let dead = UUID()
    let other = UUID()

    @Test func aComputerThatNeverGetsReadyGivesTheSelectionBack() {
        #expect(FleetSwitchFallback.shouldReturn(ready: false, waitingFor: dead, pending: dead, selected: dead))
        #expect(FleetSwitchFallback.message(unreachable: "Studio Mac", stillOn: "Home Mac")
                == "Couldn't reach Studio Mac. You're still on Home Mac.")
    }

    @Test func aReadyComputerKeepsTheSwitch() {
        #expect(!FleetSwitchFallback.shouldReturn(ready: true, waitingFor: dead, pending: dead, selected: dead))
    }

    /// Another tap, Cancel, or a pick in ☰ since then: that choice stands.
    @Test func aNewerChoiceIsNeverUndone() {
        #expect(!FleetSwitchFallback.shouldReturn(ready: false, waitingFor: dead, pending: other, selected: other))
        #expect(!FleetSwitchFallback.shouldReturn(ready: false, waitingFor: dead, pending: nil, selected: dead))
        #expect(!FleetSwitchFallback.shouldReturn(ready: false, waitingFor: dead, pending: dead, selected: other))
    }

    @Test func theLoaderNamesTheBotBeingOpened() {
        let host = UUID()
        #expect(FleetPendingOpen(hostID: host, open: .agent(profileID: "travel")).profileID == "travel")
        #expect(FleetPendingOpen(hostID: host, open: .chat(profileID: "home", storedSessionID: "s", appSessionID: nil))
            .profileID == "home")
        #expect(FleetPendingOpen(hostID: host, open: .botProfile(profileID: "finance")).profileID == "finance")
        #expect(FleetPendingOpen(hostID: host, open: .group(roomID: "r")).profileID == nil)
    }

    // MARK: A Live Activity or alert tap on another computer

    @MainActor private func tap(switchedHost: BighelpExternalSessionOpen.HostSwitch? = nil) -> BighelpExternalSessionOpen {
        let center = BighelpExternalSessionOpenCenter()
        center.request(hostID: dead, profileID: "home", storedSessionID: "s", switchedHost: switchedHost)
        return center.pending!
    }

    /// The tap switched from `other` to `dead`, which is still connecting: nothing is prepared yet,
    /// so no "This session could not be prepared" alert shows while the right chat is on its way.
    @MainActor @Test func aTapThatSwitchedComputersWaitsForTheNewOne() {
        let open = tap(switchedHost: BighelpExternalSessionOpen.HostSwitch(from: other))
        #expect(open.switchedHost == BighelpExternalSessionOpen.HostSwitch(from: other))
        #expect(ExternalOpenHostWait.step(open, hostIsReady: false, timedOut: false) == .keepWaiting)
        #expect(ExternalOpenHostWait.step(open, hostIsReady: true, timedOut: false) == .openNow)
    }

    @MainActor @Test func aTapWithNoComputerSelectedBeforeAlsoWaits() {
        let open = tap(switchedHost: BighelpExternalSessionOpen.HostSwitch(from: nil))
        #expect(ExternalOpenHostWait.step(open, hostIsReady: false, timedOut: false) == .keepWaiting)
    }

    /// The same computer as before: it opens at once, from its saved chats, as it always did.
    @MainActor @Test func aTapOnTheComputerInUseIsNotHeld() {
        let open = tap()
        #expect(open.switchedHost == nil)
        #expect(ExternalOpenHostWait.step(open, hostIsReady: false, timedOut: false) == .openNow)
        #expect(ExternalOpenHostWait.step(open, hostIsReady: false, timedOut: true) == .openNow)
    }

    /// A computer that never answers ends in the honest error, not a tap that does nothing.
    @MainActor @Test func aComputerThatNeverAnswersGivesUpWithTheUsualMessage() {
        let open = tap(switchedHost: BighelpExternalSessionOpen.HostSwitch(from: other))
        #expect(ExternalOpenHostWait.step(open, hostIsReady: false, timedOut: true) == .giveUp)
        #expect(ExternalOpenHostWait.step(open, hostIsReady: true, timedOut: true) == .openNow)
        #expect(ExternalOpenHostWait.message(unreachable: "Studio Mac", stillOn: "Home Mac")
                == "Couldn't reach Studio Mac. You're still on Home Mac.")
        #expect(ExternalOpenHostWait.message(unreachable: "Studio Mac", stillOn: nil)
                == "Couldn't reach Studio Mac. Check that it's on, then try again.")
    }
}
