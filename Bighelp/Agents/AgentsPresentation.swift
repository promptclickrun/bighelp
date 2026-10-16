import Foundation
import SwiftUI

struct AgentWorkspaceActionRequest: Equatable, Sendable {
    let owner: WorkspaceOwner
    let action: AgentWorkspaceAction
}

enum AgentWorkspaceAction: Equatable, Sendable {
    case openAgentChat(profileID: String)
    case openAgentSessions(profileID: String)
    case openAgentScheduledTasks(profileID: String)
    /// The Agents list, filtered to group chats this agent is in.
    case openAgentGroups(profileID: String)
    case openGroup(roomID: String)
    case createGroup(seedProfileID: String?)
    case openGroupSettings(roomID: String)
    case renameGroup(roomID: String, name: String)
    case deleteGroup(roomID: String)
    case openHostStatus
}

@MainActor @Observable
final class AgentGroupPreferences {
    struct Entry: Codable { var pinned = false; var archived = false }
    private var values: [String: [String: Entry]]
    private let defaults: UserDefaults
    private static let key = "loopdy.agents.groupPreferences.v1"
    static func erase(defaults: UserDefaults) { defaults.removeObject(forKey: key) }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = defaults.data(forKey: Self.key).flatMap {
            try? JSONDecoder().decode([String: [String: Entry]].self, from: $0)
        } ?? [:]
    }
    func entry(_ id: String, scope: String) -> Entry { values[scope]?[id] ?? Entry() }
    func set(_ entry: Entry, id: String, scope: String) {
        values[scope, default: [:]][id] = entry
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: Self.key) }
    }
}

enum AgentDirectoryPresentation {
    enum DirectorySection: Hashable {
        case groups
        case agents
    }

    static let sectionOrder: [DirectorySection] = [.groups, .agents]

    static func sectionOrder(filteredToProfileID _: String?) -> [DirectorySection] {
        sectionOrder
    }

    enum LoadingMode: Equatable {
        case none, fullScreen, inline
    }

    static func loadingMode(isLoading: Bool, hasProfiles: Bool) -> LoadingMode {
        guard isLoading else { return .none }
        return hasProfiles ? .inline : .fullScreen
    }

    static func visibleProfiles(_ profiles: [AgentProfile], query: String = "") -> [AgentProfile] {
        profiles.filter {
            $0 != .bighelpLinkDefault
                && matches(query, fields: [$0.name, $0.role, $0.summary, $0.id])
        }
    }

    static func visibleGroups(
        _ groups: [HermesBotModeRoomSummary], profiles: [AgentProfile],
        query: String, profileID: String?
    ) -> [HermesBotModeRoomSummary] {
        groups.filter { room in
            guard !room.isDisbanded,
                  profileID == nil || room.members.contains(where: {
                      $0.profile == profileID && $0.target["kind"]?.string == "local"
                  })
            else { return false }
            let members = room.participants(profiles: profiles)
            return matches(query, fields: [room.name] + members.flatMap {
                [$0.displayName, $0.handle, $0.profileID]
            })
        }
    }

    static func selectedGroup(
        in groups: [HermesBotModeRoomSummary], selectedID: String?
    ) -> HermesBotModeRoomSummary? {
        groups.first { $0.roomID == selectedID } ?? groups.first
    }

    static func matches(_ query: String, fields: [String]) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { term in
            fields.contains { $0.localizedStandardContains(String(term)) }
        }
    }
}

enum AgentRowMenuAction: String, CaseIterable, Equatable, Sendable {
    case openChat = "chat"
    case edit
    case viewSessions = "sessions"
    case scheduledTasks = "schedules"
    case groups
    case duplicate
    case shortcuts
    case setPrimary = "primary"
    case togglePin = "pin"
    case saveTemplate = "template"
    /// Last, and shown as destructive.
    case delete

    var isDestructive: Bool { self == .delete }

    var title: String {
        switch self {
        case .openChat: "Message"
        case .edit: "Edit"
        case .viewSessions: "Past chats"
        case .scheduledTasks: "Scheduled tasks"
        case .groups: "Group chats"
        case .duplicate: "Duplicate"
        case .shortcuts: "Use with Siri"
        case .setPrimary: "Use for new chats"
        case .togglePin: "Pin"
        case .saveTemplate: "Save as template"
        case .delete: "Delete"
        }
    }

    var systemImage: String {
        switch self {
        case .openChat: "bubble.left.and.bubble.right"
        case .edit: "pencil"
        case .viewSessions: "clock.arrow.circlepath"
        case .scheduledTasks: "calendar.badge.clock"
        case .groups: "person.2"
        case .duplicate: "plus.square.on.square"
        case .shortcuts: "waveform"
        case .setPrimary: "star"
        case .togglePin: "pin"
        case .saveTemplate: "square.and.arrow.down.on.square"
        case .delete: "trash"
        }
    }

    var capability: WorkspaceCapability? {
        switch self {
        case .openChat: .canonicalAgentChat
        case .edit: .profilesEdit
        case .viewSessions: .sessionsRead
        case .scheduledTasks: .schedulesRead
        case .groups: .groupsRead
        case .duplicate: .profilesClone
        case .delete: .profilesEdit
        case .shortcuts, .setPrimary, .togglePin, .saveTemplate: nil
        }
    }
}

