import Foundation
import Testing
@testable import Bighelp

/// An agent's HTML app in a chat (docs/HTML_APPS.md): the `html_app` card element, the answer the
/// app sends, the plugin's two routes, and what the speaker note says the app can draw.
@MainActor
struct HTMLAppTests {
    static let appID = "a_0123456789abcdef0123456789abcdef"

    static func props(_ changes: [String: BighelpJSONValue?] = [:]) -> [String: BighelpJSONValue] {
        var props: [String: BighelpJSONValue] = [
            "app_id": .string(appID), "description": .string("Split $2,400 across travel, food and fun."),
            "sends_answers": .boolean(true), "live": .boolean(false),
        ]
        for (key, value) in changes { props[key] = value }
        return props
    }

    /// A card as the plugin's `bighelp_show_app` renders it.
    static func document(props: [String: BighelpJSONValue] = props(),
                         extraElements: [String: BighelpJSONValue] = [:]) -> [String: BighelpJSONValue] {
        var elements: [String: BighelpJSONValue] = [
            "app": .object(["type": .string("html_app"), "props": .object(props), "children": .array([])]),
        ]
        elements.merge(extraElements) { $1 }
        return [
            "schema": .string("loopdy.card"), "version": .integer(1), "title": .string("Trip budget"),
            "spoken_summary": .string("An app to open in bighelp: Trip budget."), "data_sources": .array([]),
            "root": .string("app"), "elements": .object(elements),
            "content_hash": .string(String(repeating: "a", count: 64)),
            "card_id": .string(String(repeating: "b", count: 32)),
            "origin": .string("live"), "created_at": .string("2026-11-07T12:00:00Z"),
        ]
    }

    static func card(_ document: [String: BighelpJSONValue]) throws -> BighelpCardDocument {
        try BighelpCardValidator.validateForStaticRelease(BighelpCardDocument(document: document))
    }

    // MARK: The card

