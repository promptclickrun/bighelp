import SwiftUI

/// Hermes saves a chat only on its first message and drops an unsaved session a little while
/// after the app disconnects. A new chat left open with an unsent draft could come back to
/// "Route unavailable" with the draft gone. Instead, the screen quietly opens a fresh chat with
/// the same agent and puts the text back in the message box.
extension RootShellView {
    /// Leaving the app: remember the open chat's agent and text, while it has sent nothing.
    func rememberOpenChat() {
        guard case .chat(let id)? = appState.path.last, let chat = featureStore.unsentChat(id: id) else {
            appState.suspendedChat = nil
            return
        }
        appState.suspendedChat = SuspendedChat(chatID: id, agentID: chat.agentID, text: chat.text)
    }

    /// A chat that never sent anything lost its session. If it's the one on screen, a fresh
    /// chat takes its place (starting a new chat replaces the chat on top) with its text.
    func replaceLostChat(id: String, agentID: String?, text: String) {
        guard case .chat(let shown)? = appState.path.last, shown == id else { return }
        let remembered = appState.suspendedChat?.chatID == id ? appState.suspendedChat : nil
        appState.suspendedChat = nil
        let draft = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (remembered?.text ?? "") : text
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appState.pendingComposerText = draft
        }
        startNewChat(explicitAgentID: agentID ?? remembered?.agentID)
    }

    /// Hooks the store's retire signal to the screen. Called whenever the root appears.
    func watchForLostChats() {
        featureStore.onUnsentChatRetired = { id, agentID, text in
            replaceLostChat(id: id, agentID: agentID, text: text)
        }
    }
}

/// Shown for a moment while a chat whose session is gone is replaced by a fresh one.
struct ReopeningChatView: View {
    let onAppear: () -> Void

    var body: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Reopening the chat")
            .task { onAppear() }
    }
}
