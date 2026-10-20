import Foundation

/// What a fork copies: message text, history row IDs and its title.
extension DirectHermesSessionCatalogClient {
    static func messageText(_ item: TimelineItem) -> String? {
        guard case .message(let text) = item.content else { return nil }
        return text
    }

    static func historyRowID(_ item: TimelineItem) -> Int? {
        guard let range = item.id.range(of: ":row:", options: .backwards),
              let id = Int(item.id[range.upperBound...]), id > 0 else { return nil }
        return id
    }

    static func forkTitle(_ source: String) throws -> String {
        let suffix = " · Fork"
        let title = String(source.prefix(max(1, 240 - suffix.count))) + suffix
        return try DirectHermesSessionValidation.text(title, maximum: 240, allowsEmpty: false)
    }
}
