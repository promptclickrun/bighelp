import Foundation
import os

/// The finished lines of live voice calls on their way into the chat each call opened in (plugin
/// `native-voice-history-v1`), so typing afterwards carries on the same conversation.
///
/// A line goes once it ends: what the person said, or what the voice model said back, cut where the person
/// interrupted it. The plugin appends each as an ordinary message without running anything, only while no turn
/// runs in the chat (`voice_chat_busy` otherwise), and at most once per call and line, so lines are sent in
/// order until the chat takes them, however often a send is repeated. Delegated work is already its own turn
/// in the chat; nothing here sends it again.
///
/// One journal serves one chat on one computer (`shared(hostID:agentID:sessionID:)`): a call opened again in
/// the chat goes on with what an earlier call still holds, and its offer waits for those lines first, so the
/// chat it reads already has them. Lines outlive their call and its connection: `send` takes whatever
/// connection to the computer is current, and a journal stays alive while it has lines to try again.
@MainActor
final class LiveVoiceSpokenTurns {
    struct Line: Equatable {
        let voiceID: String
        let id: String
        let role: String
        let text: String
        let interrupted: Bool
        let at: Date

        var wire: BighelpJSONValue {
            .object(["id": .string(id), "role": .string(role), "text": .string(text),
                     "interrupted": .boolean(interrupted), "at": .number(at.timeIntervalSince1970)])
        }
    }

    enum Outcome: Equatable, Sendable {
        /// The chat holds them now (or held them already).
        case saved
        /// A turn runs in the chat, or the computer didn't answer: try again later.
        case wait
        /// The chat will never take them: not this agent's, gone, or a plugin without the route.
        case refused
    }

    typealias Send = @MainActor (_ voiceID: String, _ lines: [BighelpJSONValue]) async -> Outcome

    static let feature = "native-voice-history-v1"
    static let maximumLines = 256
    static let maximumBatch = 32
    /// In Unicode scalars, as the plugin counts a line's length.
    static let maximumTextLength = 4_000
    /// One send's lines together, in UTF-8 bytes: under the plugin's limit for a request.
    static let maximumBatchBytes = 120_000
    /// Waits between tries while the chat is busy or the computer is away; the last repeats until `giveUpAfter`.
    static let retryWaits: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30)]
    /// A delegated turn can run a long time. Lines that waited this long without a save are let go.
    static let giveUpAfter: Duration = .seconds(30 * 60)

    private(set) var pending: [Line] = []
    /// The newest call's way to the computer; a call opened later in the same chat replaces it.
    var send: Send?
    /// Lines reached the chat: it reads what the computer saved.
    var onSaved: (@MainActor () -> Void)?
    private var round: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var failures = 0
    private var waited: Duration = .zero
    private var lineCount = 0
    private let retryWaits: [Duration]
    private let giveUpAfter: Duration
    private let now: () -> Date

    private static let logger = Logger(subsystem: "app.loopdy.mobile", category: "LiveVoice")
    private static var journals: [String: WeakJournal] = [:]

    init(retryWaits: [Duration] = LiveVoiceSpokenTurns.retryWaits, giveUpAfter: Duration = LiveVoiceSpokenTurns.giveUpAfter,
         now: @escaping () -> Date = Date.init) {
        self.retryWaits = retryWaits.isEmpty ? Self.retryWaits : retryWaits
        self.giveUpAfter = giveUpAfter
        self.now = now
    }

    /// The journal of one chat on one computer: the same object for every call in it while one is alive.
    static func shared(hostID: String, agentID: String, sessionID: String) -> LiveVoiceSpokenTurns {
        let key = [hostID, agentID, sessionID].joined(separator: "\u{1F}")
        journals = journals.filter { $0.value.journal != nil }
        if let journal = journals[key]?.journal { return journal }
        let journal = LiveVoiceSpokenTurns()
        journals[key] = WeakJournal(journal: journal)
        return journal
    }

    /// One finished line of call `voiceID`. Empty lines and anything past the bounds are left out.
    func add(voiceID: String, role: String, text: String, interrupted: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard role == "user" || role == "assistant", !text.isEmpty, pending.count < Self.maximumLines else { return }
        lineCount += 1
        pending.append(Line(voiceID: voiceID, id: "\(role.prefix(1))\(lineCount)", role: role,
                            text: String(String.UnicodeScalarView(text.unicodeScalars.prefix(Self.maximumTextLength))),
                            interrupted: interrupted, at: now()))
        startRound()
    }

    /// Sends what waits and returns when this try ends, saved or not; a busy chat gets more tries later.
    func flush() async {
        await startRound().value
    }

    /// As `flush`, but returns after `seconds` at most, so a call or a request never waits long on it. The
    /// send itself goes on.
    func flush(waitingAtMost seconds: Double) async {
        guard !pending.isEmpty else { return }
        let round = startRound()
        _ = try? await DeviceLocationDeadline.run(seconds: seconds) { await round.value }
    }

    @discardableResult
    private func startRound() -> Task<Void, Never> {
        if let round { return round }
        let next = Task { [self] in
            await sendPending()
            round = nil
        }
        round = next
        return next
    }

    private func sendPending() async {
        while let first = pending.first {
            guard let send else { return scheduleRetry() }
            var bytes = 0
            let batch = Array(pending.prefix(Self.maximumBatch).prefix { line in
                bytes += line.text.utf8.count
                return line.voiceID == first.voiceID && (bytes <= Self.maximumBatchBytes || line == first)
            })
            switch await send(first.voiceID, batch.map(\.wire)) {
            case .saved:
                pending.removeFirst(batch.count)
                (failures, waited) = (0, .zero)
                onSaved?()
            case .refused:
                // Nothing will take them; keeping them would hold up every later line.
                Self.logger.notice("Live voice lines refused by the chat: \(batch.count, privacy: .public)")
                pending.removeFirst(batch.count)
            case .wait:
                return scheduleRetry()
            }
        }
    }

    private func scheduleRetry() {
        guard retry == nil, !pending.isEmpty else { return }
        guard waited < giveUpAfter else {
            Self.logger.notice("Live voice lines let go after waiting: \(self.pending.count, privacy: .public)")
            pending.removeAll()
            (failures, waited) = (0, .zero)
            return
        }
        let wait = retryWaits[min(failures, retryWaits.count - 1)]
        failures += 1
        waited += wait
        // The task holds the journal, so lines still waiting outlive the call that said them.
        retry = Task { [self] in
            try? await Task.sleep(for: wait)
            retry = nil
            startRound()
        }
    }

    private struct WeakJournal {
        weak var journal: LiveVoiceSpokenTurns?
    }
}
