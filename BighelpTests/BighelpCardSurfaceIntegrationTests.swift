import Foundation
import Testing
@testable import Bighelp

@MainActor
struct BighelpCardSurfaceIntegrationTests {
    @Test func timelineContentRoundTripsTheNewCardCase() throws {
        let content = TimelineContent.bighelpCard(try document(importance: nil, validUntil: nil))
        let encoded = try JSONEncoder().encode(content)
        #expect(try JSONDecoder().decode(TimelineContent.self, from: encoded) == content)
        #expect(content.kind == .bighelpCard)
    }

    private func document(importance: String?, validUntil: String?) throws -> BighelpCardDocument {
        var value: [String: BighelpJSONValue] = [
            "schema": .string("loopdy.card"),
            "version": .integer(1),
            "title": .string("Fixture"),
            "spoken_summary": .string("Fixture summary"),
            "data_sources": .array([]),
            "root": .string("root"),
            "elements": .object([
                "root": .object([
                    "type": .string("card"),
                    "props": .object(["title": .string("Fixture")]),
                    "children": .array([]),
                ]),
            ]),
            "content_hash": .string(String(repeating: "a", count: 64)),
            "card_id": .string(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()),
            "origin": .string("live"),
            "created_at": .string("2026-09-02T12:00:00Z"),
        ]
        if let importance { value["importance"] = .string(importance) }
        if let validUntil { value["valid_until"] = .string(validUntil) }
        return try BighelpCardValidator.validate(BighelpCardDocument(document: value))
    }
}
