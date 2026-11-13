import Foundation
import SwiftUI

/// Something the shell does for a group chat, asked by a list that holds only the computer it was
/// drawn for. The shell refuses a request made for another computer.
struct AgentWorkspaceActionRequest: Equatable, Sendable {
    let owner: WorkspaceOwner
    let action: AgentWorkspaceAction
}

enum AgentWorkspaceAction: Equatable, Sendable {
    case openGroup(roomID: String)
    case createGroup(seedProfileID: String?)
    case openGroupSettings(roomID: String)
    case renameGroup(roomID: String, name: String)
    case deleteGroup(roomID: String)
}

/// The old Agents screen's pins and archives of group chats (`FleetStore` keeps those now). Only the
/// saved copy is left, erased with the rest of what this device keeps.
enum AgentGroupPreferences {
    private static let key = "loopdy.agents.groupPreferences.v1"
    static func erase(defaults: UserDefaults) { defaults.removeObject(forKey: key) }
}

enum AgentActionsPresentation {
    static func unavailableMessage(_ availability: WorkspaceAvailability) -> String? {
        switch availability {
        case .available: nil
        case .unknown: "Checking what this host supports."
        case .unavailable(let reason): reason.message
        }
    }
}
