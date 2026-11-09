import SwiftUI

// What every Thinking look draws with: one frame's inputs, the state kept between frames, color
// ramps, and the person's own color turning toward its opposite. Adapted from hermex (MIT).

/// One frame's inputs. `level` runs 0 to 1 along the track, eased toward the selection; `thumbX` is
/// the thumb's center; `velocity` is how fast `level` moves, per second.
struct ThinkingSliderFrame {
    let width: Double
    let height: Double
    let time: Double
    let delta: Double
    let level: Double
    let thumbX: Double
    let velocity: Double

    /// The level a look draws at: exactly 0 at the bottom of the ladder, so the bottom stands still.
    var active: Double { level < 0.002 ? 0 : level }
    /// Time passed since the last frame. False for a still frame (Reduce Motion, a paused track).
    var isLive: Bool { delta > 0 }
    var middle: Double { height / 2 }
}

/// A look's state between frames. A `Canvas` draws from the last frame's state, so this is a plain
/// class outside SwiftUI's invalidation: updating it never redraws anything by itself. Each track
/// has its own, and a new look starts from a fresh one.
final class ThinkingSliderStore {
    struct Gear {
        let x: Double, y: Double, radius: Double, teeth: Int, isBig: Bool
        var angle: Double?
        var mix: Double?
        var chain = 0.0
        var shownX = 0.0, shownY = 0.0
    }

    struct Chip {
        var x: Double, y: Double, vx: Double, vy: Double, rotation: Double, spin: Double, size: Double
    }

    struct Blade {
        let x: Double, reach: Double, shade: Int, flower: Int, phase: Double
    }

    struct Mote {
        var x: Double, y: Double, speed: Double, phase: Double
    }

    struct InkThread {
        var x = 0.0, y = 0.0, life = 0.0, span = 1.0
        var trail: [CGPoint] = []
        var isThick = false, isEmber = false
    }

    struct Bubble {
        var x = 0.0, y = 0.0, speed = 0.0, radius = 0.0, phase = 0.0, age = 0.0, popAt = 0.0
        /// Seconds since it popped, or negative while whole.
        var pop = -1.0
        var popX = 0.0, popY = 0.0, popRadius = 0.0
    }

    struct Puff {
        var x: Double, y: Double, vx: Double, vy: Double, life: Double
    }

    struct Word {
        let index: Int, x: Double, width: Double, isKey: Bool
    }

    struct WordRow {
        let words: [Word]
        let length: Double
    }

    private(set) var level: Double?
    private var lastTime: Double?

    /// The look's own clocks. Each look names them in its drawing code.
    var phase = 0.0
    var flow = 0.0
    var offset = 0.0
    /// Wide Awake's eyes, following the drag.
    var gaze = 0.0

    /// The width a layout (gears, grass) was built for.
    var layoutWidth = 0.0
    var gears: [Gear] = []
    var chips: [Chip] = []
    var blades: [Blade] = []
    var motes: [Mote] = []
    var inkThreads: [InkThread] = []
    var bubbles: [Bubble] = []
    var puffs: [Puff] = []

    /// Train of Thought's word rows and their text, built on its first frame.
    var wordRows: [WordRow] = []
    var plainWords: [GraphicsContext.ResolvedText] = []
    var keyWords: [GraphicsContext.ResolvedText] = []
    /// Wide Awake's sleeping "z"s.
    var sleepMarks: [GraphicsContext.ResolvedText] = []

    /// The frame at `time`, with the level eased toward `target`. A held timeline (Reduce Motion, a
    /// cover, off screen, resting) snaps to the target with no time passing, so a still picture still
    /// shows a level that changed while it was held. Under Reduce Motion the clock reads 0 too.
    func advance(time: Double, target: Double, followsFinger: Bool, size: CGSize, isHeld: Bool, isStill: Bool) -> ThinkingSliderFrame {
        let delta = isHeld ? 0 : min(max(time - (lastTime ?? time), 0), 0.05)
        lastTime = time
        let previous = level ?? target
        let response = followsFinger ? 0.5 : 0.22
        let eased = isHeld ? target : previous + (target - previous) * (1 - pow(1 - response, delta * 60))
        level = eased
        let span = max(Double(size.width) - ThinkingSliderMetrics.inset * 2, 1)
        return ThinkingSliderFrame(
            width: size.width, height: size.height, time: isStill ? 0 : time, delta: delta,
            level: eased, thumbX: ThinkingSliderMetrics.inset + eased * span,
            velocity: delta > 0 ? (eased - previous) / delta : 0
        )
    }
}

/// Small, stable random numbers: the same seed draws the same thing every frame. Layout uses these;
/// particles that come and go use `Double.random`.
func thinkingRandom(_ seed: Double) -> Double {
    let value = sin(seed * 127.1 + 311.7) * 43758.5453
    return value - floor(value)
}

