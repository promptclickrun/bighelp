import Foundation

/// Media control uses authenticated native plugin HTTP. Work uses the existing
/// ChatModel and Hermes submission journal; this class owns no remote job queue.
/// Each request the voice model hands over starts at once and answers on its own,
/// so the call keeps talking while earlier work runs.
@MainActor
final class NativeLiveVoiceSession {
    typealias Operation = @MainActor (WorkspaceOperation, [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue]
    typealias CloseCleanupFactory = @MainActor (String) -> (@MainActor () async -> Void)?
    typealias Submit = @MainActor (String) async throws -> String

    private final class Call {
        let id: String
        var cursor = 0
        var seen: [String: String] = [:]
        var pending: [String: Task<String, Never>] = [:]
        var transcripts: [(Int, String)] = []
        var contextOffset = -1
        var contextIncomplete = false
        var closeCleanup: (@MainActor () async -> Void)?
        init(id: String) { self.id = id }
    }

    let owner: LiveVoiceOwner
    private let operation: Operation
    private let isCurrent: @MainActor () -> Bool
    private let closeCleanupFactory: CloseCleanupFactory?
    private let submit: Submit
    private var call: Call?
    private var pollTask: Task<Void, Never>?
    private weak var model: LiveVoiceModel?
    private var retired = false

    init(owner: LiveVoiceOwner, operation: @escaping Operation,
         isCurrent: @escaping @MainActor () -> Bool,
         closeCleanupFactory: CloseCleanupFactory? = nil,
         submit: @escaping Submit) {
        self.owner = owner
        self.operation = operation
        self.isCurrent = isCurrent
        self.closeCleanupFactory = closeCleanupFactory
        self.submit = submit
    }

    func makeModel(
        agentName: String,
        makePeer: @escaping @MainActor () -> any LiveVoiceAudioPeer = { BighelpRealtimeAudioPeer() }
    ) -> LiveVoiceModel {
        let client = LiveVoiceControlClient(owner: owner, operation: { [self] name, fields in
            try await perform(name, fields: fields)
        }, isOwnerCurrent: { [isCurrent, owner] value in value == owner && isCurrent() },
            onInvalidate: { [weak self] in self?.retire() })
        let model = LiveVoiceModel(agentName: agentName, client: client, makePeer: makePeer)
        self.model = model
        return model
    }

    func perform(_ name: String, fields: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        guard !retired, isCurrent() else { throw LiveVoiceControlError.wrongOwner }
        switch name {
        case "voice.live.status": return try await request(.nativeVoiceStatus, fields)
        case "voice.live.offer":
            guard call == nil, let id = fields["voiceId"]?.string else { throw LiveVoiceControlError.invalidResponse }
            let next = Call(id: id)
            call = next
            // Snapshot cleanup while the original owner and native context are
            // still current. The handle is retained for this exact allocation,
            // including an offer that returns late after retirement.
            next.closeCleanup = closeCleanupFactory?(id)
            do {
                let result = try await request(.nativeVoiceOffer, fields)
                guard call === next else { throw LiveVoiceControlError.wrongOwner }
                pollTask = Task { [weak self, next] in await self?.poll(next) }
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
        let work: Task<String, Never>
        if let existing = call.pending[text] {
            work = existing // Same pending request, even with a new provider item ID.
        } else {
            guard call.pending.count < 8 else {
                append("There is already pending work. Check the chat before asking for more.", delegationID: id, call: call)
                return
            }
            work = Task { [self, call, text] in
                defer { call.pending[text] = nil }
                guard !retired, isCurrent() else { return "The host connection changed. Check the chat before resending." }
                do { return Self.boundedResult(try await submit(text)) }
                catch { return "This request was not confirmed. Check the chat and its pending approvals before requesting it again." }
            }
            call.pending[text] = work
        }
        emitWorkStatus("working", delegationID: id, voiceID: voiceID)
        Task { [self, call] in
            let text = await work.value
            append(text, delegationID: id, call: call)
        }
    }

    private func append(_ text: String, delegationID: String, call expected: Call) {
        guard call === expected, isCurrent() else { return }
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
        guard !text.isEmpty else { return "Hermes accepted the request, but no final answer is confirmed yet. Check the chat." }
        if text.utf16.count <= 1_500 { return text }
        var result = String(text.prefix(1_400))
        while result.utf16.count > 1_400 { result.removeLast() }
        return "Result excerpt: " + result + "… Open the chat for the complete answer."
    }
}
