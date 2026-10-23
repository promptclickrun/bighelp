import SwiftUI

/// Settings › Experience: Bots mode, Code mode, which home a launch opens in once Code is on,
/// and the Unified Mode Toggle that puts Bots, Chat and Code at the top of each home.
extension SettingsView {
    var experienceSection: some View {
        Section {
            Toggle(isOn: $settings.simpleBotsEnabled) {
                HStack(spacing: BighelpTokens.space12) {
                    BighelpIconTile(systemName: "circle.hexagongrid")
                    settingLabel(String(localized: "Bots mode"), detail: String(localized: "Just your bots and their chats, nothing else."))
                }
                .padding(.horizontal, BighelpMenuRowLayout.labelInset)
            }
            .bighelpMacSettingsRowInsets()
            .accessibilityIdentifier("settings.simple-bots")
            Toggle(isOn: $settings.codeModeEnabled) {
                HStack(spacing: BighelpTokens.space12) {
                    BighelpIconTile(systemName: "chevron.left.forwardslash.chevron.right")
                    settingLabel(String(localized: "Code mode"), detail: String(localized: "Fire off coding sessions against your projects."))
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
            Toggle(isOn: $settings.unifiedModeToggleEnabled) {
                HStack(spacing: BighelpTokens.space12) {
                    BighelpIconTile(systemName: "capsule.lefthalf.filled")
                    settingLabel(String(localized: "Unified Mode Toggle"),
                                 detail: String(localized: "Switch between Bots, Chat and Code from the top of each home."))
                }
                .padding(.horizontal, BighelpMenuRowLayout.labelInset)
            }
            .bighelpMacSettingsRowInsets()
            .accessibilityIdentifier("settings.unified-mode-toggle")
            if (settings.simpleBotsEnabled || settings.codeModeEnabled), BighelpChatSwitcher.isOffered(screen: screen) {
                chatSwitcherToggle
            }
        } header: {
            Text("Experience")
        } footer: {
            if settings.unifiedModeToggleEnabled {
                Text("You can switch modes any time from the top of each home.")
                    .bighelpFont(.metadata)
            } else if settings.codeModeEnabled {
                Text("You can switch modes any time from ☰.")
                    .bighelpFont(.metadata)
            }
        }
        .listRowBackground(theme.surface)
    }

    /// The Duo folded, and iPad and Mac in landscape: the bots or sessions beside a chat.
    var chatSwitcherToggle: some View {
        Toggle(isOn: $settings.chatSwitcherEnabled) {
            HStack(spacing: BighelpTokens.space12) {
                BighelpIconTile(systemName: "rectangle.righthalf.inset.filled")
                settingLabel(String(localized: "Chat switcher"),
                             detail: String(localized: "Your bots, or your running sessions in Code, beside each chat."))
            }
            .padding(.horizontal, BighelpMenuRowLayout.labelInset)
        }
        .bighelpMacSettingsRowInsets()
        .accessibilityIdentifier("settings.chat-switcher")
    }
}
