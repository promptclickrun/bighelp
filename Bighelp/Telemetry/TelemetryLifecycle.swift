import SwiftUI
import UIKit

/// `app.opened`, `app.backgrounded` and `session.ended`, from the scene phase, and the
/// hand-off to the pushes the notification extension counted.
@MainActor
final class TelemetryLifecycle {
    static let shared = TelemetryLifecycle()

    private let launchedAt: Date
    private var foregroundSince: Date?
    private var hasOpened = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(now: Date = Date()) { launchedAt = now }

    func scenePhaseChanged(to phase: ScenePhase, now: Date = Date(),
                           receipts: BighelpDeliveryReceipts? = .shared) {
        switch phase {
        case .active:
            guard foregroundSince == nil else { return }
            foregroundSince = now
            Telemetry.record(.appOpened(coldStart: !hasOpened))
            hasOpened = true
            if let receipts { drainReceipts(now: now, receipts: receipts) }
        case .background:
            guard let since = foregroundSince else { return }
            foregroundSince = nil
            Telemetry.record(.appBackgrounded(foregroundMs: Self.milliseconds(from: since, to: now)))
            Telemetry.record(.sessionEnded(durationMs: Self.milliseconds(from: launchedAt, to: now)))
            sendBeforeSuspending()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    nonisolated static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1_000).rounded()))
    }

    /// iOS gives a few seconds after the background; use them to send.
    private func sendBeforeSuspending() {
        guard Telemetry.isRecording else { return }
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "bighelp usage") {
            MainActor.assumeIsolated { TelemetryLifecycle.shared.endBackgroundTask() }
        }
        Task { @MainActor in
            await Telemetry.flushForBackground()
            self.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Pushes the extension saw since last time go out as `notification.received`, source `nse`.
    /// With telemetry off or not allowed they are cleared and nothing is sent.
    func drainReceipts(now: Date = Date(), receipts: BighelpDeliveryReceipts = .shared) {
        Task { @MainActor in
            await Self.drain(receipts, into: Telemetry.client, now: now)
        }
    }

    nonisolated static func drain(_ receipts: BighelpDeliveryReceipts, into client: TelemetryClient?, now: Date) async {
        while true {
            let batch = receipts.drain(limit: BighelpDeliveryReceipts.limit)
            guard !batch.isEmpty else { return }
            guard let client, await client.enabled else { continue }
            await client.record(batch.map(Self.record))
            if batch.count < BighelpDeliveryReceipts.limit { return }
        }
    }

    nonisolated static func record(_ receipt: BighelpDeliveryReceipt) -> TelemetryRecord {
        let event = TelemetryEvent.notificationReceived(
            kind: receipt.kind == .wake ? .wake : .alert,
            path: TelemetryNotificationPath(rawValue: receipt.path.rawValue) ?? .unknown,
            delayMs: receipt.delayMilliseconds, hostToPhoneMs: receipt.hostToPhoneMilliseconds)
        return TelemetryRecord(event, at: Date(timeIntervalSince1970: Double(receipt.receivedAt) / 1_000))
    }
}
