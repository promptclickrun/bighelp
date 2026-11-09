import SwiftUI

/// Lets the chat on screen take a share handed to it (`AppState.handOff`) into its message box.
/// Its own modifier, so `ChatDestinationView`'s body doesn't grow.
@MainActor
struct PendingShareIntake: ViewModifier {
    let model: ChatModel
    let appState: AppState
    var center: PendingShareCenter = .shared

    func body(content: Content) -> some View {
        content.task(id: appState.pendingShare?.id) {
            guard !model.isBotMode else { return }
            // Every chat reports to it: one opened again after a relaunch can still settle a share
            // its history shows arrived.
            model.shareTracker = center
            let isOnTop = appState.path.last == .chat(conversationID: model.conversationID)
            guard let handoff = appState.takePendingShare(conversationID: model.conversationID,
                                                          isOnTop: isOnTop) else { return }
            let placement = await model.placeShare(handoff.share, from: handoff.inbox, tracker: center)
            if placement == .interrupted { center.release(handoff.share.id) }
        }
    }
}
