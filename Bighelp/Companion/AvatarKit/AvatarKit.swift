import SwiftUI

/// bighelp's avatar kit, exported from `Design/AvatarKit` by
/// `tools/export_native.py`. Art is in a 200×200 space; every element carries
/// its resolved style for each of the kit's states.
struct AvatarKit: Decodable, Sendable {
    let version: Int
    let states: [String]
    let themes: [Theme]
    let keyframes: [String: [Stop]]
    let characters: [Character]

    struct Theme: Decodable, Sendable, Identifiable {
        let id: String
        let name: String
        let colors: [String: String]
    }

    struct Character: Decodable, Sendable {
        let id: String
        let name: String
        let role: String
        /// "classic" characters, or "bits" with a swappable face.
        let family: String
        /// A Bit's own face parts.
        let face: Face?
        /// How far the pupils travel when looking around, in art units.
        let look: Double
        let colors: [String: String]
        let tree: Node
    }

    struct Face: Decodable, Sendable, Equatable {
        let eyes: String
        let mouth: String
        let accessory: String
    }

    struct Stop: Decodable, Sendable {
        let t: Double
        let tf: Transform?
        /// CSS `translate`, as in `Style.tl`.
        var tl: [Double]? = nil
        let o: Double?
    }

    struct Transform: Decodable, Sendable, Equatable {
        var tx: Double?
        var ty: Double?
        var r: Double?
        var sx: Double?
        var sy: Double?
    }

    struct Animation: Decodable, Sendable, Equatable {
        let name: String
        let dur: Double
        let delay: Double
        let ease: String
        let dir: String
        /// 0 means infinite.
        let iter: Double
    }

    struct Style: Decodable, Sendable, Equatable {
        var hide: Bool?
        var o: Double?
        var an: Animation?
        var tf: Transform?
        /// CSS `translate` in terms of the character's look distance and the gaze:
        /// [x, ×look, ×gaze, ×gaze×look, y, ×look, ×gaze, ×gaze×look].
        var tl: [Double]?
        var org: [Double]?
        var f: String?
        var fo: Double?
        var s: String?
        var sw: Double?
        var so: Double?
        var cap: String?
        var join: String?
        var fs: Double?
    }

    final class Node: Decodable, @unchecked Sendable {
        let kind: String
        let matrix: CGAffineTransform?
        let isBackground: Bool
        let isBody: Bool
        let isRig: Bool
        let text: String?
        let textOrigin: CGPoint?
        let styles: [String: Style]
        /// Face options that show this part (Bits), e.g. ["eyes": ["round"]].
        let when: [String: [String]]
        let children: [Node]
        /// Geometry in art units, built once.
        let path: Path?

        private enum CodingKeys: String, CodingKey {
            case t, d, cx, cy, rx, ry, x, y, w, h, text, m, bg, body, rig, st, when, k
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .t)
            if let m = try c.decodeIfPresent([Double].self, forKey: .m), m.count == 6 {
                matrix = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
            } else {
                matrix = nil
            }
            isBackground = try c.decodeIfPresent(Bool.self, forKey: .bg) ?? false
            isBody = try c.decodeIfPresent(Bool.self, forKey: .body) ?? false
            isRig = try c.decodeIfPresent(Bool.self, forKey: .rig) ?? false
            styles = try c.decode([String: Style].self, forKey: .st)
            when = try c.decodeIfPresent([String: [String]].self, forKey: .when) ?? [:]
            children = try c.decodeIfPresent([Node].self, forKey: .k) ?? []
            text = try c.decodeIfPresent(String.self, forKey: .text)
            switch kind {
            case "path":
                let data = try c.decode(String.self, forKey: .d)
                // Catalog packs come from the network; no outline needs more.
                guard data.utf8.count <= AvatarKitPackValidator.maximumPathLength else {
                    throw DecodingError.dataCorruptedError(forKey: .d, in: c, debugDescription: "Path too long.")
                }
                path = AvatarKitPath.parse(data)
                textOrigin = nil
            case "circle", "ellipse":
                let cx = try c.decode(Double.self, forKey: .cx), cy = try c.decode(Double.self, forKey: .cy)
                let rx = try c.decode(Double.self, forKey: .rx), ry = try c.decode(Double.self, forKey: .ry)
                path = Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
                textOrigin = nil
            case "rect":
                let rect = CGRect(x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y),
                                  width: try c.decode(Double.self, forKey: .w), height: try c.decode(Double.self, forKey: .h))
                let radius = try c.decodeIfPresent(Double.self, forKey: .rx) ?? 0
                path = Path(roundedRect: rect, cornerRadius: radius, style: .circular)
                textOrigin = nil
            case "text":
                path = nil
                textOrigin = CGPoint(x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y))
            default:
                path = nil
                textOrigin = nil
            }
        }

        func style(for state: String) -> Style {
            styles[state] ?? styles["idle"] ?? Style()
        }
    }

    // MARK: Library

    /// The bundled kit. Loaded once; nil only if the resource is missing or malformed.
    static let bundled: AvatarKit? = {
        guard let url = Bundle.main.url(forResource: "AvatarKit", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AvatarKit.self, from: data)
    }()

    func character(_ id: String) -> Character? {
        characters.first { $0.id == id }
    }

    func theme(_ id: String) -> Theme? {
        themes.first { $0.id == id }
    }
}

