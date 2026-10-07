import Foundation
import Testing
@testable import Bighelp

/// Settings › Appearance › App layout: the bottom bar after Chat, and ☰'s order.
struct AppLayoutTests {
    @Test func theStandardLayoutIsTodaysBarAndMenu() {
        let layout = BighelpAppLayout.standard
        #expect(layout.barTabs == [.sessions, .feed, .ideas, .goals, .apps])
        #expect(layout.menuPlaces == [.agents, .projects, .kanban, .workflows, .scheduledTasks, .usage, .settings])
    }

    @Test func swappingBoardsForPagesPutsTheBoardsInTheMenu() {
        var layout = BighelpAppLayout.standard
        for place in [BighelpPlace.feed, .ideas, .goals] { layout.unpin(place) }
        for place in [BighelpPlace.kanban, .workflows, .scheduledTasks] { layout.pin(place) }
        #expect(layout.barTabs == [.sessions, .apps, .kanban, .workflows, .scheduledTasks])
        #expect(layout.menuPlaces == [.agents, .projects, .usage, .feed, .ideas, .goals, .settings],
                "Feed, Ideas and Goals stay one tap away in the menu")
        #expect(!layout.menuPlaces.contains(.kanban), "A pinned place isn't listed twice")
    }

    @Test func theBarHoldsChatAndFourMoreAndSettingsStaysInTheMenu() {
        var layout = BighelpAppLayout.standard
        #expect(!layout.canPinMore)
        layout.pin(.kanban)
        #expect(!layout.isPinned(.kanban), "Full: remove one first")
        layout.unpin(.files)
        layout.pin(.settings)
        #expect(!layout.isPinned(.settings), "Settings can't leave the menu")
        layout.pin(.kanban)
        #expect(layout.barTabs.last == .kanban)
    }

    @Test func barAndMenuOrdersMove() {
        var layout = BighelpAppLayout.standard
        layout.movePinned(from: [3], to: 0)
        #expect(layout.barTabs == [.sessions, .apps, .feed, .ideas, .goals], "Chat stays first")
        layout.moveMenu(from: [6], to: 0)
        #expect(layout.menuPlaces.first == .settings)
        layout.unpin(.goals)
        #expect(layout.menuPlaces.last == .goals, "Taken out of the bar, it comes back at the end of the menu")
        #expect(layout.menuPlaces.first == .settings)
    }

    @Test func savedLayoutsSurviveAndOddOnesFallBack() {
        var layout = BighelpAppLayout.standard
        layout.unpin(.ideas)
        layout.pin(.workflows)
        layout.moveMenu(from: [1], to: 0)
        let restored = BighelpAppLayout(saved: layout.saved)
        #expect(restored == layout)
        #expect(BighelpAppLayout(saved: nil) == .standard)
        #expect(BighelpAppLayout(saved: "not json") == .standard)
        // A place from a newer build is dropped; a missing one comes back in the menu.
        let odd = BighelpAppLayout(saved: #"{"pinned":["kanban","teleporter","kanban","settings"],"menu":["usage"]}"#)
        #expect(odd.barTabs == [.sessions, .kanban])
        #expect(odd.menuPlaces.first == .usage && Set(odd.menuPlaces + [.kanban]) == Set(BighelpPlace.allCases))
        // A launch argument arrives as a dictionary of names.
        let argument = BighelpAppLayout(savedObject: ["pinned": ["agents", "feed"], "menu": [String]()])
        #expect(argument.barTabs == [.sessions, .agents, .feed])
        #expect(BighelpAppLayout(savedObject: 42) == .standard)
    }

    @MainActor
    @Test func settingsKeepTheLayoutOnThisDevice() throws {
        let suite = "bighelp.tests.app-layout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.appLayout == .standard)
        settings.appLayout.unpin(.feed)
        settings.appLayout.pin(.kanban)
        #expect(SettingsStore(defaults: defaults).appLayout.barTabs == [.sessions, .ideas, .goals, .apps, .kanban])
        settings.appLayout = .standard
        #expect(defaults.string(forKey: "bighelp.app-layout") == nil, "The standard layout saves nothing")
    }
}
