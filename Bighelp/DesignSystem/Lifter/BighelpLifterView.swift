import SwiftUI

/// How a `BighelpLifterView` plays its motion.
enum BighelpLifterPlayback: Equatable, Sendable {
    /// The intro once (the box turns into the state's prop), then the loop for as long as it shows.
    case automatic
    /// The whole file once, intro to outro, then holds the last frame (back on the idle pose).
    case once
    /// One frame of the loop, chosen by the caller (pull to refresh maps the pull distance to 0...1).
    case progress(Double)
}

/// The lifter, drawn natively. `size` is the side of the square the still mark fills; props,
/// jumps and confetti draw past it. Below `smallestMotion` it's always the still mark: the
/// motions don't read that small. It redraws at most 30 times a second, and only while on
/// screen and the app's loaders may move (`BighelpLoaderMotion`: not with Reduce Motion, in
/// Low Power Mode or in the background). Otherwise, and when paused, it's the still mark.
struct BighelpLifterView: View {
    let motion: BighelpLifterMotion
    var size: CGFloat = 28
    var playback: BighelpLifterPlayback = .automatic
    /// Repaints the whole figure in one color (on a filled button); nil keeps the kit's colors.
    var tint: Color?
    var isPaused = false
    /// Read aloud; nil hides it from VoiceOver (a label beside it usually says it).
    var accessibilityLabel: String?
    /// After a one-shot plays to its end (never while loaders are still).
    var onFinish: (() -> Void)?

    /// The smallest side a motion plays at (DESIGN.md › Lifter).
    static let smallestMotion: CGFloat = 28

    @BighelpLoaderMotionReader private var loaderMotion
    @BighelpThemeReader private var theme
    @State private var isVisible = false
    @State private var start = Date.now
    @State private var finished = false

    var body: some View {
        let animation = size >= Self.smallestMotion
            ? BighelpLifterAnimation.named(motion, dark: theme.isDarkPalette) : nil
        Group {
            if let animation, let still = stillFrame(animation) {
                canvas(animation, frame: still)
            } else if let animation, animates {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: finished)) { timeline in
                    canvas(animation, frame: frame(animation, at: timeline.date))
                }
            } else {
                // Small, Reduce Motion, paused or off screen: the still mark, where every motion starts and ends.
                canvas(nil, frame: 0)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            isVisible = true
            restart()
        }
        .onDisappear { isVisible = false }
        .onChange(of: motion) { restart() }
        .task(id: TaskKey(motion: motion, start: start, animates: animates && animation != nil)) {
            guard animates, let animation, playback == .once else { return }
            try? await Task.sleep(for: .seconds(max(0, animation.duration - Date.now.timeIntervalSince(start))))
            guard !Task.isCancelled else { return }
            finished = true
            onFinish?()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel ?? "")
        .accessibilityHidden(accessibilityLabel == nil)
        .accessibilityIdentifier("lifter.\(motion.rawValue)")
    }

    private struct TaskKey: Hashable {
        let motion: BighelpLifterMotion
        let start: Date
        let animates: Bool
    }

    private var animates: Bool {
        !isPaused && loaderMotion.animates && isVisible
    }

    private func restart() {
        start = .now
        finished = false
    }

    /// A frame drawn without a clock: pull progress, or the end of a one-shot that's played.
    private func stillFrame(_ animation: BighelpLifterAnimation) -> Double? {
        if case .progress(let progress) = playback {
            let loop = animation.loop
            return loop.lowerBound + min(max(progress, 0), 1) * (loop.upperBound - loop.lowerBound - 1)
        }
        if finished, playback == .once { return animation.outPoint - 1 }
        return nil
    }

    private func frame(_ animation: BighelpLifterAnimation, at date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(start)) * animation.frameRate
        if playback == .once { return animation.inPoint + min(elapsed, animation.frameCount - 1) }
        return Self.automaticFrame(animation, elapsed: elapsed)
    }

    /// The intro once, then the loop over and over.
    static func automaticFrame(_ animation: BighelpLifterAnimation, elapsed: Double) -> Double {
        if let intro = animation.intro, elapsed < intro.upperBound - intro.lowerBound {
            return intro.lowerBound + elapsed
        }
        let looped = elapsed - (animation.intro.map { $0.upperBound - $0.lowerBound } ?? 0)
        let loop = animation.loop
        return loop.lowerBound + looped.truncatingRemainder(dividingBy: loop.upperBound - loop.lowerBound)
    }

    /// The composition is drawn larger than the frame and centered on it, so props aren't cut off.
    private func canvas(_ animation: BighelpLifterAnimation?, frame: Double) -> some View {
        let reach = size * BighelpLifterAnimation.compositionSide / BighelpLifterAnimation.markBox
        let tint = tint
        let side = size
        let dark = theme.isDarkPalette
        return Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            if let animation {
                animation.draw(frame: frame, in: context, center: center, side: side, tint: tint)
            } else {
                BighelpLifterMark.draw(in: context, center: center, side: side, dark: dark, tint: tint)
            }
        }
        .frame(width: reach, height: reach)
        .allowsHitTesting(false)
    }
}

