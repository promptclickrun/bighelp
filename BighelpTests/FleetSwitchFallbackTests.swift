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
}
