import Foundation
import Observation

/// bighelp's avatar characters (the kit in `Design/AvatarKit`): ten
/// characters, then ten Bits with a swappable face.
enum CompanionCharacter: String, Codable, CaseIterable, Identifiable, Sendable {
    case lobster
    case messenger
    case dog
    case cat
    case zeus
    case robot
    case owl
    case octopus
    case fox
    case dragon
    case orb
    case cube
    case wedge
    case hex
    case drop
    case capsule
    case cloud
    case ghost
    case bloom
    case gem

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lobster: "Pinch"
        case .messenger: "Aeria"
        case .dog: "Biscuit"
        case .cat: "Miso"
        case .zeus: "Bolt"
        case .robot: "Rivet"
        case .owl: "Sage"
        case .octopus: "Inky"
        case .fox: "Kit"
        case .dragon: "Ember"
        case .orb: "Bop"
        case .cube: "Blok"
        case .wedge: "Wedge"
        case .hex: "Hexo"
        case .drop: "Drip"
        case .capsule: "Tic"
        case .cloud: "Puff"
        case .ghost: "Boo"
        case .bloom: "Bloom"
        case .gem: "Glim"
        }
    }

    /// Bits have a swappable face (eyes, mouth, accessory, cheeks).
    var isBit: Bool {
        switch self {
        case .orb, .cube, .wedge, .hex, .drop, .capsule, .cloud, .ghost, .bloom, .gem: true
        default: false
        }
    }

    static var characters: [CompanionCharacter] { allCases.filter { !$0.isBit } }
    static var bits: [CompanionCharacter] { allCases.filter(\.isBit) }

    /// Characters from earlier builds, mapped to the closest current one so a
    /// saved look keeps working.
    static let legacyIDs: [String: CompanionCharacter] = [
        "clawdi": .lobster, "fleur": .messenger, "puff": .cloud, "tri": .wedge,
        "pip": .octopus, "umbra": .ghost, "wisp": .ghost,
        "quad": .cube, "clip": .robot, "orbit": .orb,
        "sol": .dragon, "honey": .hex, "momo": .owl, "klee": .cat, "rosa": .bloom,
        "glob": .drop, "jelly": .drop, "mallow": .capsule
    ]

    /// A current or earlier character ID.
    init?(id: String) {
        guard let character = CompanionCharacter(rawValue: id) ?? Self.legacyIDs[id] else { return nil }
        self = character
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CompanionCharacter(id: raw) ?? .lobster
    }
}

/// A Bit's eyes (the kit's face options).
enum CompanionBitEyes: String, Codable, CaseIterable, Identifiable, Sendable {
    case round, dot, pill, square, lidded, visor, cyclops

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .round: "Round"
        case .dot: "Dot"
        case .pill: "Pill"
        case .square: "Square"
        case .lidded: "Sleepy"
        case .visor: "Visor"
        case .cyclops: "One eye"
        }
    }
}

/// A Bit's mouth.
enum CompanionBitMouth: String, Codable, CaseIterable, Identifiable, Sendable {
    case smile, cat, flat, fang, none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .smile: "Smile"
        case .cat: "Cat"
        case .flat: "Flat"
        case .fang: "Fang"
        case .none: "None"
        }
    }
}

/// Something a Bit wears on top.
enum CompanionBitAccessory: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, antenna, sprout, halo, crown, bow, headset

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "None"
        case .antenna: "Antenna"
        case .sprout: "Sprout"
        case .halo: "Halo"
        case .crown: "Crown"
        case .bow: "Bow"
        case .headset: "Headset"
        }
    }
}

/// Eye outline.
enum CompanionEyeStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case plain
    case visor = "visorSlit"
    case scowl
    case venom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plain: "Round"
        case .visor: "Visor"
        case .scowl: "Scowl"
        case .venom: "Sharp"
        }
    }
}

/// Headwear.
enum CompanionTopper: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case catEars
    case bearEars
    case crown
    case halo
    case devilHorns
    case sprout
    case swoosh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "None"
        case .catEars: "Cat ears"
        case .bearEars: "Bear ears"
        case .crown: "Crown"
        case .halo: "Halo"
        case .devilHorns: "Horns"
        case .sprout: "Sprout"
        case .swoosh: "Swoosh"
        }
    }
}

/// Surface pattern, drawn in shades of the body color.
enum CompanionPattern: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case hex
    case camo
    case ripple
    case wire
    case nebula
    case lava
    case plasma
    case lightning

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "Plain"
        case .hex: "Honeycomb"
        case .camo: "Camo"
        case .ripple: "Grid"
        case .wire: "Circuit"
        case .nebula: "Galaxy"
        case .lava: "Lava"
        case .plasma: "Plasma"
        case .lightning: "Storm"
        }
    }
}

