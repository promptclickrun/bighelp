import Foundation
import Testing
@testable import Bighelp

@MainActor
struct BoardDashboardTests {
    private static func defaults() -> UserDefaults {
        let name = "BoardDashboardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: Swipe decision

    @Test func aDragPastTheLineActsAndShortOfItSpringsBack() {
        #expect(DashboardSwipe.decide(translation: 96, velocity: 0) == .right)
        #expect(DashboardSwipe.decide(translation: -120, velocity: 0) == .left)
        #expect(DashboardSwipe.decide(translation: 95, velocity: 0) == nil)
        #expect(DashboardSwipe.decide(translation: -60, velocity: -100) == nil)
    }

    @Test func aQuickFlickActsSoonerButOnlyTheWayItMoved() {
        #expect(DashboardSwipe.decide(translation: 30, velocity: 900) == .right)
        #expect(DashboardSwipe.decide(translation: -30, velocity: -900) == .left)
        // Thrown back the other way, or barely moved: springs back.
        #expect(DashboardSwipe.decide(translation: 40, velocity: -900) == nil)
        #expect(DashboardSwipe.decide(translation: 10, velocity: 1_500) == nil)
    }

    @Test func eachKindHasItsOwnPairOfSwipes() {
        #expect(DashboardCardAction.action(for: .feed, .right) == .ask)
        #expect(DashboardCardAction.action(for: .feed, .left) == .clear)
        #expect(DashboardCardAction.action(for: .idea, .right) == .doIt)
        #expect(DashboardCardAction.action(for: .idea, .left) == .notNow)
        #expect(DashboardCardAction.action(for: .goal, .right) == .markDone)
        #expect(DashboardCardAction.action(for: .goal, .left) == .notToday)
        #expect(DashboardCardAction.ask.title(botName: "Juniper") == "Ask Juniper")
        // Putting away uses the boards' own words.
        #expect(DashboardCardAction.clear.title(botName: "Juniper") == BoardDismissAction(kind: .feed).title)
        #expect(DashboardCardAction.notNow.title(botName: "Juniper") == BoardDismissAction(kind: .idea).title)
        #expect(DashboardCardAction.action(for: .goal, .left) != .clear, "Remove stays in the menu")
    }

    // MARK: Piles

    @Test func pilesLeaveOutWhatsPutAwayAndDoneGoals() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let items = [
            AgentBoardItem(id: "f-old", kind: .feed, title: "Old", createdAt: now.addingTimeInterval(-600)),
            AgentBoardItem(id: "f-new", kind: .feed, title: "New", createdAt: now),
            AgentBoardItem(id: "f-gone", kind: .feed, title: "Cleared", dismissed: true, createdAt: now),
            AgentBoardItem(id: "g-done", kind: .goal, title: "Done", status: "done", createdAt: now),
            AgentBoardItem(id: "g-a", kind: .goal, title: "A", status: "active", createdAt: now.addingTimeInterval(-60)),
            AgentBoardItem(id: "g-b", kind: .goal, title: "B", status: "active", createdAt: now),
        ]
        #expect(DashboardPiles.cards(.feed, items: items, hidden: []).map(\.id) == ["f-new", "f-old"])
        #expect(DashboardPiles.cards(.feed, items: items, hidden: ["f-new"]).map(\.id) == ["f-old"])
        #expect(DashboardPiles.cards(.goal, items: items, hidden: []).map(\.id) == ["g-b", "g-a"])
        #expect(DashboardPiles.neverHad(.idea, items: items))
        #expect(!DashboardPiles.neverHad(.feed, items: items), "Cleared posts mean it's caught up, not empty")
    }

    // MARK: Not today

