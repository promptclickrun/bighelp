import SwiftUI

extension EnvironmentValues {
    /// Mirrors Settings › Nerd Mode so any surface can hide technical detail
    /// (token context, subagents, project diffs) from everyday use.
    @Entry var nerdModeEnabled = false
}

/// Everyday settings stay on the first page. Host administration (files,
/// gateways, plugins, logs, ...) is revealed only by the Nerd Mode toggle.
extension SettingsView {
    var assistantBasics: some View {
        Section {
            if let onOpenWorkspaceDestination {
                routeRow("Default model", detail: "The model new chats start with",
                         symbol: "cpu", identifier: "settings.default-model") {
                    onOpenWorkspaceDestination(.models)
                }
                routeRow("AI providers", detail: "Sign in to model providers or add API keys",
                         symbol: "key.fill", tint: Color(hex: "F28B32"), identifier: "settings.providers") {
                    onOpenWorkspaceDestination(.keys)
                }
            }
            if let composio = composioApps?() {
                NavigationLink {
                    settingsDone(AppsHubView(native: connectorApps?() ?? nil, composio: composio))
                } label: {
                    rowLabel("Apps", detail: "Let agents use your email, notes and more",
                             symbol: "app.connected.to.app.below.fill", tint: Color(hex: "3A7BD5"))
                        .bighelpSettingsLinkLabel()
                }
                .bighelpSettingsLink()
                .accessibilityIdentifier("settings.apps")
            } else if let connectorApps, let apps = connectorApps() {
                NavigationLink {
                    settingsDone(ConnectorAppsView(model: apps))
                } label: {
                    rowLabel("Apps", detail: "Let agents use your email, notes and more",
                             symbol: "app.connected.to.app.below.fill", tint: Color(hex: "3A7BD5"))
                        .bighelpSettingsLinkLabel()
                }
                .bighelpSettingsLink()
                .accessibilityIdentifier("settings.apps")
            }
            if let teamworkModel {
                TeamworkToggle(model: teamworkModel) { detail in
                    rowLabel("Teamwork", detail: detail, symbol: "person.3.fill", tint: Color(hex: "2E9E6B"),
                             showsChevron: false)
                }
                .bighelpSettingsRowInsets()
            }
            Button {
                isPersonalitiesPresented = true
            } label: {
                rowLabel("Personalities", detail: personalityDetail, symbol: "theatermasks.fill", tint: Color(hex: "B7356F"))
            }
            .bighelpSettingsButton()
            .accessibilityIdentifier("profile.personalities")
        } header: {
            Text("Assistants")
        }
        .listRowBackground(theme.surface)
        // Asked once per Settings visit; the switch reads and saves through the plugin.
        .task { if teamworkModel == nil { teamworkModel = teamwork?() } }
    }

    private var personalityDetail: String {
        guard let active = personalities.catalog?.activeName, !active.isEmpty else { return "How agents sound" }
        return active.capitalized
    }

    var nerdModeToggle: some View {
        Section {
            Toggle(isOn: $settings.nerdModeEnabled) {
                HStack(spacing: BighelpTokens.space12) {
                    BighelpIconTile(systemName: "wrench.adjustable.fill", tint: .gray)
                    settingLabel("Nerd Mode", detail: "Hermes tools and extra chat settings")
                }
                .padding(.horizontal, BighelpMenuRowLayout.labelInset)
            }
            .bighelpMacSettingsRowInsets()
            .accessibilityIdentifier("settings.nerd-mode")
        }
        .listRowBackground(theme.surface)
    }

    /// Nerd Mode: the host's own tools, with the ones people come for most
    /// (updating Hermes, restarting its gateway) one tap away.
    var hermesSection: some View {
        Section {
            if let onOpenRoute {
                routeRow("Hermes tools", detail: "Files, skills, memory, logs and more",
                         symbol: "square.grid.2x2.fill", identifier: "settings.hermes-tools") {
                    onOpenRoute(.workspaceHub)
                }
            }
        } header: {
            Text("Hermes")
        }
        .listRowBackground(theme.surface)
    }

    func routeRow(_ title: String, detail: String, symbol: String, tint: Color? = nil,
                  identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            rowLabel(title, detail: detail, symbol: symbol, tint: tint)
        }
        .bighelpSettingsButton()
        .accessibilityIdentifier(identifier)
    }

    func rowLabel(_ title: String, detail: String, symbol: String, tint: Color? = nil,
                  showsChevron: Bool = true) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            BighelpIconTile(systemName: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                Text(detail)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
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
    /// across the row and lights up under the pointer, with the ☰ menu's row layout;
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

    /// The row insets of a Settings row with an icon tile; on the Mac, the ☰ menu's.
    func bighelpSettingsRowInsets() -> some View {
        listRowInsets(BighelpPlatform.isMac
            ? BighelpMenuRowLayout.insets
            : EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    /// The ☰ menu's row insets on the Mac, so a toggle's or the profile row's icon lines up
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
