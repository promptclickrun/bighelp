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
            Button {
                isPersonalitiesPresented = true
            } label: {
                rowLabel("Personalities", detail: personalityDetail, symbol: "theatermasks.fill", tint: Color(hex: "B7356F"))
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .accessibilityIdentifier("profile.personalities")
        } header: {
            Text("Assistants")
        }
        .listRowBackground(theme.surface)
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
            }
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
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
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
    }
}