struct AgentActionItem: Identifiable, Equatable {
    let action: AgentRowMenuAction
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let detail: String?
    let isSelected: Bool
    let isUnsupported: Bool

    var id: AgentRowMenuAction { action }
}

enum AgentActionsPresentation {
    static func items(
        profileID: String, owner: WorkspaceOwner?, capabilities: WorkspaceCapabilities,
        isPrimary: Bool, isPinned: Bool, canPin: Bool, canClone: Bool,
        shortcutsAvailable: Bool, hasNavigation: Bool,
        canDelete: Bool = false, canSaveTemplate: Bool = false
    ) -> [AgentActionItem] {
        AgentRowMenuAction.allCases.compactMap { action in
            if action == .shortcuts && !shortcutsAvailable { return nil }
            if action == .delete && !canDelete { return nil }
            if action == .saveTemplate && !canSaveTemplate { return nil }
            let availability: WorkspaceAvailability
            if let owner {
                availability = action.capability.map {
                    capabilities.availability(for: $0, owner: owner, profileID: profileID)
                } ?? .available
            } else {
                availability = .unavailable(.notConnected)
            }
            var title = action.title
            var symbol = action.systemImage
            var enabled = availability.isAvailable
            var detail = unavailableMessage(availability)
            var selected = false
            if action == .setPrimary {
                selected = isPrimary
                title = isPrimary ? "Primary Agent" : title
                symbol = isPrimary ? "star.fill" : symbol
                enabled = enabled && !isPrimary
                if availability.isAvailable {
                    detail = isPrimary ? AgentActionPresentation.alreadyPrimaryHint : AgentActionPresentation.setPrimaryHint
                }
            } else if action == .togglePin {
                selected = isPinned
                title = isPinned ? "Unpin" : title
                symbol = isPinned ? "pin.slash" : symbol
                enabled = enabled && (isPinned || canPin)
                if availability.isAvailable {
                    detail = isPinned ? AgentActionPresentation.unpinHint
                        : canPin ? AgentActionPresentation.pinHint : AgentActionPresentation.pinLimitHint
                }
            } else if action == .duplicate && !canClone {
                enabled = false
                detail = "Profile duplication is not available on this connection."
            } else if [.openChat, .viewSessions, .scheduledTasks].contains(action), !hasNavigation {
                enabled = false
                detail = "This connection is not ready to open the workspace."
            }
            return AgentActionItem(
                action: action, title: title, systemImage: symbol,
                isEnabled: enabled, detail: detail, isSelected: selected,
                isUnsupported: availability == .unavailable(.unsupportedOperation)
                    || availability == .unavailable(.unsupportedHost)
            )
        }
    }

    static func unavailableMessage(_ availability: WorkspaceAvailability) -> String? {
        switch availability {
        case .available: nil
        case .unknown: "Checking what this host supports."
        case .unavailable(let reason): reason.message
        }
    }
}

enum AgentRowPresentation {
    enum ActionAlignment: Equatable {
        case center
        var swiftUIValue: VerticalAlignment { .center }
    }

    static let roleLineLimit = 2
    static let summaryLineLimit = 2
    static let textColumnCanShrink = true
    static let actionAlignment = ActionAlignment.center
    static let actionSystemImage: String? = "ellipsis"
    static let showsNavigationDisclosureIndicator = false
}

extension AgentDirectoryPresentation {
    /// Agents shown in the directory's avatar grid: the user's pins in pin
    /// order, or, when nothing is pinned, the first few agents with the
    /// primary agent leading.
    struct Featured: Equatable {
        let profiles: [AgentProfile]
        let isPinnedSelection: Bool
    }

    static let featuredLimit = AgentActionPresentation.pinnedAgentLimit

    static func featured(
        visible: [AgentProfile], pinnedIDs: [String], primaryID: String?,
        limit: Int = featuredLimit
    ) -> Featured {
        let pinned = pinnedIDs.compactMap { id in visible.first { $0.id == id } }
        if !pinned.isEmpty {
            return Featured(profiles: Array(pinned.prefix(limit)), isPinnedSelection: true)
        }
        let ordered = visible.filter { $0.id == primaryID } + visible.filter { $0.id != primaryID }
        return Featured(profiles: Array(ordered.prefix(limit)), isPinnedSelection: false)
    }
}

/// Live states derived only from authoritative Hermes state. Agents have no
/// per-profile activity feed yet, so the only agent-level signal is a Bot Mode
/// approval waiting on one of that agent's group memberships; everything else
/// stays `.idle` rather than inventing status.
enum AgentLiveStatePresentation {
    static func agentStates(
        rooms: [HermesBotModeRoomSummary],
        pendingApprovals: (String) -> [HermesBotModePendingApproval]
    ) -> [String: AgentLiveState] {
        var states: [String: AgentLiveState] = [:]
        for room in rooms where !room.isDisbanded {
            for approval in pendingApprovals(room.roomID) {
                guard let profile = room.members.first(where: { $0.memberID == approval.memberID })?.profile
                else { continue }
                states[profile] = .nudge
            }
        }
        return states
    }

    /// A group needing an approval outranks one that is simply working.
    static func groupState(isWorking: Bool, hasPendingApprovals: Bool) -> AgentLiveState? {
        if hasPendingApprovals { return .nudge }
        if isWorking { return .thinking }
        return nil
    }
}
