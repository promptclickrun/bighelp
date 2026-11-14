import SwiftUI

/// Deletes one agent's Hermes profile through the shared profile lifecycle
/// path: review, retire its chats, delete, then confirm it's gone and refresh
/// the agent list. Absent where the connection can't delete profiles.
struct AgentDeletionAction {
    let run: @MainActor (_ profileID: String) async throws -> Void
}

extension EnvironmentValues {
    @Entry var agentDeletion: AgentDeletionAction? = nil
}

/// What to do when Delete Agent ends in an error that doesn't say whether Hermes deleted the agent.
/// Hermes stops an agent's own processes before it removes it, which takes up to ten seconds and
/// can drop the app's connection. The answer is then lost, or the app's own follow-up steps find a
/// new connection and stop ("The selected host or connection changed"), while the agent is gone
/// on the computer. The agent list on the connection there is now says what happened.
enum AgentDeletionRecovery {
    /// The request may have reached Hermes: a connection that changed or dropped, or an answer
    /// that never came. A refusal (the agent is in a group chat, it's the default) is not one.
    static func leavesOutcomeOpen(_ error: any Error) -> Bool {
        switch error {
        case HermesProfileLifecycleError.ownerChanged, HermesProfileLifecycleError.outcomeUnknown,
             HermesProfileLifecycleError.reviewChanged,
             NativeWorkspaceLifecycleError.ownerChanged, NativeWorkspaceLifecycleError.sharedStateMismatch,
             WorkspaceClientError.ownerChanged, WorkspaceClientError.outcomeUnknown,
             DirectHermesError.notConnected, DirectHermesError.connectionFailed,
             DirectHermesError.disconnected, DirectHermesError.timedOut:
            true
        case WorkspaceClientError.unavailable(.notConnected):
            true
        default:
            false
        }
    }

    /// The computer the agent was on, as the app sees it now.
    struct Host {
        /// Still the computer and sign-in the deletion was sent to.
        var isSameComputer: @MainActor () -> Bool
        /// Connected, with its workspace ready to be read.
        var isReady: @MainActor () -> Bool
        /// Reads the agent list again from the computer; throws when it can't.
        var reloadAgents: @MainActor () async throws -> Void
        var hasAgent: @MainActor () -> Bool
    }

    /// True once the computer's own agent list no longer has the agent. False when it still has
    /// it, when another computer is in use, or when the computer didn't come back in `timeout`.
    @MainActor static func confirmsDeleted(
        _ host: Host, timeout: Duration = .seconds(20), step: Duration = .milliseconds(250)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while host.isSameComputer() {
            if host.isReady(), (try? await host.reloadAgents()) != nil {
                return host.isSameComputer() && !host.hasAgent()
            }
            guard ContinuousClock.now < deadline, (try? await Task.sleep(for: step)) != nil else { return false }
        }
        return false
    }
}

/// The deleted agent's chats, noted while the deletion runs so their screens can close after it.
@MainActor
final class AgentDeletionRetiredChats {
    var ids = Set<String>()
}

enum AgentDeletionPresentation {
    /// Hermes never deletes its default profile.
    static func canDelete(_ agent: AgentProfile) -> Bool {
        !agent.isDefault && agent.id != "default"
    }

    static func title(_ agent: AgentProfile) -> String { "Delete \(agent.name)?" }

    static func message(_ agent: AgentProfile) -> String {
        "This permanently deletes \(agent.name) from your computer, including its instructions, memory, skills, settings and chats. A reply in progress is stopped and unsent drafts are removed. This can't be undone."
    }

    static func progress(_ agent: AgentProfile) -> String { "Deleting \(agent.name)…" }

    static func errorMessage(_ error: any Error) -> String {
        switch error {
        case HermesProfileLifecycleError.currentProfileProtected:
            "Hermes is running as this bot on this connection, so it can't be deleted from here."
        case HermesProfileLifecycleError.activeDefaultProtected:
            "This bot is your computer's default. Make another bot the default first, in its Advanced Options › Manage bots."
        case HermesProfileLifecycleError.reviewChanged:
            "This bot changed while it was being deleted. Try again."
        case HermesProfileLifecycleError.outcomeUnknown:
            BighelpPlatform.isMac
                ? "Hermes didn't confirm the deletion. Refresh the list before trying again."
                : "Hermes didn't confirm the deletion. Pull down to refresh the list before trying again."
        default:
            (error as? LocalizedError)?.errorDescription ?? "The bot couldn't be deleted. Try again."
        }
    }
}
