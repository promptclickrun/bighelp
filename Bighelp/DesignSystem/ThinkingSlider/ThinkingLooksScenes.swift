import SwiftUI

// The Thinking looks drawn as little scenes: Clockwork, Meadow and Wide Awake. Each has a day and a
// night palette; the numbers are the approved design's.

// MARK: - Clockwork

/// Brass, then copper, then red-hot, at the levels in `stops`.
private struct ClockworkPalette: Sendable {
    let highlight: ThinkingRamp, lowlight: ThinkingRamp, background: ThinkingRamp, edge: ThinkingRamp
    let edgeOpacity: [Double]
    let idle: Color, knob: Color, shadow: Color, spark: Color, glow: ThinkingRGB
    /// Chips fly off in the highlight color at night, in the shadow color by day.
    let chipsGlow: Bool

    static let stops = [0, 0.45, 0.75, 1.0]

    static let light = ClockworkPalette(
        highlight: ThinkingRamp(stops, [0xDDB467, 0xEE9A4C, 0xEE5A35, 0xE5301F]),
        lowlight: ThinkingRamp(stops, [0x8A6125, 0x9A4416, 0x8E1A0D, 0x5E0606]),
        background: ThinkingRamp(stops, [0xF4F0E8, 0xF6ECE2, 0xF8E5DD, 0xFBDCD4]),
        edge: ThinkingRamp(stops, [0x50340F, 0x5A2A0C, 0x5A1206, 0x4A0404]), edgeOpacity: [0.4, 0.42, 0.5, 0.6],
        idle: ThinkingRGB(0x503C1E).color(0.2), knob: ThinkingRGB(0xFFFFFF).color(), shadow: ThinkingRGB(0x3C280A).color(0.26),
        spark: ThinkingRGB(0xFF7A2E).color(), glow: ThinkingRGB(0xFF3B1F), chipsGlow: false
    )
    static let dark = ClockworkPalette(
        highlight: ThinkingRamp(stops, [0xF2D59B, 0xFFC27A, 0xFF7A45, 0xFF4530]),
        lowlight: ThinkingRamp(stops, [0xA47432, 0xB5571F, 0xA3200F, 0x6B0606]),
        background: ThinkingRamp(stops, [0x13110E, 0x16100C, 0x1B0C09, 0x250807]),
        edge: ThinkingRamp(stops, [0xFFF0D2, 0xFFD7A0, 0xFFB070, 0xFFE08A]), edgeOpacity: [0.32, 0.38, 0.52, 0.75],
        idle: ThinkingRGB(0xFFF0DC).color(0.14), knob: ThinkingRGB(0xF3ECDF).color(), shadow: ThinkingRGB(0x000000).color(0.6),
        spark: ThinkingRGB(0xFFE7B0).color(), glow: ThinkingRGB(0xFF3B1F), chipsGlow: true
    )
}

extension BighelpThinkingLook {
    /// A big and a small gear in turn along the track, each meshed with the one before.
    private static func layOutGears(width: Double, height: Double) -> [ThinkingSliderStore.Gear] {
        let middle = height / 2
        let specs: [(radius: Double, teeth: Int, y: Double, isBig: Bool)] = [(18, 14, middle + 4.5, true), (10.5, 8, middle - 8.5, false)]
        var gears: [ThinkingSliderStore.Gear] = []
        var x = -4.0
        for index in 0... {
            let spec = specs[index % 2]
            if let previous = gears.last {
                let rise = spec.y - previous.y, reach = previous.radius + spec.radius
                x = previous.x + (reach * reach - rise * rise).squareRoot()
            }
            gears.append(.init(x: x, y: spec.y, radius: spec.radius, teeth: spec.teeth, isBig: spec.isBig))
            if x > width + 24 { break }
        }
        return gears
    }

