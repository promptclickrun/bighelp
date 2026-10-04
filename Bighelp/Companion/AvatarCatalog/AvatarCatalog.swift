import CryptoKit
import Foundation

/// bighelp's avatar catalog (`services/avatars`): characters drawn natively from AvatarKit JSON,
/// published without an app update. Public, read-only, approved art only.
enum AvatarCatalogPolicy {
    static let host = "avatars.bighelp.app"
    static let discoveryURL = URL(string: "https://avatars.bighelp.app/v1/avatars.json")!
    static let maximumBytes = 2_097_152
    /// The service says five minutes; never trust a longer one.
    static let maximumAge: TimeInterval = 300

    static func isAllowed(_ url: URL?) -> Bool {
        url?.scheme == "https" && url?.host == host && url?.user == nil && url?.password == nil
            && url?.port == nil
    }
}

/// One active (or once-active) catalog character. Saved with a selection, so an expired one
/// still draws.
struct AvatarCatalogEntry: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let role: String?
    let setID: String
    let category: String
    let startsAt: Date?
    let expiresAt: Date?
    /// The immutable single-character pack and its checks.
    let kitURL: URL
    let kitSHA256: String
    let kitBytes: Int

    func isActive(at date: Date) -> Bool {
        (startsAt.map { $0 <= date } ?? true) && (expiresAt.map { date < $0 } ?? true)
    }
}

struct AvatarCatalogSet: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let category: String
    let startsAt: Date?
    let expiresAt: Date?

    func isActive(at date: Date) -> Bool {
        (startsAt.map { $0 <= date } ?? true) && (expiresAt.map { date < $0 } ?? true)
    }
}

/// The discovery file, read leniently: an entry that doesn't read is dropped, never the file.
struct AvatarCatalog: Codable, Equatable, Sendable {
    var sets: [AvatarCatalogSet] = []
    var avatars: [AvatarCatalogEntry] = []

    static let empty = AvatarCatalog()

    /// The catalog as it was when this build shipped.
    static let bundled: AvatarCatalog = {
        guard let url = Bundle.main.url(forResource: "AvatarCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return .empty }
        return AvatarCatalog(discovery: data) ?? .empty
    }()

    /// The categories bighelp files the catalog's sets under.
    enum Group: String, CaseIterable, Sendable {
        /// bighelp's own art, seasonal sets included.
        case bighelp
        /// Hermes Desktop's faces and shapes, drawn by the app itself.
        case hermes
        /// Community art the maintainer approved.
        case other

        static func of(category: String) -> Group {
            switch category {
            case "bighelp", "seasonal": .bighelp
            case "faces", "shapes": .hermes
            default: .other
            }
        }
    }

    /// Active sets in a group that have at least one active character, in the catalog's order.
    func sets(in group: Group, at date: Date) -> [AvatarCatalogSet] {
        sets.filter { set in
            Group.of(category: set.category) == group && set.isActive(at: date)
                && avatars.contains { $0.setID == set.id && $0.isActive(at: date) }
        }
    }

    /// Every active character in a group, set by set.
    func avatars(in group: Group, at date: Date) -> [AvatarCatalogEntry] {
        sets(in: group, at: date).flatMap { avatars(in: $0, at: date) }
    }

    func avatars(in set: AvatarCatalogSet, at date: Date) -> [AvatarCatalogEntry] {
        avatars.filter { $0.setID == set.id && $0.isActive(at: date) && set.isActive(at: date) }
    }

    /// The next start or expiry after `date`, so an open picker can change on time, offline too.
    func nextChange(after date: Date) -> Date? {
        let boundaries = sets.flatMap { [$0.startsAt, $0.expiresAt] } + avatars.flatMap { [$0.startsAt, $0.expiresAt] }
        return boundaries.compactMap { $0 }.filter { $0 > date }.min()
    }

    init(sets: [AvatarCatalogSet] = [], avatars: [AvatarCatalogEntry] = []) {
        self.sets = sets
        self.avatars = avatars
    }

    /// Reads `/v1/avatars.json`. nil only when the file itself isn't a catalog.
    init?(discovery data: Data) {
        guard data.count <= AvatarCatalogPolicy.maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["schemaVersion"] as? Int) == 1,
              let setRows = object["sets"] as? [Any], let avatarRows = object["avatars"] as? [Any] else { return nil }
        var seen = Set<String>()
        sets = setRows.prefix(64).compactMap { row in
            guard let row = row as? [String: Any], let id = Self.identifier(row["id"]), seen.insert(id).inserted,
                  let name = Self.text(row["name"], limit: 40), let category = Self.identifier(row["category"]) else { return nil }
            return AvatarCatalogSet(id: id, name: name, category: category,
                                    startsAt: Self.date(row["startsAt"]), expiresAt: Self.date(row["expiresAt"]))
        }
        seen = []
        avatars = avatarRows.prefix(512).compactMap { row in
            guard let row = row as? [String: Any], let id = Self.identifier(row["id"]), seen.insert(id).inserted,
                  let name = Self.text(row["name"], limit: 40), let setID = Self.identifier(row["setId"]),
                  let category = Self.identifier(row["category"]),
                  let kit = row["kit"] as? [String: Any], let urlString = kit["url"] as? String,
                  let url = URL(string: urlString), AvatarCatalogPolicy.isAllowed(url),
                  let sha = kit["sha256"] as? String, Self.isSHA256(sha),
                  let bytes = kit["bytes"] as? Int, bytes > 0, bytes <= AvatarCatalogPolicy.maximumBytes
            else { return nil }
            return AvatarCatalogEntry(id: id, name: name, role: Self.text(row["role"], limit: 80), setID: setID,
                                      category: category, startsAt: Self.date(row["startsAt"]),
                                      expiresAt: Self.date(row["expiresAt"]), kitURL: url,
                                      kitSHA256: sha.lowercased(), kitBytes: bytes)
        }
        let setIDs = Set(sets.map(\.id))
        avatars.removeAll { !setIDs.contains($0.setID) }
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 64,
              value.unicodeScalars.allSatisfy({ CharacterSet.lowercaseLetters.union(.decimalDigits)
                  .union(CharacterSet(charactersIn: "-_")).contains($0) }) else { return nil }
        return value
    }