    @Test func aPluginMadeAppCardValidatesAndReadsBack() throws {
        let app = try #require(HTMLAppCard.app(in: try Self.card(Self.document())))
        #expect(app == HTMLAppCard(appID: Self.appID, title: "Trip budget",
                                   description: "Split $2,400 across travel, food and fun.",
                                   sendsAnswers: true, isLive: false))
    }

    @Test func thePluginFixtureCardValidatesAndReadsBack() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CardExamples/static-html-app.json")
        var document = try JSONDecoder().decode([String: BighelpJSONValue].self, from: Data(contentsOf: url))
        // What `render_card` adds to every card.
        for (key, value) in Self.document() where ["content_hash", "card_id", "origin", "created_at"].contains(key) {
            document[key] = value
        }
        let app = try #require(HTMLAppCard.app(in: try Self.card(document)))
        #expect(app.title == "Trip planner")
        #expect(app.sendsAnswers)
        #expect(!app.isLive)
    }

    @Test func appPropsAreExactlyTheFourKeys() {
        let wrong: [[String: BighelpJSONValue?]] = [
            ["html": .string("<p>hi</p>")],
            ["live": nil],
            ["sends_answers": .string("yes")],
            ["app_id": .string("a_0123")],
            ["app_id": .string("d_0123456789abcdef0123456789abcdef")],
            ["description": .string("")],
            ["description": .string(String(repeating: "x", count: 241))],
        ]
        for change in wrong {
            #expect(throws: (any Error).self, "\(change)") {
                try Self.card(Self.document(props: Self.props(change)))
            }
        }
    }

    @Test func anAppIsTheCardsOnlyElement() {
        let text: BighelpJSONValue = .object(["type": .string("text"),
                                              "props": .object(["value": .object(["literal": .string("Hi")])]),
                                              "children": .array([])])
        #expect(throws: (any Error).self) {
            try Self.card(Self.document(extraElements: ["note": text]))
        }
    }

    @Test func anOrdinaryCardHoldsNoApp() throws {
        var document = Self.document()
        document["root"] = .string("note")
        document["elements"] = .object(["note": .object([
            "type": .string("text"), "props": .object(["value": .object(["literal": .string("Hi")])]),
            "children": .array([]),
        ])])
        #expect(HTMLAppCard.app(in: try Self.card(document)) == nil)
    }

    // MARK: The answer the app sends

    @Test func anObjectAnswerReadsLikeAFormAnswer() throws {
        let answer = try HTMLAppAnswer(json: #"[["Travel",1100],["Food",800.5],["Booked",true],["Who",["Sam","Ana"]],["Note","Two\nlines"]]"#)
        #expect(answer.message(title: "Trip budget") == """
        My answers to “Trip budget”:
        - Travel: 1100
        - Food: 800.5
        - Booked: Yes
        - Who: Sam, Ana
        - Note: Two
          lines
        """)
    }

    @Test func aTextAnswerKeepsItsWords() throws {
        let answer = try HTMLAppAnswer(json: #""Let's do the mountains.""#)
        #expect(answer.message(title: "Trip budget") == "My answer from “Trip budget”:\nLet's do the mountains.")
    }

    @Test func answersThatCantBeWordsAreRefused() {
        let wrong = [
            #"[["Nested",{"a":1}]]"#, #"[["Nothing",null]]"#, #"[]"#, #""   ""#, #"42"#, #"[["",1]]"#,
            "[" + (0...40).map { #"["k\#($0)",1]"# }.joined(separator: ",") + "]",
            #"""# + String(repeating: "x", count: ChatOutgoingMessage.maximumCardReplyBytes) + #"""#,
        ]
        for json in wrong {
            #expect(throws: HTMLAppAnswerError.self, "\(json.prefix(40))") { try HTMLAppAnswer(json: json) }
        }
    }

    // MARK: The plugin's routes

    @Test func getReadsTheAppAndChecksItsHash() async throws {
        let html = "<!doctype html><p>Trip budget</p>"
        let client = HTMLAppsFakeClient()
        client.replies[.get] = Self.getReply(html: html)
        let page = try await HTMLAppsAPI(client: client).app(agentID: "default", appID: Self.appID, knownSHA256: nil)
        #expect(page.html == html)
        #expect(page.info.title == "Trip budget")
        #expect(page.info.sendsAnswers)
        #expect(page.info.revision == 2)
        #expect(client.calls.first?.payload == ["agentId": .string("default"), "appId": .string(Self.appID)])

        client.replies[.get] = Self.getReply(html: html, hash: String(repeating: "0", count: 64))
        await #expect(throws: HTMLAppsError.failed) {
            try await HTMLAppsAPI(client: client).app(agentID: "default", appID: Self.appID, knownSHA256: nil)
        }
    }

    @Test func getLeavesOutTheHTMLThePhoneAlreadyHas() async throws {
        let html = "<p>same</p>"
        let client = HTMLAppsFakeClient()
        var reply = Self.getReply(html: html)
        reply["html"] = nil
        client.replies[.get] = reply
        let known = HTMLAppHash.sha256(Data(html.utf8))
        let page = try await HTMLAppsAPI(client: client).app(agentID: "default", appID: Self.appID, knownSHA256: known)
        #expect(page.html == nil)
        #expect(client.calls.first?.payload["knownSha256"] == .string(known))
    }

    @Test func dataReadsTheLatestValueOrWhyThereIsNone() async throws {
        let client = HTMLAppsFakeClient()
        client.replies[.data] = ["appId": .string(Self.appID), "data": .object(["moisture": .integer(41)]),
                                 "updatedAt": .string("2026-11-07T12:00:05Z"), "dataSha256": .string("ab"),
                                 "problem": .null]
        let api = HTMLAppsAPI(client: client)
        let data = try await api.data(agentID: "default", appID: Self.appID)
        #expect(data.json == #"{"moisture":41}"#)
        #expect(data.problem == nil)

        client.replies[.data] = ["appId": .string(Self.appID), "data": .null, "updatedAt": .null,
                                 "dataSha256": .null, "problem": .string("invalid")]
        let broken = try await api.data(agentID: "default", appID: Self.appID)
        #expect(broken.json == nil)
        #expect(broken.problem == .invalid)
    }

    @Test func aPageComesInPiecesAndIsPutTogether() async throws {
        let page = String(repeating: "<p>Trip budget é</p>\n", count: 600)
        let server = HTMLAppPieceServer(page: page, pieceBytes: 4_096)
        let result = try await HTMLAppsAPI(client: server, retryDelays: [.zero])
            .app(agentID: "default", appID: Self.appID, knownSHA256: nil)
        #expect(result.html == page)
        let pieces = (Data(page.utf8).count + 4_095) / 4_096
        #expect(server.calls.count == pieces)
        let later = server.calls.dropFirst().map(\.payload)
        #expect(later.allSatisfy { $0["htmlSha256"]?.string == HTMLAppHash.sha256(Data(page.utf8)) && $0["knownSha256"] == nil })
        #expect(later.compactMap { $0["offset"]?.integer } == (1..<pieces).map { $0 * 4_096 })
    }

    @Test func aDroppedPieceIsAskedForAgainFromItsOffset() async throws {
        let page = String(repeating: "x", count: 10_000)
        let server = HTMLAppPieceServer(page: page, pieceBytes: 4_096)
        server.dropOnce = [4_096]
        let result = try await HTMLAppsAPI(client: server, retryDelays: [.zero])
            .app(agentID: "default", appID: Self.appID, knownSHA256: nil)
        #expect(result.html == page)
        #expect(server.calls.compactMap { $0.payload["offset"]?.integer } == [4_096, 4_096, 8_192])
    }

    @Test func aPageThatChangesWhileItLoadsStartsAgain() async throws {
        let server = HTMLAppPieceServer(page: String(repeating: "a", count: 10_000), pieceBytes: 4_096)
        server.replaceAfterFirstPiece = String(repeating: "b", count: 5_000)
        let result = try await HTMLAppsAPI(client: server, retryDelays: [.zero])
            .app(agentID: "default", appID: Self.appID, knownSHA256: nil)
        #expect(result.html == String(repeating: "b", count: 5_000))
    }

    /// Demo mode skips HTTP, so only this catches a route whose answer the transport would refuse
    /// before sending (on a real host, every app said "The app didn't open").
    @Test func everyAppRoutesAnswerFitsTheHTTPSizeFence() throws {
        for operation in HTMLAppsOperation.allCases {
            let budget = try #require(DirectHermesNativePluginClient.responseBudget(operation.workspaceOperation))
            #expect(budget.maximumResponseBytes <= DirectHermesHTTP.responseLimit(route: budget.path, method: "POST", query: []),
                    "\(budget.path)")
        }
    }

    @Test func refusalsBecomePlainErrors() async {
        let client = HTMLAppsFakeClient()
        client.error = WorkspaceClientError.unavailable(.unsupportedOperation)
        await #expect(throws: HTMLAppsError.needsPluginUpdate) {
            try await HTMLAppsAPI(client: client).data(agentID: "default", appID: Self.appID)
        }
        client.error = WorkspaceClientError.rejected(code: "app_not_found")
        await #expect(throws: HTMLAppsError.notFound) {
            try await HTMLAppsAPI(client: client).data(agentID: "default", appID: Self.appID)
        }
    }

    // MARK: What the app says it draws

    @Test func theSpeakerNoteOffersAppsOnlyToAPluginThatKnowsThem() {
        let both: Set<String> = [BighelpCardObjects.feature, HTMLAppWire.feature]
        let renders = DirectHermesChatSpeakerNote.payload(agentID: "default", storedSessionID: "s1", personID: "p",
                                                             name: "Sam", pluginFeatures: both)["renders"]
        #expect(renders?.array?.contains(.string("html_app")) == true)
        let older = DirectHermesChatSpeakerNote.payload(agentID: "default", storedSessionID: "s1", personID: "p",
                                                           name: "Sam", pluginFeatures: [BighelpCardObjects.feature])["renders"]
        #expect(older?.array?.contains(.string("html_app")) == false)
    }

    static func getReply(html: String, hash: String? = nil) -> [String: BighelpJSONValue] {
        let bytes = Data(html.utf8)
        return [
            "app": .object([
                "appId": .string(appID), "title": .string("Trip budget"),
                "description": .string("Split $2,400 across travel, food and fun."),
                "sendsAnswers": .boolean(true), "live": .boolean(false), "revision": .integer(2),
                "updatedAt": .string("2026-11-07T12:00:00Z"),
                "htmlSha256": .string(hash ?? HTMLAppHash.sha256(bytes)), "htmlBytes": .integer(bytes.count),
            ]),
            "html": .string(bytes.base64EncodedString()),
        ]
    }
}

