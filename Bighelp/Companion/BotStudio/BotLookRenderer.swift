import SwiftUI

/// A Bot Studio avatar ready to draw: its outline parsed once and its colors resolved. `draw` lays
/// it out in a 100 × 100 box with the person's tilt, lean and stretch, then the eyes for the pose.
/// The same math as the catalog's preview (`services/avatars/scripts/bodies-preview.py`).
struct BotLookPaths {
    private struct Layer {
        let path: Path
        let color: Color
        let stroke: CGFloat?
        let round: CGFloat?
    }

    let look: BotLook
    private let layers: [Layer]
    private let eyeColor: Color
    private let accentColor: Color
    private let bodyHex: String
    private let eyeHex: String

    init(_ look: BotLook) {
        self.look = look
        let main = HermesFaceColor.color(look.main)
        let accent = HermesFaceColor.color(look.accentColor)
        let eyes = HermesFaceColor.color(look.resolvedEyeColor)
        layers = look.body.parts.map { part in
            let color: Color = switch part.tone {
            case .main: main
            case .accent: accent
            case .shade: .black.opacity(0.16)
            case .light: .white.opacity(0.6)
            case .ink: eyes
            }
            return Layer(path: AvatarKitPath.parse(part.d), color: color,
                         stroke: part.stroke.map { CGFloat($0) }, round: part.round.map { CGFloat($0) })
        }
        eyeColor = eyes
        accentColor = accent
        bodyHex = look.main
        eyeHex = look.resolvedEyeColor
    }

