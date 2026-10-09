import SwiftUI

struct AgentFastModeRow: View {
    let model: AgentRuntimeDefaultsEditorModel
    var allowsEdits = true
    var saveImmediately = false

    var body: some View {
        Menu {
            Button {
                select(.off)
            } label: {
                if model.draft.mainChats.fastMode == .off { Label("Off", systemImage: "checkmark") }
                else { Text("Off") }
            }
            Button {
                select(.on)
            } label: {
                Text("On")
                Text("May cost more")
                if model.draft.mainChats.fastMode == .on { Image(systemName: "checkmark") }
            }
            .disabled(model.fastModeUnavailableReason != nil)
        } label: {
            LabeledContent("Fast Mode", value: value)
        }
        .disabled(!allowsEdits || !model.hasLoaded || model.isSaving || model.isLoading
                  || (model.fastModeUnavailableReason != nil && model.draft.mainChats.fastMode == .off))
        .accessibilityHint("Default for new chats with this agent. Fast Mode may cost more.")
        .accessibilityIdentifier("agent.runtime.mainChats.fast-mode")
        if let reason = model.fastModeUnavailableReason {
            Text(reason)
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var value: String {
        if model.isSaving { return "Saving…" }
        if saveImmediately, model.errorMessage != nil { return "Not confirmed" }
        if !model.hasLoaded { return "Loading…" }
        return model.fastModeUnavailableReason == nil ? model.draft.mainChats.fastMode.title : "Unavailable"
    }

    private func select(_ mode: FastMode) {
        if saveImmediately {
            Task { await model.saveFastMode(mode) }
        } else {
            model.selectFastMode(mode)
        }
    }

    @BighelpThemeReader private var theme
}
