import SwiftUI

// Heavyweight: the lifter stands on a stage and holds a box that grows with the level, over a slim
// rail with a round knob. Unlike the other looks the scene stays in the middle, so it is taller
// than one track. The lifter is drawn here in the brand kit's shapes and colors (`BighelpLifterMark`),
// not played from the kit's motions: his pose follows the level, which no kit state does.

/// Where the lifter and his box are for one frame. Plain arithmetic, so a test can read a pose.
struct HeavyweightPose {
    /// The control's height: the stage, then the rail and its knob.
    static let height: CGFloat = 160
    static let stageHeight = 118.0
    static let railY = 142.0
    static let knobRadius = 13.0

    /// True in one track's height (New chat's sweep): the stage is the track, with no rail.
    let isCompact: Bool
    let stage: CGRect
    /// The floor he stands on.
    let ground: Double
    /// His height before the load squashes him.
    let tall: Double
    let body: CGRect
    /// The box before it tilts.
    let box: CGRect
    let tilt: Double
    /// 0 to 1: how hard he shakes.
    let shake: Double
    /// 0 to 1: the level, once the box is up.
    let strain: Double
    /// 0 with the box on the floor beside him, 1 with it overhead, eased.
    let rise: Double

    /// Nothing below about a third of the way up, then harder with every level. Never while still.
    static func shake(level: Double, isStill: Bool) -> Double {
        isStill ? 0 : pow(thinkingClamp((level - 0.32) / 0.68), 1.6)
    }

    static func boxSize(level: Double, width: Double, isCompact: Bool) -> CGSize {
        let level = thinkingClamp(level)
        return isCompact
            ? CGSize(width: thinkingLerp(22, max(22, min(72, width - 24)), level), height: thinkingLerp(13, 22, level))
            : CGSize(width: thinkingLerp(46, max(46, min(150, width - 40)), level), height: thinkingLerp(26, 60, level))
    }

    /// `lift` is 0 with the box down and 1 with it up; `isStill` holds the pose without a shake.
    init(size: CGSize, level: Double, lift: Double, time: Double, isStill: Bool) {
        let width = Double(size.width), height = Double(size.height)
        let level = thinkingClamp(level)
        isCompact = height < 100
        let stageHeight = isCompact ? height : Self.stageHeight
        stage = CGRect(x: 0, y: 0, width: width, height: stageHeight)
        ground = stageHeight - (isCompact ? 10 : 16)
        tall = isCompact ? 20 : 36
        shake = Self.shake(level: level, isStill: isStill)
        strain = level * thinkingClamp(lift)
        let eased = thinkingClamp(lift)
        rise = eased * eased * (3 - 2 * eased)

        let bodyWidth = tall * 0.92 * (1 + 0.1 * strain)
        let bodyHeight = tall * (1 - 0.14 * strain)
        let centerX = width / 2 + shake * Self.wobble(time, 47, 31, 0) * tall * 0.035
        let top = ground - bodyHeight + shake * abs(sin(time * 9)) * tall * 0.03
        body = CGRect(x: centerX - bodyWidth / 2, y: top, width: bodyWidth, height: ground - top)

        let boxSize = Self.boxSize(level: level, width: width, isCompact: isCompact)
        let boxWidth = Double(boxSize.width), boxHeight = Double(boxSize.height)
        let gap = tall * (0.26 - 0.12 * strain)
        let breath = isStill ? 0 : sin(time * 2.1) * 0.6 * rise
        // The box stays on the stage however far he sways.
        let nearest = (isCompact ? 12.0 : 8.0) + boxWidth / 2
        let swayed = centerX + shake * Self.wobble(time, 39, 23, 2) * tall * 0.07
        let carryX = min(max(swayed, nearest), max(width - nearest, nearest))
        let carryY = top - gap - boxHeight / 2 + breath
        let restX = width / 2 + bodyWidth / 2 + tall * 0.42 + boxWidth / 2
        let restY = ground - boxHeight / 2
        let x = thinkingLerp(restX, carryX, rise)
        let y = thinkingLerp(restY, carryY, rise) - sin(.pi * rise) * tall * 0.25
        box = CGRect(x: x - boxWidth / 2, y: y - boxHeight / 2, width: boxWidth, height: boxHeight)
        tilt = rise * shake * Self.wobble(time, 33, 19, 4) * 0.06
    }

    /// Two sines that never line up, for a tremble that doesn't read as a loop.
    static func wobble(_ time: Double, _ fast: Double, _ slow: Double, _ seed: Double) -> Double {
        sin(time * fast + seed) * 0.6 + sin(time * slow + seed * 1.7) * 0.4
    }
}

private struct HeavyweightPalette: Sendable {
    let box: Color, boxText: Color, stage: Color, rail: Color, tick: Color, knobRing: Color, shadow: Color, sweat: Color