    @Test func notTodayLastsUntilTomorrowForThatBotOnThatComputer() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let snoozes = DashboardSnoozes(defaults: Self.defaults(), calendar: calendar)
        let evening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 22))!
        snoozes.snooze(goalID: "g1", scope: "host-a", agentID: "juniper", now: evening)

        #expect(snoozes.snoozedGoalIDs(scope: "host-a", agentID: "juniper", now: evening) == ["g1"])
        #expect(snoozes.snoozedGoalIDs(scope: "host-b", agentID: "juniper", now: evening).isEmpty)
        #expect(snoozes.snoozedGoalIDs(scope: "host-a", agentID: "ollie", now: evening).isEmpty)
        let lastMinute = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 23, minute: 59))!
        #expect(snoozes.snoozedGoalIDs(scope: "host-a", agentID: "juniper", now: lastMinute) == ["g1"])
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28))!
        #expect(snoozes.snoozedGoalIDs(scope: "host-a", agentID: "juniper", now: midnight).isEmpty)
    }

    @Test func undoingNotTodayBringsTheGoalBack() {
        let snoozes = DashboardSnoozes(defaults: Self.defaults())
        snoozes.snooze(goalID: "g1", scope: "s", agentID: "a")
        snoozes.unsnooze(goalID: "g1", scope: "s", agentID: "a")
        #expect(snoozes.snoozedGoalIDs(scope: "s", agentID: "a").isEmpty)
    }

    // MARK: Tutorial

    @Test func theTutorialShowsOnceAndOnlyWithACard() {
        let tutorial = DashboardTutorial(defaults: Self.defaults())
        #expect(!tutorial.shouldShow(cardCount: 0), "Not on a brand-new bot")
        #expect(tutorial.shouldShow(cardCount: 3))
        tutorial.markSeen()
        #expect(!tutorial.shouldShow(cardCount: 3))
    }

    @Test func theTutorialWaitsForTheRightSwipe() {
        #expect(DashboardTutorialStep.swipeLeft.after(.right) == .swipeLeft)
        #expect(DashboardTutorialStep.swipeLeft.after(.left) == .swipeRight)
        #expect(DashboardTutorialStep.swipeRight.after(.left) == .swipeRight)
        #expect(DashboardTutorialStep.swipeRight.after(.right) == .done)
    }

    @Test func theModelStartsTheTutorialOnlyOnce() {
        let model = BoardDashboardModel(agentID: "a", snoozes: DashboardSnoozes(defaults: Self.defaults()),
                                        tutorial: DashboardTutorial(defaults: Self.defaults()))
        model.startTutorialIfNeeded(cardCount: 0)
        #expect(model.tutorialStep == nil)
        model.startTutorialIfNeeded(cardCount: 2)
        #expect(model.tutorialStep == .swipeLeft)
        model.finishTutorial()
        model.startTutorialIfNeeded(cardCount: 2)
        #expect(model.tutorialStep == nil)
    }

    // MARK: Templates deck

    @Test func theTemplatesDeckGoesInOrderAndRunsOut() {
        let blueprints = ["a", "b", "c"].map { BoardBlueprint(id: $0, text: "Do \($0)", goalCategory: nil) }
        var deck = DashboardTemplateDeck(blueprints: blueprints)
        #expect(deck.current?.id == "a")
        #expect(deck.upcoming(3).map(\.id) == ["a", "b", "c"])
        deck.advance()
        #expect(deck.current?.id == "b")
        #expect(deck.upcoming(3).map(\.id) == ["b", "c"])
        deck.back()
        #expect(deck.current?.id == "a", "Undo brings the skipped one back")
        deck.advance(); deck.advance(); deck.advance()
        #expect(deck.isFinished)
        #expect(deck.current == nil)
        deck.advance()
        #expect(deck.remaining == 0)
    }

    @Test func theDeckFollowsThePagesTopicOrder() throws {
        let catalog = try BoardBlueprintCatalog.bundled()
        let deck = DashboardTemplateDeck(kind: .idea, catalog: catalog)
        #expect(deck.blueprints == catalog.groups(for: .idea).flatMap(\.blueprints))
        #expect(!deck.blueprints.isEmpty)
    }

    @Test func useSkipsTheFillInPageWhenThereIsNothingToFill() {
        #expect(BoardBlueprint(id: "x", text: "Post a morning brief to my Feed.", goalCategory: nil).needsFilling == false)
        #expect(BoardBlueprint(id: "y", text: "Track [habit] for [30] days.", goalCategory: nil).needsFilling)
    }

    // MARK: Following the shell's connection

    @Test func theDashboardReadsItsBotWithoutMovingTheShellsBoard() async {
        let client = DemoAgentBoardClient()
        let shell = AgentBoardStore()
        await shell.connect(client: client, scope: "fixtures")
        await shell.load(agentID: "finance")
        let model = BoardDashboardModel(agentID: "home", snoozes: DashboardSnoozes(defaults: Self.defaults()),
                                        tutorial: DashboardTutorial(defaults: Self.defaults()))
        await model.follow(shell)
        #expect(shell.agentID == "finance", "Widgets keep the home agent's board")
        #expect(model.store.agentID == "home")
        #expect(model.store.state == .loaded)
        #expect(model.cards(.feed).isEmpty, "The demo's brand-new bot starts empty")
    }
}

