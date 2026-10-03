import SwiftUI

/// The weather behind a card. It owns all of the animation; the card's content
/// only sees a dark color scheme. It draws its still gradient, and animates on
/// top of it only while `CardBackgroundAnimationPolicy` allows, so a chat full
/// of weather cards runs one Canvas per card on screen and none for the rest.
struct CardBackgroundView: View {
    let background: CardBackground

    @BighelpLoaderMotionReader private var motion
    @Environment(\.isCardSnapshot) private var isSnapshot
    @State private var isOnScreen = false

    var body: some View {
        let look = CardBackgroundLook(scene: background.scene, timeOfDay: background.timeOfDay)
        let animates = CardBackgroundAnimationPolicy.animates(
            background, motion: motion, isOnScreen: isOnScreen, isSnapshot: isSnapshot)
        ZStack {
            LinearGradient(colors: look.sky.map(\.color), startPoint: .top, endPoint: .bottom)
            look.scrim.color.opacity(look.scrimOpacity)
            // Not animating removes the clock altogether rather than pausing it.
            if animates, let scene = background.scene {
                TimelineView(.animation(minimumInterval: CardWeatherPainter.frameInterval(scene))) { timeline in
                    Canvas { context, size in
                        CardWeatherPainter.draw(in: &context, size: size,
                                                time: timeline.date.timeIntervalSinceReferenceDate,
                                                scene: scene, background: background, look: look)
                    }
                }
            }
        }
        .clipped()
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Draws one frame of a scene from the clock alone. Every particle's place is
/// a function of its index and the time, so there's no per-card state to keep
/// and a paused card costs nothing. Particles of one kind share one path and
/// one fill, and their count is capped by intensity.
enum CardWeatherPainter {
    static let maximumParticles = 96

    static func particleCount(_ scene: CardBackground.Scene, _ intensity: CardBackground.Intensity) -> Int {
        let counts: [Int] = switch scene {
        case .rain: [28, 52, 84]
        case .thunderstorm: [36, 60, 90]
        case .snow: [20, 38, 64]
        // Stars, drawn at night.
        case .clear: [16, 24, 32]
        case .partlyCloudy: [10, 16, 22]
        case .wind: [5, 9, 14]
        case .none, .overcast, .fog: [0, 0, 0]
        }
        return min(counts[CardBackground.Intensity.allCases.firstIndex(of: intensity) ?? 1], maximumParticles)
    }

    /// Falling things need a smooth clock; drifting clouds and fog look the
    /// same at fewer frames.
    static func frameInterval(_ scene: CardBackground.Scene) -> TimeInterval {
        switch scene {
        case .rain, .thunderstorm, .snow, .wind: BighelpLoaderCadence.soft.minimumInterval
        case .none, .clear, .partlyCloudy, .overcast, .fog: BighelpLoaderCadence.ambient.minimumInterval
        }
    }

    static func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval,
                     scene: CardBackground.Scene, background: CardBackground, look: CardBackgroundLook) {
        guard size.width > 1, size.height > 1 else { return }
        let level = Double(CardBackground.Intensity.allCases.firstIndex(of: background.intensity) ?? 1)
        let count = particleCount(scene, background.intensity)
        let isNight = background.timeOfDay == .night
        if let glow = look.glow { drawGlow(glow, in: &context, size: size, time: time, timeOfDay: background.timeOfDay) }
        if isNight, scene == .clear || scene == .partlyCloudy {
            drawStars(count, peak: look.fineParticlePeak, in: &context, size: size, time: time)
        }
        if let cloud = look.cloud {
            let groups = scene == .overcast ? 3 + Int(level) : scene == .partlyCloudy ? 1 + Int(level) : 2
            drawClouds(groups, light: cloud, in: &context, size: size, time: time, speed: scene == .thunderstorm ? 9 : 5)
        }
        if let mist = look.mist {
            let banks = scene == .fog ? 2 + Int(level) : 1
            drawMist(banks, light: mist, in: &context, size: size, time: time,
                     speed: scene == .wind ? 28 : 7, low: scene != .fog)
        }
        switch scene {
        case .rain, .thunderstorm:
            drawRain(count, level: level, peak: look.fineParticlePeak, in: &context, size: size, time: time)
        case .snow:
            drawSnow(count, peak: look.fineParticlePeak, in: &context, size: size, time: time)
        case .wind:
            drawGusts(count, peak: look.fineParticlePeak, in: &context, size: size, time: time)
        case .none, .clear, .partlyCloudy, .overcast, .fog:
            break
        }
        if let flash = look.flash {
            drawLightning(flash, level: level, peak: look.fineParticlePeak, in: &context, size: size, time: time)
        }
    }

    // MARK: Layers

    private static func drawGlow(_ glow: CardBackgroundLight, in context: inout GraphicsContext, size: CGSize,
                                 time: TimeInterval, timeOfDay: CardBackground.TimeOfDay) {
        let extent = max(size.width, size.height)
        let (center, radius): (CGPoint, CGFloat) = switch timeOfDay {
        case .day: (CGPoint(x: size.width * 0.86, y: size.height * 0.04), extent * 0.7)
        case .dusk: (CGPoint(x: size.width * 0.78, y: size.height * 1.02), extent * 0.75)
        case .night: (CGPoint(x: size.width * 0.86, y: size.height * 0.1), extent * 0.42)
        }
        // A slow breath, never above the peak the contrast check allows.
        let strength = glow.peak * (0.8 + 0.2 * sin(time * 2 * .pi / 7))
        let drift = CGFloat(sin(time * 2 * .pi / 23)) * size.width * 0.02
        let middle = CGPoint(x: center.x + drift, y: center.y)
        context.fill(
            Path(ellipseIn: CGRect(x: middle.x - radius, y: middle.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(colors: [glow.color.color.opacity(strength), glow.color.color.opacity(0)]),
                center: middle, startRadius: 0, endRadius: radius))
    }

    private static func drawStars(_ count: Int, peak: Double, in context: inout GraphicsContext, size: CGSize,
                                  time: TimeInterval) {
        // Four brightness steps, one fill each, rather than one fill per star.
        var steps = Array(repeating: Path(), count: 4)
        for index in 0..<count {
            let x = noise(index, 1) * size.width
            let y = noise(index, 2) * size.height * 0.8
            let radius = 0.5 + noise(index, 3) * 0.8
            let twinkle = 0.5 + 0.5 * sin(time * (0.8 + noise(index, 4) * 1.6) + noise(index, 5) * 2 * .pi)
            let step = min(3, Int(twinkle * 4))
            steps[step].addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        for (step, path) in steps.enumerated() {
            context.fill(path, with: .color(.white.opacity(peak * (0.4 + 0.2 * Double(step)))))
        }
    }

    /// Puffs of overlapping circles drifting sideways. Two nested outlines, each
    /// filled once at half strength, give a soft edge without a blur, and
    /// overlapping puffs never add up past the peak.
    private static func drawClouds(_ groups: Int, light: CardBackgroundLight, in context: inout GraphicsContext,
                                   size: CGSize, time: TimeInterval, speed: Double) {
        var outer = Path(), inner = Path()
        for group in 0..<groups {
            let width = size.width * (0.45 + noise(group, 11) * 0.3)
            let height = width * 0.32
            let travel = size.width + width
            let x = (noise(group, 12) * travel + time * speed * (0.7 + noise(group, 13) * 0.6))
                .truncatingRemainder(dividingBy: travel) - width
            let y = size.height * (0.05 + noise(group, 14) * 0.55)
            for puff in 0..<5 {
                let px = x + width * (0.12 + 0.19 * Double(puff))
                let lift = puff == 0 || puff == 4 ? 0.25 : (puff == 2 ? 0.75 : 0.55)
                let radius = height * (0.45 + lift * 0.45)
                let py = y + height - radius * (0.6 + lift * 0.5)
                outer.addEllipse(in: CGRect(x: px - radius, y: py - radius, width: radius * 2, height: radius * 2))
                let core = radius * 0.7
                inner.addEllipse(in: CGRect(x: px - core, y: py - core + radius * 0.1, width: core * 2, height: core * 2))
            }
        }
        context.fill(outer, with: .color(light.color.color.opacity(light.peak / 2)))
        context.fill(inner, with: .color(light.color.color.opacity(light.peak / 2)))
    }

    private static func drawMist(_ banks: Int, light: CardBackgroundLight, in context: inout GraphicsContext,
                                 size: CGSize, time: TimeInterval, speed: Double, low: Bool) {
        var outer = Path(), inner = Path()
        let breath = 0.8 + 0.2 * sin(time * 2 * .pi / 11)
        for bank in 0..<banks {
            let width = size.width * (1.1 + noise(bank, 21) * 0.6)
            let height = size.height * (low ? 0.22 : 0.2 + noise(bank, 22) * 0.14)
            let travel = size.width + width
            let direction = bank.isMultiple(of: 2) ? 1.0 : -1.0
            let offset = (noise(bank, 23) * travel + direction * time * speed * (0.6 + noise(bank, 24) * 0.8))
                .truncatingRemainder(dividingBy: travel)
            let x = (offset < 0 ? offset + travel : offset) - width
            let y = low ? size.height - height * 0.8
                : size.height * (Double(bank) + 0.2 + noise(bank, 25) * 0.5) / Double(banks) - height / 2
            let rect = CGRect(x: x, y: y, width: width, height: height)
            outer.addRoundedRect(in: rect, cornerSize: CGSize(width: height / 2, height: height / 2))
            let core = rect.insetBy(dx: width * 0.12, dy: height * 0.22)
            inner.addRoundedRect(in: core, cornerSize: CGSize(width: core.height / 2, height: core.height / 2))
        }
        context.fill(outer, with: .color(light.color.color.opacity(light.peak * breath / 2)))
        context.fill(inner, with: .color(light.color.color.opacity(light.peak * breath / 2)))
    }

    private static func drawRain(_ count: Int, level: Double, peak: Double, in context: inout GraphicsContext,
                                 size: CGSize, time: TimeInterval) {
        let slant = 0.16 + level * 0.04
        let length = 10 + level * 4
        let speed = 380 + level * 90
        var path = Path()
        for index in 0..<count {
            let fall = speed * (0.8 + noise(index, 31) * 0.4)
            let span = size.height + length
            let y = (noise(index, 32) * span + time * fall).truncatingRemainder(dividingBy: span) - length
            let x = noise(index, 33) * (size.width + slant * size.height) - slant * size.height + slant * y
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + slant * length, y: y + length))
        }
        context.stroke(path, with: .color(.white.opacity(peak * 0.85)),
                       style: StrokeStyle(lineWidth: 1 + level * 0.15, lineCap: .round))
    }

    private static func drawSnow(_ count: Int, peak: Double, in context: inout GraphicsContext, size: CGSize,
                                 time: TimeInterval) {
        // Far flakes are smaller and fainter, near ones bigger: two fills.
        var far = Path(), near = Path()
        for index in 0..<count {
            let isNear = noise(index, 41) > 0.6
            let radius = isNear ? 1.6 + noise(index, 42) * 0.9 : 0.9 + noise(index, 42) * 0.6
            let fall = (isNear ? 34 : 20) * (0.8 + noise(index, 43) * 0.4)
            let span = size.height + radius * 2
            let y = (noise(index, 44) * span + time * fall).truncatingRemainder(dividingBy: span) - radius
            let sway = sin(time * (0.6 + noise(index, 45)) + noise(index, 46) * 2 * .pi) * (isNear ? 9 : 5)
            let x = noise(index, 47) * size.width + sway
            let flake = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            if isNear { near.addEllipse(in: flake) } else { far.addEllipse(in: flake) }
        }
        context.fill(far, with: .color(.white.opacity(peak * 0.6)))
        context.fill(near, with: .color(.white.opacity(peak)))
    }

    private static func drawGusts(_ count: Int, peak: Double, in context: inout GraphicsContext, size: CGSize,
                                  time: TimeInterval) {
        var path = Path()
        for index in 0..<count {
            let length = 40 + noise(index, 51) * 50
            let speed = 160 + noise(index, 52) * 120
            let span = size.width + length * 2
            let x = (noise(index, 53) * span + time * speed).truncatingRemainder(dividingBy: span) - length
            let y = size.height * (0.1 + noise(index, 54) * 0.8)
            let wave = 4 + noise(index, 55) * 6
            path.move(to: CGPoint(x: x, y: y))
            path.addQuadCurve(to: CGPoint(x: x + length, y: y - wave * 0.4),
                              control: CGPoint(x: x + length * 0.5, y: y + wave))
        }
        context.stroke(path, with: .color(.white.opacity(peak * 0.8)),
                       style: StrokeStyle(lineWidth: 1, lineCap: .round))
    }

    /// A quick double flicker every few seconds, sooner in a heavier storm,
    /// with a thin bolt while it lasts.
    private static func drawLightning(_ flash: CardBackgroundLight, level: Double, peak: Double,
                                      in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let period = 9 - level * 2.5
        let cycle = Int((time / period).rounded(.down))
        let moment = time - Double(cycle) * period
        let strength: Double = switch moment {
        case 0..<0.1: 1
        case 0.18..<0.3: 0.6
        default: 0
        }
        guard strength > 0 else { return }
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(flash.color.color.opacity(flash.peak * strength)))
        var bolt = Path()
        var point = CGPoint(x: size.width * (0.2 + noise(cycle, 61) * 0.6), y: 0)
        bolt.move(to: point)
        for step in 0..<6 {
            point.x += (noise(cycle, 62 + step) - 0.5) * size.width * 0.12
            point.y += size.height * 0.11
            bolt.addLine(to: point)
        }
        context.stroke(bolt, with: .color(.white.opacity(peak * strength)),
                       style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
    }

    /// A steady pseudo-random number in 0..<1 for a particle and a purpose.
    private static func noise(_ index: Int, _ salt: Int) -> Double {
        var value = UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(salt) &* 0xD1B5_4A32_D192_ED03
        value ^= value >> 30
        value &*= 0xBF58_476D_1CE4_E5B9
        value ^= value >> 27
        value &*= 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) / Double(UInt64(1) << 53)
    }
}