    /// Draws into `size`; `pose` moves it (nil holds it still, eyes open).
    func draw(in context: GraphicsContext, size: CGSize, pose: BuddyPose?) {
        let side = min(size.width, size.height)
        let pose = pose ?? BuddyPose()
        var face = context
        face.translateBy(x: size.width / 2, y: size.height / 2)
        face.scaleBy(x: side / 100 * 0.94, y: side / 100 * 0.94)
        face.translateBy(x: pose.offset.width, y: pose.offset.height)
        face.rotate(by: .degrees(pose.rotation))
        // Squash and stretch around the feet, as the kit's characters do.
        face.translateBy(x: 0, y: 34)
        face.scaleBy(x: pose.squash, y: 1 / pose.squash)
        face.translateBy(x: 0, y: -34)
        face.rotate(by: .degrees((look.body.rotation ?? 0) + look.tilt))
        face.concatenate(CGAffineTransform(a: 1, b: 0, c: CGFloat(tan(-look.lean * .pi / 180)), d: 1, tx: 0, ty: 0))
        face.scaleBy(x: (1 - look.stretch * 0.14) * look.scale * (look.mirror ? -1 : 1),
                     y: (1 + look.stretch * 0.16) * look.scale)
        face.translateBy(x: -50, y: -50)

        for layer in layers {
            if let width = layer.stroke {
                face.stroke(layer.path, with: .color(layer.color),
                            style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            } else {
                face.fill(layer.path, with: .color(layer.color))
                if let round = layer.round, round > 0 {
                    face.stroke(layer.path, with: .color(layer.color), style: StrokeStyle(lineWidth: round, lineJoin: .round))
                }
            }
        }
        drawEyes(in: face, pose: pose)
        drawCheeksAndMouth(in: face, pose: pose)

        guard pose.effect != nil else { return }
        var overlay = context
        overlay.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
        overlay.scaleBy(x: side / 200, y: side / 200)
        BuddyPainter(ctx: overlay, u: 2, palette: BuddyPalette(bodyHex: bodyHex, eyeHex: eyeHex), look: BuddyLook(),
                     pose: pose)
            .effect(72, 24)
    }

    // MARK: Eyes

    /// The eyes' places with the person's spacing and size.
    private var anchors: [BotBody.Eye] {
        look.body.eyeAnchors.enumerated().map { index, eye in
            BotBody.Eye(x: eye.x + (index == 0 ? -look.eyeGap : look.eyeGap), y: eye.y, height: eye.height * look.eyeSize)
        }
    }

    private func drawEyes(in context: GraphicsContext, pose: BuddyPose) {
        let eyes = anchors
        guard eyes.count == 2 else { return }
        switch pose.eyes {
        case .happy:
            eyes.forEach { arc($0, up: true, in: context) }
        case .closed, .sad:
            eyes.forEach { arc($0, up: false, in: context) }
        case .squint(let gaze):
            drawStyle(look.eyes, eyes, openness: 0.45, gaze: gaze, in: context)
        case .wide(let gaze):
            drawStyle(look.eyes == .classic || look.eyes == .capsule ? .wide : look.eyes, eyes, openness: 1,
                      gaze: gaze, in: context)
        case .open(let openness, let gaze):
            drawStyle(look.eyes, eyes, openness: openness, gaze: gaze, in: context)
        }
    }

    private func drawStyle(_ style: BotLook.Eyes, _ eyes: [BotBody.Eye], openness: CGFloat, gaze: CGPoint,
                           in context: GraphicsContext) {
        let shifted = eyes.map { BotBody.Eye(x: $0.x + gaze.x * 2.2, y: $0.y + gaze.y * 2.2, height: $0.height) }
        let tilt = look.body.eyeTilt ?? -24
        switch style {
        case .classic:
            shifted.forEach { capsule($0, tilt: tilt, openness: openness, in: context) }
        case .capsule:
            capsule(shifted[0], tilt: 10, openness: openness, in: context)
            capsule(shifted[1], tilt: 12, openness: openness, in: context)
        case .dot:
            shifted.forEach { oval($0.x, $0.y, $0.height * 0.22, $0.height * 0.22 * max(openness, 0.2), in: context) }
        case .wide:
            shifted.forEach { wide($0, openness: openness, in: context) }
        case .sleepy:
            shifted.forEach { arc($0, up: false, in: context) }
        case .happy:
            shifted.forEach { arc($0, up: true, in: context) }
        case .wink:
            capsule(shifted[0], tilt: tilt, openness: openness, in: context)
            arc(shifted[1], up: true, in: context)
        case .visor:
            visor(shifted, openness: openness, in: context)
        case .odd:
            wide(BotBody.Eye(x: shifted[0].x, y: shifted[0].y, height: shifted[0].height * 1.12), openness: openness,
                 in: context)
            let small = shifted[1]
            oval(small.x, small.y + 1, small.height * 0.16, small.height * 0.16 * max(openness, 0.2), in: context)
        }
    }

    private func capsule(_ eye: BotBody.Eye, tilt: Double, openness: CGFloat, in context: GraphicsContext) {
        let height = eye.height * max(openness, 0.14)
        let width = eye.height * 0.42
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        let shape = Path(roundedRect: rect, cornerRadius: min(width, height) / 2)
            .applying(CGAffineTransform(rotationAngle: tilt * .pi / 180).concatenating(
                CGAffineTransform(translationX: eye.x, y: eye.y)))
        context.fill(shape, with: .color(eyeColor))
    }

    private func wide(_ eye: BotBody.Eye, openness: CGFloat, in context: GraphicsContext) {
        oval(eye.x, eye.y, eye.height * 0.3, eye.height * 0.4 * max(openness, 0.14), in: context)
        guard openness > 0.6 else { return }
        context.fill(Path(ellipseIn: CGRect(x: eye.x + eye.height * 0.1 - eye.height * 0.1,
                                            y: eye.y - eye.height * 0.15 - eye.height * 0.1,
                                            width: eye.height * 0.2, height: eye.height * 0.2)),
                     with: .color(.white))
    }

    private func visor(_ eyes: [BotBody.Eye], openness: CGFloat, in context: GraphicsContext) {
        let height = (eyes[0].height + eyes[1].height) / 2
        let bar = height * 0.55 * max(openness, 0.2)
        let left = eyes[0].x - height * 0.4, right = eyes[1].x + height * 0.4
        let middle = (eyes[0].y + eyes[1].y) / 2
        let rect = CGRect(x: left, y: middle - bar / 2, width: right - left, height: bar)
        context.fill(Path(roundedRect: rect, cornerRadius: bar / 2), with: .color(eyeColor))
        guard openness > 0.6 else { return }
        context.fill(Path(ellipseIn: CGRect(x: left + bar / 2 + 1.5, y: middle - bar * 0.35, width: 7, height: 2.6)),
                     with: .color(.white.opacity(0.85)))
    }

    private func arc(_ eye: BotBody.Eye, up: Bool, in context: GraphicsContext) {
        let half = eye.height * 0.32
        let y = eye.y + (up ? eye.height * 0.12 : -eye.height * 0.04)
        var path = Path()
        path.move(to: CGPoint(x: eye.x - half, y: y))
        path.addQuadCurve(to: CGPoint(x: eye.x + half, y: y),
                          control: CGPoint(x: eye.x, y: up ? eye.y - eye.height * 0.4 : eye.y + eye.height * 0.32))
        context.stroke(path, with: .color(eyeColor),
                       style: StrokeStyle(lineWidth: max(2.2, eye.height * 0.17), lineCap: .round))
    }

    private func oval(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double, in context: GraphicsContext) {
        context.fill(Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2)), with: .color(eyeColor))
    }

    // MARK: Cheeks and mouth

    private func drawCheeksAndMouth(in context: GraphicsContext, pose: BuddyPose) {
        let eyes = anchors
        guard eyes.count == 2 else { return }
        let left = eyes[0], right = eyes[1]
        if look.cheeks {
            let blush = Color(red: 1, green: 0.56, blue: 0.64).opacity(0.8)
            for (eye, side) in [(left, -4.0), (right, 4.0)] {
                context.fill(Path(ellipseIn: CGRect(x: eye.x + side - 4.4, y: eye.y + eye.height * 0.62 - 2.6,
                                                    width: 8.8, height: 5.2)), with: .color(blush))
            }
        }
        let x = (left.x + right.x) / 2
        let y = (left.y + right.y) / 2 + max(left.height, right.height) * 0.62
        let line = StrokeStyle(lineWidth: 2.4, lineCap: .round)
        // Talking opens a mouth on any face; otherwise the one the person picked.
        if case .open(let amount) = pose.mouth, amount > 0.15 {
            oval(x, y + 1.5, 3.2, 1 + 2.6 * amount, in: context)
            return
        }
        switch look.mouth {
        case .none:
            break
        case .smile:
            var path = Path()
            path.move(to: CGPoint(x: x - 5, y: y))
            path.addQuadCurve(to: CGPoint(x: x + 5, y: y), control: CGPoint(x: x, y: y + 5))
            context.stroke(path, with: .color(eyeColor), style: line)
        case .open:
            oval(x, y + 1.5, 3.2, 2.8, in: context)
        case .flat:
            var path = Path()
            path.move(to: CGPoint(x: x - 4, y: y + 1))
            path.addLine(to: CGPoint(x: x + 4, y: y + 1))
            context.stroke(path, with: .color(eyeColor), style: line)
        }
    }
}

