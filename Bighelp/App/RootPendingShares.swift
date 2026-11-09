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
            context: pendingShareContext)
    }

    /// The computer in use, its agents and chats, for a share's review wherever it shows.
    var pendingShareContext: PendingShareReviewContext {
        PendingShareReviewContext(
            computerName: hostRegistry?.selectedHost?.name,
            scope: currentWorkspaceOwner?.cacheScopeID,
            agents: agents.profiles,
            chats: { shareableChats(for: $0) },
            open: { share, destination, name in openPendingShare(share, at: destination, agentName: name) },
            openChat: { id in
                guard let record = sessionCatalog.session(id: id) else { return }
                appState.chatOpenedFromList = true
                openSession(record.summary)
            })
    }

    /// The same, from inside Bots mode's Settings: a chat opens once Settings has closed.
    var settingsPendingShareContext: PendingShareReviewContext {
        let context = pendingShareContext
        return PendingShareReviewContext(
            computerName: context.computerName, scope: context.scope, agents: context.agents, chats: context.chats,
            open: { share, destination, name in leaveSettings { context.open(share, destination, name) } },
            openChat: { id in leaveSettings { context.openChat(id) } })
    }

    /// ☰ › Shared with bighelp, while any share waits: every one, put off ones too.
    var pendingSharesMenuRow: (count: Int, open: () -> Void)? {
        let center = PendingShareCenter.shared
        guard center.waitingCount > 0 else { return nil }
        return (center.waitingCount, { afterClosingHomeSheets { center.showList() } })
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
                actionErrorMessage = String(localized: "bighelp couldn't open this share. Try again.")
                await center.refresh()
                return
            }
            // Never another chat or computer than the one picked: if it's gone now, the share waits.
            let record = destination.sessionID.flatMap { sessionCatalog.session(id: $0) }
            guard currentWorkspaceOwner?.cacheScopeID == destination.scope,
                  destination.sessionID == nil || record != nil else {
                center.release(share.id)
                actionErrorMessage = String(localized: "That chat isn't available now. Your share is still saved.")
                return
            }
            if let record {
                appState.handOff(PendingShareHandoff(share: share, inbox: inbox, destination: destination,
                                                     since: .now, onDropped: { center.release($0) }))
                appState.chatOpenedFromList = true
                openSession(record.summary)
                return
            }
            // A new chat shows a local canvas first and passes only its text on to the chat Hermes
            // makes, so the share goes straight to that chat, named in its placement.
            startNewChat(explicitAgentID: destination.agentID, opened: { sessionID in
                Task { @MainActor in
                    do {
                        try await center.bind(share.id, to: sessionID)
                    } catch {
                        center.release(share.id)
                        return
                    }
                    guard currentWorkspaceOwner?.cacheScopeID == destination.scope else {
                        center.release(share.id)
                        return
                    }
                    appState.handOff(PendingShareHandoff(share: share, inbox: inbox,
                                                         destination: destination.bound(to: sessionID),
                                                         since: .now, onDropped: { center.release($0) }))
                }
            })
        }
    }
}