/// The still mark: the lifter holding the box overhead, from the kit's 200-unit artboard.
/// The box is ink on light pages and cream on dark ones; the lifter is always coral.
struct BighelpLifterMark: View {
    var size: CGFloat = 28
    /// Paints the whole mark in one color; nil keeps the kit's colors.
    var tint: Color?

    @BighelpThemeReader private var theme

    var body: some View {
        let dark = theme.isDarkPalette
        let tint = tint
        Canvas { context, canvasSize in
            Self.draw(in: context, center: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2),
                      side: min(canvasSize.width, canvasSize.height), dark: dark, tint: tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Draws the mark so its artboard fills `side` points around `center`.
    static func draw(in context: GraphicsContext, center: CGPoint, side: CGFloat, dark: Bool, tint: Color?) {
        var local = context
        local.translateBy(x: center.x - side / 2, y: center.y - side / 2)
        local.scaleBy(x: side / 200, y: side / 200)
        let prop = tint ?? (dark ? BighelpBrand.cream : BighelpBrand.ink)
        let body = tint ?? BighelpBrand.coral
        local.fill(Path(roundedRect: CGRect(x: 36, y: 28, width: 128, height: 84), cornerRadius: 24), with: .color(prop))
        var arms = Path()
        arms.move(to: CGPoint(x: 84, y: 148))
        arms.addLine(to: CGPoint(x: 66, y: 110))
        arms.move(to: CGPoint(x: 116, y: 148))
        arms.addLine(to: CGPoint(x: 134, y: 110))
        local.stroke(arms, with: .color(body), style: StrokeStyle(lineWidth: 10, lineCap: .round))
        local.fill(Path(roundedRect: CGRect(x: 76, y: 128, width: 48, height: 52), cornerRadius: 22), with: .color(body))
        // One color has no eyes to draw: they'd vanish into the body.
        guard tint == nil else { return }
        for x in [90.0, 103.0] {
            local.fill(Path(roundedRect: CGRect(x: x, y: 142, width: 7, height: 16), cornerRadius: 3.5),
                       with: .color(BighelpBrand.ink))
        }
    }
}

/// Set once at the app's root: every indeterminate `ProgressView` draws the lifter, sized
/// by its control size, with its label under it. Determinate ones keep the system bar.
struct BighelpLifterProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        if configuration.fractionCompleted == nil {
            BighelpLifterSpinner(label: configuration.label)
        } else {
            ProgressView(configuration).progressViewStyle(.linear)
        }
    }
}

private struct BighelpLifterSpinner: View {
    let label: ProgressViewStyleConfiguration.Label?
    @Environment(\.controlSize) private var controlSize

    @ViewBuilder
    var body: some View {
        let stack = VStack(spacing: BighelpTokens.space8) {
            BighelpLifterView(motion: .idle, size: side)
            if let label {
                label
                    .font(.bighelp(.footnote))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        if label == nil { stack.accessibilityLabel("Loading") } else { stack }
    }

    private var side: CGFloat {
        switch controlSize {
        case .mini: 12
        case .small: 16
        case .large, .extraLarge: 36
        default: 22
        }
    }
}

extension View {
    /// When `trigger` turns true while this is on screen, the lifter's `motion` plays once in
    /// its place, then the view comes back: success when work finishes or a favorite is
    /// pinned. Never on first appearance, never while loaders are still, and never smaller
    /// than a motion plays.
    func bighelpLifterMoment(_ motion: BighelpLifterMotion, when trigger: Bool, size: CGFloat) -> some View {
        modifier(BighelpLifterMoment(motion: motion, trigger: trigger, size: size))
    }
}

private struct BighelpLifterMoment: ViewModifier {
    let motion: BighelpLifterMotion
    let trigger: Bool
    let size: CGFloat

    @State private var isPlaying = false
    @BighelpLoaderMotionReader private var loaderMotion

    func body(content: Content) -> some View {
        content
            .opacity(isPlaying ? 0 : 1)
            .overlay {
                if isPlaying {
                    BighelpLifterView(motion: motion, size: size, playback: .once) { isPlaying = false }
                }
            }
            .onChange(of: trigger) { was, now in
                if now, !was, loaderMotion.animates, size >= BighelpLifterView.smallestMotion { isPlaying = true }
            }
    }
}
