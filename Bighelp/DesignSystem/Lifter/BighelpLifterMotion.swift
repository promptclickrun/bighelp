import Foundation
import SwiftUI

/// The brand kit's lifter: eight states, each a Lottie file for light pages and one for dark
/// ones in `Resources/Lifter`, drawn natively by `BighelpLifterView`. DESIGN.md › Lifter says
/// where each one plays.
enum BighelpLifterMotion: String, CaseIterable, Sendable {
    /// He presses the box overhead. Waiting, loading, connecting, empty places.
    case idle
    /// The box becomes a brain and he juggles it. Reasoning.
    case thinking
    /// The box becomes a computer and he types. Helper agents and coding sessions at work.
    case coding
    /// He announces into a ring announcer's mic. Speaking, sending.
    case replying
    /// The box becomes a magnifying glass and he scans. Searching, reading, tool use.
    case searching
    /// The box becomes a check badge, he jumps, confetti. Finished work, the welcome.
    case success
    /// The box becomes a warning sign and he sweats. Something failed.
    case error
    /// The box becomes a moon balloon and he naps. Paused, muted, ended.
    case sleeping

    func resourceName(dark: Bool) -> String { "bighelp-lifter-\(rawValue)-\(dark ? "dark" : "light")" }
}

/// One kit animation, read once from its file. Only what the kit writes is understood:
/// shape layers of groups with paths (still or morphing), rectangles, ellipses, strokes,
/// fills and transforms, on eased or held keyframes, and the intro, loop and outro markers.
/// Anything else is skipped.
struct BighelpLifterAnimation: Sendable {
    let frameRate: Double
    let inPoint: Double
    let outPoint: Double
    /// Turns the box into this state's prop, once. Nil when the state is only a loop (idle).
    let intro: Range<Double>?
    /// Repeats for as long as the state lasts; starts and ends on the same pose.
    let loop: Range<Double>
    /// Bottom layer first.
    let layers: [Layer]

    var frameCount: Double { outPoint - inPoint }
    var duration: TimeInterval { frameCount / frameRate }

    /// The kit draws the lifter on a 400-point square at 1.5625 times the still mark's
    /// 200-unit artboard, the mark's center at (200, 197.5). `markBox` is the part of the
    /// square the mark fills, so a motion and the still mark line up at any size; props,
    /// jumps and confetti draw past it.
    static let compositionSide: CGFloat = 400
    static let markBox: CGFloat = 312.5
    static let markCenter = CGPoint(x: 200, y: 197.5)

    struct Layer: Sendable {
        let inPoint: Double
        let outPoint: Double
        let transform: Transform
        let groups: [Group]
    }

    struct Group: Sendable {
        let items: [Item]
        let transform: Transform
    }

    enum Item: Sendable {
        case path(Animated<Bezier>)
        case rectangle(center: Animated<[Double]>, size: Animated<[Double]>, radius: Animated<Double>)
        case ellipse(center: Animated<[Double]>, size: Animated<[Double]>)
        case stroke(color: Animated<[Double]>, opacity: Animated<Double>, width: Animated<Double>,
                    cap: CGLineCap, join: CGLineJoin)
        case fill(color: Animated<[Double]>, opacity: Animated<Double>)
        case group(Group)
    }

    struct Transform: Sendable {
        var anchor: Animated<[Double]> = .still([0, 0])
        var position: Animated<[Double]> = .still([0, 0])
        var scale: Animated<[Double]> = .still([100, 100])
        var rotation: Animated<Double> = .still(0)
        var opacity: Animated<Double> = .still(100)

        func matrix(at frame: Double) -> CGAffineTransform {
            let a = anchor.value(at: frame), p = position.value(at: frame), s = scale.value(at: frame)
            return CGAffineTransform(translationX: -a[safe: 0], y: -a[safe: 1])
                .concatenating(CGAffineTransform(scaleX: s[safe: 0, or: 100] / 100, y: s[safe: 1, or: 100] / 100))
                .concatenating(CGAffineTransform(rotationAngle: rotation.value(at: frame) * .pi / 180))
                .concatenating(CGAffineTransform(translationX: p[safe: 0], y: p[safe: 1]))
        }
    }

    /// A path as the kit writes it: vertices with in and out tangents relative to each.
    struct Bezier: Sendable {
        let closed: Bool
        let vertices: [CGPoint]
        let inTangents: [CGPoint]
        let outTangents: [CGPoint]

        var path: Path {
            var path = Path()
            guard let first = vertices.first else { return path }
            path.move(to: first)
            let count = vertices.count
            for index in 0..<(closed ? count : count - 1) {
                let from = vertices[index], next = (index + 1) % count, to = vertices[next]
                path.addCurve(to: to, control1: from + outTangents[safe: index],
                              control2: to + inTangents[safe: next])
            }
            if closed { path.closeSubpath() }
            return path
        }
    }

