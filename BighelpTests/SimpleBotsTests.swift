import Foundation
import SwiftUI
import Testing
@testable import Bighelp

@MainActor
struct SimpleBotsTests {
    @Test func simpleBotModeIsOffByDefaultAndChangesTheLook() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = SettingsStore(defaults: defaults)
        #expect(!fresh.simpleBotsEnabled)
        #expect(!fresh.appearanceContext.simpleBots)

        fresh.simpleBotsEnabled = true
        let relaunched = SettingsStore(defaults: defaults)
        #expect(relaunched.simpleBotsEnabled)
        let context = relaunched.appearanceContext
        #expect(context.simpleBots)
        #expect(context.lightBackground == .paper)
        #expect(context.darkBackground == .black)
    }

    @Test func edgeSwipesGoToYourBotsAndThisBotsProfile() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.leftEdgeSwipeAction = .newChat
        settings.rightEdgeSwipeAction = .none
        #expect(settings.effectiveLeftEdgeSwipeAction == .newChat, "Your choices everywhere else")
        settings.simpleBotsEnabled = true
        #expect(settings.effectiveLeftEdgeSwipeAction == .agents)
        #expect(settings.effectiveRightEdgeSwipeAction == .profile)
    }

    @Test func simpleLookHasBlackBubblesByDayAndInkAfterDark() {
        var context = BighelpAppearanceContext(appearance: .light, lightBackground: .paper, darkBackground: .black)
        context.simpleBots = true
        let day = BighelpTheme.resolve(appearance: context, colorScheme: .light, contrast: .standard)
        #expect(day.chosenBubbleHex == "111111")
        let night = BighelpTheme.resolve(appearance: BighelpAppearanceContext(appearance: .dark), colorScheme: .dark,
                                         contrast: .standard)
        #expect(night.chosenBubbleHex == nil, "Off, the person's own bubble color stays")
        var dark = context
        dark = BighelpAppearanceContext(appearance: .dark, lightBackground: .paper, darkBackground: .black)
        dark.simpleBots = true
        #expect(BighelpTheme.resolve(appearance: dark, colorScheme: .dark, contrast: .standard).chosenBubbleHex
                == "3A3A3F")
    }

    /// Buttons, links and tinted Settings text use the page's ink in Simple Bot mode. The accent used
    /// to follow the bubble color, which is a dark gray after dark, so tinted text in Settings read as
    /// grayed out ("Hermes restart", Check Host Status).
    @Test func simpleLookTintsWithThePagesInk() {
        for (scheme, ink) in [(ColorScheme.light, "111111"), (.dark, "FFFFFF")] {
            var context = BighelpAppearanceContext(appearance: scheme == .dark ? .dark : .light,
                                                   lightBackground: .paper, darkBackground: .black)
            context.simpleBots = true
            let theme = BighelpTheme.resolve(appearance: context, colorScheme: scheme, contrast: .standard)
            #expect(theme.actionHex.uppercased() == ink, "\(scheme): \(theme.actionHex)")
            #expect(theme.chosenBubbleHex == (scheme == .dark ? "3A3A3F" : "111111"), "Bubbles keep their color")
        }
    }

    /// A bubble color picked in Appearance wins in Simple Bot mode too; black and ink are only its default.
    @Test func simpleLookKeepsThePickedBubbleColor() {
        for scheme in [ColorScheme.light, .dark] {
            var context = BighelpAppearanceContext(appearance: scheme == .dark ? .dark : .light,
                                                   lightBackground: .paper, darkBackground: .black, bubbleColor: .teal)
            context.simpleBots = true
            let theme = BighelpTheme.resolve(appearance: context, colorScheme: scheme, contrast: .standard)
            #expect(theme.chosenBubbleHex == BighelpBubbleColor.teal.hex, "\(scheme)")
            context.bubbleColor = nil
            context.customBubbleHex = "#FF2D55"
            #expect(BighelpTheme.resolve(appearance: context, colorScheme: scheme, contrast: .standard).chosenBubbleHex
                    == context.customBubbleHex, "\(scheme): a custom color too")
        }
    }

    @Test func defaultMarkIsStableAndColorful() {
        let first = SimpleBotMark.defaultMark(for: "nova")
        #expect(first == SimpleBotMark.defaultMark(for: "nova"))
        let marks = Set(["nova", "havok", "sage", "miso", "default", "travel", "home", "finance"]
            .map(SimpleBotMark.defaultMark(for:)))
        #expect(marks.count > 3, "Different bots start looking different")
        #expect(!marks.contains { $0.color == .black || $0.color == .gray })
    }

    @Test func everyShapeDrawsInsideItsSquare() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        for shape in SimpleBotShape.allCases {
            let bounds = shape.path(in: rect).boundingRect
            #expect(!bounds.isEmpty, "\(shape)")
            #expect(rect.insetBy(dx: -1, dy: -1).contains(bounds), "\(shape) spills out: \(bounds)")
            #expect(bounds.width > 40 && bounds.height > 30, "\(shape) is too small: \(bounds)")
        }
        #expect(SimpleBotShape.allCases.count == 13)
        #expect(SimpleBotColor.allCases.count == 11)
    }

    @Test func markStoreKeepsEachComputersBotsApart() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SimpleBotMarkStore(defaults: defaults)
        let star = SimpleBotMark(shape: .star, color: .purple)
        store.set(star, scope: "computer:a", agentID: "nova")
        #expect(SimpleBotMarkStore(defaults: defaults).mark(scope: "computer:a", agentID: "nova") == star)
        #expect(store.mark(scope: "computer:b", agentID: "nova") == nil)
        store.set(nil, scope: "computer:a", agentID: "nova")
        #expect(SimpleBotMarkStore(defaults: defaults).mark(scope: "computer:a", agentID: "nova") == nil)
    }

    /// Multi-gateway: the other gateways' bots join the list, by their latest chat, each keeping one ID
    /// whichever gateway is selected, so a dragged order survives a switch.
    @Test func multiGatewayListsEveryGatewaysBots() {
        let home = UUID(uuidString: "0D0D0D0D-0000-4000-8000-000000000001")!
        let studio = UUID(uuidString: "0D0D0D0D-0000-4000-8000-000000000002")!
        func bot(_ id: String, isDefault: Bool = false) -> AgentProfile {
            AgentProfile(id: id, name: id.capitalized, role: "", summary: "", instructions: "", avatarFileName: nil,
                         isDefault: isDefault)
        }
        func gatewayBot(_ id: String, hidden: Bool = false, at seconds: TimeInterval?) -> SimpleBotsGatewayBot {
            SimpleBotsGatewayBot(
                agent: FleetAgent(hostID: studio, profileID: id, name: id.capitalized, role: "", avatarFile: nil,
                                  isPinned: false, isDefault: false,
                                  placement: hidden ? AgentListPlacement(isHidden: true) : nil),
                gatewayName: "Studio Mac", imageURL: nil, preview: seconds.map { _ in "Hi from \(id)" },
                date: seconds.map { Date(timeIntervalSince1970: $0) })
        }
        let profiles = [bot("default", isDefault: true), bot("nova")]
        let summaries = [SessionSummary(id: "nova", kind: .direct, agentIDs: ["nova"], title: "nova", preview: "Nova",
                                        updatedAt: Date(timeIntervalSince1970: 20))]
        let others = [gatewayBot("rio", at: 30), gatewayBot("sage", at: nil), gatewayBot("ghost", hidden: true, at: 99)]

        let off = SimpleBotsHomeProjection.home(profiles: profiles, primaryID: nil, pinnedIDs: [], summaries: summaries)
        #expect(off.rows.map(\.id) == ["bot:nova"])

        let on = SimpleBotsHomeProjection.home(profiles: profiles, primaryID: nil, pinnedIDs: [], summaries: summaries,
                                               gateways: (home, others))
        #expect(on.primary?.id == "default")
        #expect(on.rows.map(\.id) == ["bot:\(studio.uuidString)/rio", "bot:\(home.uuidString)/nova",
                                      "bot:\(studio.uuidString)/sage"])
        let dragged = SimpleBotsHomeProjection.home(
            profiles: profiles, primaryID: nil, pinnedIDs: [], summaries: summaries,
            order: ["bot:\(studio.uuidString)/sage", "bot:\(home.uuidString)/nova"], gateways: (home, others))
        #expect(dragged.rows.map(\.id) == ["bot:\(studio.uuidString)/rio", "bot:\(studio.uuidString)/sage",
                                           "bot:\(home.uuidString)/nova"], "Not placed yet first, then the order")
    }

    @Test func homeLeadsWithThePrimaryBotThenPinnedThenLatest() {
        func bot(_ id: String, hidden: Bool = false, isDefault: Bool = false) -> AgentProfile {
            AgentProfile(id: id, name: id.capitalized, role: "", summary: "", instructions: "", avatarFileName: nil,
                         isDefault: isDefault, placement: hidden ? AgentListPlacement(isHidden: true) : nil)
        }
        func chat(_ id: String, _ agents: [String], kind: SessionKind = .direct, at seconds: TimeInterval) -> SessionSummary {
            SessionSummary(id: id, kind: kind, agentIDs: agents, title: id, preview: "From \(id)",
                           updatedAt: Date(timeIntervalSince1970: seconds))
        }
        let profiles = [bot("default", isDefault: true), bot("nova"), bot("sage"), bot("havok"), bot("ghost", hidden: true),
                        bot("quiet")]
        let summaries = [chat("nova-old", ["nova"], at: 10), chat("nova-new", ["nova"], at: 50),
                         chat("sage", ["sage"], at: 40), chat("havok", ["havok"], at: 30),
                         chat("room", ["nova", "sage"], kind: .botMode, at: 45), chat("ghost", ["ghost"], at: 99)]

        let home = SimpleBotsHomeProjection.home(profiles: profiles, primaryID: nil, pinnedIDs: ["havok"],
                                                 summaries: summaries)
        #expect(home.primary?.id == "default", "Without a pick, the default bot leads")
        #expect(home.pinned.map(\.id) == ["havok"], "A pinned bot sits beside it")
        #expect(home.rows.map(\.id) == ["bot:nova", "group:room", "bot:sage", "bot:quiet"])
        #expect(home.rows[0].preview == "From nova-new", "A bot shows its latest chat")
        #expect(!home.rows.contains { $0.id == "bot:ghost" }, "Hidden bots stay off the home")

        let picked = SimpleBotsHomeProjection.home(profiles: profiles, primaryID: "sage", pinnedIDs: [],
                                                   summaries: summaries)
        #expect(picked.primary?.id == "sage")
        #expect(picked.primaryPreview?.id == "sage")
        #expect(picked.rows.first?.id == "bot:nova")
    }

    private func bots(_ ids: [String], hidden: Set<String> = []) -> [AgentProfile] {
        ids.map { id in
            AgentProfile(id: id, name: id.capitalized, role: "", summary: "", instructions: "", avatarFileName: nil,
                         isDefault: id == "default", placement: hidden.contains(id) ? AgentListPlacement(isHidden: true) : nil)
        }
    }

    /// Six on top, all the same size: the primary bot and five pinned ones, three to a row. Later pins
    /// lead the list; hidden ones don't show.
    @Test func topHoldsTwoRowsOfThree() {
        let profiles = bots(["default", "a", "b", "c", "d", "e", "f", "g"], hidden: ["b"])
        let home = SimpleBotsHomeProjection.home(profiles: profiles, primaryID: nil,
                                                 pinnedIDs: ["default", "a", "b", "c", "d", "e", "f", "g"], summaries: [])
        #expect(home.primary?.id == "default")
        #expect(home.pinned.map(\.id) == ["a", "c", "d", "e", "f"])
        let top = [home.primary!] + home.pinned
        #expect(SimpleBotsHomeProjection.topRows(top).map { $0.map(\.id) } == [["default", "a", "c"], ["d", "e", "f"]])
        #expect(home.rows.map(\.id) == ["bot:g"], "A pin past the top leads the list")
        #expect(home.top.map(\.id) == ["default", "a", "c", "d", "e", "f"], "Undragged, the primary bot leads")

        let dragged = SimpleBotsHomeProjection.home(profiles: profiles, primaryID: nil,
                                                    pinnedIDs: ["default", "a", "c", "d"], summaries: [],
                                                    topOrder: ["c", "default", "a"])
        #expect(dragged.top.map(\.id) == ["c", "default", "a", "d"],
                "The dragged order, the primary bot among them; a pin not placed yet follows")
    }

    /// Only pins the top shows count: the primary bot (pinned as the default), hidden bots and bots
    /// this computer no longer has filled the shared list and left room for two.
    @Test func onlyPinsTheHomeShowsCountTowardSix() {
        let profiles = bots(["default", "hidden", "a", "b", "c"], hidden: ["hidden"])
        let pins = ["default", "hidden", "gone", "a", "b"]
        #expect(SimpleBotsHomeProjection.canPin("c", profiles: profiles, primaryID: nil, pinnedIDs: pins))
        #expect(!SimpleBotsHomeProjection.canPin("default", profiles: profiles, primaryID: nil, pinnedIDs: pins),
                "The primary bot isn't pinned below itself")
        #expect(!SimpleBotsHomeProjection.canPin("a", profiles: profiles, primaryID: nil, pinnedIDs: pins), "Already pinned")
        let full = bots(["default", "a", "b", "c", "d", "e", "f"])
        #expect(!SimpleBotsHomeProjection.canPin("f", profiles: full, primaryID: nil,
                                                 pinnedIDs: ["a", "b", "c", "d", "e"]), "Six on top is the most")
    }

    /// A dragged order wins; a bot or group chat not placed yet leads, by its latest chat.
    @Test func draggedOrderPlacesTheListAndNewOnesLead() {
        let profiles = bots(["default", "a", "b", "c", "new"])
        let summaries = [SessionSummary(id: "c-chat", kind: .direct, agentIDs: ["c"], title: "c", preview: "Hi",
                                        updatedAt: Date(timeIntervalSince1970: 90)),
                         SessionSummary(id: "room", kind: .botMode, agentIDs: ["a", "b"], title: "Room", preview: "Yo",
                                        updatedAt: Date(timeIntervalSince1970: 80))]
        let home = SimpleBotsHomeProjection.home(profiles: profiles, primaryID: nil, pinnedIDs: [], summaries: summaries,
                                                 order: ["bot:b", "group:room", "bot:a", "bot:c"])
        #expect(home.rows.map(\.id) == ["bot:new", "bot:b", "group:room", "bot:a", "bot:c"])
        #expect(SimpleBotsHomeProjection.moving("bot:c", to: "bot:b", in: home.rows.map(\.id))
                == ["bot:new", "bot:c", "bot:b", "group:room", "bot:a"])
        #expect(SimpleBotsHomeProjection.moving("bot:new", to: "bot:c", in: ["bot:new", "bot:b", "bot:c"])
                == ["bot:b", "bot:c", "bot:new"], "Dragged down, it takes the place under the finger")
    }

    @Test func draggedOrderIsKeptPerComputer() {
        let defaults = UserDefaults(suiteName: "SimpleBotsOrder-\(UUID().uuidString)")!
        let store = SimpleBotsOrderStore(defaults: defaults)
        store.set(["bot:a", "bot:b"], scope: "studio")
        #expect(store.order(scope: "studio") == ["bot:a", "bot:b"])
        #expect(store.order(scope: "laptop").isEmpty)
        #expect(SimpleBotsOrderStore(defaults: defaults).order(scope: "studio") == ["bot:a", "bot:b"])
    }

    @Test func autoReviewIsSmartOrManualAndNeverTurnsApprovalsOff() async throws {
        let host = SimpleBotDemoConfiguration()
        let settings = SimpleBotHostSettings(client: host, profile: "default", allProfiles: { ["default", "nova"] })
        await settings.refresh()
        #expect(settings.load == .loaded)
        #expect(settings.autoReview)

        await settings.setAutoReview(false)
        #expect(!settings.autoReview)
        #expect(try await host.read(profile: "default")["approvals"]?.object?["mode"] == .string("manual"))
        await settings.setAutoReview(true)
        #expect(try await host.read(profile: "default")["approvals"]?.object?["mode"] == .string("smart"))

        await settings.setRules("  Ask before deleting files.  ")
        #expect(settings.rules == "Ask before deleting files.")
        #expect(try await host.read(profile: "default")["approvals"]?.object?["mode"] == .string("smart"),
                "Saving rules keeps the mode: Hermes merges a save")

        await settings.setTimeZone("America/Chicago")
        #expect(settings.timeZone == "America/Chicago")
        #expect(try await host.read(profile: "nova")["timezone"] == .string("America/Chicago"),
                "Every bot on the computer follows the time zone")
    }

    @Test func approvalsOffOnTheHostIsSaidPlainly() async throws {
        let host = SimpleBotDemoConfiguration()
        try await host.write(["approvals": .object(["mode": .string("off")])], profile: "default")
        let settings = SimpleBotHostSettings(client: host, profile: "default", allProfiles: { ["default"] })
        await settings.refresh()
        #expect(!settings.autoReview)
        #expect(settings.approvalsOff)
    }
}

