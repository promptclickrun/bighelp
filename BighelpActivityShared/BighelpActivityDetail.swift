import CryptoKit
import Foundation
import Security

/// What a chat's row on the Live Activity shows beyond its phase: the step in progress, the last
/// steps, a question that waits, the reply's first lines (sealed-card-v1).
///
/// The computer encrypts it for a key only this phone has, so the notification service and Apple
/// carry bytes they can't read. The format mirrors the bighelp plugin's `card_detail.py`;
/// `BighelpTests/Fixtures/sealed-card-v1-vector.json` is shared by both. Every field is optional:
/// a row that doesn't open, or has none, draws its plain status.
struct BighelpActivityDetail: Equatable, Sendable {
    struct Step: Equatable, Sendable {
        var tool: String
        var count: Int
        var note: String?
    }

    /// When the turn started (Unix seconds), for the card's own timer.
    var started: Int?
    var steps = 0
    /// The tool in progress, as Hermes names it. The phone words it (`BighelpActivityStepWords`).
    var tool: String?
    var note: String?
    /// Finished steps, newest first.
    var trail: [Step] = []
    var say: String?
    var question: String?
    var preview: String?
    var helperGoals: [String] = []
    var contextUsed: Int?
    var contextWindow: Int?
    var model: String?

    private struct Wire: Decodable {
        struct Step: Decodable { var t: String?; var c: Int?; var n: String? }
        var b: Int?; var s: Int?; var t: String?; var n: String?; var tr: [Step]?
        var say: String?; var q: String?; var p: String?; var h: [String]?
        var cu: Int?; var cm: Int?; var m: String?
    }

    /// One bounded line. The computer bounds these too; the card never trusts a length.
    private static func line(_ value: String?, _ limit: Int) -> String? {
        guard let value else { return nil }
        let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(limit))
    }

    init(json: Data) throws {
        let wire = try JSONDecoder().decode(Wire.self, from: json)
        started = wire.b.flatMap { $0 > 0 ? $0 : nil }
        steps = min(max(wire.s ?? 0, 0), 9_999)
        tool = Self.line(wire.t, 48)
        note = Self.line(wire.n, 100)
        trail = (wire.tr ?? []).prefix(3).compactMap { step in
            Self.line(step.t, 48).map { Step(tool: $0, count: min(max(step.c ?? 1, 1), 999), note: Self.line(step.n, 100)) }
        }
        say = Self.line(wire.say, 160)
        question = Self.line(wire.q, 200)
        preview = Self.line(wire.p, 280)
        helperGoals = (wire.h ?? []).prefix(2).compactMap { Self.line($0, 60) }
        contextUsed = wire.cu.flatMap { $0 > 0 ? $0 : nil }
        contextWindow = wire.cm.flatMap { $0 > 0 ? $0 : nil }
        model = Self.line(wire.m, 48)
    }

    init() {}

    /// Opens a row's `sealed` bytes: nonce, ciphertext and tag in unpadded base64url, bound to the
    /// row's own timestamp. Nil for anything that isn't this row's detail at this time.
    static func open(_ sealed: String, timestamp: Int, key: SymmetricKey) -> BighelpActivityDetail? {
        guard sealed.utf8.count <= 1_200, let combined = decode(sealed), combined.count > 28,
              let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: key, authenticating: Data("bighelp-card-v1|\(timestamp)".utf8))
        else { return nil }
        return try? BighelpActivityDetail(json: plain)
    }

    static func decode(_ value: String) -> Data? {
        guard value.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 })
        else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    static func encode(_ value: Data) -> String {
        value.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// The phone's key for card detail. One random secret sits in a keychain group the app and the
/// Live Activity extension share; each chat row gets its own key derived from it, and only that
/// row key goes to the computer, over the app's own connection to it.
enum BighelpActivityCardKey {
    private static let service = "app.loopdy.mobile.card-key"
    private static let account = "master-v1"
    /// Found once per process. Never kept while missing: the app may make it after the extension started.
    private static let cache = Cache()
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: SymmetricKey?
        func get(_ load: () -> SymmetricKey?) -> SymmetricKey? {
            lock.lock(); defer { lock.unlock() }
            if value == nil { value = load() }
            return value
        }
    }

    private static var group: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BighelpCardKeychainGroup") as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    private static func query() -> [String: Any]? {
        guard let group else { return nil }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecAttrAccessGroup as String: group]
    }

    /// The secret, made on first use by the app (`create`). The extension only reads it.
    static func master(create: Bool = false) -> SymmetricKey? {
        cache.get {
            guard var read = query() else { return nil }
            read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(read as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
            guard create, status == errSecItemNotFound, var add = query() else { return nil }
            let fresh = SymmetricKey(size: .bits256)
            add[kSecValueData as String] = fresh.withUnsafeBytes { Data($0) }
            // The card is drawn while the phone is locked, so the key must be readable then.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? fresh : nil
        }
    }

    /// A row's own key, so one chat's detail never opens as another's.
    static func rowKey(_ rowID: String, master: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data("bighelp-card-v1".utf8),
                               info: Data(rowID.utf8), outputByteCount: 32)
    }

    /// The row key as the computer takes it, or nil when this device keeps no card key.
    static func wireKey(rowID: String) -> String? {
        master(create: true).map { master in
            BighelpActivityDetail.encode(rowKey(rowID, master: master).withUnsafeBytes { Data($0) })
        }
    }
}

