import SwiftUI
import UIKit

/// A blob face, drawn from the same path text blobatar would emit.
struct HermesBlobFaceView: View {
    private let head: Color
    private let eye: Color
    private let bodyParts: [Path]
    private let eyes: [Path]

    /// `color` (`hsl()` or hex) paints the face over the color its seed would give.
    init(seed: String, kind: HermesBlobFace.Kind?, color: String? = nil) {
        let rendering = HermesBlobFace.render(seed: seed, kind: kind)
        head = HermesFaceColor.color(color.flatMap { $0.isEmpty ? nil : $0 } ?? rendering.head)
        eye = HermesFaceColor.color(rendering.eye)
        bodyParts = rendering.body.map { part in
            switch part {
            case .circle(let cx, let cy, let r):
                Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            case .path(let d):
                SVGPathData.path(d)
            }
        }
        eyes = rendering.eyes.map(SVGPathData.path)
    }

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            context.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
            context.scaleBy(x: side / 100, y: side / 100)
            // Each element fills on its own, as SVG does; one combined path
            // would punch holes where the petals and body wind opposite ways.
            for part in bodyParts { context.fill(part, with: .color(head)) }
            for part in eyes { context.fill(part, with: .color(eye)) }
        }
        .accessibilityHidden(true)
    }
}

/// A geometric face at rest: body, eyes and catchlights in Hermes's 40×44 box.
struct HermesShapeFaceView: View {
    let shape: String
    let color: String

    var body: some View {
        let isDark = HermesShapeFace.isDark(color)
        let fill = HermesFaceColor.color(color)
        let eyeFill = isDark ? Color(red: 232 / 255, green: 220 / 255, blue: 195 / 255).opacity(0.95) : Color.black.opacity(0.85)
        let sparkle = isDark ? Color.black.opacity(0.6) : Color.white.opacity(0.85)
        let ring = HermesShapeFace.ring(shape)
        let eyeY = HermesShapeFace.eyeLine(shape)
        Canvas { context, size in
            let scale = min(size.width / 40, size.height / 44)
            context.translateBy(x: (size.width - 40 * scale) / 2, y: (size.height - 44 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            var outline = Path()
            if let first = ring.first {
                outline.move(to: CGPoint(x: first.0, y: first.1))
                for point in ring.dropFirst() { outline.addLine(to: CGPoint(x: point.0, y: point.1)) }
                outline.closeSubpath()
            }
            context.fill(outline, with: .color(fill))
            for x in [15.4, 24.6] {
                context.fill(Path(ellipseIn: CGRect(x: x - 2.2, y: eyeY - 2.3, width: 4.4, height: 4.6)), with: .color(eyeFill))
                context.fill(Path(ellipseIn: CGRect(x: x - 0.6 - 0.65, y: eyeY - 0.7 - 0.65, width: 1.3, height: 1.3)),
                             with: .color(sparkle))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A Hermes look drawn as a view: a blob face or a geometric face.
struct HermesLookView: View {
    let look: AgentAvatarLook
    /// The agent's profile name, which a face follows unless it's locked.
    let name: String

    var body: some View {
        switch look.style {
        case .face:
            let blob = HermesBlobShape(look.shape) ?? HermesBlobShape()
            HermesBlobFaceView(seed: look.faceSeed ?? blob.seed(name: name), kind: blob.kind, color: look.color)
        case .shape:
            HermesShapeFaceView(shape: look.shape ?? HermesShapeFace.defaultShape(for: name),
                                color: HermesShapeFace.color(look.color, name: name))
        case .photo:
            Color.clear
        }
    }
}

enum HermesFaceColor {
    static func color(_ css: String) -> Color {
        guard let rgb = HermesCSSColor.rgb(css) else { return Color(red: 139 / 255, green: 92 / 255, blue: 246 / 255) }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// Saves a Hermes look as the agent's picture.
@MainActor
enum HermesLookRenderer {
    /// Hermes Desktop pushes its live faces as 160×160 PNGs and, for a face
    /// look, draws the vector itself instead of a picture that size. Matching
    /// it keeps Desktop's face live while every other app gets the picture.
    static let pixelDimension = 160

    static func png(look: AgentAvatarLook, name: String) -> Data? {
        let side = CGFloat(pixelDimension)
        let renderer = ImageRenderer(content: HermesLookView(look: look, name: name).frame(width: side, height: side))
        renderer.scale = 1
        renderer.isOpaque = false
        return renderer.uiImage?.pngData()
    }
}

/// The small slice of SVG path syntax blobatar writes: absolute M, L, H, V, C, Q and Z.
enum SVGPathData {
    static func path(_ d: String) -> Path {
        var path = Path()
        var numbers: [Double] = []
        var command: Character?
        var current = CGPoint.zero
        var token = ""

        func flushToken() {
            if let value = Double(token) { numbers.append(value) }
            token = ""
        }
        func apply() {
            guard let command else { return }
            let p = numbers
            switch command {
            case "M" where p.count >= 2:
                current = CGPoint(x: p[0], y: p[1]); path.move(to: current)
            case "L" where p.count >= 2:
                current = CGPoint(x: p[0], y: p[1]); path.addLine(to: current)
            case "H" where p.count >= 1:
                current = CGPoint(x: p[0], y: current.y); path.addLine(to: current)
            case "V" where p.count >= 1:
                current = CGPoint(x: current.x, y: p[0]); path.addLine(to: current)
            case "C" where p.count >= 6:
                current = CGPoint(x: p[4], y: p[5])
                path.addCurve(to: current, control1: CGPoint(x: p[0], y: p[1]), control2: CGPoint(x: p[2], y: p[3]))
            case "Q" where p.count >= 4:
                current = CGPoint(x: p[2], y: p[3])
                path.addQuadCurve(to: current, control: CGPoint(x: p[0], y: p[1]))
            case "Z":
                path.closeSubpath()
            default:
                break
            }
            numbers.removeAll()
        }

        for character in d {
            if "MLHVCQZ".contains(character) {
                flushToken()
                apply()
                command = character
            } else if character == " " || character == "," {
                flushToken()
            } else if character == "-", !token.isEmpty {
                flushToken()
                token = "-"
            } else {
                token.append(character)
            }
        }
        flushToken()
        apply()
        return path
    }
}
