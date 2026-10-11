import SwiftUI

/// Reasoning as a slider: one round notch for each level the model offers, the
/// fill over the levels up to the chosen one (hiding their notches), and the
/// thumb on it. Tap a notch or drag; VoiceOver adjusts it, and on the Mac the
/// arrow keys step through the levels. Levels run left to right in every
/// language. Shows every label up to five levels; with more, the two ends, and
/// the chosen level is always named above the track.
struct BighelpReasoningSlider: View {
    let choices: [BighelpReasoningChoice]
    let selectedValue: String?
    let isEnabled: Bool
    let accessibilityIdentifier: String
    let onSelect: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @BighelpThemeReader private var theme: BighelpTheme
    #if targetEnvironment(macCatalyst)
    @FocusState private var isKeyboardFocused: Bool
    #endif

    private let trackHeight: CGFloat = 6
    private var thumbDiameter: CGFloat { BighelpTokens.scaled(26) }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reasoning").bighelpFont(.label, weight: .semibold)
                Spacer(minLength: BighelpTokens.space8)
                Text(selectedChoice?.label ?? "Choose a level")
                    .bighelpFont(.label, weight: .semibold)
                    .foregroundStyle(theme.action)
            }
            track
            labels
            if let detail = selectedChoice?.detail, !detail.isEmpty {
                Text(detail)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reasoning level")
        .accessibilityValue(selectedChoice?.label ?? "Not selected")
        .accessibilityAdjustableAction(adjust)
        .accessibilityIdentifier(accessibilityIdentifier)
        .opacity(isEnabled ? 1 : 0.48)
        .sensoryFeedback(.selection, trigger: selectedIndex)
        #if targetEnvironment(macCatalyst)
        .focusable(canAdjust)
        .focused($isKeyboardFocused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard canAdjust else { return .ignored }
            adjust(press.key == .rightArrow || press.key == .upArrow ? .increment : .decrement)
            return .handled
        }
        #endif
    }

    private var track: some View {
        GeometryReader { proxy in
            let inset = thumbDiameter / 2
            let usable = max(proxy.size.width - thumbDiameter, 1)
            let midY = proxy.size.height / 2
            let selected = selectedIndex ?? 0
            let thumbX = inset + usable * fraction(selected)
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(theme.secondaryText.opacity(0.18))
                    .frame(width: usable + trackHeight, height: trackHeight)
                    .position(x: proxy.size.width / 2, y: midY)
                // The notches sit under the fill, so only the levels past the chosen one show them.
                ForEach(choices.indices, id: \.self) { index in
                    Circle()
                        .fill(theme.secondaryText.opacity(0.42))
                        .frame(width: trackHeight, height: trackHeight)
                        .position(x: inset + usable * fraction(index), y: midY)
                }
                if selectedIndex != nil {
                    Capsule()
                        .fill(theme.action)
                        .frame(width: thumbX - inset + trackHeight, height: trackHeight)
                        .position(x: (inset + thumbX) / 2, y: midY)
                    // White in both modes, like the system slider, so it stands out on a dark track too.
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.18), radius: 3, y: 1)
                        .frame(width: thumbDiameter, height: thumbDiameter)
                        .position(x: thumbX, y: midY)
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard canAdjust else { return }
                        let index = nearestIndex(x: value.location.x, inset: inset, usable: usable)
                        if index != selectedIndex { onSelect(choices[index].value) }
                    }
            )
            .animation(reduceMotion ? nil : .snappy(duration: BighelpTokens.stateDuration), value: selectedIndex)
        }
        .frame(height: BighelpTokens.hitTarget)
        // Lowest to highest runs left to right in every language, like a progress bar.
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(canAdjust)
    }

    private var labels: some View {
        GeometryReader { proxy in
            let inset = thumbDiameter / 2
            let usable = max(proxy.size.width - thumbDiameter, 1)
            ForEach(shownLabelIndices, id: \.self) { index in
                let x = inset + usable * fraction(index)
                Text(choices[index].label)
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(index == selectedIndex ? theme.action : theme.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
                    .position(x: min(max(x, inset), proxy.size.width - inset), y: proxy.size.height / 2)
            }
        }
        .frame(height: BighelpTokens.scaled(18))
        .accessibilityHidden(true)
    }

    private var selectedIndex: Int? { choices.firstIndex { $0.value == selectedValue } }
    private var selectedChoice: BighelpReasoningChoice? { selectedIndex.map { choices[$0] } }
    private var canAdjust: Bool { isEnabled && choices.count > 1 }

    /// Every label fits up to five levels; with more, the two ends.
    private var shownLabelIndices: [Int] {
        guard choices.count > 5 else { return Array(choices.indices) }
        return [0, choices.count - 1]
    }

    private func fraction(_ index: Int) -> CGFloat {
        choices.count > 1 ? CGFloat(index) / CGFloat(choices.count - 1) : 0
    }

    private func nearestIndex(x: CGFloat, inset: CGFloat, usable: CGFloat) -> Int {
        let progress = min(max((x - inset) / usable, 0), 1)
        return Int((progress * CGFloat(choices.count - 1)).rounded())
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        guard canAdjust else { return }
        let current = selectedIndex ?? 0
        let next = switch direction {
        case .increment: min(current + 1, choices.count - 1)
        case .decrement: max(current - 1, 0)
        @unknown default: current
        }
        if next != selectedIndex { onSelect(choices[next].value) }
    }
}