    private static func text(_ value: Any?, limit: Int) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limit else { return nil }
        return trimmed
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
    }

    /// Timestamps carry their offset; date-only or offset-free ones aren't accepted.
    static func date(_ value: Any?) -> Date? {
        guard let value = value as? String, value.utf8.count <= 40 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

/// A catalog character someone picked: enough to draw it forever, even after it leaves the catalog.
struct AvatarCatalogReference: Codable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    /// The immutable pack's hash: its file name on the phone and its address's last part.
    let kitSHA256: String
    let kitURL: URL

    init(_ entry: AvatarCatalogEntry) {
        id = entry.id
        name = entry.name
        kitSHA256 = entry.kitSHA256
        kitURL = entry.kitURL
    }

    init(id: String, name: String, kitSHA256: String, kitURL: URL) {
        self.id = id
        self.name = name
        self.kitSHA256 = kitSHA256
        self.kitURL = kitURL
    }

    private enum CodingKeys: String, CodingKey { case id, name, sha256, url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        let sha = try c.decode(String.self, forKey: .sha256)
        let url = try c.decode(URL.self, forKey: .url)
        guard id.utf8.count <= 64, name.count <= 40, AvatarCatalog.isSHA256(sha), AvatarCatalogPolicy.isAllowed(url) else {
            throw DecodingError.dataCorruptedError(forKey: .sha256, in: c, debugDescription: "Not a catalog avatar.")
        }
        kitSHA256 = sha.lowercased()
        kitURL = url
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kitSHA256, forKey: .sha256)
        try c.encode(kitURL, forKey: .url)
    }
}

// MARK: - Checking packs

/// The kit decoder was written for the bundled file; anything from the network is checked first.
enum AvatarKitPackValidator {
    static let maximumNesting = 48
    static let maximumNodes = 4_000
    static let maximumPathLength = 20_000
    static let maximumText = 16
    static let allowedKinds: Set<String> = ["g", "svg", "path", "circle", "ellipse", "rect", "text"]

    /// Decodes a pack whose bytes and hash were already checked, then checks what it holds.
    static func decode(_ data: Data) -> AvatarKit? {
        guard data.count <= AvatarCatalogPolicy.maximumBytes, nesting(of: data) <= maximumNesting,
              let kit = try? JSONDecoder().decode(AvatarKit.self, from: data),
              !kit.characters.isEmpty, kit.characters.count <= 64 else { return nil }
        var count = 0
        for character in kit.characters {
            guard character.look.isFinite, abs(character.look) <= 100, isValid(character.tree, count: &count) else { return nil }
        }
        for stops in kit.keyframes.values {
            for stop in stops {
                guard stop.t.isFinite, (stop.o ?? 0).isFinite, isFinite(stop.tf), (stop.tl ?? []).allSatisfy(\.isFinite) else { return nil }
            }
        }
        return kit
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Bracket depth outside strings, before any recursive decoding.
    static func nesting(of data: Data) -> Int {
        var depth = 0, deepest = 0, inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x7B, 0x5B: depth += 1; deepest = max(deepest, depth)
            case 0x7D, 0x5D: depth -= 1
            default: break
            }
        }
        return deepest
    }

    private static func isValid(_ node: AvatarKit.Node, count: inout Int) -> Bool {
        count += 1
        guard count <= maximumNodes, allowedKinds.contains(node.kind), (node.text?.count ?? 0) <= maximumText else { return false }
        if let matrix = node.matrix {
            guard [matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty].allSatisfy(\.isFinite) else { return false }
        }
        if let path = node.path {
            let box = path.boundingRect
            guard path.isEmpty || [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite) else { return false }
        }
        for style in node.styles.values {
            let numbers = [style.o, style.fo, style.so, style.sw, style.fs].compactMap { $0 } + (style.tl ?? []) + (style.org ?? [])
            guard numbers.allSatisfy(\.isFinite), isFinite(style.tf), abs(style.sw ?? 0) <= 200, (style.fs ?? 12) <= 200 else { return false }
        }
        return node.children.allSatisfy { isValid($0, count: &count) }
    }

    private static func isFinite(_ transform: AvatarKit.Transform?) -> Bool {
        guard let transform else { return true }
        return [transform.tx, transform.ty, transform.r, transform.sx, transform.sy].compactMap { $0 }.allSatisfy(\.isFinite)
    }
}