/// A fresh random number in 0..<1, for particle spawns.
func thinkingChance() -> Double { Double.random(in: 0..<1) }

func thinkingLerp(_ from: Double, _ to: Double, _ amount: Double) -> Double {
    from + (to - from) * amount
}

func thinkingClamp(_ value: Double, _ low: Double = 0, _ high: Double = 1) -> Double {
    min(max(value, low), high)
}

let thinkingTau = Double.pi * 2

/// A color as 0–255 sRGB channels, so ramps mix the way the mock's canvas did.
struct ThinkingRGB: Sendable {
    let red: Double, green: Double, blue: Double

    init(_ hex: UInt32) {
        red = Double((hex >> 16) & 0xFF)
        green = Double((hex >> 8) & 0xFF)
        blue = Double(hex & 0xFF)
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    func mixed(with other: ThinkingRGB, by amount: Double) -> ThinkingRGB {
        ThinkingRGB(
            red: thinkingLerp(red, other.red, amount), green: thinkingLerp(green, other.green, amount),
            blue: thinkingLerp(blue, other.blue, amount)
        )
    }

    func color(_ opacity: Double = 1) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: opacity)
    }
}

/// Colors or numbers placed at levels `stops`, read anywhere between them.
struct ThinkingRamp: Sendable {
    let stops: [Double]
    let colors: [ThinkingRGB]

    init(_ stops: [Double], _ hexes: [UInt32]) {
        self.stops = stops
        colors = hexes.map { ThinkingRGB($0) }
    }

    func at(_ level: Double) -> ThinkingRGB {
        let (index, amount) = Self.segment(stops, level)
        return colors[index].mixed(with: colors[index + 1], by: amount)
    }

    static func number(_ stops: [Double], _ values: [Double], _ level: Double) -> Double {
        let (index, amount) = segment(stops, level)
        return thinkingLerp(values[index], values[index + 1], amount)
    }

    private static func segment(_ stops: [Double], _ level: Double) -> (Int, Double) {
        var index = 0
        while index < stops.count - 2, level > stops[index + 1] { index += 1 }
        return (index, thinkingClamp((level - stops[index]) / (stops[index + 1] - stops[index])))
    }
}

/// The person's color at 0 and its opposite at 1, turning the long way round the color wheel. A
/// color with almost no hue (Ink) has no opposite, so it turns toward Ember instead. Built once per
/// view update from the resolved accent, never per frame.
struct ThinkingAccent: Equatable, Sendable {
    private struct HSL: Equatable, Sendable {
        var hue: Double, saturation: Double, lightness: Double
    }

    private let from: HSL
    private let to: HSL
    private let turn: Double

    init(red: Double, green: Double, blue: Double, isDark: Bool) {
        let (start, chroma) = Self.hsl(red: red, green: green, blue: blue)
        if chroma < 0.06 {
            let ember = ThinkingRGB(isDark ? 0xFF8A7A : 0xF0624E)
            let (target, _) = Self.hsl(red: ember.red / 255, green: ember.green / 255, blue: ember.blue / 255)
            from = HSL(hue: target.hue, saturation: start.saturation, lightness: start.lightness)
            to = target
            turn = 0
        } else {
            from = start
            to = HSL(
                hue: (start.hue + 180).truncatingRemainder(dividingBy: 360),
                saturation: max(start.saturation, 0.72), lightness: isDark ? 0.64 : 0.5
            )
            turn = 180
        }
    }

    /// The color `amount` of the way along, 0 to 1.
    func color(_ amount: Double, opacity: Double = 1) -> Color {
        let t = thinkingClamp(amount)
        let hue = (from.hue + turn * t).truncatingRemainder(dividingBy: 360)
        let rgb = Self.rgb(
            hue: hue, saturation: thinkingLerp(from.saturation, to.saturation, t),
            lightness: thinkingLerp(from.lightness, to.lightness, t)
        )
        return Color(.sRGB, red: rgb.0, green: rgb.1, blue: rgb.2, opacity: opacity)
    }

    /// The same color for a mark on a thumb. Every thumb is light, in both modes, so the mark is
    /// never lighter than a mid tone: night's Ink is nearly white, and its dot vanished on the thumb.
    func thumbMark(_ amount: Double, opacity: Double = 1) -> Color {
        let t = thinkingClamp(amount)
        let hue = (from.hue + turn * t).truncatingRemainder(dividingBy: 360)
        let rgb = Self.rgb(
            hue: hue, saturation: thinkingLerp(from.saturation, to.saturation, t),
            lightness: min(thinkingLerp(from.lightness, to.lightness, t), 0.46)
        )
        return Color(.sRGB, red: rgb.0, green: rgb.1, blue: rgb.2, opacity: opacity)
    }

    /// Where a point at `place` sits between the two colors: all the person's at the bottom of the
    /// ladder, mostly the opposite at the top, with bands flowing toward the thumb.
    static func shade(_ level: Double, _ place: Double, flow: Double) -> Double {
        thinkingClamp(level * 0.85 + level * 0.45 * sin(thinkingTau * (place - flow)))
    }

