import SwiftUI

/// Settings' first screen: you, your bots, this app, your computers, then help. Each row opens
/// one page, and its second line, when it has one, is a value.
extension SettingsView {
    func settingsMenuGroup(header: String? = nil, sections: [SettingsMenuSection]) -> some View {
        Section {
            ForEach(sections) { section in
                settingsMenuLink(section)
            }
        } header: {
            if let header { Text(header) }
        }
        .listRowBackground(theme.surface)
    }

    /// One page's row, by its `SettingsMenuSection`.
    func settingsMenuLink(_ section: SettingsMenuSection) -> some View {
        settingsLink(to: .section(section)) {
            rowLabel(section.title, detail: menuDetail(section), symbol: section.systemImage,
                     showsChevron: BighelpPlatform.drawsOwnLinkChevron)
                .bighelpSettingsLinkLabel()
        }
        .bighelpSettingsLink()
        .accessibilityValue(section == .appearance ? appearanceSummary : "")
        .accessibilityIdentifier(section.accessibilityIdentifier)
        .driveTarget(section.accessibilityIdentifier)
    }

    /// The first group: your name and photo, your plans' usage, and what other apps shared while
    /// it waits.
    var youSection: some View {
        Section {
            youRow
            if let usage, let onOpenRoute {
                Button { onOpenRoute(.usage) } label: {
                    rowLabel(String(localized: "Usage"), detail: usagePercent(usage).map { "\(Int($0.rounded()))%" },
                             symbol: "chart.bar.fill")
                }
                .bighelpSettingsButton()
                .accessibilityIdentifier("simple-bots.settings.usage")
                .driveTarget("simple-bots.settings.usage")
                .task { if usage.state == .idle { await usage.load(refresh: false) } }
            }
            if let pendingShares, PendingShareCenter.shared.waitingCount > 0 {
                NavigationLink {
                    settingsDone(PendingShareListView(center: .shared, context: pendingShares))
                } label: {
                    rowLabel(String(localized: "Shared with Bighelp"), detail: "\(PendingShareCenter.shared.waitingCount)",
                             symbol: "square.and.arrow.down.fill", showsChevron: BighelpPlatform.drawsOwnLinkChevron)
                        .bighelpSettingsLinkLabel()
                }
                .bighelpSettingsLink()
                .accessibilityIdentifier("simple-bots.settings.shared-with-bighelp")
            }
        }
        .listRowBackground(theme.surface)
    }

    /// The most used of your AI plans' limits, like the Usage page's tightest one.
    private func usagePercent(_ usage: ProviderUsageStore) -> Double? {
        usage.report?.providers.filter(\.activeInHermes).flatMap(\.windows).map(\.usedPercent).max()
    }

    /// Your photo and name, which open the page that changes them.
    private var youRow: some View {
        settingsLink(to: .you) {
            HStack(spacing: BighelpTokens.space12) {
                AvatarView(stableID: UserIdentity.stableID, displayName: userIdentity.identity.displayName,
                           imageURL: userIdentity.avatarURL(), size: 44, kind: .person)
                Text(userIdentity.identity.name.isEmpty ? String(localized: "Add your name") : userIdentity.identity.name)
                    .bighelpFont(.body, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
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

    /// The agent Voice settings opens on (`VoiceSettingsView`), so the row says what that page shows.
    var voiceSettingsAgentID: String? {
        agents.first { $0.id == agentDirectory?.selectedAgentID }?.id
            ?? agents.first(where: \.isDefault)?.id ?? agents.first?.id
    }

    /// The voice type that agent uses; Live names its provider (GPT-Live or Gemini Live).
    private var voiceDetail: String {
        let voice = settings.voicePreference(computer: workspaceConnections?.owner?.cacheScopeID,
                                             agentID: voiceSettingsAgentID)
        return voice.mode == .codexLive ? "\(voice.mode.title) · \(voice.liveProvider.shortTitle)" : voice.mode.title
    }

    /// A row's value, for the pages that have one to show.
    func menuDetail(_ section: SettingsMenuSection) -> String? {
        switch section {
        case .appearance: appearanceSummary

        case .voice: voiceDetail
        default: nil
        }
    }
}
