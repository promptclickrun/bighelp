import CryptoKit
import Foundation

/// Whether a draft card is the card the plugin made. The plugin hashes the card before it adds
/// `content_hash`, `card_id`, `created_at` and `origin` (docs/BIGHELP_CARDS.md), so the app works
/// the hash out again: an agent that pastes an edited copy with the old hash is caught here, and
/// one that makes a new hash is caught by the host's `cardHash` when Save claims the draft.
enum ImageDraftCardHash {
    static let rendererKeys: Set<String> = ["content_hash", "card_id", "created_at", "origin"]

    /// Worked out when the card is decoded (`BighelpCardDocument.isDraftContentIntact`), which a chat
    /// does once per message, never per redraw.
    static func isIntact(_ card: BighelpCardDocument) -> Bool { card.isDraftContentIntact }

    static func isIntact(document: [String: BighelpJSONValue]) -> Bool {
        guard let claimed = document["content_hash"]?.string?.lowercased(),
              document["card_id"]?.string?.lowercased() == String(claimed.prefix(32)) else { return false }
        return contentHash(of: document) == claimed
    }

    /// SHA-256 (hex) of the card without the renderer's own keys, in the plugin's canonical form.
    static func contentHash(of document: [String: BighelpJSONValue]) -> String? {
        let input = document.filter { !rendererKeys.contains($0.key) }
        guard let text = canonical(.object(input)) else { return nil }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Python's `json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"),
    /// sort_keys=True)`, the plugin's `canonical_json`: keys in code point order, no spaces,
    /// UTF-8 as is, and only quotes, backslashes and control characters escaped.
    static func canonical(_ value: BighelpJSONValue) -> String? {
        var output = ""
        guard write(value, into: &output) else { return nil }
        return output
    }

    private static func write(_ value: BighelpJSONValue, into output: inout String) -> Bool {
        switch value {
        case .null: output += "null"
        case .boolean(let flag): output += flag ? "true" : "false"
        case .integer(let number): output += String(number)
        case .number(let number):
            guard number.isFinite else { return false }
            // Python writes floats with repr: 2.0, 0.1, 1e-05, 1e+16, as Swift's description does.
            output += "\(number)"
        case .string(let text): escape(text, into: &output)
        case .array(let items):
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += "," }
                guard write(item, into: &output) else { return false }
            }
            output += "]"
        case .object(let object):
            output += "{"
            let keys = object.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) { $0.value < $1.value } }
            for (index, key) in keys.enumerated() {
                if index > 0 { output += "," }
                escape(key, into: &output)
                output += ":"
                guard let item = object[key], write(item, into: &output) else { return false }
            }
            output += "}"
        }
        return true
    }

    private static func escape(_ text: String, into output: inout String) {
        output += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}