    /// A property's value: still, or keyframes eased between with the kit's cubic curves.
    enum Animated<Value: BighelpLifterInterpolating>: Sendable {
        case still(Value)
        case keyframes([Keyframe<Value>])

        func value(at frame: Double) -> Value {
            switch self {
            case .still(let value): return value
            case .keyframes(let keys):
                guard let first = keys.first else { preconditionFailure("Parsed keyframes are never empty.") }
                guard frame > first.time else { return first.value }
                for (index, key) in keys.enumerated() where index + 1 < keys.count {
                    let next = keys[index + 1]
                    guard frame < next.time else { continue }
                    if key.holds || next.time <= key.time { return key.value }
                    let linear = (frame - key.time) / (next.time - key.time)
                    let eased = key.curve.map { BighelpLifterCurve.solve($0, at: linear) } ?? linear
                    return Value.interpolate(key.value, next.value, eased)
                }
                return keys[keys.count - 1].value
            }
        }
    }

    struct Keyframe<Value: Sendable>: Sendable {
        let time: Double
        let value: Value
        /// This keyframe's out handle and the next one's in handle, as a CSS cubic-bezier.
        let curve: (Double, Double, Double, Double)?
        let holds: Bool
    }
}

/// Values the kit animates, blended between two keyframes.
protocol BighelpLifterInterpolating: Sendable {
    static func interpolate(_ a: Self, _ b: Self, _ t: Double) -> Self
}

