import Foundation
import Testing
@testable import Bighelp

/// Usage › Limits per computer: the one in use, another, or all of them under
/// their own names. Every computer and number here is made up.
struct UsageLimitsComputersTests {
    private static let studio = HostUsage(id: "studio", name: "Studio Mac", limits: .loaded(
        ProviderUsageReport(agentID: "default", fetchedAt: nil, cached: false, providers: [])))
    private static let office = HostUsage(id: "office", name: "Office Linux", failure: "Couldn't reach this computer.")
    private static let hosts = [HostUsage(id: "home", name: "Home Hermes"), studio, office]

    @Test func oneComputerOffersNoChoiceAndNoNames() {
        for saved in ["", "all", "studio"] {
            let limits = UsageLimitsComputers(selectedID: "home", selectedName: "Home Hermes",
                                              hosts: [HostUsage(id: "home", name: "Home Hermes")], saved: saved)
            #expect(!limits.offersChoice)
            #expect(!limits.showsNames)
            #expect(limits.choice == .current)
            #expect(limits.shown.map(\.id) == ["home"])
        }
    }

    @Test func allShowsEveryComputerUnderItsName() {
        let limits = UsageLimitsComputers(selectedID: "home", selectedName: "Home Hermes", hosts: Self.hosts,
                                          saved: "all")
        #expect(limits.offersChoice)
        #expect(limits.showsNames, "Each computer gets its own heading")
        #expect(limits.title == "All computers")
        // The one in use first; one that can't be reached still has its section to say so.
        #expect(limits.shown.map(\.name) == ["Home Hermes", "Studio Mac", "Office Linux"])
        #expect(limits.shown.map(\.isSelected) == [true, false, false])
        #expect(limits.shown[0].usage == nil, "The computer in use reads its limits through ProviderUsageStore")
        #expect(limits.shown[2].usage?.failure == "Couldn't reach this computer.")
        #expect(!limits.computers.contains { limits.isChosen($0) })
    }

    @Test func oneChosenComputerShowsAloneWithoutHeadings() {
        let studio = UsageLimitsComputers(selectedID: "home", selectedName: "Home Hermes", hosts: Self.hosts,
                                          saved: "studio")
        #expect(studio.choice == .computer("studio"))
        #expect(studio.shown.map(\.name) == ["Studio Mac"])
        #expect(!studio.showsNames, "The menu already says which computer")
        #expect(studio.title == "Studio Mac")
        #expect(studio.isChosen(studio.computers[1]))

        let current = UsageLimitsComputers(selectedID: "home", selectedName: "Home Hermes", hosts: Self.hosts,
                                           saved: "")
        #expect(current.choice == .current, "The computer in use by default")
        #expect(current.shown.map(\.name) == ["Home Hermes"])
        #expect(current.title == "Home Hermes")
    }

    @Test func aSavedComputerThatIsGoneOrInUseFallsBackToTheOneInUse() {
        let gone = UsageLimitsComputers(selectedID: "home", selectedName: "Home Hermes", hosts: Self.hosts,
                                        saved: "lab")
        #expect(gone.choice == .current)
        // After switching to Studio Mac, its saved id is simply the computer in use.
        let switched = UsageLimitsComputers(selectedID: "studio", selectedName: "Studio Mac", hosts: [
            HostUsage(id: "studio", name: "Studio Mac"), HostUsage(id: "home", name: "Home Hermes"),
        ], saved: "studio")
        #expect(switched.choice == .current)
        #expect(switched.shown.map(\.name) == ["Studio Mac"])
    }

    @Test func pickingTheComputerInUseFollowsLaterSwitches() {
        let limits = UsageLimitsComputers(selectedID: "home", selectedName: "Home Hermes", hosts: Self.hosts,
                                          saved: "all")
        #expect(UsageLimitsComputers.saved(for: limits.computers[0]) == "current")
        #expect(UsageLimitsComputers.saved(for: limits.computers[1]) == "studio")
        #expect(UsageLimitsComputers.Choice(saved: "current") == .current)
    }
}
