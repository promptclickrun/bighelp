import CryptoKit
import Foundation
import Testing
@testable import Bighelp

/// The plugin seals `Fixtures/sealed-card-v1-vector.json` with a test-only key; the card must
/// open it to the same step, question and reply lines, and open nothing else.
struct BighelpActivityDetailTests {
    private struct Vector: Decodable {
        let key: String
        let timestamp: Int
        let sealed: String
    }

    private let vector: Vector
    private let key: SymmetricKey

    init() throws {
        vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appending(path: "Fixtures/sealed-card-v1-vector.json")))
        key = SymmetricKey(data: try #require(BighelpActivityDetail.decode(vector.key)))
    }

    /// An iPhone draws the card where the keychain can't be reached (the simulator lets it), so a card
    /// carries its own copy of the secret in its attributes. A row opens with it and with no other.
    @Test func aRowOpensWithTheKeyItsCardCarries() throws {
        let master = SymmetricKey(size: .bits256)
        let id = "native-" + String(repeating: "ab", count: 32)
        let box = try AES.GCM.seal(Data(#"{"v":1,"b":1800000000,"s":2,"t":"web_search","n":"lamb prices"}"#.utf8),
                                   using: BighelpActivityCardKey.rowKey(id, master: master),
                                   authenticating: Data("bighelp-card-v1|1800000100".utf8))
        var row = BighelpActivitySession(id: id, phase: .usingTool, timestamp: 1_800_000_100)
        row.sealed = BighelpActivityDetail.encode(try #require(box.combined))
        let cardKey = BighelpActivityDetail.encode(master.withUnsafeBytes { Data($0) })
        #expect(row.openDetail(cardKey: cardKey)?.tool == "web_search")
        let another = BighelpActivityDetail.encode(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        #expect(row.openDetail(cardKey: another) == nil)
        #expect(BighelpActivityCardKey.master(attributeKey: "not-a-key") == nil)
        #expect(BighelpActivityCardKey.master(attributeKey: nil) == nil)
    }

    /// The key rides in the card's attributes only: a card started before cards carried one still
    /// reads, and nothing Bighelp saves about a row keeps it.
    @Test func aCardsKeyIsNeverInWhatBighelpSaves() throws {
        var attributes = try #require(LoopdySessionActivityAttributes.make(
            sessionID: "native-row", sessionTitle: "Chat", agentID: "agent", agentName: "Scout"))
        let before = try JSONDecoder().decode(LoopdySessionActivityAttributes.self, from: JSONEncoder().encode(attributes))
        #expect(before.cardKey == nil)
        attributes.cardKey = "made-up-key"
        let carried = try JSONDecoder().decode(LoopdySessionActivityAttributes.self, from: JSONEncoder().encode(attributes))
        #expect(carried.cardKey == "made-up-key")
        let saved = BighelpActivitySessionInfo(attributes: attributes, title: "Lamb prices").withoutCardKey
        #expect(!String(decoding: try JSONEncoder().encode(saved), as: UTF8.self).contains("made-up-key"))
        #expect(saved.attributes.agentName == "Scout")
    }

    @Test func opensWhatTheComputerSealed() throws {
        let detail = try #require(BighelpActivityDetail.open(vector.sealed, timestamp: vector.timestamp, key: key))
        #expect(detail.started == 1_800_000_000)
        #expect(detail.steps == 9)
        #expect(detail.tool == "execute_code")
        #expect(detail.note == "price per lb")
        #expect(detail.trail == [.init(tool: "web_extract", count: 6, note: "example.com"),
                                 .init(tool: "web_search", count: 3, note: "protein powder prices")])
        #expect(detail.say == "Comparing four brands now.")
        #expect(detail.question == "Send the order for $47.00?")
        #expect(detail.preview == "Cheapest per lb is Northfield Whey at $9.40 — “four” brands compared.")
        #expect(detail.helperGoals == ["Check shipping costs"])
        #expect(detail.contextUsed == 30_300)
        #expect(detail.contextWindow == 272_000)
        #expect(detail.model == "sample-model-1")
    }

    @Test func opensNothingForAnotherTimeKeyOrRow() {
        #expect(BighelpActivityDetail.open(vector.sealed, timestamp: vector.timestamp + 1, key: key) == nil)
        #expect(BighelpActivityDetail.open(vector.sealed, timestamp: vector.timestamp, key: SymmetricKey(size: .bits256)) == nil)
        #expect(BighelpActivityDetail.open("not base64url!", timestamp: vector.timestamp, key: key) == nil)
        #expect(BighelpActivityDetail.open(String(repeating: "A", count: 1_201), timestamp: vector.timestamp, key: key) == nil)
        // Each chat row has its own key, so one chat's detail never opens as another's.
        let master = SymmetricKey(size: .bits256)
        let one = BighelpActivityCardKey.rowKey("native-one", master: master)
        let two = BighelpActivityCardKey.rowKey("native-two", master: master)
        #expect(one.withUnsafeBytes { Data($0) } != two.withUnsafeBytes { Data($0) })
        #expect(one.withUnsafeBytes { Data($0) } == BighelpActivityCardKey.rowKey("native-one", master: master).withUnsafeBytes { Data($0) })
    }

    @Test func aRowKeepsItsSealedBytesThroughThePushAndTheCardsOwnRewrite() throws {
        // What Apple hands the card: rows with and without detail, and a field this build doesn't know.
        let push = Data(#"""
        {"phase":"using_tool","currentAction":"","progress":0,"completedSteps":0,"activeSubagentCount":0,"latestTool":null,
         "timestamp":100,"activeCount":2,"activeRows":["a","b"],"groupId":"g","sessions":[
          {"id":"a","phase":"using_tool","timestamp":100,"activeSubagentCount":0,"sealed":"abc","later":1},
          {"id":"b","phase":"thinking","timestamp":90,"activeSubagentCount":0}]}
        """#.utf8)
        let state = try JSONDecoder().decode(LoopdySessionActivityAttributes.ContentState.self, from: push)
        #expect(state.sessions?.map(\.sealed) == ["abc", nil])
        // ActivityKit takes 4 KB: the rows shown first keep their detail, the rest draw their status.
        let rows = (0..<6).map { BighelpActivitySession(id: "row-\($0)", phase: .thinking, timestamp: 100) }.map { row in
            var row = row; row.sealed = String(repeating: "s", count: 1_000); return row
        }
        var rewritten = BighelpActivitySession.aggregate(rows, timestamp: 100)
        #expect(rewritten.sessions?.map { $0.sealed != nil } == [true, true, false, false, false])
        #expect(try JSONEncoder().encode(rewritten).count < 4_000)
        // The driver adds the rows the card doesn't show; detail gives way to them.
        rewritten.activeRows = (0..<64).map { String(format: "%016d", $0) }
        BighelpActivitySession.fitSealed(&rewritten)
        #expect(rewritten.sessions?.map { $0.sealed != nil } == [true, false, false, false, false])
        #expect(try JSONEncoder().encode(rewritten).count < 4_000)
    }

    @Test func wordsAStepFromItsToolName() {
        #expect(BighelpActivityStepWords.now("execute_code") == "Running code")
        #expect(BighelpActivityStepWords.now("mcp_something_new") == "Using a tool")
        #expect(BighelpActivityStepWords.done("web_extract", count: 6) == "Read 6 pages")
        #expect(BighelpActivityStepWords.done("web_search", count: 1) == "Searched the web")
        #expect(BighelpActivityStepWords.duration(141) == "2:21")
        #expect(BighelpActivityStepWords.duration(3_725) == "1:02:05")
        #expect(BighelpActivityStepWords.tokens(30_300) == "30k")
    }
}