    /// One gear at `angle`: teeth, and for a big gear a rim, three spokes and a hub. Holes run the
    /// other way round, so the default nonzero fill leaves them empty.
    private static func gearPath(x: Double, y: Double, radius: Double, teeth: Int, isBig: Bool, angle: Double) -> Path {
        var path = Path()
        let step = thinkingTau / Double(teeth), outer = radius + 2.4, inner = radius - 2.2
        func point(_ reach: Double, _ turn: Double) -> CGPoint {
            CGPoint(x: x + cos(turn) * reach, y: y + sin(turn) * reach)
        }
        for tooth in 0..<teeth {
            let center = angle + Double(tooth) * step
            if tooth == 0 { path.move(to: point(inner, center - 0.5 * step)) } else { path.addLine(to: point(inner, center - 0.5 * step)) }
            path.addLine(to: point(inner, center - 0.26 * step))
            path.addLine(to: point(outer, center - 0.15 * step))
            path.addLine(to: point(outer, center + 0.15 * step))
            path.addLine(to: point(inner, center + 0.26 * step))
        }
        path.closeSubpath()
        if isBig {
            let hole = radius - 6.2
            path.addThinkingRing(x, y, radius: hole, isHole: true)
            for spoke in 0..<3 {
                let turn = angle + Double(spoke) * thinkingTau / 3 + 0.3
                let ux = cos(turn), uy = sin(turn), vx = -uy, vy = ux, half = 1.3, start = 2.0, end = hole + 0.5
                path.move(to: CGPoint(x: x + ux * start - vx * half, y: y + uy * start - vy * half))
                path.addLine(to: CGPoint(x: x + ux * end - vx * half, y: y + uy * end - vy * half))
                path.addLine(to: CGPoint(x: x + ux * end + vx * half, y: y + uy * end + vy * half))
                path.addLine(to: CGPoint(x: x + ux * start + vx * half, y: y + uy * start + vy * half))
                path.closeSubpath()
            }
            path.addThinkingRing(x, y, radius: 3.6, isHole: false)
            path.addThinkingRing(x, y, radius: 1.4, isHole: true)
        } else {
            path.addThinkingRing(x, y, radius: 2, isHole: true)
        }
        return path
    }

