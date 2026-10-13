import SwiftUI

/// How a `BighelpNoodleView` plays its motion.
enum BighelpNoodlePlayback: Equatable, Sendable {
    /// Loops if the kit loops it, else plays once.
    case automatic
    /// Over and over, holding the end this long before each restart (tricks used as loaders).
    case loop(pause: TimeInterval = 0)
    /// Once, then holds the last frame.
    case once
    /// One frame, chosen by the caller (pull to refresh maps the pull distance to 0...1).
    case progress(Double)
}

/// A brand-kit motion drawn natively. `size` is the side of the square the mark fills;
/// extras like sparkles draw past it. It redraws at most 30 times a second, and only while
/// on screen and the app's loaders may move (`BighelpLoaderMotion`: not with Reduce Motion,
/// in Low Power Mode or in the background). Otherwise, and when paused, it's the still mark.
struct BighelpNoodleView: View {
    let motion: BighelpNoodleMotion
    var size: CGFloat = 28
    var playback: BighelpNoodlePlayback = .automatic
    /// Repaints every stroke; nil keeps the kit's Ember.
    var tint: Color?
    var isPaused = false
    /// Read aloud; nil hides it from VoiceOver (a label beside it usually says it).
    var accessibilityLabel: String?
    /// After a one-shot plays to its end (never while loaders are still).
    var onFinish: (() -> Void)?

    @BighelpLoaderMotionReader private var loaderMotion
    @State private var isVisible = false
    @State private var start = Date.now
    @State private var finished = false

    var body: some View {
        let animation = BighelpNoodleAnimation.named(motion)
        Group {
            if let animation, let still = stillFrame(animation) {
                canvas(animation, frame: still)
            } else if let animation, animates {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: finished)) { timeline in
                    canvas(animation, frame: frame(animation, at: timeline.date))
                }
            } else {
                // Reduce Motion, paused or off screen: the mark at rest, where every motion starts and ends.
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
        .task(id: TaskKey(motion: motion, start: start, animates: animates)) {
            guard animates, let animation, case .once = resolved(animation) else { return }
            try? await Task.sleep(for: .seconds(max(0, animation.duration - Date.now.timeIntervalSince(start))))
            guard !Task.isCancelled else { return }
            finished = true
            onFinish?()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel ?? "")
        .accessibilityHidden(accessibilityLabel == nil)
        .accessibilityIdentifier("noodle.\(motion.rawValue)")
    }

    private struct TaskKey: Hashable {
        let motion: BighelpNoodleMotion
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

    private func resolved(_ animation: BighelpNoodleAnimation) -> BighelpNoodlePlayback {
        guard playback == .automatic else { return playback }
        return animation.loops ? .loop() : .once
    }

    /// A frame drawn without a clock: pull progress, or the end of a one-shot that's played.
    private func stillFrame(_ animation: BighelpNoodleAnimation) -> Double? {
        if case .progress(let progress) = playback {
            return animation.inPoint + min(max(progress, 0), 1) * (animation.frameCount - 1)
        }
        if finished, case .once = resolved(animation) { return animation.outPoint - 1 }
        return nil
    }

    private func frame(_ animation: BighelpNoodleAnimation, at date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(start)) * animation.frameRate
        switch resolved(animation) {
        case .loop(let pause):
            let period = animation.frameCount + pause * animation.frameRate
            return animation.inPoint + min(elapsed.truncatingRemainder(dividingBy: period), animation.frameCount - 1)
        default:
            return animation.inPoint + min(elapsed, animation.frameCount - 1)
        }
    }

    /// The composition is drawn larger than the frame and centered on it, so extras aren't cut off.
    private func canvas(_ animation: BighelpNoodleAnimation?, frame: Double) -> some View {
        let reach = size * BighelpNoodleAnimation.compositionSide / BighelpNoodleAnimation.markBox
        let tint = tint
        let side = size
        return Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            if let animation {
                animation.draw(frame: frame, in: context, center: center, side: side, tint: tint)
            } else {
                BighelpNoodleAnimation.drawMark(in: context, center: center, side: side, color: tint ?? BighelpBrand.ember)
            }
        }
        .frame(width: reach, height: reach)
        .allowsHitTesting(false)
    }
}