@MainActor
struct TeamworkTests {
    @Test func statusIsReadLeniently() throws {
        let status = try TeamworkStatus(json: [
            "enabled": .boolean(true), "extra": .string("ignored"),
            "agents": .array([.object(["id": .string("default"), "name": .string("Gordie"), "role": .string("Chief")]),
                              .object(["id": .string("Bad Id!"), "name": .string("Nope")]),
                              .object(["id": .string("nova"), "name": .string("Nova")])]),
            "reached": .array([.string("default"), .string("nova")]), "failed": .array([]),
        ])
        #expect(status.enabled)
        #expect(status.agents.map(\.id) == ["default", "nova"])
        #expect(status.agents[1].role == "")
        #expect(throws: WorkspaceClientError.self) { try TeamworkStatus(json: ["agents": .array([])]) }
    }

    @Test func switchSaysWhatItDoes() async {
        let model = TeamworkModel(client: DemoTeamworkClientForTests())
        await model.refresh()
        #expect(model.load == .loaded)
        #expect(!model.isOn)
        #expect(model.detail == "Your agents learn about each other and ask each other for help.")
        await model.set(true)
        #expect(model.isOn)
        #expect(model.detail == "Your 3 agents know each other and ask each other for help.")
    }

    @Test func olderPluginAsksForAnUpdate() async {
        let model = TeamworkModel(client: FailingTeamworkClient(error: .unavailable(.unsupportedOperation)))
        await model.refresh()
        #expect(model.load == .needsPluginUpdate)
        #expect(model.detail == "Update the bighelp plugin on this computer to use this.")
    }

    @Test func agentsTheComputerMissedAreNamed() async {
        let model = TeamworkModel(client: PartialTeamworkClient())
        await model.set(true)
        #expect(model.detail == "The computer didn't save it for Nova. Try again.")
    }
}

@MainActor
private final class DemoTeamworkClientForTests: TeamworkClient {
    private let demo = DemoTeamworkClient()
    func team(enabled: Bool?) async throws -> TeamworkStatus { try await demo.team(enabled: enabled) }
}

@MainActor
private final class FailingTeamworkClient: TeamworkClient {
    let error: WorkspaceClientError
    init(error: WorkspaceClientError) { self.error = error }
    func team(enabled: Bool?) async throws -> TeamworkStatus { throw error }
}

@MainActor
private final class PartialTeamworkClient: TeamworkClient {
    func team(enabled: Bool?) async throws -> TeamworkStatus {
        TeamworkStatus(enabled: true, agents: [.init(id: "default", name: "Gordie", role: ""),
                                               .init(id: "nova", name: "Nova", role: "")],
                       reached: ["default"], failed: ["nova"])
    }
}
