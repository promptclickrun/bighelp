import Foundation

enum BighelpCardImportance: Int, Codable, Comparable, Sendable {
    case normal
    case important
    case urgent

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct BighelpCardDocument: Codable, Equatable, Sendable, Identifiable {
    let document: [String: BighelpJSONValue]
    /// For a card holding a photo draft: whether its content still has the hash the plugin made it
    /// with. Worked out here, once per decoded card. Other cards don't need it.
    let isDraftContentIntact: Bool

    init(document: [String: BighelpJSONValue]) throws {
        guard document["schema"]?.string == "loopdy.card",
              document["version"]?.integer == 1,
              document["title"]?.string != nil,
              document["spoken_summary"]?.string != nil,
              document["root"]?.string != nil,
              document["elements"]?.object != nil,
              document["data_sources"]?.array != nil,
              let hash = document["content_hash"]?.string, hash.count == 64,
              let cardID = document["card_id"]?.string, cardID.count == 32,
              document["origin"]?.string == "live",
              document["created_at"]?.string != nil else { throw BighelpCardDocumentError.invalid }
        self.document = document
        isDraftContentIntact = ImageDraftCard.holdsDraft(document) ? ImageDraftCardHash.isIntact(document: document) : true
    }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode([String: BighelpJSONValue].self)
        try self.init(document: value)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(document)
    }

    var id: String { document["card_id"]?.string ?? "" }
    var title: String { document["title"]?.string ?? "" }
    var spokenSummary: String { document["spoken_summary"]?.string ?? "" }
    var importance: BighelpCardImportance {
        switch document["importance"]?.string {
        case "important": .important
        case "urgent": .urgent
        default: .normal
        }
    }
    var validUntil: Date? {
        guard let value = document["valid_until"]?.string else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
    var root: String { document["root"]?.string ?? "" }
    var elements: [String: BighelpJSONValue] { document["elements"]?.object ?? [:] }
    var dataSources: [BighelpJSONValue] { document["data_sources"]?.array ?? [] }
}

enum BighelpCardDocumentError: Error, Equatable { case invalid }
