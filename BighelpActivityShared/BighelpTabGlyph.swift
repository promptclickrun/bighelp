import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The bottom bar's own icons for Chat, Feed, Ideas and Goals: a 24-pt grid,
/// round 1.7-pt strokes and the brand's dot, outlined when idle and filled when
/// selected. Each state is one filled path (strokes, fills and the cut-out dots
/// already merged), so it tints like text and stays sharp at any size. The
/// widgets share it, which is why it lives here rather than in an asset catalog.
enum BighelpTabGlyph: Sendable, CaseIterable {
    case chat, feed, ideas, goals

    /// The drawing on its 24 × 24 grid.
    func path(selected: Bool) -> Path {
        switch (self, selected) {
        case (.chat, false): Drawing.chat
        case (.chat, true): Drawing.chatSelected
        case (.feed, false): Drawing.feed
        case (.feed, true): Drawing.feedSelected
        case (.ideas, false): Drawing.ideas
        case (.ideas, true): Drawing.ideasSelected
        case (.goals, false): Drawing.goals
        case (.goals, true): Drawing.goalsSelected
        }
    }

    #if canImport(UIKit)
    /// A template image of the glyph, for places that only take images (the
    /// large content viewer).
    func image(selected: Bool) -> UIImage {
        Self.images[self]?[selected ? 1 : 0] ?? UIImage()
    }

    private static let images: [BighelpTabGlyph: [UIImage]] = Dictionary(uniqueKeysWithValues: allCases.map {
        ($0, [$0.render(selected: false), $0.render(selected: true)])
    })

    private func render(selected: Bool) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: 48, height: 48)
        let path = BighelpTabGlyphShape(glyph: self, selected: selected).path(in: rect).cgPath
        return UIGraphicsImageRenderer(size: rect.size).image { context in
            context.cgContext.addPath(path)
            context.cgContext.fillPath()
        }.withRenderingMode(.alwaysTemplate)
    }
    #endif
}

/// A tab glyph drawn to fit its frame, in the foreground style.
struct BighelpTabGlyphShape: Shape {
    let glyph: BighelpTabGlyph
    var selected = false

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let transform = CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2)
            .scaledBy(x: side / 24, y: side / 24)
        return glyph.path(selected: selected).applying(transform)
    }
}

/// The design's SVG paths, copied as drawn so they can be checked against it.
private enum Drawing {
    static let strokeWidth: CGFloat = 1.7

    // Chat: a speech bubble with two eyes. Selected, it's solid with the eyes cut out.
    static let bubble = svg("M12 4C17.2 4 20.5 6.9 20.5 11S17.2 18 12 18C10.9 18 9.9 17.9 9 17.6L5.2 19.9 6 16.1"
                            + "C4.4 14.9 3.5 13.1 3.5 11 3.5 6.9 6.8 4 12 4Z")
    static let chat = union(stroked(bubble), dot(9.2, 11, 1.25), dot(14.8, 11, 1.25))
    static let chatSelected = solid(bubble).subtracting(union(dot(9.2, 11, 1.35), dot(14.8, 11, 1.35)))

    // Feed: a card with a dot and two lines, and a signal in its corner.
    static let signal = svg("M16 5.2A2.8 2.8 0 0 1 18.8 8M16 2.4A5.6 5.6 0 0 1 21.6 8")
    static let cardLines = svg("M10.6 13H12.6M7 17H12.6")
    static let feed = union(
        stroked(svg("M12.5 8H6.5A3 3 0 0 0 3.5 11V17.5A3 3 0 0 0 6.5 20.5H13A3 3 0 0 0 16 17.5V11.5")),
        dot(7.6, 13, 1.4), stroked(cardLines), stroked(signal))
    static let feedSelected = solid(svg("M6.5 8H12.5A3.5 3.5 0 0 0 16 11.5V17.5A3 3 0 0 1 13 20.5H6.5"
                                        + "A3 3 0 0 1 3.5 17.5V11A3 3 0 0 1 6.5 8Z"))
        .subtracting(union(dot(7.6, 13, 1.5), stroked(cardLines)))
        .union(stroked(signal))

    // Ideas: a four-point sparkle and the brand's dot.
    static let sparkle = svg("M11 5C11.6 9.6 14.4 12.4 19 13 14.4 13.6 11.6 16.4 11 21 10.4 16.4 7.6 13.6 3 13"
                             + " 7.6 12.4 10.4 9.6 11 5Z")
    static let ideas = union(stroked(sparkle), dot(18.6, 5.4, 1.6))
    static let ideasSelected = union(solid(sparkle), dot(18.6, 5.4, 1.9))

