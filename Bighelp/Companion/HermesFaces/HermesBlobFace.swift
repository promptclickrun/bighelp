import Foundation

/// Hermes Desktop's "blob faces": a Swift port of blobatar 2.0.0 (MIT, © 2026
/// Alain), the library Hermes Desktop's Bot Mode draws them with. The same
/// seed gives the same face down to the SVG path text, so a face picked here
/// is the face Hermes Desktop shows. Notices: ThirdParty-NOTICES.txt.
///
/// Everything below is frozen by blobatar's own contract for its 2.x major:
/// the hash, the trait keys and ranges, the band table and the tone set.
/// Change nothing here without new vectors from the library itself.
enum HermesBlobFace {
    /// The ten silhouettes. `trait` sits in the middle of each one's band, the
    /// value Hermes Desktop pins when a silhouette is chosen.
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case round, organic, boxy, capsule, nub, cloud, droplet, hexagon, sun, triangle

        var id: String { rawValue }

        var trait: Double {
            switch self {
            case .round: 0.11
            case .organic: 0.35
            case .boxy: 0.54
            case .capsule: 0.65
            case .nub: 0.745
            case .cloud: 0.825
            case .droplet: 0.8875
            case .hexagon: 0.9325
            case .sun: 0.965
            case .triangle: 0.99
            }
        }

        var displayName: String { rawValue.capitalized }
    }

    /// One filled element, in the face's 100×100 box.
    enum Part: Equatable, Sendable {
        case circle(cx: Double, cy: Double, r: Double)
        case path(String)
    }

    struct Rendering: Equatable, Sendable {
        let head: String
        let eye: String
        let body: [Part]
        let eyes: [String]

        /// The markup blobatar's `blobatar(seed, opts)` returns, byte for byte.
        var svg: String {
            var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><g fill=\"\(head)\">"
            for part in body {
                switch part {
                case .circle(let cx, let cy, let r):
                    out += "<circle cx=\"\(BlobNumber.r2(cx))\" cy=\"\(BlobNumber.r2(cy))\" r=\"\(BlobNumber.r2(r))\"/>"
                case .path(let d):
                    out += "<path d=\"\(d)\"/>"
                }
            }
            out += "</g><g fill=\"\(eye)\">"
            for d in eyes { out += "<path d=\"\(d)\"/>" }
            return out + "</g></svg>"
        }
    }

    /// The silhouette a seed draws: the pinned one, else the one its `shape` trait falls in.
    static func silhouette(seed: String, kind: Kind?) -> Kind {
        if let kind { return kind }
        let value = BlobTraits(seed: seed)("shape")
        return BlobLayout.bands.first { value < $0.1 }?.0 ?? .triangle
    }

    /// Whether the outline is drawn through `body.r<i>` points, which wobble and mirror edit.
    static func hasWobblyOutline(_ kind: Kind) -> Bool { kind == .organic || kind == .cloud }

    /// `edits` are bighelp's hand edits, applied as blobatar trait overrides.
    static func render(seed: String, kind: Kind? = nil, edits: HermesBlobEdits? = nil) -> Rendering {
        var overrides = edits?.traits ?? [:]
        if let kind { overrides["shape"] = kind.trait }
        let t = BlobTraits(seed: seed, overrides: overrides)
        let palette = BlobColor.palette(hue: t.num("hue", 0, 360), tone: t("tone"))
        let layout = BlobLayout(t)
        var body: [Part] = layout.petals.map { .circle(cx: $0.cx, cy: $0.cy, r: $0.r) }
        body += layout.extra.map { .path($0) }
        body.append(.path(layout.path))
        return Rendering(head: palette.head, eye: palette.eye, body: body,
                         eyes: layout.eyes.map { BlobGeometry.superellipse($0) })
    }
}

// MARK: - Seed hashing (blobatar src/hash.ts, src/traits.ts)

struct BlobTraits {
    private let state: UInt32
    private let overrides: [String: Double]

