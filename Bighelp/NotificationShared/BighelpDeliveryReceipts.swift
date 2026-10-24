import Darwin
import Foundation

/// One push, as the notification service extension (or the app, for a wake) saw it.
/// Only times and fixed labels: nothing from the message, no event ID, no token.
struct BighelpDeliveryReceipt: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case alert, wake }
    enum Path: String, Codable, Sendable { case direct, buzzkit, unknown }

    let kind: Kind
    let path: Path
    /// Unix milliseconds on this phone when the push arrived.
    let receivedAt: Int64
    /// When the relay sent it (`bighelp_meta.sentAt`), if it said.
    let sentAt: Int64?
    /// When the host event happened (`bighelp_meta.occurredAt`), if it said.
    let occurredAt: Int64?

    /// Relay send to this phone, when known and not negative (clocks can disagree).
    var delayMilliseconds: Int? { Self.span(from: sentAt, to: receivedAt) }
    /// Host event to this phone, when known and not negative.
    var hostToPhoneMilliseconds: Int? { Self.span(from: occurredAt, to: receivedAt) }

    private static func span(from start: Int64?, to end: Int64) -> Int? {
        guard let start, end >= start else { return nil }
        let difference = end - start
        return difference <= 86_400_000 ? Int(difference) : nil
    }
}

/// A small bounded list of receipts in the app group the extension and the app share.
/// The extension only writes here: it makes no network calls for telemetry. The app
/// reads the list when it opens and comes forward, sends it and clears it.
///
/// Both processes lock the file (`flock`), so a push arriving while the app drains
/// neither loses nor repeats a receipt.
struct BighelpDeliveryReceipts: @unchecked Sendable {
    /// The group the extension's entitlements and `BighelpRecentAlerts` already use.
    static let appGroup = "group.app.loopdy.mobile.buzzkit"
    static let limit = 200
    static let fileName = "bighelp-delivery-receipts.json"
    /// The newest receipt kept when the file is bigger than this. 200 entries are about 30 KB.
    private static let maximumFileBytes = 128 * 1_024
    private static let processLock = NSLock()

    /// The app keeps this in the shared group's defaults: false while "Share usage and diagnostics" is off,
    /// so the extension writes nothing then.
    static let recordingKey = "bighelp.telemetry.receipts-enabled"

    let fileURL: URL?
    let defaults: UserDefaults?

    init(fileURL: URL?, defaults: UserDefaults? = nil) {
        self.fileURL = fileURL
        self.defaults = defaults
    }

    static var shared: BighelpDeliveryReceipts {
        BighelpDeliveryReceipts(fileURL: FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: fileName),
                                defaults: UserDefaults(suiteName: appGroup))
    }

    /// On unless the app said otherwise.
    var isRecording: Bool { defaults?.object(forKey: Self.recordingKey) as? Bool ?? true }

    func setRecording(_ recording: Bool) { defaults?.set(recording, forKey: Self.recordingKey) }

    /// Called by the notification service extension once per push, and by the app for a wake.
    static func record(userInfo: [AnyHashable: Any], receivedAt: Date) {
        shared.record(userInfo: userInfo, receivedAt: receivedAt)
    }

    /// The oldest `limit` receipts, removed from the file.
    static func drain(limit: Int) -> [BighelpDeliveryReceipt] {
        shared.drain(limit: limit)
    }

    func record(userInfo: [AnyHashable: Any], receivedAt: Date) {
        guard isRecording else { return }
        append(Self.receipt(userInfo: userInfo, receivedAt: receivedAt))
    }

    func append(_ receipt: BighelpDeliveryReceipt) {
        _ = update { receipts in
            receipts.append(receipt)
            if receipts.count > Self.limit { receipts.removeFirst(receipts.count - Self.limit) }
        }
    }

    func drain(limit: Int) -> [BighelpDeliveryReceipt] {
        guard limit > 0 else { return [] }
        return update { receipts in
            let taken = Array(receipts.prefix(limit))
            receipts.removeFirst(taken.count)
            return taken
        } ?? []
    }

    var count: Int { update { $0.count } ?? 0 }

    // MARK: - Reading a push

    /// Alert or wake, and when the relay said it sent it. A push without `bighelp_meta`, or with
    /// garbage in it, still counts: it just has path `unknown` and no times.
    static func receipt(userInfo: [AnyHashable: Any], receivedAt: Date) -> BighelpDeliveryReceipt {
        let meta = dictionary(userInfo["bighelp_meta"])
        let path: BighelpDeliveryReceipt.Path
        var sentAt: Int64?
        var occurredAt: Int64?
        if let meta, integer(meta["v"]) == 1 {
            path = (meta["path"] as? String).flatMap(BighelpDeliveryReceipt.Path.init(rawValue:)) ?? .unknown
            sentAt = milliseconds(meta["sentAt"])
            occurredAt = milliseconds(meta["occurredAt"])
        } else {
            path = .unknown
        }
        return BighelpDeliveryReceipt(kind: kind(of: userInfo), path: path,
                                      receivedAt: Int64((receivedAt.timeIntervalSince1970 * 1_000).rounded()),
                                      sentAt: sentAt, occurredAt: occurredAt)
    }

    /// The sign-in wake carries `bighelp_wake`; a silent push (`content-available` and no alert) is a wake too.
    static func kind(of userInfo: [AnyHashable: Any]) -> BighelpDeliveryReceipt.Kind {
        if userInfo["bighelp_wake"] != nil { return .wake }
        if let aps = dictionary(userInfo["aps"]), aps["alert"] == nil, integer(aps["content-available"]) == 1 {
            return .wake
        }
        return .alert
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let value = value as? [String: Any] { return value }
        guard let value = value as? NSDictionary else { return nil }
        var result: [String: Any] = [:]
        for (key, entry) in value {
            guard let key = key as? String else { return nil }
            result[key] = entry
        }
        return result
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 9e15 else { return nil }
        return Int(double)
    }

    /// A Unix time in milliseconds: a plain positive number, and not before 2020 or past 2100.
    private static func milliseconds(_ value: Any?) -> Int64? {
        guard let number = integer(value), (1_577_836_800_000...4_102_444_800_000).contains(number) else { return nil }
        return Int64(number)
    }

    // MARK: - The file

    private func update<T>(_ body: (inout [BighelpDeliveryReceipt]) -> T) -> T? {
        guard let fileURL else { return nil }
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let descriptor = open(fileURL.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return nil }
        defer { flock(descriptor, LOCK_UN) }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var receipts: [BighelpDeliveryReceipt] = []
        if let data = try? handle.readToEnd(), !data.isEmpty, data.count <= Self.maximumFileBytes,
           let saved = try? JSONDecoder().decode([BighelpDeliveryReceipt].self, from: data) {
            receipts = saved
        }
        let result = body(&receipts)
        guard let data = try? JSONEncoder().encode(receipts) else { return result }
        ftruncate(descriptor, 0)
        lseek(descriptor, 0, SEEK_SET)
        _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, data.count) }
        return result
    }
}
