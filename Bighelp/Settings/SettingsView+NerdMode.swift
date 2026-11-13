import SwiftUI

extension EnvironmentValues {
    /// Mirrors Settings › Advanced options (Nerd Mode) so any surface can hide technical detail
    /// (token context, subagents, project diffs) from everyday use.
    @Entry var nerdModeEnabled = false
}

/// Settings' first page past you: your bots and what they use, then (last) Help & feedback and
/// the Advanced options switch, which shows the technical groups at the end of each page.
extension SettingsView {
    var yourBotsSection: some View {
        Section {
            if let onOpenWorkspaceDestination {
                // Default model and AI providers are one page.
                routeRow(String(localized: "Models"), symbol: "cpu", identifier: "settings.default-model") {
                    onOpenWorkspaceDestination(.models)
                }
            }
            // Always here: Device access works before any computer is connected.
            settingsLink(to: .apps) {
                rowLabel(String(localized: "Apps & skills"), symbol: "app.connected.to.app.below.fill",
                         showsChevron: BighelpPlatform.drawsOwnLinkChevron)
                    .bighelpSettingsLinkLabel()
            }
            .bighelpSettingsLink()
            .accessibilityIdentifier("settings.apps")
            .driveTarget("settings.apps")
            settingsMenuLink(.voice)
            Button {
                isPersonalitiesPresented = true
            } label: {
                rowLabel(String(localized: "Personality"), detail: personalityDetail, symbol: "theatermasks.fill")
            }
            .bighelpSettingsButton()
            .accessibilityIdentifier("profile.personalities")
            if let teamworkModel {
                TeamworkToggle(model: teamworkModel) { detail in
                    rowLabel(String(localized: "Teamwork"), detail: detail, symbol: "person.3.fill",
                             showsChevron: false)
                }
                .bighelpSettingsRowInsets()
            }
        } header: {
            Text("Your bots")
        }
        .listRowBackground(theme.surface)
        // Asked once per computer while Settings shows; the switch reads and saves through the plugin.
        // Keyed by the computer, never the owner: a reconnect keeps it, a switch from a computer's
        // row makes a new one, and a moment without a connection keeps the one it has.
        .task(id: workspaceConnections?.owner?.cacheScopeID) { refreshTeamworkModel() }
    }

    private func refreshTeamworkModel() {
        let scope = workspaceConnections?.owner?.cacheScopeID
        guard teamworkModel == nil || (scope != nil && scope != teamworkScope) else { return }
        teamworkModel = teamwork?()
        teamworkScope = scope
    }

    /// The personality in use; nothing until one is.
    private var personalityDetail: String? {
        guard let active = personalities.catalog?.activeName, !active.isEmpty else { return nil }
        return active.capitalized
    }

    var helpAndAdvancedSection: some View {
        Section {
            settingsMenuLink(.help)
            Toggle(isOn: $settings.nerdModeEnabled) {
                HStack(spacing: BighelpTokens.space12) {
                    BighelpIconTile(systemName: "wrench.adjustable.fill")
                    settingTitle(String(localized: "Advanced options"))
                }
                .padding(.horizontal, BighelpMenuRowLayout.labelInset)
            }
            .bighelpMacSettingsRowInsets()
            .accessibilityIdentifier("settings.nerd-mode")
        }
        .listRowBackground(theme.surface)
    }

    func routeRow(_ title: String, detail: String? = nil, symbol: String, tint: Color? = nil,
                  identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            rowLabel(title, detail: detail, symbol: symbol, tint: tint)
        }
        .bighelpSettingsButton()
        .accessibilityIdentifier(identifier)
    }

    /// A root row: its icon tile, its title and, when it has one, its value under it.
    func rowLabel(_ title: String, detail: String? = nil, symbol: String, tint: Color? = nil,
                  showsChevron: Bool = true) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            BighelpIconTile(systemName: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                if let detail {
                    Text(detail)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: BighelpTokens.space8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 52)
        .contentShape(.rect)
        .padding(.horizontal, BighelpMenuRowLayout.labelInset)
    }
}

extension View {
    /// A Settings row with an icon tile that runs an action. On the Mac it takes the click
    /// across the row and lights up under the pointer, with the sidebar's row layout;
    /// elsewhere it's a plain button with the page's row insets.
    func bighelpSettingsButton() -> some View {
        bighelpPlainButtonStyle(BighelpMenuRowLayout.outline, padding: BighelpMenuRowLayout.highlightPadding)
            .bighelpSettingsRowInsets()
    }

    /// A Settings row that is a `NavigationLink`: the link keeps its own style (a button style
    /// doesn't reach it), so the Mac's hover goes on its label with `bighelpSettingsLinkLabel`.
    /// On the Mac the List's own chevron, outside the row, gives way to the label's, in line
    /// with the button rows' (`BighelpPlatform.drawsOwnLinkChevron`).
    @ViewBuilder
    func bighelpSettingsLink() -> some View {
        #if targetEnvironment(macCatalyst) && compiler(>=6.2)
        // In the iOS 26 SDK; available from Catalyst 17, so no runtime check.
        bighelpSettingsRowInsets().navigationLinkIndicatorVisibility(.hidden)
        #else
        bighelpSettingsRowInsets()
        #endif
    }

    /// The label of a `bighelpSettingsLink` row: on the Mac it lights up under the pointer
    /// and takes the click across the row, like `bighelpSettingsButton`.
    func bighelpSettingsLinkLabel() -> some View {
        bighelpPointer(BighelpMenuRowLayout.outline, padding: BighelpMenuRowLayout.highlightPadding)
    }

    /// The row insets of a Settings row with an icon tile; on the Mac, the sidebar's.
    func bighelpSettingsRowInsets() -> some View {
        listRowInsets(BighelpPlatform.isMac
            ? BighelpMenuRowLayout.insets
            : EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    /// The sidebar's row insets on the Mac, so a toggle's or the profile row's icon lines up
    /// with the other rows'. Elsewhere the row keeps the List's own: these labels set no
    /// height, and without the List's room their wrapped text touched the card's edges.
    @ViewBuilder
    func bighelpMacSettingsRowInsets() -> some View {
        #if targetEnvironment(macCatalyst)
        listRowInsets(BighelpMenuRowLayout.insets)
        #else
        self
        #endif
    }
}
