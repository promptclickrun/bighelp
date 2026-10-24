import Foundation
import Testing
@testable import Bighelp

/// The app's allowlist against the ingestion contract's own file (`telemetry-v1.json`, copied from the
/// Worker's repo into `Fixtures/`). The Worker enforces it, the app mirrors it: when they differ, this fails.
struct TelemetryContractTests {
    private static var contract: [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/telemetry-v1.json")
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    }

    private typealias Spec = [String: [String: [String: Any]]]

    /// `events[source]` as name -> prop -> spec.
    private func events(_ source: String) throws -> Spec {
        let all = try #require(Self.contract["events"] as? [String: Any])
        let sourceEvents = try #require(all[source] as? [String: Any])
        var result: Spec = [:]
        for (name, value) in sourceEvents {
            let props = ((value as? [String: Any])?["props"] as? [String: Any]) ?? [:]
            result[name] = props.compactMapValues { $0 as? [String: Any] }
        }
        return result
    }

    /// What the Swift side can send, as name -> prop -> the wire values seen.
    private func swiftEvents(source: TelemetrySource) -> [String: [String: [TelemetryWireEvent.Value]]] {
        var result: [String: [String: [TelemetryWireEvent.Value]]] = [:]
        for event in TelemetryEncodingTests.everyEvent where event.source == source {
            let wire = TelemetryWireEvent(event, timeMilliseconds: 1)
            for (key, value) in wire.props { result[wire.name, default: [:]][key, default: []].append(value) }
            if wire.props.isEmpty { result[wire.name, default: [:]] = result[wire.name] ?? [:] }
        }
        return result
    }

    @Test(arguments: [("app", TelemetrySource.app), ("nse", TelemetrySource.nse)])
    func theEventNamesAndPropsMatchTheContract(name: String, source: TelemetrySource) throws {
        let spec = try events(name)
        let mine = swiftEvents(source: source)
        #expect(Set(mine.keys) == Set(spec.keys), "\(name): event names differ")
        for (event, props) in spec {
            let sent = mine[event] ?? [:]
            #expect(Set(sent.keys) == Set(props.keys), "\(event): props differ")
            for (key, prop) in props {
                let type = prop["type"] as? String
                for value in sent[key] ?? [] {
                    switch (type, value) {
                    case ("bool", .bool): break
                    case ("ms", .integer(let number)): #expect((0...86_400_000).contains(number), "\(event).\(key)")
                    case ("count", .integer(let number)): #expect((0...100_000).contains(number), "\(event).\(key)")
                    case ("enum", .code(let code)):
                        let allowed = (prop["values"] as? [String]) ?? []
                        #expect(allowed.contains(code), "\(event).\(key)=\(code)")
                    case ("frames", .frames): break
                    default: Issue.record("\(event).\(key) is \(type ?? "?") in the contract but \(value) here")
                    }
                }
            }
        }
    }

