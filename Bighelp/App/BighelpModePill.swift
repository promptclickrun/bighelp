import SwiftUI

/// Settings › Experience › Unified Mode Toggle: Bots, Chat and Code in one compact pill at the top
/// of each home, as tall as the header's glass buttons. The mode showing sits in a darker capsule.
struct BighelpModePill: View {
    let modeSwitch: BighelpModeSwitch

    @BighelpThemeReader private var theme

    private static let inset: CGFloat = 3

    var body: some View {
        HStack(spacing: 0) {
            ForEach(modeSwitch.modes) { mode in
                segment(mode)
            }
        }
        .padding(Self.inset)
        .bighelpNavigationGlass(in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode")
        .accessibilityIdentifier("mode.pill")
    }

    private func segment(_ mode: BighelpMode) -> some View {
        let isOn = mode == modeSwitch.current
        return Button {
            if !isOn { modeSwitch.select(mode) }
        } label: {
            Text(mode.title)
                .font(.bighelp(.subheadline, weight: .semibold))
                .foregroundStyle(isOn ? theme.primaryText : theme.primaryText.opacity(0.75))
                .lineLimit(1)
                .padding(.horizontal, BighelpTokens.scaled(13))
                .frame(height: HeaderButtonMetrics.glass - Self.inset * 2)
                .background {
                    if isOn {
                        Capsule()
                            .fill(selectedFill)
                            .shadow(color: .black.opacity(theme.isDarkPalette ? 0 : 0.12), radius: 2, y: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .bighelpPlainButtonStyle(.capsule)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("mode.pill.\(mode.rawValue)")
    }

    /// Dark: nearly black, sunk into the glass. Light: a white page on the gray track.
    private var selectedFill: Color {
        theme.isDarkPalette ? Color.black.opacity(0.6) : theme.canvas
    }
}
