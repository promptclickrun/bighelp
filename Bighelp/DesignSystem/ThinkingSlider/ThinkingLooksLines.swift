import SwiftUI

// The Thinking looks drawn as lines: Noodle, Train of Thought and Ink Bloom. Each has a day and a
// night palette; the numbers are the approved design's.

// MARK: - Noodle

private struct NoodlePalette: Sendable {
    let background: Color, tint: Double, guide: Color, knob: Color, shadow: Color

    static let light = NoodlePalette(
        background: ThinkingRGB(0xFFFFFF).color(), tint: 0.07, guide: ThinkingRGB(0x14141E).color(0.2),
        knob: ThinkingRGB(0xFFFFFF).color(), shadow: ThinkingRGB(0x14141E).color(0.26)
    )
    static let dark = NoodlePalette(
        background: ThinkingRGB(0x0B0B0D).color(), tint: 0.1, guide: ThinkingRGB(0xFFFFFF).color(0.16),
        knob: ThinkingRGB(0xFFF9F5).color(), shadow: ThinkingRGB(0x000000).color(0.6)
    )
}

extension BighelpThinkingLook {
    /// The brand's one stroke writing toward the thumb: a wave at the bottom of the ladder, tighter
    /// loops above it, turning from the person's color to its opposite.
    static func drawNoodle(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore, _ paint: ThinkingPaint) {
        let palette = paint.isDark ? NoodlePalette.dark : NoodlePalette.light
        let level = frame.active, middle = frame.middle
        if level > 0 { store.phase += frame.delta * (0.15 + 4 * level * level) }
        context.fillThinkingTrack(frame, palette.background)
        context.fillThinkingTrack(frame, paint.accent.color(level * 0.7, opacity: palette.tint))

        var guide = Path()
        guide.move(to: CGPoint(x: frame.thumbX, y: middle))
        guide.addLine(to: CGPoint(x: frame.width, y: middle))
        context.stroke(guide, with: .color(palette.guide), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1.5, 6]))

        // A prolate cycloid: a wave below one loop per pitch, loops above it.
        let pitch = 72 - 50 * level
        let depth = pitch / thinkingTau * (0.35 + 2.1 * level)
        let rise = min(depth * 1.25, middle - 7)
        let flow = store.phase * 0.3
        var written = context
        written.clip(to: Path(CGRect(x: 0, y: 0, width: frame.thumbX, height: frame.height)))
        func stroke(shift: Double, sway: Double, opacity: Double, width: Double) {
            var path = Path()
            let end = (frame.thumbX + depth + 6) / pitch
            var unit = -1.5, isFirst = true
            while unit <= end {
                let angle = thinkingTau * (unit - store.phase - shift)
                let point = CGPoint(x: pitch * unit - depth * sin(angle), y: middle + rise * sway * cos(angle))
                if isFirst { path.move(to: point); isFirst = false } else { path.addLine(to: point) }
                unit += 0.025
            }
            let stops = (0...8).map { step -> Gradient.Stop in
                let place = Double(step) / 8
                let fade = place < 0.3 ? place / 0.3 * 0.55 : thinkingLerp(0.55, 1, (place - 0.3) / 0.7)
                let shade = ThinkingAccent.shade(level, place * 1.2 + shift, flow: flow)
                return Gradient.Stop(color: paint.accent.color(shade, opacity: opacity * fade), location: place)
            }
            written.stroke(
                path,
                with: .linearGradient(Gradient(stops: stops), startPoint: .zero, endPoint: CGPoint(x: max(frame.thumbX, 1), y: 0)),
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            )
        }
        if level > 0.45 { stroke(shift: 0.37, sway: -0.7, opacity: (level - 0.45) / 0.55 * 0.45, width: 1.4) }
        stroke(shift: 0, sway: 1, opacity: 1, width: 2.4 + 1.2 * level)
    }

    /// A resting pen: a white knob with a dot in the stroke's color at the tip.
    static func drawNoodleThumb(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore, _ paint: ThinkingPaint) {
        let palette = paint.isDark ? NoodlePalette.dark : NoodlePalette.light
        context.drawThinkingKnob(x: frame.thumbX, y: frame.middle, radius: 20, fill: palette.knob, shadow: palette.shadow)
        let shade = ThinkingAccent.shade(frame.active, 1.2, flow: store.phase * 0.3)
        var dot = Path()
        dot.addThinkingDot(frame.thumbX, frame.middle, radius: 4.5)
        context.fill(dot, with: .color(paint.accent.thumbMark(shade)))
    }
}