    @Test func requiredPropsAreAlwaysSent() throws {
        for (source, swift) in [("app", TelemetrySource.app), ("nse", .nse)] {
            for (event, props) in try events(source) {
                for (key, prop) in props where (prop["required"] as? Bool) == true {
                    for sent in TelemetryEncodingTests.everyEvent where sent.source == swift {
                        let wire = TelemetryWireEvent(sent, timeMilliseconds: 1)
                        if wire.name == event { #expect(wire.props[key] != nil, "\(event) must always carry \(key)") }
                    }
                }
            }
        }
    }

    @Test func theEnumsHaveExactlyTheContractsValues() throws {
        let spec = try events("app")
        func values(_ event: String, _ key: String) -> Set<String> {
            Set((spec[event]?[key]?["values"] as? [String]) ?? [])
        }
        #expect(Set(TelemetryFeature.allCases.map(\.rawValue)) == values("feature.used", "feature"))
        #expect(Set(TelemetryLaunchKind.allCases.map(\.rawValue)) == values("perf.launch", "kind"))
        #expect(Set(TelemetryOutcome.allCases.map(\.rawValue)) == values("perf.reconnect", "outcome"))
        let nse = try events("nse")
        #expect(Set(TelemetryNotificationKind.allCases.map(\.rawValue)) == Set((nse["notification.received"]?["kind"]?["values"] as? [String]) ?? []))
        #expect(Set(TelemetryNotificationPath.allCases.map(\.rawValue)) == Set((nse["notification.received"]?["path"]?["values"] as? [String]) ?? []))
    }

    @Test func theLimitsAndTypesMatch() throws {
        let limits = try #require(Self.contract["limits"] as? [String: Int])
        #expect(limits["maxEvents"] == TelemetryBatchEncoder.maximumEvents)
        #expect(limits["maxFrames"] == TelemetryFrame.maximumPerEvent)
        #expect(limits["maxFramesJsonChars"] == TelemetryBatchEncoder.maximumFramesJSONCharacters)
        #expect(limits["minEvents"] == 1)
        #expect((limits["maxWireBytes"] ?? 0) >= TelemetryBatchEncoder.maximumWireBytes)
        #expect((limits["maxDecompressedBytes"] ?? 0) >= TelemetryBatchEncoder.maximumBodyBytes)
        let types = try #require(Self.contract["types"] as? [String: [String: Any]])
        #expect(types["ms"]?["max"] as? Int == TelemetryWireEvent.maximumMilliseconds)
        #expect(types["count"]?["max"] as? Int == TelemetryWireEvent.maximumCount)
        // The frame entry's name pattern, and the binary id's, accept what the Swift side accepts and refuse what it refuses.
        let entry = try #require((types["frames"]?["entry"]) as? [String: Any])
        let namePattern = try #require((entry["n"] as? [String: Any])?["pattern"] as? String)
        for name in ["Bighelp", "libswiftCore.dylib", "a+b-c_d.e"] {
            #expect(name.range(of: namePattern, options: .regularExpression) != nil && TelemetryFrame.isBinaryName(name))
        }
        for name in ["", "my app", "/Users/x", String(repeating: "a", count: 65)] {
            #expect(name.range(of: namePattern, options: .regularExpression) == nil && !TelemetryFrame.isBinaryName(name))
        }
        let uuidPattern = try #require((types["hexuuid"])?["pattern"] as? String)
        for value in ["3F2A9C1E-5B7D-4E8F-9A10-2C4D6E8F0A1B", "3f2a9c1e5b7d4e8f9a102c4d6e8f0a1b"] {
            #expect(value.range(of: uuidPattern, options: .regularExpression) != nil && TelemetryFrame.isHexUUID(value))
        }
        #expect(!TelemetryFrame.isHexUUID("short") && "short".range(of: uuidPattern, options: .regularExpression) == nil)
        let uuid = try #require(types["uuid"]?["pattern"] as? String)
        #expect(TelemetryBatchEncoder.newID().range(of: uuid, options: .regularExpression) != nil)
    }

    @Test func theContextMatchesForBothSources() throws {
        let context = try #require(Self.contract["context"] as? [String: [String: [String: Any]]])
        let sample = TelemetryContext.test.wire
        for source in ["app", "nse"] {
            let spec = try #require(context[source])
            #expect(Set(sample.keys) == Set(spec.keys), "\(source): context keys differ")
            for (key, value) in sample {
                let rule = try #require(spec[key])
                if (rule["type"] as? String) == "enum" {
                    #expect(((rule["values"] as? [String]) ?? []).contains(value), "\(source).\(key)=\(value)")
                }
            }
            let enums = { (key: String) in Set((spec[key]?["values"] as? [String]) ?? []) }
            #expect(Set(["debug", "testflight", "appstore"]) == enums("channel"))
            #expect(Set(["iOS", "iPadOS", "macOS", "visionOS", "watchOS"]) == enums("os"))
            #expect(Set(["iPhone", "iPad", "Mac", "Vision", "Watch"]) == enums("deviceClass"))
        }
        #expect(Set(TelemetryChannel.allCases.map(\.rawValue)) == ["debug", "testflight", "appstore"])
        #expect(["app", "nse", "host"] == (Self.contract["publicSources"] as? [String]))
        #expect(Set(TelemetrySource.allCases.map(\.rawValue)) == ["app", "nse"])
    }
}