/// How the avatar moves when nothing else is happening.
enum CompanionVibe: String, Codable, CaseIterable, Identifiable, Sendable {
    case calm
    case bouncy
    case dancer
    case cheerful
    case curious
    case sleepy
    case zen
    case spinner

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .calm: "Calm"
        case .bouncy: "Bouncy"
        case .dancer: "Dancer"
        case .cheerful: "Cheerful"
        case .curious: "Curious"
        case .sleepy: "Sleepy"
        case .zen: "Zen"
        case .spinner: "Spinner"
        }
    }

    var systemImage: String {
        switch self {
        case .calm: "leaf"
        case .bouncy: "arrow.up.and.down"
        case .dancer: "music.note"
        case .cheerful: "face.smiling"
        case .curious: "eyes"
        case .sleepy: "moon.zzz"
        case .zen: "sparkles"
        case .spinner: "arrow.triangle.2.circlepath"
        }
    }

    /// Character mood ID for this move.
    var moodID: String {
        switch self {
        case .calm: "idle"
        case .bouncy: "bounce"
        case .dancer: "dance"
        case .cheerful: "happy"
        case .curious: "lookAround"
        case .sleepy: "sleepy"
        case .zen: "meditate"
        case .spinner: "spin"
        }
    }
}

struct CompanionAppearance: Codable, Equatable, Sendable {
    static let fallbackColorHex = "#FF5A4F"

    var character: CompanionCharacter
    private var storedColorHex: String
    var matchesTheme: Bool
    /// Optional avatar-creator choices. nil keeps each character's own look.
    var eyeStyle: CompanionEyeStyle?
    private var storedEyeColorHex: String?
    var topper: CompanionTopper?
    var pattern: CompanionPattern?
    var vibe: CompanionVibe?
    /// Avatar kit colorway ID; nil keeps the character's own palette.
    var colorway: String?
    /// A Bit's face parts; nil keeps the Bit's own.
    var bitEyes: CompanionBitEyes?
    var bitMouth: CompanionBitMouth?
    var bitAccessory: CompanionBitAccessory?
    var showsCheeks: Bool
    /// True keeps the character's (or colorway's) main color instead of
    /// tinting it with `colorHex` or the app theme.
    var usesCharacterColors: Bool
    /// A character from the avatar catalog; it draws instead of `character`, which stays for
    /// builds that don't know the catalog.
    var catalogAvatar: AvatarCatalogReference?

    var colorHex: String {
        get { storedColorHex }
        set { storedColorHex = Self.validatedColorHex(newValue) ?? Self.fallbackColorHex }
    }

    /// nil picks a readable eye color for the body automatically.
    var eyeColorHex: String? {
        get { storedEyeColorHex }
        set { storedEyeColorHex = newValue.flatMap(Self.validatedColorHex) }
    }

    init(
        character: CompanionCharacter = .lobster,
        colorHex: String = CompanionAppearance.fallbackColorHex,
        matchesTheme: Bool = true,
        eyeStyle: CompanionEyeStyle? = nil,
        eyeColorHex: String? = nil,
        topper: CompanionTopper? = nil,
        pattern: CompanionPattern? = nil,
        vibe: CompanionVibe? = nil,
        colorway: String? = nil,
        usesCharacterColors: Bool = false,
        bitEyes: CompanionBitEyes? = nil,
        bitMouth: CompanionBitMouth? = nil,
        bitAccessory: CompanionBitAccessory? = nil,
        showsCheeks: Bool = true,
        catalogAvatar: AvatarCatalogReference? = nil
    ) {
        self.character = character
        storedColorHex = Self.validatedColorHex(colorHex) ?? Self.fallbackColorHex
        self.matchesTheme = matchesTheme
        self.eyeStyle = eyeStyle
        storedEyeColorHex = eyeColorHex.flatMap(Self.validatedColorHex)
        self.topper = topper
        self.pattern = pattern
        self.vibe = vibe
        self.colorway = colorway.flatMap(Self.validatedColorway)
        self.usesCharacterColors = usesCharacterColors
        self.bitEyes = bitEyes
        self.bitMouth = bitMouth
        self.bitAccessory = bitAccessory
        self.showsCheeks = showsCheeks
        self.catalogAvatar = catalogAvatar
    }

