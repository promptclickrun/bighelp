import Foundation

/// Collects events, batches them and sends them, off the main actor so telemetry
/// never waits on the chat and the chat never waits on telemetry.
///
/// - Flushes every 60 seconds, at 50 queued events, and when the app goes to the background.
/// - The queue is bounded and drops the oldest. A bounded copy is kept on disk so a kill doesn't lose it all.
/// - 429 backs off (the service's Retry-After, else 1, 2, 4 ... minutes up to an hour) and keeps the events.
///   Any other failure drops the batch without a word.
actor TelemetryClient {
    struct Configuration: Sendable {
        var endpoint = URLSessionTelemetryTransport.endpoint
        var flushInterval: Duration = .seconds(60)
        var flushThreshold = 50
        var memoryCapacity = 500
        var diskCapacity = 200
        var maximumBatchesPerFlush = 4
        var persistDelay: Duration = .seconds(2)
        /// The Worker refuses events older than 7 days.
        var maximumAge: TimeInterval = 6 * 86_400
        var firstBackoff: TimeInterval = 60
        var longestBackoff: TimeInterval = 3_600
    }

    private let configuration: Configuration
    private let transport: any TelemetryTransport
    private let identity: any TelemetryIdentityStore
    private let disk: any TelemetryDiskStore
    private let context: TelemetryContext
    private let session: String
    private let now: @Sendable () -> Date

    private var isEnabled: Bool
    private var queue: [TelemetryRecord] = []
    private var installID: String?
    private var isFlushing = false
    private var retryNotBefore: Date?
    private var backoff: TimeInterval = 0
    private var timer: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private(set) var droppedForCapacity = 0

    init(configuration: Configuration = Configuration(), transport: any TelemetryTransport,
         identity: any TelemetryIdentityStore, disk: any TelemetryDiskStore, context: TelemetryContext,
         session: String = TelemetryBatchEncoder.newID(), isEnabled: Bool,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.transport = transport
        self.identity = identity
        self.disk = disk
        self.context = context
        self.session = session
        self.isEnabled = isEnabled
        self.now = now
    }

    var queuedCount: Int { queue.count }
    var enabled: Bool { isEnabled }
    var queuedEvents: [TelemetryEvent] { queue.map(\.event) }
    var nextAttempt: Date? { retryNotBefore }

    // MARK: - Starting and stopping

    /// Picks up what a kill left on disk and starts the 60-second timer.
    func start() {
        guard isEnabled else { return }
        restore()
        guard timer == nil else { return }
        timer = Task { [configuration] in
            while !Task.isCancelled {
                try? await Task.sleep(for: configuration.flushInterval)
                guard !Task.isCancelled else { return }
                await self.flush()
            }
        }
    }

    private func restore() {
        let oldest = now().addingTimeInterval(-configuration.maximumAge)
        let saved = disk.load().filter { Date(timeIntervalSince1970: Double($0.time) / 1_000) > oldest }
        guard !saved.isEmpty else { return }
        queue = saved + queue
        trim()
    }

    /// Off: stop at once, forget the queue, the file and the install ID.
    /// On: a fresh install ID is made when the first batch needs it.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            start()
        } else {
            timer?.cancel(); timer = nil
            persistTask?.cancel(); persistTask = nil
            queue.removeAll()
            retryNotBefore = nil
            backoff = 0
            installID = nil
            disk.delete()
            identity.delete()
        }
    }

    // MARK: - Recording

    func record(_ event: TelemetryEvent, at date: Date) {
        record([TelemetryRecord(event, at: date)])
    }

    /// Several at once (the receipts the extension wrote). Ones older than the Worker takes are left out,
    /// and one dated in the future counts as now.
    func record(_ records: [TelemetryRecord]) {
        guard isEnabled else { return }
        let current = now()
        let oldest = Int64((current.addingTimeInterval(-configuration.maximumAge).timeIntervalSince1970 * 1_000).rounded())
        let latest = Int64((current.timeIntervalSince1970 * 1_000).rounded())
        for record in records where record.time >= oldest {
            queue.append(record.time > latest ? TelemetryRecord(record.event, at: current) : record)
        }
        trim()
        if queue.count >= configuration.flushThreshold {
            Task { await self.flush() }
        } else {
            schedulePersist()
        }
    }

    private func trim() {
        let extra = queue.count - configuration.memoryCapacity
        guard extra > 0 else { return }
        queue.removeFirst(extra)
        droppedForCapacity += extra
    }

    // MARK: - Sending

    /// Sends what's queued, a batch at a time. Quiet: nothing here throws or logs.
    func flush() async {
        guard isEnabled, !isFlushing, !queue.isEmpty else { return }
        if let retryNotBefore, now() < retryNotBefore { return }
        guard let id = ensureInstallID() else { return }
        isFlushing = true
        defer { isFlushing = false }
        for _ in 0..<configuration.maximumBatchesPerFlush {
            guard isEnabled, let first = queue.first else { break }
            let source = first.event.source
            let count = TelemetryBatchEncoder.fit(queue, source: source)
            guard count > 0 else { queue.removeFirst(); continue }
            let batch = Array(queue.prefix(count))
            queue.removeFirst(count)
            guard let body = TelemetryBatchEncoder.body(source: source, id: id, session: session, context: context,
                                                        events: batch.map(\.wire)) else { continue }
            let response = await transport.send(TelemetryRequest(url: configuration.endpoint, body: body.data,
                                                                 isGzip: body.isGzip))
            // Turned off while it was in the air: nothing is kept, nothing more is sent.
            guard isEnabled else { return }
            switch response {
            case .accepted:
                backoff = 0
                retryNotBefore = nil
            case .rateLimited(let after):
                backoff = backoff == 0 ? configuration.firstBackoff : min(backoff * 2, configuration.longestBackoff)
                let wait = min(max(after ?? 0, backoff), configuration.longestBackoff)
                retryNotBefore = now().addingTimeInterval(wait)
                queue = batch + queue
                trim()
                schedulePersist()
                return
            case .dropped:
                break
            }
        }
        if queue.isEmpty { persistNow() } else { schedulePersist() }
    }

    private func ensureInstallID() -> String? {
        if let installID { return installID }
        installID = identity.load() ?? identity.create()
        return installID
    }

    // MARK: - Keeping a copy

    private func schedulePersist() {
        guard persistTask == nil else { return }
        persistTask = Task { [configuration] in
            try? await Task.sleep(for: configuration.persistDelay)
            guard !Task.isCancelled else { return }
            self.persistNow()
        }
    }

    /// Writes the newest events to disk (or removes the file when there are none).
    func persistNow() {
        persistTask?.cancel(); persistTask = nil
        guard isEnabled else { return }
        disk.save(Array(queue.suffix(configuration.diskCapacity)))
    }

    /// The app is going to the background: send what's there and keep the rest.
    func flushForBackground() async {
        await flush()
        persistNow()
    }
}
