import Foundation

/// How Hermes Desktop should draw an agent: the look Bot Mode keeps in the
/// profile's `ui_meta["hermes-bots"]` (`shape`, `color`, `imageKind`, `custom`).
/// Written next to the avatar picture so Desktop shows the same face.
struct AgentAvatarLook: Codable, Equatable, Sendable {
    enum Style: String, Codable, Sendable {
        /// A blob face (`blobatar…`).
        case face
        /// A geometric face in a color.
        case shape
        /// A picture: a photo, a pet or one of the app's characters.
        case photo
    }

    var style: Style
    /// Hermes's shape string: `blobatar[:seed[:kind]]` for faces, a shape name for shapes.
    var shape: String?
    /// A picked shape or face color (`hsl()` or hex); nil matches the name.
    var color: String?
    /// The name a face that follows the name was drawn from. If the agent's
    /// profile name turns out different, the face is locked to this one so
    /// Hermes Desktop still draws the picture that was saved.
    var faceSeed: String?

    static let photo = AgentAvatarLook(style: .photo)

    /// Reads a look Hermes Desktop (or this app) saved, so the studio opens on it.
    init?(namespace: [String: BighelpJSONValue]) {
        let shape = namespace["shape"]?.string.flatMap { $0.isEmpty || $0.utf8.count > 200 ? nil : $0 }
        let color = namespace["color"]?.string.flatMap { $0.utf8.count > 64 ? nil : $0 }
        if namespace["imageKind"]?.string == "photo" {
            self.init(style: .photo)
        } else if let shape, HermesBlobShape(shape) != nil {
            self.init(style: .face, shape: shape, color: color)
        } else if let shape, HermesShapeFace.pickerShapes.contains(shape) {
            self.init(style: .shape, shape: shape, color: color)
        } else {
            return nil
        }
    }

    init(style: Style, shape: String? = nil, color: String? = nil, faceSeed: String? = nil) {
        self.style = style
        self.shape = shape
        self.color = color
        self.faceSeed = faceSeed
    }

    /// The shape string to save for the profile named `profileID`.
    func savedShape(profileID: String) -> String? {
        guard style == .face, let shape, var blob = HermesBlobShape(shape) else { return shape }
        if blob.seedPart.isEmpty, let faceSeed, BlobTraits.normalized(faceSeed) != BlobTraits.normalized(profileID) {
            blob.seedPart = faceSeed
        }
        return blob.string
    }

    /// Bot Mode's namespace with this look written in; other keys are kept.
    func applied(to namespace: [String: BighelpJSONValue], profileID: String) -> [String: BighelpJSONValue] {
        var result = namespace
        result["custom"] = .boolean(true)
        result["imageKind"] = .string(style == .photo ? "photo" : "shape")
        switch style {
        case .photo:
            break
        case .face:
            if let shape = savedShape(profileID: profileID) { result["shape"] = .string(shape) }
        case .shape:
            if let shape { result["shape"] = .string(shape) }
            if let color { result["color"] = .string(color) } else { result.removeValue(forKey: "color") }
        }
        return result
    }
}

/// A blob face's shape string, as Hermes Desktop writes it:
/// `blobatar` follows the name, `blobatar:<seed>` is locked,
/// and a third part pins one of the silhouettes. bighelp adds a fourth for
/// hand edits (`HermesBlobEdits`), which Desktop skips: it reads two parts
/// after `blobatar` and rebuilds the string without the rest when it edits.
struct HermesBlobShape: Equatable, Sendable {
    /// The locked seed; empty while the face follows the name.
    var seedPart: String
    var kind: HermesBlobFace.Kind?
    /// Hand edits on top of the seed's body; nil draws the seed face as blobatar does.
    var edits: HermesBlobEdits?

    init(seedPart: String = "", kind: HermesBlobFace.Kind? = nil, edits: HermesBlobEdits? = nil) {
        self.seedPart = seedPart
        self.kind = kind
        self.edits = edits
    }

    init?(_ shape: String?) {
        guard let shape, shape == "blobatar" || shape.hasPrefix("blobatar:") else { return nil }
        let parts = shape.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        seedPart = parts.count > 1 ? parts[1] : ""
        kind = parts.count > 2 ? HermesBlobFace.Kind(rawValue: parts[2]) : nil
        // Edits that don't read leave the seed face, never a blank one.
        edits = parts.count > 3 ? HermesBlobEdits(parts[3]) : nil
    }

    var string: String {
        if let edits, !edits.isEmpty { return "blobatar:\(seedPart):\(kind?.rawValue ?? ""):\(edits.string)" }
        if let kind { return "blobatar:\(seedPart):\(kind.rawValue)" }
        return seedPart.isEmpty ? "blobatar" : "blobatar:\(seedPart)"
    }

    var isLocked: Bool { !seedPart.isEmpty }

    /// The seed actually drawn: the locked one, else the name.
    func seed(name: String) -> String {
        if !seedPart.isEmpty { return seedPart }
        return name.isEmpty ? "agent" : name
    }

