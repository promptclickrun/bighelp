import Foundation

/// Media control uses authenticated native plugin HTTP. Work uses the existing
/// ChatModel and Hermes submission journal; this class owns no remote job queue.
/// Each request the voice model hands over starts at once and answers on its own,
/// so the call keeps talking while earlier work runs.
///
/// GPT-Live's events come from the host's feed (`poll`) and its results go back
/// through the host. A Gemini call's events come from the phone's own connection
/// (`LiveVoiceLocalSession`), and its results go back to it as `UPDATE` text.
@MainActor
final class NativeLiveVoiceSession {
    typealias Operation = @MainActor (WorkspaceOperation, [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue]
    typealias CloseCleanupFactory = @MainActor (String) -> (@MainActor () async -> Void)?
    typealias Submit = @MainActor (String) async throws -> String
    /// Who is talking and where (`LiveVoiceCallContext.fields`), for a computer that lists `native-voice-context-v1`.
    typealias Context = @MainActor () async -> [String: BighelpJSONValue]

    /// What a request came back with, and whether the chat confirmed it at all.
    private struct Outcome: Sendable {
        let text: String
        var confirmed = true
    }

    private final class Call {
        let id: String
        /// Gemini: events and results stay on the phone's own connection.
        let local: Bool
        var cursor = 0
        var seen: [String: String] = [:]
        var pending: [String: Task<Outcome, Never>] = [:]
        var transcripts: [(Int, String)] = []
        var contextOffset = -1
        var contextIncomplete = false
        var closeCleanup: (@MainActor () async -> Void)?
        /// Requests that finished on this call, newest last, for `check_work`.
        var finished: [String] = []
        init(id: String, local: Bool) {
            self.id = id
            self.local = local
        }
    }

    let owner: LiveVoiceOwner
    private let operation: Operation
    private let isCurrent: @MainActor () -> Bool
    private let closeCleanupFactory: CloseCleanupFactory?
    private let submit: Submit
    private let context: Context?
    private var call: Call?
    private var pollTask: Task<Void, Never>?
    private weak var model: LiveVoiceModel?
    private weak var localSession: (any LiveVoiceLocalSession)?
    private var retired = false

    init(owner: LiveVoiceOwner, operation: @escaping Operation,
         isCurrent: @escaping @MainActor () -> Bool,
         closeCleanupFactory: CloseCleanupFactory? = nil,
         submit: @escaping Submit,
         context: Context? = nil) {
        self.owner = owner
        self.operation = operation
        self.isCurrent = isCurrent
        self.closeCleanupFactory = closeCleanupFactory
        self.submit = submit
        self.context = context
    }

    func makeModel(
        agentName: String,
        makePeer: @escaping @MainActor () -> any LiveVoiceAudioPeer = { BighelpRealtimeAudioPeer() },
        makeLocalPeer: @escaping @MainActor () -> any LiveVoiceAudioPeer & LiveVoiceLocalSession = {
            GeminiLiveAudioPeer()
        }
    ) -> LiveVoiceModel {
        let client = LiveVoiceControlClient(owner: owner, operation: { [self] name, fields in
            try await perform(name, fields: fields)
        }, isOwnerCurrent: { [isCurrent, owner] value in value == owner && isCurrent() },
            onInvalidate: { [weak self] in self?.retire() })
        let model = LiveVoiceModel(agentName: agentName, client: client, makePeer: { [weak self] in
            // The model asks for its peer as it starts, with the provider it starts with.
            guard let self, self.model?.provider.usesHostMedia == false else { return makePeer() }
            let peer = makeLocalPeer()
            self.adopt(peer)
            return peer
        })
        self.model = model
        return model
    }

    func perform(_ name: String, fields: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        guard !retired, isCurrent() else { throw LiveVoiceControlError.wrongOwner }
        let local = fields["provider"]?.string.flatMap(LiveVoiceProvider.init(rawValue:))?.usesHostMedia == false
        switch name {
        case "voice.live.status": return try await request(local ? .nativeVoiceGeminiStatus : .nativeVoiceStatus, fields)
        case "voice.live.offer":
            guard call == nil, let id = fields["voiceId"]?.string else { throw LiveVoiceControlError.invalidResponse }
            let next = Call(id: id, local: local)
            call = next
            // Snapshot cleanup while the original owner and native context are
            // still current. The handle is retained for this exact allocation,
            // including an offer that returns late after retirement.
            next.closeCleanup = closeCleanupFactory?(id)
            do {
                // The phone's context rides in the offer; the offer's own fields win.
                var fields = fields
                if let context { fields.merge(await context()) { own, _ in own } }
                guard call === next else { throw LiveVoiceControlError.wrongOwner }
                let result = try await request(local ? .nativeVoiceGeminiOffer : .nativeVoiceOffer, fields)
                guard call === next else { throw LiveVoiceControlError.wrongOwner }
                // Gemini's events arrive on the phone's own connection; the host has none to poll.
                if !local { pollTask = Task { [weak self, next] in await self?.poll(next) } }
                return result
            } catch {
                if call === next { call = nil }
                throw error
            }
        case "voice.live.close":
            if fields["voiceId"]?.string == call?.id {
                call = nil
                pollTask?.cancel()
                pollTask = nil
            }
            // Accepted native work is deliberately not cancelled with media.
            return try await request(.nativeVoiceClose, fields)
        case "voice.live.jobs":
            // Work and approvals already appear in the same authoritative chat.
            // Do not manufacture a second set of voice job IDs or revisions.
            return ["voiceId": fields["voiceId"] ?? .null, "jobs": .array([])]
        default: throw LiveVoiceControlError.unavailable
        }
    }

    private func request(_ operation: WorkspaceOperation, _ fields: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        guard isCurrent() else { throw LiveVoiceControlError.wrongOwner }
        var fields = fields
        fields["agentId"] = .string(owner.agentID)
        fields["sessionId"] = .string(owner.sessionID)
        let result = try await self.operation(operation, fields)
        guard isCurrent() else { throw LiveVoiceControlError.wrongOwner }
        return result
    }

    private func poll(_ expected: Call) async {
        do {
            while call === expected, isCurrent(), !Task.isCancelled {
                let page = try await request(.nativeVoicePoll, ["voiceId": .string(expected.id), "after": .integer(expected.cursor)])
                guard call === expected else { return }
                guard page["voiceId"]?.string == expected.id, let rows = page["events"]?.array,
                      rows.count <= 4, let next = page["next"]?.integer else { throw LiveVoiceControlError.invalidResponse }
                for row in rows {
                    guard let value = row.object, value["sequence"]?.integer == expected.cursor + 1,
                          let event = value["event"]?.object else { throw LiveVoiceControlError.invalidResponse }
                    receiveEvent(event, voiceID: expected.id)
                    expected.cursor += 1
                }
                guard next == expected.cursor else { throw LiveVoiceControlError.invalidResponse }
                if page["closed"]?.boolean == true {
                    emit(["kind": .string("closed")], voiceID: expected.id)
                    call = nil
                    return
                }
                if rows.isEmpty { try await Task.sleep(for: .milliseconds(400)) }
            }
        } catch is CancellationError {
        } catch {
            guard call === expected else { return }
            emit(["kind": .string("provider_error"), "fatal": .boolean(true)], voiceID: expected.id)
            call = nil
            // No polling failure can fall back to Link or replay a prompt.
            _ = try? await request(.nativeVoiceClose, ["voiceId": .string(expected.id)])
        }
    }

    func receiveEvent(_ event: [String: BighelpJSONValue], voiceID: String) {
        guard isCurrent(), let call, call.id == voiceID, let kind = event["kind"]?.string else { return }
        if kind == "transcript_delta", event["role"]?.string == "user",
           let end = event["end_ms"]?.integer, let text = event["text"]?.string {
            call.transcripts.append((end, text))
            while call.transcripts.count > 128 || call.transcripts.reduce(0, { $0 + $1.1.utf8.count }) > 16_384 {
                let removed = call.transcripts.removeFirst()
                if removed.0 > call.contextOffset { call.contextIncomplete = true }
            }
        }
        guard kind == "delegation" || kind == "delegation_context_required" else {
            emit(event, voiceID: voiceID)
            return
        }
        guard let id = event["id"]?.string, !id.isEmpty, id.utf8.count <= 180 else { return }
        var text = event["text"]?.string
        if kind == "delegation_context_required", !call.contextIncomplete, let offset = event["offset_ms"]?.integer {
            text = call.transcripts.filter { $0.0 > call.contextOffset && $0.0 <= offset }.map(\.1).joined()
            call.contextOffset = offset
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 3_072, call.seen[id] == nil, call.seen.count < 1024 else { return }
        call.seen[id] = text
        let work: Task<Outcome, Never>
        if let existing = call.pending[text] {
            work = existing // Same pending request, even with a new provider item ID.
        } else {
            guard call.pending.count < 8 else {
                append(Outcome(text: "There is already pending work. Check the chat before asking for more.", confirmed: false),
                       delegationID: id, call: call)
                return
            }
            work = Task { [self, call, text] in
                defer { call.pending[text] = nil }
                guard !retired, isCurrent() else {
                    return Outcome(text: "The host connection changed. Check the chat before resending.", confirmed: false)
                }
                do { return Outcome(text: Self.boundedResult(try await submit(text))) }
                catch {
                    return Outcome(text: "This request was not confirmed. Check the chat and its pending approvals before requesting it again.",
                                   confirmed: false)
                }
            }
            call.pending[text] = work
        }
        emitWorkStatus("working", delegationID: id, voiceID: voiceID)
        Task { [self, call] in
            append(await work.value, delegationID: id, call: call)
        }
    }

    private func append(_ outcome: Outcome, delegationID: String, call expected: Call) {
        let text = outcome.text
        guard call === expected, isCurrent() else { return }
        if expected.local {
            guard let localSession else { return }
            let request = expected.seen[delegationID] ?? ""
            if outcome.confirmed {
                expected.finished.append(request)
                if expected.finished.count > 8 { expected.finished.removeFirst() }
            }
            localSession.sendText(Self.update(request: request, result: text, confirmed: outcome.confirmed))
            emitWorkStatus("result_sent", delegationID: delegationID, voiceID: expected.id)
            return
        }
        Task { [self, expected] in
            guard call === expected, isCurrent() else { return }
            do {
                _ = try await request(.nativeVoiceResult, ["voiceId": .string(expected.id),
                    "delegationId": .string(delegationID), "text": .string(text)])
                guard call === expected, isCurrent() else { return }
                emitWorkStatus("result_sent", delegationID: delegationID, voiceID: expected.id)
            } catch {
                guard call === expected else { return }
                emit(["kind": .string("provider_error"), "fatal": .boolean(false)], voiceID: expected.id)
            }
        }
    }

    /// A Gemini call: events from the phone's own connection, plus `check_work`, which this answers.
    private func adopt(_ peer: any LiveVoiceLocalSession) {
        localSession = peer
        peer.onEvent = { [weak self] event in self?.receiveLocal(event) }
    }

    private func receiveLocal(_ event: [String: BighelpJSONValue]) {
        guard let call, call.local else { return }
        if event["kind"]?.string == "closed" {
            // Gemini ended the call: the next one starts fresh. Work it started keeps going.
            emit(event, voiceID: call.id)
            self.call = nil
            return
        }
        guard event["kind"]?.string == "tool" else {
            receiveEvent(event, voiceID: call.id)
            return
        }
        guard event["name"]?.string == GeminiLiveTranslator.checkWork, let id = event["id"]?.string else { return }
        let running = call.pending.keys.sorted().map {
            BighelpJSONValue.object(["request": .string($0), "state": .string("working")])
        }
        let done = call.finished.suffix(3).map {
            BighelpJSONValue.object(["request": .string($0), "state": .string("finished")])
        }
        localSession?.answerFunction(id: id, name: GeminiLiveTranslator.checkWork, response: ["work": .array(running + done)])
    }

    /// The voice model tells this as its own news, in the first person (the plugin's brief says how).
    /// Work the chat never confirmed is never called done.
    static func update(request: String, result: String, confirmed: Bool = true) -> String {
        let asked = request.isEmpty ? "" : " (\"\(String(request.prefix(300)))\")"
        return confirmed
            ? "UPDATE: the work you started\(asked) is done. What came back: \(result)"
            : "UPDATE: the work you tried to start\(asked) is not confirmed, so do not say it is done. \(result)"
    }

    private func emit(_ event: [String: BighelpJSONValue], voiceID: String) {
        model?.receive(["voiceId": .string(voiceID), "event": .object(event)], owner: owner)
    }

    private func emitWorkStatus(_ state: String, delegationID: String, voiceID: String) {
        emit(["kind": .string("delegation_status"), "state": .string(state),
              "delegationId": .string(delegationID)], voiceID: voiceID)
    }

    private func retire() {
        retired = true
        let identifier = call?.id
        let preparedCleanup = call?.closeCleanup
        call = nil
        pollTask?.cancel()
        pollTask = nil
        if let preparedCleanup {
            Task { await preparedCleanup() }
            return
        }
        guard let identifier, isCurrent() else { return }
        Task { [operation, owner] in
            _ = try? await operation(.nativeVoiceClose, ["voiceId": .string(identifier),
                "agentId": .string(owner.agentID), "sessionId": .string(owner.sessionID)])
        }
    }

    static func boundedResult(_ text: String) -> String {
        guard !text.isEmpty else { return "I started this, but there is no final answer yet. It will show in the chat." }
        if text.utf16.count <= 1_500 { return text }
        var result = String(text.prefix(1_400))
        while result.utf16.count > 1_400 { result.removeLast() }
        return "Result excerpt: " + result + "… Open the chat for the complete answer."
    }
}
