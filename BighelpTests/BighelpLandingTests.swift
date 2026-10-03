import Foundation
import Testing
@testable import Bighelp

/// Settings › Chat › Open on and Start with: the screen and agent a cold
/// launch lands on, with today's start kept until someone picks.
@MainActor
struct BighelpLandingTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "landing-\(UUID().uuidString)")!
    }

    // MARK: Which screen each choice opens

    @Test func eachChoiceOpensItsScreen() {
        func open(_ screen: BighelpLandingScreen) -> BighelpLandingDestination? {
            BighelpLanding.destination(for: .chosen(screen), kanbanAvailable: true, kanbanWaitIsOver: false,
                                       projectsAvailable: true)
        }
        #expect(open(.agents) == .agents)
        #expect(open(.allAgents) == .allAgents)
        #expect(open(.lastChat) == .homeChat)
        #expect(open(.feed) == .board(.feed))
        #expect(open(.ideas) == .board(.ideas))
        #expect(open(.goals) == .board(.goals))
        #expect(open(.kanban) == .kanban)
        #expect(open(.projects) == .projects)
    }

    @Test func nothingPickedKeepsTodaysStart() {
        #expect(BighelpLanding.destination(for: .standard(opensChat: true), kanbanAvailable: nil,
                                           kanbanWaitIsOver: false, projectsAvailable: true) == .homeChat)
        // `-loopdy.home.opens-chat NO` (the UI tests' older flows) stays on the chat list.
        #expect(BighelpLanding.destination(for: .standard(opensChat: false), kanbanAvailable: nil,
                                           kanbanWaitIsOver: false, projectsAvailable: true) == .chatList)
    }

    @Test func kanbanFallsBackQuietlyWhereTheComputerHasNone() {
        #expect(BighelpLanding.destination(for: .chosen(.kanban), kanbanAvailable: false, kanbanWaitIsOver: false,
                                           projectsAvailable: true) == .homeChat)
    }

    @Test func kanbanWaitsBrieflyForTheFirstAnswer() {
        #expect(BighelpLanding.destination(for: .chosen(.kanban), kanbanAvailable: nil, kanbanWaitIsOver: false,
                                           projectsAvailable: true) == nil, "Not known yet: wait")
        #expect(BighelpLanding.destination(for: .chosen(.kanban), kanbanAvailable: nil, kanbanWaitIsOver: true,
                                           projectsAvailable: true) == .homeChat, "No answer in time: the default")
    }

    @Test func projectsFallBackWhereTheyCantOpen() {
        #expect(BighelpLanding.destination(for: .chosen(.projects), kanbanAvailable: nil, kanbanWaitIsOver: false,
                                           projectsAvailable: false) == .homeChat)
    }

    // MARK: All hosts at launch

    @Test func onlyAChosenScreenDecidesTheAllHostsView() {
        #expect(BighelpLanding.allHostsMode(for: .chosen(.allAgents)) == true)
        #expect(BighelpLanding.allHostsMode(for: .chosen(.agents)) == false)
        #expect(BighelpLanding.allHostsMode(for: .chosen(.feed)) == false)
        #expect(BighelpLanding.allHostsMode(for: .standard(opensChat: true)) == nil, "Untouched until picked")
        #expect(BighelpLanding.allHostsMode(for: .standard(opensChat: false)) == nil)
    }

    // MARK: Start with

    @Test func aStartAgentThatStillExistsIsUsed() {
        #expect(BighelpLanding.startAgent(stored: "travel", agentIDs: ["finance", "travel"],
                                          choice: .chosen(.feed)) == "travel")
        #expect(BighelpLanding.startAgent(stored: "travel", agentIDs: ["finance", "travel"],
                                          choice: .standard(opensChat: true)) == "travel")
    }

    @Test func aStartAgentThatsGoneFallsBackToAutomatic() {
        #expect(BighelpLanding.startAgent(stored: "deleted", agentIDs: ["finance", "travel"],
                                          choice: .chosen(.lastChat)) == nil)
        #expect(BighelpLanding.startAgent(stored: nil, agentIDs: ["finance"], choice: .chosen(.lastChat)) == nil)
    }

    @Test func allAgentsStartsWithNoOneAgent() {
        #expect(BighelpLanding.startAgent(stored: "travel", agentIDs: ["travel"], choice: .chosen(.allAgents)) == nil)
        #expect(!BighelpLandingScreen.allAgents.offersStartAgent)
        #expect(BighelpLandingScreen.allCases.filter(\.offersStartAgent).count == BighelpLandingScreen.allCases.count - 1)
    }

    // MARK: Saved choices

    @Test func theOldOpensChatValueCarriesOverUntilAScreenIsPicked() {
        let unset = defaults()
        #expect(SettingsStore(defaults: unset).launchLanding == .standard(opensChat: true))

        let chatList = defaults()
        chatList.set(false, forKey: BighelpLanding.legacyOpensChatKey)
        #expect(SettingsStore(defaults: chatList).launchLanding == .standard(opensChat: false))

        let opensChat = defaults()
        opensChat.set(true, forKey: BighelpLanding.legacyOpensChatKey)
        #expect(SettingsStore(defaults: opensChat).launchLanding == .standard(opensChat: true))

        // Picking a screen wins over the old value.
        chatList.set("goals", forKey: BighelpLanding.screenKey)
        #expect(SettingsStore(defaults: chatList).launchLanding == .chosen(.goals))
    }

    @Test func anUnknownSavedScreenKeepsTodaysStart() {
        let saved = defaults()
        saved.set("dashboard", forKey: BighelpLanding.screenKey)
        let settings = SettingsStore(defaults: saved)
        #expect(settings.landingScreen == nil)
        #expect(settings.launchLanding == .standard(opensChat: true))
    }

    @Test func aPickedScreenAppliesNextLaunch() {
        let saved = defaults()
        let settings = SettingsStore(defaults: saved)
        settings.landingScreen = .projects
        #expect(settings.launchLanding == .standard(opensChat: true), "This launch already happened")
        let next = SettingsStore(defaults: saved)
        #expect(next.landingScreen == .projects)
        #expect(next.launchLanding == .chosen(.projects))

        next.landingScreen = nil
        #expect(SettingsStore(defaults: saved).launchLanding == .standard(opensChat: true), "Back to the default")
    }

    @Test func startAgentsAreKeptPerComputer() {
        let saved = defaults()
        let settings = SettingsStore(defaults: saved)
        settings.setStartAgentID("travel", scope: "computer-a")
        settings.setStartAgentID("home", scope: "computer-b")
        let next = SettingsStore(defaults: saved)
        #expect(next.startAgentID(scope: "computer-a") == "travel")
        #expect(next.startAgentID(scope: "computer-b") == "home")
        #expect(next.startAgentID(scope: "computer-c") == nil, "Another computer never gets an ID it doesn't have")
        #expect(next.startAgentID(scope: nil) == nil)

        next.setStartAgentID(nil, scope: "computer-a")
        #expect(SettingsStore(defaults: saved).startAgentID(scope: "computer-a") == nil, "Automatic again")
        #expect(SettingsStore(defaults: saved).startAgentID(scope: "computer-b") == "home")
    }

    @Test func aChosenScreenSetsTheAllHostsViewAtLaunch() {
        let multi = defaults()
        multi.set("all-agents", forKey: BighelpLanding.screenKey)
        let settings = SettingsStore(defaults: multi)
        settings.applyLaunchLandingToAllHostsMode()
        #expect(settings.allHostsMode)

        let one = defaults()
        one.set(true, forKey: "bighelp.hosts.all-hosts")
        one.set("feed", forKey: BighelpLanding.screenKey)
        let single = SettingsStore(defaults: one)
        single.applyLaunchLandingToAllHostsMode()
        #expect(!single.allHostsMode)

        let untouched = defaults()
        untouched.set(true, forKey: "bighelp.hosts.all-hosts")
        let standard = SettingsStore(defaults: untouched)
        standard.applyLaunchLandingToAllHostsMode()
        #expect(standard.allHostsMode, "Nothing picked: the all-hosts switch stays as it was")
    }

    @Test func choicesUseThePlainLabels() {
        #expect(BighelpLandingScreen.allCases.map(\.title)
                == ["Agents", "Agents (multi)", "Last chat", "Feed", "Ideas", "Goals", "Kanban", "Projects"])
    }
}
