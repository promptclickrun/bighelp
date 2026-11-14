#if os(visionOS)
import SwiftUI

/// Settings › In your space (Vision Pro): show the agent in the room, and
/// choose what a quick pinch on it does.
struct SpatialAvatarSettingsSection: View {
    @Bindable var settings: SettingsStore

    @Environment(\.spatialAvatar) private var avatar
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @BighelpThemeReader private var theme

    var body: some View {
        Section {
            Toggle("Show your bot in the room", isOn: Binding(
                get: { avatar?.isVolumeOpen ?? false },
                set: { show in
                    if show { openWindow(id: SpatialAvatarSceneID.avatar) }
                    else { dismissWindow(id: SpatialAvatarSceneID.avatar) }
                }
            ))
            .accessibilityIdentifier("settings.spatial-avatar.show")

            Button {
                SpatialSimpleMode.enter(avatar, openWindow: openWindow)
            } label: {
                Label("Switch to simple mode", systemImage: "figure.stand")
            }
            .accessibilityIdentifier("settings.spatial-avatar.simple-mode")

            Picker("Quick pinch", selection: $settings.spatialAvatarPinchAction) {
                ForEach(SpatialAvatarPinchAction.allCases) { action in
                    Label(action.title, systemImage: action.systemImage).tag(action)
                }
            }
            .bighelpSegmentedPicker()
            .frame(minHeight: BighelpTokens.hitTarget)
            .accessibilityIdentifier("settings.spatial-avatar.pinch")
        } header: {
            Text("In your space")
        } footer: {
            Text("\(settings.spatialAvatarPinchAction.detail) Simple mode closes Bighelp's window and leaves just your bot; Open Bighelp under it brings the window back. To move your bot, pinch and hold the bar under it and drag. Let go near a table and it stays anchored there.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
    }
}
#endif
