import Foundation
import Testing
@testable import Bighelp

/// The batch the app sends is checked against the ingestion contract's `app` and `nse` allowlists
/// (CONTRACTS.md §3): only these names, only these keys, only valid values.
struct TelemetryEncodingTests {
    /// Event name to the props it may carry.
    static let allowedProps: [String: Set<String>] = [
        "app.opened": ["coldStart"],
        "app.backgrounded": ["foregroundMs"],
        "session.ended": ["durationMs"],
        "feature.used": ["feature"],
        "perf.launch": ["kind", "medianMs", "samples"],
        "perf.first_token_ms": ["ms"],
        "perf.reconnect": ["ms", "attempts", "outcome"],
        "hang": ["durationMs", "frames"],
        "crash": ["exceptionType", "exceptionCode", "signal", "frames"],
        "telemetry.toggled": ["enabled"],
        "notification.received": ["kind", "path", "delayMs", "hostToPhoneMs"],
    ]
    static let msKeys: Set<String> = ["foregroundMs", "durationMs", "medianMs", "ms", "delayMs", "hostToPhoneMs"]
    static let countKeys: Set<String> = ["samples", "attempts", "exceptionType", "exceptionCode", "signal"]
    static let enums: [String: Set<String>] = [
        "feature": ["chat_sent", "card_rendered", "form_submitted", "voice_turn", "voice_live", "workflow_run",
                    "mode_switched", "agent_opened", "file_opened", "shortcut_run", "widget_opened",
                    "carplay_voice", "watch_chat", "notification_opened"],
        "kind": ["first_draw", "resume", "optimized_first_draw", "alert", "wake"],
        "outcome": ["ok", "failed"],
        "path": ["direct", "buzzkit", "unknown"],
    ]
    static let contextKeys: Set<String> = ["appVersion", "build", "os", "osVersion", "deviceClass", "channel"]

    static var frames: [TelemetryFrame] {
        [TelemetryFrame(binaryUUID: "3F2A9C1E-5B7D-4E8F-9A10-2C4D6E8F0A1B", offset: 4_096, name: "Bighelp")!,
         TelemetryFrame(binaryUUID: "aaaaaaaabbbbccccddddeeeeeeeeeeee", offset: 0, name: "libsystem_kernel.dylib")!]
    }

    /// One of every event the app can make.
    static var everyEvent: [TelemetryEvent] {
        var events: [TelemetryEvent] = [
            .appOpened(coldStart: true), .appOpened(coldStart: false), .appBackgrounded(foregroundMs: 42_000),
            .sessionEnded(durationMs: 600_000), .firstToken(ms: 850), .toggled(enabled: true),
            .reconnect(ms: 1_200, attempts: 2, outcome: .ok), .reconnect(ms: nil, attempts: nil, outcome: .failed),
            .hang(durationMs: 2_500, frames: frames), .crash(exceptionType: 1, exceptionCode: 2, signal: 11, frames: frames),
            .crash(exceptionType: nil, exceptionCode: nil, signal: nil, frames: []),
        ]
        events += TelemetryFeature.allCases.map(TelemetryEvent.featureUsed)
        events += TelemetryLaunchKind.allCases.map { .launch(kind: $0, medianMs: 700, samples: 12) }
        for kind in TelemetryNotificationKind.allCases {
            for path in TelemetryNotificationPath.allCases {
                events.append(.notificationReceived(kind: kind, path: path, delayMs: 1_800, hostToPhoneMs: 2_400))
            }
        }
        return events
    }

