import Foundation
import Testing
@testable import Bighelp

/// Bots mode's sections: folders of bots and group chats on the home. A bot's section is on its own
/// profile (Hermes Desktop's field); the sections list and group chats' sections, pins and hides are
/// the app's (`FleetStore`), kept on the computers too.
@MainActor
struct SimpleBotsSectionsTests {
    static let home = UUID(uuidString: "0D0D0D0D-0000-4000-8000-000000000001")!
    static let studio = UUID(uuidString: "0D0D0D0D-0000-4000-8000-000000000002")!

    @MainActor
    final class Reader: FleetHostReading {
        var hosts = [FleetHost(id: SimpleBotsSectionsTests.home, name: "Home Mac", isSelected: true),
                     FleetHost(id: SimpleBotsSectionsTests.studio, name: "Studio Mac", isSelected: false)]
        var snapshots: [UUID: FleetSnapshot] = [:]

        func read(_ hostID: UUID, avatars: FleetAvatarFolder) async throws -> FleetSnapshot {
            snapshots[hostID] ?? FleetSnapshot(refreshedAt: Date())
        }

        func select(_ hostID: UUID) {}
        func canOpen(_ hostID: UUID) -> Bool { true }
        func setPinned(_ pinned: Bool, hostID: UUID, profileID: String) -> Bool { true }
        /// Keeps it, as the computer would.
        func setPlacement(_ placement: AgentListPlacement, hostID: UUID, profileID: String) async throws {
            guard let index = snapshots[hostID]?.agents.firstIndex(where: { $0.profileID == profileID }) else { return }
            snapshots[hostID]?.agents[index].placement = placement
        }
        func updateChat(_ change: FleetChatChange, chat: FleetChat) async throws {}
    }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "bot-sections-\(UUID().uuidString)")
    }

    private func bot(_ id: String, on host: UUID? = nil, in section: FleetSection? = nil, hidden: Bool = false) -> SimpleBotsBot {
        var bot = SimpleBotsBot(id: host.map { FleetID.make($0, id) } ?? id, profileID: id, hostID: host,
                                name: id.capitalized, role: "", isHidden: hidden)
        bot.placement = AgentListPlacement(sectionID: section?.id, sectionName: section?.name, isHidden: hidden)
        return bot
    }

    private func group(_ room: String, on host: UUID = home, members: [SimpleBotsBot] = []) -> SimpleBotsGroup {
        SimpleBotsGroup(FleetGroup(hostID: host, roomID: room, name: room.capitalized, memberNames: [],
                                   updatedAt: Date(timeIntervalSince1970: 10), isWorking: false, canRename: false,
                                   canDelete: false), members: members)
    }

    private let work = FleetSection(id: "sec-work", name: "Work")
    private let family = FleetSection(id: "sec-family", name: "Family")

    // MARK: The home

    /// A section holds its members, on top or not; the list under the top keeps only bots and group
    /// chats in no section. An empty section shows; hidden ones go nowhere.
    @Test func sectionsHoldTheirMembersAndTheListKeepsTheRest() throws {
        let bots = [bot("default", in: work), bot("mina", in: work), bot("otto"), bot("juno", in: work, hidden: true)]
        let crew = group("crew"), team = group("team")
        let sectioning = SimpleBotsSectioning(sections: [work, family], groupSections: [crew.key!: work.id])

        let shown = SimpleBotsHomeProjection.home(bots: bots, primaryID: "default", pinnedIDs: [], latest: [:],
                                                  groups: [crew, team], sectioning: sectioning)

        #expect(shown.sections.map(\.section) == [work, family], "In the person's order; an empty one shows")
        let card = try #require(shown.sections.first)
        #expect(Set(card.members.map(\.id)) == ["bot:default", "bot:mina", crew.itemID],
                "The primary bot is on top and in its section")
        #expect(card.countText == "2 bots, 1 group chat")
        #expect(shown.sections[1].countText == "Empty")
        #expect(shown.rows.map(\.id) == [team.itemID, "bot:otto"], "The list has what's in no section")
        #expect(!shown.rows.contains { $0.id == "bot:juno" } && !card.members.contains { $0.id == "bot:juno" })
    }

    /// With one gateway (Multi-gateway off, or one picked in Filter by Gateway) a section shows only
    /// that gateway's members, and one whose members are all on another gateway stays off.
    @Test func aSectionWithMembersOnlyElsewhereStaysOffTheHome() async throws {
        let reader = Reader()
        let studioOnly = FleetSection(id: "sec-studio", name: "Studio things")
        reader.snapshots[Self.studio] = FleetSnapshot(agents: [
            FleetAgent(hostID: Self.studio, profileID: "rio", name: "Rio", role: "", isPinned: false, isDefault: false,
                       placement: AgentListPlacement(sectionID: studioOnly.id, sectionName: studioOnly.name)),
        ], refreshedAt: Date())
        let fleet = FleetStore(reader: reader, directory: folder(), saveDelay: .zero)
        fleet.refresh()
        await fleet.waitForReads()
        fleet.sections = [work, studioOnly]
        fleet.groupSectionIDs = [FleetID.make(Self.studio, "group/launch"): work.id]

        let here = SimpleBotsSectioning(fleet: fleet, shown: [Self.home])
        #expect(here.elsewhere == [studioOnly.id, work.id])
        let mina = bot("mina", on: Self.home, in: work)
        let oneGateway = SimpleBotsHomeProjection.home(bots: [mina], primaryID: nil, pinnedIDs: [], latest: [:],
                                                       groups: [], sectioning: here)
        #expect(oneGateway.sections.map(\.section) == [work], "Work has Mina here; Studio things has no one here")
        #expect(oneGateway.sections[0].countText == "1 bot", "Only this gateway's members count")

        let every = SimpleBotsSectioning(fleet: fleet)
        let rio = bot("rio", on: Self.studio, in: studioOnly)
        let launch = group("launch", on: Self.studio)
        let multi = SimpleBotsHomeProjection.home(bots: [mina, rio], primaryID: nil, pinnedIDs: [], latest: [:],
                                                  groups: [launch], sectioning: every)
        #expect(multi.sections.map(\.section) == [work, studioOnly])
        #expect(multi.sections[0].countText == "1 bot, 1 group chat")
        #expect(multi.sections[0].hostIDs == [Self.studio, Self.home] || multi.sections[0].hostIDs == [Self.home, Self.studio])
    }

    /// Same-named sections on two computers show as one; two bots with one name stay two.
    @Test func sameNamedSectionsAcrossComputersShowAsOne() async throws {
        let fleet = FleetStore(reader: Reader(), directory: folder(), saveDelay: .zero)
        fleet.sections = [work]
        // Hermes Desktop on the studio made its own "work" section.
        let desktop = AgentListPlacement(sectionID: "sec-desktop", sectionName: "work")
        fleet.adoptSections(adding: [desktop])
        #expect(fleet.sections == [work], "A section whose name is listed joins it")

        var rio = bot("mina", on: Self.studio)
        rio.placement = desktop
        let mina = bot("mina", on: Self.home, in: work)
        let shown = SimpleBotsHomeProjection.home(bots: [mina, rio], primaryID: nil, pinnedIDs: [], latest: [:],
                                                  groups: [], sectioning: SimpleBotsSectioning(fleet: fleet))
        let card = try #require(shown.sections.first)
        #expect(card.members.count == 2, "Two bots named Mina on two computers stay apart")
        #expect(Set(card.hostIDs) == [Self.home, Self.studio])

        // A section only Hermes Desktop knows comes in from its member.
        fleet.adoptSections(adding: [AgentListPlacement(sectionID: "sec-new", sectionName: "Errands")])
        #expect(fleet.sections.map(\.name) == ["Work", "Errands"])
    }

    // MARK: Changing sections

    /// What a phone sends for each bot, and its bots as the home sees them after.
    @MainActor
    final class Phone {
        var placements: [String: AgentListPlacement] = [:]
    }

    private func editor(_ fleet: FleetStore, _ phone: Phone, bots ids: [String], groups: [SimpleBotsGroup]) -> SimpleBotsSectionEditor {
        let bots = ids.map { id -> SimpleBotsBot in
            var bot = bot(id)
            bot.placement = phone.placements[id]
            return bot
        }
        return SimpleBotsSectionEditor(fleet: fleet, bots: bots, groups: groups) { bot, placement in
            phone.placements[bot.profileID] = placement
        }
    }

    /// New Section with members, Rename, a bot picked from another section moves, Move to Section,
    /// Edit Members, then Delete: every member stays, in No section.
    @Test func creatingRenamingMovingAndDeletingKeepsEveryMember() async throws {
        let directory = folder()
        let fleet = FleetStore(reader: Reader(), directory: directory, saveDelay: .zero)
        let phone = Phone()
        let crew = group("crew")
        let bots = ["mina", "otto"]

        let made = try #require(await editor(fleet, phone, bots: bots, groups: [crew])
            .create(named: "  Work ", members: ["bot:mina", crew.itemID]))
        #expect(made.name == "Work")
        #expect(phone.placements["mina"] == AgentListPlacement(sectionID: made.id, sectionName: "Work"))
        #expect(fleet.groupSectionIDs[crew.key!] == made.id)
        #expect(phone.placements["otto"] == nil, "Only the picked ones change")

        await editor(fleet, phone, bots: bots, groups: [crew]).rename(made.id, to: "Projects")
        #expect(fleet.sections.map(\.name) == ["Projects"])
        #expect(phone.placements["mina"]?.sectionName == "Projects", "Each member carries the new name, for Hermes Desktop")

        let family = try #require(await editor(fleet, phone, bots: bots, groups: [crew])
            .create(named: "Family", members: ["bot:mina", "bot:otto"]))
        #expect(phone.placements["mina"]?.sectionID == family.id, "A bot is in one section at a time")
        #expect(phone.placements["otto"]?.sectionID == family.id)

        let otto = try #require(editor(fleet, phone, bots: bots, groups: [crew]).bots.first { $0.profileID == "otto" })
        await editor(fleet, phone, bots: bots, groups: [crew]).move(.bot(otto), to: nil)
        #expect(phone.placements["otto"]?.sectionID == nil, "No section")
        await editor(fleet, phone, bots: bots, groups: [crew]).move(.group(crew), to: family.id)
        #expect(fleet.groupSectionIDs[crew.key!] == family.id)

        await editor(fleet, phone, bots: bots, groups: [crew]).setMembers(of: made.id, to: ["bot:otto", crew.itemID])
        #expect(phone.placements["otto"]?.sectionID == made.id)
        #expect(fleet.groupSectionIDs[crew.key!] == made.id, "Edit Members moves a group chat from another section")
        #expect(phone.placements["mina"]?.sectionID == family.id, "Ones not picked and not in it stay where they are")

        fleet.orderSections([family.id, made.id])
        #expect(fleet.sections.map(\.id) == [family.id, made.id])

        await editor(fleet, phone, bots: bots, groups: [crew]).delete(made.id)
        #expect(fleet.sections == [FleetSection(id: family.id, name: "Family")])
        #expect(phone.placements["otto"]?.sectionID == nil, "Deleting a section keeps its bots, in No section")
        #expect(fleet.groupSectionIDs[crew.key!] == nil, "and its group chats")
        #expect(phone.placements["mina"]?.sectionID == family.id)

        let relaunched = FleetStore(reader: Reader(), directory: directory, saveDelay: .zero)
        #expect(relaunched.sections.map(\.name) == ["Family"])
    }

    /// With Multi-gateway off, the home shows only this computer's bots; deleting or renaming a
    /// section still reaches its members on the others, so it can't come back from them.
    @Test func deletingASectionReachesItsMembersOnOtherComputers() async throws {
        let reader = Reader()
        let work = self.work
        reader.snapshots[Self.studio] = FleetSnapshot(agents: [
            FleetAgent(hostID: Self.studio, profileID: "rio", name: "Rio", role: "", isPinned: false, isDefault: false,
                       placement: AgentListPlacement(sectionID: work.id, sectionName: work.name)),
        ], refreshedAt: Date())
        let fleet = FleetStore(reader: reader, directory: folder(), saveDelay: .zero)
        fleet.refresh()
        await fleet.waitForReads()
        fleet.sections = [work]
        let phone = Phone()
        phone.placements["mina"] = AgentListPlacement(sectionID: work.id, sectionName: work.name)

        await editor(fleet, phone, bots: ["mina"], groups: []).rename(work.id, to: "Projects")
        #expect(fleet.agent(hostID: Self.studio, profileID: "rio")?.placement?.sectionName == "Projects")

        await editor(fleet, phone, bots: ["mina"], groups: []).delete(work.id)
        #expect(phone.placements["mina"]?.sectionID == nil)
        #expect(fleet.agent(hostID: Self.studio, profileID: "rio")?.placement?.sectionID == nil,
                "The studio's bot leaves the section too")
        fleet.adoptSections()
        #expect(fleet.sections.isEmpty, "So the section doesn't come back")
    }

    /// A section made on each computer under one name (Hermes Desktop makes its own IDs) shows as
    /// one. Renaming or deleting it changes its members one at a time, and the home takes in
    /// sections from members after each change: the other computer's ID must not bring the old
    /// section back meanwhile.
    @Test func renamingOrDeletingSameNamedSectionsLeavesNoneBehind() async throws {
        let work = self.work
        /// Mina on this computer in `work`, Rio on the studio in its own "Work".
        func setUp() async -> (FleetStore, SimpleBotsSectionEditor, Phone) {
            let reader = Reader()
            reader.snapshots[Self.studio] = FleetSnapshot(agents: [
                FleetAgent(hostID: Self.studio, profileID: "rio", name: "Rio", role: "", isPinned: false,
                           isDefault: false, placement: AgentListPlacement(sectionID: "sec-desktop", sectionName: "Work")),
            ], refreshedAt: Date())
            let fleet = FleetStore(reader: reader, directory: folder(), saveDelay: .zero)
            fleet.refresh()
            await fleet.waitForReads()
            fleet.sections = [work]
            let phone = Phone()
            phone.placements["mina"] = AgentListPlacement(sectionID: work.id, sectionName: work.name)
            var mina = bot("mina")
            mina.placement = phone.placements["mina"]
            let editor = SimpleBotsSectionEditor(fleet: fleet, bots: [mina], groups: []) { bot, placement in
                phone.placements[bot.profileID] = placement
                // What `FleetSectionAdoption` does when the gateway in use's bots change.
                fleet.adoptSections(adding: Array(phone.placements.values))
            }
            return (fleet, editor, phone)
        }

        let (renamed, renaming, _) = await setUp()
        await renaming.rename(work.id, to: "Projects")
        #expect(renamed.sections == [FleetSection(id: work.id, name: "Projects")], "No “Work” is left over")
        #expect(renamed.agent(hostID: Self.studio, profileID: "rio")?.placement
                == AgentListPlacement(sectionID: work.id, sectionName: "Projects"))

        let (deleted, deleting, phone) = await setUp()
        await deleting.delete(work.id)
        #expect(phone.placements["mina"]?.sectionID == nil)
        #expect(deleted.agent(hostID: Self.studio, profileID: "rio")?.placement?.sectionID == nil)
        #expect(deleted.sections.isEmpty, "The studio's own ID for it doesn't bring it back")
    }

    /// Another device filed a bot on another computer into the section, and this phone's copy of
    /// that computer hasn't read it yet. Once Rename or Delete has changed the members it knew, the
    /// other computers are read again and that bot takes the change too: left as it was, it brought
    /// the deleted section back at the next read.
    @Test func aSectionChangeReachesBotsTheCopiesMissed() async throws {
        let work = self.work
        /// Mina on this computer in `work`; Rio on the studio filed in it only after the copy was read.
        func setUp() async -> (FleetStore, Reader, SimpleBotsSectionEditor) {
            let reader = Reader()
            reader.snapshots[Self.studio] = FleetSnapshot(agents: [
                FleetAgent(hostID: Self.studio, profileID: "rio", name: "Rio", role: "", isPinned: false,
                           isDefault: false),
            ], refreshedAt: Date())
            let fleet = FleetStore(reader: reader, directory: folder(), saveDelay: .zero)
            fleet.refresh()
            await fleet.waitForReads()
            fleet.sections = [work]
            reader.snapshots[Self.studio]?.agents[0].placement = AgentListPlacement(sectionID: work.id,
                                                                                   sectionName: work.name)
            let phone = Phone()
            phone.placements["mina"] = AgentListPlacement(sectionID: work.id, sectionName: work.name)
            return (fleet, reader, editor(fleet, phone, bots: ["mina"], groups: []))
        }

        let (renamed, studio, renaming) = await setUp()
        await renaming.rename(work.id, to: "Projects")
        await renamed.waitForSectionCatchUp(work.id)
        #expect(studio.snapshots[Self.studio]?.agents.first?.placement
                == AgentListPlacement(sectionID: work.id, sectionName: "Projects"), "Rio takes the new name")

        let (deleted, reader, deleting) = await setUp()
        await deleting.delete(work.id)
        await deleted.waitForSectionCatchUp(work.id)
        #expect(reader.snapshots[Self.studio]?.agents.first?.placement?.sectionID == nil, "Rio leaves it")
        deleted.refresh(force: true)
        await deleted.waitForReads()
        #expect(deleted.sections.isEmpty, "So the section doesn't come back at the next read")
    }

    // MARK: Group chats

    /// A pinned group chat shows on top with the pinned bots, and counts toward the six; a hidden one
    /// goes off the home. Both stay after a relaunch.
    @Test func groupChatsPinHideAndKeepThoseChoices() throws {
        let directory = folder()
        let fleet = FleetStore(reader: Reader(), directory: directory, saveDelay: .zero)
        let crew = group("crew", members: [bot("mina")]), team = group("team"), quiet = group("quiet")
        fleet.setPinned(groupKey: crew.key!, true)
        fleet.setHidden(groupKey: quiet.key!, true)

        let relaunched = FleetStore(reader: Reader(), directory: directory, saveDelay: .zero)
        #expect(relaunched.pinnedGroupIDs == [crew.key!])
        #expect(relaunched.hiddenGroupIDs == [quiet.key!])

        let bots = ["default", "a", "b"].map { bot($0) }
        let shown = SimpleBotsHomeProjection.home(bots: bots, primaryID: "default", pinnedIDs: ["a"], latest: [:],
                                                  groups: [crew, team, quiet], topOrder: [crew.itemID],
                                                  sectioning: SimpleBotsSectioning(fleet: relaunched))
        #expect(shown.top.map(\.id) == [crew.itemID, "default", "a"], "A group chat drags on top like a bot")
        #expect(shown.pinnedGroups.map(\.id) == [crew.id])
        #expect(!shown.rows.contains { $0.id == crew.itemID || $0.id == quiet.itemID })
        #expect(shown.rows.contains { $0.id == team.itemID })
        #expect(SimpleBotsHomeProjection.canPin(team, home: shown))
        #expect(SimpleBotsHomeProjection.canPin("b", bots: bots, primaryID: "default", pinnedIDs: ["a"],
                                                pinnedGroups: shown.pinnedGroups.count))

        // Five pins beside the primary bot fill the top: no room for another, bot or group chat.
        let full = ["default", "a", "b", "c", "d"].map { bot($0) }
        let crowded = SimpleBotsHomeProjection.home(bots: full, primaryID: "default", pinnedIDs: ["a", "b", "c", "d"],
                                                    latest: [:], groups: [crew, team],
                                                    sectioning: SimpleBotsSectioning(fleet: relaunched))
        #expect(crowded.pinCount == 5)
        #expect(!SimpleBotsHomeProjection.canPin(team, home: crowded))
        #expect(!SimpleBotsHomeProjection.canPin("e", bots: full + [bot("e")], primaryID: "default",
                                                 pinnedIDs: ["a", "b", "c", "d"], pinnedGroups: 1))

        relaunched.setPinned(groupKey: crew.key!, false)
        relaunched.setHidden(groupKey: quiet.key!, false)
        #expect(relaunched.pinnedGroupIDs.isEmpty && relaunched.hiddenGroupIDs.isEmpty)
    }

    /// A group chat just made has no messages, so the catalog doesn't list it yet: Hermes' rooms do,
    /// and it shows at once, named as its catalog row will be.
    @Test func aGroupChatWithNoMessagesYetShowsOnTheHome() {
        let members = ["mina", "otto"].map { id in
            HermesBotModeRoomMember(memberID: "member-\(id)", profile: id, handle: id,
                                    target: ["kind": .string("local"), "profile": .string(id)])
        }
        func room(_ id: String) -> HermesBotModeRoomSummary {
            HermesBotModeRoomSummary(room: HermesBotModeRoomState(
                roomID: id, name: id.capitalized, members: members, authorityGatewayID: "gateway", authorityEpoch: 1,
                revision: 1, createdAt: 50, updatedAt: 60, latestSequence: 0, disbandedAt: nil, driverStatus: nil),
                capabilities: nil)
        }
        let talked = SessionSummary(id: "hermes-room:crew", kind: .botMode, agentIDs: ["mina", "otto"], title: "Crew",
                                    preview: "Hi", updatedAt: Date(timeIntervalSince1970: 90), hostedRoomID: "crew")
        let bots = [bot("mina"), bot("otto")]

        let groups = SimpleBotsHomeProjection.groups([talked], rooms: [room("crew"), room("fresh")],
                                                     hostID: Self.home, bots: bots)

        #expect(groups.map(\.id) == ["hermes-room:crew", "hermes-room:fresh"], "Each once, the catalog's first")
        #expect(groups[1].summary == nil && groups[1].isOnGatewayInUse)
        #expect(groups[1].members.map(\.profileID) == ["mina", "otto"])
        #expect(groups[1].key == FleetID.make(Self.home, "group/fresh"))
    }

    /// A section's page rearranges its members within the home's one order.
    @Test func aSectionsPageRearrangesItsMembersInPlace() {
        #expect(SimpleBotsHomeProjection.placing(["bot:b", "bot:a"], in: ["bot:x", "bot:a", "bot:y", "bot:b"])
                == ["bot:x", "bot:b", "bot:y", "bot:a"])
        #expect(SimpleBotsHomeProjection.placing(["bot:new", "bot:a"], in: ["bot:a", "bot:x"])
                == ["bot:new", "bot:a", "bot:x"], "One not placed yet leads, as on the home")
    }

    // MARK: Menus

    /// + has New Bot, New Group Chat and New Section, in that order, each only where it can work.
    @Test func plusOffersOnlyWhatCanWork() {
        #expect(SimpleBotsNewItem.available(canCreateBots: true, canCreateGroups: true, hasSections: true)
                == [.bot, .groupChat, .section])
        #expect(SimpleBotsNewItem.available(canCreateBots: true, canCreateGroups: false, hasSections: true)
                == [.bot, .section], "A computer that can't make group chats leaves it out")
        #expect(SimpleBotsNewItem.available(canCreateBots: false, canCreateGroups: false, hasSections: true) == [.section])
        #expect(SimpleBotsNewItem.available(canCreateBots: false, canCreateGroups: false, hasSections: false).isEmpty)
    }

    @Test func menusListTheirActionsInOrder() {
        #expect(SimpleBotsMenuAction.bot(isPrimary: false, isPinned: false, canPin: true, canFile: true, isUnread: false)
                == [.newChat, .pin, .rearrange, .moveToSection, .markUnread, .botProfile, .hide])
        #expect(SimpleBotsMenuAction.bot(isPrimary: true, isPinned: true, canPin: true, canFile: true, isUnread: true)
                == [.newChat, .rearrange, .moveToSection, .markRead, .botProfile], "The primary bot has no Pin or Hide")
        #expect(SimpleBotsMenuAction.bot(isPrimary: false, isPinned: true, canPin: false, canFile: false, isUnread: false)
                == [.newChat, .unpin, .rearrange, .markUnread, .botProfile, .hide])

        #expect(SimpleBotsMenuAction.group(isPinned: false, canPin: true, canFile: true, isUnread: false,
                                           hasSettings: true, canHide: true, canDelete: true)
                == [.pin, .rearrange, .moveToSection, .markUnread, .groupSettings, .hide, .deleteGroupChat])
        #expect(SimpleBotsMenuAction.group(isPinned: true, canPin: false, canFile: true, isUnread: true,
                                           hasSettings: false, canHide: true, canDelete: false)
                == [.unpin, .rearrange, .moveToSection, .markRead, .hide],
                "A computer that can't delete group chats leaves Delete out")
        #expect(SimpleBotsMenuAction.group(isPinned: false, canPin: false, canFile: false, isUnread: false,
                                           hasSettings: false, canHide: false, canDelete: false)
                == [.rearrange, .markUnread])
    }
}