// MARK: - Train of Thought

private struct TrainPalette: Sendable {
    let background: Color, word: Color, rule: Color, knob: Color, shadow: Color

    static let light = TrainPalette(
        background: ThinkingRGB(0xFAFAF8).color(), word: ThinkingRGB(0x1A1A20).color(),
        rule: ThinkingRGB(0x14141E).color(0.13), knob: ThinkingRGB(0xFFFFFF).color(), shadow: ThinkingRGB(0x14141E).color(0.24)
    )
    static let dark = TrainPalette(
        background: ThinkingRGB(0x0E0E11).color(), word: ThinkingRGB(0xEDEAE4).color(),
        rule: ThinkingRGB(0xFFFFFF).color(0.11), knob: ThinkingRGB(0xF4F1EC).color(), shadow: ThinkingRGB(0x000000).color(0.6)
    )
}

/// The little words a train of thought is made of. Shown as decoration, in every language.
private let trainWords = [
    "hmm", "what if", "maybe", "so", "because", "check", "compare", "wait", "try that", "then", "why", "plan",
    "edge case", "but", "ok", "verify", "idea", "next", "unless", "also", "recall", "test it", "sketch", "weigh", "rethink",
    "simplify", "and", "if", "sources", "options", "almost", "yes", "no", "careful", "step 2", "again", "closer", "got it"
]

/// Three rows of words: where each lane starts showing, how fast it runs and how far it sits from the middle.
private let trainLanes: [(rise: Double, start: Double, speed: Double)] = [(0, 0, 1), (-13, 0.3, 0.8), (13, 0.6, 1.18)]

extension BighelpThinkingLook {
    /// Builds the word rows once per track. The font is monospaced, so a word is as wide as its
    /// letters times one measured advance.
    private static func buildTrainRows(_ context: GraphicsContext, _ store: ThinkingSliderStore) {
        let plainFont = Font.system(size: 10.5, weight: .medium, design: .monospaced)
        let keyFont = Font.system(size: 10.5, weight: .semibold, design: .monospaced)
        store.plainWords = trainWords.map { context.resolve(Text(verbatim: $0).font(plainFont)) }
        store.keyWords = trainWords.map { context.resolve(Text(verbatim: $0).font(keyFont)) }
        let sample = context.resolve(Text(verbatim: String(repeating: "0", count: 10)).font(plainFont))
        let advance = Double(sample.measure(in: CGSize(width: 1000, height: 100)).width) / 10
        store.wordRows = (0..<trainLanes.count).map { row in
            let lane = Double(row)
            var x = 0.0
            var words: [ThinkingSliderStore.Word] = []
            words.reserveCapacity(40)
            for item in 0..<40 {
                let place = Double(item)
                let index = min(Int(thinkingRandom(lane * 97 + place * 13.7) * Double(trainWords.count)), trainWords.count - 1)
                let width = Double(trainWords[index].count) * advance
                words.append(.init(index: index, x: x, width: width, isKey: thinkingRandom(lane * 31 + place * 7.3) < 0.2))
                x += width + 16 + (thinkingRandom(place * 3.1 + lane) * 10).rounded()
            }
            return .init(words: words, length: x)
        }
    }

