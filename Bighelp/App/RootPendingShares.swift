import SwiftUI

/// Shares from other apps (`PendingShareCenter`): the review that offers them, and opening the
/// chat the person picks with the share in its message box.
extension RootShellView {
    var pendingShareReview: PendingShareReview {
        PendingShareReview(
            center: .shared,
            isBlocked: presentsFirstRunOnboarding || hostRegistry?.isWorkspaceReady != true
                || hostRegistry?.isSetupPresented == true || isUnifiedSettingsPresented,
            usesDemoData: usesWorkspaceFixtures,
            computerName: hostRegistry?.selectedHost?.name,
            scope: currentWorkspaceOwner?.cacheScopeID,
            agents: agents.profiles,
            chats: { shareableChats(for: $0) },
            open: { share, destination, name in openPendingShare(share, at: destination, agentName: name) })
    }

    /// An agent's own chats on this computer, newest first: no group chats or scheduled runs.
    func shareableChats(for agentID: String) -> [SessionSummary] {
        sessionCatalog.records.map(\.summary)
            .filter { $0.kind == .direct && $0.agentIDs == [agentID] && $0.hostedRoomID == nil && !$0.isCronSession }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Records where the share goes, then opens that chat; the chat takes the share into its
    /// message box (`PendingShareIntake`). Only on the computer it was picked on.
    func openPendingShare(_ share: PendingShare, at destination: PendingShareDestination, agentName: String) {
        let center = PendingShareCenter.shared
        guard let inbox = center.inbox, currentWorkspaceOwner?.cacheScopeID == destination.scope else {
            actionErrorMessage = String(localized: "You switched computers. Pick where this share goes again.")
            return
        }
        Task { @MainActor in
            do {
                try await center.place(share, at: destination, agentName: agentName)
            } catch {
                actionErrorMessage = String(localized: "bighelp couldn't open this share. It's still saved. Try again.")
                return
            }
            guard currentWorkspaceOwner?.cacheScopeID == destination.scope else {
                center.release(share.id)
                return
            }
            appState.handOff(PendingShareHandoff(share: share, inbox: inbox, destination: destination, since: .now,
                                                 onDropped: { center.release($0) }))
            if let sessionID = destination.sessionID, let record = sessionCatalog.session(id: sessionID) {
                appState.chatOpenedFromList = true
                openSession(record.summary)
            } else {
                startNewChat(explicitAgentID: destination.agentID)
            }
        }
    }
}
