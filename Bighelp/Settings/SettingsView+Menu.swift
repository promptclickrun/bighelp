import SwiftUI

/// Settings' first screen: the groups of pages, one row each.
extension SettingsView {
    func settingsMenuGroup(header: String? = nil, sections: [SettingsMenuSection]) -> some View {
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
        } header: {
            if let header { Text(header) }
        }
        .listRowBackground(theme.surface)
    }

    /// The first row: your photo and name, which open the page that changes them.
    var youRow: some View {
        Section {
            settingsLink(to: .you) {
                HStack(spacing: BighelpTokens.space12) {
                    AvatarView(stableID: UserIdentity.stableID, displayName: userIdentity.identity.displayName,
                               imageURL: userIdentity.avatarURL(), size: 44, kind: .person)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(userIdentity.identity.name.isEmpty ? String(localized: "Add your name") : userIdentity.identity.name)
                            .bighelpFont(.body, weight: .semibold)
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                        Text("Your name and photo in chats")
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: BighelpTokens.space8)
                    if BighelpPlatform.drawsOwnLinkChevron {
                        Image(systemName: "chevron.right")
                            .font(.bighelp(.footnote).weight(.semibold))
                            .foregroundStyle(theme.tertiaryText)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 60)
                .padding(.horizontal, BighelpMenuRowLayout.labelInset)
                .bighelpSettingsLinkLabel()
            }
            .bighelpSettingsLink()
            .accessibilityIdentifier("settings.you")
            .driveTarget("settings.you")
        }
        .listRowBackground(theme.surface)
    }

    /// The homes in use, as the Modes row says them.

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
        case .modes: settings.modesSummary
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