extension Double: BighelpLifterInterpolating {
    static func interpolate(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

extension Array: BighelpLifterInterpolating where Element == Double {
    static func interpolate(_ a: [Double], _ b: [Double], _ t: Double) -> [Double] {
        zip(a, b).map { $0 + ($1 - $0) * t }
    }
}

extension BighelpLifterAnimation.Bezier: BighelpLifterInterpolating {
    /// The kit morphs between paths with the same number of points; any other pair holds.
    static func interpolate(_ a: Self, _ b: Self, _ t: Double) -> Self {
        guard a.vertices.count == b.vertices.count else { return t < 1 ? a : b }
        func blend(_ x: [CGPoint], _ y: [CGPoint]) -> [CGPoint] {
            zip(x, y).map { CGPoint(x: $0.x + ($1.x - $0.x) * t, y: $0.y + ($1.y - $0.y) * t) }
        }
        return Self(closed: a.closed, vertices: blend(a.vertices, b.vertices),
                    inTangents: blend(a.inTangents, b.inTangents), outTangents: blend(a.outTangents, b.outTangents))
    }
}

/// The kit's eases: CSS cubic-bezier curves solved for x.
enum BighelpLifterCurve {
    static func solve(_ curve: (Double, Double, Double, Double), at x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        let (x1, y1, x2, y2) = curve
        func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
        }
        var low = 0.0, high = 1.0, t = x
        for _ in 0..<20 {
            t = (low + high) / 2
            if bezier(t, x1, x2) < x { low = t } else { high = t }
        }
        return bezier(t, y1, y2)
    }
}

// MARK: Drawing

extension BighelpLifterAnimation {
    /// Draws one frame into `context`, scaled so the mark box fills `side` points around
    /// the context's center. A tint repaints every stroke and fill, keeping their own opacity.
    func draw(frame: Double, in context: GraphicsContext, center: CGPoint, side: CGFloat, tint: Color?) {
        let scale = side / Self.markBox
        let view = CGAffineTransform(translationX: -Self.markCenter.x, y: -Self.markCenter.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        for layer in layers where frame >= layer.inPoint && frame < layer.outPoint {
            let opacity = layer.transform.opacity.value(at: frame) / 100
            guard opacity > 0 else { continue }
            let matrix = layer.transform.matrix(at: frame).concatenating(view)
            for group in layer.groups.reversed() {
                draw(group, frame: frame, matrix: matrix, opacity: opacity, in: context, tint: tint)
            }
        }
    }

    private func draw(_ group: Group, frame: Double, matrix parent: CGAffineTransform, opacity parentOpacity: Double,
                      in context: GraphicsContext, tint: Color?) {
        let opacity = parentOpacity * group.transform.opacity.value(at: frame) / 100
        guard opacity > 0 else { return }
        let matrix = group.transform.matrix(at: frame).concatenating(parent)
        var shape = Path()
        for item in group.items {
            switch item {
            case .path(let bezier): shape.addPath(bezier.value(at: frame).path)
            case .rectangle(let center, let size, let radius):
                let c = center.value(at: frame), s = size.value(at: frame)
                let rect = CGRect(x: c[safe: 0] - s[safe: 0] / 2, y: c[safe: 1] - s[safe: 1] / 2,
                                  width: s[safe: 0], height: s[safe: 1])
                let corner = min(radius.value(at: frame), rect.width / 2, rect.height / 2)
                shape.addPath(Path(roundedRect: rect, cornerRadius: max(0, corner), style: .circular))
            case .ellipse(let center, let size):
                let c = center.value(at: frame), s = size.value(at: frame)
                shape.addPath(Path(ellipseIn: CGRect(x: c[safe: 0] - s[safe: 0] / 2, y: c[safe: 1] - s[safe: 1] / 2,
                                                     width: s[safe: 0], height: s[safe: 1])))
            case .group(let child):
                draw(child, frame: frame, matrix: matrix, opacity: opacity, in: context, tint: tint)
            case .stroke, .fill: break
            }
        }
        guard !shape.isEmpty else { return }
        // Line widths scale with the transform, so stroke in the group's own space.
        var local = context
        local.concatenate(matrix)
        for item in group.items {
            switch item {
            case .stroke(let color, let strokeOpacity, let width, let cap, let join):
                let alpha = opacity * strokeOpacity.value(at: frame) / 100
                local.stroke(shape, with: .color(Self.color(color.value(at: frame), alpha: alpha, tint: tint)),
                             style: StrokeStyle(lineWidth: width.value(at: frame), lineCap: cap, lineJoin: join))
            case .fill(let color, let fillOpacity):
                let alpha = opacity * fillOpacity.value(at: frame) / 100
                local.fill(shape, with: .color(Self.color(color.value(at: frame), alpha: alpha, tint: tint)))
            default: break
            }
        }
    }

    private static func color(_ rgba: [Double], alpha: Double, tint: Color?) -> Color {
        let own = rgba[safe: 3, or: 1]
        if let tint { return tint.opacity(alpha * own) }
        return Color(.sRGB, red: rgba[safe: 0], green: rgba[safe: 1], blue: rgba[safe: 2], opacity: alpha * own)
    }
}

// MARK: Reading the kit's files

extension BighelpLifterAnimation {
    /// Every motion, in each palette, read on first use and kept.
    @MainActor static func named(_ motion: BighelpLifterMotion, dark: Bool) -> BighelpLifterAnimation? {
        let key = motion.resourceName(dark: dark)
        if let cached = cache[key] { return cached }
        guard let url = Bundle.main.url(forResource: key, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let animation = BighelpLifterAnimation(data: data) else { return nil }
        cache[key] = animation
        return animation
    }

    @MainActor private static var cache: [String: BighelpLifterAnimation] = [:]

    init?(data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let frameRate = Self.number(root["fr"]), frameRate > 0,
              let outPoint = Self.number(root["op"]),
              let layerList = root["layers"] as? [[String: Any]] else { return nil }
        let inPoint = Self.number(root["ip"]) ?? 0
        guard outPoint > inPoint else { return nil }
        self.frameRate = frameRate
        self.inPoint = inPoint
        self.outPoint = outPoint
        let markers = Self.markers(root["markers"], within: inPoint..<outPoint)
        intro = markers["intro"]
        loop = markers["loop"] ?? inPoint..<outPoint
        layers = layerList.reversed().compactMap { layer in
            guard Self.number(layer["ty"]) == 4, let shapes = layer["shapes"] as? [[String: Any]] else { return nil }
            return Layer(inPoint: Self.number(layer["ip"]) ?? inPoint, outPoint: Self.number(layer["op"]) ?? outPoint,
                         transform: Self.transform(layer["ks"] as? [String: Any]),
                         groups: shapes.compactMap(Self.group))
        }
    }

    /// `[{"cm": "loop", "tm": 30, "dr": 60}]`, kept only when it lies inside the file.
    private static func markers(_ json: Any?, within file: Range<Double>) -> [String: Range<Double>] {
        var ranges: [String: Range<Double>] = [:]
        for marker in json as? [[String: Any]] ?? [] {
            guard let name = marker["cm"] as? String, let start = number(marker["tm"]),
                  let length = number(marker["dr"]), length > 0,
                  start >= file.lowerBound, start + length <= file.upperBound else { continue }
            ranges[name] = start..<(start + length)
        }
        return ranges
    }

    private static func group(_ json: [String: Any]) -> Group? {
        guard json["ty"] as? String == "gr", let items = json["it"] as? [[String: Any]] else { return nil }
        let transform = items.first { $0["ty"] as? String == "tr" }.map(Self.transform) ?? Transform()
        return Group(items: items.compactMap(Self.item), transform: transform)
    }

    private static func item(_ json: [String: Any]) -> Item? {
        switch json["ty"] as? String {
        case "gr": return group(json).map(Item.group)
        case "sh": return animated(json["ks"], bezier).map(Item.path)
        case "rc":
            guard let center = animated(json["p"], vector), let size = animated(json["s"], vector) else { return nil }
            return .rectangle(center: center, size: size, radius: animated(json["r"], scalar) ?? .still(0))
        case "el":
            guard let center = animated(json["p"], vector), let size = animated(json["s"], vector) else { return nil }
            return .ellipse(center: center, size: size)
        case "st":
            guard let color = animated(json["c"], vector) else { return nil }
            return .stroke(color: color, opacity: animated(json["o"], scalar) ?? .still(100),
                           width: animated(json["w"], scalar) ?? .still(1),
                           cap: [1: .butt, 3: .square][Self.number(json["lc"]) ?? 2] ?? .round,
                           join: [1: .miter, 3: .bevel][Self.number(json["lj"]) ?? 2] ?? .round)
        case "fl":
            guard let color = animated(json["c"], vector) else { return nil }
            return .fill(color: color, opacity: animated(json["o"], scalar) ?? .still(100))
        default: return nil
        }
    }

    private static func transform(_ json: [String: Any]?) -> Transform {
        guard let json else { return Transform() }
        var transform = Transform()
        if let anchor = animated(json["a"], vector) { transform.anchor = anchor }
        if let position = animated(json["p"], vector) { transform.position = position }
        if let scale = animated(json["s"], vector) { transform.scale = scale }
        if let rotation = animated(json["r"], scalar) { transform.rotation = rotation }
        if let opacity = animated(json["o"], scalar) { transform.opacity = opacity }
        return transform
    }

    /// `{"a": 0, "k": value}` or `{"a": 1, "k": [keyframes]}`.
    private static func animated<Value>(_ json: Any?, _ read: (Any?) -> Value?) -> Animated<Value>? {
        guard let property = json as? [String: Any] else { return nil }
        guard Self.number(property["a"]) == 1 else { return read(property["k"]).map(Animated.still) }
        let keys: [Keyframe<Value>] = (property["k"] as? [[String: Any]] ?? []).compactMap { key in
            guard let time = Self.number(key["t"]), let value = read(key["s"]) else { return nil }
            let out = key["o"] as? [String: Any], into = key["i"] as? [String: Any]
            let curve = [out?["x"], out?["y"], into?["x"], into?["y"]].map(Self.first)
            return Keyframe(time: time, value: value,
                            curve: curve.allSatisfy { $0 != nil }
                                ? (curve[0] ?? 0, curve[1] ?? 0, curve[2] ?? 1, curve[3] ?? 1) : nil,
                            holds: Self.number(key["h"]) == 1)
        }
        return keys.isEmpty ? nil : .keyframes(keys)
    }

    private static func scalar(_ json: Any?) -> Double? { number(json) ?? (json as? [Any]).flatMap { first($0) } }

    private static func vector(_ json: Any?) -> [Double]? {
        if let number = number(json) { return [number] }
        let values = (json as? [Any])?.compactMap(number)
        return values?.isEmpty == false ? values : nil
    }

    /// A path value, also when it comes wrapped in a one-item list (as keyframes do).
    private static func bezier(_ json: Any?) -> Bezier? {
        guard let shape = (json as? [String: Any]) ?? (json as? [Any])?.first as? [String: Any],
              let vertices = points(shape["v"]), !vertices.isEmpty else { return nil }
        let zero = Array(repeating: CGPoint.zero, count: vertices.count)
        return Bezier(closed: shape["c"] as? Bool ?? false, vertices: vertices,
                      inTangents: points(shape["i"]) ?? zero, outTangents: points(shape["o"]) ?? zero)
    }

    private static func points(_ json: Any?) -> [CGPoint]? {
        (json as? [[Any]])?.map { pair in CGPoint(x: number(pair.first) ?? 0, y: number(pair.dropFirst().first) ?? 0) }
    }

    private static func first(_ json: Any?) -> Double? {
        number(json) ?? (json as? [Any])?.first.flatMap(number)
    }

    private static func number(_ json: Any?) -> Double? { (json as? NSNumber)?.doubleValue }
}

private extension Array where Element == Double {
    subscript(safe index: Int, or fallback: Double = 0) -> Double { indices.contains(index) ? self[index] : fallback }
}

private extension Array where Element == CGPoint {
    subscript(safe index: Int) -> CGPoint { indices.contains(index) ? self[index] : .zero }
}

private func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
