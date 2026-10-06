import Foundation
import Testing
@testable import Bighelp

/// The all-hosts view lists every host's agents, chats and tasks. The selected
/// host's come from the app live; the others are read, at most once a minute,
/// and kept on the device so the list shows at once and survives a host that's
/// out of reach.
@MainActor
struct FleetStoreTests {
    private let home = UUID()
    private let studio = UUID()
    private let office = UUID()

    @MainActor
    final class Reader: FleetHostReading {
        var hosts: [FleetHost]
        var snapshots: [UUID: FleetSnapshot] = [:]
        var failures: [UUID: String] = [:]
        private(set) var reads: [UUID] = []
        private(set) var selected: [UUID] = []
        private(set) var keptConnected: [UUID] = []
        private(set) var pinChanges: [String] = []

        init(hosts: [FleetHost]) { self.hosts = hosts }

        func read(_ hostID: UUID, avatars: FleetAvatarFolder) async throws -> FleetSnapshot {
            reads.append(hostID)
            if let message = failures[hostID] { throw FleetReadError(message: message) }
            return snapshots[hostID] ?? FleetSnapshot(refreshedAt: Date())
        }

        func select(_ hostID: UUID) {
            selected.append(hostID)
            hosts = hosts.map { FleetHost(id: $0.id, name: $0.name, isSelected: $0.id == hostID) }
        }

        func canOpen(_ hostID: UUID) -> Bool { true }

        func keepConnected(_ hostID: UUID) async { keptConnected.append(hostID) }

        func setPinned(_ pinned: Bool, hostID: UUID, profileID: String) -> Bool {
            pinChanges.append((pinned ? "pin " : "unpin ") + profileID)
            return true
        }

        private(set) var placements: [String: AgentListPlacement] = [:]
        var placementFailure: (any Error)?