    init(seed: String, normalize: Bool = true, overrides: [String: Double] = [:]) {
        let text = normalize ? Self.normalized(seed) : seed
        // JavaScript's `length` counts UTF-16 units; the bytes hashed are UTF-8.
        state = Self.feed(1_779_033_703 ^ UInt32(truncatingIfNeeded: text.utf16.count), Array(text.utf8))
        self.overrides = overrides
    }

    static func normalized(_ seed: String) -> String {
        seed.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Uniform in [0, 1) for `key`, independent of every other key.
    func callAsFunction(_ key: String) -> Double {
        if let value = overrides[key] { return value > 0 ? (value < 1 ? value : 0.999999) : 0 }
        return Double(Self.finalize(Self.feed(Self.feed(state, [0xFF]), Array(key.utf8)))) / 4_294_967_296
    }

    func num(_ key: String, _ min: Double, _ max: Double) -> Double { min + self(key) * (max - min) }
    func int(_ key: String, _ min: Int, _ max: Int) -> Int {
        min + Int((self(key) * Double(max - min + 1)).rounded(.down))
    }
    func jitter(_ key: String, _ amount: Double) -> Double { (self(key) * 2 - 1) * amount }

    private static func feed(_ start: UInt32, _ bytes: [UInt8]) -> UInt32 {
        var h = start
        for byte in bytes {
            h = (h ^ UInt32(byte)) &* 3_432_918_353
            h = (h << 13) | (h >> 19)
        }
        return h
    }

    private static func finalize(_ start: UInt32) -> UInt32 {
        var h = (start ^ (start >> 16)) &* 2_246_822_507
        h = (h ^ (h >> 13)) &* 3_266_489_909
        return h ^ (h >> 16)
    }
}

// MARK: - Numbers as JavaScript writes them

enum BlobNumber {
    /// `Math.round`: halves go toward +∞, unlike Swift's schoolbook rounding.
    static func jsRound(_ value: Double) -> Double {
        let floor = value.rounded(.down)
        return value - floor >= 0.5 ? floor + 1 : floor
    }

    /// blobatar's `r2`: two decimals, written the way `String(number)` does.
    static func r2(_ value: Double) -> String {
        let rounded = jsRound(value * 100) / 100
        if rounded == 0 { return "0" }
        if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int64(rounded)) }
        return "\(rounded)"
    }

    /// V8's `Math.hypot` (normalized Kahan sum), so near-threshold fits agree.
    static func jsHypot(_ values: Double...) -> Double {
        let magnitudes = values.map(abs)
        let largest = magnitudes.max() ?? 0
        guard largest > 0, largest.isFinite else { return largest }
        var sum = 0.0
        var compensation = 0.0
        for magnitude in magnitudes {
            let normalized = magnitude / largest
            let summand = normalized * normalized - compensation
            let preliminary = sum + summand
            compensation = (preliminary - sum) - summand
            sum = preliminary
        }
        return sum.squareRoot() * largest
    }
}

// MARK: - Path primitives (blobatar src/shape.ts)

enum BlobGeometry {
    struct Superellipse {
        var cx: Double, cy: Double, rx: Double, ry: Double
        var n: Double = 4
        var rot: Double = 0
    }

    static func superellipse(_ e: Superellipse) -> String {
        let k = min(1, (8 * pow(2, -1 / e.n) - 4) / 3)
        let a = e.rx, b = e.ry
        let ak = a * k, bk = b * k
        let points: [(Double, Double)] = [
            (a, 0),
            (a, bk), (ak, b), (0, b),
            (-ak, b), (-a, bk), (-a, 0),
            (-a, -bk), (-ak, -b), (0, -b),
            (ak, -b), (a, -bk), (a, 0),
        ]
        let t = (e.rot * Double.pi) / 180
        let cosine = cos(t), sine = sin(t)
        func at(_ index: Int) -> String {
            let (x, y) = points[index]
            return "\(BlobNumber.r2(e.cx + x * cosine - y * sine)) \(BlobNumber.r2(e.cy + x * sine + y * cosine))"
        }
        var d = "M\(at(0))"
        for index in stride(from: 1, to: 13, by: 3) { d += "C\(at(index)) \(at(index + 1)) \(at(index + 2))" }
        return d + "Z"
    }

