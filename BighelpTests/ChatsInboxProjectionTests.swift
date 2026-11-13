import Foundation
import Testing
@testable import Bighelp

/// The Chats view's one list: every computer's chats merged, the computer in use live and the
/// others from their all-hosts copies, Pinned first and then the newest.
@MainActor
struct ChatsInboxProjectionTests {
    private static let home = UUID()
    private static let studio = UUID()
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, at minutesAgo: Double, pinned: Bool = false, unread: Bool = false,
                         title: String? = nil, preview: String = "") -> SessionSummary {
        SessionSummary(id: id, kind: .direct, agentIDs: ["mina"], title: title ?? id.capitalized, preview: preview,
                       updatedAt: Self.now.addingTimeInterval(-minutesAgo * 60), isPinned: pinned,
                       isUnread: unread, tracksUnread: true)
    }

    private func fleetChat(_ id: String, on hostID: UUID, at minutesAgo: Double, title: String? = nil) -> FleetChat {
        FleetChat(hostID: hostID, profileID: "otto", storedSessionID: id, title: title ?? id.capitalized,
                  preview: "", updatedAt: Self.now.addingTimeInterval(-minutesAgo * 60), isActive: false)
    }

    private func room(_ id: String) -> HermesBotModeRoomSummary {
        let members = ["mina", "otto"].map { profile in
            HermesBotModeRoomMember(memberID: "member-\(profile)", profile: profile, handle: profile,
                                    target: ["kind": .string("local"), "profile": .string(profile)])
        }
        return HermesBotModeRoomSummary(room: HermesBotModeRoomState(
            roomID: id, name: id.capitalized, members: members, authorityGatewayID: "gateway", authorityEpoch: 1,
            revision: 1, createdAt: 50, updatedAt: 60, latestSequence: 0, disbandedAt: nil, driverStatus: nil),
            capabilities: nil)
    }

    private func computers(home: [FleetChat] = [], studio: [FleetChat]) -> [ChatsInboxComputer] {
        [ChatsInboxComputer(id: Self.home, name: "Home Mac", chats: home, groups: []),
         ChatsInboxComputer(id: Self.studio, name: "Studio Mac", chats: studio, groups: [])]
    }

    @Test func pinnedComeFirstThenTheNewest() {
        let rows = ChatsInboxProjection.rows(ChatsInboxInput(
            sessions: [session("old", at: 300), session("pinned", at: 900, pinned: true), session("new", at: 5)],
            selectedHostID: Self.home,
            computers: computers(studio: [fleetChat("studio-mid", on: Self.studio, at: 60)])))

        #expect(rows.map(\.title) == ["Pinned", "New", "Studio-Mid", "Old"])
    }

    @Test func theComputerInUsesCopiesAreDropped() {
        let rows = ChatsInboxProjection.rows(ChatsInboxInput(
            sessions: [session("live", at: 10)],
            selectedHostID: Self.home,
            computers: computers(home: [fleetChat("live", on: Self.home, at: 10)],
                                 studio: [fleetChat("away", on: Self.studio, at: 20)]),
            showsComputerTags: true))

        #expect(rows.map(\.title) == ["Live", "Away"], "The live chat once, from its catalog")
        #expect(rows[0].isOnComputerInUse && rows[0].computerTag == nil)
        #expect(rows[1].computerTag == "Studio Mac")
    }

    @Test func oneComputerShowsNoComputerTags() {
        let rows = ChatsInboxProjection.rows(ChatsInboxInput(
            sessions: [session("live", at: 10)], selectedHostID: Self.home,
            computers: computers(studio: [fleetChat("away", on: Self.studio, at: 20)]), showsComputerTags: false))

        #expect(rows.allSatisfy { $0.computerTag == nil })
    }

    @Test func aComputerChipShowsOnlyThatComputersChats() {
        let rows = ChatsInboxProjection.rows(ChatsInboxInput(
            sessions: [session("live", at: 10)], selectedHostID: Self.home,
            computers: computers(studio: [fleetChat("away", on: Self.studio, at: 20)]), showsComputerTags: true))

        #expect(ChatsInboxProjection.filter(rows, by: .computer(Self.studio), matching: "").map(\.title) == ["Away"])
        #expect(ChatsInboxProjection.filter(rows, by: .computer(Self.home), matching: "").map(\.title) == ["Live"])
        #expect(ChatsInboxProjection.filter(rows, by: .all, matching: "").count == 2)
    }

    /// Another computer's copy has no read state, so only the computer in use's chats can be unread.
    @Test func unreadShowsOnlyUnreadChats() {
        let rows = ChatsInboxProjection.rows(ChatsInboxInput(
            sessions: [session("seen", at: 10), session("fresh", at: 20, unread: true)], selectedHostID: Self.home,
            computers: computers(studio: [fleetChat("away", on: Self.studio, at: 5)])))

        #expect(ChatsInboxProjection.filter(rows, by: .unread, matching: "").map(\.title) == ["Fresh"])
    }

    @Test func searchLooksAtTitlesAndPreviews() {
        let rows = ChatsInboxProjection.rows(ChatsInboxInput(
            sessions: [session("trip", at: 10, title: "Lisbon trip"),
                       session("budget", at: 20, title: "Budget", preview: "Dining is capped at $300.")],
            selectedHostID: Self.home,
            computers: computers(studio: [fleetChat("away", on: Self.studio, at: 5, title: "Widget fix")])))

        #expect(ChatsInboxProjection.filter(rows, by: .all, matching: " lisbon ").map(\.title) == ["Lisbon trip"])
        #expect(ChatsInboxProjection.filter(rows, by: .all, matching: "dining").map(\.title) == ["Budget"])
        #expect(ChatsInboxProjection.filter(rows, by: .all, matching: "widget").map(\.title) == ["Widget fix"])
        #expect(ChatsInboxProjection.filter(rows, by: .all, matching: "nothing").isEmpty)
    }

    /// A group chat just made has no messages, so the catalog doesn't list it yet: Hermes' rooms do.
    @Test func aGroupChatWithNoMessageYetShowsOnce() {
        let talked = SessionSummary(id: "hermes-room:crew", kind: .botMode, agentIDs: ["mina", "otto"], title: "Crew",
                                    preview: "Hi", updatedAt: Self.now, hostedRoomID: "crew")
        let rows = ChatsInboxProjection.rows(ChatsInboxInput(
            sessions: [talked], rooms: [room("crew"), room("fresh")], selectedHostID: Self.home))

        #expect(rows.map(\.id) == ["here/hermes-room:crew", "here/hermes-room:fresh"])
        #expect(rows.allSatisfy(\.isGroup))
        #expect(rows[1].memberIDs == ["mina", "otto"])
        #expect(!rows[1].canPin && !rows[1].canRename, "Group chats are managed in their own settings")
    }

    @Test func codingSessionsCarryTheCodeTag() {
        let rows = ChatsInboxProjection.rows(ChatsInboxInput(
            sessions: [session("fix", at: 10), session("chat", at: 20)], codeSessionIDs: ["fix"],
            selectedHostID: Self.home))

        #expect(rows.map(\.isCode) == [true, false])
    }

    /// Another computer's chat renames and archives through the fleet; it has no pin or read state.
    @Test func anotherComputersChatOffersOnlyWhatTheFleetCanDo() throws {
        let rows = ChatsInboxProjection.rows(ChatsInboxInput(
            selectedHostID: Self.home, computers: computers(studio: [fleetChat("away", on: Self.studio, at: 5)])))

        let away = try #require(rows.first)
        #expect(away.canRename && away.canArchive)
        #expect(!away.canPin && !away.canMarkUnread)
    }

    @Test func sectionsArePinnedThenByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let rows = ChatsInboxProjection.rows(ChatsInboxInput(
            sessions: [session("pinned", at: 5 * 24 * 60, pinned: true), session("today", at: 1),
                       session("yesterday", at: 24 * 60), session("older", at: 4 * 24 * 60)],
            selectedHostID: Self.home))

        let sections = ChatsInboxProjection.sections(rows, now: Self.now, calendar: calendar)

        #expect(sections.map(\.kind) == [.pinned, .today, .yesterday, .earlier])
        #expect(sections.map { $0.rows.map(\.title) } == [["Pinned"], ["Today"], ["Yesterday"], ["Older"]])
    }

    @Test func theCacheSortsOnlyWhenAnInputChanges() {
        let cache = ChatsInboxCache()
        var builds = 0
        let key = ChatsInboxCache.Key(revision: 1, rooms: [], codeSessionIDs: [], selectedHostID: Self.home,
                                      computers: [], showsComputerTags: false)
        let build = { builds += 1; return [ChatsInboxRow]() }

        _ = cache.rows(for: key, build: build)
        _ = cache.rows(for: key, build: build)
        #expect(builds == 1)
        _ = cache.rows(for: ChatsInboxCache.Key(revision: 2, rooms: [], codeSessionIDs: [], selectedHostID: Self.home,
                                                computers: [], showsComputerTags: false), build: build)
        #expect(builds == 2)
    }
}
