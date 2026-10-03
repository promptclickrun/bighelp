import Foundation
import Testing
@testable import Bighelp

@MainActor
struct BighelpCardSurfaceIntegrationTests {
    @Test func inboxPolicyRoutesLegacyAndNewCardsWithoutFallbackText() throws {
        let legacy = try JSONDecoder().decode(
            GenerativeUICard.self,
            from: Data("{\"schema\":\"loopdy.generative_ui\",\"version\":1,\"component\":\"summary\",\"title\":\"Legacy\",\"body\":\"Supported\"}".utf8)
        )
        let legacyItem = DashboardInboxItem(
            id: "legacy", title: "Legacy", detail: "Text", agentName: "Agent", status: "Now", card: legacy
        )
        #expect(InboxUpdateContentPolicy.primaryContent(for: legacyItem) == .generativeUICard)
        guard case .legacy = legacyItem.cardEnvelope else {
            Issue.record("Expected legacy envelope")
            return
        }

        let card = try document(importance: "important", validUntil: nil)
        let newItem = DashboardInboxItem(
            id: "card", title: "Card", detail: "Text", agentName: "Agent", status: "Now", bighelpCard: card
        )
        #expect(InboxUpdateContentPolicy.primaryContent(for: newItem) == .bighelpCard)
        guard case .card = newItem.cardEnvelope else {
            Issue.record("Expected new card envelope")
            return
        }
    }

    @Test func timelineContentRoundTripsTheNewCardCase() throws {
        let content = TimelineContent.bighelpCard(try document(importance: nil, validUntil: nil))
        let encoded = try JSONEncoder().encode(content)
        #expect(try JSONDecoder().decode(TimelineContent.self, from: encoded) == content)
        #expect(content.kind == .bighelpCard)
    }

    @Test func dashboardRanksGenericImportanceAndOmitsOnlyUnpinnedExpiredCards() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-02T14:00:00Z"))
        let source = BighelpCardDashboardSource(snapshot: DashboardSnapshot(
            inbox: [
                item("normal", card: try document(importance: nil, validUntil: nil)),
                item("urgent", card: try document(importance: "urgent", validUntil: "2026-09-03T12:00:00Z")),
                item("expired", card: try document(importance: "urgent", validUntil: "2026-09-02T13:00:00Z")),
                item("important", card: try document(importance: "important", validUntil: nil)),
                item("pinned-expired", card: try document(importance: nil, validUntil: "2026-09-02T13:00:00Z"), pinned: true),
            ],
            attentionItems: [],
            completedItems: [],
            agents: []
        ))
        let model = DashboardModel(source: source, now: { now })
        await model.load()
        #expect(model.snapshot?.inbox.map(\.id) == ["pinned-expired", "urgent", "important", "normal"])
    }

    private func item(_ id: String, card: BighelpCardDocument, pinned: Bool = false) -> DashboardInboxItem {
        DashboardInboxItem(
            id: id,
            title: id,
            detail: "Fixture",
            agentName: "Agent",
            status: "Now",
            bighelpCard: card,
            isPinned: pinned,
            createdAt: Date(timeIntervalSince1970: 1_788_350_400)
        )
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

@MainActor
private struct BighelpCardDashboardSource: DashboardDataSource {
    let snapshot: DashboardSnapshot
    func loadDashboard() async throws -> DashboardSnapshot { snapshot }
}
