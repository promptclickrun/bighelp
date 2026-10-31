import SwiftUI

/// The states the avatar designer can play on the face being edited, each
/// one of the moods the characters already act out (`BuddyPose.moods`). A
/// preview only: nothing here reaches the agent's live face.
enum AvatarPlayState: String, CaseIterable, Identifiable, Sendable {
    case idle, still, bounce, listen, think, speak, work, curious, love, celebrate, sleep, oops

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: "Idle"
        case .still: "Still"
        case .bounce: "Bounce"
        case .listen: "Listen"
        case .think: "Think"
        case .speak: "Speak"
        case .work: "Work"
        case .curious: "Curious"
        case .love: "Love"
        case .celebrate: "Celebrate"
        case .sleep: "Sleep"
        case .oops: "Oops"
        }
    }

    /// The mood it plays; nil for Still, which holds a still frame.
    var mood: String? {
        switch self {
        case .idle: "idle"
        case .still: nil
        case .bounce: "bounce"
        case .listen: "listening"
        case .think: "thinking"
        case .speak: "nod"
        case .work: "scan"
        case .curious: "curious"
        case .love: "happy"
        case .celebrate: "excited"
        case .sleep: "sleepy"
        case .oops: "sad"
        }
    }

    var animates: Bool { self != .still }
}

/// A blob face acting out a `BuddyPose`: the body hops, leans and squashes,
/// the eyes blink, close or smile, and the pose's effect (hearts, Zzz, a
/// thought) floats at the top right, drawn by `BuddyPainter` as on characters.
struct HermesBlobFacePlayer: View {
    let seed: String
    let kind: HermesBlobFace.Kind?
    var edits: HermesBlobEdits?
    var color: String?
    let state: AvatarPlayState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let face = HermesBlobFacePaths(seed: seed, kind: kind, edits: edits, color: color)
        Group {
            if state.animates, !reduceMotion {
                TimelineView(.animation) { timeline in
                    canvas(face, time: timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))
                }
            } else {
                canvas(face, time: AvatarKitScene.stillTime)
            }
        }
        .accessibilityHidden(true)
    }

    private func canvas(_ face: HermesBlobFacePaths, time: Double) -> some View {
        let pose = state.mood.map { BuddyPose.make(mood: $0, time: time) } ?? BuddyPose()
        return Canvas { context, size in
            face.draw(in: context, size: size, pose: pose)
        }
    }
}

/// One blob face as filled paths in its 100×100 box, ready to pose.
struct HermesBlobFacePaths {
    let head: Color
    let eye: Color
    let headHex: String
    let eyeHex: String
    let body: [Path]
    let eyes: [Path]

    init(seed: String, kind: HermesBlobFace.Kind?, edits: HermesBlobEdits?, color: String?) {
        let rendering = HermesBlobFace.render(seed: seed, kind: kind, edits: edits)
        headHex = color.flatMap { $0.isEmpty ? nil : $0 } ?? rendering.head
        eyeHex = HermesFaceColor.eye(rendering.eye, on: headHex)
        head = HermesFaceColor.color(headHex)
        eye = HermesFaceColor.color(eyeHex)
        body = rendering.body.map { part in
            switch part {
            case .circle(let cx, let cy, let r): Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            case .path(let d): SVGPathData.path(d)
            }
        }
        eyes = rendering.eyes.map(SVGPathData.path)
    }

    func draw(in context: GraphicsContext, size: CGSize, pose: BuddyPose) {
        let side = min(size.width, size.height)
        // Leave room around the face for hops and effects.
        let scale = side / 100 * 0.82
        var face = context
        face.translateBy(x: size.width / 2, y: size.height / 2)
        face.scaleBy(x: scale, y: scale)
        face.translateBy(x: pose.offset.width, y: pose.offset.height)
        face.rotate(by: .degrees(pose.rotation))
        // Squash and stretch around the feet, as the characters do.
        let feet = 32.0
        face.translateBy(x: 0, y: feet)
        face.scaleBy(x: pose.squash, y: 1 / pose.squash)
        face.translateBy(x: -50, y: -50 - feet)
        for part in body { face.fill(part, with: .color(head)) }
        for path in eyes { drawEye(path, pose: pose, in: face) }

        guard pose.effect != nil else { return }
        var overlay = context
        overlay.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
        overlay.scaleBy(x: side / 200, y: side / 200)
        BuddyPainter(ctx: overlay, u: 2, palette: BuddyPalette(bodyHex: Self.hex(headHex), eyeHex: Self.hex(eyeHex)), look: BuddyLook(), pose: pose)
            .effect(72, 24)
    }

    private func drawEye(_ path: Path, pose: BuddyPose, in context: GraphicsContext) {
        let box = path.boundingRect
        let center = CGPoint(x: box.midX, y: box.midY)
        func reshaped(scaleX: CGFloat = 1, scaleY: CGFloat, look: CGPoint = .zero) -> Path {
            path.applying(CGAffineTransform(translationX: -center.x, y: -center.y)
                .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
                .concatenating(CGAffineTransform(translationX: center.x + look.x * 3, y: center.y + look.y * 3)))
        }
        switch pose.eyes {
        case let .open(openness, look):
            context.fill(reshaped(scaleY: max(0.08, openness), look: look), with: .color(eye))
        case let .wide(look):
            context.fill(reshaped(scaleX: 1.12, scaleY: 1.12, look: look), with: .color(eye))
        case let .squint(look):
            context.fill(reshaped(scaleY: 0.4, look: look), with: .color(eye))
        case .sad:
            context.fill(reshaped(scaleY: 0.7, look: CGPoint(x: 0, y: 0.5)), with: .color(eye))
        case .closed:
            let line = Path(roundedRect: CGRect(x: box.minX - 0.4, y: center.y, width: box.width + 0.8, height: 2.4),
                            cornerRadius: 1.2)
            context.fill(line, with: .color(eye))
        case .happy:
            var arc = Path()
            arc.move(to: CGPoint(x: box.minX - 0.6, y: center.y + 1.5))
            arc.addQuadCurve(to: CGPoint(x: box.maxX + 0.6, y: center.y + 1.5),
                             control: CGPoint(x: center.x, y: center.y - box.height * 0.45))
            context.stroke(arc, with: .color(eye), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        }
    }

    /// `BuddyPalette` takes hex; a face color can be `hsl()`.
    private static func hex(_ css: String) -> String {
        guard let rgb = HermesCSSColor.rgb(css) else { return "#8B5CF6" }
        return CompanionColor.hex(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
