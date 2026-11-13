import Foundation
import Testing
@testable import Bighelp

/// One home: where an install that ran the modes lands, and its edge swipes without the mode actions.
@MainActor
struct HomeSettingsMigrationTests {
    private typealias Migration = HomeSettingsMigration

    private func existing(_ change: (inout Migration.Stored) -> Void = { _ in }) -> Migration.Stored {
        var stored = Migration.Stored(isExistingInstall: true)
        change(&stored)
        return stored
    }

    /// Opens on, the first tab's view, and Show every computer.
    private struct Lands: Equatable {
        let landing: HomeLanding
        let view: HomeConversationsView
        let everyComputer: Bool

        init(_ landing: HomeLanding, _ view: HomeConversationsView, _ everyComputer: Bool) {
            self.landing = landing
            self.view = view
            self.everyComputer = everyComputer
        }
    }

    private func lands(_ stored: Migration.Stored) -> Lands {
        let outcome = Migration.outcome(stored)
        return Lands(outcome.landing, outcome.view, outcome.showsEveryComputer)
    }

    private func defaults() -> (UserDefaults, () -> Void) {
        let suite = "home-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    // MARK: Where a person lands, first match wins

    @Test func botsModeOpensOnBotsAndShowsEveryComputerOnlyWithMultiGateway() {
        #expect(lands(existing { $0.botsMode = true; $0.allHosts = true }) == Lands(.bots, .bots, false))
        #expect(lands(existing { $0.botsMode = true; $0.multiGateway = true }) == Lands(.bots, .bots, true))
        #expect(lands(existing { $0.botsMode = true; $0.codeMode = true; $0.codeOpensAtLaunch = true }).landing == .bots,
                "Bots mode wins over Code")
    }

