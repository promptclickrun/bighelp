import Foundation

/// Who's in control of the screen, as this viewer sees it. Hermes owns the truth (the
/// lease); this is a cache of it that never goes backwards: a reply or event about an
/// older lease (lower epoch) is ignored.
struct BotScreenControl: Equatable {
    enum Holder: Equatable {
        case agent
        case me
        case someoneElse
        /// This viewer held control under the ID it had before a reconnect (the app came
        /// back from the background). Hermes still keeps the person's control; taking it
        /// again under the new ID carries on where they were.
        case meBeforeReconnect
    }

    private(set) var lease = BotScreenLease.agent
    private(set) var viewerID: String?
    private var earlierViewerHashes: Set<String> = []

    var holder: Holder {
        guard lease.holder == .human else { return .agent }
        if lease.isHeld(byViewerID: viewerID) { return .me }
        if let hash = lease.viewerHash, earlierViewerHashes.contains(hash) { return .meBeforeReconnect }
        return .someoneElse
    }

    /// Takes a lease from a reply or an event. False when it's older than the one shown.
    @discardableResult
    mutating func apply(_ next: BotScreenLease) -> Bool {
        guard next.epoch >= lease.epoch else { return false }
        lease = next
        return true
    }

    /// The viewer ID Hermes gave this attach. A new one keeps the old one's hash, so a
    /// lease it held still reads as this person's.
    mutating func adopt(viewerID next: String) {
        if let viewerID, viewerID != next { earlierViewerHashes.insert(BotScreenLease.hash(viewerID: viewerID)) }
        viewerID = next
    }
}

/// How the screen's socket closed, from Hermes' close codes.
enum BotScreenStreamEnd: Equatable {
    /// 4000: another person took control; watch again on a fresh ticket.
    case controlTaken
    /// 4001: the screen isn't running.
    case screenGone
    /// 4401: the ticket was spent or expired; get another.
    case ticketRefused
    /// 4403: the host refused the socket (its address or origin rules).
    case notAllowed
    /// The socket closed or dropped some other way.
    case dropped

    init(closeCode: Int?) {
        switch closeCode {
        case 4000: self = .controlTaken
        case 4001: self = .screenGone
        case 4401: self = .ticketRefused
        case 4403: self = .notAllowed
        default: self = .dropped
        }
    }
}

/// When to connect again. Hermes closes the socket on purpose for a takeover or a spent
/// ticket, so those reconnect at once, but a screen that keeps doing it is left alone
/// after a few quick tries. A dropped link backs off: 1, 2, 4, 8 seconds.
struct BotScreenReconnects {
    static let quickLimit = 3
    static let quickWindow: TimeInterval = 10
    static let dropLimit = 5

    private var quick: [Date] = []
    private var drops = 0

    /// A picture arrived: the connection works, so dropped links start counting again.
    mutating func connected() { drops = 0 }

    /// How long to wait before the next try, or nil to stop and say why.
    mutating func delay(after end: BotScreenStreamEnd, now: Date = .now) -> Duration? {
        switch end {
        case .screenGone, .notAllowed:
            return nil
        case .controlTaken, .ticketRefused:
            quick = quick.filter { now.timeIntervalSince($0) < Self.quickWindow } + [now]
            return quick.count > Self.quickLimit ? nil : .zero
        case .dropped:
            drops += 1
            return drops > Self.dropLimit ? nil : .seconds(min(8, 1 << (drops - 1)))
        }
    }
}