/// Serves one app's page the way the plugin does (`DemoHTMLAppsClient.pageReply`), and can drop a
/// piece once or replace the page after the first piece.
@MainActor
final class HTMLAppPieceServer: HTMLAppsClient {
    var page: Data
    let pieceBytes: Int
    var dropOnce: Set<Int> = []
    var replaceAfterFirstPiece: String?
    private(set) var calls: [(operation: HTMLAppsOperation, payload: [String: BighelpJSONValue])] = []

    init(page: String, pieceBytes: Int) {
        self.page = Data(page.utf8)
        self.pieceBytes = pieceBytes
    }

    func perform(_ operation: HTMLAppsOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        calls.append((operation, payload))
        if let offset = payload["offset"]?.integer, dropOnce.remove(offset) != nil {
            throw WorkspaceClientError.transportUnavailable
        }
        let info: [String: BighelpJSONValue] = [
            "appId": .string(HTMLAppTests.appID), "title": .string("Trip budget"), "description": .string("D"),
            "sendsAnswers": .boolean(true), "live": .boolean(false), "revision": .integer(1),
        ]
        let reply = try DemoHTMLAppsClient.pageReply(info: info, page: page, payload: payload, pieceBytes: pieceBytes)
        if let replacement = replaceAfterFirstPiece {
            page = Data(replacement.utf8)
            replaceAfterFirstPiece = nil
        }
        return reply
    }
}

@MainActor
final class HTMLAppsFakeClient: HTMLAppsClient {
    var replies: [HTMLAppsOperation: [String: BighelpJSONValue]] = [:]
    var error: (any Error)?
    private(set) var calls: [(operation: HTMLAppsOperation, payload: [String: BighelpJSONValue])] = []

    func perform(_ operation: HTMLAppsOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        calls.append((operation, payload))
        if let error { throw error }
        return replies[operation] ?? [:]
    }
}