    @Test func codeAsTheLaunchHomeOpensOnWork() {
        #expect(lands(existing { $0.codeMode = true; $0.codeOpensAtLaunch = true; $0.allHosts = true })
                == Lands(.work, .chats, true))
        #expect(lands(existing { $0.codeMode = true; $0.codeOpensAtLaunch = true; $0.landing = "agents" }).landing == .work,
                "Code mode ignored Opens on")
        #expect(lands(existing { $0.codeMode = true }).landing == .chats, "Code on beside Chat opened on Chat")
    }

    @Test func agentsOpensOnBotsAsItWas() {
        #expect(lands(existing { $0.landing = "agents" }) == Lands(.bots, .bots, false))
        #expect(lands(existing { $0.landing = "agents"; $0.allHosts = true }) == Lands(.bots, .bots, true))
    }

    @Test func everyComputersAgentsOpensOnBotsWithEveryComputer() {
        #expect(lands(existing { $0.landing = "all-agents"; $0.allHosts = false }) == Lands(.bots, .bots, true))
    }

    @Test func sessionsAndLastChatOpenOnChats() {
        #expect(lands(existing { $0.landing = "sessions" }) == Lands(.chats, .chats, false))
        #expect(lands(existing { $0.landing = "last-chat"; $0.allHosts = true }) == Lands(.chats, .chats, true))
    }

    @Test func feedIdeasAndGoalsOpenOnToday() {
        for screen in ["feed", "ideas", "goals"] {
            #expect(lands(existing { $0.landing = screen }) == Lands(.today, .chats, false), "\(screen)")
        }
    }

    @Test func kanbanAndProjectsOpenOnWork() {
        for screen in ["kanban", "projects"] {
            #expect(lands(existing { $0.landing = screen; $0.allHosts = true }) == Lands(.work, .chats, true), "\(screen)")
        }
    }

    @Test func theAllHostsViewWithNothingPickedOpensOnBots() {
        #expect(lands(existing { $0.allHosts = true }) == Lands(.bots, .bots, true))
    }

    @Test func nothingPickedOpensOnChatsWithOneComputer() {
        #expect(lands(existing()) == Lands(.chats, .chats, false))
        #expect(lands(existing { $0.landing = "dashboard" }) == Lands(.chats, .chats, false), "An unknown screen")
    }

    @Test func aNewInstallIsAskedAndShowsEveryComputer() {
        #expect(lands(Migration.Stored()) == Lands(.chats, .chats, true))
    }

    // MARK: Edge swipes

    @Test func modeSwipesBecomePlaces() {
        #expect(Migration.remapped("botsMode", edgeDefault: .sessions) == .agents)
        for mode in ["nextMode", "chatMode", "codeMode"] {
            #expect(Migration.remapped(mode, edgeDefault: .sessions) == .sessions, "\(mode) on the left")
            #expect(Migration.remapped(mode, edgeDefault: .newChat) == .newChat, "\(mode) on the right")
        }
        #expect(Migration.remapped("inbox", edgeDefault: .sessions) == .home)
        #expect(Migration.remapped("quickWorkspace", edgeDefault: .sessions) == .quickWorkspace)
        #expect(Migration.remapped("none", edgeDefault: .newChat) == WorkspaceSwipeAction.none)
        #expect(Migration.remapped(nil, edgeDefault: .newChat) == .newChat)
        #expect(Migration.remapped("teleport", edgeDefault: .sessions) == .sessions)
    }

    @Test func botsModeKeepsTheSwipesItHad() {
        let outcome = Migration.outcome(existing { $0.botsMode = true; $0.leftEdge = "nextMode"; $0.rightEdge = "none" })
        #expect(outcome.leftEdge == .agents)
        #expect(outcome.rightEdge == .profile)
    }

    // MARK: Writing it down

    @Test func runsOnceAndWritesOnlyTheNewTruth() {
        let (defaults, cleanUp) = defaults()
        defer { cleanUp() }
        defaults.set(true, forKey: "bighelp.settings.simple-bots")
        defaults.set(true, forKey: "bighelp.simple-bots.multi-gateway")
        defaults.set("chatMode", forKey: "loopdy.workspace.leftEdgeSwipeAction")
        defaults.set("feed", forKey: BighelpLanding.screenKey)

        Migration.runIfNeeded(defaults: defaults)

        #expect(defaults.string(forKey: BighelpLanding.screenKey) == "bots")
        #expect(defaults.string(forKey: "bighelp.home.view") == "bots")
        #expect(defaults.object(forKey: "bighelp.hosts.all-hosts") as? Bool == true)
        #expect(defaults.string(forKey: "loopdy.workspace.leftEdgeSwipeAction") == "agents")
        #expect(defaults.string(forKey: "loopdy.workspace.rightEdgeSwipeAction") == "profile")
        #expect(defaults.bool(forKey: "bighelp.settings.simple-bots"), "Old keys stay")
        #expect(defaults.bool(forKey: Migration.markerKey))

        defaults.set(false, forKey: "bighelp.settings.simple-bots")
        defaults.set("sessions", forKey: BighelpLanding.screenKey)
        Migration.runIfNeeded(defaults: defaults)
        #expect(defaults.string(forKey: "bighelp.home.view") == "bots", "The marker stops a second run")
        #expect(defaults.string(forKey: BighelpLanding.screenKey) == "sessions")
    }

    @Test func anOldScreenThatMapsByItselfStaysAsSaved() {
        let (defaults, cleanUp) = defaults()
        defer { cleanUp() }
        defaults.set("goals", forKey: BighelpLanding.screenKey)

        Migration.runIfNeeded(defaults: defaults)

        #expect(defaults.string(forKey: BighelpLanding.screenKey) == "goals", "The old shell still reads it")
        #expect(defaults.string(forKey: "bighelp.home.view") == "chats")
        #expect(defaults.object(forKey: "bighelp.hosts.all-hosts") as? Bool == false, "One computer, as it was")
        #expect(defaults.object(forKey: "loopdy.workspace.leftEdgeSwipeAction") == nil, "Unchanged swipes stay unset")
    }

    @Test func aNewInstallGetsOnlyTheMarker() {
        let (defaults, cleanUp) = defaults()
        defer { cleanUp() }

        Migration.runIfNeeded(defaults: defaults)

        #expect(defaults.bool(forKey: Migration.markerKey))
        #expect(defaults.object(forKey: BighelpLanding.screenKey) == nil, "First run asks")
        #expect(defaults.object(forKey: "bighelp.home.view") == nil)
        #expect(defaults.object(forKey: "bighelp.hosts.all-hosts") == nil)
    }

    // MARK: What the store reads after

    @Test func theStoreReadsTheMigratedHome() {
        let (defaults, cleanUp) = defaults()
        defer { cleanUp() }
        defaults.set(true, forKey: "bighelp.settings.simple-bots")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.homeLanding == .bots)
        #expect(settings.launchHomeLanding == .bots)
        #expect(settings.homeView == .bots)
        #expect(!settings.showsEveryComputer)
    }

    @Test func aNewInstallOpensOnChatsWithEveryComputerUntilFirstRunAsks() {
        let (defaults, cleanUp) = defaults()
        defer { cleanUp() }

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.homeLanding == .chats)
        #expect(settings.homeView == .chats)
        #expect(settings.showsEveryComputer)
    }

    @Test func opensOnSetsTheViewForBotsAndChatsAndKeepsItForTodayAndWork() {
        let (defaults, cleanUp) = defaults()
        defer { cleanUp() }
        let settings = SettingsStore(defaults: defaults)

        settings.homeLanding = .bots
        #expect(settings.homeView == .bots)
        settings.homeLanding = .today
        #expect(settings.homeView == .bots, "The last view picked")
        settings.homeView = .chats
        settings.homeLanding = .work
        #expect(settings.homeView == .chats)

        let next = SettingsStore(defaults: defaults)
        #expect(next.launchHomeLanding == .work)
        #expect(next.homeView == .chats)
        #expect(settings.launchHomeLanding == .chats, "This launch already happened")
    }
}
