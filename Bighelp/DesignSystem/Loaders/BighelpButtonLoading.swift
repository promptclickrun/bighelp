import SwiftUI

/// What a button is doing after it's pressed.
enum BighelpButtonLoadState: Equatable, Sendable {
    case idle
    /// Working: a spinner and a shimmering label ("Setting it up…").
    case working(String)
    /// Done: a check pops in beside the label ("Mina's ready").
    case success(String)
}

/// A button's label that can show working and success without changing the
/// button's width: the idle label sets the size, and the working and success
/// labels are drawn inside it (a long one shrinks a little, then truncates).
/// To give a longer working label room, size the idle label (`.frame(minWidth:)`
/// inside the closure). Style the button as usual; on a filled button pass its
/// ink as `ink`.
///
/// ```swift
/// Button(action: create) {
///     BighelpButtonLoadingLabel(state: state, ink: theme.actionForeground) {
///         Label("New agent", systemImage: "person.badge.plus")
///     }
/// }
/// .disabled(state != .idle)
/// ```
struct BighelpButtonLoadingLabel<Idle: View>: View {
    let state: BighelpButtonLoadState
    /// The label's color: the spinner and shimmer are drawn in it.
    var ink: Color?
    @ViewBuilder var idle: () -> Idle

    @BighelpLoaderMotionReader private var motion
    @BighelpLoaderScaled(relativeTo: .body) private var markSide: CGFloat = 16

    var body: some View {
        idle()
            .visible(state == .idle)
            .overlay {
                switch state {
                case .idle:
                    EmptyView()
                case .working(let text):
                    HStack(spacing: BighelpTokens.space8) {
                        BighelpSpinner(size: markSide, color: ink)
                        Text(text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .bighelpShimmer(isActive: true, base: ink?.opacity(0.7), highlight: ink)
                    }
                    .transition(.opacity)
                case .success(let text):
                    HStack(spacing: BighelpTokens.space8) {
                        BighelpCheckPop(side: markSide)
                        Text(text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .transition(.opacity)
                }
            }
            .animation(motion.moves ? .easeOut(duration: BighelpTokens.stateDuration) : nil, value: state)
            // The hidden labels are out of the way, so VoiceOver reads the one showing.
            .accessibilityElement(children: .combine)
    }
}

private extension View {
    func visible(_ isVisible: Bool) -> some View {
        opacity(isVisible ? 1 : 0).accessibilityHidden(!isVisible)
    }
}

/// A check that pops in once when it appears (Reduce Motion: it's just there).
struct BighelpCheckPop: View {
    var side: CGFloat = 18

    @BighelpLoaderMotionReader private var motion
    @State private var isShown = false

    var body: some View {
        Image(systemName: "checkmark")
            .resizable().scaledToFit()
            .fontWeight(.bold)
            .frame(width: side * 0.78, height: side * 0.78)
            .frame(width: side, height: side)
            .scaleEffect(isShown || !motion.moves ? 1 : 0.8)
            .opacity(isShown || !motion.moves ? 1 : 0)
            .onAppear {
                withAnimation(motion.moves ? BighelpLoaderCurve.pop.animation(duration: BighelpLoaderTiming.checkPop) : nil) {
                    isShown = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// The press look for bighelp's buttons: a slight shrink and dim, never a
/// color change. Reduce Motion keeps the dim and drops the shrink.
enum BighelpButtonPress {
    static let scale: CGFloat = 0.96
    static let opacity: Double = 0.88
}

extension View {
    /// Applies the press look while `isPressed`. Use it inside a `ButtonStyle`:
    /// `configuration.label….bighelpPressFeedback(isPressed: configuration.isPressed)`.
    func bighelpPressFeedback(isPressed: Bool) -> some View {
        modifier(BighelpPressFeedbackModifier(isPressed: isPressed))
    }
}

private struct BighelpPressFeedbackModifier: ViewModifier {
    let isPressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && !reduceMotion ? BighelpButtonPress.scale : 1)
            .opacity(isPressed ? BighelpButtonPress.opacity : 1)
            .animation(.easeOut(duration: BighelpTokens.pressDuration), value: isPressed)
    }
}

/// A button style that only adds the press look; the label draws everything else.
struct BighelpScaleDimPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.bighelpPressFeedback(isPressed: configuration.isPressed)
    }
}

extension ButtonStyle where Self == BighelpScaleDimPressStyle {
    static var bighelpScaleDim: BighelpScaleDimPressStyle { BighelpScaleDimPressStyle() }
}
