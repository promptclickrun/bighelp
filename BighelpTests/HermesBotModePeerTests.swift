import Foundation
import Testing
@testable import Bighelp

/// Group chats with agents on other computers (Hermes RoomLink).
@MainActor
struct HermesBotModePeerTests {
    static let digest = String(repeating: "ab", count: 32)

    static func profile(_ id: String, _ name: String) -> AgentProfile {
        AgentProfile(id: id, name: name, role: "", summary: "", instructions: "", avatarFileName: nil, isDefault: false)
    }

    static func catalog(installation: String = "install-studio", digest: String = Self.digest,
                        endpoint: BighelpJSONValue = .object([
                            "available": .boolean(true), "url": .string("https://studio.example.com"),
                            "transport_security": .string("tls"),
                        ])) -> [String: BighelpJSONValue] {
        ["installation_id": .string(installation), "catalog_digest": .string(digest),
         "protocol_versions": .array([.integer(1)]), "link_modes": .array([.string("direct")]),
         "execution_policy": .object(["target_profile": .string("research")]), "endpoint": endpoint]
    }

    @Test func aComputerWithoutAReachableAddressCannotJoin() throws {
        let link = try HermesBotModeRoomLink.parse(roomLink: ["enabled": .boolean(true), "catalog": .object(Self.catalog())],
                                                   profile: "research")
        #expect(link.endpointURL == "https://studio.example.com")
        #expect(throws: HermesBotModeRoomLink.Problem.noAddress("not_configured")) {
            try HermesBotModeRoomLink.parse(catalog: Self.catalog(endpoint: .object([
                "available": .boolean(false), "reason": .string("not_configured"),
            ])), profile: "research")
        }
        #expect(throws: HermesBotModeRoomLink.Problem.unavailable("durable_run_storage_required")) {
            try HermesBotModeRoomLink.parse(roomLink: ["enabled": .boolean(false),
                                                       "reason": .string("durable_run_storage_required")],
                                            profile: "research")
        }
        // Hermes refuses plain http beyond this machine, and so does the app.
        #expect(!HermesBotModeRoomLink.isLinkAddress("http://studio.example.com"))
        #expect(HermesBotModeRoomLink.isLinkAddress("http://127.0.0.1:8642"))
        #expect(throws: BighelpLinkWorkspaceClientError.invalidResponse) {
            try HermesBotModeRoomLink.parse(catalog: Self.catalog(digest: "short"), profile: "research")
        }
    }

    @Test func peerMembersAreDeviceQualifiedAndUniqueBesideLocalOnes() throws {
        let link = try HermesBotModeRoomLink.parse(catalog: Self.catalog(), profile: "research")
        let local = HermesBotModeRoomMember(memberID: "research", profile: "research", handle: "rio",
                                            target: ["kind": .string("local"), "profile": .string("research")])
        let peers = HermesBotModePeerMembers.members(for: [
            (HermesBotModePeerCandidate(hostID: "host-a", hostName: "Studio Mac", profileID: "research", name: "Rio"), link),
            (HermesBotModePeerCandidate(hostID: "host-b", hostName: "Studio Mac", profileID: "research", name: "Rio"), link),
        ], taken: [local])
        #expect(peers.map(\.member.memberID) == ["research-studio-mac", "research-studio-mac-2"])
        #expect(peers.map(\.member.handle) == ["rio-studio-mac", "rio-studio-mac-2"])
        #expect(peers.allSatisfy { HermesBotModeWireCodec.member($0.member) })
        #expect(peers.first?.member.target["peer_id"] == .string("studio-mac"))
        #expect(peers.first?.member.target["capability_digest"] == .string(Self.digest))
    }

    @Test func aPeerNeverBorrowsALocalProfileAndItsRoomCanRun() throws {
        let peer = HermesBotModeRoomMember(
            memberID: "research-studio-mac", profile: "research", handle: "rio-studio-mac", displayName: "Rio",
            target: ["kind": .string("peer"), "peer_id": .string("studio-mac"), "installation_id": .string("install-studio"),
                     "profile": .string("research"), "capability_digest": .string(Self.digest)]
        )
        let localProfile = Self.profile("research", "Local Research")
        let peers = PeerHostsFake()
        peers.computers = ["studio-mac": "Studio Mac"]
        let participant = HermesBotModeParticipant(member: peer, profiles: [localProfile], peers: peers)
        #expect(participant.profile == nil)
        #expect(participant.displayName == "Rio")
        #expect(participant.availability == .otherComputer)
        #expect(participant.computerName == "Studio Mac")
        #expect(participant.peerImageURL == nil)
        // Its computer's own list gives its current name and picture.
        let picture = URL(fileURLWithPath: "/tmp/fleet/avatars/rio.png")
        peers.agents["studio-mac/research"] = HermesBotModePeerAgent(name: "Rio Tanaka", imageURL: picture)
        let current = HermesBotModeParticipant(member: peer, profiles: [localProfile], peers: peers)
        #expect(current.displayName == "Rio Tanaka")
        #expect(current.peerImageURL == picture)
        let local = HermesBotModeRoomMember(memberID: "default", profile: "default", handle: "juno",
                                            target: ["kind": .string("local"), "profile": .string("default")])
        let state = HermesBotModeRoomState(
            roomID: "room", name: "Mixed", members: [local, peer], authorityGatewayID: "gateway",
            authorityEpoch: 1, revision: 1, createdAt: 1, updatedAt: 1, latestSequence: 0,
            disbandedAt: nil, driverStatus: nil
        )
        #expect(HermesBotModeRoomSummary(room: state, capabilities: .fixture()).canExecute)
    }

    @Test func aPeersMessagesKeepItsOwnNameBesideALocalAgentWithTheSameProfileID() throws {
        // Found on two real hosts: both agents were the "default" profile, and
        // the remote one's reply showed the local agent's name.
        let local = HermesBotModeRoomMember(memberID: "default", profile: "default", handle: "lab-agent",
                                            displayName: "Lab agent",
                                            target: ["kind": .string("local"), "profile": .string("default")])
        let peer = HermesBotModeRoomMember(
            memberID: "default-desk", profile: "default", handle: "desk-agent-desk", displayName: "Desk agent",
            target: ["kind": .string("peer"), "peer_id": .string("desk"), "installation_id": .string("install-desk"),
                     "profile": .string("default"), "capability_digest": .string(Self.digest)]
        )
        let state = HermesBotModeRoomState(
            roomID: "room-names", name: "Names", members: [local, peer], authorityGatewayID: "gateway",
            authorityEpoch: 1, revision: 1, createdAt: 1, updatedAt: 1, latestSequence: 0,
            disbandedAt: nil, driverStatus: nil
        )
        var room = try BotModeRoom(
            id: state.roomID,
            members: [local, peer].map {
                BotModeMember(profileID: $0.profile, handle: $0.handle, sessionID: "", nativeMemberID: $0.memberID)
            },
            visibleEvents: [], nativeRoomID: state.roomID, nativeState: state
        )
        for (index, member) in [local, peer].enumerated() {
            let event = HermesBotModeEvent(
                roomID: room.id, sequence: index + 1, eventID: "reply-\(member.memberID)", kind: "message.member",
                actor: ["kind": .string("member"), "id": .string(member.memberID)], authorityEpoch: 1,
                payload: ["text": .string("Hello"), "thread_id": .string("thread"), "member_id": .string(member.memberID)],
                createdAt: 1
            )
            room.appendNativeShared(try #require(event.botModeEvent(sourceOrder: index)))
        }
        var lab = Self.profile("default", "Lab agent")
        lab.avatarFileName = "lab.png"
        let directory = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: [lab]),
                                            defaults: isolatedDefaults(), profiles: [lab])
        let store = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], executionEnabled: false)
        let model = ChatModel(
            conversationID: room.id, client: ConversationFixtureClient(),
            userIdentity: .init(name: "Me", avatarFileName: nil),
            initialItems: [], botModeRoomStore: store, agentDirectory: directory, botModeRoomID: room.id
        )
        #expect(model.botModeTimelineItems.map(\.sender.snapshot.name) == ["Lab agent", "Desk agent"])
        #expect(model.botModeTimelineItems.map(\.sender.snapshot.avatarFileName) == ["lab.png", nil])
        // With Desk's own picture from its computer, its replies show that picture.
        let peers = PeerHostsFake()
        let deskPicture = URL(fileURLWithPath: "/tmp/fleet/avatars/desk.png")
        peers.agents["desk/default"] = HermesBotModePeerAgent(name: "Desk agent", imageURL: deskPicture)
        store.peerHosts = peers
        #expect(model.botModeTimelineItems.map(\.sender.snapshot.imageURL) == [nil, deskPicture])
        let resolver = TimelineSenderResolver(agents: directory)
        #expect(model.botModeTimelineItems.last.map { resolver.display(for: $0.sender).imageURL } == deskPicture)
    }

    @Test func clientCarriesTheGrantFromTheAgentsComputerToTheHome() async throws {
        let owner = WorkspaceOwner(authority: try .fixture(id: "peer-owner"),
                                   authenticationGeneration: UUID(), connectionGeneration: UUID())
        let workspace = PeerWorkspace(owner: owner)
        workspace.respond[.groupsPeerInvite] = [
            "grant": .string("signed-grant"), "target_profile": .string("research"),
            "catalog": .object(Self.catalog()), "endpoint": Self.catalog()["endpoint"]!,
        ]
        workspace.respond[.groupsPeerRegister] = [
            "registered": .boolean(true), "mode": .string("direct"), "transport_security": .string("tls"),
            "target_install_id": .string("install-studio"), "target_profile": .string("research"),
        ]
        let client = HermesHostedRoomClient(workspace: workspace, owner: owner)
        let invite = try await client.groupsPeerInvite(
            profile: "research", roomID: "room", homeInstallID: "gateway", authorityGatewayID: "gateway",
            authorityEpoch: 1, memberID: "research-studio-mac"
        )
        #expect(!invite.description.contains("signed-grant"))
        try await client.groupsPeerRegister(roomID: "room", memberID: "research-studio-mac", invite: invite)
        let register = try #require(workspace.sent.last)
        #expect(register.0 == .groupsPeerRegister)
        #expect(register.1["grant"] == .string("signed-grant"))
        #expect(register.1["target_url"] == .string("https://studio.example.com"))
        #expect(register.1["catalog"] == .object(Self.catalog()), "Hermes checks the catalog it sent, unchanged")
        #expect(workspace.sent.first?.1["home_install_id"] == .string("gateway"))
        #expect(try DirectHermesWorkspaceClient.route(.groupsPeerRegister, payload: register.1)
            == .rpc("groups.peer.register", register.1))
    }

    @Test func creatingAGroupLinksEachAgentOnAnotherComputer() async throws {
        let home = PeerHomeClient()
        let hosts = PeerHostsFake()
        let store = BotModeRoomStore(client: BotModeFixtureClient(), nativeClient: home)
        store.peerHosts = hosts
        let room = try await store.createNativeRoom(
            roomID: "room-mixed", name: "Mixed", profiles: [Self.profile("default", "Juno")],
            peers: [HermesBotModePeerCandidate(hostID: "host-studio", hostName: "Studio Mac",
                                               profileID: "research", name: "Rio")]
        )
        #expect(home.created.map(\.target) == [
            ["kind": .string("local"), "profile": .string("default")],
            ["kind": .string("peer"), "peer_id": .string("studio-mac"), "installation_id": .string("install-studio"),
             "profile": .string("research"), "capability_digest": .string(Self.digest)],
        ])
        #expect(hosts.invites.map(\.memberID) == ["research-studio-mac"])
        #expect(hosts.invites.first?.homeInstallID == "gateway")
        #expect(home.registered == ["research-studio-mac"])
        #expect(room.nativePendingPeerLinks.isEmpty)
        #expect(store.nativePeerLinkProblems["room-mixed"] == nil)
    }

    @Test func aLinkThatFailsWaitsInTheRoomAndRetriesWhenItOpens() async throws {
        let home = PeerHomeClient()
        home.registerFailures = 1
        let hosts = PeerHostsFake()
        let store = BotModeRoomStore(client: BotModeFixtureClient(), nativeClient: home)
        store.peerHosts = hosts
        let room = try await store.createNativeRoom(
            roomID: "room-later", name: "Later", profiles: [Self.profile("default", "Juno")],
            peers: [HermesBotModePeerCandidate(hostID: "host-studio", hostName: "Studio Mac",
                                               profileID: "research", name: "Rio")]
        )
        #expect(room.nativePendingPeerLinks.map(\.memberID) == ["research-studio-mac"])
        #expect(store.nativePeerLinkProblems["room-later"]?.contains("Rio on Studio Mac isn't linked yet") == true)
        let reopened = try await store.openNativeRoom(roomID: "room-later")
        #expect(reopened.nativePendingPeerLinks.isEmpty)
        #expect(home.registered == ["research-studio-mac"])
        #expect(store.nativePeerLinkProblems["room-later"] == nil)
    }

    @Test func aComputerThatCannotJoinStopsTheGroupBeforeHermesMakesIt() async throws {
        let home = PeerHomeClient()
        let hosts = PeerHostsFake()
        hosts.problem = .noAddress("not_configured")
        let store = BotModeRoomStore(client: BotModeFixtureClient(), nativeClient: home)
        store.peerHosts = hosts
        do {
            _ = try await store.createNativeRoom(
                roomID: "room-none", name: "None", profiles: [Self.profile("default", "Juno")],
                peers: [HermesBotModePeerCandidate(hostID: "host-studio", hostName: "Studio Mac",
                                                   profileID: "research", name: "Rio")]
            )
            Issue.record("Creating should fail")
        } catch let error as BotModePeerLinkError {
            #expect(error.message.hasPrefix("Studio Mac has no address other computers can reach"))
        }
        #expect(home.created.isEmpty)
    }
}

