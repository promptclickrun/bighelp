import Foundation

/// What the app may tell the telemetry service. Every name, key and value is a
/// case or a number here, so text from a chat, a file or a person can't get in.
/// A new event needs a case below and a row in the ingestion Worker's allowlist
/// (`bighelp-telemetry`), which drops anything it doesn't know.

/// The parts of the app `feature.used` can name.
enum TelemetryFeature: String, CaseIterable, Codable, Sendable {
    case chatSent = "chat_sent"
    case cardRendered = "card_rendered"
    case formSubmitted = "form_submitted"
    case voiceTurn = "voice_turn"
    case voiceLive = "voice_live"
    case workflowRun = "workflow_run"
    case modeSwitched = "mode_switched"
    case agentOpened = "agent_opened"
    case fileOpened = "file_opened"
    case shortcutRun = "shortcut_run"
    case widgetOpened = "widget_opened"
    case carplayVoice = "carplay_voice"
    case watchChat = "watch_chat"
    case notificationOpened = "notification_opened"
}

enum TelemetryLaunchKind: String, CaseIterable, Codable, Sendable {
    case firstDraw = "first_draw"
    case resume
    case optimizedFirstDraw = "optimized_first_draw"
}

enum TelemetryOutcome: String, CaseIterable, Codable, Sendable {
    case ok
    case failed
}

enum TelemetryNotificationKind: String, CaseIterable, Codable, Sendable {
    case alert
    case wake
}

enum TelemetryNotificationPath: String, CaseIterable, Codable, Sendable {
    case direct
    case buzzkit
    case unknown
}

/// One line of a stack: which binary, how far into it, and the binary's name.
/// Addresses only; a dSYM turns them into names later, off the phone.
struct TelemetryFrame: Equatable, Codable, Sendable {
    static let maximumPerEvent = 64
    let binaryUUID: String
    let offset: Int
    let name: String

    /// Nil unless all three pass the Worker's own patterns.
    init?(binaryUUID: String, offset: Int, name: String) {
        let uuid = binaryUUID.lowercased()
        guard offset >= 0, Self.isHexUUID(uuid), Self.isBinaryName(name) else { return nil }
        self.binaryUUID = uuid
        self.offset = offset
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case binaryUUID, offset, name }

    /// A saved frame is checked again on the way back in.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let frame = TelemetryFrame(binaryUUID: try values.decode(String.self, forKey: .binaryUUID),
                                         offset: try values.decode(Int.self, forKey: .offset),
                                         name: try values.decode(String.self, forKey: .name)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "frame"))
        }
        self = frame
    }

    /// `^[0-9a-fA-F-]{32,36}$`
    static func isHexUUID(_ value: String) -> Bool {
        (32...36).contains(value.utf8.count)
            && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) || $0 == 45 }
    }

    /// `^[A-Za-z0-9_.+-]{1,64}$`
    static func isBinaryName(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count)
            && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                    || $0 == 95 || $0 == 46 || $0 == 43 || $0 == 45
            }
    }
}

enum TelemetryEvent: Equatable, Codable, Sendable {
    case appOpened(coldStart: Bool)
    case appBackgrounded(foregroundMs: Int)
    case sessionEnded(durationMs: Int)
    case featureUsed(TelemetryFeature)
    case launch(kind: TelemetryLaunchKind, medianMs: Int?, samples: Int?)
    case firstToken(ms: Int)
    case reconnect(ms: Int?, attempts: Int?, outcome: TelemetryOutcome)
    case hang(durationMs: Int?, frames: [TelemetryFrame])
    case crash(exceptionType: Int?, exceptionCode: Int?, signal: Int?, frames: [TelemetryFrame])
    case toggled(enabled: Bool)
    case notificationReceived(kind: TelemetryNotificationKind, path: TelemetryNotificationPath,
                              delayMs: Int?, hostToPhoneMs: Int?)