    static func blobPath(cx: Double, cy: Double, rx: Double, ry: Double, radii: [Double], rot: Double = 0) -> String {
        let n = radii.count
        let t0 = (rot * Double.pi) / 180
        let points: [(Double, Double)] = radii.enumerated().map { index, m in
            let angle = t0 + (2 * Double.pi * Double(index)) / Double(n)
            return (cx + rx * m * cos(angle), cy + ry * m * sin(angle))
        }
        func at(_ index: Int) -> (Double, Double) { points[((index % n) + n) % n] }
        let r2 = BlobNumber.r2
        var d = "M\(r2(at(0).0)) \(r2(at(0).1))"
        for index in 0..<n {
            let (x0, y0) = at(index - 1), (x1, y1) = at(index), (x2, y2) = at(index + 1), (x3, y3) = at(index + 2)
            d += "C\(r2(x1 + (x2 - x0) / 6)) \(r2(y1 + (y2 - y0) / 6))"
                + " \(r2(x2 - (x3 - x1) / 6)) \(r2(y2 - (y3 - y1) / 6))"
                + " \(r2(x2)) \(r2(y2))"
        }
        return d + "Z"
    }

    static func polygon(cx: Double, cy: Double, rx: Double, ry: Double, sides: Int, round: Double, rot: Double) -> String {
        let k = round > 0 ? (round < 1 ? round / 2 : 0.5) : 0
        let t0 = (rot * Double.pi) / 180 - Double.pi / 2
        let vertices: [(Double, Double)] = (0..<sides).map { index in
            let angle = t0 + (2 * Double.pi * Double(index)) / Double(sides)
            return (cx + rx * cos(angle), cy + ry * sin(angle))
        }
        func at(_ index: Int) -> (Double, Double) { vertices[((index % sides) + sides) % sides] }
        func cut(_ i: Int, _ j: Int) -> String {
            let (x0, y0) = at(i), (x1, y1) = at(j)
            return "\(BlobNumber.r2(x0 + (x1 - x0) * k)) \(BlobNumber.r2(y0 + (y1 - y0) * k))"
        }
        var d = "M\(cut(0, -1))"
        for index in 0..<sides {
            let (x, y) = at(index)
            d += "Q\(BlobNumber.r2(x)) \(BlobNumber.r2(y)) \(cut(index, index + 1))"
            if k < 0.5 { d += "L\(cut(index + 1, index))" }
        }
        return d + "Z"
    }

    static func box(cx: Double, cy: Double, rx: Double, ry: Double) -> String {
        let left = BlobNumber.r2(cx - rx), right = BlobNumber.r2(cx + rx)
        return "M\(left) \(BlobNumber.r2(cy - ry))H\(right)V\(BlobNumber.r2(cy + ry))H\(left)Z"
    }

    static func taper(cx: Double, cy: Double, rx: Double, ry: Double, tip: Double) -> String {
        let t = max(1.05, tip)
        let tx = rx * (1 - 1 / (t * t)).squareRoot()
        let ty = cy - ry / t
        let apex = cy - t * ry
        let px = tx * 0.14
        let py = ty + 0.86 * (apex - ty)
        let r2 = BlobNumber.r2
        return "M\(r2(cx - tx)) \(r2(ty))L\(r2(cx - px)) \(r2(py))Q\(r2(cx)) \(r2(apex)) \(r2(cx + px)) \(r2(py))L\(r2(cx + tx)) \(r2(ty))Z"
    }
}

// MARK: - Layout (blobatar src/styles/compose.ts, shapes.ts, blob.ts)

private struct BlobLayout {
    struct Body {
        var cx: Double, cy: Double, rx: Double, ry: Double, n: Double, rot: Double
        var radii: [Double]
        var sides = 0
        var round = 0.0
    }
    struct Ellipse { var cx: Double, cy: Double, rx: Double, ry: Double }
    struct Petal { var cx: Double, cy: Double, r: Double }

