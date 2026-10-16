import Foundation

struct HermesBotModeRoomListPage: Codable, Equatable, Sendable {
    let rooms: [HermesBotModeRoomState]
    let nextOffset: Int?

    private enum CodingKeys: String, CodingKey {
        case rooms
        case nextOffset = "next_offset"
    }
}

@MainActor
protocol HermesBotModeCatalogClient: HermesBotModeClient {
    func groupsList(offset: Int, limit: Int) async throws -> HermesBotModeRoomListPage
    func groupsRename(roomID: String, eventID: String, name: String) async throws -> HermesBotModeRoomState
    func groupsDisband(roomID: String) async throws
}

extension HermesBotModeCatalogClient {
    func groupsDisband(roomID: String) async throws { throw BotModeRoomError.executionUnavailable }
}

enum BotModeRoomCatalogState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case unavailable(String)
    case failed(String)
}

struct HermesBotModeRenameIntent: Codable, Equatable, Sendable {
    let eventID: String
    let name: String
}

struct HermesBotModeCreationIntent: Codable, Equatable, Sendable {
    let roomID: String
    let name: String
    let members: [HermesBotModeRoomMember]
    var wasDispatched: Bool
}

struct HermesBotModeRetryJournal: Codable, Equatable, Sendable {
    let taskIDs: [String]
    var awaitingReceipt: Set<String> = []
    var receipts: [String: HermesBotModeTaskReceipt] = [:]
    var terminalTaskIDs: Set<String> = []

    var isComplete: Bool {
        !taskIDs.isEmpty && awaitingReceipt.isEmpty
            && taskIDs.allSatisfy { receipts[$0] != nil && terminalTaskIDs.contains($0) }
    }
}

/// A message sent while the room's agents were already working. Persisted
/// before `groups.send` so a lost answer is retried with the same key.
struct HermesBotModeFollowUp: Codable, Equatable, Sendable {
    static let maximumPending = 16

    let eventID: String
    let threadID: String
    let text: String
    var senderSnapshot: TimelineSenderSnapshot?
    /// Hermes' own event ID from the `groups.send` receipt.
    var discussionEventID: String?
}

struct HermesBotModeParticipant: Identifiable, Equatable, Sendable {
    enum Availability: Equatable, Sendable {
        case available
        case profileUnavailable
        /// Lives on another computer, which runs its turns (RoomLink).
        case otherComputer
        case unsupportedTarget
    }

    let memberID: String
    let profileID: String
    let handle: String
    let displayName: String
    let profile: AgentProfile?
    let availability: Availability
    /// The computer an agent from elsewhere lives on.
    let computerName: String?

    var id: String { memberID }
    var canOpenAgentChat: Bool { availability == .available }

    /// `computerNamed` names a peer member's computer from its `peer_id`. A
    /// peer never borrows a local profile, even one with the same ID.
    init(member: HermesBotModeRoomMember, profiles: [AgentProfile],
         computerNamed: (String) -> String? = { _ in nil }) {
        memberID = member.memberID
        profileID = member.profile
        handle = member.handle
        let isLocal = member.target["kind"]?.string == "local"
            && member.target["profile"]?.string == member.profile
        let peerID = member.target["kind"]?.string == "peer" ? member.target["peer_id"]?.string : nil
        let matches = isLocal ? profiles.filter { $0.id == member.profile } : []
        profile = matches.count == 1 ? matches.first : nil
        displayName = profile?.name ?? member.displayName ?? member.handle
        computerName = peerID.map { computerNamed($0) ?? $0 }
        availability = peerID != nil ? .otherComputer
            : !isLocal ? .unsupportedTarget
            : profile == nil ? .profileUnavailable : .available
    }
}

/// The containing workspace owns this projection. A room ID alone never
/// authorizes a callback after the selected host or credential changes.
struct HermesBotModeRoomSummary: Identifiable, Equatable, Sendable {
    let roomID: String
    let name: String
    let members: [HermesBotModeRoomMember]
    let updatedAt: Date
    let isDisbanded: Bool
    let canRename: Bool
    let canExecute: Bool

    var id: String { roomID }
    var memberCount: Int { members.count }
    var canOpen: Bool { !isDisbanded }

    init(room: HermesBotModeRoomState, capabilities: HermesBotModeCapabilities?) {
        roomID = room.roomID
        name = room.name
        members = room.members
        updatedAt = Date(timeIntervalSince1970: room.updatedAt)
        isDisbanded = room.disbandedAt != nil
        canRename = !isDisbanded
            && capabilities?.supports("groups.rename") == true
            && room.authorityGatewayID == capabilities?.authorityGatewayID
        canExecute = !isDisbanded
            && capabilities?.supportsNativeExecution == true
            && room.authorityGatewayID == capabilities?.authorityGatewayID
            && (2...BotModeRoom.maximumMembers).contains(room.members.count)
            && room.members.allSatisfy {
                // Hermes runs an agent on another computer through its RoomLink.
                $0.target["kind"]?.string == "peer"
                    || ($0.target["kind"]?.string == "local" && $0.target["profile"]?.string == $0.profile)
            }
    }

    func participants(profiles: [AgentProfile],
                      computerNamed: (String) -> String? = { _ in nil }) -> [HermesBotModeParticipant] {
        members.map { HermesBotModeParticipant(member: $0, profiles: profiles, computerNamed: computerNamed) }
    }
}
