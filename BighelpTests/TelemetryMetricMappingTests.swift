import Foundation
import Testing
@testable import Bighelp

struct TelemetryMetricMappingTests {
    private typealias Bucket = TelemetryMetricMapping.Bucket

    @Test func theMedianBucketAndTheSampleCount() throws {
        let buckets = [Bucket(startMs: 0, endMs: 100, count: 3), Bucket(startMs: 100, endMs: 200, count: 4),
                       Bucket(startMs: 200, endMs: 400, count: 5), Bucket(startMs: 400, endMs: 800, count: 2)]
        let result = try #require(TelemetryMetricMapping.median(of: buckets))
        #expect(result.samples == 14)
        #expect(result.medianMs == 150, "7 of 14 launches were 200 ms or less; the middle of that bucket")
        // Order and empty buckets don't matter.
        let shuffled = (buckets + [Bucket(startMs: 800, endMs: 900, count: 0)]).reversed().map { $0 }
        #expect(TelemetryMetricMapping.median(of: shuffled)?.medianMs == 150)
        #expect(TelemetryMetricMapping.median(of: []) == nil)
        #expect(TelemetryMetricMapping.median(of: [Bucket(startMs: 0, endMs: 10, count: 0)]) == nil)
        #expect(TelemetryMetricMapping.median(of: [Bucket(startMs: .nan, endMs: 10, count: 4)]) == nil)
    }

    @Test func aLaunchEventHasTheKindTheMedianAndTheCount() {
        let event = TelemetryMetricMapping.launchEvent(kind: .resume, buckets: [Bucket(startMs: 100, endMs: 300, count: 9)])
        #expect(event == .launch(kind: .resume, medianMs: 200, samples: 9))
        #expect(TelemetryMetricMapping.launchEvent(kind: .firstDraw, buckets: []) == nil)
    }