/// A Bot Studio avatar at rest, for pickers and the saved picture.
struct BotLookView: View {
    let look: BotLook

    var body: some View {
        let paths = BotLookPaths(look)
        Canvas { context, size in paths.draw(in: context, size: size, pose: nil) }
            .accessibilityHidden(true)
    }
}

/// A Bot Studio avatar acting out a state, like the Hermes faces (`HermesShapeFacePlayer`): idle
/// plays the move the person picked. Reduce Motion, Low Power Mode, the background and rows off
/// screen hold the state's key pose (`BighelpLoaderMotionReader`).
struct BotLookPlayer: View {
    let look: BotLook
    let state: AvatarPlayState
    @BighelpLoaderMotionReader private var motion

    var body: some View {
        let paths = BotLookPaths(look)
        Group {
            if state.animates, motion.animates {
                TimelineView(.animation) { timeline in
                    canvas(paths, time: timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))
                }
            } else {
                canvas(paths, time: state.keyTime)
            }
        }
        .accessibilityHidden(true)
    }

    private var mood: String? {
        state == .idle ? look.move.mood : state.mood
    }

    private func canvas(_ paths: BotLookPaths, time: Double) -> some View {
        let pose = mood.map { BuddyPose.make(mood: $0, time: time) }
        return Canvas { context, size in paths.draw(in: context, size: size, pose: pose) }
    }
}

@MainActor
enum BotLookRenderer {
    /// The picture saved with the look: what Hermes Desktop, other devices, widgets and the Watch show.
    static let pixelDimension = 512

    static func png(_ look: BotLook) -> Data? {
        let side = CGFloat(pixelDimension)
        let renderer = ImageRenderer(content: BotLookView(look: look).frame(width: side, height: side))
        renderer.scale = 1
        renderer.isOpaque = false
        return renderer.uiImage?.pngData()
    }
}