    // Goals: a flag on a mountain.
    static let mountain = svg("M3 19.5L9.5 10 12.8 14.5 15 11.5 21 19.5Z")
    static let pole = svg("M9.5 10V3.5")
    static let goals = union(stroked(mountain), stroked(pole), stroked(svg("M9.5 3.8H14.5L13.2 5.6 14.5 7.4H9.5")))
    static let goalsSelected = union(solid(mountain), stroked(pole), solid(svg("M9.5 3.8H14.5L13.2 5.6 14.5 7.4H9.5Z")))

    static func stroked(_ path: Path) -> Path {
        path.strokedPath(StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
    }

    /// Filled and stroked, like SVG's fill plus stroke.
    static func solid(_ path: Path) -> Path { path.union(stroked(path)) }

    static func dot(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }

    static func union(_ first: Path, _ rest: Path...) -> Path {
        rest.reduce(first) { $0.union($1) }
    }

    /// Reads the absolute path commands the design uses: M, L, H, V, C, S, A
    /// (circular, unrotated) and Z, with repeated arguments.
    static func svg(_ data: String) -> Path {
        var path = Path()
        var tokens = SVGTokens(data)
        var command: Character = "M"
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?
        while true {
            if let next = tokens.peekCommand() {
                tokens.skipCommand()
                command = next
            } else if !tokens.hasNumber {
                break
            }
            var control: CGPoint?
            switch command {
            case "M":
                current = tokens.point(); start = current
                path.move(to: current)
                command = "L" // Further pairs are lines.
            case "L":
                current = tokens.point(); path.addLine(to: current)
            case "H":
                current.x = tokens.number(); path.addLine(to: current)
            case "V":
                current.y = tokens.number(); path.addLine(to: current)
            case "C", "S":
                // S mirrors the previous curve's last control point.
                let first = command == "C" ? tokens.point()
                    : lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let second = tokens.point()
                current = tokens.point()
                path.addCurve(to: current, control1: first, control2: second)
                control = second
            case "A":
                let radius = tokens.number()
                _ = tokens.number(); _ = tokens.number() // ry (equal) and rotation (none).
                let large = tokens.number() != 0, sweep = tokens.number() != 0
                let end = tokens.point()
                addArc(to: &path, from: current, to: end, radius: radius, large: large, sweep: sweep)
                current = end
            case "Z":
                path.closeSubpath(); current = start
                if tokens.hasNumber { assertionFailure("Numbers after Z"); return path }
            default:
                assertionFailure("Unsupported path command \(command)")
                return path
            }
            lastControl = control
        }
        return path
    }

    /// SVG's endpoint arc as a center arc (SVG 1.1, appendix F.6.5).
    private static func addArc(to path: inout Path, from p1: CGPoint, to p2: CGPoint, radius: CGFloat,
                               large: Bool, sweep: Bool) {
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        let distance = dx * dx + dy * dy
        guard distance > 0 else { return }
        let r = max(radius, distance.squareRoot())
        let scale = (large != sweep ? 1 : -1) * max(0, (r * r - distance) / distance).squareRoot()
        let center = CGPoint(x: scale * dy + (p1.x + p2.x) / 2, y: -scale * dx + (p1.y + p2.y) / 2)
        // Sweep 1 is toward increasing angles, which y-down Core Graphics calls counterclockwise.
        path.addArc(center: center, radius: r,
                    startAngle: .radians(atan2(p1.y - center.y, p1.x - center.x)),
                    endAngle: .radians(atan2(p2.y - center.y, p2.x - center.x)),
                    clockwise: !sweep)
    }
}

private struct SVGTokens {
    private let characters: [Character]
    private var index = 0

    init(_ text: String) { characters = Array(text) }

    private mutating func skipSeparators() {
        while index < characters.count, characters[index] == " " || characters[index] == "," { index += 1 }
    }

    mutating func peekCommand() -> Character? {
        skipSeparators()
        guard index < characters.count, characters[index].isLetter else { return nil }
        return characters[index]
    }

    mutating func skipCommand() { index += 1 }

    var hasNumber: Bool {
        mutating get {
            skipSeparators()
            guard index < characters.count else { return false }
            return characters[index].isNumber || "-.".contains(characters[index])
        }
    }

    mutating func number() -> CGFloat {
        skipSeparators()
        var text = ""
        if index < characters.count, characters[index] == "-" { text.append("-"); index += 1 }
        while index < characters.count, characters[index].isNumber
                || (characters[index] == "." && !text.contains(".")) {
            text.append(characters[index]); index += 1
        }
        return CGFloat(Double(text) ?? 0)
    }

    mutating func point() -> CGPoint {
        let x = number()
        return CGPoint(x: x, y: number())
    }
}
