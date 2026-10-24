import Foundation

/// Builds the body of `POST /v1/batch` (contract §3): the envelope, 1 to 50
/// events, JSON, gzip when it's smaller. It writes only what `TelemetryWireEvent`
/// and `TelemetryContext` hold, so there is nothing else to leak.
enum TelemetryBatchEncoder {
    static let maximumEvents = 50
    /// The Worker refuses more than 256 KiB once unzipped and 64 KiB on the wire.
    static let maximumBodyBytes = 200_000
    static let maximumWireBytes = 60_000
    /// Below this, gzip's own overhead isn't worth it.
    static let gzipThreshold = 1_024

    struct Body: Equatable, Sendable {
        let data: Data
        let isGzip: Bool
        let eventCount: Int
    }

    /// Lowercase UUID v4, the form the Worker takes for `id` and `session`.
    static func isUUIDv4(_ value: String) -> Bool {
        guard value.utf8.count == 36, value == value.lowercased(), let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value && Array(value)[14] == "4" && "89ab".contains(Array(value)[19])
    }

    static func newID() -> String { UUID().uuidString.lowercased() }

    /// The Worker takes `frames` as at most 64 entries and 8,192 characters of compact JSON. Outermost
    /// frames (the end of the list) are dropped until it fits; the innermost, nearest the fault, stay.
    static let maximumFramesJSONCharacters = 8_192

    static func fittingFrames(_ frames: [TelemetryFrame]) -> [[String: Any]] {
        var kept = frames.prefix(TelemetryFrame.maximumPerEvent).map {
            ["b": $0.binaryUUID, "o": $0.offset, "n": $0.name] as [String: Any]
        }
        while !kept.isEmpty {
            let size = (try? JSONSerialization.data(withJSONObject: kept).count) ?? Int.max
            if size <= maximumFramesJSONCharacters { break }
            kept.removeLast()
        }
        return kept
    }

    static func object(_ event: TelemetryWireEvent) -> [String: Any] {
        var props: [String: Any] = [:]
        for (key, value) in event.props {
            switch value {
            case .bool(let flag): props[key] = flag
            case .integer(let number): props[key] = number
            case .code(let code): props[key] = code
            case .frames(let frames):
                props[key] = fittingFrames(frames)
            }
        }
        return ["name": event.name, "t": event.time, "p": props]
    }

    /// The batch as JSON, or nil when the id or session isn't a UUID or there are no events.
    static func json(source: TelemetrySource, id: String, session: String?, context: TelemetryContext,
                     events: [TelemetryWireEvent]) -> Data? {
        guard isUUIDv4(id), session.map(isUUIDv4) ?? true,
              (1...maximumEvents).contains(events.count) else { return nil }
        var envelope: [String: Any] = [
            "version": 1, "source": source.rawValue, "id": id,
            "context": context.wire, "events": events.map(object),
        ]
        if let session { envelope["session"] = session }
        return try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    static func body(source: TelemetrySource, id: String, session: String?, context: TelemetryContext,
                     events: [TelemetryWireEvent]) -> Body? {
        guard let data = json(source: source, id: id, session: session, context: context, events: events) else { return nil }
        if data.count > gzipThreshold, let zipped = TelemetryGzip.compress(data), zipped.count < data.count {
            guard zipped.count <= maximumWireBytes else { return nil }
            return Body(data: zipped, isGzip: true, eventCount: events.count)
        }
        guard data.count <= maximumWireBytes else { return nil }
        return Body(data: data, isGzip: false, eventCount: events.count)
    }

    /// How many of the first events fit one batch: at most 50, all one source, and
    /// small enough for the Worker's limits (events with long stacks are big).
    static func fit(_ events: [TelemetryRecord], source: TelemetrySource) -> Int {
        var size = 600
        var count = 0
        for record in events {
            guard record.event.source == source, count < maximumEvents else { break }
            let bytes = (try? JSONSerialization.data(withJSONObject: object(record.wire)).count) ?? maximumBodyBytes
            if count > 0, size + bytes > maximumBodyBytes { break }
            size += bytes + 1
            count += 1
        }
        return count
    }
}
