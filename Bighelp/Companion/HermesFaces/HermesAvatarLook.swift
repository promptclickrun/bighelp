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
/// and a third part pins one of the silhouettes.
struct HermesBlobShape: Equatable, Sendable {
    /// The locked seed; empty while the face follows the name.
    var seedPart: String
    var kind: HermesBlobFace.Kind?

    init(seedPart: String = "", kind: HermesBlobFace.Kind? = nil) {
        self.seedPart = seedPart
        self.kind = kind
    }

    init?(_ shape: String?) {
        guard let shape, shape == "blobatar" || shape.hasPrefix("blobatar:") else { return nil }
        let parts = shape.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        seedPart = parts.count > 1 ? parts[1] : ""
        kind = parts.count > 2 ? HermesBlobFace.Kind(rawValue: parts[2]) : nil
    }

    var string: String {
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
}
