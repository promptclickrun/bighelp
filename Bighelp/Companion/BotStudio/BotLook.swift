import Foundation

/// One body from Bot Studio's catalog (`services/avatars/docs/BOT_BODIES.md`): a flat outline in a
/// 100 × 100 box, where its eyes sit, and its default colors. A saved avatar keeps its body, so it
/// still draws after its set leaves the catalog.
struct BotBody: Codable, Equatable, Hashable, Sendable, Identifiable {
    struct Part: Codable, Equatable, Hashable, Sendable {
        enum Tone: String, Codable, Sendable { case main, accent, shade, light, ink }

        let d: String
        let tone: Tone
        /// A line this wide, with round caps and joins; nil fills the shape.
        let stroke: Double?
        /// A filled shape's rounding: a stroke this wide in its own color, with round joins.
        let round: Double?

        init(d: String, tone: Tone = .main, stroke: Double? = nil, round: Double? = nil) {
            self.d = d
            self.tone = tone
            self.stroke = stroke
            self.round = round
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            d = try container.decode(String.self, forKey: .d)
            guard !d.isEmpty, d.utf8.count <= BotBody.maximumPathLength else {
                throw DecodingError.dataCorruptedError(forKey: .d, in: container, debugDescription: "Bad outline")
            }
            // A tone a later catalog adds draws in the main color.
            tone = (try? container.decodeIfPresent(Tone.self, forKey: .tone)) ?? .main
            stroke = (try? container.decodeIfPresent(Double.self, forKey: .stroke)).flatMap { $0 }.map(BotBody.width)
            round = (try? container.decodeIfPresent(Double.self, forKey: .round)).flatMap { $0 }.map(BotBody.width)
        }
    }

    struct Colors: Codable, Equatable, Hashable, Sendable {
        let main: String
        let accent: String?
    }

    /// Where an eye goes, before the body's rotation.
    struct Eye: Equatable, Hashable, Sendable {
        let x: Double
        let y: Double
        let height: Double
    }

    static let maximumParts = 12
    static let maximumPathLength = 4_000

    let id: String
    let name: String
    let role: String?
    let set: String?
    let parts: [Part]
    let eyes: [[Double]]
    let eyeTilt: Double?
    let rotation: Double?
    let colors: Colors

    init(id: String, name: String, role: String? = nil, set: String? = nil, parts: [Part], eyes: [[Double]],
         eyeTilt: Double? = nil, rotation: Double? = nil, colors: Colors) {
        self.id = id
        self.name = name
        self.role = role
        self.set = set
        self.parts = parts
        self.eyes = eyes
        self.eyeTilt = eyeTilt
        self.rotation = rotation
        self.colors = colors
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        role = try? container.decodeIfPresent(String.self, forKey: .role)
        set = try? container.decodeIfPresent(String.self, forKey: .set)
        parts = try container.decode([Part].self, forKey: .parts)
        eyes = try container.decode([[Double]].self, forKey: .eyes)
        eyeTilt = (try? container.decodeIfPresent(Double.self, forKey: .eyeTilt)).flatMap { $0 }
        rotation = (try? container.decodeIfPresent(Double.self, forKey: .rotation)).flatMap { $0 }
        colors = try container.decode(Colors.self, forKey: .colors)
        guard !id.isEmpty, id.utf8.count <= 80, !name.isEmpty, name.utf8.count <= 40,
              (1...Self.maximumParts).contains(parts.count),
              eyes.count == 2, eyes.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) else {
            throw DecodingError.dataCorruptedError(forKey: .parts, in: container, debugDescription: "Bad body")
        }
    }

    var eyeAnchors: [Eye] {
        eyes.map { Eye(x: min(max($0[0], 0), 100), y: min(max($0[1], 0), 100), height: min(max($0[2], 4), 24)) }
    }

    var hasAccent: Bool { parts.contains { $0.tone == .accent } }

    fileprivate static func width(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 24) : 0
    }
}

/// An avatar made in Bot Studio: a body, and what the person picked for it. Saved on the host in the
/// agent's `ui_meta["hermes-bots"]` (`AgentAvatarLook.studio`), so it follows the agent; every
/// other app shows the picture saved with it.
struct BotLook: Codable, Equatable, Hashable, Sendable {
    enum Eyes: String, Codable, CaseIterable, Identifiable, Sendable {
        case classic, capsule, dot, wide, sleepy, happy, wink, visor, odd

        var id: String { rawValue }

        var title: String {
            switch self {
            case .classic: "Classic"
            case .capsule: "Tall"
            case .dot: "Dot"
            case .wide: "Wide"
            case .sleepy: "Sleepy"
            case .happy: "Happy"
            case .wink: "Wink"
            case .visor: "Visor"
            case .odd: "Odd pair"
            }
        }
    }

