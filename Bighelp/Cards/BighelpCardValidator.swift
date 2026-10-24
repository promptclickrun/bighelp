import Foundation

enum BighelpCardValidationError: Error, Equatable {
    case invalid
    case limitExceeded
    case unknownElement
    case unknownSource(String)
    case liveDataUnavailable
}

enum BighelpCardValidator {
    static let supportedElementTypes: Set<String> = [
        "card", "vstack", "hstack", "grid", "text", "metric", "badge",
        "progress", "chart", "table", "list", "divider", "spacer", "image",
        "contact", "place", "music", "contact_draft", "event_draft",
    ]
    private static let supportedOperations: Set<String> = [
        "coalesce", "add", "subtract", "multiply", "divide", "percent_change",
        "equal", "not_equal", "greater_than", "greater_than_or_equal",
        "less_than", "less_than_or_equal", "and", "or", "not",
    ]
    private static let maximumElements = 80
    private static let maximumDepth = 12
    private static let maximumChildren = 20
    private static let maximumDocumentNodes = 10_000
    private static let maximumStringLength = 10_000

    static func validateForStaticRelease(_ card: BighelpCardDocument) throws -> BighelpCardDocument {
        guard card.dataSources.isEmpty else {
            throw BighelpCardValidationError.liveDataUnavailable
        }
        return try validate(card)
    }

    static func validate(_ card: BighelpCardDocument) throws -> BighelpCardDocument {
        var nodeCount = 0
        try validateJSON(.object(card.document), depth: 0, nodeCount: &nodeCount)

        guard !card.elements.isEmpty, card.elements.count <= maximumElements,
              card.elements[card.root] != nil else {
            throw BighelpCardValidationError.limitExceeded
        }
        guard let createdAtText = card.document["created_at"]?.string,
              let createdAt = ISO8601DateFormatter().date(from: createdAtText) else {
            throw BighelpCardValidationError.invalid
        }
        if let importance = card.document["importance"]?.string,
           !["normal", "important", "urgent"].contains(importance) {
            throw BighelpCardValidationError.invalid
        }
        if let validUntilText = card.document["valid_until"]?.string {
            guard let validUntil = ISO8601DateFormatter().date(from: validUntilText),
                  validUntil > createdAt,
                  validUntil <= createdAt.addingTimeInterval(30 * 86_400) else {
                throw BighelpCardValidationError.invalid
            }
        }

        let sourceIDs = try validateSources(card.dataSources, createdAt: createdAt)
        var active = Set<String>()
        var visited = Set<String>()
        var parentCounts: [String: Int] = [:]

        func walk(_ id: String, depth: Int) throws {
            guard depth <= maximumDepth else { throw BighelpCardValidationError.limitExceeded }
            guard !active.contains(id) else { throw BighelpCardValidationError.invalid }
            guard let element = card.elements[id]?.object,
                  let type = element["type"]?.string,
                  supportedElementTypes.contains(type),
                  case .object(let props)? = element["props"],
                  case .array(let rawChildren)? = element["children"] else {
                throw BighelpCardValidationError.unknownElement
            }
            guard rawChildren.count <= maximumChildren else { throw BighelpCardValidationError.limitExceeded }
            if BighelpCardObjects.types.contains(type) {
                // Plain values only: a music object's `source` is a word, not a data source.
                guard rawChildren.isEmpty else { throw BighelpCardValidationError.invalid }
                try BighelpCardObjects.validate(type: type, props: props)
            } else {
                try validateElement(type: type, props: props, children: rawChildren)
                try validateBindings(.object(props), sourceIDs: sourceIDs, depth: 0)
            }

            active.insert(id)
            visited.insert(id)
            var localChildren = Set<String>()
            for rawChild in rawChildren {
                guard let childID = rawChild.string,
                      localChildren.insert(childID).inserted,
                      card.elements[childID] != nil else {
                    throw BighelpCardValidationError.invalid
                }
                parentCounts[childID, default: 0] += 1
                guard parentCounts[childID] == 1 else { throw BighelpCardValidationError.invalid }
                try walk(childID, depth: depth + 1)
            }
            active.remove(id)
        }

        try walk(card.root, depth: 0)
        guard visited.count == card.elements.count,
              parentCounts[card.root] == nil else {
            throw BighelpCardValidationError.invalid
        }
        // A card holds one photo draft and nothing else to act on beside it (docs/IMAGE_DRAFTS.md).
        try ImageDraftCard.validateComposition(card.elements)
        return card
    }

