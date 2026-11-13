import Foundation
import Testing
@testable import Bighelp

/// A space as the plugin's routes describe it (docs/SPACES.md › Routes), read leniently, and the
/// chat's `space_draft` card, read exactly.
@MainActor
struct SpacesWireTests {
    static let spaceID = "s_0123456789abcdef0123456789abcdef"
    static let appID = "a_0123456789abcdef0123456789abcdef"
    static let at = Date(timeIntervalSince1970: 1_794_500_000)

    /// The plan's sample space, with a card the app can draw.
    static func spaceJSON(_ changes: [String: BighelpJSONValue?] = [:]) -> [String: BighelpJSONValue] {
        var json: [String: BighelpJSONValue] = [
            "spaceId": .string(spaceID), "agentId": .string("research"), "state": .string("live"),
            "title": .string("Commute"), "description": .string("Drive time to work."),
            "size": .string("small"), "hidden": .boolean(false), "position": .integer(3_072), "revision": .integer(2),
            "cardsSha256": .string(String(repeating: "c", count: 64)),
            "card": .object(DemoSpaceCards.commute(at).card),
            "sizes": .object(["tall": .object(DemoSpaceCards.workouts(at).card)]),
            "cardOmitted": .boolean(false),
            "updatedAt": .string("2026-11-12T14:02:00Z"), "checkedAt": .string("2026-11-12T14:15:01.250Z"),
            "page": .object(["appId": .string(appID), "htmlSha256": .string(String(repeating: "d", count: 64)),
                             "live": .boolean(true)]),
            "routine": .object([
                "kind": .string("script"), "usesAI": .boolean(false), "updates": .string("Every 15 minutes"),
                "cadenceMinutes": .integer(15), "state": .string("running"), "nextRunAt": .string("2026-11-12T14:30:00Z"),
                "lastRunAt": .string("2026-11-12T14:15:00Z"), "problem": .null, "pendingChange": .boolean(false),
            ]),
            "status": .string("fresh"),
        ]
        for (key, value) in changes { json[key] = value }
        return json
    }

    /// A bot wrote the title and the words; native UI never draws more than the plugin accepts.
    @Test func aBotsTitleAndDescriptionAreCappedAtTheWireMaximums() throws {
        let long = String(repeating: "w", count: 10_000)
        let space = try #require(Space(json: Self.spaceJSON(["title": .string(long), "description": .string(long)])))
        #expect(space.title.count == SpacesWire.maximumTitleLength)
        #expect(space.description.count == SpacesWire.maximumDescriptionLength)
        // A blank title falls back to the card's.
        let untitled = try #require(Space(json: Self.spaceJSON(["title": .string("  ")])))
        #expect(untitled.title == "Commute")
        // And the copy on the phone's disk reads back as it was kept.
        #expect(Space(json: space.json)?.title == space.title)
    }

