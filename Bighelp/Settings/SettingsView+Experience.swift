import SwiftUI

/// Settings › Modes: the home a launch opens in (Bots, Chat or Code), Code mode's own switch, and
/// the switcher that puts the modes at the top of each home. The chat switcher is in Settings › Chat.
extension SettingsView {
    @ViewBuilder
    var experienceSection: some View {
        Section {
            HomeExperienceModeCards(selected: settings.homeMode) { mode in
                withAnimation(.snappy(duration: BighelpTokens.stateDuration)) {
                    settings.selectHomeMode(mode)
                }
            }
            .listRowInsets(EdgeInsets(top: BighelpTokens.space4, leading: 0, bottom: BighelpTokens.space8, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            Text("Home experience")
        }

        Section {
            // Code can stay on beside a Chat or Bots home: ☰ and the switcher reach it.
            Toggle(isOn: Binding(get: { settings.codeModeEnabled }, set: { settings.setCodeMode($0) })) {
                HStack(spacing: BighelpTokens.space12) {
                    BighelpIconTile(systemName: "chevron.left.forwardslash.chevron.right")
                    settingLabel(String(localized: "Code mode"), detail: String(localized: "Fire off coding chats against your projects."))
                }
                .padding(.horizontal, BighelpMenuRowLayout.labelInset)
            }
            .bighelpMacSettingsRowInsets()
            .accessibilityIdentifier("settings.code-mode")

            Toggle(isOn: $settings.unifiedModeToggleEnabled) {
                HStack(spacing: BighelpTokens.space12) {
                    BighelpIconTile(systemName: "capsule.lefthalf.filled")
                    settingLabel(String(localized: "Header mode switcher"),
                                 detail: String(localized: "Switch between Bots, Chat and Code from the top of each home."))
                }
                .padding(.horizontal, BighelpMenuRowLayout.labelInset)
            }
            .bighelpMacSettingsRowInsets()
            .accessibilityIdentifier("settings.unified-mode-toggle")
        }
        .listRowBackground(theme.surface)
    }
}

private struct HomeExperienceModeCards: View {
    let selected: BighelpMode
    let onSelect: (BighelpMode) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast
    @BighelpThemeReader private var theme

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: BighelpTokens.space8))
            : AnyLayout(HStackLayout(spacing: BighelpTokens.space8))

        layout {
            ForEach(BighelpMode.allCases) { mode in
                card(mode)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.modes.picker")
    }

    private func card(_ mode: BighelpMode) -> some View {
        let isSelected = mode == selected
        let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)

        return Button {
            onSelect(mode)
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    HStack(spacing: BighelpTokens.space12) {
                        iconWell(mode, isSelected: isSelected)
                        VStack(alignment: .leading, spacing: 2) {
                            titleText(mode)
                            detailText(mode, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(spacing: BighelpTokens.space8) {
                        iconWell(mode, isSelected: isSelected)
                        VStack(spacing: 3) {
                            titleText(mode)
                            detailText(mode, alignment: .center)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(.horizontal, BighelpTokens.space8)
            .padding(.vertical, BighelpTokens.space12)
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
            .background(
                shape.fill(isSelected ? theme.action.opacity(theme.isDarkPalette ? 0.16 : 0.10) : theme.surface)
            )
            .overlay {
                shape.strokeBorder(
                    isSelected ? theme.action : (contrast == .increased ? theme.primaryText : theme.border),
                    lineWidth: isSelected ? 1.75 : BighelpTokens.hairline
                )
            }
            .contentShape(shape)
        }
        .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mode.title)
        .accessibilityValue(mode.shortDetail)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.mode.\(mode.rawValue)")
        .driveTarget("settings.mode.\(mode.rawValue)")
    }

    private func iconWell(_ mode: BighelpMode, isSelected: Bool) -> some View {
        Image(systemName: mode.systemImage)
            .font(.bighelp(.subheadline, weight: .semibold))
            .foregroundStyle(isSelected ? theme.actionForeground : theme.primaryText)
            .frame(width: BighelpTokens.scaled(32), height: BighelpTokens.scaled(32))
            .background(
                RoundedRectangle(cornerRadius: BighelpTokens.radius8 + 2, style: .continuous)
                    .fill(isSelected ? theme.action : theme.raisedSurface)
            )
            .accessibilityHidden(true)
    }

    private func titleText(_ mode: BighelpMode) -> some View {
        Text(mode.title)
            .font(.bighelp(.subheadline, weight: .bold))
            .foregroundStyle(theme.primaryText)
            .lineLimit(1)
    }

    private func detailText(_ mode: BighelpMode, alignment: TextAlignment) -> some View {
        Text(mode.shortDetail)
            .font(.bighelp(.caption2))
            .foregroundStyle(theme.secondaryText)
            .multilineTextAlignment(alignment)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
            .fixedSize(horizontal: false, vertical: true)
    }
}
