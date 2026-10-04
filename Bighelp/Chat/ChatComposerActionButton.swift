import SwiftUI
import UIKit

enum MidSessionSendPresentation {
    static let unlockHoldDuration = ChatComposerInteractionPolicy.sendOptionsLongPressDuration

    static func alternatives(
        defaultBehavior: MidSessionChatBehavior
    ) -> [MidSessionChatBehavior] {
        MidSessionChatBehavior.allCases.filter { $0 != defaultBehavior }
    }

    static func unlockProgress(elapsed: TimeInterval) -> Double {
        guard unlockHoldDuration > 0 else { return 1 }
        return min(max(elapsed / unlockHoldDuration, 0), 1)
    }
}

enum AdaptiveComposerActionPresentation {
    static let tintOpacity = 0.82
    /// Painted circle inside the 44pt hit area, matching the attach control.
    static var diameter: CGFloat { ComposerFieldMetrics.controlDiameter }
    /// Touches this far outside the button still count: Send and Voice sit at
    /// the screen's edge, where fingers land a little off.
    static let hitSlop: CGFloat = 8
    /// A tap may drift this far before it stops being a tap. SwiftUI's own tap
    /// allows much less, so a slightly moving finger missed Send.
    static let tapSlop: CGFloat = 28
}

struct AdaptiveComposerActionButton: View {
    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatSurfaceCapabilities) private var capabilities
    let action: ChatComposerPrimaryAction
    private var effectiveAction: ChatComposerPrimaryAction { capabilities.resolve(action) }
    let isBusy: Bool
    let canSend: Bool
    let canStop: Bool
    let onVoice: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let defaultMidSessionBehavior: MidSessionChatBehavior?
    let onMidSessionSend: (MidSessionChatBehavior) -> Void
    var allowedMidSessionBehaviors: [MidSessionChatBehavior] = [.steer, .queued, .interruptAndSend]
    /// Plain-language reason Send is unavailable (read by VoiceOver).
    var unavailableReason: String? = nil
    /// Bumped by Command-Return on a keyboard: the send choices while the
    /// agent works (or a plain send when there are none).
    var keyboardSendOptionsRequest = 0
    /// The keyboard's send choices closed (picked or dismissed).
    var onKeyboardSendOptionsClosed: (() -> Void)? = nil

    @State private var isMidSessionOptionsPresented = false
    @State private var unlockProgress: Double = 0
    @State private var holdThresholdReached = false
    @State private var optionsAppeared = false
    @State private var touchIsActive = false
    @State private var touchActiveWhenOptionsAppeared = false
    @State private var optionsFromKeyboard = false
    /// True only while a finger is down; resets itself on release or cancel.
    @GestureState private var isHolding = false
    private let holdObservationEnabled = ProcessInfo.processInfo.arguments.contains("-observe-send-hold")

    var body: some View {
        Group {
            if midSessionAlternatives.isEmpty {
                Button(action: perform) {
                    actionContent
                        .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        .contentShape(.interaction,
                                      Rectangle().inset(by: -AdaptiveComposerActionPresentation.hitSlop))
                        .contentShape(.accessibility, Rectangle())
                }
                .buttonStyle(.bighelpPress)
                .disabled(!isEnabled)
            } else {
                actionContent
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(.interaction,
                                  Rectangle().inset(by: -AdaptiveComposerActionPresentation.hitSlop))
                    .contentShape(.accessibility, Rectangle())
                    .gesture(midSessionHoldGesture)
                    .simultaneousGesture(
                        // Released before the hold unlocked, without wandering off: a tap.
                        DragGesture(minimumDistance: 0).onEnded { value in
                            let drift = hypot(value.translation.width, value.translation.height)
                            guard isEnabled, !holdThresholdReached,
                                  drift <= AdaptiveComposerActionPresentation.tapSlop else { return }
                            perform()
                        }
                    )
                    .accessibilityAddTraits(.isButton)
                    #if targetEnvironment(macCatalyst)
                    // A mouse rarely finds press-and-hold; right-click offers the same choices.
                    .contextMenu { midSessionChoicesMenu }
                    #endif
                    .disabled(!isEnabled)
            }
        }
        .overlay {
            Circle()
                .trim(from: 0, to: unlockProgress)
                .stroke(
                    uiV3Enabled
                        ? (effectiveAction == .stop
                            ? theme.danger
                            : theme.action)
                        : theme.actionForeground,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(
                    width: AdaptiveComposerActionPresentation.diameter + 6,
                    height: AdaptiveComposerActionPresentation.diameter + 6
                )
                .opacity(unlockProgress > 0 ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .accessibilityIdentifier("chat.send.unlock-progress")
        }
        #if targetEnvironment(macCatalyst)
        // The Mac shows the choices in a popover on Send, like its other small choices.
        .popover(isPresented: $isMidSessionOptionsPresented, arrowEdge: .top) {
            midSessionOptions
                .frame(width: 380)
                .fixedSize(horizontal: false, vertical: true)
                .presentationCompactAdaptation(.popover)
                .onDisappear(perform: midSessionOptionsClosed)
        }
        #else
        .sheet(isPresented: $isMidSessionOptionsPresented, onDismiss: midSessionOptionsClosed) {
            midSessionOptions
                .presentationDetents([.height(optionsFromKeyboard ? 380 : 300)])
                .modifier(FittedSheetSizing())
                .presentationDragIndicator(.visible)
        }
        #endif
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
        .accessibilityActions {
            ForEach(midSessionAlternatives) { behavior in
                Button("\(behavior.title): \(behavior.detail)") {
                    onMidSessionSend(behavior)
                }
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
        // A tap or a hold let go early must not leave the unlock ring drawn.
        .onChange(of: isHolding) { _, holding in
            guard !holding, !holdThresholdReached else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { unlockProgress = 0 }
        }
        .onChange(of: keyboardSendOptionsRequest) { _, _ in
            guard isEnabled, effectiveAction == .send else { return }
            guard !midSessionAlternatives.isEmpty else { return perform() }
            optionsFromKeyboard = true
            isMidSessionOptionsPresented = true
        }
        // Confirms the mid-session hold unlocked before the options sheet rises.
        .sensoryFeedback(.impact(weight: .medium), trigger: holdThresholdReached) { _, reached in reached }
    }

    private var midSessionOptions: some View {
        MidSessionSendOptionsSheet(
            defaultBehavior: defaultMidSessionBehavior ?? .steer,
            alternatives: midSessionAlternatives,
            fromKeyboard: optionsFromKeyboard,
            onSelect: onMidSessionSend
        )
        .onAppear {
            guard holdObservationEnabled else { return }
            optionsAppeared = true
            touchActiveWhenOptionsAppeared = touchIsActive
        }
    }

    private func midSessionOptionsClosed() {
        holdThresholdReached = false
        touchIsActive = false
        unlockProgress = 0
        optionsAppeared = false
        touchActiveWhenOptionsAppeared = false
        if optionsFromKeyboard { onKeyboardSendOptionsClosed?() }
        optionsFromKeyboard = false
    }

    #if targetEnvironment(macCatalyst)
    /// Every way to send while the agent works, the usual one first.
    @ViewBuilder
    private var midSessionChoicesMenu: some View {
        if let defaultMidSessionBehavior {
            ForEach([defaultMidSessionBehavior] + midSessionAlternatives) { behavior in
                Button {
                    onMidSessionSend(behavior)
                } label: {
                    Text(behavior.title)
                    Text(behavior.detail)
                }
                .accessibilityIdentifier("chat.send.menu.\(behavior.rawValue)")
            }
        }
    }
    #endif

    @ViewBuilder
    private var actionContent: some View {
        let content = ZStack {
            Image(systemName: actionSystemImage)
                .font(.system(size: 16, weight: .bold))
                .contentTransition(.symbolEffect(.replace.downUp))
                .opacity(isBusy ? 0 : 1)
            BighelpThinkingOrb(
                scenario: .composing,
                scale: .inline,
                surface: uiV3Enabled ? .automatic : theme.actionThinkingOrbSurface
            )
                .accessibilityHidden(true)
                .opacity(isBusy ? 1 : 0)
        }
        .foregroundStyle(actionForeground)
        .frame(width: AdaptiveComposerActionPresentation.diameter, height: AdaptiveComposerActionPresentation.diameter)
        .animation(reduceMotion ? nil : .snappy(duration: BighelpTokens.stateDuration), value: actionSystemImage)
        .animation(reduceMotion ? nil : .easeInOut(duration: BighelpTokens.stateDuration), value: isBusy)
        content
            .background { actionBackground }
            .opacity(isEnabled || isBusy ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: BighelpTokens.stateDuration), value: isEnabled)
    }

    private var actionForeground: Color {
        switch effectiveAction {
        case .voice: theme.primaryText
        case .send: theme.actionForeground
        case .stop: .white
        }
    }

    /// Solid circles for Send (accent) and Stop (danger); the voice shortcut shown while the draft
    /// is empty is glass in the quiet incoming color.
    @ViewBuilder
    private var actionBackground: some View {
        switch effectiveAction {
        case .voice:
            // Glass like the message box beside it; Send and Stop stay solid so they read as actions.
            Color.clear
                .composerGlass(Circle(), fill: theme.incomingMessageBackground)
                .overlay {
                    if colorSchemeContrast == .increased {
                        Circle().strokeBorder(theme.primaryText, lineWidth: 1.5)
                    }
                }
        case .send:
            Circle().fill(theme.action)
        case .stop:
            Circle().fill(theme.danger)
        }
    }

    private var midSessionHoldGesture: some Gesture {
        LongPressGesture(
            minimumDuration: MidSessionSendPresentation.unlockHoldDuration,
            maximumDistance: MidSessionSendHoldStateMachine.maximumDistance
        )
        .updating($isHolding) { _, holding, _ in holding = true }
        .onChanged { _ in
            guard isEnabled else { return }
            touchIsActive = true
            withAnimation(reduceMotion ? nil : .linear(duration: MidSessionSendPresentation.unlockHoldDuration)) {
                unlockProgress = 1
            }
        }
        .onEnded { _ in
            guard isEnabled else { return }
            holdThresholdReached = true
            isMidSessionOptionsPresented = true
        }
    }

    private var isEnabled: Bool {
        guard !isBusy else { return false }
        return switch effectiveAction {
        case .voice: true
        case .send: canSend
        case .stop: canStop
        }
    }

    private var accessibilityLabel: String {
        if isBusy { return effectiveAction == .stop ? "Stopping response" : "Sending message" }
        return switch effectiveAction {
        case .voice: "Open voice chat"
        case .send: isQueueingAttachments ? "Queue attachment" : "Send message"
        case .stop: "Stop response"
        }
    }

    private var accessibilityValue: String {
        if isBusy { return effectiveAction == .stop ? "Stopping" : "Sending" }
        if let defaultMidSessionBehavior, effectiveAction == .send {
            let base = "Default during this active turn: \(defaultMidSessionBehavior.title)"
            guard holdObservationEnabled else { return base }
            return base
                + " thresholdReached=\(holdThresholdReached)"
                + " optionsAppeared=\(optionsAppeared)"
                + " touchActiveWhenOptionsAppeared=\(touchActiveWhenOptionsAppeared)"
        }
        if isEnabled { return "Available" }
        if effectiveAction == .send, let unavailableReason { return "Unavailable, " + unavailableReason }
        return "Unavailable"
    }

    private var accessibilityHint: String {
        if isQueueingAttachments { return "Queues the attachment after the current turn without interrupting it." }
        guard !midSessionAlternatives.isEmpty else { return "" }
        return "Press and hold for 1 second to unlock \(midSessionAlternatives.map(\.title).joined(separator: " or "))."
    }

    private var midSessionAlternatives: [MidSessionChatBehavior] {
        guard effectiveAction == .send, let defaultMidSessionBehavior else { return [] }
        return MidSessionSendPresentation.alternatives(defaultBehavior: defaultMidSessionBehavior)
            .filter { allowedMidSessionBehaviors.contains($0) && capabilities.allows($0) }
    }

    private func perform() {
        switch effectiveAction {
        case .voice:
            onVoice()
        case .send:
            BighelpHaptics.tap()
            onSend()
        case .stop:
            BighelpHaptics.tap(rigid: true)
            onStop()
        }
    }

    private var isQueueingAttachments: Bool {
        defaultMidSessionBehavior == .queued && allowedMidSessionBehaviors == [.queued]
    }

    private var actionSystemImage: String {
        switch effectiveAction {
        case .voice: uiV3Enabled ? "mic" : "waveform"
        case .send: isQueueingAttachments ? "clock.arrow.circlepath" : "arrow.up"
        case .stop: "stop.fill"
        }
    }

    private var accessibilityIdentifier: String {
        switch effectiveAction {
        case .voice: "chat.voice"
        case .send: "chat.send"
        case .stop: "chat.stop"
        }
    }

    @BighelpThemeReader private var theme: BighelpTheme

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
}

/// Detents only size sheets on iPhone; on iPad and Mac the sheet fits its choices.
private struct FittedSheetSizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18, visionOS 2, *) {
            content.presentationSizing(.fitted)
        } else {
            content
        }
    }
}