    private(set) var petals: [Petal] = []
    private(set) var extra: [String] = []
    private(set) var path = ""
    private(set) var eyes: [BlobGeometry.Superellipse] = []

    /// The frozen band table: upper edge of each silhouette's band.
    fileprivate static let bands: [(HermesBlobFace.Kind, Double)] = [
        (.round, 0.22), (.organic, 0.48), (.boxy, 0.6), (.capsule, 0.7), (.nub, 0.79),
        (.cloud, 0.86), (.droplet, 0.915), (.hexagon, 0.95), (.sun, 0.98), (.triangle, 1),
    ]

    init(_ t: BlobTraits) {
        let value = t("shape")
        let kind = Self.bands.first { value < $0.1 }?.0 ?? .triangle
        let r = t.num("body.r", 31, 38) * Self.core(kind)
        var body = Body(
            cx: 50 + t.jitter("body.x", 1.5), cy: 50 + t.jitter("body.y", 1.5),
            rx: r, ry: r * t.num("body.ratio", 0.92, 1.08), n: t.num("body.n", 1.9, 2.5), rot: 0,
            radii: (0..<t.int("body.pts", 6, 8)).map { 1 + t.jitter("body.r\($0)", 0.16) }
        )
        Self.patch(kind, t, &body)
        let face = Self.face(kind, body)
        decorate(kind, t, body)
        path = Self.draw(kind, body)
        eyes = Self.fit(t, body, face)
    }

    private static func core(_ kind: HermesBlobFace.Kind) -> Double {
        switch kind {
        case .round: 1
        case .organic: 0.98
        case .boxy: 0.86
        case .capsule: 1.02
        case .nub: 0.88
        case .cloud, .droplet: 0.78
        case .hexagon: 1.05
        case .sun: 0.7
        case .triangle: 1.15
        }
    }

    private static func patch(_ kind: HermesBlobFace.Kind, _ t: BlobTraits, _ b: inout Body) {
        switch kind {
        case .boxy:
            b.n = t.num("body.n", 3.4, 6)
            b.rot = t.num("body.rot", -20, 20)
        case .capsule:
            b.ry *= t.num("capsule.squat", 0.55, 0.68)
        case .droplet:
            b.cy += 0.22 * b.ry
            b.n = 2
        case .hexagon:
            b.sides = 6
            b.rot = t.num("body.rot", -12, 12)
            b.round = t.num("poly.round", 0.24, 0.5)
        case .triangle:
            b.sides = 3
            b.rot = t.num("body.rot", -5, 5)
            b.round = t.num("poly.round", 0.24, 0.5)
        default:
            break
        }
    }

    private static func shrunk(_ b: Body, _ k: Double) -> Ellipse { Ellipse(cx: b.cx, cy: b.cy, rx: b.rx * k, ry: b.ry * k) }

    private static func face(_ kind: HermesBlobFace.Kind, _ b: Body) -> Ellipse {
        switch kind {
        case .organic, .cloud: shrunk(b, (b.radii.min() ?? 1) * 0.95)
        case .capsule: shrunk(b, 0.94)
        case .droplet: Ellipse(cx: b.cx, cy: b.cy + b.ry * 0.05, rx: b.rx * 0.88, ry: b.ry * 0.88)
        case .hexagon: shrunk(b, 0.84)
        case .triangle: Ellipse(cx: b.cx, cy: b.cy + b.ry * 0.1, rx: b.rx * 0.54, ry: b.ry * 0.36)
        default: Ellipse(cx: b.cx, cy: b.cy, rx: b.rx, ry: b.ry)
        }
    }