    enum Mouth: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, smile, open, flat

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: "None"
            case .smile: "Smile"
            case .open: "Open"
            case .flat: "Flat"
            }
        }
    }

    /// What the avatar does while its agent is idle: one of the moods every face plays (`BuddyPose`).
    enum Move: String, Codable, CaseIterable, Identifiable, Sendable {
        case calm, bounce, lookAround, dance, peek, doze

        var id: String { rawValue }

        var title: String {
            switch self {
            case .calm: "Calm"
            case .bounce: "Bounce"
            case .lookAround: "Look around"
            case .dance: "Dance"
            case .peek: "Peek"
            case .doze: "Doze"
            }
        }

        var mood: String {
            switch self {
            case .calm: "idle"
            case .bounce: "bounce"
            case .lookAround: "lookAround"
            case .dance: "dance"
            case .peek: "peek"
            case .doze: "sleepy"
            }
        }
    }

    static let eyeSizes = 0.7...1.4
    static let eyeGaps = -5.0...5.0
    static let tilts = -30.0...30.0
    static let leans = -20.0...20.0
    static let stretches = -1.0...1.0
    static let scales = 0.85...1.15

    var body: BotBody
    var eyes = Eyes.classic
    var eyeSize = 1.0
    var eyeGap = 0.0
    /// nil picks dark or light eyes for the main color.
    var eyeColor: String?
    var mouth = Mouth.none
    var main: String
    /// nil uses the body's own second color.
    var accent: String?
    var cheeks = false
    /// Degrees added to the body's own tilt.
    var tilt = 0.0
    var lean = 0.0
    /// Taller above 0, wider below.
    var stretch = 0.0
    var scale = 1.0
    var mirror = false
    /// Calm unless the person picks a move: an avatar never starts with one.
    var move = Move.calm
    /// 2 since moves start calm. Looks saved before it bounced only because that was the default.
    var version = 2

    init(body: BotBody) {
        self.body = body
        main = body.colors.main
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        body = try container.decode(BotBody.self, forKey: .body)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil }
        func number(_ key: CodingKeys, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            guard let found: Double = value(key), found.isFinite else { return fallback }
            return min(max(found, range.lowerBound), range.upperBound)
        }
        main = value(.main).flatMap(Self.hex) ?? body.colors.main
        accent = value(.accent).flatMap(Self.hex)
        eyeColor = value(.eyeColor).flatMap(Self.hex)
        // Choices a later app adds read as the default here.
        eyes = value(.eyes) ?? .classic
        mouth = value(.mouth) ?? .none
        move = value(.move) ?? .calm
        let saved: Int = value(.version) ?? 1
        if saved < 2, move == .bounce { move = .calm }
        cheeks = value(.cheeks) ?? false
        mirror = value(.mirror) ?? false
        eyeSize = number(.eyeSize, Self.eyeSizes, 1)
        eyeGap = number(.eyeGap, Self.eyeGaps, 0)
        tilt = number(.tilt, Self.tilts, 0)
        lean = number(.lean, Self.leans, 0)
        stretch = number(.stretch, Self.stretches, 0)
        scale = number(.scale, Self.scales, 1)
    }

    /// The colors the body shows: the person's, else the body's own.
    var accentColor: String { accent ?? body.colors.accent ?? main }

    /// The eye color that stands out more on the main color (dark eyes on most bodies, light ones on
    /// a dark body), unless the person picked one.
    var resolvedEyeColor: String {
        if let eyeColor { return eyeColor }
        guard let rgb = HermesCSSColor.rgb(main) else { return Self.darkEyes }
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let body = 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
        // Contrast with the dark eyes (luminance about 0.011) against contrast with the light ones (about 0.86).
        return (body + 0.05) / 0.061 >= 0.91 / (body + 0.05) ? Self.darkEyes : Self.lightEyes
    }

    static let darkEyes = "#1C1A19"
    static let lightEyes = "#F4EFE6"

    /// A new body starts as it comes: its own colors, classic eyes and shape, and no move. Choices made
    /// for another body never carry over.
    mutating func use(_ body: BotBody) {
        self = BotLook(body: body)
    }

    /// `#RRGGBB` in capitals, or nil for anything else.
    static func hex(_ text: String) -> String? {
        let digits = text.hasPrefix("#") ? text.dropFirst() : text[...]
        guard digits.count == 6, digits.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) })
        else { return nil }
        return "#" + digits.uppercased()
    }
}

// MARK: - Choices