@MainActor
private final class PeerWorkspace: WorkspaceOperationPerforming {
    let owner: WorkspaceOwner?
    let capabilities: WorkspaceCapabilities
    var respond: [WorkspaceOperation: [String: BighelpJSONValue]] = [:]
    private(set) var sent: [(WorkspaceOperation, [String: BighelpJSONValue])] = []

    init(owner: WorkspaceOwner) {
        self.owner = owner
        capabilities = .init(owner: owner)
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                 owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        sent.append((operation, payload))
        guard let response = respond[operation] else { throw WorkspaceClientError.invalidRequest }
        return response
    }
}

@MainActor
private final class PeerHostsFake: HermesBotModePeerHosts {
    var problem: HermesBotModeRoomLink.Problem?
    var computers: [String: String] = [:]
    /// By "peerID/profile".
    var agents: [String: HermesBotModePeerAgent] = [:]
    private(set) var invites: [(memberID: String, homeInstallID: String)] = []

    func roomLink(hostID: String, profile: String) async throws -> HermesBotModeRoomLink {
        if let problem { throw problem }
        return try HermesBotModeRoomLink.parse(catalog: HermesBotModePeerTests.catalog(), profile: profile)
    }

    func invite(hostID: String, profile: String, roomID: String, homeInstallID: String,
                authorityGatewayID: String, authorityEpoch: Int, memberID: String) async throws -> HermesBotModePeerInvite {
        invites.append((memberID, homeInstallID))
        return HermesBotModePeerInvite(grant: "grant-\(memberID)",
                                       link: try await roomLink(hostID: hostID, profile: profile))
    }