    /// The shape MetricKit's `jsonRepresentation()` has, with text a real report would never be
    /// trusted to keep clean.
    private func tree(frames: Int, attributedFirst: Bool = true) -> Data {
        func chain(_ depth: Int, prefix: String) -> [String: Any] {
            var frame: [String: Any] = [
                "binaryUUID": "3F2A9C1E-5B7D-4E8F-9A10-2C4D6E8F0A1B", "offsetIntoBinaryTextSegment": depth * 16,
                "sampleCount": 1, "binaryName": "Bighelp", "address": 4_300_000_000 + depth,
            ]
            if depth + 1 < frames { frame["subFrames"] = [chain(depth + 1, prefix: prefix)] }
            return frame
        }
        let attributed: [String: Any] = ["threadAttributed": true, "callStackRootFrames": [chain(0, prefix: "a")]]
        let other: [String: Any] = ["threadAttributed": false, "callStackRootFrames": [[
            "binaryUUID": "aaaaaaaabbbbccccddddeeeeeeeeeeee", "offsetIntoBinaryTextSegment": 7, "binaryName": "UIKitCore",
        ]]]
        let object: [String: Any] = ["callStacks": attributedFirst ? [other, attributed] : [attributed, other],
                                     "callStackPerThread": false]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func aCrashStackKeepsTheInnermostSixtyFourFramesFirst() throws {
        let frames = TelemetryMetricMapping.frames(fromCallStackTree: tree(frames: 100))
        #expect(frames.count == 64)
        #expect(frames.first?.offset == 99 * 16, "innermost frame first")
        #expect(frames.last?.offset == 36 * 16)
        #expect(frames.allSatisfy { $0.name == "Bighelp" && $0.binaryUUID == "3f2a9c1e-5b7d-4e8f-9a10-2c4d6e8f0a1b" })
    }

    @Test func theThreadThatCrashedIsTheOneUsed() {
        for first in [true, false] {
            let frames = TelemetryMetricMapping.frames(fromCallStackTree: tree(frames: 3, attributedFirst: first))
            #expect(frames.map(\.offset) == [32, 16, 0])
        }
    }

    @Test func aHangTreeFollowsTheHeaviestPath() throws {
        func frame(_ name: String, _ samples: Int, _ offset: Int, _ sub: [[String: Any]] = []) -> [String: Any] {
            ["binaryUUID": "3F2A9C1E-5B7D-4E8F-9A10-2C4D6E8F0A1B", "offsetIntoBinaryTextSegment": offset,
             "sampleCount": samples, "binaryName": name, "subFrames": sub]
        }
        let root = frame("start", 10, 1, [frame("light", 2, 2), frame("heavy", 8, 3, [frame("leaf", 8, 4)])])
        let data = try JSONSerialization.data(withJSONObject: [
            "callStacks": [["threadAttributed": true, "callStackRootFrames": [root]]]])
        #expect(TelemetryMetricMapping.frames(fromCallStackTree: data).map(\.name) == ["leaf", "heavy", "start"])
    }

    @Test func textInAReportNeverReachesTheEvent() throws {
        let hostile: [String: Any] = [
            "callStacks": [["threadAttributed": true, "callStackRootFrames": [[
                "binaryUUID": "3F2A9C1E-5B7D-4E8F-9A10-2C4D6E8F0A1B", "offsetIntoBinaryTextSegment": 8,
                "binaryName": "/Users/alice/Documents/secret plan.pdf", "address": 1,
                "terminationReason": "Alice's message: my password is hunter2",
                "exceptionReason": "NSInvalidArgumentException, Alice's chat text",
                "subFrames": [[
                    "binaryUUID": "not a uuid, Alice", "offsetIntoBinaryTextSegment": 9, "binaryName": "Bighelp",
                ], [
                    "binaryUUID": "3F2A9C1E-5B7D-4E8F-9A10-2C4D6E8F0A1B", "offsetIntoBinaryTextSegment": "Alice",
                    "binaryName": "Bighelp",
                ]],
            ]]]],
            "terminationReason": "Alice's message: my password is hunter2",
        ]
        let data = try JSONSerialization.data(withJSONObject: hostile)
        let event = TelemetryMetricMapping.crashEvent(exceptionType: 1, exceptionCode: 2, signal: 6, callStackTree: data)
        let wire = TelemetryWireEvent(event, timeMilliseconds: 1)
        let object = TelemetryBatchEncoder.object(wire)
        let text = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8) ?? ""
        for secret in ["Alice", "hunter2", "/Users", "secret plan", "password", "NSInvalid", "terminationReason"] {
            #expect(!text.contains(secret), "\(secret) got into the event")
        }
        // The one frame with a real UUID and offset stays; its name was not a plain name, so it is dropped.
        guard case .crash(_, _, _, let frames) = event else { Issue.record("not a crash"); return }
        #expect(frames.count == 1)
        #expect(frames[0].name == "unknown" && frames[0].offset == 8)
    }

    @Test func onlyPlainBinaryNamesSurvive() {
        #expect(TelemetryMetricMapping.plainBinaryName("libswiftCore.dylib") == "libswiftCore.dylib")
        #expect(TelemetryMetricMapping.plainBinaryName("Bighelp") == "Bighelp")
        for name in ["my app", "/Users/alice/notes", "secret plan.pdf", "", nil, String(repeating: "a", count: 65), "naïve"] {
            #expect(TelemetryMetricMapping.plainBinaryName(name) == "unknown")
        }
    }

    @Test func badOrHugeTreesGiveNoFramesAndNoCrash() {
        #expect(TelemetryMetricMapping.frames(fromCallStackTree: Data()).isEmpty)
        #expect(TelemetryMetricMapping.frames(fromCallStackTree: Data("not json".utf8)).isEmpty)
        #expect(TelemetryMetricMapping.frames(fromCallStackTree: Data("{}".utf8)).isEmpty)
        #expect(TelemetryMetricMapping.frames(fromCallStackTree: Data(count: 5_000_000)).isEmpty)
    }

    @Test func crashAndHangEventsCarryOnlyNumbersAndFrames() {
        let crash = TelemetryMetricMapping.crashEvent(exceptionType: 1, exceptionCode: 2, signal: 11, callStackTree: nil)
        #expect(crash == .crash(exceptionType: 1, exceptionCode: 2, signal: 11, frames: []))
        let hang = TelemetryMetricMapping.hangEvent(durationMs: 4_200, callStackTree: tree(frames: 2))
        guard case .hang(let duration, let frames) = hang else { Issue.record("not a hang"); return }
        #expect(duration == 4_200 && frames.count == 2)
    }
}