    /// Little words drift toward a text cursor, faster and in more rows as it thinks harder. Key
    /// words turn from the person's color to its opposite.
    static func drawTrain(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore, _ paint: ThinkingPaint) {
        let palette = paint.isDark ? TrainPalette.dark : TrainPalette.light
        let level = frame.active, middle = frame.middle
        if level > 0 {
            store.offset += frame.delta * (10 + 250 * level * level)
            store.flow += frame.delta * (0.15 + 1.1 * level)
        }
        context.fillThinkingTrack(frame, palette.background)
        context.fill(
            Path(CGRect(x: frame.thumbX, y: middle - 0.5, width: max(frame.width - frame.thumbX, 0), height: 1)),
            with: .color(palette.rule)
        )
        if store.wordRows.isEmpty { buildTrainRows(context, store) }

        let keyMix = thinkingClamp((level - 0.1) / 0.2)
        let smear = level > 0.75 ? 0.3 * (level - 0.75) / 0.25 : 0
        let reachWidth = max(frame.thumbX, 1)
        for (row, lane) in trainLanes.enumerated() {
            let show = thinkingClamp((level - lane.start) / 0.14)
            guard show > 0, row < store.wordRows.count else { continue }
            let words = store.wordRows[row]
            let shift = store.offset * lane.speed, y = middle + lane.rise
            for word in words.words {
                let x = (word.x + shift).truncatingRemainder(dividingBy: words.length) - 60
                if x > frame.thumbX || x + word.width < 0 { continue }
                let reach = thinkingClamp((frame.thumbX - 16 - (x + word.width)) / 28)
                let enter = thinkingClamp((x + word.width) / 40)
                let alpha = show * reach * enter * (0.25 + 0.6 * thinkingClamp(x / reachWidth))
                if alpha < 0.02 { continue }
                if !word.isKey || keyMix < 1 {
                    var text = store.plainWords[word.index]
                    text.shading = .color(palette.word)
                    let plain = word.isKey ? 1 - keyMix : 1
                    if smear > 0 {
                        context.opacity = alpha * plain * smear
                        context.draw(text, at: CGPoint(x: x - 5, y: y), anchor: .leading)
                    }
                    context.opacity = alpha * plain
                    context.draw(text, at: CGPoint(x: x, y: y), anchor: .leading)
                }
                if word.isKey, keyMix > 0 {
                    var text = store.keyWords[word.index]
                    let from = paint.accent.color(ThinkingAccent.shade(level, x / 110, flow: store.flow))
                    let to = paint.accent.color(ThinkingAccent.shade(level, (x + word.width) / 110, flow: store.flow))
                    text.shading = .linearGradient(
                        Gradient(colors: [from, to]), startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x + word.width, y: 0)
                    )
                    if smear > 0 {
                        context.opacity = alpha * keyMix * smear
                        context.draw(text, at: CGPoint(x: x - 5, y: y), anchor: .leading)
                    }
                    context.opacity = min(1, alpha * 1.25) * keyMix
                    context.draw(text, at: CGPoint(x: x, y: y), anchor: .leading)
                }
            }
        }
        context.opacity = 1
    }

    /// A tall knob holding a text cursor that glows in the key words' color.
    static func drawTrainThumb(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore, _ paint: ThinkingPaint) {
        let palette = paint.isDark ? TrainPalette.dark : TrainPalette.light
        let x = frame.thumbX, y = frame.middle, level = frame.active
        let knob = Path(roundedRect: CGRect(x: x - 14, y: y - 20, width: 28, height: 40), cornerRadius: 14)
        context.drawThinkingShadow(knob, palette.shadow)
        context.fill(knob, with: .color(palette.knob))

        let caret = ThinkingAccent.shade(level, x / 110, flow: store.flow)
        var cursor = Path()
        cursor.move(to: CGPoint(x: x, y: y - 10)); cursor.addLine(to: CGPoint(x: x, y: y + 10))
        cursor.move(to: CGPoint(x: x - 4, y: y - 11)); cursor.addLine(to: CGPoint(x: x + 4, y: y - 11))
        cursor.move(to: CGPoint(x: x - 4, y: y + 11)); cursor.addLine(to: CGPoint(x: x + 4, y: y + 11))
        if level > 0 {
            context.strokeThinkingGlow(cursor, paint.accent.thumbMark(caret, opacity: 0.9), spread: 3 + 9 * level, lineWidth: 2.4)
        }
        context.stroke(cursor, with: .color(paint.accent.thumbMark(caret)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
    }
}

// MARK: - Ink Bloom

private struct InkPalette: Sendable {
    let background: Color, ink: ThinkingRGB, ember: ThinkingRGB, drop: Color, shine: Color, ring: ThinkingRGB, shadow: Color

    static let light = InkPalette(
        background: ThinkingRGB(0xFBFAF7).color(), ink: ThinkingRGB(0x15151B), ember: ThinkingRGB(0xE8563F),
        drop: ThinkingRGB(0x15151B).color(), shine: ThinkingRGB(0xFFFFFF).color(0.55), ring: ThinkingRGB(0x15151B),
        shadow: ThinkingRGB(0x14141E).color(0.24)
    )
    static let dark = InkPalette(
        background: ThinkingRGB(0x09090B).color(), ink: ThinkingRGB(0xF1ECE3), ember: ThinkingRGB(0xFF8A7A),
        drop: ThinkingRGB(0xF1ECE3).color(), shine: ThinkingRGB(0x000000).color(0.28), ring: ThinkingRGB(0xF1ECE3),
        shadow: ThinkingRGB(0x000000).color(0.6)
    )
}

extension BighelpThinkingLook {
    /// Starts a thread of ink, reusing its trail's storage. `anywhere` scatters the first ones along
    /// the track; later ones start near the left.
    private static func spawnInk(_ thread: inout ThinkingSliderStore.InkThread, _ frame: ThinkingSliderFrame, _ level: Double, anywhere: Bool) {
        thread.x = anywhere ? thinkingChance() * frame.thumbX * 0.9 : thinkingChance() * max(frame.thumbX * 0.35, 8)
        thread.y = frame.middle + (thinkingChance() - 0.5) * (10 + 18 * level)
        thread.life = anywhere ? thinkingChance() : 0
        thread.span = 1.2 + thinkingChance() * 1.8
        thread.trail.removeAll(keepingCapacity: true)
        thread.isThick = thinkingChance() < 0.3
        thread.isEmber = thinkingChance() < 0.14
    }

    /// Ink curls through water toward a drop: more of it, thicker and faster as it thinks harder,
    /// with threads of Ember near the top.
    static func drawInk(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore, _ paint: ThinkingPaint) {
        let palette = paint.isDark ? InkPalette.dark : InkPalette.light
        let level = frame.active, middle = frame.middle
        if level > 0 { store.phase += frame.delta * (0.35 + 1.6 * level) }
        context.fillThinkingTrack(frame, palette.background)
        if level > 0 {
            context.fill(
                Path(CGRect(x: 0, y: 0, width: frame.thumbX, height: frame.height)),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: palette.ink.color(0), location: 0),
                        .init(color: palette.ink.color(0.02 + 0.06 * level), location: 0.75),
                        .init(color: palette.ink.color(0), location: 1)
                    ]),
                    startPoint: .zero, endPoint: CGPoint(x: max(frame.thumbX, 1), y: 0)
                )
            )
        }

        let wanted = level > 0 ? Int((16 + 140 * level).rounded()) : 0
        while store.inkThreads.count < wanted {
            var thread = ThinkingSliderStore.InkThread()
            thread.trail.reserveCapacity(25)
            spawnInk(&thread, frame, level, anywhere: true)
            store.inkThreads.append(thread)
        }
        if store.inkThreads.count > wanted { store.inkThreads.removeLast(store.inkThreads.count - wanted) }

        let push = 8 + 55 * level * level, turbulence = 14 + 46 * level, time = store.phase
        var thin = ThinkingOpacityBuckets(count: 10), thick = ThinkingOpacityBuckets(count: 10), ember = Path()
        for index in store.inkThreads.indices {
            if frame.isLive {
                var thread = store.inkThreads[index]
                let angle = sin(thread.x * 0.019 + time * 0.9) * 1.3
                    + cos(thread.y * 0.12 - time * 1.1 + thread.x * 0.007) * 1.5
                    + sin((thread.x + thread.y) * 0.031 + time * 0.6) * 0.7
                thread.x += frame.delta * (push + turbulence * cos(angle))
                thread.y += frame.delta * (turbulence * sin(angle) * 0.8 + (middle - thread.y) * 0.6)
                thread.life += frame.delta / thread.span
                thread.trail.append(CGPoint(x: thread.x, y: thread.y))
                if thread.trail.count > 24 { thread.trail.removeFirst() }
                if thread.life >= 1 || thread.x > frame.thumbX - 6 || thread.y < -4 || thread.y > frame.height + 4 {
                    spawnInk(&thread, frame, level, anywhere: false)
                }
                store.inkThreads[index] = thread
            }
            let thread = store.inkThreads[index]
            guard thread.trail.count >= 2 else { continue }
            let opacity = sin(.pi * thinkingClamp(thread.life)) * (0.14 + 0.36 * level)
            if thread.isEmber, level > 0.7 {
                ember.addLines(thread.trail)
            } else if thread.isThick {
                thick.append(opacity: opacity) { $0.addLines(thread.trail) }
            } else {
                thin.append(opacity: opacity) { $0.addLines(thread.trail) }
            }
        }
        for (buckets, width) in [(thin, 1.0), (thick, 2.6)] {
            let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            for index in buckets.paths.indices where !buckets.paths[index].isEmpty {
                context.stroke(buckets.paths[index], with: .color(palette.ink.color(buckets.opacity(at: index))), style: style)
            }
        }
        if level > 0.7 {
            context.stroke(
                ember, with: .color(palette.ember.color((level - 0.7) / 0.3 * 0.6)),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// A drop of ink, with a ripple spreading under it while it thinks.
    static func drawInkThumb(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore, _ paint: ThinkingPaint) {
        let palette = paint.isDark ? InkPalette.dark : InkPalette.light
        let x = frame.thumbX, center = frame.middle + 4, level = frame.active
        if level > 0, frame.time > 0 {
            let period = 2.6 - 1.4 * level
            let ripple = frame.time.truncatingRemainder(dividingBy: period) / period
            let radiusX = 10 + 14 * ripple, radiusY = 2.5 + 3 * ripple
            context.stroke(
                Path(ellipseIn: CGRect(x: x - radiusX, y: center + 13 - radiusY, width: radiusX * 2, height: radiusY * 2)),
                with: .color(palette.ring.color((1 - ripple) * 0.4)), lineWidth: 1
            )
        }
        var drop = Path()
        drop.move(to: CGPoint(x: x, y: center - 21))
        drop.addCurve(to: CGPoint(x: x + 14, y: center + 2), control1: CGPoint(x: x + 4, y: center - 13), control2: CGPoint(x: x + 14, y: center - 6))
        // Rising angles run through the bottom of the drop, as on the design's canvas.
        drop.addArc(center: CGPoint(x: x, y: center + 2), radius: 14, startAngle: .zero, endAngle: .radians(.pi), clockwise: false)
        drop.addCurve(to: CGPoint(x: x, y: center - 21), control1: CGPoint(x: x - 14, y: center - 6), control2: CGPoint(x: x - 4, y: center - 13))
        drop.closeSubpath()
        context.drawThinkingShadow(drop, palette.shadow)
        context.fill(drop, with: .color(palette.drop))
        let shine = Path(ellipseIn: CGRect(x: -2.6, y: -5, width: 5.2, height: 10))
            .applying(CGAffineTransform(rotationAngle: 0.4).concatenating(CGAffineTransform(translationX: x - 5, y: center - 1)))
        context.fill(shine, with: .color(palette.shine))
    }
}
