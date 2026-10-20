import SwiftUI

/// Settings › Experience: Simple Bot mode, Bighelp IDE, and which home a launch opens in once it's on.
extension SettingsView {
    var experienceSection: some View {
        Section {
            Toggle(isOn: $settings.simpleBotsEnabled) {
                HStack(spacing: BighelpTokens.space12) {
                    BighelpIconTile(systemName: "circle.hexagongrid")
                    settingLabel("Simple Bot mode", detail: "Just your bots and their chats, nothing else.")
                }
                .padding(.horizontal, BighelpMenuRowLayout.labelInset)
            }
            .bighelpMacSettingsRowInsets()
            .accessibilityIdentifier("settings.simple-bots")
            Toggle(isOn: $settings.codeModeEnabled) {
                HStack(spacing: BighelpTokens.space12) {
                    BighelpIconTile(systemName: "chevron.left.forwardslash.chevron.right")
                    settingLabel("Bighelp IDE", detail: "Fire off coding sessions against your projects.")
                }
                .padding(.horizontal, BighelpMenuRowLayout.labelInset)
            }
            .bighelpMacSettingsRowInsets()
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
