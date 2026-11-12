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
        let rewritten = BighelpActivitySession.aggregate(rows, timestamp: 100)
        #expect(rewritten.sessions?.map { $0.sealed != nil } == [true, true, false, false, false])
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
