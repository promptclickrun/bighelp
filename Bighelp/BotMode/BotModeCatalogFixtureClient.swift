#if DEBUG
import Foundation

@MainActor
class BotModeCatalogFixtureClient: HermesBotModeCatalogClient {
    /// Demo group chats can be created (and then sit quiet, with no replies).
    static let createsGroupsArgument = "-preview-group-create"

    private var states: [HermesBotModeRoomState]
    private let showsStoreScreenshots: Bool
    private let createsGroups: Bool

    init(previewsExistingGroup: Bool = false, showsStoreScreenshots: Bool = false, createsGroups: Bool = false) {
        self.showsStoreScreenshots = showsStoreScreenshots
        self.createsGroups = createsGroups
        states = showsStoreScreenshots ? [AppStoreScreenshotFixture.groupRoom] : previewsExistingGroup ? [
            Self.room("demo-agent-group", name: "Household team", profiles: ["finance", "home"])
        ] : [
            Self.room("studio-pair", name: "Studio pair", profiles: ["studio", "build"]),
            Self.room("research-circle", name: "Research circle", profiles: ["studio", "field", "missing-profile"]),
        ]
    }

    func groupsCapabilities() async throws -> HermesBotModeCapabilities {
        if showsStoreScreenshots || createsGroups {
            return .init(
                protocolVersion: 2, driver: true, persistentProcess: true,
                authorityGatewayID: "fixture-gateway", roomLink: [:],
                features: HermesBotModeCapabilities.requiredFeatures,
                methods: HermesBotModeCapabilities.requiredOperations + ["groups.list", "groups.rename", "groups.disband"],
                maxLogLimit: 500
            )
        }
        return .init(
            protocolVersion: 2, driver: showsStoreScreenshots, persistentProcess: false,
            authorityGatewayID: "fixture-gateway", roomLink: [:], features: [],
            methods: ["groups.capabilities", "groups.list", "groups.state", "groups.log", "groups.rename", "groups.disband"],
            maxLogLimit: 500
        )
    }

    func groupsList(offset: Int, limit: Int) async throws -> HermesBotModeRoomListPage {
        guard offset >= 0, (1...500).contains(limit) else { throw WorkspaceClientError.invalidRequest }
        let rooms = Array(states.dropFirst(offset).prefix(limit))
        return .init(rooms: rooms, nextOffset: offset + rooms.count < states.count ? offset + rooms.count : nil)
    }

    func groupsState(roomID: String, includeDisbanded: Bool) async throws -> HermesBotModeRoomState {
        guard let state = states.first(where: { $0.roomID == roomID }) else {
            throw BotModeRoomError.roomNotFound
        }
        return state
    }

    func groupsLog(roomID: String, sinceSequence: Int, limit: Int, includeDisbanded: Bool) async throws -> HermesBotModeLogPage {
        _ = try await groupsState(roomID: roomID, includeDisbanded: includeDisbanded)
        if showsStoreScreenshots {
            let events = AppStoreScreenshotFixture.groupEvents
            let page = Array(events.filter { $0.sequence > sinceSequence }.prefix(limit))
            return .init(events: page, cursor: page.last?.sequence ?? sinceSequence, latestSequence: events.count,
                         hasMore: (page.last?.sequence ?? events.count) < events.count,
                         authority: .init(gatewayID: "fixture-gateway", epoch: 1))
        }
        if createsGroups, limit > 0 {
            return .init(events: [], cursor: sinceSequence, latestSequence: sinceSequence, hasMore: false,
                         authority: .init(gatewayID: "fixture-gateway", epoch: 1))
        }
        guard sinceSequence == 0, limit > 0 else { throw WorkspaceClientError.invalidRequest }
        return .init(events: [], cursor: 0, latestSequence: 0, hasMore: false,
                     authority: .init(gatewayID: "fixture-gateway", epoch: 1))
    }

    func groupsCreate(roomID: String, name: String, members: [HermesBotModeRoomMember]) async throws -> HermesBotModeRoomState {
        guard createsGroups else { throw BotModeRoomError.executionUnavailable }
        guard !states.contains(where: { $0.roomID == roomID }) else { throw WorkspaceClientError.invalidRequest }
        let now = Date().timeIntervalSince1970
        let state = HermesBotModeRoomState(
            roomID: roomID, name: name, members: members,
            authorityGatewayID: "fixture-gateway", authorityEpoch: 1, revision: 1,
            createdAt: now, updatedAt: now, latestSequence: 0, disbandedAt: nil, driverStatus: nil
        )
        states.insert(state, at: 0)
        return state
    }
    func groupsRename(roomID: String, eventID: String, name: String) async throws -> HermesBotModeRoomState {
        let state = try await groupsState(roomID: roomID, includeDisbanded: false)
        let renamed = HermesBotModeRoomState(
            roomID: state.roomID, name: name, members: state.members,
            authorityGatewayID: state.authorityGatewayID, authorityEpoch: state.authorityEpoch,
            revision: state.revision + 1, createdAt: state.createdAt, updatedAt: state.updatedAt + 1,
            latestSequence: state.latestSequence, disbandedAt: nil, driverStatus: nil
        )
        states = states.map { $0.roomID == roomID ? renamed : $0 }
        return renamed
    }
    func groupsDisband(roomID: String) async throws {
        _ = try await groupsState(roomID: roomID, includeDisbanded: false)
        states.removeAll { $0.roomID == roomID }
    }
    func groupsSend(roomID: String, eventID: String, payload: HermesBotModeUserPayload) async throws -> HermesBotModeSendResult {
        throw BotModeRoomError.executionUnavailable
    }
    func groupsStop(roomID: String, cancelID: String) async throws {
        throw BotModeRoomError.executionUnavailable
    }
    func groupsRetry(roomID: String, taskID: String) async throws -> HermesBotModeRetryResult {
        throw BotModeRoomError.executionUnavailable
    }

    private static func room(_ id: String, name: String, profiles: [String]) -> HermesBotModeRoomState {
        .init(
            roomID: id, name: name,
            members: profiles.map {
                .init(memberID: "member-\($0)", profile: $0, handle: $0, displayName: $0.capitalized,
                      target: ["kind": .string("local"), "profile": .string($0)])
            },
            authorityGatewayID: "fixture-gateway", authorityEpoch: 1, revision: 1,
            createdAt: 1_788_000_000, updatedAt: 1_788_000_001, latestSequence: 0,
            disbandedAt: nil, driverStatus: nil
        )
    }
}
#endif