private struct MidSessionSendOptionsSheet: View {
    let defaultBehavior: MidSessionChatBehavior
    let alternatives: [MidSessionChatBehavior]
    /// From Command-Return: every choice, the usual one first, picked with 1–3 or Return.
    var fromKeyboard = false
    let onSelect: (MidSessionChatBehavior) -> Void

    @Environment(\.dismiss) private var dismiss

    private var choices: [MidSessionChatBehavior] {
        fromKeyboard ? [defaultBehavior] + alternatives : alternatives
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(fromKeyboard ? "Send how?" : "Send another way")
                    .bighelpFont(.sectionTitle, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                Text(fromKeyboard
                     ? "Your agent is still working. Press 1–\(choices.count), or Return to \(defaultBehavior.title.lowercased())."
                     : "\(BighelpPlatform.isMac ? "Click" : "Tap") sends with \(defaultBehavior.title). Choose a one-time alternative below.")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
            }

            VStack(spacing: BighelpTokens.space8) {
                ForEach(choices) { behavior in
                    Button {
                        dismiss()
                        onSelect(behavior)
                    } label: {
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            Text(behavior.title)
                                .bighelpFont(.label)
                                .foregroundStyle(theme.primaryText)
                            Text(behavior.detail)
                                .bighelpFont(.metadata)
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                        .padding(.horizontal, BighelpTokens.space12)
                        .padding(.vertical, BighelpTokens.space8)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .bighelpSurface(.capsuleControl, isInteractive: true)
                    .accessibilityLabel(behavior.title)
                    .accessibilityHint(behavior.detail)
                    .accessibilityIdentifier("chat.send.mid-session.\(behavior.rawValue)")
                }
            }
        }
        .background {
            if fromKeyboard {
                // 1–3 pick a choice; Return picks the usual one, listed first.
                KeyboardChoiceKeys(count: choices.count, onCancel: BighelpPlatform.isMac ? { dismiss() } : nil) { index in
                    guard choices.indices.contains(index) else { return }
                    dismiss()
                    onSelect(choices[index])
                }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        }
        .padding(BighelpTokens.space20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.send.mid-session.options")
    }

    @BighelpThemeReader private var theme: BighelpTheme

}
