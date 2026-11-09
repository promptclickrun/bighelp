import SwiftUI

extension BighelpThinkingLook {
    /// Settings › Appearance › Thinking. Kept on this device, for every computer; a saved name
    /// this build doesn't know reads as the default look.
    static let storageKey = "bighelp.appearance.thinking-look"
}

extension BighelpThinkingLevel {
    /// Every level Hermes names, lowest first. A chat shows the ones its model offers.
    static let all: [BighelpThinkingLevel] = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        .map { BighelpThinkingLevel(reasoningValue: $0, title: $0) }

    /// A level as Hermes names it. `title` is what the host calls a level bighelp has no name for.
    init(reasoningValue value: String, title: String) {
        let names: (title: String, short: String)? = switch value {
        case "none": (String(localized: "Off"), String(localized: "Off"))
        case "minimal": (String(localized: "Minimal"), String(localized: "Min"))
        case "low": (String(localized: "Low"), String(localized: "Low"))
        case "medium": (String(localized: "Medium"), String(localized: "Med"))
        case "high": (String(localized: "High"), String(localized: "High"))
        case "xhigh": (String(localized: "X-High"), String(localized: "X-High"))
        case "max": (String(localized: "Max"), String(localized: "Max"))
        case "ultra": (String(localized: "Ultra"), String(localized: "Ultra"))
        default: nil
        }
        self.init(value: value, title: names?.title ?? title, shortTitle: names?.short ?? title)
    }
}

/// Settings › Appearance › Thinking: every look of the Thinking control, running. Each one drags
/// and taps like the real control and changes nothing on any computer. The buttons on top set
/// them all to one level to compare; the name line picks the look every chat uses.
struct ThinkingLookSettingsView: View {
    @AppStorage(BighelpThinkingLook.storageKey) private var selected = BighelpThinkingLook.defaultLook
    @State private var sharedLevel = "high"
    /// Levels the person dragged a look to since last setting them all.
    @State private var triedLevels: [BighelpThinkingLook: String] = [:]

    private static let presets = ["none", "medium", "xhigh", "ultra"]

    var body: some View {
        ScrollView {
            // Lazy, so a look off screen stops drawing.
            LazyVStack(alignment: .leading, spacing: BighelpTokens.space16) {
                presets
                ForEach(BighelpThinkingLook.allCases) { look in
                    card(look)
                }
            }
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.vertical, BighelpTokens.space16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(theme.canvas.ignoresSafeArea())
        .driveScrolls()
        .navigationTitle("Thinking")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("thinking-look")
    }

    /// Buttons, not a segmented picker: pressing the level they're all on has to put back any
    /// look that was dragged away from it.
    private var presets: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text("How the Thinking control looks in a chat. Drag one to try it.")
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            // Wraps at larger text; no button is ever cut off.
            BighelpFlowLayout(spacing: BighelpTokens.space8) {
                ForEach(Self.presets, id: \.self) { value in
                    let isOn = value == sharedLevel && triedLevels.isEmpty
                    Button {
                        sharedLevel = value
                        triedLevels = [:]
                    } label: {
                        Text(BighelpThinkingLevel(reasoningValue: value, title: value).title)
                            .bighelpFont(.label, weight: .semibold)
                            .foregroundStyle(isOn ? theme.actionForeground : theme.primaryText)
                            .padding(.horizontal, BighelpTokens.space16)
                            .frame(minHeight: BighelpTokens.scaled(36))
                            .background(isOn ? theme.action : theme.surface, in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Set all to \(BighelpThinkingLevel(reasoningValue: value, title: value).title)")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityIdentifier("thinking-look.set-all.\(value)")
                }
            }
        }
    }

    private func card(_ look: BighelpThinkingLook) -> some View {
        let isSelected = look == selected
        return VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Button {
                guard !isSelected else { return }
                selected = look
                BighelpHaptics.tap()
            } label: {
                HStack(alignment: .top, spacing: BighelpTokens.space12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: look.name)
                            .bighelpFont(.body, weight: .semibold)
                            .foregroundStyle(theme.primaryText)
                        Text(look.summary)
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: BighelpTokens.space8)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(isSelected ? theme.action : theme.tertiaryText)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: look.name))
            .accessibilityHint(isSelected ? "Your Thinking control" : "Makes this your Thinking control")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("thinking-look.pick.\(look.rawValue)")
            .driveTarget("thinking-look.pick.\(look.rawValue)")

            BighelpThinkingControl(
                levels: BighelpThinkingLevel.all,
                current: triedLevels[look] ?? sharedLevel,
                look: look,
                accent: theme.action,
                accessibilityIdentifier: "thinking-look.try.\(look.rawValue)"
            ) { triedLevels[look] = $0 }
        }
        .padding(BighelpTokens.space16)
        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius20))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius20)
                .stroke(isSelected ? theme.action : theme.border, lineWidth: isSelected ? 2 : BighelpTokens.hairline)
        }
        // The pick button and the control keep their own identifiers.
        .accessibilityElement(children: .contain)
    }

    @BighelpThemeReader private var theme: BighelpTheme
}