    private mutating func decorate(_ kind: HermesBlobFace.Kind, _ t: BlobTraits, _ b: Body) {
        switch kind {
        case .capsule:
            for side in [-1.0, 1.0] { petals.append(Petal(cx: b.cx + side * (b.rx - b.ry), cy: b.cy, r: b.ry)) }
        case .nub:
            for index in 0..<t.int("nub.n", 1, 2) {
                let angle = t.num("nub.a\(index)", 0, 2 * Double.pi)
                petals.append(Petal(cx: b.cx + cos(angle) * b.rx * 0.88, cy: b.cy + sin(angle) * b.rx * 0.88,
                                    r: b.rx * t.num("nub.r\(index)", 0.24, 0.4)))
            }
        case .cloud:
            let count = t.int("cloud.n", 4, 6)
            for index in 0..<count {
                let angle = Double.pi + (Double.pi * (Double(index) + 0.5)) / Double(count)
                petals.append(Petal(cx: b.cx + cos(angle) * b.rx * 0.8, cy: b.cy + sin(angle) * b.rx * 0.5,
                                    r: b.rx * t.num("cloud.r\(index)", 0.44, 0.62)))
            }
        case .droplet:
            extra.append(BlobGeometry.taper(cx: b.cx, cy: b.cy, rx: b.rx, ry: b.ry, tip: t.num("droplet.tip", 1.4, 1.65)))
        case .sun:
            let count = t.int("sun.n", 6, 9)
            let distance = b.rx * t.num("sun.dist", 1.0, 1.08)
            let radius = b.rx * t.num("sun.r", 0.2, 0.26)
            let offset = t.num("sun.rot", 0, 2 * Double.pi)
            for index in 0..<count {
                let angle = offset + (2 * Double.pi * Double(index)) / Double(count)
                petals.append(Petal(cx: b.cx + cos(angle) * distance, cy: b.cy + sin(angle) * distance, r: radius))
            }
        default:
            break
        }
    }

    private static func draw(_ kind: HermesBlobFace.Kind, _ b: Body) -> String {
        switch kind {
        case .organic, .cloud:
            BlobGeometry.blobPath(cx: b.cx, cy: b.cy, rx: b.rx, ry: b.ry, radii: b.radii, rot: b.rot)
        case .capsule:
            BlobGeometry.box(cx: b.cx, cy: b.cy, rx: b.rx - b.ry, ry: b.ry)
        case .hexagon, .triangle:
            BlobGeometry.polygon(cx: b.cx, cy: b.cy, rx: b.rx, ry: b.ry, sides: b.sides, round: b.round, rot: b.rot)
        default:
            BlobGeometry.superellipse(.init(cx: b.cx, cy: b.cy, rx: b.rx, ry: b.ry, n: b.n, rot: b.rot))
        }
    }

    /// `faceFit`: the eye cluster, scaled down until it fits the face region.
    private static func fit(_ t: BlobTraits, _ b: Body, _ face: Ellipse) -> [BlobGeometry.Superellipse] {
        let rx = b.rx
        let er0 = t.num("eye.rx", 0.075, 0.105) * rx
        let ratio = t.num("eye.ratio", 1.9, 3.2)
        let scale = t.num("eye.scale", 0.78, 1.24)
        let stretch = t.num("eye.stretch", 0.85, 1.18)
        let clearance = t.num("eye.gap", 0.1, 0.24) * rx
        let wide = er0 * max(1, scale)
        let tall = er0 * ratio * max(1, scale * stretch)
        let gap0 = wide + rx * 0.03 + clearance

        let gx = t.jitter("gaze.x", 0.09) * face.rx
        let gy = t.num("gaze.y", -0.2, 0.08) * face.ry
        let dy = t.jitter("eye.dy", 0.04) * face.ry
        let reach = BlobNumber.jsHypot(wide, tall)
        let need = BlobNumber.jsHypot((abs(gx) + gap0 + reach) / face.rx, (abs(gy) + abs(dy) + reach) / face.ry)
        let fit = need > 0.9 ? 0.9 / need : 1

        let er = er0 * fit
        let eyeRy = er * ratio
        let gap = gap0 * fit
        let room = max(0, min(1, clearance / tall))
        let bound = min(12, (asin(room) * 180) / Double.pi)
        let lean = t.num("eye.lean", -1, 1) * bound
        let lean2 = max(-12, min(12, lean + t.jitter("eye.lean2", 3.5)))

        let cx = face.cx + gx * fit
        let cy = face.cy + gy * fit
        return [
            .init(cx: cx - gap, cy: cy, rx: er, ry: eyeRy, n: t.num("eye.n", 3.5, 6), rot: lean),
            .init(cx: cx + gap, cy: cy + dy * fit, rx: er * scale, ry: eyeRy * scale * stretch,
                  n: t.num("eye.n", 3.5, 6), rot: lean2),
        ]
    }
}

