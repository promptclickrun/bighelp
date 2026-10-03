import Foundation

/// One of the person's hosts, as the all-hosts view lists it.
struct FleetHost: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var isSelected: Bool
}

/// What the all-hosts view last learned from one host. The selected host's
/// comes from its live connection; the others are read now and then and kept
/// on this device, so the list shows at once.
struct FleetSnapshot: Codable, Equatable, Sendable {
    var agents: [FleetAgent] = []
    var chats: [FleetChat] = []
    var tasks: [FleetTask] = []
    /// Group chats; nil in snapshots saved before groups were listed.
    var groups: [FleetGroup]? = nil
    var refreshedAt: Date
}

/// Agent IDs are only unique within one host.
enum FleetID {
    static func make(_ hostID: UUID, _ value: String) -> String { hostID.uuidString + "/" + value }
}

struct FleetAgent: Codable, Equatable, Sendable, Identifiable {
    let hostID: UUID
    let profileID: String
    var name: String
    var role: String
    /// The agent's picture, copied into the fleet's own folder.
    var avatarFile: String?
    var isPinned: Bool
    var isDefault: Bool
    /// What Hermes says one of its chats is doing right now.
    var activity: FleetActivity?
    /// Its section and whether it's hidden, as saved on its host.
    var placement: AgentListPlacement? = nil

    var id: String { FleetID.make(hostID, profileID) }
    var isHidden: Bool { placement?.isHidden == true }
}

/// A group chat (a Hermes hosted room) on one host.
struct FleetGroup: Codable, Equatable, Sendable, Identifiable {
    let hostID: UUID
    let roomID: String
    var name: String
    /// Member names, for the row's second line.
    var memberNames: [String]
    var updatedAt: Date
    var isWorking: Bool
    var canRename: Bool
    var canDelete: Bool

    var id: String { FleetID.make(hostID, "group/" + roomID) }
}

enum FleetActivity: String, Codable, Sendable {
    case working
    /// A chat is waiting on the person (an approval or a question).
    case waiting
}

struct FleetChat: Codable, Equatable, Sendable, Identifiable {
    let hostID: UUID
    let profileID: String
    /// Hermes' own session ID, stable for that host.
    let storedSessionID: String
    /// The selected host's catalog ID when the chat was read live.
    var appSessionID: String?
    var title: String
    var preview: String
    var updatedAt: Date
    var isActive: Bool

    var id: String { FleetID.make(hostID, storedSessionID) }
}

struct FleetTask: Codable, Equatable, Sendable, Identifiable {
    let hostID: UUID
    let jobID: String
    let profileID: String
    var name: String
    /// The schedule in words, as the host's Scheduled tasks list shows it.
    var schedule: String
    var nextRun: Date?
    var status: ScheduledTaskStatus

    var id: String { FleetID.make(hostID, profileID + "/" + jobID) }
}

enum FleetHostStatus: Equatable, Sendable {
    case idle
    case loading
    case ready
    /// Couldn't read the host; what's shown is from its last visit.
    case unreachable(String)
}

/// Where a tap in the all-hosts view leads once its host is the selected one.
enum FleetOpen: Equatable, Sendable {
    case agent(profileID: String)
    case chat(profileID: String, storedSessionID: String, appSessionID: String?)
    case task(jobID: String, profileID: String)
    case newChat(profileID: String)
    case group(roomID: String)
    /// A new group chat with these agents, from New chat's Group chat.
    case newGroup(profileIDs: [String])
    /// The agent's routines (its scheduled tasks).
    case routines(profileID: String)
    case destination(FleetDestination)
}

/// Screens that belong to one host. With several hosts, the all-hosts view
/// asks which one first.
enum FleetDestination: String, Equatable, Sendable, Identifiable {
    case settings, agents, projects, kanban, providerUsage, credentialVault, folder

    var id: Self { self }

    var title: String {
        switch self {
        case .settings: "Settings"
        case .agents: "Agents"
        case .projects: "Projects"
        case .kanban: "Kanban"
        case .providerUsage: "Provider usage"
        case .credentialVault: "Credential vault"
        case .folder: "Folder"
        }
    }
}

/// A tap that has to wait for its host to become the selected one.
struct FleetPendingOpen: Equatable, Sendable {
    let hostID: UUID
    let open: FleetOpen
}

/// What a group chat's row can do from the all-hosts list.
enum FleetGroupAction: Equatable, Sendable {
    case open
    case rename(String)
    case delete
}
