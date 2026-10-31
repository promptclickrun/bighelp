import SwiftUI

/// Settings' first screen: the groups of pages, one row each.
extension SettingsView {
    func settingsMenuGroup(sections: [SettingsMenuSection]) -> some View {
        Section {
            ForEach(sections) { section in
                settingsLink(to: .section(section)) {
                    settingsMenuRow(section)
                }
                .bighelpSettingsLink()
                .accessibilityValue(section == .appearance ? appearanceSummary : "")
                .accessibilityIdentifier(section.accessibilityIdentifier)
                .driveTarget(section.accessibilityIdentifier)
            }
        }
        .listRowBackground(theme.surface)
    }

    /// The agent Voice settings opens on (`VoiceSettingsView`), so the row says what that page shows.
    var voiceSettingsAgentID: String? {
        agents.first { $0.id == agentDirectory?.selectedAgentID }?.id
            ?? agents.first(where: \.isDefault)?.id ?? agents.first?.id
    }

    /// The voice type that agent uses; Full Duplex names its provider (GPT-Live or Gemini Live).
    private var voiceDetail: String {
        let voice = settings.voicePreference(computer: workspaceConnections?.owner?.cacheScopeID,
                                             agentID: voiceSettingsAgentID)
        return voice.mode == .codexLive
            ? "\(VoiceConversationMode.codexLive.title) · \(voice.liveProvider.shortTitle)"
            : String(localized: "TTS · reads replies aloud")
    }

    func menuDetail(_ section: SettingsMenuSection) -> String {
        switch section {
        case .appearance: appearanceSummary
        case .voice: voiceDetail
        default: section.detail
        }
    }

    func settingsMenuRow(_ section: SettingsMenuSection) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            // In the person's color (Appearance), like every row's icon.
            BighelpIconTile(systemName: section.systemImage)
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