    private static func validateSources(
        _ rawSources: [BighelpJSONValue],
        createdAt: Date
    ) throws -> Set<String> {
        guard rawSources.count <= 4 else { throw BighelpCardValidationError.limitExceeded }
        var ids = Set<String>()
        for rawSource in rawSources {
            guard let source = rawSource.object,
                  let id = source["id"]?.string,
                  !id.isEmpty, id.count <= 64,
                  ids.insert(id).inserted,
                  let request = source["request"]?.object,
                  request["method"]?.string == "GET",
                  let urlString = request["url"]?.string,
                  let url = URL(string: urlString),
                  (try? BighelpCardNetworkPolicy.validate(url)) != nil,
                  let response = source["response"]?.object,
                  response["format"]?.string == "json",
                  let root = response["root"]?.string,
                  root.isEmpty || root.hasPrefix("/"),
                  let refresh = source["refresh"]?.object,
                  let minimum = refresh["minimum_interval_seconds"]?.integer,
                  (60...3_600).contains(minimum),
                  let stale = refresh["stale_after_seconds"]?.integer,
                  stale >= minimum, stale <= 86_400,
                  let expiry = refresh["expires_at"]?.string,
                  let expiryDate = ISO8601DateFormatter().date(from: expiry),
                  expiryDate > createdAt,
                  expiryDate <= createdAt.addingTimeInterval(7 * 86_400) else {
                throw BighelpCardValidationError.invalid
            }
            if request.keys.contains(where: { !["method", "url"].contains($0) }) {
                throw BighelpCardValidationError.invalid
            }
        }
        return ids
    }

    private static func validateElement(
        type: String,
        props: [String: BighelpJSONValue],
        children: [BighelpJSONValue]
    ) throws {
        let allowed: Set<String>
        let required: Set<String>
        switch type {
        case "card":
            allowed = ["title", "subtitle"]; required = ["title"]
        case "vstack", "hstack":
            allowed = ["spacing", "alignment"]; required = []
        case "grid":
            allowed = ["columns", "spacing", "alignment"]; required = ["columns"]
            guard let columns = props["columns"]?.integer, (2...3).contains(columns) else {
                throw BighelpCardValidationError.invalid
            }
        case "text":
            allowed = ["value", "format", "typography", "color", "alignment", "line_limit"]
            required = ["value"]
            if let lineLimit = props["line_limit"]?.integer, !(1...20).contains(lineLimit) {
                throw BighelpCardValidationError.invalid
            }
        case "metric":
            allowed = ["label", "value", "format", "trend", "trend_format", "semantic"]
            required = ["label", "value"]
        case "badge":
            allowed = ["value", "semantic"]; required = ["value", "semantic"]
        case "progress":
            allowed = ["label", "value", "maximum", "format", "semantic"]
            required = ["label", "value", "maximum"]
        case "chart":
            allowed = ["kind", "description", "series"]
            required = allowed
            guard let kind = props["kind"]?.string, ["line", "area", "bar"].contains(kind),
                  let series = props["series"]?.array, (1...6).contains(series.count) else {
                throw BighelpCardValidationError.invalid
            }
            for value in series {
                guard let points = value.object?["points"]?.array, (1...120).contains(points.count) else {
                    throw BighelpCardValidationError.limitExceeded
                }
            }
        case "table":
            allowed = ["columns", "rows"]; required = allowed
            guard let columns = props["columns"]?.array, (1...8).contains(columns.count),
                  let rows = props["rows"]?.array, rows.count <= 50 else {
                throw BighelpCardValidationError.limitExceeded
            }
            for row in rows {
                guard let cells = row.object?["cells"]?.array,
                      cells.count == columns.count else {
                    throw BighelpCardValidationError.invalid
                }
            }
        case "list":
            allowed = ["items", "empty_text", "shows_dividers"]; required = ["items"]
            guard children.count == 1,
                  props["items"]?.object?["source"]?.string != nil,
                  props["items"]?.object?["pointer"]?.string != nil else {
                throw BighelpCardValidationError.invalid
            }
        case "divider":
            allowed = ["semantic"]; required = []
        case "spacer":
            allowed = ["size"]; required = ["size"]
        case "image":
            allowed = ["name", "accessibility_label", "semantic", "scale"]
            required = ["name", "accessibility_label"]
            let imageNames: Set<String> = [
                "bitcoinsign.circle.fill", "bolt.fill", "calendar",
                "chart.line.uptrend.xyaxis", "checkmark.circle.fill", "clock",
                "cloud.sun.fill", "drop.fill", "exclamationmark.triangle.fill",
                "info.circle.fill", "location.fill", "BighelpMarkColor", "star.fill",
                "thermometer.medium", "wave.3.right.circle", "wind",
            ]
            guard let name = props["name"]?.string, imageNames.contains(name) else {
                throw BighelpCardValidationError.invalid
            }
        default:
            throw BighelpCardValidationError.invalid
        }
        guard required.isSubset(of: props.keys), Set(props.keys).isSubset(of: allowed) else {
            throw BighelpCardValidationError.invalid
        }
        if !["card", "vstack", "hstack", "grid", "list"].contains(type), !children.isEmpty {
            throw BighelpCardValidationError.invalid
        }
        let semantics: Set<String> = ["primary", "secondary", "positive", "warning", "negative", "accent", "neutral"]
        if let semantic = props["semantic"]?.string, !semantics.contains(semantic) {
            throw BighelpCardValidationError.invalid
        }
        let spacing: Set<String> = ["none", "xsmall", "small", "medium", "large", "xlarge"]
        for key in ["spacing", "size"] {
            if let token = props[key]?.string, !spacing.contains(token) {
                throw BighelpCardValidationError.invalid
            }
        }
    }