    private enum CodingKeys: String, CodingKey {
        case character
        case colorHex
        case matchesTheme
        case eyeStyle
        case eyeColorHex
        case topper
        case pattern
        case vibe
        case colorway
        case usesCharacterColors
        case bitEyes
        case bitMouth
        case bitAccessory
        case showsCheeks
        case catalogAvatar
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        character = try container.decode(CompanionCharacter.self, forKey: .character)
        let colorHex = try container.decode(String.self, forKey: .colorHex)
        guard let validatedColor = Self.validatedColorHex(colorHex) else {
            throw DecodingError.dataCorruptedError(
                forKey: .colorHex,
                in: container,
                debugDescription: "Companion colors must use six-digit hexadecimal RGB."
            )
        }
        storedColorHex = validatedColor
        matchesTheme = try container.decode(Bool.self, forKey: .matchesTheme)
        // Creator choices are optional; an unknown value from a newer build
        // falls back to the character's own look instead of losing the pet.
        eyeStyle = try? container.decodeIfPresent(CompanionEyeStyle.self, forKey: .eyeStyle)
        storedEyeColorHex = (try? container.decodeIfPresent(String.self, forKey: .eyeColorHex))
            .flatMap { $0 }.flatMap(Self.validatedColorHex)
        topper = try? container.decodeIfPresent(CompanionTopper.self, forKey: .topper)
        pattern = try? container.decodeIfPresent(CompanionPattern.self, forKey: .pattern)
        vibe = try? container.decodeIfPresent(CompanionVibe.self, forKey: .vibe)
        colorway = (try? container.decodeIfPresent(String.self, forKey: .colorway)).flatMap { $0 }.flatMap(Self.validatedColorway)
        // Looks saved before the kit always tinted the body.
        usesCharacterColors = (try? container.decodeIfPresent(Bool.self, forKey: .usesCharacterColors)).flatMap { $0 } ?? false
        bitEyes = try? container.decodeIfPresent(CompanionBitEyes.self, forKey: .bitEyes)
        bitMouth = try? container.decodeIfPresent(CompanionBitMouth.self, forKey: .bitMouth)
        bitAccessory = try? container.decodeIfPresent(CompanionBitAccessory.self, forKey: .bitAccessory)
        showsCheeks = (try? container.decodeIfPresent(Bool.self, forKey: .showsCheeks)).flatMap { $0 } ?? true
        catalogAvatar = (try? container.decodeIfPresent(AvatarCatalogReference.self, forKey: .catalogAvatar)).flatMap { $0 }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(character, forKey: .character)
        try container.encode(storedColorHex, forKey: .colorHex)
        try container.encode(matchesTheme, forKey: .matchesTheme)
        try container.encodeIfPresent(eyeStyle, forKey: .eyeStyle)
        try container.encodeIfPresent(storedEyeColorHex, forKey: .eyeColorHex)
        try container.encodeIfPresent(topper, forKey: .topper)
        try container.encodeIfPresent(pattern, forKey: .pattern)
        try container.encodeIfPresent(vibe, forKey: .vibe)
        try container.encodeIfPresent(colorway, forKey: .colorway)
        try container.encode(usesCharacterColors, forKey: .usesCharacterColors)
        try container.encodeIfPresent(bitEyes, forKey: .bitEyes)
        try container.encodeIfPresent(bitMouth, forKey: .bitMouth)
        try container.encodeIfPresent(bitAccessory, forKey: .bitAccessory)
        if !showsCheeks { try container.encode(showsCheeks, forKey: .showsCheeks) }
        try container.encodeIfPresent(catalogAvatar, forKey: .catalogAvatar)
    }

    static func validatedColorway(_ value: String) -> String? {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 32,
              bytes.allSatisfy({ ASCIIText.isLowercaseLetter($0) || ASCIIText.isDigit($0) || $0 == UInt8(ascii: "-") })
        else { return nil }
        return value
    }

    /// Byte by byte, without Foundation's character sets: on one tester's iPhone that check turned
    /// down every valid color, so every avatar drew in `fallbackColorHex`.
    static func validatedColorHex(_ value: String) -> String? {
        var digits = ArraySlice(value.utf8)
        while let first = digits.first, ASCIIText.isSpace(first) { digits = digits.dropFirst() }
        while let last = digits.last, ASCIIText.isSpace(last) { digits = digits.dropLast() }
        if digits.first == UInt8(ascii: "#") { digits = digits.dropFirst() }
        guard digits.count == 6, digits.allSatisfy(ASCIIText.isHexDigit) else { return nil }
        return "#" + String(decoding: digits.map(ASCIIText.uppercased), as: UTF8.self)
    }
}

