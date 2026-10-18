import Foundation
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
        #expect(home.rows.map(\.id) == ["bot:havok", "bot:nova", "group:room", "bot:sage", "bot:quiet"])
        #expect(home.rows[1].preview == "From nova-new", "A bot shows its latest chat")
        #expect(!home.rows.contains { $0.id == "bot:ghost" }, "Hidden bots stay off the home")

        let picked = SimpleBotsHomeProjection.home(profiles: profiles, primaryID: "sage", pinnedIDs: [],
                                                   summaries: summaries)
        #expect(picked.primary?.id == "sage")
        #expect(picked.primaryPreview?.id == "sage")
        #expect(picked.rows.first?.id == "bot:nova")
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