// MARK: - Palette (blobatar src/color.ts)

enum BlobColor {
    struct Oklch { var l: Double, c: Double, h: Double }

    /// Pale and mid tones dominate; the near-black ink body stays a rare find.
    private static let tones: [(Double, Double, Double)] = [
        (0.2, 0.86, 0.085), (0.36, 0.9, 0.028), (0.62, 0.73, 0.135),
        (0.8, 0.62, 0.165), (0.93, 0.87, 0.16), (1.0, 0.34, 0.035),
    ]
    private static let darkSurface = Oklch(l: 0.145, c: 0, h: 0)

    static func palette(hue h: Double, tone: Double) -> (head: String, eye: String) {
        let swatch = tones.first { tone < $0.0 } ?? tones[0]
        let bg = Oklch(l: 0.965, c: 0.01, h: h)
        var head = ensureContrast(Oklch(l: swatch.1, c: swatch.2, h: h), darkSurface, 1.5)
        var eye = head.l >= 0.5 ? Oklch(l: 0.17, c: 0.02, h: h) : Oklch(l: 0.97, c: 0.012, h: h)
        head = ensureContrast(head, bg, 1.25)
        eye = ensureContrast(eye, head, 4.5)
        return (hex(head), hex(eye))
    }

    private static func linear(_ color: Oklch) -> [Double] {
        let r = (color.h * Double.pi) / 180
        let a = color.c * cos(r)
        let b = color.c * sin(r)
        let l_ = color.l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = color.l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = color.l - 0.0894841775 * a - 1.291485548 * b
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        return [
            4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S,
            -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S,
            -0.0041960863 * L - 0.7034186147 * M + 1.707614701 * S,
        ]
    }

    /// In-gamut sRGB, giving up chroma rather than shifting hue.
    private static func resolve(_ color: Oklch) -> [Double] {
        func inGamut(_ rgb: [Double]) -> Bool { rgb.allSatisfy { $0 >= -1e-4 && $0 <= 1 + 1e-4 } }
        var rgb = linear(color)
        if !inGamut(rgb) {
            var low = 0.0, high = color.c
            for _ in 0..<12 {
                let mid = (low + high) / 2
                if inGamut(linear(Oklch(l: color.l, c: mid, h: color.h))) { low = mid } else { high = mid }
            }
            rgb = linear(Oklch(l: color.l, c: low, h: color.h))
        }
        return rgb.map { min(1, max(0, $0)) }
    }

    private static func luminance(_ color: Oklch) -> Double {
        let rgb = resolve(color)
        return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
    }

    static func contrast(_ a: Oklch, _ b: Oklch) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func ensureContrast(_ fg: Oklch, _ bg: Oklch, _ minimum: Double) -> Oklch {
        if contrast(fg, bg) >= minimum { return fg }
        let lean: Double = fg.l >= bg.l ? 1 : -1
        for direction in [lean, -lean] {
            var probe = fg
            for _ in 0..<60 {
                probe.l = min(1, max(0, probe.l + direction * 0.02))
                if contrast(probe, bg) >= minimum { return probe }
                if probe.l == 0 || probe.l == 1 { break }
            }
        }
        let black = Oklch(l: 0, c: 0, h: fg.h), white = Oklch(l: 1, c: 0, h: fg.h)
        return contrast(black, bg) >= contrast(white, bg) ? black : white
    }

    static func hex(_ color: Oklch) -> String {
        "#" + resolve(color).map { value -> String in
            let encoded = value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
            let byte = Int(BlobNumber.jsRound(encoded * 255))
            let text = String(byte, radix: 16)
            return text.count < 2 ? "0" + text : text
        }.joined()
    }
}
