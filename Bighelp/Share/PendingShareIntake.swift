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
            let isOnTop = appState.path.last == .chat(conversationID: model.conversationID)
            guard let handoff = appState.takePendingShare(
                conversationID: model.conversationID, memberIDs: model.memberIDs, isOnTop: isOnTop,
                isNewChat: isOnTop && model.transcriptEntries.isEmpty) else { return }
            center.hold(handoff.share.id, by: model)
            let placement = await model.placeShare(handoff.share, from: handoff.inbox) { [center] id in
                center.settled(id)
            }
            if placement == .interrupted { center.release(handoff.share.id) }
        }
    }
}
