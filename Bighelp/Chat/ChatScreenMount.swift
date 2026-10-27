import Foundation

/// What a chat screen tells the app while it shows a chat: it counts as on screen
/// (`BighelpVisibleChats`, so its alerts stay quiet), and its PDF picker and resume
/// progress belong to it.
///
/// A `ChatView` can be handed another `ChatModel` and stay on screen: New chat
/// replaces a local draft with the durable session in place, and a reconnect can make
/// the model again. `mount` is called again then and moves everything to the new
/// model; registering only when the view appears left the chat in front of the
/// person unregistered, and its alerts showed.
@MainActor
final class ChatScreenMount {
    /// Names this screen to `BighelpVisibleChats`: a chat view made again can appear before the old one leaves.
    private let screen = UUID()
    private weak var mounted: ChatModel?

    func mount(_ model: ChatModel) {
        if let old = mounted, old !== model { release(old) }
        mounted = model
        BighelpVisibleChats.shared.appeared(model, screen: screen)
        ChatPDFPagesDraftRegistry.mount(model)
        model.nativeSessionResumeProgress.mount()
    }

    func unmount() {
        guard let model = mounted else { return }
        mounted = nil
        release(model)
    }

    private func release(_ model: ChatModel) {
        BighelpVisibleChats.shared.disappeared(model, screen: screen)
        ChatPDFPagesDraftRegistry.unmount(model)
        model.nativeSessionResumeProgress.unmount()
    }
}
