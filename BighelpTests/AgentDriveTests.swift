import Foundation
import Testing
import UIKit
@testable import Bighelp

/// An agent showing the person a place in bighelp (#662): the catalog it searches, the
/// `iphone_navigation` tool's checks, and the navigator that plays a playbook and goes back.
@MainActor
struct AgentDriveTests {
    // MARK: Catalog

    @Test func everyPlaceHasOneIDAndAPlaybookThatEndsWhereItSays() {
        let ids = DriveCatalog.places.map(\.id)
        #expect(Set(ids).count == ids.count)
        for place in DriveCatalog.places {
            #expect(!place.playbooks.isEmpty, "\(place.id) is reachable in no mode")
            for (mode, steps) in place.playbooks {
                #expect(steps.first?.move != nil, "\(place.id) in \(mode) starts without a move")
                #expect(steps.dropLast().allSatisfy { !$0.points }, "\(place.id) points before its last step")
                if steps.last?.points == true { #expect(steps.last?.target != nil) }
            }
        }
    }

    @Test func thePersonsOwnWordsFindTheirPlace() {
        let feed = DriveCatalog.search("How do I see what my Feed can do?", mode: .bots, nerdMode: false, limit: 3)
        #expect(feed.first?.id == "bot.dashboard.templates.feed")
        let returnKey = DriveCatalog.search("enter key sends", mode: .chat, nerdMode: false, limit: 3)
        #expect(returnKey.first?.id == "settings.chat.return-sends")
        #expect(DriveCatalog.search("kanban", mode: .bots, nerdMode: false, limit: 5).isEmpty, "Bots mode has no Kanban")
    }

    @Test func nerdModePlacesStayHiddenUntilItIsOn() {
        #expect(!DriveCatalog.search("hermes tools", mode: .chat, nerdMode: false, limit: 5).contains { $0.id == "hermes.tools" })
        #expect(DriveCatalog.search("hermes tools", mode: .chat, nerdMode: true, limit: 5).contains { $0.id == "hermes.tools" })
    }

    @Test func feedTemplatesWalkTheProfileThenPointAtTheDeck() throws {
        let steps = try #require(DriveCatalog.place("bot.dashboard.templates.feed")?.playbooks[.bots])
        #expect(steps.map { $0.label(bot: "Nova") } == ["Nova's profile", "Dashboard", "Templates", "Feed"])
        #expect(steps[0].move == .botProfile(BotProfileOpening(tab: .dashboard)))
        #expect(steps[2].move == .botProfile(BotProfileOpening(sheet: .templates(.feed))))
        #expect(steps[3].points && steps[3].target == "dashboard.templates.deck")
    }

    // MARK: Tool

    @Test func navigationIsOnByDefaultAndNeedsTheNewerPlugin() {
        #expect(DeviceToolCapability.navigation.pluginFeature == "native-device-navigation-v1")
        #expect(!DeviceToolCapability.navigation.sharesPersonalData)
        #expect(DeviceToolCatalog.operations["navigation.open"]?.journaled == false)
        var saved: [Bool] = []
        let permissions = DeviceToolPermissions(status: { _ in .notRequested }, request: { _ in .notRequested },
                                                isForeground: { true }, readGrants: { _ in nil }, writeGrants: { _, _ in },
                                                saveNavigationAllowed: { saved.append($0) })
        #expect(permissions.isEnabled(.navigation) && permissions.status(for: .navigation) == .available)
        permissions.disable(.navigation)
        #expect(!permissions.isEnabled(.navigation) && saved == [false])
        #expect(permissions.isEnabled(.appearance), "Each light tool has its own switch")
    }

    @Test func placesListsMatchesForThisMode() throws {
        let fixture = ToolFixture(mode: .bots)
        let payload = try fixture.tool.execute(operation: "navigation.places", arguments: ["query": .string("feed templates")],
                                       context: ToolFixture.context, authorize: {})
        guard case .array(let places)? = payload["places"], case .object(let first)? = places.first else {
            Issue.record("No places"); return
        }
        #expect(first["id"] == .string("bot.dashboard.templates.feed"))
        #expect(first["needs"] == .string("bot"))
    }

    @Test func openRefusesWhatItCannotShowBeforeMovingAnything() {
        let fixture = ToolFixture(mode: .chat)
        func failure(_ arguments: [String: BighelpJSONValue]) -> String? {
            do { _ = try fixture.tool.execute(operation: "navigation.open", arguments: arguments,
                                              context: ToolFixture.context, authorize: {}); return nil }
            catch let error as any DeviceToolFailure { return error.code } catch { return "other" }
        }
        #expect(failure([:]) == "invalid_arguments")
        #expect(failure(["place": .string("Kanban")]) == "invalid_arguments", "Ids are lowercase")
        #expect(failure(["place": .string("kanban"), "tap": .string("x")]) == "invalid_arguments")
        #expect(failure(["place": .string("kanban"), "note": .string(String(repeating: "a", count: 161))]) == "invalid_arguments")
        #expect(failure(["place": .string("nowhere")]) == "unknown_place")
        #expect(failure(["place": .string("bot.dashboard")]) == "not_in_this_mode")
        #expect(failure(["place": .string("hermes.tools")]) == "needs_nerd_mode")
        #expect(fixture.opened.isEmpty)
    }

    @Test func openStartsTheDriveForTheAgentInTheChatWhenNoBotIsNamed() throws {
        let fixture = ToolFixture(mode: .bots)
        let payload = try fixture.tool.execute(operation: "navigation.open",
                                               arguments: ["place": .string("bot.info"), "note": .string("Here it is")],
                                               context: ToolFixture.context, authorize: {})
        #expect(payload["opened"] == .string("bot.info"))
        #expect(payload["mode"] == .string("bots"))
        #expect(fixture.opened.map(\.bot) == ["nova"])
        #expect(fixture.opened.map(\.note) == ["Here it is"])
        #expect(throws: (any Error).self) {
            try fixture.tool.execute(operation: "navigation.open",
                                     arguments: ["place": .string("bot.info"), "bot": .string("someone-else")],
                                     context: ToolFixture.context, authorize: {})
        }
    }