        func setPlacement(_ placement: AgentListPlacement, hostID: UUID, profileID: String) async throws {
            if let placementFailure { throw placementFailure }
            placements[profileID] = placement
        }
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "fleet-tests-\(UUID().uuidString)")
    }

    private func reader(_ count: Int = 2) -> Reader {
        Reader(hosts: [
            FleetHost(id: home, name: "Home", isSelected: true),
            FleetHost(id: studio, name: "Studio", isSelected: false),
            FleetHost(id: office, name: "Office", isSelected: false),
        ].prefix(count).map { $0 })
    }

    private func agent(_ host: UUID, _ id: String, _ name: String, pinned: Bool = false,
                       placement: AgentListPlacement? = nil) -> FleetAgent {
        FleetAgent(hostID: host, profileID: id, name: name, role: "", isPinned: pinned, isDefault: false,
                   placement: placement)
    }

    private func names(_ block: FleetSectionBlock) -> [String] {
        block.items.map { item in
            switch item {
            case .agent(let agent): agent.name
            case .group(let group): group.name
            }
        }
    }

    private func blocks(_ fleet: FleetStore) -> [FleetSectionBlock] {
        FleetSectioning.blocks(fleet.agents().map(FleetListItem.agent) + fleet.groups().map(FleetListItem.group),
                               sections: fleet.sections, groupSections: fleet.groupSectionIDs)
    }

    // MARK: Hidden agents and sections

    /// Hiding only changes the list, and it's saved on the agent's own host.
    @Test func hidingAnAgentSavesItOnItsHost() async throws {
        let reader = reader()
        reader.snapshots[studio] = FleetSnapshot(agents: [agent(studio, "rio", "Rio")], refreshedAt: Date())
        let fleet = FleetStore(reader: reader, directory: directory(), saveDelay: .zero)
        fleet.refresh()
        await fleet.waitForReads()
        let rio = try #require(fleet.agent(hostID: studio, profileID: "rio"))

        try await fleet.setHidden(rio, true)
        #expect(reader.placements["rio"]?.isHidden == true)
        #expect(fleet.agent(hostID: studio, profileID: "rio")?.isHidden == true)
        #expect(fleet.hiddenAgentCount == 1)

        // A read that started before the save doesn't bring it back.
        fleet.refresh(force: true)
        await fleet.waitForReads()
        #expect(fleet.agent(hostID: studio, profileID: "rio")?.isHidden == true)

        try await fleet.setHidden(try #require(fleet.agent(hostID: studio, profileID: "rio")), false)
        #expect(reader.placements["rio"]?.isHidden == false)
        #expect(fleet.hiddenAgentCount == 0)
    }

    /// A host that can't save puts the agent back and says to update Hermes.
    @Test func placementTheHostRefusesIsUndoneWithAPlainReason() async throws {
        let reader = reader()
        reader.snapshots[studio] = FleetSnapshot(agents: [agent(studio, "rio", "Rio")], refreshedAt: Date())
        reader.placementFailure = WorkspaceClientError.unavailable(.unsupportedHost)
        let fleet = FleetStore(reader: reader, directory: directory(), saveDelay: .zero)
        fleet.refresh()
        await fleet.waitForReads()
        let rio = try #require(fleet.agent(hostID: studio, profileID: "rio"))
        await #expect(throws: WorkspaceClientError.self) { try await fleet.setHidden(rio, true) }
        #expect(fleet.agent(hostID: studio, profileID: "rio")?.isHidden == false)
        #expect(fleet.placementError == "Update Hermes on Studio to keep sections and hidden agents there.")
    }

    /// Agents on both hosts file into one section; the selected host saves
    /// through its own agent list. Deleting the section never deletes them,
    /// and Undo files them back.
    @Test func deletingASectionOnlyUnfilesItsAgentsAndUndoPutsThemBack() async throws {
        let reader = reader()
        reader.snapshots[studio] = FleetSnapshot(agents: [agent(studio, "rio", "Rio")], refreshedAt: Date())
        let folder = directory()
        let fleet = FleetStore(reader: reader, directory: folder, saveDelay: .zero)
        var homeWrites: [String: AgentListPlacement] = [:]
        fleet.selectedHostPlacementWriter = { placement, profileID in homeWrites[profileID] = placement }
        fleet.recordLive(FleetSnapshot(agents: [agent(home, "ava", "Ava")], refreshedAt: Date()), hostID: home)
        fleet.refresh()
        await fleet.waitForReads()

        let work = try #require(fleet.createSection(named: "  Work  "))
        #expect(work.name == "Work")
        #expect(work.id.hasPrefix("sec-"))
        try await fleet.file(try #require(fleet.agent(hostID: home, profileID: "ava")), in: work.id)
        try await fleet.file(try #require(fleet.agent(hostID: studio, profileID: "rio")), in: work.id)
        #expect(homeWrites["ava"] == AgentListPlacement(sectionID: work.id, sectionName: "Work"))
        #expect(reader.placements["rio"] == AgentListPlacement(sectionID: work.id, sectionName: "Work"))
        #expect(blocks(fleet).map(names) == [["Ava", "Rio"].sorted(), []])

        let deletion = try #require(fleet.deleteSection(work.id))
        #expect(fleet.sections.isEmpty)
        #expect(blocks(fleet).map(names) == [["Ava", "Rio"].sorted()])
        for _ in 0..<100 where reader.placements["rio"]?.sectionID != nil { await Task.yield() }
        #expect(reader.placements["rio"]?.sectionID == nil)
        #expect(homeWrites["ava"]?.sectionID == nil)
        #expect(fleet.agents().count == 2)

        fleet.undoDeleteSection(deletion)
        for _ in 0..<100 where reader.placements["rio"]?.sectionID == nil { await Task.yield() }
        #expect(fleet.sections == [work])
        #expect(reader.placements["rio"]?.sectionID == work.id)
        #expect(blocks(fleet).first.map(names) == ["Ava", "Rio"].sorted())

        // The section list (order, empty ones) stays on this device.
        let later = try #require(fleet.createSection(named: "Later"))
        fleet.moveSection(later.id, by: -1)
        let relaunched = FleetStore(reader: reader, directory: folder, saveDelay: .zero)
        #expect(relaunched.sections == [later, work])
    }

    /// Sections made on another device are rebuilt from the names their
    /// agents carry, and same-named sections on different hosts show as one.
    @Test func sectionsFromOtherDevicesAreRebuiltAndSameNamesGroupTogether() async throws {
        let reader = reader(3)
        reader.snapshots[studio] = FleetSnapshot(agents: [
            agent(studio, "rio", "Rio", placement: AgentListPlacement(sectionID: "sec-a", sectionName: "Work")),
        ], refreshedAt: Date())
        reader.snapshots[office] = FleetSnapshot(agents: [
            agent(office, "sam", "Sam", placement: AgentListPlacement(sectionID: "sec-b", sectionName: "work")),
            agent(office, "kim", "Kim", placement: AgentListPlacement(sectionID: "sec-c", sectionName: "Personal",
                                                                      isHidden: true)),
        ], refreshedAt: Date())
        let fleet = FleetStore(reader: reader, directory: directory(), saveDelay: .zero)
        fleet.refresh()
        await fleet.waitForReads()

        #expect(Set(fleet.sections.map(\.name)) == ["Personal", "Work"])
        #expect(fleet.sections.count == 2)
        let work = try #require(fleet.sections.first { FleetSection.nameKey($0.name) == "work" })
        let workBlock = try #require(blocks(fleet).first { $0.section?.id == work.id })
        #expect(Set(names(workBlock)) == ["Rio", "Sam"])
        #expect(fleet.hiddenAgentCount == 1)
    }

    /// Hermes Desktop names an agent's routines "[bot:<agent>] <routine>";
    /// people see the routine's own name.
    @Test func desktopRoutineTagIsNotShown() {
        #expect(ScheduledTask.routineName("[bot:research] Morning digest") == "Morning digest")
        #expect(ScheduledTask.routineName("[bot:Ops_2]   Weekly report") == "Weekly report")
        #expect(ScheduledTask.routineName("Morning digest") == "Morning digest")
        #expect(ScheduledTask.routineName("[bot:research] ") == "[bot:research] ")
        #expect(ScheduledTask.routineName("[bot:-bad] Odd") == "[bot:-bad] Odd")
    }

    /// A group chat's section is kept on this device, like Hermes Desktop.
    @Test func groupChatsFileIntoSectionsOnThisDevice() async throws {
        let reader = reader()
        let folder = directory()
        let fleet = FleetStore(reader: reader, directory: folder, saveDelay: .zero)
        let group = FleetGroup(hostID: home, roomID: "room-1", name: "Launch crew", memberNames: ["Ava", "Rio"],
                               updatedAt: Date(), isWorking: false, canRename: true, canDelete: true)
        fleet.recordLive(FleetSnapshot(agents: [agent(home, "ava", "Ava")], groups: [group], refreshedAt: Date()),
                         hostID: home)
        let team = try #require(fleet.createSection(named: "Team"))
        fleet.file(group, in: team.id)
        #expect(blocks(fleet).map(names) == [["Launch crew"], ["Ava"]])
        let relaunched = FleetStore(reader: reader, directory: folder, saveDelay: .zero)
        #expect(relaunched.groupSectionIDs[group.id] == team.id)
        _ = fleet.deleteSection(team.id)
        #expect(blocks(fleet).map(names) == [["Ava", "Launch crew"]])
    }

    private func chat(_ host: UUID, _ profile: String, _ id: String, minutesAgo: Double) -> FleetChat {
        FleetChat(hostID: host, profileID: profile, storedSessionID: id, title: id, preview: "",
                  updatedAt: Date().addingTimeInterval(-minutesAgo * 60), isActive: false)
    }

    @Test func agentsFromEveryHostAreListedByTheirLatestChat() async {
        let reader = reader()
        reader.snapshots[studio] = FleetSnapshot(
            agents: [agent(studio, "default", "Rio")],
            chats: [chat(studio, "default", "s1", minutesAgo: 5)], refreshedAt: Date())
        let fleet = FleetStore(reader: reader, directory: directory(), saveDelay: .zero)
        fleet.recordLive(FleetSnapshot(
            agents: [agent(home, "default", "Avery"), agent(home, "travel", "Mina")],
            chats: [chat(home, "default", "h1", minutesAgo: 30), chat(home, "travel", "h2", minutesAgo: 1)],
            refreshedAt: Date()), hostID: home)

        fleet.refresh()
        await fleet.waitForReads()

        // The same profile ID on two hosts is two agents.
        #expect(fleet.agents().map(\.name) == ["Mina", "Rio", "Avery"])
        #expect(fleet.agents(on: studio).map(\.name) == ["Rio"])
        #expect(fleet.chats().map(\.storedSessionID) == ["h2", "s1", "h1"])
        #expect(fleet.showsHostNames)
        #expect(reader.reads == [studio], "The selected host is live; it is never read")
    }

    /// All sessions' search bar matches a chat's title and its preview text, in any case, on every host.
    @Test func chatSearchMatchesTitleAndPreview() {
        let fleet = FleetStore(reader: reader(), directory: directory(), saveDelay: .zero)
        var trip = chat(home, "travel", "Trip to Lisbon", minutesAgo: 1)
        trip.preview = "Booked the train"
        var budget = chat(studio, "default", "Budget", minutesAgo: 2)
        budget.preview = "The lisbon hotel costs more"
        fleet.recordLive(FleetSnapshot(agents: [agent(home, "travel", "Mina")], chats: [trip], refreshedAt: Date()),
                         hostID: home)
        fleet.recordLive(FleetSnapshot(agents: [agent(studio, "default", "Rio")], chats: [budget],
                                       refreshedAt: Date()), hostID: studio)

        #expect(fleet.chats(matching: "lisbon").map(\.title) == ["Trip to Lisbon", "Budget"])
        #expect(fleet.chats(matching: "TRAIN").map(\.title) == ["Trip to Lisbon"])
        #expect(fleet.chats(on: studio, matching: "lisbon").map(\.title) == ["Budget"])
        #expect(fleet.chats(matching: "  ").count == 2, "An empty search shows every chat")
        #expect(fleet.chats(matching: "paris").isEmpty)
    }

    /// All sessions filters like one computer's Sessions: by agent (on its own computer)
    /// and by where the chats started.
    @Test func chatFiltersMatchAnAgentOnItsComputerAndWhereChatsStarted() {
        let fleet = FleetStore(reader: reader(), directory: directory(), saveDelay: .zero)
        var telegram = chat(home, "travel", "Hotel", minutesAgo: 1)
        telegram.origin = "telegram"
        var codex = chat(home, "default", "Menus", minutesAgo: 2)
        codex.origin = "codex-cli"
        var studioTravel = chat(studio, "travel", "Flights", minutesAgo: 3)
        studioTravel.origin = "telegram"
        fleet.recordLive(FleetSnapshot(agents: [agent(home, "travel", "Mina"), agent(home, "default", "Rio")],
                                       chats: [telegram, codex], refreshedAt: Date()), hostID: home)
        fleet.recordLive(FleetSnapshot(agents: [agent(studio, "travel", "Sage")], chats: [studioTravel],
                                       refreshedAt: Date()), hostID: studio)

        let mina = FleetChatsFilter(agentID: FleetID.make(home, "travel"))
        #expect(fleet.chats(matching: "", filter: mina).map(\.title) == ["Hotel"], "Same profile on another computer isn't Mina")
        #expect(fleet.chats(matching: "", filter: FleetChatsFilter(origin: "Telegram")).map(\.title) == ["Hotel", "Flights"])
        #expect(fleet.chats(on: studio, matching: "", filter: FleetChatsFilter(origin: "Telegram")).map(\.title) == ["Flights"])
        #expect(fleet.origins() == ["Codex", "Telegram"])
        #expect(fleet.chats(matching: "", filter: FleetChatsFilter()).count == 3)
    }

    /// Pinned agents from every host stay in the order the person dragged them
    /// into, after a relaunch too; a newly pinned agent joins at the end.
    @Test func pinnedAgentsKeepTheArrangedOrderAcrossHosts() async {
        let folder = directory()
        let reader = reader()
        reader.snapshots[studio] = FleetSnapshot(
            agents: [agent(studio, "default", "Rio", pinned: true)],
            chats: [chat(studio, "default", "s1", minutesAgo: 1)], refreshedAt: Date())
        let live = FleetSnapshot(
            agents: [agent(home, "default", "Avery", pinned: true), agent(home, "travel", "Mina", pinned: true)],
            chats: [chat(home, "default", "h1", minutesAgo: 30), chat(home, "travel", "h2", minutesAgo: 5)],
            refreshedAt: Date())
        let fleet = FleetStore(reader: reader, directory: folder, saveDelay: .zero)
        fleet.recordLive(live, hostID: home)
        fleet.refresh()
        await fleet.waitForReads()
        #expect(fleet.pinnedAgents().map(\.name) == ["Rio", "Mina", "Avery"], "Unarranged: latest chat first")

        let avery = FleetID.make(home, "default"), rio = FleetID.make(studio, "default")
        fleet.reorderPinned([avery, rio])
        #expect(fleet.pinnedAgents().map(\.name) == ["Avery", "Rio", "Mina"])

        let reopened = FleetStore(reader: reader, directory: folder, saveDelay: .zero)
        reopened.recordLive(live, hostID: home)
        reopened.refresh()
        await reopened.waitForReads()
        #expect(reopened.pinnedAgents().map(\.name) == ["Avery", "Rio", "Mina"], "The order survives a relaunch")
    }

    /// Pinning or unpinning another host's agent here saves it for that host
    /// and shows at once; an unpinned agent leaves the arranged order too.
    @Test func pinningFromAllAgentsSavesForThatHost() async {
        let reader = reader()
        reader.snapshots[studio] = FleetSnapshot(
            agents: [agent(studio, "default", "Rio", pinned: true), agent(studio, "music", "Lena")],
            refreshedAt: Date())
        let fleet = FleetStore(reader: reader, directory: directory(), saveDelay: .zero)
        fleet.recordLive(FleetSnapshot(agents: [agent(home, "default", "Avery", pinned: true)], refreshedAt: Date()),
                         hostID: home)
        fleet.refresh()
        await fleet.waitForReads()
        let rio = FleetID.make(studio, "default")
        fleet.reorderPinned([rio, FleetID.make(home, "default")])

        fleet.setPinned(try! #require(fleet.agent(hostID: studio, profileID: "default")), false)
        #expect(fleet.pinnedAgents().map(\.name) == ["Avery"])
        #expect(!fleet.pinnedOrder.contains(rio))
        fleet.setPinned(try! #require(fleet.agent(hostID: studio, profileID: "music")), true)
        #expect(fleet.pinnedAgents().map(\.name) == ["Avery", "Lena"])
        #expect(reader.pinChanges == ["unpin default", "pin music"])

        // The selected host's own agent list saves its pins; the store only shows them.
        fleet.setPinned(try! #require(fleet.agent(hostID: home, profileID: "default")), false)
        #expect(fleet.pinnedAgents().map(\.name) == ["Lena"])
        #expect(reader.pinChanges.count == 2)
    }

    /// Another host's pins are saved where its Agents screen reads them, and an
    /// unpinned default agent stays unpinned (it's remembered as unpinned).
    @Test func anotherHostsPinsAreSavedWhereItsAgentsScreenReadsThem() throws {
        let suite = "bighelp.tests.fleet-pins.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AgentDirectoryStore.savePin(true, agentID: "music", in: defaults, hostBucket: "scope"))
        #expect(AgentDirectoryStore.savedPinnedAgentIDs(in: defaults, hostBucket: "scope") == ["music"])
        #expect(!AgentDirectoryStore.savePin(true, agentID: "music", in: defaults, hostBucket: "scope"), "Already pinned")
        #expect(AgentDirectoryStore.savePin(false, agentID: "music", in: defaults, hostBucket: "scope"))
        #expect(AgentDirectoryStore.savedPinnedAgentIDs(in: defaults, hostBucket: "scope") == [])
        #expect(AgentDirectoryStore.savePin(false, agentID: "default", in: defaults, hostBucket: "fresh"))
        #expect(AgentDirectoryStore.savedPinnedAgentIDs(in: defaults, hostBucket: "fresh") == [])
        #expect(AgentDirectoryStore.savedUnpinnedAgentIDs(in: defaults, hostBucket: "fresh") == ["default"])
    }

    @Test func aHostIsReadAtMostOnceAMinuteUnlessAsked() async {
        let reader = reader()
        let fleet = FleetStore(reader: reader, directory: directory(), saveDelay: .zero)
        fleet.refresh()
        await fleet.waitForReads()
        fleet.refresh()
        await fleet.waitForReads()
        #expect(reader.reads == [studio])
        fleet.refresh(force: true)
        await fleet.waitForReads()
        #expect(reader.reads == [studio, studio])
    }

    @Test func aHostReadRecentlyIsStillKeptConnectedForTheNextSwitch() async {
        let reader = reader()
        let fleet = FleetStore(reader: reader, directory: directory(), saveDelay: .zero)
        fleet.refresh()
        await fleet.waitForReads()
        #expect(reader.keptConnected.isEmpty, "A read connects it anyway")

        fleet.refresh()
        for _ in 0..<20 where reader.keptConnected.isEmpty { await Task.yield() }
        #expect(reader.reads == [studio])
        #expect(reader.keptConnected == [studio], "Not read again, but its connection is checked")
    }

    @Test func aHostOutOfReachKeepsWhatItHadLastTime() async {
        let folder = directory()
        let reader = reader(3)
        reader.snapshots[office] = FleetSnapshot(agents: [agent(office, "ops", "Kit")], refreshedAt: Date())
        let first = FleetStore(reader: reader, directory: folder, saveDelay: .zero)
        first.refresh()
        await first.waitForReads()
        await first.waitForSaves()

        reader.failures[office] = "Couldn't reach this host."
        let relaunched = FleetStore(reader: reader, directory: folder, saveDelay: .zero)
        #expect(relaunched.agents(on: office).map(\.name) == ["Kit"], "Shown at once from this device")
        relaunched.refresh(force: true)
        await relaunched.waitForReads()

        #expect(relaunched.statuses[office] == .unreachable("Couldn't reach this host."))
        #expect(relaunched.agents(on: office).map(\.name) == ["Kit"])
    }

    @Test func aRemovedHostIsForgotten() async {
        let folder = directory()
        let reader = reader()
        reader.snapshots[studio] = FleetSnapshot(agents: [agent(studio, "default", "Rio")], refreshedAt: Date())
        let fleet = FleetStore(reader: reader, directory: folder, saveDelay: .zero)
        fleet.refresh()
        await fleet.waitForReads()
        await fleet.waitForSaves()

        reader.hosts.removeAll { $0.id == studio }
        fleet.syncHosts()

        #expect(fleet.agents().isEmpty)
        #expect(!fleet.showsHostNames)
        #expect(FleetStore(reader: reader, directory: folder).snapshots[studio] == nil)
    }

    @Test func liveDataOnlyCountsForAKnownHost() {
        let fleet = FleetStore(reader: reader(), directory: directory(), saveDelay: .zero)
        fleet.recordLive(FleetSnapshot(agents: [agent(office, "x", "Ghost")], refreshedAt: Date()), hostID: office)
        #expect(fleet.agents().isEmpty)
    }

    @Test func tasksThatWillRunComeFirstSoonestFirst() {
        let fleet = FleetStore(reader: reader(), directory: directory(), saveDelay: .zero)
        let now = Date()
        func task(_ name: String, _ status: ScheduledTaskStatus, in hours: Double?) -> FleetTask {
            FleetTask(hostID: home, jobID: name, profileID: "default", name: name, schedule: "",
                      nextRun: hours.map { now.addingTimeInterval($0 * 3_600) }, status: status)
        }
        fleet.recordLive(FleetSnapshot(tasks: [task("paused", .paused, in: nil), task("later", .active, in: 5),
                                               task("soon", .active, in: 1)], refreshedAt: now), hostID: home)
        #expect(fleet.tasks().map(\.name) == ["soon", "later", "paused"])
    }

    @Test func choosingAHostSelectsIt() {
        let reader = reader()
        let fleet = FleetStore(reader: reader, directory: directory(), saveDelay: .zero)
        fleet.select(studio)
        #expect(reader.selected == [studio])
        #expect(fleet.selectedHostID == studio)
    }

    // MARK: Reading a host's session list

    @Test func sessionRowsBecomeChatsWithWhatTheyAreDoingNow() throws {
        let row: BighelpJSONValue = .object([
            "id": .string("abc"), "title": .string("Trip"), "preview": .string("Book the flight"),
            "started_at": .number(1_790_000_000), "last_active": .number(1_790_000_600),
            "source": .string("telegram"),
        ])
        let chat = try #require(RegistryFleetReader.chat(row, hostID: studio, profileID: "default",
                                                         live: ["abc": "streaming"]))
        #expect(chat.storedSessionID == "abc")
        #expect(chat.origin == "telegram", "Its channel tag, like one computer's Sessions")
        #expect(chat.title == "Trip")
        #expect(chat.updatedAt == Date(timeIntervalSince1970: 1_790_000_600))
        #expect(chat.isActive)
        let idle = RegistryFleetReader.chat(row, hostID: studio, profileID: "default", live: ["abc": "idle"])
        #expect(idle?.isActive == false)
        #expect(RegistryFleetReader.chat(.object(["title": .string("No ID")]), hostID: studio,
                                         profileID: "default", live: [:]) == nil)
    }
}