// MARK: - Paths

enum AvatarKitPath {
    /// SVG path data with M, L, H, V, C, Q, A and Z (absolute or relative).
    static func parse(_ data: String) -> Path {
        var path = Path()
        var tokens = tokenize(data)[...]
        var command: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero
        func number() -> Double? {
            guard case let .number(value)? = tokens.first else { return nil }
            tokens = tokens.dropFirst()
            return value
        }
        while let token = tokens.first {
            if case let .command(letter) = token {
                tokens = tokens.dropFirst()
                command = letter
                if letter == "Z" || letter == "z" {
                    path.closeSubpath()
                    current = start
                    continue
                }
            }
            let relative = command.isLowercase
            func point(_ x: Double, _ y: Double) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch command {
            case "M", "m":
                guard let x = number(), let y = number() else { return path }
                current = point(x, y)
                start = current
                path.move(to: current)
                command = relative ? "l" : "L"
            case "L", "l":
                guard let x = number(), let y = number() else { return path }
                current = point(x, y)
                path.addLine(to: current)
            case "H", "h":
                guard let x = number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case "V", "v":
                guard let y = number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
            case "C", "c":
                guard let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(),
                      let x = number(), let y = number() else { return path }
                let control1 = point(x1, y1), control2 = point(x2, y2), end = point(x, y)
                path.addCurve(to: end, control1: control1, control2: control2)
                current = end
            case "Q", "q":
                guard let x1 = number(), let y1 = number(), let x = number(), let y = number() else { return path }
                let control = point(x1, y1), end = point(x, y)
                path.addQuadCurve(to: end, control: control)
                current = end
            case "A", "a":
                guard let rx = number(), let ry = number(), let rotation = number(), let large = number(),
                      let sweep = number(), let x = number(), let y = number() else { return path }
                let end = point(x, y)
                addArc(to: &path, from: current, to: end, radii: CGSize(width: rx, height: ry),
                       rotation: rotation, large: large != 0, sweep: sweep != 0)
                current = end
            default:
                return path
            }
        }
        return path
    }