/// The mark's one stroke: the stem, the bowl and the tail, from the kit's 100-unit artboard.
struct BighelpNoodleShape: Shape {
    /// Stem top (28, 12) down to the bowl, around it, then the tail out to (8, 94).
    static let artboardPath: Path = {
        let k: CGFloat = 13.807 // 25 * 0.5523, a quarter circle's handle
        var path = Path()
        path.move(to: CGPoint(x: 28, y: 12))
        path.addLine(to: CGPoint(x: 28, y: 60))
        path.addCurve(to: CGPoint(x: 53, y: 85), control1: CGPoint(x: 28, y: 60 + k), control2: CGPoint(x: 53 - k, y: 85))
        path.addCurve(to: CGPoint(x: 78, y: 60), control1: CGPoint(x: 53 + k, y: 85), control2: CGPoint(x: 78, y: 60 + k))
        path.addCurve(to: CGPoint(x: 53, y: 35), control1: CGPoint(x: 78, y: 60 - k), control2: CGPoint(x: 53 + k, y: 35))
        path.addCurve(to: CGPoint(x: 28, y: 60), control1: CGPoint(x: 53 - k, y: 35), control2: CGPoint(x: 28, y: 60 - k))
        path.addCurve(to: CGPoint(x: 8, y: 94), control1: CGPoint(x: 28, y: 80), control2: CGPoint(x: 22, y: 90))
        return path
    }()

    /// The stroke's bounds with its round caps: x 0...86, y 4...102.
    static let bounds = CGRect(x: 0, y: 4, width: 86, height: 98)

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.bounds.width, rect.height / Self.bounds.height)
        let dx = rect.midX - Self.bounds.midX * scale, dy = rect.midY - Self.bounds.midY * scale
        return Self.artboardPath.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: dx / scale, y: dy / scale))
    }
}

/// The still mark. `size` is the height of the stroke with its caps.
struct BighelpNoodleMark: View {
    var size: CGFloat = 28
    var color: Color = BighelpBrand.ember

    var body: some View {
        let unit = size / BighelpNoodleShape.bounds.height
        BighelpNoodleShape()
            .stroke(color, style: StrokeStyle(lineWidth: 16 * unit, lineCap: .round, lineJoin: .round))
            .frame(width: BighelpNoodleShape.bounds.width * unit, height: size)
            .accessibilityHidden(true)
    }
}

/// Set once at the app's root: every indeterminate `ProgressView` draws the Noodle's
/// loader, sized by its control size, with its label under it. Determinate ones keep
/// the system bar.
struct BighelpNoodleProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        if configuration.fractionCompleted == nil {
            BighelpNoodleSpinner(label: configuration.label)
        } else {
            ProgressView(configuration).progressViewStyle(.linear)
        }
    }
}

private struct BighelpNoodleSpinner: View {
    let label: ProgressViewStyleConfiguration.Label?
    @Environment(\.controlSize) private var controlSize

    @ViewBuilder
    var body: some View {
        let stack = VStack(spacing: BighelpTokens.space8) {
            BighelpNoodleView(motion: .loader, size: side)
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
    /// When `trigger` turns true while this is on screen, the kit's `motion` plays once in
    /// its place, then the view comes back: done when work finishes, a heart for a new
    /// favorite. Never on first appearance, and never while loaders are still.
    func bighelpNoodleMoment(_ motion: BighelpNoodleMotion, when trigger: Bool, size: CGFloat) -> some View {
        modifier(BighelpNoodleMoment(motion: motion, trigger: trigger, size: size))
    }
}

private struct BighelpNoodleMoment: ViewModifier {
    let motion: BighelpNoodleMotion
    let trigger: Bool
    let size: CGFloat

    @State private var isPlaying = false
    @BighelpLoaderMotionReader private var loaderMotion

    func body(content: Content) -> some View {
        content
            .opacity(isPlaying ? 0 : 1)
            .overlay {
                if isPlaying {
                    BighelpNoodleView(motion: motion, size: size, playback: .once) { isPlaying = false }
                }
            }
            .onChange(of: trigger) { was, now in
                if now, !was, loaderMotion.animates { isPlaying = true }
            }
    }
}