    @Test func everyEventUsesOnlyAllowlistedNamesKeysAndValues() throws {
        for event in Self.everyEvent {
            let wire = TelemetryWireEvent(event, timeMilliseconds: 1_800_000_000_000)
            let allowed = try #require(Self.allowedProps[wire.name], "\(wire.name) is not on the allowlist")
            #expect(Set(wire.props.keys).isSubset(of: allowed), "\(wire.name) has a key off the allowlist")
            for (key, value) in wire.props {
                switch value {
                case .bool: #expect(["coldStart", "enabled"].contains(key))
                case .integer(let number):
                    if Self.msKeys.contains(key) { #expect((0...86_400_000).contains(number)) }
                    else { #expect(Self.countKeys.contains(key) && (0...100_000).contains(number)) }
                case .code(let code):
                    #expect(Self.enums[key]?.contains(code) == true, "\(key)=\(code) is not an allowed value")
                case .frames(let frames):
                    #expect(key == "frames" && frames.count <= 64)
                }
            }
            if wire.name == "feature.used" { #expect(wire.props["feature"] != nil) }
            if wire.name == "perf.launch" || wire.name == "notification.received" { #expect(wire.props["kind"] != nil) }
            if wire.name == "perf.first_token_ms" { #expect(wire.props["ms"] != nil) }
        }
    }

    @Test func theTwoSourcesAreSeparate() {
        #expect(TelemetryEvent.appOpened(coldStart: true).source == .app)
        #expect(TelemetryEvent.featureUsed(.chatSent).source == .app)
        #expect(TelemetryEvent.notificationReceived(kind: .alert, path: .direct, delayMs: 1, hostToPhoneMs: 2).source == .nse)
    }

    @Test func theBatchEnvelopeMatchesTheContract() throws {
        let id = TelemetryBatchEncoder.newID(), session = TelemetryBatchEncoder.newID()
        let events = Self.everyEvent.map { TelemetryWireEvent($0, timeMilliseconds: 1_800_000_000_000) }
        let data = try #require(TelemetryBatchEncoder.json(source: .app, id: id, session: session, context: .test,
                                                           events: events))
        let batch = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(batch.keys) == ["version", "source", "id", "session", "context", "events"])
        #expect(batch["version"] as? Int == 1)
        #expect(batch["source"] as? String == "app")
        #expect(TelemetryBatchEncoder.isUUIDv4(try #require(batch["id"] as? String)))
        #expect(TelemetryBatchEncoder.isUUIDv4(try #require(batch["session"] as? String)))
        let context = try #require(batch["context"] as? [String: String])
        #expect(Set(context.keys).isSubset(of: Self.contextKeys))
        #expect(context["os"] == "iOS" && context["deviceClass"] == "iPhone" && context["channel"] == "testflight")
        let sent = try #require(batch["events"] as? [[String: Any]])
        #expect(sent.count == events.count && sent.count <= 50)
        for event in sent {
            #expect(Set(event.keys) == ["name", "t", "p"])
            #expect(event["t"] is Int || event["t"] is Int64)
            #expect(Self.allowedProps[try #require(event["name"] as? String)] != nil)
        }
    }

    @Test func aBatchNeedsAValidIDOneToFiftyEventsAndOptionalSession() {
        let id = TelemetryBatchEncoder.newID()
        let one = [TelemetryWireEvent(.appOpened(coldStart: true), timeMilliseconds: 1)]
        #expect(TelemetryBatchEncoder.json(source: .app, id: id, session: nil, context: .test, events: one) != nil)
        #expect(TelemetryBatchEncoder.json(source: .app, id: id, session: nil, context: .test, events: []) == nil)
        #expect(TelemetryBatchEncoder.json(source: .app, id: id, session: nil, context: .test,
                                           events: Array(repeating: one[0], count: 51)) == nil)
        for bad in ["", "not-a-uuid", id.uppercased(), "11111111-1111-1111-8111-111111111111", "Alice's phone"] {
            #expect(TelemetryBatchEncoder.json(source: .app, id: bad, session: nil, context: .test, events: one) == nil)
            #expect(TelemetryBatchEncoder.json(source: .app, id: id, session: bad, context: .test, events: one) == nil)
        }
    }

    @Test func contextValuesThatFailTheirPatternAreLeftOut() {
        let context = TelemetryContext(appVersion: "Alice's beta", build: "build 12", os: "iOS", osVersion: "26.5.1",
                                       deviceClass: "iPhone", channel: .debug)
        #expect(context.wire == ["os": "iOS", "osVersion": "26.5.1", "deviceClass": "iPhone", "channel": "debug"])
        #expect(TelemetryContext.isVersion("2.6.19") && TelemetryContext.isVersion("26") && TelemetryContext.isVersion("1.2.3.4"))
        #expect(!TelemetryContext.isVersion("1.2.3.4.5") && !TelemetryContext.isVersion("1..2") && !TelemetryContext.isVersion("12345"))
        #expect(!TelemetryContext.isVersion("2.6.19-beta") && !TelemetryContext.isVersion(""))
        #expect(TelemetryContext.isBuild("159") && !TelemetryContext.isBuild("12345678") && !TelemetryContext.isBuild("1a"))
    }

