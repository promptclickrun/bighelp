import SwiftUI
import UIKit

// One clock and one motion rule for every loader. Shimmers, sweeps, spinners
// and glows all read the wall clock, so every copy on screen moves in step, and
// they all stop together on a still frame when they shouldn't move.

/// Loop lengths and curves from the loader design. Durations shared with the
/// rest of the app (press, state, transition) stay in `BighelpTokens`.
enum BighelpLoaderTiming {
    static let shimmer: TimeInterval = 1.9
    static let skeletonSweep: TimeInterval = 1.7
    static let dotsBounce: TimeInterval = 1.1
    static let breathe: TimeInterval = 2.4
    static let ping: TimeInterval = 2.4
    static let glowSweep: TimeInterval = 3.2
    static let developScan: TimeInterval = 2.6
    static let packetTravel: TimeInterval = 1.6
    static let packetProbe: TimeInterval = 1.4
    static let dashFlow: TimeInterval = 1
    static let checkPop: TimeInterval = BighelpTokens.sceneDuration
    static let stepRise: TimeInterval = BighelpTokens.transitionDuration
    /// The image glows drift on long, unrelated loops so they never look repeated.
    static let glowDrifts: [TimeInterval] = [9, 11, 8, 10]
}

/// A CSS-style cubic Bézier timing curve, for loops driven by the clock and for
/// one-shot SwiftUI animations alike.
struct BighelpLoaderCurve: Equatable, Sendable {
    let x1: Double, y1: Double, x2: Double, y2: Double

    static let linear = Self(x1: 0, y1: 0, x2: 1, y2: 1)
    static let easeInOut = Self(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
    static let easeOut = Self(x1: 0, y1: 0, x2: 0.58, y2: 1)
    /// The site's soft ease: quick start, long settle.
    static let site = Self(x1: 0.2, y1: 0.8, x2: 0.2, y2: 1)
    /// New things pop in with a small overshoot.
    static let pop = Self(x1: 0.2, y1: 0.9, x2: 0.3, y2: 1.25)

    /// Progress along the curve at `t` (0...1) of the time.
    func callAsFunction(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        if self == .linear { return t }
        // Solve x(u) = t for the curve parameter u, then read y(u).
        var u = t
        for _ in 0..<8 {
            let x = sample(u, x1, x2) - t
            let slope = derivative(u, x1, x2)
            guard abs(x) > 1e-6, abs(slope) > 1e-6 else { break }
            u = min(max(u - x / slope, 0), 1)
        }
        return sample(u, y1, y2)
    }

    func animation(duration: TimeInterval) -> Animation {
        .timingCurve(x1, y1, x2, y2, duration: duration)
    }

    private func sample(_ u: Double, _ p1: Double, _ p2: Double) -> Double {
        let v = 1 - u
        return 3 * v * v * u * p1 + 3 * v * u * u * p2 + u * u * u
    }

    private func derivative(_ u: Double, _ p1: Double, _ p2: Double) -> Double {
        let v = 1 - u
        return 3 * v * v * p1 + 6 * v * u * (p2 - p1) + 3 * u * u * (1 - p2)
    }
}

/// One moment of the shared loader clock: wall time, or the still frame.
struct BighelpLoaderTime: Equatable, Sendable {
    /// Seconds since the reference date; nil for the still frame.
    let seconds: TimeInterval?

    static let still = Self(seconds: nil)

    init(seconds: TimeInterval?) { self.seconds = seconds }
    init(_ date: Date) { seconds = date.timeIntervalSinceReferenceDate }

    var isStill: Bool { seconds == nil }

    /// How far through a loop of `period` seconds, 0..<1. Every copy of a loader
    /// gets the same answer at the same moment; `offset` shifts one copy on
    /// purpose (tiles in a grid). The still frame answers `rest`.
    func phase(_ period: TimeInterval, offset: TimeInterval = 0, rest: Double = 0) -> Double {
        guard let seconds, period > 0 else { return rest }
        let value = (seconds + offset).truncatingRemainder(dividingBy: period) / period
        return value < 0 ? value + 1 : value
    }