    @Test func theDraftCardsWordsAreCappedToo() {
        let long = String(repeating: "w", count: 10_000)
        let details = SpaceDraftDetails(title: long, description: long, updates: long, usesAI: false)
        #expect(details.title.count == SpacesWire.maximumTitleLength)
        #expect(details.description.count == SpacesWire.maximumDescriptionLength)
        #expect(details.updates.count == SpacesWire.maximumUpdatesLength)
        #expect(SpaceDraftDetails(title: "Commute", description: "Drive time.", updates: "Every hour", usesAI: true).title
                == "Commute")
    }

    // MARK: Space

    @Test func aFullSpaceReadsEveryField() throws {
        let space = try #require(Space(json: Self.spaceJSON()))
        #expect(space.key == "research/" + Self.spaceID)
        #expect(space.state == .live)
        #expect(space.title == "Commute")
        #expect(space.size == .small)
        #expect(!space.hidden)
        #expect(space.position == 3_072)
        #expect(space.revision == 2)
        #expect(space.cardsSHA256 == String(repeating: "c", count: 64))
        #expect(space.card?.title == "Commute")
        #expect(space.card(for: .tall)?.title == "Workouts")
        #expect(space.card(for: .wide)?.title == "Commute")
        #expect(!space.cardUnreadable)
        #expect(space.updatedAt == ISO8601DateFormatter().date(from: "2026-11-12T14:02:00Z"))
        #expect(space.checkedAt != nil)
        #expect(space.page == SpacePage(appID: Self.appID, htmlSHA256: String(repeating: "d", count: 64), isLive: true))
        #expect(space.page?.card(title: space.title, description: space.description).sendsAnswers == false)
        #expect(space.routine.kind == .script)
        #expect(!space.routine.usesAI)
        #expect(space.routine.updates == "Every 15 minutes")
        #expect(space.routine.cadenceMinutes == 15)
        #expect(space.routine.state == .running)
        #expect(space.routine.problem == nil)
        #expect(space.status == .fresh)
        #expect(!space.isStopped)
    }

    @Test func unknownValuesFallBackAndUnknownKeysAreIgnored() throws {
        let space = try #require(Space(json: Self.spaceJSON([
            "size": .string("huge"), "status": .string("glowing"), "position": .string("first"),
            "updatedAt": .string("yesterday"), "checkedAt": .integer(12), "card": nil, "sizes": nil,
            "routine": .object(["kind": .string("ai"), "state": .string("sleeping"), "problem": .string("Bad output!")]),
            "somethingNew": .object(["x": .integer(1)]), "page": .object(["appId": .string("not-an-app")]),
        ])))
        #expect(space.size == .wide)
        #expect(space.status == .unknown)
        #expect(space.position == SpacesWire.maximumPositionMagnitude)
        #expect(space.updatedAt == nil)
        #expect(space.checkedAt == nil)
        #expect(space.card == nil)
        #expect(!space.cardUnreadable)
        #expect(space.page == nil)
        #expect(space.routine.state == .unknown)
        // Not running, as far as this app can tell: drawn as stopped.
        #expect(space.isStopped)
        // Never "no AI" by guess.
        #expect(space.routine.usesAI)
        // Only the plugin's fixed codes, never text.
        #expect(space.routine.problem == nil)
    }

    @Test func aMissingRoutineSaysUsesAIAndStopped() throws {
        let space = try #require(Space(json: Self.spaceJSON(["routine": nil, "status": nil])))
        #expect(space.routine.kind == .unknown)
        #expect(space.routine.usesAI)
        #expect(space.isStopped)
    }

    @Test func aCardThatCantBeDrawnMarksOnlyItsSpace() throws {
        var card = DemoSpaceCards.commute(Self.at).card
        card["data_sources"] = .array([.object(["id": .string("live")])])
        let space = try #require(Space(json: Self.spaceJSON(["card": .object(card), "title": .string("  ")])))
        #expect(space.card == nil)
        #expect(space.cardUnreadable)
        #expect(space.holdsCards)
        // No title of its own and no card to borrow one from.
        #expect(space.title.isEmpty)
    }

    @Test func aBrokenSpaceIsLeftOutAndTheRestRead() {
        let list = SpacesList(json: [
            "spaces": .array([
                .object(Self.spaceJSON()),
                .object(Self.spaceJSON(["spaceId": nil])),
                .object(Self.spaceJSON(["agentId": .string("Not An Id")])),
                .string("garbage"),
                .object(Self.spaceJSON(["title": .string("Second copy")])),
                .object(Self.spaceJSON(["spaceId": .string("s_ffffffffffffffffffffffffffffffff"), "size": .integer(3)])),
            ]),
            "agents": .object(["research": .string("ok"), "nova": .string("profile_not_found"),
                               "atlas": .string("busy"), "BAD": .string("ok")]),
        ])
        #expect(list.spaces.map(\.spaceID) == [Self.spaceID, "s_ffffffffffffffffffffffffffffffff"])
        // The first of two with one key wins.
        #expect(list.spaces.first?.title == "Commute")
        #expect(list.spaces.last?.size == .wide)
        #expect(list.agents == ["research": .ok, "nova": .notFound, "atlas": .other("busy")])
        #expect(SpacesList(json: [:]).spaces.isEmpty)
    }

    @Test func thePhonesCopyReadsBackAsTheSameSpace() throws {
        let space = try #require(Space(json: Self.spaceJSON()))
        #expect(Space(json: space.json) == space)
        var unreadable = Self.spaceJSON()
        unreadable["card"] = .object(["schema": .string("other")])
        let marked = try #require(Space(json: unreadable))
        let copy = try #require(Space(json: marked.json))
        #expect(copy.cardUnreadable)
        #expect(copy == marked)
    }

    @Test func cardsLeftOutAreTakenFromThePhoneOnlyWhenUnchanged() throws {
        let cached = try #require(Space(json: Self.spaceJSON()))
        let omitted = try #require(Space(json: Self.spaceJSON(["card": nil, "sizes": nil])))
        #expect(omitted.needsCards)
        #expect(omitted.takingCards(from: cached).card == cached.card)
        let changed = try #require(Space(json: Self.spaceJSON([
            "card": nil, "sizes": nil, "cardsSha256": .string(String(repeating: "e", count: 64)),
        ])))
        #expect(changed.takingCards(from: cached).card == nil)
        let tooBig = try #require(Space(json: Self.spaceJSON(["card": nil, "sizes": nil, "cardOmitted": .boolean(true)])))
        #expect(tooBig.needsCards)
    }

    @Test func changesMergeApplyAndCatchUp() throws {
        let space = try #require(Space(json: Self.spaceJSON()))
        let changes = SpaceChanges(size: .tall).merging(SpaceChanges(hidden: true)).merging(SpaceChanges(size: .wide))
        #expect(changes == SpaceChanges(size: .wide, hidden: true))
        #expect(changes.payload == ["size": .string("wide"), "hidden": .boolean(true)])
        let changed = changes.applied(to: space)
        #expect(changed.size == .wide && changed.hidden)
        #expect(!changes.isSatisfied(by: space))
        #expect(changes.isSatisfied(by: changed))
    }

    @Test func idsAreThePluginsPatterns() {
        #expect(SpacesWire.isSpaceID(Self.spaceID))
        #expect(!SpacesWire.isSpaceID("s_0123456789ABCDEF0123456789abcdef"))
        #expect(!SpacesWire.isSpaceID("a_0123456789abcdef0123456789abcdef"))
        #expect(SpacesWire.isAgentID("research"))
        #expect(SpacesWire.isAgentID("9-lives_bot"))
        #expect(!SpacesWire.isAgentID("-research"))
        #expect(!SpacesWire.isAgentID("Research"))
        #expect(!SpacesWire.isAgentID(String(repeating: "a", count: 65)))
        let operation = SpacesWire.newOperationID()
        #expect(operation == operation.lowercased() && UUID(uuidString: operation) != nil)
    }

    @Test func refusalsBecomeWhatTheScreensActOn() {
        let cases: [(WorkspaceClientError, SpacesError)] = [
            (.rejected(code: "space_not_found"), .notFound),
            (.rejected(code: "profile_not_found"), .notFound),
            (.rejected(code: "draft_changed"), .draftChanged(revision: nil)),
            (.rejected(code: "space_not_draft"), .notDraft),
            (.rejected(code: "spaces_full"), .full),
            (.rejected(code: "refresh_too_soon"), .tooSoon(retryAfter: nil)),
            (.rejected(code: "schedules_unavailable"), .schedulesUnavailable),
            (.rejected(code: "routine_failed"), .routineFailed(nil)),
            (.rejected(code: "invalid_request"), .other(code: "invalid_request")),
            (.outcomeUnknown, .unreachable),
            (.ownerChanged, .unreachable),
            // Only the client's own context check says "update the plugin".
            (.unavailable(.unsupportedOperation), .unreachable),
            (.unavailable(.pluginRequired), .unreachable),
        ]
        for (error, expected) in cases {
            #expect(SpacesError(error) == expected, "\(error)")
        }
        #expect(!SpacesError.unreachable.isDefinite)
        #expect(SpacesError.notFound.isDefinite)
        #expect(SpaceRefreshRun(rawValue: "paused") == .paused)
    }

    @Test func aScriptThatChangedAfterAddIsNamed() throws {
        let space = try #require(Space(json: Self.spaceJSON([
            "routine": .object(["kind": .string("script"), "state": .string("failed"),
                                "problem": .string("script_changed")]),
            "status": .string("stopped"),
        ])))
        #expect(space.isScriptChanged)
        #expect(space.isStopped)
        #expect(!space.isPaused)
    }

    // MARK: Known answers from the spaces routes

    /// The plugin sends these 5xx only once it knows what happened: a refresh that ran and failed,
    /// and a delete that took the space off Today but couldn't remove its task yet. Other routes'
    /// `schedules_unavailable` (Workflows' triggers) keep their meaning.
    @Test func theSpacesRoutesKnownFailuresAreRefusalsNotUnknown() async throws {
        let http = SpacesNativeHTTP()
        let owner = try SpacesNativeHTTP.owner()
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        let delete: [String: BighelpJSONValue] = [
            "agentId": .string("home"), "spaceId": .string(Self.spaceID), "operationId": .string(SpacesWire.newOperationID()),
        ]
        http.answer = (503, "schedules_unavailable")
        await #expect(throws: WorkspaceClientError.rejected(code: "schedules_unavailable")) {
            try await client.perform(.spacesDelete, payload: delete)
        }
        http.answer = (502, "routine_failed")
        await #expect(throws: WorkspaceClientError.rejected(code: "routine_failed")) {
            try await client.perform(.spacesRefresh, payload: delete)
        }
        http.answer = (503, "spaces_unavailable")
        await #expect(throws: WorkspaceClientError.rejected(code: "spaces_unavailable")) {
            try await client.perform(.spacesAdd, payload: delete)
        }
        // Any other 5xx to a change may have run: still unknown.
        http.answer = (503, "busy")
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await client.perform(.spacesDelete, payload: delete)
        }
        http.answer = (503, "schedules_unavailable")
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await client.perform(.cardsTemplatesInstall, payload: ["agentId": .string("default")])
        }
    }

    // MARK: The routes

    /// Demo mode skips HTTP, so only this catches a route the transport would refuse before
    /// sending, or one the plugin client doesn't route at all.
    @Test func everySpacesRouteIsRoutedAndItsAnswerFitsTheHTTPSizeFence() throws {
        for operation in SpacesOperation.allCases {
            let budget = try #require(DirectHermesNativePluginClient.responseBudget(operation.workspaceOperation))
            #expect(budget.path == "/api/plugins/loopdy/native/spaces/" + operation.rawValue)
            #expect(budget.maximumResponseBytes <= DirectHermesHTTP.responseLimit(route: budget.path, method: "POST", query: []),
                    "\(budget.path)")
        }
        // A list of every bot's spaces can come near 4 MiB before the plugin leaves cards out.
        let list = try #require(DirectHermesNativePluginClient.responseBudget(.spacesList))
        #expect(list.maximumResponseBytes > 4 * 1_024 * 1_024)
    }

    // MARK: The draft card

    static func draftProps(_ changes: [String: BighelpJSONValue?] = [:]) -> [String: BighelpJSONValue] {
        var props: [String: BighelpJSONValue] = [
            "space_id": .string(spaceID), "description": .string("Drive time to work, from live traffic."),
            "updates": .string("Every 15 minutes"), "uses_ai": .boolean(false), "revision": .integer(1),
        ]
        for (key, value) in changes { props[key] = value }
        return props
    }

    /// The card `bighelp_draft_space` renders, as `render_card` leaves it.
    static func draftDocument(props: [String: BighelpJSONValue] = draftProps(),
                              extraElements: [String: BighelpJSONValue] = [:]) -> [String: BighelpJSONValue] {
        var elements: [String: BighelpJSONValue] = [
            "space": .object(["type": .string("space_draft"), "props": .object(props), "children": .array([])]),
        ]
        elements.merge(extraElements) { $1 }
        return [
            "schema": .string("loopdy.card"), "version": .integer(1), "title": .string("Commute"),
            "spoken_summary": .string("A space to add to Today: Commute. Updates every 15 minutes, without AI."),
            "data_sources": .array([]), "root": .string("space"), "elements": .object(elements),
            "content_hash": .string(String(repeating: "a", count: 64)), "card_id": .string(String(repeating: "b", count: 32)),
            "origin": .string("live"), "created_at": .string("2026-11-12T12:00:00Z"),
        ]
    }

    @Test func theDraftCardReadsBackExactly() throws {
        let card = try BighelpCardDocument(document: Self.draftDocument())
        let draft = try #require(SpaceDraftCard.draft(in: card))
        #expect(draft == SpaceDraftCard(spaceID: Self.spaceID, title: "Commute",
                                        description: "Drive time to work, from live traffic.",
                                        updates: "Every 15 minutes", usesAI: false, revision: 1))
    }

    @Test func draftPropsAreExactlyTheFiveKeys() {
        let wrong: [[String: BighelpJSONValue?]] = [
            ["size": .string("wide")],
            ["uses_ai": nil],
            ["uses_ai": .string("no")],
            ["revision": .integer(0)],
            ["revision": .number(1.5)],
            ["space_id": .string("s_0123")],
            ["space_id": .string(Self.appID)],
            ["description": .string(" ")],
            ["description": .string(String(repeating: "x", count: 241))],
            ["updates": .string("")],
            ["updates": .string(String(repeating: "x", count: 61))],
        ]
        for change in wrong {
            #expect(throws: (any Error).self, "\(change)") {
                try SpaceDraftCard(props: Self.draftProps(change), title: "Commute")
            }
        }
        #expect((try? SpaceDraftCard(props: Self.draftProps(["uses_ai": .boolean(true)]), title: "Workouts"))?.usesAI == true)
    }

    /// The speaker note says the app draws drafts only to a plugin that knows them, and the whole
    /// list stays within the plugin's eight names.
    @Test func theSpeakerNoteOffersDraftsOnlyToAPluginThatKnowsThem() {
        let every: Set<String> = [BighelpCardObjects.feature, ImageDraftWire.feature, HTMLAppWire.feature, SpacesWire.feature]
        let renders = DirectHermesChatSpeakerNote.payload(agentID: "default", storedSessionID: "s1", personID: "p",
                                                          name: "Sam", pluginFeatures: every)["renders"]?.array
        #expect(renders?.last == .string("space_draft"))
        #expect((renders?.count ?? 0) <= 8)
        let older = DirectHermesChatSpeakerNote.payload(agentID: "default", storedSessionID: "s1", personID: "p", name: "Sam",
                                                        pluginFeatures: [BighelpCardObjects.feature, HTMLAppWire.feature])["renders"]
        #expect(older?.array?.contains(.string("space_draft")) == false)
    }

    /// The plugin's own example (`fixtures/loopdy_card_v1/static-space-draft.json`, same bytes).
    @Test func thePluginFixtureDraftValidatesAndReadsBack() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CardExamples/static-space-draft.json")
        var document = try JSONDecoder().decode([String: BighelpJSONValue].self, from: Data(contentsOf: url))
        // What `render_card` adds to every card.
        for (key, value) in Self.draftDocument() where ["content_hash", "card_id", "origin", "created_at"].contains(key) {
            document[key] = value
        }
        let card = try BighelpCardValidator.validate(BighelpCardDocument(document: document))
        let draft = try #require(SpaceDraftCard.draft(in: card))
        #expect(draft == SpaceDraftCard(spaceID: Self.spaceID, title: "Commute",
                                        description: "Drive time to work, from live traffic.",
                                        updates: "Every 15 minutes", usesAI: false, revision: 1))
    }

    @Test func aDraftIsItsCardsOnlyElement() throws {
        let alone = try BighelpCardDocument(document: Self.draftDocument())
        #expect(throws: Never.self) { try SpaceDraftCard.validateComposition(alone.elements) }
        let crowded = try BighelpCardDocument(document: Self.draftDocument(extraElements: [
            "note": .object(["type": .string("text"), "props": .object(["value": .object(["literal": .string("Hi")])]),
                             "children": .array([])]),
        ]))
        #expect(throws: BighelpCardValidationError.self) { try SpaceDraftCard.validateComposition(crowded.elements) }
    }

    // MARK: The demo computer's cards

    @Test func everyDemoCardDraws() throws {
        for cards in [DemoSpaceCards.commute(Self.at), DemoSpaceCards.garden(Self.at),
                      DemoSpaceCards.workouts(Self.at), DemoSpaceCards.spending(Self.at)] {
            _ = try BighelpCardValidator.validateForStaticRelease(BighelpCardDocument(document: cards.card))
            for (_, size) in cards.sizes {
                _ = try BighelpCardValidator.validateForStaticRelease(BighelpCardDocument(document: try #require(size.object)))
            }
        }
    }
}

/// The plugin's HTTP for `DirectHermesNativePluginClient`: its context lists Spaces, and every
/// route answers with one error.
@MainActor
private final class SpacesNativeHTTP: DirectHermesNativeHTTP {
    var answer: (status: Int, code: String) = (503, "busy")
    private static let etag = "\"sha256:" + String(repeating: "a", count: 64) + "\""

    static func owner() throws -> WorkspaceOwner {
        WorkspaceOwner(authority: try .direct(endpointIdentity: "https://host.example", providerID: "basic", userID: "person"),
                       authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    func nativeResponse(_ request: DirectHermesHTTPRequest,
                        requestGuard: DirectHermesNativeRequestGuard?) async throws -> DirectHermesHTTP.Response {
        let url = try #require(URL(string: "https://host.example" + request.path))
        guard requestGuard != nil else {
            let context: [String: BighelpJSONValue] = [
                "schemaVersion": .integer(1), "pluginVersion": .string("test"), "runtimeId": .string("runtime-test"),
                "servingProfileId": .string("default"),
                "principal": .object(["provider": .string("basic"), "userId": .string("person"), "displayName": .null]),
                "features": .array(["native-context-v1", "serving-profile-v1", "native-card-templates-v1",
                                    SpacesWire.feature].map(BighelpJSONValue.string)),
            ]
            let http = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                    headerFields: ["ETag": Self.etag, "Cache-Control": "no-store"]))
            return .init(http: http, body: try JSONEncoder().encode(BighelpJSONValue.object(context)))
        }
        let http = try #require(HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                                headerFields: ["Cache-Control": "no-store"]))
        let body: [String: BighelpJSONValue] = ["error": .object(["code": .string(answer.code), "message": .string("details")])]
        return .init(http: http, body: try JSONEncoder().encode(BighelpJSONValue.object(body)))
    }
}