    private static func validateBindings(
        _ value: BighelpJSONValue,
        sourceIDs: Set<String>,
        depth: Int
    ) throws {
        guard depth <= 16 else { throw BighelpCardValidationError.limitExceeded }
        switch value {
        case .object(let object):
            if let sourceID = object["source"]?.string {
                guard sourceIDs.contains(sourceID),
                      let pointer = object["pointer"]?.string,
                      pointer.isEmpty || pointer.hasPrefix("/") else {
                    throw BighelpCardValidationError.unknownSource(sourceID)
                }
            }
            if let expression = object["expression"]?.object {
                guard let operation = expression["op"]?.string,
                      supportedOperations.contains(operation),
                      let arguments = expression["arguments"]?.array,
                      !arguments.isEmpty, arguments.count <= 8 else {
                    throw BighelpCardValidationError.invalid
                }
            }
            for nested in object.values {
                try validateBindings(nested, sourceIDs: sourceIDs, depth: depth + 1)
            }
        case .array(let array):
            for nested in array {
                try validateBindings(nested, sourceIDs: sourceIDs, depth: depth + 1)
            }
        default:
            break
        }
    }

    private static func validateJSON(
        _ value: BighelpJSONValue,
        depth: Int,
        nodeCount: inout Int
    ) throws {
        guard depth <= 24 else { throw BighelpCardValidationError.limitExceeded }
        nodeCount += 1
        guard nodeCount <= maximumDocumentNodes else { throw BighelpCardValidationError.limitExceeded }
        switch value {
        case .string(let string):
            guard string.count <= maximumStringLength else { throw BighelpCardValidationError.limitExceeded }
        case .array(let array):
            for nested in array { try validateJSON(nested, depth: depth + 1, nodeCount: &nodeCount) }
        case .object(let object):
            guard object.count <= 200 else { throw BighelpCardValidationError.limitExceeded }
            for (key, nested) in object {
                guard key.count <= 128 else { throw BighelpCardValidationError.limitExceeded }
                try validateJSON(nested, depth: depth + 1, nodeCount: &nodeCount)
            }
        default:
            break
        }
    }
}
