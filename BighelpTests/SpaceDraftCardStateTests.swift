import Foundation
import Testing
@testable import Bighelp

/// The chat's draft card: read the draft, Add to Today, then On Today, and every way that can go
/// otherwise. Answers count only for the request the card waits on.
@MainActor
struct SpaceDraftCardStateTests {
    static let draft = SpaceDraftCard(spaceID: SpacesWireTests.spaceID, title: "Commute",
                                      description: "Drive time to work.", updates: "Every 15 minutes",
                                      usesAI: false, revision: 1)

    static func routine(state: String, usesAI: Bool = false, pendingChange: Bool = false) -> BighelpJSONValue {
        .object(["kind": .string(usesAI ? "ai" : "script"), "usesAI": .boolean(usesAI),
                 "updates": .string(usesAI ? "Every day at 7:00" : "Every 15 minutes"), "state": .string(state),
                 "pendingChange": .boolean(pendingChange)])
    }

    static func draftSpace(revision: Int = 1, size: String = "small", usesAI: Bool = false,
                           description: String = "Drive time to work.") throws -> Space {
        try #require(Space(json: SpacesWireTests.spaceJSON([
            "state": .string("draft"), "status": .string("draft"), "revision": .integer(revision),
            "size": .string(size), "description": .string(description),
            "routine": routine(state: "draft", usesAI: usesAI),
        ])))
    }

    static func liveSpace(revision: Int = 1, pendingChange: Bool = false) throws -> Space {
        try #require(Space(json: SpacesWireTests.spaceJSON([
            "revision": .integer(revision), "routine": routine(state: "running", pendingChange: pendingChange),
        ])))
    }

    /// A flow that has read the draft.
    static func ready() throws -> SpaceDraftFlow {
        var flow = SpaceDraftFlow(draft: draft)
        let read = flow.beginLoad()
        flow.loaded(.success(try draftSpace()), ticket: read)
        return flow
    }

    @Test func aDraftIsAddedAndThenOnToday() throws {
        var flow = SpaceDraftFlow(draft: Self.draft)
        #expect(flow.phase == .loading)
        #expect(!flow.canAdd)
        let read = flow.beginLoad()
        flow.loaded(.success(try Self.draftSpace(size: "small")), ticket: read)
        #expect(flow.phase == .ready)
        #expect(flow.size == .small)
        #expect(flow.canAdd)

        let addTicket = flow.beginAdd()
        let add = try #require(addTicket)
        #expect(add.revision == 1)
        #expect(flow.phase == .adding)
        #expect(flow.beginAdd() == nil)
        #expect(!flow.added(.success(try Self.liveSpace()), ticket: add))
        #expect(flow.phase == .onToday)
        #expect(!flow.showsSizes)
    }

    @Test func aSpaceAlreadyLiveIsOnToday() throws {
        var flow = SpaceDraftFlow(draft: Self.draft)
        let read = flow.beginLoad()
        flow.loaded(.success(try Self.liveSpace()), ticket: read)
        #expect(flow.phase == .onToday)
        #expect(!flow.wantsRead)
    }

    @Test func aLiveSpaceWithAChangedRoutineWaitsForAdd() throws {
        var flow = SpaceDraftFlow(draft: Self.draft)
        let read = flow.beginLoad()
        flow.loaded(.success(try Self.liveSpace(pendingChange: true)), ticket: read)
        #expect(flow.phase == .ready)
        #expect(flow.canAdd)
    }

    @Test func aDeletedDraftIsRemoved() {
        var flow = SpaceDraftFlow(draft: Self.draft)
        let read = flow.beginLoad()
        flow.loaded(.failure(.notFound), ticket: read)
        #expect(flow.phase == .removed)
        #expect(!flow.canAdd)
    }

    @Test func aDraftThatCanNotBeReadStillAdds() {
        var flow = SpaceDraftFlow(draft: Self.draft)
        let read = flow.beginLoad()
        flow.loaded(.failure(.unreachable), ticket: read)
        #expect(flow.phase == .ready)
        #expect(flow.preview == nil)
        #expect(flow.canAdd)
        // Shown again later, it asks again.
        #expect(flow.wantsRead)
    }

    @Test func aNewerDraftOnTheComputerIsWhatAddSends() throws {
        var flow = SpaceDraftFlow(draft: Self.draft)
        let read = flow.beginLoad()
        flow.loaded(.success(try Self.draftSpace(revision: 2, usesAI: true, description: "Drive and train times.")),
                    ticket: read)
        #expect(flow.notice == .changed)
        #expect(flow.revision == 2)
        #expect(flow.details.description == "Drive and train times.")
        #expect(flow.details.usesAI)
        #expect(flow.details.updates == "Every day at 7:00")
        #expect(flow.beginAdd()?.revision == 2)
    }

    @Test func theBotChangingTheDraftReadsItAgain() throws {
        var flow = try Self.ready()
        let addTicket = flow.beginAdd()
        let add = try #require(addTicket)
        let addReread = flow.added(.failure(.draftChanged(revision: 3)), ticket: add)
        #expect(addReread)
        #expect(flow.phase == .loading)
        #expect(flow.notice == .changed)
        #expect(flow.revision == 3)
        #expect(!flow.canAdd)

        let read = flow.beginLoad()
        flow.loaded(.success(try Self.draftSpace(revision: 3)), ticket: read)
        #expect(flow.phase == .ready)
        #expect(flow.notice == .changed)
        #expect(flow.beginAdd()?.revision == 3)
    }

    @Test func anOlderPluginSaysToUpdateIt() throws {
        var loading = SpaceDraftFlow(draft: Self.draft)
        let read = loading.beginLoad()
        loading.loaded(.failure(.needsPluginUpdate), ticket: read)
        #expect(loading.phase == .needsPluginUpdate)

        var adding = try Self.ready()
        let addTicket = adding.beginAdd()
        let add = try #require(addTicket)
        adding.added(.failure(.needsPluginUpdate), ticket: add)
        #expect(adding.phase == .needsPluginUpdate)
        #expect(!adding.canAdd)
    }

    @Test func noAnswerKeepsAddAndSaysSo() throws {
        var flow = try Self.ready()
        let addTicket = flow.beginAdd()
        let add = try #require(addTicket)
        flow.added(.failure(.unreachable), ticket: add)
        #expect(flow.phase == .ready)
        #expect(flow.notice == .unreachable)
        #expect(flow.canAdd)
        // Trying again clears the line until the next answer.
        _ = flow.beginAdd()
        #expect(flow.notice == nil)
    }

    @Test func aMissingScriptSaysToAskTheBot() throws {
        var flow = try Self.ready()
        let addTicket = flow.beginAdd()
        let add = try #require(addTicket)
        flow.added(.failure(.scriptMissing), ticket: add)
        #expect(flow.phase == .ready)
        #expect(flow.notice == .scriptMissing)
    }

    @Test func alreadyLiveAtAddIsOnToday() throws {
        var flow = try Self.ready()
        let addTicket = flow.beginAdd()
        let add = try #require(addTicket)
        flow.added(.failure(.notDraft), ticket: add)
        #expect(flow.phase == .onToday)
    }

    @Test func aLateAnswerForAnOlderRevisionIsIgnored() throws {
        var flow = try Self.ready()
        let firstTicket = flow.beginAdd()
        let first = try #require(firstTicket)
        // The same Add answered twice: first "the bot changed it", then, late, a success for revision 1.
        let firstReread = flow.added(.failure(.draftChanged(revision: 2)), ticket: first)
        #expect(firstReread)
        let read = flow.beginLoad()
        #expect(!flow.added(.success(try Self.liveSpace(revision: 1)), ticket: first))
        #expect(flow.phase == .loading)
        #expect(flow.revision == 2)

        flow.loaded(.success(try Self.draftSpace(revision: 2)), ticket: read)
        #expect(flow.phase == .ready)
    }

    @Test func aReadTheCardGaveUpOnChangesNothing() throws {
        var flow = SpaceDraftFlow(draft: Self.draft)
        let first = flow.beginLoad()
        let second = flow.beginLoad()
        flow.loaded(.failure(.notFound), ticket: first)
        #expect(flow.phase == .loading)
        flow.loaded(.success(try Self.draftSpace()), ticket: second)
        #expect(flow.phase == .ready)
    }

    @Test func theCardNeverSaysNoAIByGuess() throws {
        // The card's props say no AI, but the computer's routine for the same revision says AI.
        var flow = SpaceDraftFlow(draft: Self.draft)
        #expect(!flow.details.usesAI)
        let read = flow.beginLoad()
        flow.loaded(.success(try Self.draftSpace(usesAI: true)), ticket: read)
        #expect(flow.details.usesAI)

        let props = SpaceDraftCard(spaceID: SpacesWireTests.spaceID, title: "Commute", description: "Drive time.",
                                   updates: "Every hour", usesAI: true, revision: 1)
        var aiFlow = SpaceDraftFlow(draft: props)
        let aiRead = aiFlow.beginLoad()
        aiFlow.loaded(.success(try Self.draftSpace(usesAI: false)), ticket: aiRead)
        #expect(aiFlow.details.usesAI)
    }

    @Test func aSizeThePersonPickedStays() throws {
        var flow = SpaceDraftFlow(draft: Self.draft)
        flow.choose(.tall)
        let read = flow.beginLoad()
        flow.loaded(.success(try Self.draftSpace(size: "small")), ticket: read)
        #expect(flow.size == .tall)
        let addTicket = flow.beginAdd()
        let add = try #require(addTicket)
        #expect(add.revision == 1)
        flow.choose(.small)
        #expect(flow.size == .tall)
    }

    // MARK: The card's model

    /// What the fake computer was asked.
    @MainActor
    final class Calls {
        var reads = 0
        var sent: [(revision: Int, size: SpaceSize, hasPreview: Bool)] = []
    }

    @Test func addSendsTheRevisionAndSizeShownAndReadsAgainWhenTheBotChangedIt() async throws {
        let calls = Calls()
        let drafts = [try Self.draftSpace(revision: 1), try Self.draftSpace(revision: 2)]
        let live = try Self.liveSpace(revision: 2)
        let model = SpaceDraftCardModel(
            draft: Self.draft,
            read: { (_: String, _: String) async throws(SpacesError) -> Space in
                calls.reads += 1
                return drafts[min(calls.reads, 2) - 1]
            },
            add: { (_: String, _: String, revision: Int, size: SpaceSize, preview: Space?) async throws(SpacesError) -> Space in
                calls.sent.append((revision, size, preview != nil))
                // The bot drafted revision 2 while the card still showed 1.
                if revision == 1 { throw .draftChanged(revision: nil) }
                return live
            })
        await model.load(agentID: "research")
        model.choose(.wide)
        model.add(agentID: "research")
        while model.flow.phase == .adding { await Task.yield() }
        #expect(model.flow.notice == .changed)
        #expect(model.reloads == 1)

        await model.load(agentID: "research")
        #expect(model.flow.revision == 2)
        model.add(agentID: "research")
        while model.flow.phase == .adding { await Task.yield() }
        #expect(model.flow.phase == .onToday)
        #expect(calls.sent.map(\.revision) == [1, 2])
        #expect(calls.sent.map(\.size) == [.wide, .wide])
        #expect(calls.sent.allSatisfy { $0.hasPreview })
    }
}