    static let light = HeavyweightPalette(
        box: BighelpBrand.ink, boxText: BighelpBrand.cream, stage: BighelpBrand.cream,
        rail: BighelpBrand.ink.opacity(0.13), tick: BighelpBrand.ink.opacity(0.26), knobRing: .white,
        shadow: BighelpBrand.ink.opacity(0.28), sweat: BighelpBrand.ink
    )
    static let dark = HeavyweightPalette(
        box: BighelpBrand.cream, boxText: BighelpBrand.ink, stage: BighelpBrand.ink,
        rail: BighelpBrand.cream.opacity(0.2), tick: BighelpBrand.cream.opacity(0.34), knobRing: .black,
        shadow: Color.black.opacity(0.6), sweat: BighelpBrand.cream
    )
}

extension BighelpThinkingLook {
    /// The stage, the box and the lifter.
    static func drawHeavyweight(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore, _ paint: ThinkingPaint) {
        let palette = paint.isDark ? HeavyweightPalette.dark : HeavyweightPalette.light
        // The box goes up as soon as the level leaves the bottom, and down when it comes back.
        let wanted: Double = frame.level > 0.02 ? 1 : 0
        store.lift = frame.isLive ? store.lift + (wanted - store.lift) * (1 - exp(-frame.delta * 9)) : wanted
        if abs(wanted - store.lift) < 0.001 { store.lift = wanted }
        let pose = HeavyweightPose(
            size: CGSize(width: frame.width, height: frame.height), level: frame.active, lift: store.lift,
            time: frame.time, isStill: !frame.isLive
        )

        // In one track's height the track's own pill is the stage.
        let corner = pose.isCompact ? 0 : 22.0
        context.fill(Path(roundedRect: pose.stage, cornerRadius: corner, style: .continuous), with: .color(palette.stage))
        if !pose.isCompact {
            let half = min(96, frame.width / 2 - 22)
            var floor = Path()
            floor.move(to: CGPoint(x: frame.width / 2 - half, y: pose.ground + 1))
            floor.addLine(to: CGPoint(x: frame.width / 2 + half, y: pose.ground + 1))
            context.stroke(floor, with: .color(palette.tick), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        drawHeavyweightBox(context, pose, store, paint, palette)
        drawHeavyweightLifter(context, pose, frame, palette)
    }

    /// The rail, a dot per level and the knob. One track's height has none of them.
    static func drawHeavyweightThumb(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore, _ paint: ThinkingPaint) {
        guard frame.height >= 100 else { return }
        let palette = paint.isDark ? HeavyweightPalette.dark : HeavyweightPalette.light
        let y = HeavyweightPose.railY
        let rail = CGRect(x: 8, y: y - 3, width: max(frame.width - 16, 6), height: 6)
        context.fill(Path(roundedRect: rail, cornerRadius: 3), with: .color(palette.rail))
        let filled = CGRect(x: 8, y: y - 3, width: max(frame.thumbX - 8, 6), height: 6)
        context.fill(Path(roundedRect: filled, cornerRadius: 3), with: .color(BighelpBrand.coral))
        if paint.steps > 1 {
            var passed = Path(), ahead = Path()
            let span = max(frame.width - ThinkingSliderMetrics.inset * 2, 1)
            for step in 0..<paint.steps {
                let place = Double(step) / Double(paint.steps - 1)
                let x = ThinkingSliderMetrics.inset + place * span
                if place <= frame.level + 0.001 { passed.addThinkingDot(x, y, radius: 1.5) } else { ahead.addThinkingDot(x, y, radius: 1.5) }
            }
            context.fill(passed, with: .color(palette.knobRing))
            context.fill(ahead, with: .color(palette.tick))
        }
        let radius = HeavyweightPose.knobRadius
        context.drawThinkingKnob(x: frame.thumbX, y: y, radius: radius, fill: BighelpBrand.coral, shadow: palette.shadow)
        context.stroke(
            Path(ellipseIn: CGRect(x: frame.thumbX - radius, y: y - radius, width: radius * 2, height: radius * 2)),
            with: .color(palette.knobRing), lineWidth: 3
        )
    }

    private static func drawHeavyweightBox(
        _ context: GraphicsContext, _ pose: HeavyweightPose, _ store: ThinkingSliderStore, _ paint: ThinkingPaint,
        _ palette: HeavyweightPalette
    ) {
        let box = pose.box
        var local = context
        local.translateBy(x: box.midX, y: box.midY)
        local.rotate(by: .radians(pose.tilt))
        local.fill(
            Path(
                roundedRect: CGRect(x: -box.width / 2, y: -box.height / 2, width: box.width, height: box.height),
                cornerRadius: min(box.width, box.height) * 0.28, style: .continuous
            ),
            with: .color(palette.box)
        )
        // The level's name on the box, where the box is big enough to read it.
        guard let caption = paint.caption, !caption.isEmpty, box.height > 18 else { return }
        let key = "\(paint.isDark ? "night" : "day")|\(caption)"
        if store.captionKey != key {
            store.captionKey = key
            store.caption = context.resolve(
                Text(verbatim: caption.localizedUppercase)
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(palette.boxText)
            )
        }
        guard let text = store.caption else { return }
        // Resolved once at one size, then scaled to the box: resolving text every frame costs too much.
        let size = text.measure(in: CGSize(width: 2000, height: 200))
        guard size.width > 0 else { return }
        let scale = min(box.height * 0.46 / 28, box.width * 0.8 / size.width)
        local.scaleBy(x: scale, y: scale)
        local.draw(text, at: .zero, anchor: .center)
    }

    private static func drawHeavyweightLifter(
        _ context: GraphicsContext, _ pose: HeavyweightPose, _ frame: ThinkingSliderFrame, _ palette: HeavyweightPalette
    ) {
        let tall = pose.tall
        let bodyWidth = Double(pose.body.width), bodyHeight = Double(pose.body.height)
        let bodyTop = Double(pose.body.minY), centerX = Double(pose.body.midX)
        let shoulderY = bodyTop + bodyHeight * 0.42
        // His hands follow the bottom of the box, wherever it is on its way up.
        let holdX = Double(pose.box.midX), holdY = Double(pose.box.maxY) - 1
        let reach = min(Double(pose.box.width) * 0.36, bodyWidth * 0.95)
        var arms = Path()
        for side in [-1.0, 1.0] {
            let shoulderX = centerX + side * bodyWidth * 0.34
            let restX = centerX + side * bodyWidth * 0.8, restY = pose.ground - bodyHeight * 0.2
            let handX = thinkingLerp(restX, holdX + side * reach, pose.rise)
            let handY = thinkingLerp(restY, holdY, pose.rise)
            // Elbows push out under the load.
            let tremble = pose.shake * HeavyweightPose.wobble(frame.time, 41, 29, side) * tall * 0.04
            let bend = side * (pose.strain * tall * 0.22 + tremble)
            arms.move(to: CGPoint(x: shoulderX, y: shoulderY))
            arms.addQuadCurve(
                to: CGPoint(x: handX, y: handY),
                control: CGPoint(x: (shoulderX + handX) / 2 + bend, y: (shoulderY + handY) / 2)
            )
        }
        context.stroke(arms, with: .color(BighelpBrand.coral), style: StrokeStyle(lineWidth: tall * 0.2, lineCap: .round))
        context.fill(
            Path(roundedRect: pose.body, cornerRadius: min(bodyWidth, bodyHeight) * 0.46, style: .continuous),
            with: .color(BighelpBrand.coral)
        )

        // Eyes: tall and calm, then squeezed thin under the load. With the box down he looks at it.
        let squint = pose.strain * pose.strain
        let full = bodyHeight * 0.31
        let eyeHeight = max(thinkingLerp(full, bodyHeight * 0.15, squint), 1.6)
        let eyeWidth = bodyWidth * 0.146 * (1 + 0.35 * squint)
        let eyeY = bodyTop + bodyHeight * 0.27 + (full - eyeHeight) / 2
        let glance = bodyWidth * 0.07 * (1 - pose.rise)
        var eyes = Path()
        for side in [-1.0, 1.0] {
            let eyeX = centerX + side * bodyWidth * 0.135 - eyeWidth / 2 + glance
            eyes.addRoundedRect(
                in: CGRect(x: eyeX, y: eyeY, width: eyeWidth, height: eyeHeight),
                cornerSize: CGSize(width: eyeWidth / 2, height: eyeWidth / 2)
            )
        }
        context.fill(eyes, with: .color(BighelpBrand.ink))

        guard pose.shake > 0.5 else { return }
        let strength = (pose.shake - 0.5) / 0.5
        for drop in 0..<3 {
            let phase = (frame.time * 1.5 + Double(drop) / 3).truncatingRemainder(dividingBy: 1)
            let side: Double = drop % 2 == 0 ? -1 : 1
            let x = centerX + side * (bodyWidth * 0.62 + phase * tall * 0.5)
            let y = bodyTop + bodyHeight * 0.25 - sin(phase * .pi) * tall * 0.3 + phase * tall * 0.35
            var sweat = Path()
            sweat.addThinkingDot(x, y, radius: max(tall * 0.055, 1.2))
            context.fill(sweat, with: .color(palette.sweat.opacity((1 - phase) * strength * 0.6)))
        }
    }
}
