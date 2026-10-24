import Foundation
@testable import Bighelp

/// A transport that never touches the network: it records what would have been sent and
/// answers from a script (accepted when the script runs out).
final class FakeTelemetryTransport: TelemetryTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [TelemetryResponse]
    private var sent: [TelemetryRequest] = []

    init(_ responses: [TelemetryResponse] = []) { scripted = responses }

    var requests: [TelemetryRequest] { lock.withLock { sent } }

    func send(_ request: TelemetryRequest) async -> TelemetryResponse {
        lock.withLock {
            sent.append(request)
            return scripted.isEmpty ? .accepted : scripted.removeFirst()
        }
    }

    /// Every request body, unzipped, as JSON objects.
    var batches: [[String: Any]] {
        requests.compactMap { request in
            let data = request.isGzip ? TelemetryGzip.decompress(request.body) : request.body
            return data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }
    }

    /// Every request body, unzipped, as one string.
    var allText: String {
        requests.map { request in
            let data = request.isGzip ? TelemetryGzip.decompress(request.body) : request.body
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }.joined(separator: "\n")
    }

    func waitForRequests(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while requests.count < count, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return requests.count >= count
    }
}

final class FakeTelemetryIdentity: TelemetryIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private(set) var created = 0
    private(set) var deleted = 0
    var failsToCreate = false

    var current: String? { lock.withLock { value } }
    func load() -> String? { lock.withLock { value } }
    func create() -> String? {
        lock.withLock {
            guard !failsToCreate else { return nil }
            created += 1
            value = UUID().uuidString.lowercased()
            return value
        }
    }
    func delete() { lock.withLock { value = nil; deleted += 1 } }
}

final class FakeTelemetryDisk: TelemetryDiskStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [TelemetryRecord] = []
    private(set) var deleted = 0

    init(_ records: [TelemetryRecord] = []) { self.records = records }
    var saved: [TelemetryRecord] { lock.withLock { records } }
    func load() -> [TelemetryRecord] { lock.withLock { records } }
    func save(_ records: [TelemetryRecord]) { lock.withLock { self.records = records } }
    func delete() { lock.withLock { records = []; deleted += 1 } }
}

final class TelemetryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    /// Starts at the real time (events made with `Date()` must look recent) and then stands still.
    init(_ date: Date = Date()) { self.date = date }
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

extension TelemetryContext {
    static let test = TelemetryContext(appVersion: "2.7.0", build: "160", os: "iOS", osVersion: "26.5.0",
                                       deviceClass: "iPhone", channel: .testflight)
}

enum TelemetryTestRig {
    struct Rig {
        let client: TelemetryClient
        let transport: FakeTelemetryTransport
        let identity: FakeTelemetryIdentity
        let disk: FakeTelemetryDisk
        let clock: TelemetryTestClock
    }

    static func make(responses: [TelemetryResponse] = [], enabled: Bool = true,
                     configuration: TelemetryClient.Configuration = .init(), disk: FakeTelemetryDisk = .init(),
                     clock: TelemetryTestClock = .init()) -> Rig {
        let transport = FakeTelemetryTransport(responses)
        let identity = FakeTelemetryIdentity()
        let client = TelemetryClient(configuration: configuration, transport: transport, identity: identity,
                                     disk: disk, context: .test, isEnabled: enabled, now: { clock.now })
        return Rig(client: client, transport: transport, identity: identity, disk: disk, clock: clock)
    }
}
