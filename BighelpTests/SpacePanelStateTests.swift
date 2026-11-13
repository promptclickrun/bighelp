import Foundation
import Testing
@testable import Bighelp

/// A space panel's one footer line, picked from what the computer said (never the time it was
/// drawn), and how its time reads.
@MainActor
struct SpacePanelStateTests {
    static func space(_ changes: [String: BighelpJSONValue?] = [:]) throws -> Space {
        try #require(Space(json: SpacesWireTests.spaceJSON(changes)))
    }

    static func item(_ space: Space, isConnected: Bool = true) -> TodaySpace {
        TodaySpace(id: TodaySpace.id(scope: "scope", key: space.key), space: space, scope: "scope", hostKey: "demo",
                   computerName: "Demo computer", botName: "Research", isConnected: isConnected)
    }

    static func routine(state: String, usesAI: Bool = false) -> BighelpJSONValue {
        .object(["kind": .string(usesAI ? "ai" : "script"), "usesAI": .boolean(usesAI),
                 "updates": .string("Every 15 minutes"), "state": .string(state)])
    }

    @Test func aFreshSpaceSaysWhenItUpdated() throws {
        let space = try Self.space()
        let footer = SpacePanelFooter.state(for: Self.item(space), size: .small)
        #expect(footer == .updated(space.updatedAt, usesAI: false))
        #expect(space.updatedAt != nil)
    }

    @Test func anAIRoutineCarriesTheBadge() throws {
        let space = try Self.space(["routine": Self.routine(state: "running", usesAI: true)])
        #expect(SpacePanelFooter.state(for: Self.item(space), size: .small) == .updated(space.updatedAt, usesAI: true))
    }

    @Test(arguments: ["missing", "failed", "late", "something-new"])
    func aRoutineThatIsNotRunningStopsThePanel(state: String) throws {
        let space = try Self.space(["routine": Self.routine(state: state), "status": .string("stale")])
        #expect(SpacePanelFooter.state(for: Self.item(space), size: .small) == .stopped(.idle))
    }

    /// Paused in Scheduled tasks: only the person resumes it there, so no Try again and no error.
    @Test func aPausedRoutineSaysWhereToResumeIt() throws {
        let space = try Self.space(["routine": Self.routine(state: "paused"), "status": .string("stopped")])
        #expect(SpacePanelFooter.state(for: Self.item(space), size: .small) == .paused)
    }

    /// The bot changed its script after the space was added: no Try again, which can't fix it.
    @Test func aChangedScriptStopsThePanelWithoutTryAgain() throws {
        let routine: BighelpJSONValue = .object(["kind": .string("script"), "usesAI": .boolean(false),
                                                 "updates": .string("Every 15 minutes"), "state": .string("failed"),
                                                 "problem": .string("script_changed")])
        let space = try Self.space(["routine": routine, "status": .string("stopped")])
        #expect(SpacePanelFooter.state(for: Self.item(space), size: .small) == .scriptChanged)
        // Another problem is an ordinary stop, with Try again.
        let failed: BighelpJSONValue = .object(["kind": .string("script"), "state": .string("failed"),
                                                "problem": .string("script_failed")])
        let other = try Self.space(["routine": failed, "status": .string("stopped")])
        #expect(SpacePanelFooter.state(for: Self.item(other), size: .small) == .stopped(.idle))
    }

    @Test func theComputerSayingStoppedStopsARunningRoutine() throws {
        let space = try Self.space(["status": .string("stopped")])
        #expect(SpacePanelFooter.state(for: Self.item(space), size: .small, retry: .running) == .stopped(.running))
    }

    @Test func aComputerThatIsNotConnectedSaysSoAndKeepsItsCard() throws {
        let stopped = try Self.space(["routine": Self.routine(state: "late")])
        #expect(SpacePanelFooter.state(for: Self.item(stopped, isConnected: false), size: .small) == .notConnected)
        let noCard = try Self.space(["card": nil, "sizes": nil])
        #expect(SpacePanelFooter.state(for: Self.item(noCard, isConnected: false), size: .small) == .notConnected)
    }

    @Test func aCardThatCanNotBeDrawnSaysSo() throws {
        let space = try Self.space(["card": .object(["schema": .string("other")]), "sizes": nil])
        #expect(space.cardUnreadable)
        #expect(SpacePanelFooter.state(for: Self.item(space), size: .wide) == .unreadable)
    }

    @Test func aCardNotReadYetIsAStillPlaceholder() throws {
        let space = try Self.space(["card": nil, "sizes": nil, "cardOmitted": .boolean(true)])
        #expect(SpacePanelFooter.state(for: Self.item(space), size: .small) == .loading)
    }

    @Test func eachSizeDrawsItsOwnCardOrTheSpaceCard() throws {
        // Only a Tall card: Tall draws it, the other sizes wait for theirs.
        let space = try Self.space(["card": nil])
        #expect(SpacePanelFooter.state(for: Self.item(space), size: .tall) == .updated(space.updatedAt, usesAI: false))
        #expect(SpacePanelFooter.state(for: Self.item(space), size: .small) == .loading)
    }

    @Test func aDraftPreviewHasNoFooter() throws {
        let space = try Self.space(["state": .string("draft"), "status": .string("draft"),
                                    "routine": Self.routine(state: "draft")])
        #expect(SpacePanelFooter.state(space: space, size: .wide, isConnected: true) == .none)
    }

    @Test func tryAgainNamesOnlyTheAnswersThePersonCanActOn() {
        #expect(SpacePanelRetry.after(.tooSoon(retryAfter: 40)) == .tooSoon)
        #expect(SpacePanelRetry.after(.routineFailed(nil)) == .failed)
        #expect(SpacePanelRetry.after(.unreachable) == .idle)
        #expect(SpacePanelRetry.after(.notFound) == .idle)
    }

    @Test func tryAgainKeepsTheComputersAnswer() async {
        let retry = SpacePanelRetryModel()
        retry.run { () async throws(SpacesError) -> SpaceRefreshRun in throw .tooSoon(retryAfter: nil) }
        #expect(retry.state == .running)
        while retry.state == .running { await Task.yield() }
        #expect(retry.state == .tooSoon)
    }

    // MARK: Time

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    static let locale = Locale(identifier: "en_US")

    /// iOS writes a narrow space before AM and PM.
    static func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    @Test func todayIsATime() throws {
        let now = try #require(SpacesWire.date(.string("2026-11-12T18:00:00Z")))
        let updated = try #require(SpacesWire.date(.string("2026-11-12T14:14:00Z")))
        #expect(Self.plain(SpacePanelTime.text(updated, now: now, calendar: Self.calendar, locale: Self.locale)) == "2:14 PM")
    }

    @Test func anotherDayIsADate() throws {
        let now = try #require(SpacesWire.date(.string("2026-11-12T08:00:00Z")))
        let yesterday = try #require(SpacesWire.date(.string("2026-11-10T23:30:00Z")))
        #expect(SpacePanelTime.text(yesterday, now: now, calendar: Self.calendar, locale: Self.locale) == "Nov 10")
        let lastYear = try #require(SpacesWire.date(.string("2025-12-31T09:00:00Z")))
        #expect(SpacePanelTime.text(lastYear, now: now, calendar: Self.calendar, locale: Self.locale) == "Dec 31, 2025")
    }
}