    @Test func aClosedChatStopsTheDriveBeforeItStarts() {
        let fixture = ToolFixture(mode: .chat)
        #expect(throws: (any Error).self) {
            try fixture.tool.execute(operation: "navigation.open", arguments: ["place": .string("kanban")],
                                     context: ToolFixture.context, authorize: { throw CancellationError() })
        }
        #expect(fixture.opened.isEmpty)
    }

    // MARK: Navigator

    @Test func aDriveMovesInOrderTakesLaterProfileStepsLiveAndGoesBack() async throws {
        let router = FakeRouter(path: [.chat(conversationID: "c1")])
        let navigator = DriveNavigator()
        navigator.attach(router, agent: { _ in nil }, chat: { nil })
        let steps = try #require(DriveCatalog.place("bot.dashboard.templates.feed")?.playbooks[.bots])
        let trail = navigator.start(title: "Feed templates", steps: steps, bot: (id: "nova", name: "Nova"),
                                    agent: DriveAgent(id: "nova", name: "Nova", imageURL: nil), note: "Swipe right",
                                    chat: nil, reduceMotion: true)
        #expect(trail == ["Nova's profile", "Dashboard", "Templates", "Feed"])
        try await waitUntil { navigator.phase == .arrived }
        #expect(router.moves == [.botProfile(BotProfileOpening(tab: .dashboard))], "The profile is pushed once")
        #expect(navigator.profileRequest?.opening == BotProfileOpening(sheet: .templates(.feed)))
        #expect(navigator.lit == 4)
        #expect(navigator.spotlight == "dashboard.templates.deck")
        navigator.returnToChat()
        #expect(router.restored == DriveSnapshot(tab: .sessions, path: [.chat(conversationID: "c1")]))
        try await waitUntil { navigator.phase == .idle }
    }

    @Test func aStepLightsOnlyWhenTheScreenShowsIt() async throws {
        let router = FakeRouter(path: [])
        router.shows = []
        let navigator = DriveNavigator()
        navigator.attach(router, agent: { _ in nil }, chat: { nil })
        let steps = try #require(DriveCatalog.place("settings.chat.return-sends")?.playbooks[.chat])
        navigator.start(title: "Return sends", steps: steps, bot: nil, agent: DriveAgent(id: "a", name: "A", imageURL: nil),
                        note: nil, chat: nil, reduceMotion: true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(navigator.lit == 0, "Settings hasn't shown its menu")
        router.shows = ["settings.menu.chat", "settings.chat.return-sends"]
        try await waitUntil { navigator.phase == .arrived }
        #expect(navigator.lit == steps.count)
        navigator.stay()
        #expect(navigator.phase == .idle && router.restored == nil, "Stay leaves the person where they are")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }
}

@MainActor
private final class FakeRouter: DriveRouting {
    var path: [AppRoute]
    var moves: [DriveMove] = []
    var restored: DriveSnapshot?
    /// The controls on screen; nil means every one.
    var shows: Set<String>?

    init(path: [AppRoute]) { self.path = path }

    func snapshot() -> DriveSnapshot { DriveSnapshot(tab: .sessions, path: path) }
    func restore(_ snapshot: DriveSnapshot) { restored = snapshot; path = snapshot.path }
    func perform(_ move: DriveMove, bot: String?) {
        moves.append(move)
        if case .botProfile(let opening) = move, let bot { path.append(.simpleBotProfile(agentID: bot, opening: opening)) }
    }
    func frame(_ target: String) -> CGRect? {
        shows.map { $0.contains(target) } ?? true ? CGRect(x: 10, y: 10, width: 40, height: 40) : nil
    }
}

@MainActor
private final class ToolFixture {
    static let context = DeviceToolCallContext(requestID: "r", hostID: "h", agentID: "nova", sessionID: "s", turnID: "t")
    var opened: [(place: String, bot: String?, note: String?)] = []
    private(set) var tool: DeviceNavigationTool!

    init(mode: BighelpMode, nerdMode: Bool = false) {
        tool = DeviceNavigationTool(.init(
            mode: { mode }, nerdMode: { nerdMode },
            botName: { $0 == "nova" ? "Nova" : nil },
            open: { [weak self] place, steps, bot, note, _ in
                self?.opened.append((place.id, bot?.id, note))
                return steps.map { $0.label(bot: bot?.name) }
            }))
    }
}
