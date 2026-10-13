import SwiftUI

/// Settings › Experience: Bighelp IDE, and which home a launch opens in once it's on.
extension SettingsView {
    var experienceSection: some View {
        Section {
            Toggle(isOn: $settings.codeModeEnabled) {
                HStack(spacing: BighelpTokens.space12) {
                    BighelpIconTile(systemName: "chevron.left.forwardslash.chevron.right")
                    settingLabel("Bighelp IDE", detail: "Fire off coding sessions against your projects.")
                }
            }
            .accessibilityIdentifier("settings.code-mode")
            if settings.codeModeEnabled {
                Picker("Open in", selection: $settings.startExperience) {
                    ForEach(BighelpExperience.allCases) { experience in
                        Text(experience.title).tag(experience)
                    }
                }
                .bighelpSegmentedPicker()
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("settings.code-mode.open-in")
            }
        } header: {
            Text("Experience")
        } footer: {
            if settings.codeModeEnabled {
                Text("You can switch modes any time from ☰.")
                    .bighelpFont(.metadata)
            }
        }
        .listRowBackground(theme.surface)
    }
}
