import SwiftUI

/// Settings' first screen: the groups of pages, one row each.
extension SettingsView {
    func settingsMenuGroup(sections: [SettingsMenuSection]) -> some View {
        Section {
            ForEach(sections) { section in
                NavigationLink {
                    settingsDone(destination(for: section))
                } label: {
                    settingsMenuRow(section)
                }
                .bighelpSettingsLink()
                .accessibilityValue(section == .appearance ? appearanceSummary : "")
                .accessibilityIdentifier(section.accessibilityIdentifier)
            }
        }
        .listRowBackground(theme.surface)
    }

    func menuDetail(_ section: SettingsMenuSection) -> String {
        switch section {
        case .appearance: appearanceSummary
        case .voice: settings.voiceConversationMode == .codexLive
            ? "GPT Live 1 · a live conversation" : "TTS · reads replies aloud"
        default: section.detail
        }
    }

    func settingsMenuRow(_ section: SettingsMenuSection) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            BighelpIconTile(systemName: section.systemImage, tint: section.tintHex.map { Color(hex: $0) })
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                if section == .connectivityAndNotifications, let attention = selectedHostPluginUpdate?.attentionTitle {
                    Text(attention)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.action)
                        .accessibilityIdentifier("settings.menu.plugin-update")
                } else {
                    Text(menuDetail(section))
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: BighelpTokens.space8)
            if BighelpPlatform.drawsOwnLinkChevron {
                // The List's own chevron is hidden on the Mac (`bighelpSettingsLink`).
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 52)
        .padding(.horizontal, BighelpMenuRowLayout.labelInset)
        .bighelpSettingsLinkLabel()
    }
}