    /// Receipts the notification extension wrote go out as source `nse`.
    var source: TelemetrySource {
        if case .notificationReceived = self { return .nse }
        return .app
    }
}

/// An event waiting to be sent, with the moment it happened.
struct TelemetryRecord: Equatable, Codable, Sendable {
    let event: TelemetryEvent
    /// Unix milliseconds.
    let time: Int64

    init(_ event: TelemetryEvent, at date: Date) {
        self.event = event
        time = Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    var wire: TelemetryWireEvent { TelemetryWireEvent(event, timeMilliseconds: time) }
}

enum TelemetrySource: String, CaseIterable, Codable, Sendable {
    case app
    case nse
}

/// One event as it travels: a name, a time in Unix milliseconds, and its props.
struct TelemetryWireEvent: Equatable, Sendable {
    enum Value: Equatable, Sendable {
        case bool(Bool)
        case integer(Int)
        case code(String)
        case frames([TelemetryFrame])
    }

    let name: String
    let time: Int64
    let source: TelemetrySource
    let props: [String: Value]

    /// `ms`: an integer from 0 to 86,400,000.
    static let maximumMilliseconds = 86_400_000
    /// `count`: an integer from 0 to 100,000.
    static let maximumCount = 100_000

    init(_ event: TelemetryEvent, timeMilliseconds: Int64) {
        time = timeMilliseconds
        source = event.source
        var props: [String: Value] = [:]
        func ms(_ key: String, _ value: Int?) {
            if let value { props[key] = .integer(min(max(value, 0), Self.maximumMilliseconds)) }
        }
        func count(_ key: String, _ value: Int?) {
            if let value { props[key] = .integer(min(max(value, 0), Self.maximumCount)) }
        }
        // A code that doesn't fit is left out, never squeezed into a wrong number.
        func exact(_ key: String, _ value: Int?) {
            if let value, (0...Self.maximumCount).contains(value) { props[key] = .integer(value) }
        }
        switch event {
        case .appOpened(let coldStart):
            name = "app.opened"
            props["coldStart"] = .bool(coldStart)
        case .appBackgrounded(let foregroundMs):
            name = "app.backgrounded"
            ms("foregroundMs", foregroundMs)
        case .sessionEnded(let durationMs):
            name = "session.ended"
            ms("durationMs", durationMs)
        case .featureUsed(let feature):
            name = "feature.used"
            props["feature"] = .code(feature.rawValue)
        case .launch(let kind, let medianMs, let samples):
            name = "perf.launch"
            props["kind"] = .code(kind.rawValue)
            ms("medianMs", medianMs)
            count("samples", samples)
        case .firstToken(let value):
            name = "perf.first_token_ms"
            ms("ms", value)
        case .reconnect(let value, let attempts, let outcome):
            name = "perf.reconnect"
            ms("ms", value)
            count("attempts", attempts)
            props["outcome"] = .code(outcome.rawValue)
        case .hang(let durationMs, let frames):
            name = "hang"
            ms("durationMs", durationMs)
            if !frames.isEmpty { props["frames"] = .frames(Array(frames.prefix(TelemetryFrame.maximumPerEvent))) }
        case .crash(let type, let code, let signal, let frames):
            name = "crash"
            exact("exceptionType", type)
            exact("exceptionCode", code)
            exact("signal", signal)
            if !frames.isEmpty { props["frames"] = .frames(Array(frames.prefix(TelemetryFrame.maximumPerEvent))) }
        case .toggled(let enabled):
            name = "telemetry.toggled"
            props["enabled"] = .bool(enabled)
        case .notificationReceived(let kind, let path, let delayMs, let hostToPhoneMs):
            name = "notification.received"
            props["kind"] = .code(kind.rawValue)
            props["path"] = .code(path.rawValue)
            ms("delayMs", delayMs)
            ms("hostToPhoneMs", hostToPhoneMs)
        }
        self.props = props
    }
}
