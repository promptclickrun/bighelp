import SwiftUI

// The switcher beside a chat (`BighelpChatSwitcher`): a coding session's other sessions, else the bots.
extension RootShellView {
    /// The column for the chat with `conversationID`, where one shows: nil with the switcher turned
    /// off, or with fewer than two places to go.
    func chatSwitcherColumn(for conversationID: String, agentID: String?) -> AnyView? {
        guard BighelpChatSwitcher.isShown(isOn: settings.chatSwitcherEnabled, screen: screen,
                                          horizontalSizeClass: horizontalSizeClass) else { return nil }
        if let store = codeHome, store.scopeID == currentWorkspaceOwner?.cacheScopeID,
           store.sessions.contains(where: { $0.id == conversationID }) {
            let reader = CodeChatStatusReader(catalog: sessionCatalog, features: featureStore)
            guard store.switcherSessions(reader: reader).count > 1 else { return nil }
            return AnyView(CodeSessionSwitcher(store: store, reader: reader, currentID: conversationID,
                                               onOpen: { session in
                // In place of the chat that's open, so Back still goes to where it was opened from.
                if case .chat? = appState.path.last { appState.path.removeLast() }
                openCodeSession(session)
            }))
        }
        let context = simpleBotsContext
        guard SimpleBotsSwitcher.top(context).count > 1 else { return nil }
        return AnyView(SimpleBotsSwitcher(context: context, currentAgentID: agentID))
    }
}

/// A coding session's switcher: reads the sessions again as their states change.
private struct CodeSessionSwitcher: View {
    let store: CodeHomeStore
    let reader: CodeChatStatusReader
    let currentID: String
    let onOpen: (CodeSessionRecord) -> Void

    var body: some View {
        let sessions = store.switcherSessions(reader: reader)
        BighelpChatSwitcherColumn(stops: sessions.enumerated().map { index, entry in
            let (session, status) = entry
            return BighelpChatSwitcherStop(
                id: session.id, title: session.title, state: status.switcherLabel,
                isCurrent: session.id == currentID,
                face: AnyView(CodeSessionSwitcherTile(title: session.title, status: status,
                                                      color: CodeSessionColor.color(at: index))),
                open: { onOpen(session) })
        })
    }
}