    /// A fresh seed, like Desktop's `Math.random().toString(36).slice(2, 10)`.
    static func randomSeed() -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }

    // MARK: Hand edits

    /// How far one Taller, Wider or Smaller tap moves its trait.
    static let sizeStep = 0.25

    /// The trait's position (0…1) this face draws with: the edit, else the seed's.
    func position(_ key: String, seed: String) -> Double {
        if let value = edits?.traits[key] { return value }
        return BlobTraits(seed: seed, overrides: kind.map { ["shape": $0.trait] } ?? [:])(key)
    }

    mutating func taller(seed: String) { setRatio(position("body.ratio", seed: seed) + Self.sizeStep) }
    mutating func wider(seed: String) { setRatio(position("body.ratio", seed: seed) - Self.sizeStep) }
    mutating func smaller(seed: String) { setSize(position("body.r", seed: seed) - Self.sizeStep) }
    mutating func bigger(seed: String) { setSize(position("body.r", seed: seed) + Self.sizeStep) }

    func canGrowTaller(seed: String) -> Bool { position("body.ratio", seed: seed) < HermesBlobEdits.maximum }
    func canGrowWider(seed: String) -> Bool { position("body.ratio", seed: seed) > 0 }
    func canShrink(seed: String) -> Bool { position("body.r", seed: seed) > 0 }
    func canGrow(seed: String) -> Bool { position("body.r", seed: seed) < HermesBlobEdits.maximum }

    /// Outline points (6…8), as blobatar's `body.pts` picks them.
    func bumps(seed: String) -> Int {
        if let count = edits?.wobble?.count { return count }
        return Self.count(at: position("body.pts", seed: seed))
    }

    /// A new count keeps the wobble's strength, and the mirror when the count is even.
    mutating func setBumps(_ count: Int, seed: String) {
        let count = min(8, max(6, count))
        let strength = wobble(seed: seed)
        let mirrored = isMirrored(seed: seed)
        setPositions(Self.scaledSeedBumps(count: count, strength: strength, seed: seed))
        guard mirrored else { return }
        if count.isMultiple(of: 2) { setMirrored(true, seed: seed) } else { update { $0.mirrored = false } }
    }

    /// How much the outline wobbles: 0 smooth, 0.5 the seed's own, 1 twice that.
    /// Read from the points that stayed inside blobatar's range; a point at an end
    /// was cut short there, so it says less than the strength that put it there.
    func wobble(seed: String) -> Double {
        let positions = bumpPositions(seed: seed)
        let scales = positions.indices.compactMap { index -> Double? in
            let own = Self.seedBump(index, seed: seed) - 0.5
            let value = positions[index]
            guard abs(own) > 0.02, value > 0, value < HermesBlobEdits.maximum else { return nil }
            return (value - 0.5) / own
        }.sorted()
        guard !scales.isEmpty else {
            // Every point flat, or every point cut short.
            return positions.allSatisfy { abs($0 - 0.5) < 0.006 } ? 0 : 1
        }
        return min(1, max(0, scales[scales.count / 2] / 2))
    }

    mutating func setWobble(_ strength: Double, seed: String) {
        let mirrored = isMirrored(seed: seed)
        setPositions(Self.scaledSeedBumps(count: bumps(seed: seed), strength: strength, seed: seed))
        if mirrored { setMirrored(true, seed: seed) }
    }

    /// Whether the outline matches left and right. Kept as its own flag: a smooth
    /// outline matches too, and it mustn't turn the mirror on by itself.
    func isMirrored(seed: String) -> Bool { edits?.mirrored == true }

    /// Mirroring copies the right side onto the left; an odd count takes the next even one.
    /// Turning it off gives the left side the seed's own bumps again, at the same strength.
    mutating func setMirrored(_ isOn: Bool, seed: String) {
        var count = bumps(seed: seed)
        guard isOn else {
            setPositions(Self.scaledSeedBumps(count: count, strength: wobble(seed: seed), seed: seed))
            update { $0.mirrored = false }
            return
        }
        var positions = bumpPositions(seed: seed)
        if !count.isMultiple(of: 2) {
            count += 1
            positions = Self.scaledSeedBumps(count: count, strength: wobble(seed: seed), seed: seed)
        }
        for index in 0..<count where Self.isRightSide(index, count: count) {
            positions[Self.mirror(index, count: count)] = positions[index]
        }
        setPositions(positions)
        update { $0.mirrored = true }
    }

    private func bumpPositions(seed: String) -> [Double] {
        if let wobble = edits?.wobble { return wobble }
        return (0..<bumps(seed: seed)).map { Self.seedBump($0, seed: seed) }
    }

    private mutating func setRatio(_ value: Double) { update { $0.ratio = HermesBlobEdits.clamped(value) } }
    private mutating func setSize(_ value: Double) { update { $0.size = HermesBlobEdits.clamped(value) } }

    private mutating func update(_ change: (inout HermesBlobEdits) -> Void) {
        var next = edits ?? HermesBlobEdits()
        change(&next)
        edits = next.isEmpty ? nil : next
    }

    private mutating func setPositions(_ positions: [Double]) {
        update { edits in
            edits.bumps = positions.count
            edits.wobble = positions.map(HermesBlobEdits.clamped)
        }
    }

    private static func seedBump(_ index: Int, seed: String) -> Double { BlobTraits(seed: seed)("body.r\(index)") }
    private static func scaledSeedBumps(count: Int, strength: Double, seed: String) -> [Double] {
        let scale = max(0, min(1, strength)) * 2
        return (0..<count).map { 0.5 + (seedBump($0, seed: seed) - 0.5) * scale }
    }
    private static func count(at position: Double) -> Int { 6 + min(2, Int((position * 3).rounded(.down))) }
    /// Point `i` sits at `2πi/count` from the right, so its mirror across the middle is `count/2 - i`.
    private static func mirror(_ index: Int, count: Int) -> Int { ((count / 2 - index) % count + count) % count }
    private static func isRightSide(_ index: Int, count: Int) -> Bool { cos(2 * Double.pi * Double(index) / Double(count)) > -1e-9 }
}

