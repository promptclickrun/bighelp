import SwiftUI

/// Kept inside Model & speed so adding speed choices never grows the main menu.
struct SessionFastModeMenu: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let controls: SessionRuntimeControlModel
    var isAllocating = false

    var body: some View {
        Menu {
            if let reason = controls.fastMode?.unavailableReason {
                Text(reason)
            } else if controls.fastMode != nil {
                Button {
                    Task { await controls.selectFastMode(.off) }
                } label: {
                    if controls.fastMode?.mode == .off { Label("Off", systemImage: "checkmark") }
                    else { Text("Off") }
                }
                .accessibilityIdentifier("chat.fast-mode.off")
                Button {
                    Task { await controls.selectFastMode(.on) }
                } label: {
                    if dynamicTypeSize.isAccessibilitySize {
                        Text("On · costs more")
                    } else {
                        Text("On")
                        Text("May cost more")
                    }
                    if controls.fastMode?.mode == .on { Image(systemName: "checkmark") }
                }
                .accessibilityIdentifier("chat.fast-mode.on")
            } else {
                Button(controls.isLoadingFastMode ? "Loading…" : "Try again") {
                    Task { await controls.loadFastModeIfNeeded() }
                }
                .disabled(controls.isLoadingFastMode)
            }
            if let message = controls.fastModeError { Text(message) }
        } label: {
            if dynamicTypeSize.isAccessibilitySize {
                Text("Fast Mode: \(controls.fastMode?.title ?? "Unknown")")
            } else {
                Text("Fast Mode")
                Text("\(controls.fastMode?.title ?? "Unknown") · This chat")
            }
            Image(systemName: "bolt")
        }
        .disabled(isAllocating || controls.isTurnActive || controls.isApplyingSelection || controls.hasPendingSelection)
        .accessibilityHint("Changes only this chat. Turning on Fast Mode may cost more.")
        .accessibilityIdentifier("chat.fast-mode")
    }
}

/// Load from the mounted chat, not from menu content whose tasks may never run.
struct ChatFastModeLoader: ViewModifier {
    let controls: SessionRuntimeControlModel?
    let isAllocating: Bool

    private struct Key: Equatable {
        let session: String?
        let model: String?
        let provider: String?
        let busy: Bool
        let allocating: Bool
    }

    func body(content: Content) -> some View {
        content.task(id: Key(session: controls?.sessionID, model: controls?.currentModel,
                             provider: controls?.currentProvider, busy: controls?.isTurnActive == true,
                             allocating: isAllocating)) {
            guard !isAllocating else { return }
            await controls?.loadFastModeIfNeeded()
        }
    }
}
