import Foundation
#if canImport(MetricKit)
import MetricKit

/// MetricKit only, no third-party SDK. iOS hands over launch histograms and
/// crash and hang reports up to a day after they happened, without symbols.
/// The call stacks go as binary UUIDs and offsets, so a dSYM can name them later.
final class TelemetryMetricKit: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = TelemetryMetricKit()
    private var isSubscribed = false

    /// Starts listening, only when this run may send telemetry.
    func start() {
        guard Telemetry.isActive, !isSubscribed else { return }
        isSubscribed = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let launch = payload.applicationLaunchMetrics else { continue }
            let when = payload.timeStampEnd
            for (kind, histogram) in [
                (TelemetryLaunchKind.firstDraw, launch.histogrammedTimeToFirstDraw),
                (.resume, launch.histogrammedApplicationResumeTime),
                (.optimizedFirstDraw, launch.histogrammedOptimizedTimeToFirstDraw),
            ] {
                var buckets: [TelemetryMetricMapping.Bucket] = []
                let milliseconds = UnitDuration.milliseconds
                let enumerator = histogram.bucketEnumerator
                while let bucket = enumerator.nextObject() as? MXHistogramBucket<UnitDuration> {
                    buckets.append(.init(startMs: bucket.bucketStart.converted(to: milliseconds).value,
                                         endMs: bucket.bucketEnd.converted(to: milliseconds).value,
                                         count: bucket.bucketCount))
                }
                if let event = TelemetryMetricMapping.launchEvent(kind: kind, buckets: buckets) {
                    Telemetry.record(event, at: when)
                }
            }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let when = payload.timeStampEnd
            for crash in payload.crashDiagnostics ?? [] {
                // The termination reason and exception reason are text MetricKit made up from the
                // app's own state, so they're not read.
                Telemetry.record(TelemetryMetricMapping.crashEvent(
                    exceptionType: crash.exceptionType?.intValue, exceptionCode: crash.exceptionCode?.intValue,
                    signal: crash.signal?.intValue, callStackTree: crash.callStackTree.jsonRepresentation()), at: when)
            }
            for hang in payload.hangDiagnostics ?? [] {
                let seconds = hang.hangDuration.converted(to: .seconds).value
                Telemetry.record(TelemetryMetricMapping.hangEvent(
                    durationMs: seconds.isFinite ? Int((seconds * 1_000).rounded()) : nil,
                    callStackTree: hang.callStackTree.jsonRepresentation()), at: when)
            }
        }
    }
}
#else
final class TelemetryMetricKit: @unchecked Sendable {
    static let shared = TelemetryMetricKit()
    func start() {}
}
#endif
