import Foundation

/// MetricKit's reports, turned into telemetry events. Everything here is plain
/// numbers, so it is tested without MetricKit. The mapping reads a fixed few
/// numeric fields and a call stack's addresses; it never reads a termination
/// reason, an exception reason, a virtual-memory description or any other
/// free text MetricKit offers.
enum TelemetryMetricMapping {
    struct Bucket: Equatable, Sendable {
        let startMs: Double
        let endMs: Double
        let count: Int
    }

    /// The bucket most launches fell in (its middle, in milliseconds) and how many launches there were.
    static func median(of buckets: [Bucket]) -> (medianMs: Int, samples: Int)? {
        let sorted = buckets.filter { $0.count > 0 && $0.startMs.isFinite && $0.endMs.isFinite }
            .sorted { $0.startMs < $1.startMs }
        let total = sorted.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        var seen = 0
        for bucket in sorted {
            seen += bucket.count
            if seen * 2 >= total {
                return (Int(((bucket.startMs + bucket.endMs) / 2).rounded()), total)
            }
        }
        return nil
    }

    static func launchEvent(kind: TelemetryLaunchKind, buckets: [Bucket]) -> TelemetryEvent? {
        guard let (medianMs, samples) = median(of: buckets) else { return nil }
        return .launch(kind: kind, medianMs: medianMs, samples: samples)
    }

    /// A call stack tree as MetricKit's JSON: stacks of root frames, each frame with sub-frames.
    /// The thread that crashed or hung comes first; its heaviest path is followed from the
    /// outermost caller to the innermost frame, and the innermost `maximum` frames are kept,
    /// innermost first.
    static func frames(fromCallStackTree data: Data, maximum: Int = TelemetryFrame.maximumPerEvent) -> [TelemetryFrame] {
        guard !data.isEmpty, data.count <= 4_194_304,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]] else { return [] }
        let stack = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        guard let roots = stack?["callStackRootFrames"] as? [[String: Any]] else { return [] }

        var path: [[String: Any]] = []
        var level = roots
        while path.count < 4_096, let next = level.max(by: { sampleCount($0) < sampleCount($1) }) {
            path.append(next)
            level = (next["subFrames"] as? [[String: Any]]) ?? []
        }
        return path.reversed().compactMap(frame).prefix(maximum).map { $0 }
    }

    private static func sampleCount(_ frame: [String: Any]) -> Int { (frame["sampleCount"] as? Int) ?? 0 }

    private static func frame(_ value: [String: Any]) -> TelemetryFrame? {
        guard let uuid = value["binaryUUID"] as? String,
              let offset = (value["offsetIntoBinaryTextSegment"] as? NSNumber).flatMap({ Int(exactly: $0.int64Value) })
        else { return nil }
        return TelemetryFrame(binaryUUID: uuid, offset: offset, name: plainBinaryName(value["binaryName"] as? String))
    }

    /// A binary's name as it is when it already looks like one (`A-Za-z0-9_.+-`, up to 64), else
    /// `unknown`. It isn't cleaned up: text that isn't a plain name is dropped whole, so a path or
    /// a sentence can't come through in pieces. The UUID and offset still say which binary it was.
    static func plainBinaryName(_ name: String?) -> String {
        guard let name, TelemetryFrame.isBinaryName(name) else { return "unknown" }
        return name
    }

    static func crashEvent(exceptionType: Int?, exceptionCode: Int?, signal: Int?, callStackTree: Data?) -> TelemetryEvent {
        .crash(exceptionType: exceptionType, exceptionCode: exceptionCode, signal: signal,
               frames: callStackTree.map { frames(fromCallStackTree: $0) } ?? [])
    }

    static func hangEvent(durationMs: Int?, callStackTree: Data?) -> TelemetryEvent {
        .hang(durationMs: durationMs, frames: callStackTree.map { frames(fromCallStackTree: $0) } ?? [])
    }
}