    @Test func theChannelComesFromTheBuildAndTheReceipt() {
        #expect(TelemetryContext.channel(receiptName: "sandboxReceipt", isDebugBuild: true) == .debug)
        #expect(TelemetryContext.channel(receiptName: "sandboxReceipt", isDebugBuild: false) == .testflight)
        #expect(TelemetryContext.channel(receiptName: "receipt", isDebugBuild: false) == .appstore)
        #expect(TelemetryContext.channel(receiptName: nil, isDebugBuild: false) == .appstore)
    }

    @Test func numbersOutsideTheirRangeAreClampedOrLeftOut() {
        let wire = TelemetryWireEvent(.appBackgrounded(foregroundMs: -5), timeMilliseconds: 1)
        #expect(wire.props["foregroundMs"] == .integer(0))
        #expect(TelemetryWireEvent(.firstToken(ms: 9_999_999_999), timeMilliseconds: 1).props["ms"] == .integer(86_400_000))
        #expect(TelemetryWireEvent(.launch(kind: .resume, medianMs: 5, samples: 5_000_000), timeMilliseconds: 1)
            .props["samples"] == .integer(100_000))
        // A crash code that doesn't fit is dropped, not squeezed into a wrong number.
        let crash = TelemetryWireEvent(.crash(exceptionType: 1, exceptionCode: 0x8badf00d, signal: -1, frames: []),
                                       timeMilliseconds: 1)
        #expect(crash.props["exceptionType"] == .integer(1))
        #expect(crash.props["exceptionCode"] == nil && crash.props["signal"] == nil)
    }

    @Test func framesNeedAHexBinaryIDAPlainNameAndAnOffset() {
        #expect(TelemetryFrame(binaryUUID: "3F2A9C1E-5B7D-4E8F-9A10-2C4D6E8F0A1B", offset: 1, name: "Bighelp") != nil)
        #expect(TelemetryFrame(binaryUUID: "3f2a9c1e5b7d4e8f9a102c4d6e8f0a1b", offset: 0, name: "UIKitCore") != nil)
        #expect(TelemetryFrame(binaryUUID: "3F2A9C1E-5B7D-4E8F-9A10-2C4D6E8F0A1B", offset: -1, name: "X") == nil)
        #expect(TelemetryFrame(binaryUUID: "short", offset: 1, name: "X") == nil)
        #expect(TelemetryFrame(binaryUUID: "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", offset: 1, name: "X") == nil)
        for name in ["", "my secret file.pdf", "/Users/alice/notes", String(repeating: "a", count: 65), "naïve"] {
            #expect(TelemetryFrame(binaryUUID: "3F2A9C1E-5B7D-4E8F-9A10-2C4D6E8F0A1B", offset: 1, name: name) == nil)
        }
        let uuid = TelemetryFrame(binaryUUID: "3F2A9C1E-5B7D-4E8F-9A10-2C4D6E8F0A1B", offset: 1, name: "X")
        #expect(uuid?.binaryUUID == "3f2a9c1e-5b7d-4e8f-9a10-2c4d6e8f0a1b")
    }

    @Test func anEventCarriesAtMostSixtyFourFrames() throws {
        let many = (0..<100).compactMap { TelemetryFrame(binaryUUID: "3F2A9C1E-5B7D-4E8F-9A10-2C4D6E8F0A1B", offset: $0, name: "Bighelp") }
        let wire = TelemetryWireEvent(.hang(durationMs: 3_000, frames: many), timeMilliseconds: 1)
        guard case .frames(let kept)? = wire.props["frames"] else { Issue.record("no frames"); return }
        #expect(kept.count == 64)
        let object = TelemetryBatchEncoder.object(wire)
        let props = try #require(object["p"] as? [String: Any])
        let encoded = try #require(props["frames"] as? [[String: Any]])
        #expect(encoded.count == 64)
        #expect(Set(try #require(encoded.first).keys) == ["b", "o", "n"])
    }

    @Test func frameListsAreCutToTheWorkersEightKilobyteLimit() throws {
        // 64 frames with long names and big offsets are about 9,600 characters of JSON.
        let long = String(repeating: "n", count: 64)
        let frames = (0..<64).compactMap {
            TelemetryFrame(binaryUUID: "3F2A9C1E-5B7D-4E8F-9A10-2C4D6E8F0A1B", offset: 4_000_000_000 + $0, name: long)
        }
        #expect(frames.count == 64)
        let wire = TelemetryWireEvent(.crash(exceptionType: 1, exceptionCode: 2, signal: 6, frames: frames), timeMilliseconds: 1)
        let object = TelemetryBatchEncoder.object(wire)
        let kept = try #require((object["p"] as? [String: Any])?["frames"] as? [[String: Any]])
        let json = try JSONSerialization.data(withJSONObject: kept)
        #expect(json.count <= 8_192)
        #expect(kept.count < 64 && kept.count > 40)
        #expect(kept.first?["o"] as? Int == 4_000_000_000, "the innermost frame stays; the outermost go first")
        // A list that already fits is left whole.
        let small = TelemetryBatchEncoder.fittingFrames(Self.frames)
        #expect(small.count == 2)
        // The whole batch carrying it still encodes.
        #expect(TelemetryBatchEncoder.body(source: .app, id: TelemetryBatchEncoder.newID(), session: nil, context: .test,
                                           events: [wire]) != nil)
    }

    @Test func aBodyOverAKilobyteIsGzippedWhenThatIsSmaller() throws {
        let id = TelemetryBatchEncoder.newID()
        let events = (0..<50).map { _ in TelemetryWireEvent(.featureUsed(.chatSent), timeMilliseconds: 1_800_000_000_000) }
        let big = try #require(TelemetryBatchEncoder.body(source: .app, id: id, session: nil, context: .test, events: events))
        #expect(big.isGzip && big.eventCount == 50)
        #expect(big.data.prefix(2) == Data([0x1f, 0x8b]))
        let plain = try #require(TelemetryBatchEncoder.json(source: .app, id: id, session: nil, context: .test, events: events))
        #expect(big.data.count < plain.count)
        #expect(TelemetryGzip.decompress(big.data) == plain)

        let small = try #require(TelemetryBatchEncoder.body(source: .app, id: id, session: nil, context: .test,
                                                            events: [events[0]]))
        #expect(!small.isGzip)
        #expect((try? JSONSerialization.jsonObject(with: small.data)) != nil)
    }

    @Test func gzipSurvivesARoundTripAndRejectsDamage() throws {
        let text = Data(String(repeating: "bighelp telemetry ", count: 400).utf8)
        let zipped = try #require(TelemetryGzip.compress(text))
        #expect(TelemetryGzip.decompress(zipped) == text)
        var damaged = zipped
        damaged[damaged.count - 6] ^= 0xff
        #expect(TelemetryGzip.decompress(damaged) == nil)
        #expect(TelemetryGzip.compress(Data()) == nil)
        #expect(TelemetryGzip.crc32(Data("123456789".utf8)) == 0xcbf4_3926)
    }

    @Test func eventsFitOneSourceAtATimeAndUnderTheSizeLimit() {
        let app = TelemetryRecord(.appOpened(coldStart: true), at: Date())
        let nse = TelemetryRecord(.notificationReceived(kind: .alert, path: .direct, delayMs: 1, hostToPhoneMs: 1), at: Date())
        #expect(TelemetryBatchEncoder.fit([app, app, nse, app], source: .app) == 2)
        #expect(TelemetryBatchEncoder.fit([nse, app], source: .nse) == 1)
        #expect(TelemetryBatchEncoder.fit(Array(repeating: app, count: 80), source: .app) == 50)
        let frames = (0..<64).compactMap { TelemetryFrame(binaryUUID: "3F2A9C1E-5B7D-4E8F-9A10-2C4D6E8F0A1B", offset: $0, name: "Bighelp") }
        let heavy = TelemetryRecord(.crash(exceptionType: 1, exceptionCode: 1, signal: 6, frames: frames), at: Date())
        let fitted = TelemetryBatchEncoder.fit(Array(repeating: heavy, count: 50), source: .app)
        #expect(fitted >= 1 && fitted <= 50)
    }

    @Test func eventsSurviveTheDiskCopy() throws {
        let records = Self.everyEvent.map { TelemetryRecord($0, at: Date(timeIntervalSince1970: 1_800_000_000)) }
        let data = try JSONEncoder().encode(records)
        #expect(try JSONDecoder().decode([TelemetryRecord].self, from: data) == records)
        // A saved frame that no longer passes is refused.
        let hang = [TelemetryRecord(.hang(durationMs: 1, frames: Self.frames), at: Date())]
        let text = try #require(String(data: try JSONEncoder().encode(hang), encoding: .utf8))
        #expect(text.contains("Bighelp"))
        let tampered = Data(text.replacingOccurrences(of: "Bighelp", with: "my secret file").utf8)
        #expect((try? JSONDecoder().decode([TelemetryRecord].self, from: tampered)) == nil)
    }
}