    /// A gear train the thumb engages like a clutch. Pushed hard it heats from brass to red-hot,
    /// shakes on its axles and throws sparks and chips.
    static func drawClockwork(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore, _ paint: ThinkingPaint) {
        let palette = paint.isDark ? ClockworkPalette.dark : ClockworkPalette.light
        let level = frame.active, live = frame.isLive
        if level > 0 { store.phase += frame.delta * (0.35 + 7.5 * level * level) }
        if store.gears.isEmpty || store.layoutWidth != frame.width {
            store.gears = layOutGears(width: frame.width, height: frame.height)
            store.layoutWidth = frame.width
        }
        context.fillThinkingTrack(frame, palette.background.at(level).color())
        let highlight = palette.highlight.at(level), lowlight = palette.lowlight.at(level)
        let metal = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [highlight.color(), lowlight.color()]),
            startPoint: CGPoint(x: 0, y: 6), endPoint: CGPoint(x: 0, y: frame.height - 4)
        )
        let edge = palette.edge.at(level).color(ThinkingRamp.number(ClockworkPalette.stops, palette.edgeOpacity, level))
        // Shaking starts past High and grows hard toward the top; every third gear is loose and sags.
        let shake = pow(thinkingClamp((level - 0.4) / 0.6), 1.6), heat = thinkingClamp((level - 0.7) / 0.3)
        var sparks = Path()
        for index in store.gears.indices {
            var gear = store.gears[index]
            // Meshed: a tooth of the last gear faces a gap of this one along the line between their centers.
            if index == 0 {
                gear.chain = store.phase
            } else {
                let previous = store.gears[index - 1], line = atan2(gear.y - previous.y, gear.x - previous.x)
                gear.chain = -(previous.chain - line) * (Double(previous.teeth) / Double(gear.teeth)) + line + .pi - .pi / Double(gear.teeth)
            }
            let isOn = gear.x < frame.thumbX - 2
            if isOn || gear.angle == nil { gear.angle = gear.chain }
            let goal = isOn ? 1.0 : 0
            let mix = gear.mix.map { live ? $0 + (goal - $0) * min(1, frame.delta * 10) : goal } ?? goal
            gear.mix = mix
            let isLoose = index % 3 == 1, force = isOn ? shake * (isLoose ? 1.7 : 1) : 0
            let seed = Double(index)
            let wobble = live ? sin(frame.time * 53 + seed * 2.3) * 0.6 + sin(frame.time * 89 + seed * 4.1) * 0.4 : 0
            let bounce = live ? sin(frame.time * 61 + seed * 1.3) * 0.6 + sin(frame.time * 97 + seed * 3.7) * 0.4 : 0
            gear.shownX = gear.x + force * 2.6 * wobble
            gear.shownY = gear.y + force * 2.2 * bounce + (isLoose ? force * 1.6 : 0)
            store.gears[index] = gear

            let path = gearPath(
                x: gear.shownX, y: gear.shownY, radius: gear.radius, teeth: gear.teeth, isBig: gear.isBig,
                angle: (gear.angle ?? gear.chain) + force * 0.14 * wobble
            )
            if mix < 1 {
                context.opacity = 1 - mix
                context.stroke(path, with: .color(palette.idle), lineWidth: 1)
            }
            if mix > 0 {
                context.opacity = mix
                if heat > 0 { context.strokeThinkingGlow(path, palette.glow.color(0.85 * heat), spread: 9 * heat * 0.6, lineWidth: 1) }
                context.fill(path, with: metal)
                context.stroke(path, with: .color(edge), lineWidth: 0.7 + 0.5 * heat)
            }
            context.opacity = 1

            if level > 0.55, index > 0, isOn, live {
                let previous = store.gears[index - 1]
                let share = previous.radius / (previous.radius + gear.radius), strength = (level - 0.55) / 0.45
                for spark in 0..<2 where thinkingRandom(floor(frame.time * 24) + seed * 7.1 + Double(spark) * 3.3) > 0.72 - 0.42 * strength {
                    let sparkX = previous.shownX + (gear.shownX - previous.shownX) * share + (thinkingChance() - 0.5) * 4
                    let sparkY = previous.shownY + (gear.shownY - previous.shownY) * share + (thinkingChance() - 0.5) * 4
                    sparks.addThinkingDot(sparkX, sparkY, radius: 0.9 + 1.3 * strength)
                }
            }
            if isOn, live, level > 0.7, store.chips.count < 40, thinkingChance() < frame.delta * 0.9 * (level - 0.7) / 0.3 {
                let turn = thinkingChance() * thinkingTau
                store.chips.append(.init(
                    x: gear.shownX + cos(turn) * gear.radius, y: gear.shownY + sin(turn) * gear.radius,
                    vx: (thinkingChance() - 0.5) * 50, vy: -25 - thinkingChance() * 45, rotation: thinkingChance() * thinkingTau,
                    spin: (thinkingChance() - 0.5) * 24, size: 1 + thinkingChance() * 1.4
                ))
            }
        }
        if level > 0.55 {
            context.opacity = thinkingClamp((level - 0.55) / 0.3)
            context.fill(sparks, with: .color(palette.spark))
            context.opacity = 1
        }
        if live, !store.chips.isEmpty {
            for index in store.chips.indices {
                store.chips[index].vy += 260 * frame.delta
                store.chips[index].x += store.chips[index].vx * frame.delta
                store.chips[index].y += store.chips[index].vy * frame.delta
                store.chips[index].rotation += store.chips[index].spin * frame.delta
            }
            store.chips.removeAll { $0.y >= frame.height + 6 }
        }
        if !store.chips.isEmpty {
            var bits = Path()
            for chip in store.chips {
                let across = cos(chip.rotation) * chip.size, down = sin(chip.rotation) * chip.size
                bits.move(to: CGPoint(x: chip.x + across, y: chip.y + down))
                bits.addLine(to: CGPoint(x: chip.x - down, y: chip.y + across))
                bits.addLine(to: CGPoint(x: chip.x - across, y: chip.y - down))
                bits.addLine(to: CGPoint(x: chip.x + down, y: chip.y - across))
                bits.closeSubpath()
            }
            context.fill(bits, with: .color((palette.chipsGlow ? highlight : lowlight).color()))
        }
    }

    /// A knurled knob with a metal boss that heats with the gears.
    static func drawClockworkThumb(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore, _ paint: ThinkingPaint) {
        let palette = paint.isDark ? ClockworkPalette.dark : ClockworkPalette.light
        let x = frame.thumbX, y = frame.middle, level = frame.active
        let highlight = palette.highlight.at(level), lowlight = palette.lowlight.at(level)
        context.drawThinkingKnob(x: x, y: y, radius: 20, fill: palette.knob, shadow: palette.shadow)
        var knurl = Path()
        let turn = store.phase * 0.35
        for notch in 0..<30 {
            let angle = turn + Double(notch) * thinkingTau / 30
            knurl.move(to: CGPoint(x: x + cos(angle) * 16.2, y: y + sin(angle) * 16.2))
            knurl.addLine(to: CGPoint(x: x + cos(angle) * 19, y: y + sin(angle) * 19))
        }
        context.stroke(knurl, with: .color(lowlight.color(0.6)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        var boss = Path()
        boss.addThinkingDot(x, y, radius: 6)
        context.fill(boss, with: .radialGradient(
            Gradient(colors: [highlight.color(), lowlight.color()]),
            center: CGPoint(x: x - 2, y: y - 2), startRadius: 0.5, endRadius: 8.5
        ))
    }
}

// MARK: - Meadow

private struct MeadowPalette: Sendable {
    let background: Color, blades: [Color], dim: Color, flowers: [Color], mote: Color
    /// Fireflies glow at night; by day they are pollen.
    let motesGlow: Bool
    let soil: Color, knob: Color, leaf: Color, shadow: Color

    static let light = MeadowPalette(
        background: ThinkingRGB(0xEEF5EC).color(),
        blades: [ThinkingRGB(0x3D8A56).color(), ThinkingRGB(0x2C7044).color(), ThinkingRGB(0x63A86F).color()],
        dim: ThinkingRGB(0x326441).color(0.24),
        flowers: [ThinkingRGB(0xF0624E).color(), ThinkingRGB(0x8F75EC).color(), ThinkingRGB(0xA9C230).color(), ThinkingRGB(0x3BA9E0).color()],
        mote: ThinkingRGB(0xC99A2E).color(), motesGlow: false, soil: ThinkingRGB(0x326441).color(0.12),
        knob: ThinkingRGB(0xFFFFFF).color(), leaf: ThinkingRGB(0x2C7044).color(), shadow: ThinkingRGB(0x1E4628).color(0.26)
    )
    static let dark = MeadowPalette(
        background: ThinkingRGB(0x0A110E).color(),
        blades: [ThinkingRGB(0x2D6446).color(), ThinkingRGB(0x3E8659).color(), ThinkingRGB(0x5AAE76).color()],
        dim: ThinkingRGB(0x78AA8C).color(0.17),
        flowers: [ThinkingRGB(0xFF8A7A).color(), ThinkingRGB(0xC9B6FF).color(), ThinkingRGB(0xE6F27C).color(), ThinkingRGB(0x9ED8FF).color()],
        mote: ThinkingRGB(0xF6F0A2).color(), motesGlow: true, soil: ThinkingRGB(0x78AA8C).color(0.1),
        knob: ThinkingRGB(0xEEF4EE).color(), leaf: ThinkingRGB(0x3E8659).color(), shadow: ThinkingRGB(0x000000).color(0.6)
    )
}

extension BighelpThinkingLook {
    /// Grass grows up to the thumb and sways; thinking harder raises the wind, then flowers open and
    /// fireflies (pollen by day) come out.
    static func drawMeadow(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore, _ paint: ThinkingPaint) {
        let palette = paint.isDark ? MeadowPalette.dark : MeadowPalette.light
        let level = frame.active
        if level > 0 { store.phase += frame.delta * (0.5 + 3.2 * level) }
        let wind = store.phase
        if store.blades.isEmpty || store.layoutWidth != frame.width {
            let count = Int((frame.width / 3.1).rounded(.up))
            store.blades = (0..<count).map { index in
                let seed = Double(index)
                return .init(
                    x: seed * 3.1 + thinkingRandom(seed) * 2.2, reach: thinkingRandom(seed + 40),
                    shade: min(Int(thinkingRandom(seed + 80) * 3), 2),
                    flower: thinkingRandom(seed + 120) < 0.13 ? min(Int(thinkingRandom(seed + 160) * 4), 3) : -1,
                    phase: thinkingRandom(seed + 200) * thinkingTau
                )
            }
            store.layoutWidth = frame.width
        }
        context.fillThinkingTrack(frame, palette.background)
        let base = frame.height - 3, tallest = frame.height - 12
        context.fill(Path(CGRect(x: 0, y: base, width: frame.width, height: 3)), with: .color(palette.soil))

        let bloom = thinkingClamp((level - 0.55) / 0.3), flowerRadius = 1 + 2 * bloom
        var lit = [Path(), Path(), Path()], dim = Path(), flowers = [Path(), Path(), Path(), Path()]
        let gust = 0.6 + 0.4 * sin(wind * 0.37), reachWidth = max(frame.thumbX, 1)
        for blade in store.blades {
            let isOn = blade.x < frame.thumbX - 6
            let height: Double, sway: Double
            if isOn {
                let rise = 0.5 + 0.5 * thinkingClamp(blade.x / reachWidth)
                height = 4 + tallest * (0.12 + 0.88 * level) * (0.45 + 0.55 * blade.reach) * rise
                sway = (1 + 10 * level * gust) * sin(wind * 1.7 + blade.x * 0.035 + blade.phase * 0.3) * (height / tallest)
                    + 0.8 * level * sin(wind * 4.1 + blade.phase)
            } else {
                height = 2.5 + 2.5 * blade.reach
                sway = 0
            }
            let tip = CGPoint(x: blade.x + sway, y: base - height)
            let control = CGPoint(x: blade.x + sway * 0.25, y: base - height * 0.55)
            if isOn {
                lit[blade.shade].move(to: CGPoint(x: blade.x, y: base))
                lit[blade.shade].addQuadCurve(to: tip, control: control)
                if bloom > 0, blade.flower >= 0 { flowers[blade.flower].addThinkingDot(tip.x, tip.y, radius: flowerRadius) }
            } else {
                dim.move(to: CGPoint(x: blade.x, y: base))
                dim.addQuadCurve(to: tip, control: control)
            }
        }
        let style = StrokeStyle(lineWidth: 1.6, lineCap: .round)
        context.stroke(dim, with: .color(palette.dim), style: style)
        for shade in lit.indices { context.stroke(lit[shade], with: .color(palette.blades[shade]), style: style) }
        if bloom > 0 {
            for kind in flowers.indices { context.fill(flowers[kind], with: .color(palette.flowers[kind])) }
        }

        let wanted = level > 0.78 ? Int((22 * (level - 0.78) / 0.22).rounded()) : 0
        while store.motes.count < wanted {
            store.motes.append(.init(
                x: thinkingChance() * frame.thumbX, y: frame.height * (0.25 + thinkingChance() * 0.55),
                speed: 4 + thinkingChance() * 8, phase: thinkingChance() * thinkingTau
            ))
        }
        if store.motes.count > wanted { store.motes.removeLast(store.motes.count - wanted) }
        guard !store.motes.isEmpty else { return }
        var motes = Path(), halos = Path()
        for index in store.motes.indices {
            var mote = store.motes[index]
            mote.x += frame.delta * (mote.speed + 22 * level)
            mote.y += frame.delta * (sin(frame.time * 2 + mote.phase) * 6 - 2)
            if mote.x > frame.thumbX - 10 || mote.y < 4 {
                mote.x = thinkingChance() * 30
                mote.y = frame.height * (0.3 + thinkingChance() * 0.5)
            }
            store.motes[index] = mote
            let radius = 0.9 + 0.7 * abs(sin(frame.time * 3 + mote.phase))
            motes.addThinkingDot(mote.x, mote.y, radius: radius)
            if palette.motesGlow { halos.addThinkingDot(mote.x, mote.y, radius: radius + 3) }
        }
        context.opacity = thinkingClamp((level - 0.78) / 0.12)
        // A firefly's glow is a faint disc around it, in place of a shadow blur.
        if palette.motesGlow { context.fill(halos, with: .color(palette.mote.opacity(0.25))) }
        context.fill(motes, with: .color(palette.mote))
        context.opacity = 1
    }

    /// A knob with a sprout that leans in the wind.
    static func drawMeadowThumb(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore, _ paint: ThinkingPaint) {
        let palette = paint.isDark ? MeadowPalette.dark : MeadowPalette.light
        let x = frame.thumbX, y = frame.middle
        context.drawThinkingKnob(x: x, y: y, radius: 20, fill: palette.knob, shadow: palette.shadow)
        let lean = 0.18 * frame.active * sin(store.phase * 1.7)
        let place = CGAffineTransform(rotationAngle: lean).concatenating(CGAffineTransform(translationX: x, y: y + 8))
        var stem = Path()
        stem.move(to: .zero)
        stem.addLine(to: CGPoint(x: 0, y: -10))
        context.stroke(stem.applying(place), with: .color(palette.leaf), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        func leaf(_ centerX: Double, _ centerY: Double, _ turn: Double) -> Path {
            Path(ellipseIn: CGRect(x: -4.6, y: -2.4, width: 9.2, height: 4.8))
                .applying(CGAffineTransform(rotationAngle: turn).concatenating(CGAffineTransform(translationX: centerX, y: centerY)))
                .applying(place)
        }
        var leaves = leaf(-4.4, -10.5, -0.55)
        leaves.addPath(leaf(4.4, -12.5, 0.55))
        context.fill(leaves, with: .color(palette.leaf))
    }
}

// MARK: - Wide Awake

/// Calm lilac, then hot pink, then red, at the levels in `stops`.
private struct AwakePalette: Sendable {
    let highlight: ThinkingRamp, middle: ThinkingRamp, lowlight: ThinkingRamp, bubble: ThinkingRamp, background: ThinkingRamp
    let eye: Color, sleep: Color, vein: Color, shadow: Color
    let bubbleOpacity: Double, fillOpacity: Double

    static let stops = [0, 0.6, 1.0]

    static let light = AwakePalette(
        highlight: ThinkingRamp(stops, [0xF3EFFF, 0xFFE8F6, 0xFFE6D9]), middle: ThinkingRamp(stops, [0xB5A0FF, 0xF07AC8, 0xFF6A4A]),
        lowlight: ThinkingRamp(stops, [0x7560E0, 0xB0308E, 0xC21E1E]), bubble: ThinkingRamp(stops, [0x6E55D8, 0xC0359A, 0xD8321E]),
        background: ThinkingRamp(stops, [0xF5F2FF, 0xFFF0F8, 0xFFEDE8]),
        eye: ThinkingRGB(0x17122E).color(), sleep: ThinkingRGB(0x503CAA).color(0.6), vein: ThinkingRGB(0xD91E1E).color(),
        shadow: ThinkingRGB(0x3C288C).color(0.3), bubbleOpacity: 0.45, fillOpacity: 0.07
    )
    static let dark = AwakePalette(
        highlight: ThinkingRamp(stops, [0xEEE8FF, 0xFFE3F4, 0xFFE0D2]), middle: ThinkingRamp(stops, [0xB5A0FF, 0xF07AC8, 0xFF6A4A]),
        lowlight: ThinkingRamp(stops, [0x6B55D8, 0xA82A86, 0xB81A1A]), bubble: ThinkingRamp(stops, [0xC9B6FF, 0xFF9AD8, 0xFF8A6A]),
        background: ThinkingRamp(stops, [0x0F0E15, 0x150C14, 0x1D0B0B]),
        eye: ThinkingRGB(0x17122E).color(), sleep: ThinkingRGB(0xEEE8FF).color(0.65), vein: ThinkingRGB(0xFF5A4A).color(),
        shadow: ThinkingRGB(0x000000).color(0.6), bubbleOpacity: 0.55, fillOpacity: 0.1
    )
}

/// How open the eyes are along the ladder: asleep, waking, wide awake at Medium, then narrowing
/// into a glare. Eight stops, whatever levels the model offers.
private let awakeOpenness = [0, 0.38, 0.78, 0.92, 0.8, 0.66, 0.54, 0.46]

extension BighelpThinkingLook {
    private static func openness(at level: Double) -> Double {
        let place = thinkingClamp(level) * Double(awakeOpenness.count - 1)
        let index = min(Int(place), awakeOpenness.count - 2)
        return thinkingLerp(awakeOpenness[index], awakeOpenness[index + 1], place - Double(index))
    }

    private static func spawnBubble(_ bubble: inout ThinkingSliderStore.Bubble, _ frame: ThinkingSliderFrame, anywhere: Bool) {
        bubble.x = thinkingChance() * max(frame.thumbX - 24, 4)
        bubble.y = anywhere ? thinkingChance() * frame.height : frame.height + 4
        bubble.speed = 0.6 + thinkingChance() * 0.8
        bubble.radius = 1.6 + thinkingChance() * 2.6
        bubble.phase = thinkingChance() * thinkingTau
        bubble.age = 0
        bubble.popAt = thinkingChance() * frame.height * 0.55
        bubble.pop = -1
    }

    /// Bubbles rise behind the face, more and faster as it thinks harder; past the middle of the
    /// ladder they pop before they reach the top.
    static func drawAwake(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore, _ paint: ThinkingPaint) {
        let palette = paint.isDark ? AwakePalette.dark : AwakePalette.light
        let level = frame.active, live = frame.isLive
        if level > 0 { store.phase += frame.delta * (0.6 + 2.4 * level) }
        context.fillThinkingTrack(frame, palette.background.at(level).color())
        let wanted = level > 0 ? Int((4 + 90 * level * level).rounded()) : 0
        while store.bubbles.count < wanted {
            var bubble = ThinkingSliderStore.Bubble()
            spawnBubble(&bubble, frame, anywhere: true)
            store.bubbles.append(bubble)
        }
        if store.bubbles.count > wanted { store.bubbles.removeLast(store.bubbles.count - wanted) }

        var bubbles = Path(), rays = Path()
        for index in store.bubbles.indices {
            var bubble = store.bubbles[index]
            defer { store.bubbles[index] = bubble }
            if bubble.pop >= 0 {
                bubble.pop += frame.delta
                if bubble.pop <= 0.16 {
                    let burst = bubble.pop / 0.16, inner = bubble.popRadius * (1 + burst * 0.6), outer = inner + 2 + 3 * burst
                    for ray in 0..<6 {
                        let angle = Double(ray) * thinkingTau / 6 + bubble.phase
                        rays.move(to: CGPoint(x: bubble.popX + cos(angle) * inner, y: bubble.popY + sin(angle) * inner))
                        rays.addLine(to: CGPoint(x: bubble.popX + cos(angle) * outer, y: bubble.popY + sin(angle) * outer))
                    }
                    continue
                }
                spawnBubble(&bubble, frame, anywhere: false)
            }
            bubble.y -= frame.delta * bubble.speed * (8 + 80 * level * level)
            bubble.age += frame.delta
            if bubble.y < -6 || bubble.x > frame.thumbX - 18 { spawnBubble(&bubble, frame, anywhere: false) }
            let rise = thinkingClamp((frame.height - bubble.y) / frame.height)
            let radius = bubble.radius * (0.5 + 0.9 * rise) * (1 + 0.5 * level)
            let x = bubble.x + sin(bubble.age * (3 + 6 * level) + bubble.phase) * (1.5 + 4 * level * level)
            if live, level > 0.5, bubble.y < bubble.popAt {
                bubble.pop = 0
                bubble.popX = x
                bubble.popY = bubble.y
                bubble.popRadius = radius
                continue
            }
            bubbles.addThinkingDot(x, bubble.y, radius: radius)
        }
        let tone = palette.bubble.at(level)
        context.fill(bubbles, with: .color(tone.color(palette.fillOpacity)))
        context.stroke(bubbles, with: .color(tone.color(palette.bubbleOpacity + 0.25 * level)), lineWidth: 1.1 + 0.4 * level)
        context.stroke(rays, with: .color(tone.color(0.85)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
    }

    /// The thumb is the agent's face: asleep at the bottom, wide awake at Medium, then glaring,
    /// frowning, gritting its teeth and fuming toward the top. Its eyes follow the drag.
    static func drawAwakeThumb(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore, _ paint: ThinkingPaint) {
        let palette = paint.isDark ? AwakePalette.dark : AwakePalette.light
        let level = frame.active, live = frame.isLive
        // From Medium, rising all the way to the top.
        let grit = thinkingClamp((frame.level - 0.4) / 0.6)
        let rage = live && level > 0.85 ? (level - 0.85) / 0.15 : 0
        store.gaze = live ? store.gaze + (thinkingClamp(frame.velocity * 1.5, -1, 1) - store.gaze) * min(1, frame.delta * 10) : 0
        let bob = level > 0 ? sin(store.phase * 2.2) * (0.6 + 1.2 * level) * (1 - grit * 0.7) : 0
        let x = frame.thumbX + rage * 0.8 * sin(frame.time * 57)
        let y = frame.middle + bob + rage * 0.6 * sin(frame.time * 71)
        let radius = 20.0
        let middle = palette.middle.at(level), tone = palette.bubble.at(level)

        if level > 0 {
            var trail = Path()
            trail.addThinkingDot(x - 25, y + 12, radius: 2.3)
            trail.addThinkingDot(x - 31, y + 17, radius: 1.5)
            context.fill(trail, with: .color(tone.color(0.7 * min(1, level * 4))))
            let glow = radius + 6 + 10 * level
            var halo = Path()
            halo.addThinkingDot(x, y, radius: glow)
            context.fill(halo, with: .radialGradient(
                Gradient(colors: [middle.color(0.35 * level), middle.color(0)]),
                center: CGPoint(x: x, y: y), startRadius: radius - 4, endRadius: glow
            ))
        }
        // Steam off the top once it's fuming.
        if live, level > 0.75, store.puffs.count < 10, thinkingChance() < frame.delta * 14 * (level - 0.75) / 0.25 {
            let side: Double = thinkingChance() < 0.5 ? -1 : 1
            store.puffs.append(.init(
                x: x + side * (7 + thinkingChance() * 5), y: y - 15, vx: side * (6 + thinkingChance() * 8), vy: -16 - 20 * level, life: 0
            ))
        }
        if live, !store.puffs.isEmpty {
            for index in store.puffs.indices {
                store.puffs[index].life += frame.delta / 0.7
                store.puffs[index].x += store.puffs[index].vx * frame.delta
                store.puffs[index].y += store.puffs[index].vy * frame.delta
            }
            store.puffs.removeAll { $0.life >= 1 }
        }
        for puff in store.puffs {
            var cloud = Path()
            cloud.addThinkingDot(puff.x, puff.y, radius: 1.5 + 3 * puff.life)
            context.fill(cloud, with: .color(tone.color(0.4 * (1 - puff.life) * (level > 0.75 ? 1 : 0.5))))
        }

        var face = Path()
        face.addThinkingDot(x, y, radius: radius)
        context.drawThinkingKnob(x: x, y: y + 0.5, radius: radius, fill: .clear, shadow: palette.shadow)
        let skin = GraphicsContext.Shading.radialGradient(
            Gradient(stops: [
                .init(color: palette.highlight.at(level).color(), location: 0),
                .init(color: middle.color(), location: 0.5),
                .init(color: palette.lowlight.at(level).color(), location: 1)
            ]),
            center: CGPoint(x: x - 7, y: y - 9), startRadius: 1, endRadius: radius + 10
        )
        context.fill(face, with: skin)

        var open = openness(at: frame.level)
        if level > 0, frame.level < 0.5, frame.time > 0, frame.time.truncatingRemainder(dividingBy: 4.2) < 0.12 { open *= 0.1 }
        let eyeY = y - 1.5
        var eyes = Path(), shut = Path(), lids = Path(), brows = Path()
        for side in [-1.0, 1.0] {
            let eyeX = x + side * 6.8 + store.gaze * 2.2, inner = eyeX - side * 3.6, outer = eyeX + side * 3.6
            if open < 0.15 {
                let start = Double.pi * 0.15
                shut.move(to: CGPoint(x: eyeX + cos(start) * 3.2, y: eyeY - 1.5 + sin(start) * 3.2))
                shut.addArc(center: CGPoint(x: eyeX, y: eyeY - 1.5), radius: 3.2, startAngle: .radians(start), endAngle: .radians(.pi * 0.85), clockwise: false)
            } else {
                let height = 0.6 + 3.9 * open
                eyes.addEllipse(in: CGRect(x: eyeX - 2.6, y: eyeY - height, width: 5.2, height: height * 2))
                // A lid slanting down toward the nose, lower the harder it thinks.
                if grit > 0 {
                    lids.move(to: CGPoint(x: inner, y: eyeY - height + 2 * height * 0.55 * grit))
                    lids.addLine(to: CGPoint(x: outer, y: eyeY - height + 2 * height * 0.12 * grit))
                    lids.addLine(to: CGPoint(x: outer, y: eyeY - height - 3))
                    lids.addLine(to: CGPoint(x: inner, y: eyeY - height - 3))
                    lids.closeSubpath()
                }
            }
            if grit > 0 {
                brows.move(to: CGPoint(x: eyeX - side * 3.4, y: eyeY - 6.6 + 3.2 * grit))
                brows.addLine(to: CGPoint(x: eyeX + side * 3.4, y: eyeY - 7.4 - 0.5 * grit))
            }
        }
        context.stroke(shut, with: .color(palette.eye), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        context.fill(eyes, with: .color(palette.eye))
        context.fill(lids, with: skin)
        if grit > 0 {
            context.stroke(
                brows, with: .color(palette.eye.opacity(thinkingClamp(grit * 2.5))),
                style: StrokeStyle(lineWidth: 1.5 + 0.9 * grit, lineCap: .round)
            )
        }

        // A frown that sets harder, then gritted teeth from Max.
        if grit > 0.08 {
            let mouthY = y + 9
            if grit > 0.8 {
                let clench = (grit - 0.8) / 0.2, width = 6 + 3 * clench, height = 1.6 + 2.6 * clench
                let teeth = Path(roundedRect: CGRect(x: x - width / 2, y: mouthY - height / 2, width: width, height: height), cornerRadius: 1.2)
                context.fill(teeth, with: .color(.white))
                context.stroke(teeth, with: .color(palette.eye), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                var gaps = Path()
                gaps.move(to: CGPoint(x: x - width / 2, y: mouthY))
                gaps.addLine(to: CGPoint(x: x + width / 2, y: mouthY))
                for offset in [-width / 6, width / 6] {
                    gaps.move(to: CGPoint(x: x + offset, y: mouthY - height / 2))
                    gaps.addLine(to: CGPoint(x: x + offset, y: mouthY + height / 2))
                }
                context.stroke(gaps, with: .color(palette.eye), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            } else {
                let width = 4 + 3 * grit
                var frown = Path()
                frown.move(to: CGPoint(x: x - width / 2, y: mouthY + 1.2 * grit))
                frown.addQuadCurve(to: CGPoint(x: x + width / 2, y: mouthY + 1.2 * grit), control: CGPoint(x: x, y: mouthY - 1.4 * grit))
                context.stroke(frown, with: .color(palette.eye), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        // The cross-popping vein, from Max.
        if level > 0.82 {
            let size = thinkingClamp((level - 0.82) / 0.18) * (1 + (live ? 0.15 * sin(frame.time * 9) : 0))
            let centerX = x + 14, centerY = y - 13
            var vein = Path()
            for (across, down) in [(1.0, 1.0), (1, -1), (-1, 1), (-1, -1)] {
                let originX = centerX + across * 2.6 * size, originY = centerY + down * 2.6 * size
                let facing = atan2(-down, -across), reach = 2.2 * size
                vein.move(to: CGPoint(x: originX + cos(facing - 1) * reach, y: originY + sin(facing - 1) * reach))
                vein.addArc(
                    center: CGPoint(x: originX, y: originY), radius: reach,
                    startAngle: .radians(facing - 1), endAngle: .radians(facing + 1), clockwise: false
                )
            }
            context.stroke(vein, with: .color(palette.vein), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        if frame.level < 0.02 {
            if store.sleepMarks.isEmpty {
                store.sleepMarks = [10.0, 8.0].map { size in
                    context.resolve(Text(verbatim: "z").font(.system(size: size, weight: .heavy, design: .rounded)))
                }
            }
            // Placed by their baseline, as the design's canvas does: the bottom edge sits a little below it.
            for (mark, place) in zip(store.sleepMarks, [(17.0, -8.0, 10.0), (23, -15, 8)]) {
                var text = mark
                text.shading = .color(palette.sleep)
                context.draw(text, at: CGPoint(x: x + place.0, y: y + place.1 + place.2 * 0.24), anchor: .bottomLeading)
            }
        }
    }
}