/// Hand edits on a blob face, as blobatar trait positions (0…1, two places), so
/// any blobatar renderer can draw them with `traits`. Written as the shape
/// string's fourth part: `e1,h75,s25,n8,w50.62.38…,m` (version, `body.ratio`,
/// `body.r`, `body.pts`, then `body.r0`, `body.r1`…, and `m` when the outline is
/// mirrored, which is only for the editor: the points already match). It never holds a `:`.
struct HermesBlobEdits: Equatable, Sendable {
    /// `body.ratio`: higher is taller, lower is wider.
    var ratio: Double?
    /// `body.r`: lower is smaller.
    var size: Double?
    /// `body.pts`: outline points, 6…8.
    var bumps: Int?
    /// `body.r<i>`: how far each point reaches; 0.5 is none.
    var wobble: [Double]?
    /// The editor keeps the left side a copy of the right.
    var mirrored = false

    static let maximum = 0.99

    init(ratio: Double? = nil, size: Double? = nil, bumps: Int? = nil, wobble: [Double]? = nil, mirrored: Bool = false) {
        self.ratio = ratio
        self.size = size
        self.bumps = bumps
        self.wobble = wobble
        self.mirrored = mirrored
    }

    /// Reads the fourth part; nil for anything it can't read in full, so the seed face shows.
    init?(_ text: String) {
        guard text.utf8.count <= 120 else { return nil }
        let tokens = text.split(separator: ",").map(String.init)
        guard tokens.first == "e1" else { return nil }
        for token in tokens.dropFirst() {
            if token == "m" { mirrored = true; continue }
            guard let key = token.first else { return nil }
            let value = String(token.dropFirst())
            switch key {
            case "h": guard let number = Self.percent(value) else { return nil }; ratio = number
            case "s": guard let number = Self.percent(value) else { return nil }; size = number
            case "n": guard let count = Int(value), (6...8).contains(count) else { return nil }; bumps = count
            case "w":
                let numbers = value.split(separator: ".", omittingEmptySubsequences: false).map { Self.percent(String($0)) }
                guard (6...8).contains(numbers.count), numbers.allSatisfy({ $0 != nil }) else { return nil }
                wobble = numbers.compactMap { $0 }
            default:
                // A later version's key: skip it rather than lose the rest.
                continue
            }
        }
        if let wobble, let bumps, wobble.count != bumps { return nil }
        if let wobble, bumps == nil { bumps = wobble.count }
    }

    var isEmpty: Bool { ratio == nil && size == nil && bumps == nil && wobble == nil && !mirrored }

    var string: String {
        var tokens = ["e1"]
        if let ratio { tokens.append("h\(Self.digits(ratio))") }
        if let size { tokens.append("s\(Self.digits(size))") }
        if let bumps { tokens.append("n\(bumps)") }
        if let wobble { tokens.append("w" + wobble.map(Self.digits).joined(separator: ".")) }
        if mirrored { tokens.append("m") }
        return tokens.joined(separator: ",")
    }

    /// The blobatar trait overrides these edits draw with.
    var traits: [String: Double] {
        var result: [String: Double] = [:]
        if let ratio { result["body.ratio"] = ratio }
        if let size { result["body.r"] = size }
        if let bumps { result["body.pts"] = (Double(bumps - 6) + 0.5) / 3 }
        for (index, value) in (wobble ?? []).enumerated() { result["body.r\(index)"] = value }
        return result
    }

    static func clamped(_ value: Double) -> Double { (min(maximum, max(0, value)) * 100).rounded() / 100 }

    private static func percent(_ text: String) -> Double? {
        guard (1...2).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(text) else { return nil }
        return Double(number) / 100
    }

    private static func digits(_ value: Double) -> String { String(Int((clamped(value) * 100).rounded())) }
}