@MainActor
@Observable
final class CompanionStore {
    static let currentSchemaVersion = 1
    // Catalog characters add their pack reference to each look.
    static let maximumPersistedBytes = 262_144
    static let maximumOverrides = 256
    static let maximumKeyUTF8Count = 512
    nonisolated static let minimumSizeScale = 0.6
    nonisolated static let maximumSizeScale = 1.5
    nonisolated static let defaultSizeScale = 1.0

    var isEnabled: Bool {
        didSet { persistIfReady() }
    }

    var defaultAppearance: CompanionAppearance {
        didSet { persistIfReady() }
    }

    private var storedSizeScale: Double

    var sizeScale: Double {
        get { storedSizeScale }
        set {
            storedSizeScale = Self.sanitizedSizeScale(newValue)
            persistIfReady()
        }
    }

    var isAdventurous: Bool {
        didSet { persistIfReady() }
    }

    private(set) var agentOverrides: [String: CompanionAppearance] {
        didSet { persistIfReady() }
    }

    /// A new phone's pet: bighelp's first character, in its own colors.
    static var firstPet: CompanionAppearance {
        var appearance = CompanionAppearance(usesCharacterColors: true)
        appearance.catalogAvatar = AvatarCatalog.bundled.avatars(in: .bighelp, at: .now).first.map(AvatarCatalogReference.init)
        return appearance
    }

    private static let storageKey = "loopdy.companion.preferences"
    private let defaults: UserDefaults
    private var isReadyToPersist = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let persisted = Self.readPersistedState(from: defaults, key: Self.storageKey)
        isEnabled = persisted?.isEnabled ?? false
        defaultAppearance = Self.sanitized(persisted?.defaultAppearance ?? Self.firstPet)
        storedSizeScale = Self.sanitizedSizeScale(persisted?.sizeScale ?? Self.defaultSizeScale)
        isAdventurous = persisted?.isAdventurous ?? false
        agentOverrides = persisted?.agentOverrides ?? [:]
        isReadyToPersist = true
    }

    func appearance(for agentKey: String?) -> CompanionAppearance {
        guard let agentKey else { return defaultAppearance }
        return agentOverrides[agentKey] ?? defaultAppearance
    }

    func override(for agentKey: String) -> CompanionAppearance? {
        agentOverrides[agentKey]
    }

    func setOverride(_ appearance: CompanionAppearance?, for agentKey: String) {
        guard Self.isValidKey(agentKey) else { return }
        if let appearance {
            guard agentOverrides[agentKey] != appearance else { return }
            if agentOverrides[agentKey] == nil, agentOverrides.count >= Self.maximumOverrides {
                return
            }
            var candidate = agentOverrides
            candidate[agentKey] = Self.sanitized(appearance)
            let state = PersistedState(
                schemaVersion: Self.currentSchemaVersion,
                isEnabled: isEnabled,
                defaultAppearance: Self.sanitized(defaultAppearance),
                sizeScale: sizeScale,
                isAdventurous: isAdventurous,
                agentOverrides: candidate
            )
            // Reserve space for future bounded preference changes. Never accept
            // an override in memory which cannot survive reopening.
            guard let encoded = try? JSONEncoder().encode(state),
                  encoded.count <= Self.maximumPersistedBytes - 256 else { return }
            agentOverrides = candidate
        } else {
            agentOverrides.removeValue(forKey: agentKey)
        }
    }

    func clearAgentOverrides() {
        guard !agentOverrides.isEmpty else { return }
        agentOverrides.removeAll(keepingCapacity: false)
    }

    static func agentKey(agentScope: String, agentID: String) -> String {
        "\(agentScope.utf8.count):\(agentScope)\(agentID.utf8.count):\(agentID)"
    }

    private struct PersistedState: Codable {
        let schemaVersion: Int
        let isEnabled: Bool
        let defaultAppearance: CompanionAppearance
        let sizeScale: Double
        let isAdventurous: Bool
        let agentOverrides: [String: CompanionAppearance]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case isEnabled
            case defaultAppearance
            case sizeScale
            case isAdventurous
            case agentOverrides
        }

        init(
            schemaVersion: Int,
            isEnabled: Bool,
            defaultAppearance: CompanionAppearance,
            sizeScale: Double,
            isAdventurous: Bool,
            agentOverrides: [String: CompanionAppearance]
        ) {
            self.schemaVersion = schemaVersion
            self.isEnabled = isEnabled
            self.defaultAppearance = defaultAppearance
            self.sizeScale = CompanionStore.sanitizedSizeScale(sizeScale)
            self.isAdventurous = isAdventurous
            self.agentOverrides = agentOverrides
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
            defaultAppearance = try container.decode(CompanionAppearance.self, forKey: .defaultAppearance)
            sizeScale = CompanionStore.sanitizedSizeScale(
                (try? container.decode(Double.self, forKey: .sizeScale))
                    ?? CompanionStore.defaultSizeScale
            )
            isAdventurous = (try? container.decode(Bool.self, forKey: .isAdventurous)) ?? false
            agentOverrides = try container.decode(
                [String: CompanionAppearance].self,
                forKey: .agentOverrides
            )
        }
    }

    private func persistIfReady() {
        guard isReadyToPersist else { return }
        let state = PersistedState(
            schemaVersion: Self.currentSchemaVersion,
            isEnabled: isEnabled,
            defaultAppearance: Self.sanitized(defaultAppearance),
            sizeScale: sizeScale,
            isAdventurous: isAdventurous,
            agentOverrides: agentOverrides
        )
        guard let data = try? JSONEncoder().encode(state),
              data.count <= Self.maximumPersistedBytes else {
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func readPersistedState(from defaults: UserDefaults, key: String) -> PersistedState? {
        guard let data = defaults.data(forKey: key),
              data.count <= maximumPersistedBytes,
              let decoded = try? JSONDecoder().decode(PersistedState.self, from: data),
              decoded.schemaVersion == currentSchemaVersion,
              decoded.agentOverrides.count <= maximumOverrides,
              decoded.agentOverrides.keys.allSatisfy(isValidKey) else {
            return nil
        }
        return PersistedState(
            schemaVersion: currentSchemaVersion,
            isEnabled: decoded.isEnabled,
            defaultAppearance: sanitized(decoded.defaultAppearance),
            sizeScale: sanitizedSizeScale(decoded.sizeScale),
            isAdventurous: decoded.isAdventurous,
            agentOverrides: decoded.agentOverrides.mapValues(sanitized)
        )
    }

    nonisolated static func sanitizedSizeScale(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSizeScale }
        return min(max(value, minimumSizeScale), maximumSizeScale)
    }

    private static func sanitized(_ appearance: CompanionAppearance) -> CompanionAppearance {
        CompanionAppearance(
            character: appearance.character,
            colorHex: appearance.colorHex,
            matchesTheme: appearance.matchesTheme,
            eyeStyle: appearance.eyeStyle,
            eyeColorHex: appearance.eyeColorHex,
            topper: appearance.topper,
            pattern: appearance.pattern,
            vibe: appearance.vibe,
            colorway: appearance.colorway,
            usesCharacterColors: appearance.usesCharacterColors,
            bitEyes: appearance.bitEyes,
            bitMouth: appearance.bitMouth,
            bitAccessory: appearance.bitAccessory,
            showsCheeks: appearance.showsCheeks,
            catalogAvatar: appearance.catalogAvatar
        )
    }

    private static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= maximumKeyUTF8Count
    }
}

