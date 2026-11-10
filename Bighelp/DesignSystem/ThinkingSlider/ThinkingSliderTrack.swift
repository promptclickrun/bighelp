import SwiftUI
import UIKit

// A Thinking look on screen: the running drawing, and the same drawing you can tap and drag.
// Adapted from hermex (MIT).

/// The running look alone, with no touches. Used by previews, the settings page and the control.
/// Capped at 60 frames a second so a ProMotion screen doesn't double the work. It holds still under
/// Reduce Motion, while the app is away, while off screen or covered, and once it has rested at the
/// bottom of the ladder for a moment, where every look stands still anyway.
struct ThinkingSliderTrack: View {
    let look: BighelpThinkingLook
    /// 0 to 1 along the track.
    let level: Double
    /// Moves the thumb with the finger instead of easing to it.
    let followsFinger: Bool
    /// The person's color, which Noodle and Train of Thought start in.
    let accent: Color
    /// Holds the animation for a cover the track can't see for itself.
    let isPaused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.self) private var environment
    @BighelpThemeReader private var theme: BighelpTheme
    @State private var store = ThinkingSliderStore()
    /// False once a pushed page hides the track.
    @State private var isOnScreen = true
    /// True once the level has stayed at the bottom long enough for every look to stand still.
    @State private var hasRested = false

    init(look: BighelpThinkingLook, level: Double, followsFinger: Bool, accent: Color, isPaused: Bool = false) {
        self.look = look
        self.level = level
        self.followsFinger = followsFinger
        self.accent = accent
        self.isPaused = isPaused
    }

    var body: some View {
        let isStill = reduceMotion
        // Checked against the level itself too, so the frame a drag starts in is already live.
        let isResting = hasRested && level == 0
        let isHeld = isStill || isPaused || !isOnScreen || scenePhase != .active || isResting
        let paint = self.paint
        let store = store
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: isHeld)) { timeline in
            Canvas { context, size in
                let frame = store.advance(
                    time: timeline.date.timeIntervalSinceReferenceDate, target: level,
                    followsFinger: followsFinger, size: size, isHeld: isHeld, isStill: isStill
                )
                var track = context
                track.clip(to: Path(
                    roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2, style: .continuous
                ))
                look.drawTrack(&track, frame, store, paint)
                look.drawThumb(&context, frame, store, paint)
            }
        }
        .frame(height: ThinkingSliderMetrics.height)
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .task(id: level == 0) {
            guard level == 0 else {
                hasRested = false
                return
            }
            // About as long as the thumb takes to ease home and the looks' last particles to leave.
            try? await Task.sleep(for: .milliseconds(1200))
            if !Task.isCancelled { hasRested = true }
        }
        .accessibilityHidden(true)
    }

    /// Day or night and the person's color, resolved once per update rather than every frame.
    private var paint: ThinkingPaint {
        let resolved = accent.resolve(in: environment)
        return ThinkingPaint(
            isDark: theme.isDarkPalette,
            accent: ThinkingAccent(
                red: Double(min(max(resolved.red, 0), 1)), green: Double(min(max(resolved.green, 0), 1)),
                blue: Double(min(max(resolved.blue, 0), 1)), isDark: theme.isDarkPalette
            )
        )
    }
}

/// A look you can tap and drag, shared by the Thinking control and the settings page. A tap picks
/// the nearest level at once. A sideways drag follows the finger with a tick per level and picks
/// one level on release; a vertical swipe scrolls whatever holds the track instead.
struct ThinkingInteractiveTrack: View {
    let look: BighelpThinkingLook
    let ladder: ThinkingLadder
    let accent: Color
    let isPaused: Bool
    @Binding var drag: ThinkingSliderDrag
    /// A level picked by a tap or a release. Never the current one.
    let onSelect: (Int) -> Void

    @State private var ticks = 0

    init(
        look: BighelpThinkingLook, ladder: ThinkingLadder, accent: Color, isPaused: Bool = false,
        drag: Binding<ThinkingSliderDrag>, onSelect: @escaping (Int) -> Void
    ) {
        self.look = look
        self.ladder = ladder
        self.accent = accent
        self.isPaused = isPaused
        _drag = drag
        self.onSelect = onSelect
    }

    /// With no current level the thumb rests at the bottom of the ladder.
    private var shownPosition: Double {
        drag.position ?? ladder.currentIndex.map(ladder.position(of:)) ?? 0
    }

    var body: some View {
        ThinkingSliderTrack(
            look: look, level: shownPosition, followsFinger: drag.position != nil && !drag.isLanded,
            accent: accent, isPaused: isPaused
        )
        .overlay {
            ThinkingTouchSurface(
                onTap: { x, width in
                    select(ladder.index(atPosition: ThinkingLadder.position(atX: x, width: width)))
                },
                onMove: { x, width in
                    if drag.move(to: ThinkingLadder.position(atX: x, width: width), on: ladder) { ticks += 1 }
                },
                onEnd: {
                    if let index = drag.end(on: ladder) { onSelect(index) }
                },
                onCancel: { drag.cancel() }
            )
        }
        .environment(\.layoutDirection, .leftToRight)
        .sensoryFeedback(.selection, trigger: ticks)
        .task(id: drag.isLanded) {
            guard drag.isLanded else { return }
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { drag.cancel() }
        }
    }

    private func select(_ index: Int) {
        guard index != ladder.currentIndex else { return }
        ticks += 1
        onSelect(index)
    }
}

/// A clear UIKit view over the track for its touches. A pan begins only if the finger first moves
/// sideways and otherwise fails at once, so the list or sheet around it scrolls; SwiftUI's
/// `DragGesture` holds the touch whichever way the finger goes. UIKit's recognizers work the same on
/// iOS 17, the Mac and Vision Pro.
private struct ThinkingTouchSurface: UIViewRepresentable {
    /// Each gets the touch's x and the track's width.
    let onTap: (CGFloat, CGFloat) -> Void
    let onMove: (CGFloat, CGFloat) -> Void
    let onEnd: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        // The closures read the ladder and drag of this update, so the newest ones must answer.
        context.coordinator.surface = self
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var surface: ThinkingTouchSurface

        init(_ surface: ThinkingTouchSurface) {
            self.surface = surface
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            surface.onTap(recognizer.location(in: view).x, view.bounds.width)
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let x = recognizer.location(in: view).x, width = view.bounds.width
            switch recognizer.state {
            case .began, .changed: surface.onMove(x, width)
            case .ended:
                // The lift can land past the last movement sample, on another level.
                surface.onMove(x, width)
                surface.onEnd()
            case .cancelled, .failed: surface.onCancel()
            default: break
            }
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return ThinkingLadder.isAdjustment(CGSize(width: velocity.x, height: velocity.y))
        }
    }
}
