import SwiftUI

/// Picks how hard the agent thinks: a "Thinking" header naming the level, a look you can tap and
/// drag, and one tappable short label per level under it. A sideways drag follows the finger with a
/// tick per level and sends one change on release; a vertical swipe scrolls whatever holds it.
/// VoiceOver adjusts it like a slider, the Mac's arrow keys step one level, and the largest text
/// sizes get a plain list. Levels run left to right in every language. Adapted from hermex (MIT).
struct BighelpThinkingControl: View {
    let levels: [BighelpThinkingLevel]
    let current: String?
    let look: BighelpThinkingLook
    let accent: Color
    let automatic: BighelpThinkingAutomatic?
    let isDisabled: Bool
    /// Holds the animation while something covers the control.
    let isCovered: Bool
    let accessibilityIdentifier: String
    let onCommit: (String) -> Void

    @BighelpThemeReader private var theme: BighelpTheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var drag = ThinkingSliderDrag()
    @State private var ticks = 0
    #if targetEnvironment(macCatalyst)
    @FocusState private var isKeyboardFocused: Bool
    #endif

    init(
        levels: [BighelpThinkingLevel], current: String?, look: BighelpThinkingLook, accent: Color,
        automatic: BighelpThinkingAutomatic? = nil, isDisabled: Bool = false, isCovered: Bool = false,
        accessibilityIdentifier: String = "thinking.control", onCommit: @escaping (String) -> Void
    ) {
        self.levels = levels
        self.current = current
        self.look = look
        self.accent = accent
        self.automatic = automatic
        self.isDisabled = isDisabled
        self.isCovered = isCovered
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onCommit = onCommit
    }

    private var isAutomatic: Bool { automatic?.isOn == true }

    /// While the automatic level is on, no point on the ladder is current, so the thumb rests at the
    /// bottom and any level a person picks is a change.
    private var ladder: ThinkingLadder {
        ThinkingLadder(levels: levels.map(\.value), current: isAutomatic ? nil : current)
    }

    /// The level to name: the finger's while one is down, else the chat's.
    private var shownIndex: Int? {
        drag.position.map(ladder.index(atPosition:)) ?? ladder.currentIndex
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            levelList
        } else {
            slider
        }
    }

    private var slider: some View {
        let ladder = ladder
        return VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                Text("Thinking")
                    .bighelpFont(.label)
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: BighelpTokens.space8)
                if let automatic { automaticButton(automatic) }
                // While Auto is on, its filled button is the value.
                if automatic?.isOn != true {
                    Text(verbatim: valueTitle(ladder))
                        .bighelpFont(.label, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                }
            }
            // A look draws left to right and reads touches the same way, so its labels keep that
            // order too, in right-to-left languages as well.
            VStack(spacing: BighelpTokens.space8) {
                ThinkingInteractiveTrack(look: look, ladder: ladder, accent: accent, isPaused: isCovered, drag: $drag) { index in
                    if let level = ladder.commit(at: index) { onCommit(level) }
                }
                // A new look starts from fresh state, not another look's particles.
                .id(look)
                labels(ladder)
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .opacity(isDisabled ? 0.5 : 1)
        .allowsHitTesting(!isDisabled)
        .sensoryFeedback(.selection, trigger: ticks)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Thinking"))
        .accessibilityValue(Text(verbatim: valueTitle(ladder)))
        .accessibilityAdjustableAction { direction in
            step(direction == .increment ? 1 : -1)
        }
        .modifier(AutomaticAccessibilityAction(automatic: automatic, isDisabled: isDisabled))
        .accessibilityIdentifier(accessibilityIdentifier)
        #if targetEnvironment(macCatalyst)
        .focusable(!isDisabled)
        .focused($isKeyboardFocused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard !isDisabled else { return .ignored }
            step(press.key == .rightArrow || press.key == .upArrow ? 1 : -1)
            return .handled
        }
        #endif
    }

    /// Hermes' automatic level, beside the value: filled while it's on.
    private func automaticButton(_ automatic: BighelpThinkingAutomatic) -> some View {
        // Auto that is already on has nothing to send: Hermes refuses a second one.
        Button { if !automatic.isOn { automatic.select() } } label: {
            Text(verbatim: automatic.title)
                .bighelpFont(.metadata, weight: .semibold)
                .lineLimit(1)
                .foregroundStyle(automatic.isOn ? theme.actionForeground : theme.action)
                .padding(.horizontal, BighelpTokens.space8)
                .padding(.vertical, 3)
                .background {
                    Capsule().fill(automatic.isOn ? theme.action : Color.clear)
                }
                .overlay {
                    Capsule().strokeBorder(theme.action, lineWidth: 1)
                }
                .frame(minHeight: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func labels(_ ladder: ThinkingLadder) -> some View {
        let shown = shownIndex
        return HStack(spacing: 0) {
            ForEach(Array(ladder.levels.enumerated()), id: \.offset) { index, level in
                Button { send(index, on: ladder) } label: {
                    Text(verbatim: shortTitle(for: level))
                        .bighelpFont(.metadata, weight: index == shown ? .semibold : .regular)
                        .foregroundStyle(index == shown ? theme.primaryText : theme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func valueTitle(_ ladder: ThinkingLadder) -> String {
        if let position = drag.position { return title(for: ladder.levels[ladder.index(atPosition: position)]) }
        if let automatic, automatic.isOn { return automatic.title }
        return ladder.currentIndex.map { title(for: ladder.levels[$0]) } ?? String(localized: "Default")
    }

    /// A level the host holds that the model's list doesn't name shows as itself.
    private func title(for value: String) -> String {
        levels.first { $0.value == value }?.title ?? value
    }

    private func shortTitle(for value: String) -> String {
        levels.first { $0.value == value }?.shortTitle ?? value
    }

    private func send(_ index: Int, on ladder: ThinkingLadder) {
        guard let level = ladder.commit(at: index) else { return }
        ticks += 1
        onCommit(level)
    }

    /// VoiceOver's swipe or an arrow key: one level along.
    private func step(_ step: Int) {
        guard !isDisabled else { return }
        let ladder = ladder
        if let next = ladder.adjusted(by: step), let level = ladder.commit(at: next) {
            ticks += 1
            onCommit(level)
        }
    }

    /// The largest text sizes: no track holds names that large, so every level is its own row.
    private var levelList: some View {
        let ladder = ladder
        return VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text("Thinking")
                .bighelpFont(.label, weight: .semibold)
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            if let automatic {
                listRow(title: automatic.title, isSelected: automatic.isOn, action: automatic.select)
            }
            ForEach(Array(ladder.levels.enumerated()), id: \.offset) { index, level in
                listRow(title: title(for: level), isSelected: index == ladder.currentIndex) {
                    if let level = ladder.commit(at: index) { onCommit(level) }
                }
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func listRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(verbatim: title)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: BighelpTokens.space8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(theme.action)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The automatic level as a VoiceOver action, since the control reads as one adjustable element and
/// hides the button in its header. Branches only on whether there is one, which a call site never
/// changes, so turning it on or off keeps the track's running state.
private struct AutomaticAccessibilityAction: ViewModifier {
    let automatic: BighelpThinkingAutomatic?
    let isDisabled: Bool

    func body(content: Content) -> some View {
        if let automatic {
            content.accessibilityAction(named: Text(verbatim: automatic.title)) {
                guard !isDisabled, !automatic.isOn else { return }
                automatic.select()
            }
        } else {
            content
        }
    }
}