    /// Hue in degrees, and the chroma that tells a neutral apart.
    private static func hsl(red: Double, green: Double, blue: Double) -> (HSL, Double) {
        let high = max(red, green, blue), low = min(red, green, blue), chroma = high - low
        let lightness = (high + low) / 2
        var hue = 0.0, saturation = 0.0
        if chroma > 0 {
            saturation = lightness > 0.5 ? chroma / (2 - high - low) : chroma / (high + low)
            if high == red {
                hue = (green - blue) / chroma + (green < blue ? 6 : 0)
            } else if high == green {
                hue = (blue - red) / chroma + 2
            } else {
                hue = (red - green) / chroma + 4
            }
            hue *= 60
        }
        return (HSL(hue: hue, saturation: saturation, lightness: lightness), chroma)
    }

    private static func rgb(hue: Double, saturation: Double, lightness: Double) -> (Double, Double, Double) {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = hue / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch sector {
        case ..<1: (chroma, second, 0)
        case ..<2: (second, chroma, 0)
        case ..<3: (0, chroma, second)
        case ..<4: (0, second, chroma)
        case ..<5: (second, 0, chroma)
        default: (chroma, 0, second)
        }
        let base = lightness - chroma / 2
        return (r + base, g + base, b + base)
    }
}

/// Filling every dot or thread with its own opacity would be hundreds of draws a frame. Grouping them
/// into a few opacities makes it a handful, with no visible difference at this size.
struct ThinkingOpacityBuckets {
    private(set) var paths: [Path]

    init(count: Int) { paths = Array(repeating: Path(), count: count) }

    mutating func append(opacity: Double, _ add: (inout Path) -> Void) {
        let index = min(max(Int(opacity * Double(paths.count)), 0), paths.count - 1)
        add(&paths[index])
    }

    func opacity(at index: Int) -> Double { (Double(index) + 0.5) / Double(paths.count) }
}

extension Path {
    /// A circle as its own closed contour, for paths that batch many dots.
    mutating func addThinkingDot(_ x: Double, _ y: Double, radius: Double) {
        addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }

    /// A circle drawn point by point in a known direction, so nonzero fill can punch holes: angles
    /// rising for a solid, falling for a hole.
    mutating func addThinkingRing(_ x: Double, _ y: Double, radius: Double, isHole: Bool) {
        let segments = max(12, Int(radius * 2.5))
        for step in 0...segments {
            let angle = thinkingTau * Double(isHole ? segments - step : step) / Double(segments)
            let point = CGPoint(x: x + cos(angle) * radius, y: y + sin(angle) * radius)
            if step == 0 { move(to: point) } else { addLine(to: point) }
        }
        closeSubpath()
    }
}

extension GraphicsContext {
    func fillThinkingTrack(_ frame: ThinkingSliderFrame, _ color: Color) {
        fill(Path(CGRect(x: 0, y: 0, width: frame.width, height: frame.height)), with: .color(color))
    }

    /// A round knob with a soft shadow under it. A blur filter every frame costs too much, so the
    /// shadow is a radial gradient ring, a little low, as hermex's round thumb draws it.
    func drawThinkingKnob(x: Double, y: Double, radius: Double, fill color: Color, shadow: Color) {
        let spread = 6.0
        let center = CGPoint(x: x, y: y + 1.5)
        fill(
            Path(ellipseIn: CGRect(x: x - radius - spread, y: center.y - radius - spread, width: (radius + spread) * 2, height: (radius + spread) * 2)),
            with: .radialGradient(Gradient(colors: [shadow, shadow.opacity(0)]), center: center, startRadius: radius - 3, endRadius: radius + spread)
        )
        fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
    }

    /// The same soft shadow for a knob that isn't round: the outline stroked wide and faint, then
    /// narrower and stronger, a little low.
    func drawThinkingShadow(_ shape: Path, _ shadow: Color, drop: Double = 1.5) {
        let low = shape.offsetBy(dx: 0, dy: drop)
        stroke(low, with: .color(shadow.opacity(0.35)), lineWidth: 9)
        stroke(low, with: .color(shadow.opacity(0.6)), lineWidth: 4)
    }

    /// A glow along a line: wide faint strokes under it, in place of a shadow blur.
    func strokeThinkingGlow(_ shape: Path, _ color: Color, spread: Double, lineWidth: Double) {
        guard spread > 0 else { return }
        let style = StrokeStyle(lineWidth: lineWidth + spread * 1.6, lineCap: .round, lineJoin: .round)
        stroke(shape, with: .color(color.opacity(0.18)), style: style)
        stroke(shape, with: .color(color.opacity(0.3)), style: StrokeStyle(lineWidth: lineWidth + spread * 0.7, lineCap: .round, lineJoin: .round))
    }
}