extension BotLook {
    /// The main colors on offer, light to dark around the wheel, then the neutrals.
    static let palette = ["#E5484D", "#EF6F2E", "#F0A030", "#F2C94C", "#84C225", "#58C47A", "#14B8A6", "#4FA8F0",
                          "#3B82F6", "#5B5FE6", "#8B5CF6", "#C847E0", "#E8459A", "#8B6440", "#7A7A7A", "#F4F1EA"]

    struct Colorway: Identifiable, Equatable, Sendable {
        let name: String
        let main: String
        let accent: String
        let eyes: String?
        var id: String { name }
    }

    /// Main and second colors that go together.
    static let colorways = [
        Colorway(name: "Sunset", main: "#EF6F2E", accent: "#FFD0A8", eyes: nil),
        Colorway(name: "Sky", main: "#4FA8F0", accent: "#FFFFFF", eyes: nil),
        Colorway(name: "Moss", main: "#58C47A", accent: "#F2C94C", eyes: nil),
        Colorway(name: "Berry", main: "#E8459A", accent: "#5B1A3A", eyes: nil),
        Colorway(name: "Grape", main: "#8B5CF6", accent: "#F2C94C", eyes: nil),
        Colorway(name: "Cocoa", main: "#8B6440", accent: "#F4F1EA", eyes: nil),
        Colorway(name: "Night", main: "#2E3A59", accent: "#9CD3FF", eyes: "#9CD3FF"),
        Colorway(name: "Paper", main: "#F4F1EA", accent: "#E5484D", eyes: nil),
    ]

    static let eyeColors = ["#1C1A19", "#F4EFE6", "#0F766E", "#B45309", "#5B5FE6"]

    /// Something new to start from: any body on offer, a color from the palette, and small
    /// differences in eyes and shape, so two surprises rarely look alike. It never adds a move.
    static func surprise(from bodies: [BotBody], using generator: inout some RandomNumberGenerator) -> BotLook? {
        guard let body = bodies.randomElement(using: &generator) else { return nil }
        var look = BotLook(body: body)
        if Double.random(in: 0...1, using: &generator) < 0.6 {
            look.main = palette.randomElement(using: &generator) ?? body.colors.main
        }
        let eyes: [Eyes] = [.classic, .classic, .classic, .capsule, .dot, .wide, .happy, .sleepy, .wink, .visor, .odd]
        look.eyes = eyes.randomElement(using: &generator) ?? .classic
        look.eyeSize = Double.random(in: 0.85...1.2, using: &generator)
        look.cheeks = Double.random(in: 0...1, using: &generator) < 0.25
        look.mouth = Double.random(in: 0...1, using: &generator) < 0.2 ? .smile : .none
        look.tilt = Double.random(in: -12...12, using: &generator)
        look.lean = Double.random(in: -6...6, using: &generator)
        look.stretch = Double.random(in: -0.25...0.25, using: &generator)
        look.mirror = Bool.random(using: &generator)
        return look
    }

    static func surprise(from bodies: [BotBody]) -> BotLook? {
        var generator = SystemRandomNumberGenerator()
        return surprise(from: bodies, using: &generator)
    }

    /// The body nearest an avatar made before Bot Studio, so the studio opens on something like it:
    /// a Hermes face's silhouette, a Hermes shape, or a kit character's redrawn self.
    static func bodyID(for start: AvatarCreatorStart) -> String? {
        switch start {
        case .look(let look):
            switch look.style {
            case .face: return "hermes." + (HermesBlobShape(look.shape)?.kind?.rawValue ?? "round")
            case .shape: return shapeBodies[look.shape ?? ""] ?? "shapes.ball"
            case .photo: return look.studio?.body.id
            }
        case .character(let appearance), .surprise(let appearance):
            let name = appearance.character.displayName.lowercased()
            return (appearance.character.isBit ? "bits." : "classics.") + name
        default:
            return nil
        }
    }

    /// Hermes' eight shapes, by the Shapes body that draws most like each.
    private static let shapeBodies = [
        "circle": "shapes.ball", "blob": "shapes.puff", "squircle": "shapes.squircle", "pill": "shapes.bean",
        "triangle": "shapes.peak", "hexagon": "shapes.gem", "cloud": "shapes.puff", "drop": "shapes.drop",
    ]

    /// The color an avatar made before Bot Studio had, as `#RRGGBB`.
    static func color(for start: AvatarCreatorStart) -> String? {
        switch start {
        case .look(let look): return look.color.flatMap(hexColor)
        case .character(let appearance): return hex(appearance.colorHex)
        default: return nil
        }
    }

    /// Any color Hermes writes (`#hex` or `hsl()`) as `#RRGGBB`.
    static func hexColor(_ css: String) -> String? {
        guard let rgb = HermesCSSColor.rgb(css) else { return nil }
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.red), byte(rgb.green), byte(rgb.blue))
    }
}