/// How much of the detail the card shows (Settings › Notifications). The computer seals the same
/// detail whatever the choice; this only decides what is drawn where others can see the phone.
enum BighelpActivityDetailLevel: String, CaseIterable, Sendable {
    case statusOnly, steps, stepsAndText

    static let key = "bighelp.activity.detail-level"
    static let nerdKey = "bighelp.activity.nerd-line"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: BighelpWidgetSnapshot.appGroup) }

    static var current: BighelpActivityDetailLevel {
        get { defaults?.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .stepsAndText }
        set { defaults?.set(newValue.rawValue, forKey: key) }
    }
    /// Context use and the model's name on the card, for people with Nerd Mode on.
    static var showsNerdLine: Bool {
        get { defaults?.bool(forKey: nerdKey) ?? false }
        set { defaults?.set(newValue, forKey: nerdKey) }
    }

    var title: String {
        switch self {
        case .statusOnly: "Status only"
        case .steps: "Steps"
        case .stepsAndText: "Steps and text"
        }
    }
}

extension BighelpActivitySession {
    /// This row's detail, when it carries one that opens with this phone's key.
    func openDetail() -> BighelpActivityDetail? {
        guard let sealed, let master = BighelpActivityCardKey.master() else { return nil }
        return BighelpActivityDetail.open(sealed, timestamp: timestamp, key: BighelpActivityCardKey.rowKey(id, master: master))
    }
}

/// Plain words for a step, from the tool's name as Hermes sends it.
enum BighelpActivityStepWords {
    private static func has(_ name: String, _ markers: String...) -> Bool { markers.contains { name.contains($0) } }

    /// The step in progress: "Running code".
    static func now(_ tool: String) -> String {
        let name = tool.lowercased()
        if has(name, "clarify") { return "Asking you" }
        if has(name, "execute_code") { return "Running code" }
        if has(name, "terminal", "process") { return "Running a command" }
        if has(name, "patch") { return "Editing a file" }
        if has(name, "web_search", "search_web") { return "Searching the web" }
        if has(name, "web_extract", "fetch") { return "Reading a page" }
        if has(name, "browser") { return "Browsing the web" }
        if has(name, "session_search") { return "Searching past chats" }
        if has(name, "search_files") { return "Searching files" }
        if has(name, "read_file") { return "Reading a file" }
        if has(name, "write_file") { return "Writing a file" }
        if has(name, "vision") { return "Looking at a picture" }
        if has(name, "image", "video") { return "Making a picture" }
        if has(name, "text_to_speech", "tts") { return "Making speech" }
        if has(name, "skill") { return "Reading a skill" }
        if has(name, "memory") { return "Remembering" }
        if has(name, "todo") { return "Planning" }
        if has(name, "cron", "schedule") { return "Scheduling" }
        if has(name, "delegate", "subagent") { return "Starting helpers" }
        if has(name, "message") { return "Sending a message" }
        if has(name, "bighelp_board") { return "Posting an update" }
        return "Using a tool"
    }

    /// A finished step, with how many times in a row: "Read 6 pages".
    static func done(_ tool: String, count: Int) -> String {
        let name = tool.lowercased(), many = count > 1
        if has(name, "clarify") { return "Asked you" }
        if has(name, "execute_code") { return many ? "Ran code \(count) times" : "Ran code" }
        if has(name, "terminal", "process") { return many ? "Ran \(count) commands" : "Ran a command" }
        if has(name, "patch") { return many ? "Made \(count) edits" : "Edited a file" }
        if has(name, "web_search", "search_web") { return many ? "Searched the web \(count) times" : "Searched the web" }
        if has(name, "web_extract", "fetch") { return many ? "Read \(count) pages" : "Read a page" }
        if has(name, "browser") { return "Browsed the web" }
        if has(name, "session_search") { return "Searched past chats" }
        if has(name, "search_files") { return "Searched files" }
        if has(name, "read_file") { return many ? "Read \(count) files" : "Read a file" }
        if has(name, "write_file") { return many ? "Wrote \(count) files" : "Wrote a file" }
        if has(name, "vision") { return many ? "Looked at \(count) pictures" : "Looked at a picture" }
        if has(name, "image", "video") { return many ? "Made \(count) pictures" : "Made a picture" }
        if has(name, "text_to_speech", "tts") { return "Made speech" }
        if has(name, "skill") { return many ? "Read \(count) skills" : "Read a skill" }
        if has(name, "memory") { return "Checked memory" }
        if has(name, "todo") { return "Updated the plan" }
        if has(name, "cron", "schedule") { return "Scheduled a task" }
        if has(name, "delegate", "subagent") { return "Started helpers" }
        if has(name, "message") { return many ? "Sent \(count) messages" : "Sent a message" }
        if has(name, "bighelp_board") { return "Posted an update" }
        return many ? "Used \(count) tools" : "Used a tool"
    }

    /// "2:21" or "1:02:05".
    static func duration(_ seconds: Int) -> String {
        let total = max(0, seconds), hours = total / 3_600, minutes = total % 3_600 / 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// "30k" for 30,300.
    static func tokens(_ count: Int) -> String {
        count >= 1_000_000 ? String(format: "%.1fM", Double(count) / 1_000_000)
            : count >= 1_000 ? "\(count / 1_000)k" : "\(count)"
    }
}