/// sRGB helpers for avatar colors (six-digit hex).
enum CompanionColor {
    static func components(_ hex: String) -> (red: Double, green: Double, blue: Double) {
        let digits = (CompanionAppearance.validatedColorHex(hex) ?? CompanionAppearance.fallbackColorHex).utf8.dropFirst()
        let value = digits.reduce(UInt32(0)) { $0 << 4 | UInt32(ASCIIText.hexValue($1)) }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// WCAG relative luminance, 0 (black) to 1 (white).
    static func luminance(_ hex: String) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let color = components(hex)
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// Negative amounts mix toward black, positive toward white.
    static func shade(_ hex: String, by amount: Double) -> String {
        let color = components(hex)
        let target: Double = amount < 0 ? 0 : 1
        let weight = min(abs(amount), 1)
        return Self.hex(
            red: color.red + (target - color.red) * weight,
            green: color.green + (target - color.green) * weight,
            blue: color.blue + (target - color.blue) * weight
        )
    }
}

/// ASCII checks on raw bytes, for values that must read the same on every device.
enum ASCIIText {
    static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
    static func isLowercaseLetter(_ byte: UInt8) -> Bool { (0x61...0x7A).contains(byte) }
    static func isHexDigit(_ byte: UInt8) -> Bool { isDigit(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte) }
    static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || (0x09...0x0D).contains(byte) }
    static func uppercased(_ byte: UInt8) -> UInt8 { isLowercaseLetter(byte) ? byte - 0x20 : byte }

    /// 0–15 for a hex digit; 0 otherwise.
    static func hexValue(_ byte: UInt8) -> UInt8 {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: 0
        }
    }
}