    func hostName(peerID: String) -> String? { computers[peerID] }
    func agent(peerID: String, profile: String) -> HermesBotModePeerAgent? { agents["\(peerID)/\(profile)"] }
    func refreshAgents() {}
    func connect(peerID: String) async throws -> any HermesBotModePeerConnection {
        throw WorkspaceClientError.unavailable(.unsupportedHost)
    }
}

/// The home computer: creates rooms with exactly the members it was given,
/// as Hermes stores them, and registers grants.
@MainActor
private final class PeerHomeClient: HermesBotModeClient, HermesBotModePeerRegistering {
    private(set) var created: [HermesBotModeRoomMember] = []
    private(set) var registered: [String] = []
    var registerFailures = 0
    private var state: HermesBotModeRoomState?

    func groupsCapabilities() async throws -> HermesBotModeCapabilities { .fixture() }

    func groupsCreate(roomID: String, name: String, members: [HermesBotModeRoomMember]) async throws -> HermesBotModeRoomState {
        created = members
        let state = HermesBotModeRoomState(
            roomID: roomID, name: name, members: members, authorityGatewayID: "gateway", authorityEpoch: 1,
            revision: 1, createdAt: 1, updatedAt: 1, latestSequence: 0, disbandedAt: nil, driverStatus: nil
        )
        self.state = state
        return state
    }

    func groupsState(roomID: String, includeDisbanded: Bool) async throws -> HermesBotModeRoomState {
        guard let state, state.roomID == roomID else { throw BotModeRoomError.roomNotFound }
        return state
    }

    func groupsPeerRegister(roomID: String, memberID: String, invite: HermesBotModePeerInvite) async throws {
        if registerFailures > 0 {
            registerFailures -= 1
            throw WorkspaceClientError.transportUnavailable
        }
        registered.append(memberID)
    }

    func groupsLog(roomID: String, sinceSequence: Int, limit: Int, includeDisbanded: Bool) async throws -> HermesBotModeLogPage {
        .init(events: [], cursor: sinceSequence, latestSequence: sinceSequence, hasMore: false,
              authority: .init(gatewayID: "gateway", epoch: 1))
    }

    func groupsSend(roomID: String, eventID: String, payload: HermesBotModeUserPayload) async throws -> HermesBotModeSendResult {
        throw BotModeRoomError.executionUnavailable
    }

    func groupsStop(roomID: String, cancelID: String) async throws {}

    func groupsRetry(roomID: String, taskID: String) async throws -> HermesBotModeRetryResult {
        throw BotModeRoomError.executionUnavailable
    }
}