    /// Back and forth, like CSS `alternate`: 0 → 1 over one period, 1 → 0 over the next.
    func pingPong(_ period: TimeInterval, offset: TimeInterval = 0, curve: BighelpLoaderCurve = .easeInOut,
                  rest: Double = 0) -> Double {
        guard !isStill else { return rest }
        let lap = phase(period * 2, offset: offset) * 2
        return curve(lap <= 1 ? lap : 2 - lap)
    }
}

/// Lets a screen ask its loaders to hold still, as if Reduce Motion, Low Power
/// Mode or a background scene applied. It can only stop motion, never start it.
/// The loader gallery uses it on the Mac, where those settings can't be faked.
struct BighelpLoaderMotionOverride: Equatable, Sendable {
    var reduceMotion = false
    var lowPowerMode = false
    var sceneInactive = false
}

extension EnvironmentValues {
    @Entry var bighelpLoaderMotionOverride = BighelpLoaderMotionOverride()
}

/// What loaders may do right now.
struct BighelpLoaderMotion: Equatable, Sendable {
    /// Endless loops and flourishes (shimmers, sweeps, spinners, glows, a ping).
    let animates: Bool
    /// Moves that answer a change (steps rising in, a fold opening). Under
    /// Reduce Motion they become plain fades.
    let moves: Bool
    /// Low Power Mode: a shimmer rests as plain secondary text.
    let isLowPower: Bool
}

enum BighelpLoaderMotionPolicy {
    /// - Parameters:
    ///   - appIsActive: the app's own state (`BighelpLoaderSystemState`), which a
    ///     hosted chat row can't get wrong.
    ///   - scenePhase: the view's environment. Chat rows carry a copy of it, and a
    ///     stale "inactive" copy once froze every chat animation, so only
    ///     `.background` from it can stop a loader.
    static func resolve(reduceMotion: Bool, appIsActive: Bool, scenePhase: ScenePhase,
                        lowPowerMode: Bool, override: BighelpLoaderMotionOverride) -> BighelpLoaderMotion {
        let reduce = reduceMotion || override.reduceMotion
        let lowPower = lowPowerMode || override.lowPowerMode
        let active = appIsActive && scenePhase != .background && !override.sceneInactive
        return BighelpLoaderMotion(animates: !reduce && active && !lowPower, moves: !reduce, isLowPower: lowPower)
    }
}

/// The app's foreground state and Low Power Mode, followed through
/// notifications rather than the environment, so loaders inside hosted rows
/// (the chat's table cells) see the same truth as the rest of the app.
@MainActor
@Observable
final class BighelpLoaderSystemState {
    static let shared = BighelpLoaderSystemState()

    private(set) var appIsActive: Bool
    private(set) var isLowPowerMode: Bool
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        appIsActive = UIApplication.shared.applicationState == .active
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let center = NotificationCenter.default
        let activity: [(Notification.Name, Bool)] = [
            (UIApplication.didBecomeActiveNotification, true),
            (UIApplication.willResignActiveNotification, false),
            (UIApplication.didEnterBackgroundNotification, false),
        ]
        for (name, isActive) in activity {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appIsActive = isActive }
            })
        }
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        })
    }
}

/// Reads `BighelpLoaderMotion` for the view it's in.
@MainActor
@propertyWrapper
struct BighelpLoaderMotionReader: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.bighelpLoaderMotionOverride) private var override

    init() {}

    var wrappedValue: BighelpLoaderMotion {
        let system = BighelpLoaderSystemState.shared
        return BighelpLoaderMotionPolicy.resolve(
            reduceMotion: reduceMotion, appIsActive: system.appIsActive, scenePhase: scenePhase,
            lowPowerMode: system.isLowPowerMode, override: override
        )
    }
}

/// How often a loader redraws. Small, quick things need every frame; soft
/// sweeps and slow glows look the same at fewer.
enum BighelpLoaderCadence: Sendable {
    /// Spinners, bouncing dots, packets on a line.
    case smooth
    /// Shimmers and sweeps.
    case soft
    /// Slowly drifting glows.
    case ambient

    var minimumInterval: TimeInterval {
        switch self {
        case .smooth: 1.0 / 60.0
        case .soft: 1.0 / 30.0
        case .ambient: 1.0 / 24.0
        }
    }
}

/// The shared clock. Draws `content` every frame from wall time while loaders
/// may move, and once, with `BighelpLoaderTime.still`, when they may not.
/// There are no per-view timers: a paused clock costs nothing.
struct BighelpLoaderClock<Content: View>: View {
    var isRunning = true
    var cadence: BighelpLoaderCadence = .soft
    @ViewBuilder var content: (BighelpLoaderTime) -> Content

    @BighelpLoaderMotionReader private var motion

    var body: some View {
        let runs = isRunning && motion.animates
        TimelineView(.animation(minimumInterval: cadence.minimumInterval, paused: !runs)) { context in
            content(runs ? BighelpLoaderTime(context.date) : .still)
        }
    }
}

/// A size that grows with text: Dynamic Type on iPhone, iPad and Vision Pro,
/// the chosen text size on the Mac (whose text styles are fixed).
@MainActor
@propertyWrapper
struct BighelpLoaderScaled: DynamicProperty {
    @ScaledMetric private var scaled: CGFloat

    init(wrappedValue: CGFloat, relativeTo style: Font.TextStyle) {
        _scaled = ScaledMetric(wrappedValue: wrappedValue, relativeTo: style)
    }

    var wrappedValue: CGFloat {
        #if targetEnvironment(macCatalyst)
        (scaled * BighelpInterfaceSize.shared.textSize.macFactor * 2).rounded() / 2
        #else
        scaled
        #endif
    }
}
