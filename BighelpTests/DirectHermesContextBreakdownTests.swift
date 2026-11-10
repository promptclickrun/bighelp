import Foundation
import Testing
@testable import Bighelp

/// The chat's Context page reads Hermes' `session.context_breakdown`. Hermes adds to that answer
/// over time, and an answer with a part the app doesn't know must still show.
struct DirectHermesContextBreakdownTests {
    /// Hermes 0.23's answer for a live chat: the eight parts the app shows, plus `context_files`.
    private func answer(extra: [String: BighelpJSONValue] = [:],
                        categories: [BighelpJSONValue]? = nil) -> BighelpJSONValue {
        var object: [String: BighelpJSONValue] = [
            "categories": .array(categories ?? [
                .object(["color": .string("#6b7280"), "id": .string("system_prompt"),
                         "label": .string("System prompt"), "tokens": .integer(4_200)]),
                .object(["color": .string("#3b82f6"), "id": .string("conversation"),
                         "label": .string("Conversation"), "tokens": .integer(51_407)]),
            ]),
            "estimated_total": .integer(55_607), "context_max": .integer(1_000_000),
            "context_percent": .integer(6), "context_used": .integer(55_607),
            "context_source": .string("provider_usage"), "context_estimated": .boolean(false),
            "model": .string("example-model"),
        ]
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    @Test func anAnswerWithPartsTheAppDoesNotKnowStillShows() throws {
        let files: BighelpJSONValue = .array([.object(["path": .string("AGENTS.md"), "loaded": .boolean(true)])])
        let breakdown = try DirectHermesContextBreakdown(hermes: answer(extra: ["context_files": files]))
        #expect(breakdown.contextUsed == 55_607 && breakdown.contextMax == 1_000_000 && breakdown.contextPercent == 6)
        #expect(breakdown.categories.map(\.id) == ["system_prompt", "conversation"])
        #expect(breakdown.estimatedTotal == 55_607 && breakdown.model == "example-model")
    }

    @Test func aRowWithMoreOrLessThanTheAppKnowsHidesOnlyItself() throws {
        let breakdown = try DirectHermesContextBreakdown(hermes: answer(categories: [
            .object(["color": .string("#111"), "id": .string("skills"), "label": .string("Skills"),
                     "tokens": .integer(900), "glyph": .string("◆")]),
            .object(["id": .string("memory"), "tokens": .integer(300)]),
            .object(["id": .string("broken"), "tokens": .string("many")]),
            .string("not a row"),
        ]))
        #expect(breakdown.categories.map(\.id) == ["skills", "memory"])
        #expect(breakdown.categories.map(\.label) == ["Skills", "memory"], "A row without a label shows its name")
        #expect(breakdown.categories.map(\.tokens) == [900, 300])
    }

    @Test func missingTotalsAreWorkedOutAndOnlyANonObjectIsRefused() throws {
        let bare = try DirectHermesContextBreakdown(hermes: .object([
            "categories": .array([.object(["id": .string("conversation"), "tokens": .integer(250)])]),
            "context_max": .integer(1_000), "context_used": .integer(250),
        ]))
        #expect(bare.estimatedTotal == 250 && bare.contextPercent == 25)
        #expect(bare.contextEstimated == false && bare.contextSource.isEmpty && bare.model.isEmpty)

        let empty = try DirectHermesContextBreakdown(hermes: .object([:]))
        #expect(empty.categories.isEmpty && empty.contextMax == 0 && empty.contextPercent == 0)
        #expect(throws: DirectHermesError.self) { try DirectHermesContextBreakdown(hermes: .array([])) }
    }
}
