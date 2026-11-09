import SwiftUI

/// Lets the chat on screen take a share handed to it (`AppState.handOff`) into its message box.
/// Its own modifier, so `ChatDestinationView`'s body doesn't grow.
@MainActor
struct PendingShareIntake: ViewModifier {
    let model: ChatModel
    let appState: AppState
    /// The computer this chat is on (`cacheScopeID`).
    let scope: String?
    var center: PendingShareCenter = .shared

    func body(content: Content) -> some View {
        content.task(id: appState.pendingShare?.id) {
            await Self.take(into: model, appState: appState, scope: scope, center: center)
        }
    }

    /// What the chat does as it opens, and again when a share is handed to it.
    static func take(into model: ChatModel, appState: AppState, scope: String?, center: PendingShareCenter) async {
        guard !model.isBotMode else { return }
        // Every chat reports to it: one opened again after a relaunch can still settle a share
        // its history shows arrived.
        model.shareTracker = center
        // The share the person opened first, whole, files and all, even when the box already has
        // its words; then those its saved draft still holds.
        let isOnTop = appState.path.last == .chat(conversationID: model.conversationID)
        if let handoff = appState.takePendingShare(conversationID: model.conversationID, isOnTop: isOnTop) {
            let placement = await model.placeShare(handoff.share, from: handoff.inbox, tracker: center)
            if placement == .interrupted { center.release(handoff.share.id) }
        }
        model.restoreSharesInBox(scope: scope)
    }
}