    /// An SVG elliptical arc as cubic curves (SVG 1.1, appendix F.6).
    private static func addArc(to path: inout Path, from start: CGPoint, to end: CGPoint, radii: CGSize,
                               rotation: Double, large: Bool, sweep: Bool) {
        var rx = abs(radii.width), ry = abs(radii.height)
        guard rx > 0, ry > 0, start != end else { path.addLine(to: end); return }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coefficient = (large == sweep ? -1.0 : 1.0) * sqrt(max(0, numerator / denominator))
        let cxPrime = coefficient * rx * y1 / ry, cyPrime = -coefficient * ry * x1 / rx
        let center = CGPoint(x: cosPhi * cxPrime - sinPhi * cyPrime + (start.x + end.x) / 2,
                             y: sinPhi * cxPrime + cosPhi * cyPrime + (start.y + end.y) / 2)
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let ux = (x1 - cxPrime) / rx, uy = (y1 - cyPrime) / ry
        let startAngle = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, (-x1 - cxPrime) / rx, (-y1 - cyPrime) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        func mapped(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: center.x + rx * cosPhi * x - ry * sinPhi * y, y: center.y + rx * sinPhi * x + ry * cosPhi * y)
        }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2) - 0.001)))
        let step = delta / Double(segments)
        let handle = 4 / 3 * tan(step / 4)
        for index in 0..<segments {
            let a = startAngle + step * Double(index), b = a + step
            let control1 = mapped(cos(a) - handle * sin(a), sin(a) + handle * cos(a))
            let control2 = mapped(cos(b) + handle * sin(b), sin(b) - handle * cos(b))
            path.addCurve(to: index == segments - 1 ? end : mapped(cos(b), sin(b)), control1: control1, control2: control2)
        }
    }

    private enum Token { case command(Character), number(Double) }

    private static func tokenize(_ data: String) -> [Token] {
        var tokens: [Token] = []
        var buffer = ""
        func flush() {
            if let value = Double(buffer) { tokens.append(.number(value)) }
            buffer = ""
        }
        for character in data {
            if "MmLlHhVvCcQqAaZz".contains(character) {
                flush()
                tokens.append(.command(character))
            } else if character == "-" {
                // A minus starts a new number unless it follows an exponent.
                if !(buffer.last == "e" || buffer.last == "E") { flush() }
                buffer.append(character)
            } else if character.isNumber || character == "." || character == "e" || character == "E" {
                if character == ".", buffer.contains("."), !buffer.contains("e") { flush() }
                buffer.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }
}

// MARK: - Timing

enum AvatarKitTiming {
    /// Progress 0…1 through one keyframe segment, eased as CSS would.
    static func ease(_ name: String, _ x: Double) -> Double {
        switch name {
        case "linear": return x
        case "ease": return bezier(0.25, 0.1, 0.25, 1, x)
        case "ease-in": return bezier(0.42, 0, 1, 1, x)
        case "ease-out": return bezier(0, 0, 0.58, 1, x)
        case "ease-in-out": return bezier(0.42, 0, 0.58, 1, x)
        default:
            if name.hasPrefix("steps(") { return x >= 1 ? 1 : 0 }
            if name.hasPrefix("cubic-bezier(") {
                let values = name.dropFirst("cubic-bezier(".count).dropLast()
                    .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if values.count == 4 { return bezier(values[0], values[1], values[2], values[3], x) }
            }
            return bezier(0.25, 0.1, 0.25, 1, x)
        }
    }

    static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        func coordinate(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
        }
        var low = 0.0, high = 1.0, t = x
        for _ in 0..<24 {
            let value = coordinate(t, x1, x2)
            if abs(value - x) < 0.0005 { break }
            if value < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return coordinate(t, y1, y2)
    }

    /// Where an animation is at `time` seconds: its transform, translate and opacity, if animated.
    static func sample(_ animation: AvatarKit.Animation, stops: [AvatarKit.Stop], time: Double, baseOpacity: Double)
        -> (transform: AvatarKit.Transform?, translate: [Double]?, opacity: Double?) {
        let duration = max(animation.dur, 0.001)
        let elapsed = time - animation.delay
        var cycle = floor(elapsed / duration)
        if animation.iter > 0, cycle >= animation.iter { cycle = animation.iter - 1 }
        var progress = min(max(elapsed / duration - cycle, 0), 1)
        let odd = Int(cycle).isMultiple(of: 2) == false
        switch animation.dir {
        case "reverse": progress = 1 - progress
        case "alternate": if odd { progress = 1 - progress }
        case "alternate-reverse": if !odd { progress = 1 - progress }
        default: break
        }

        let transformStops = stops.filter { $0.tf != nil }
        let opacityStops = stops.filter { $0.o != nil }
        var transform: AvatarKit.Transform?
        if !transformStops.isEmpty {
            let (a, b, local) = segment(transformStops, progress)
            let eased = ease(animation.ease, local)
            transform = interpolate(a.tf ?? .init(), b.tf ?? .init(), eased)
        }
        let translateStops = stops.filter { $0.tl != nil }
        var translate: [Double]?
        if !translateStops.isEmpty {
            let (a, b, local) = segment(translateStops, progress)
            let eased = ease(animation.ease, local)
            let from = a.tl ?? [], to = b.tl ?? []
            translate = (0..<8).map { index in
                let x = index < from.count ? from[index] : 0, y = index < to.count ? to[index] : 0
                return x + (y - x) * eased
            }
        }
        var opacity: Double?
        if !opacityStops.isEmpty {
            let (a, b, local) = segment(opacityStops, progress, fallbackOpacity: baseOpacity)
            opacity = (a.o ?? baseOpacity) + ((b.o ?? baseOpacity) - (a.o ?? baseOpacity)) * ease(animation.ease, local)
        }
        return (transform, translate, opacity)
    }

    private static func segment(_ stops: [AvatarKit.Stop], _ progress: Double,
                                fallbackOpacity: Double = 1) -> (AvatarKit.Stop, AvatarKit.Stop, Double) {
        var list = stops
        if let first = list.first, first.t > 0 {
            list.insert(.init(t: 0, tf: first.tf == nil ? nil : .init(), tl: first.tl == nil ? nil : [],
                              o: first.o == nil ? nil : fallbackOpacity), at: 0)
        }
        if let last = list.last, last.t < 1 {
            list.append(.init(t: 1, tf: last.tf == nil ? nil : .init(), tl: last.tl == nil ? nil : [],
                              o: last.o == nil ? nil : fallbackOpacity))
        }
        for index in 0..<(list.count - 1) where progress <= list[index + 1].t {
            let a = list[index], b = list[index + 1]
            let span = b.t - a.t
            return (a, b, span > 0 ? (progress - a.t) / span : 1)
        }
        let last = list[list.count - 1]
        return (last, last, 1)
    }

    private static func interpolate(_ a: AvatarKit.Transform, _ b: AvatarKit.Transform, _ k: Double) -> AvatarKit.Transform {
        func mix(_ x: Double?, _ y: Double?, _ identity: Double) -> Double {
            let from = x ?? identity, to = y ?? identity
            return from + (to - from) * k
        }
        return .init(tx: mix(a.tx, b.tx, 0), ty: mix(a.ty, b.ty, 0), r: mix(a.r, b.r, 0),
                     sx: mix(a.sx, b.sx, 1), sy: mix(a.sy, b.sy, 1))
    }
}
