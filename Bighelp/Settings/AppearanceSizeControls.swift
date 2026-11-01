import SwiftUI

/// Settings › Appearance › Text and buttons. Changes apply everywhere at once.
struct AppearanceSizeControls: View {
    @Bindable private var size = BighelpInterfaceSize.shared
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                label(String(localized: "Text size"), value: size.textSize.title)
                // Six sizes don't fit an iPhone as named segments; a slider, like Chat layout's.
                HStack(spacing: BighelpTokens.space12) {
                    Image(systemName: "textformat.size.smaller")
                        .accessibilityHidden(true)
                    Slider(value: textSizeValue, in: Self.textSizeRange, step: 1)
                        .tint(theme.action)
                        .accessibilityLabel("Text size")
                        .accessibilityValue(size.textSize.title)
                        .accessibilityIdentifier("appearance.text-size")
                    Image(systemName: "textformat.size.larger")
                        .accessibilityHidden(true)
                }
                .foregroundStyle(theme.primaryText)
                .frame(minHeight: BighelpTokens.hitTarget)
            }
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                label(String(localized: "Button size"), value: size.buttonSize.title)
                Picker("Button size", selection: $size.buttonSize) {
                    ForEach(BighelpButtonSize.allCases) { step in
                        Text(step.title).tag(step)
                    }
                }
                .bighelpSegmentedPicker()
                .accessibilityIdentifier("appearance.button-size")
                Text(footnote)
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.snappy, value: size.textSize)
        .animation(.snappy, value: size.buttonSize)
    }

    private func label(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).bighelpFont(.label).foregroundStyle(theme.primaryText)
            Spacer()
            Text(value).font(.bighelp(.caption)).foregroundStyle(theme.secondaryText)
        }
    }

    private static let textSizeRange = Double(BighelpTextSize.small.rawValue)...Double(BighelpTextSize.largest.rawValue)

    private var textSizeValue: Binding<Double> {
        Binding(get: { Double(size.textSize.rawValue) },
                set: { size.textSize = BighelpTextSize(rawValue: Int($0.rounded())) ?? .platformDefault })
    }

    private var footnote: String {
        #if targetEnvironment(macCatalyst)
        String(localized: "Buttons include the message box and avatars. ⌘+ and ⌘− also change the text size.")
        #else
        String(localized: "Text size adds to your device's own text size. Buttons include the message box and avatars.")
        #endif
    }
}
