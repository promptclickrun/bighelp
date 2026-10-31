import Foundation

/// Immutable authority selected by app composition, not inferred from a title or
/// provider transcript. Recreate the client/model when any coordinate changes.
struct LiveVoiceOwner: Equatable, Hashable, Sendable {
    let hostID: String
    let authorizationID: String
    let agentID: String
    let sessionID: String
}

/// Who runs a Full Duplex call. Each agent can have its own (`AgentVoiceChoices`).
enum LiveVoiceProvider: String, CaseIterable, Identifiable, Sendable {
    case codexSubscription = "codex_subscription"
    case apiKey = "api_key"
    /// The phone talks to Gemini directly, with a single-use token the plugin makes from the agent's key.
    case gemini

    var id: String { rawValue }
    var title: String {
        switch self {
        case .codexSubscription: "GPT-Live, Codex subscription"
        case .apiKey: "GPT-Live, API key (separate billing)"
        case .gemini: "Gemini Live, your Gemini key"
        }
    }

    /// The short name the Default Voice row shows.
    var shortTitle: String {
        switch self {
        case .codexSubscription, .apiKey: "GPT-Live"
        case .gemini: "Gemini Live"
        }
    }

    var voices: [String] {
        switch self {
        case .codexSubscription: ["arbor", "breeze", "cove", "ember", "juniper", "maple", "sol", "spruce", "vale"]
        case .apiKey: ["marin", "quartz", "ripple", "vesper", "willow", "stone", "gleam", "meridian", "bossa", "tempo", "beacon", "delta", "cinder"]
        // The plugin accepts only these: Gemini plays its default voice for a name it doesn't know.
        case .gemini: ["Zephyr", "Puck", "Charon", "Kore", "Fenrir", "Leda", "Orus", "Aoede", "Callirrhoe", "Autonoe",
                       "Enceladus", "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi",
                       "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird",
                       "Zubenelgenubi", "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat"]
        }
    }
    var defaultVoice: String {
        switch self {
        case .codexSubscription: "cove"
        case .apiKey: "marin"
        case .gemini: "Zephyr"
        }
    }

    /// GPT-Live's media and events go through the plugin; Gemini's stay between the phone and Gemini.
    var usesHostMedia: Bool { self != .gemini }
}

/// What the plugin answers an offer with: GPT-Live's answer SDP, or where the phone connects to Gemini.
enum LiveVoiceAnswer: Equatable, Sendable {
    case sdp(String)
    case gemini(url: URL, token: String, model: String)
}

enum LiveVoiceControlError: Error, LocalizedError, Sendable {
    case invalidResponse, wrongOwner, unavailable, timedOut
    /// The host answers status for Gemini without a key for this agent.
    case geminiKeyMissing
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Your computer sent back a voice answer the app couldn't use. Try again."
        case .wrongOwner: "This voice call no longer belongs to this chat. Close voice and open it again."
        case .unavailable: "Live voice isn't available on your computer right now. Try again, or use TTS voice mode."
        case .timedOut: "Your computer didn't answer in time. Try again."
        case .geminiKeyMissing: "This agent has no Gemini API key on your computer. Add one as GEMINI_API_KEY, then try again."
        }
    }
}

struct LiveVoiceJob: Identifiable, Equatable, Sendable {
    struct Pending: Equatable, Sendable {
        let id: String
        let revision: Int
        let kind: String
        let prompt: String
    }
    let id: String
    let sessionID: String
    let runID: String
    let title: String
    let status: String
    let revision: Int
    let result: String?
    let pending: Pending?

    var isTerminal: Bool { ["completed", "failed", "cancelled", "expired"].contains(status) }
    var isControllable: Bool { ["running", "waiting"].contains(status) }
    var needsApproval: Bool { pending?.kind == "approval" && isControllable }

    init(document: [String: BighelpJSONValue]) throws {
        guard let id = document["jobId"]?.string, !id.isEmpty, id.utf8.count <= 180,
              let sessionID = document["sessionId"]?.string, !sessionID.isEmpty,
              let runID = document["runId"]?.string, !runID.isEmpty,
              let revision = document["revision"]?.integer, revision > 0,
              let status = document["state"]?.string, !status.isEmpty, status.utf8.count <= 64 else {
            throw LiveVoiceControlError.invalidResponse
        }
        self.id = id
        self.sessionID = sessionID
        self.runID = runID
        self.revision = revision
        title = String((document["text"]?.string ?? "Voice task").prefix(400))
        self.status = status
        result = document["summary"]?.string.map { String($0.prefix(8_000)) }
        if let value = document["pending"]?.object {
            guard let id = value["pendingId"]?.string, !id.isEmpty,
                  let revision = value["revision"]?.integer, revision > 0,
                  let kind = value["kind"]?.string, ["approval", "clarification"].contains(kind),
                  let prompt = value["prompt"]?.string, prompt.utf8.count <= 8_192 else {
                throw LiveVoiceControlError.invalidResponse
            }
            pending = Pending(id: id, revision: revision, kind: kind, prompt: prompt)
        } else {
            pending = nil
        }
    }
}

enum LiveVoiceJobAction: Sendable {
    case cancel
    case steer(String)
    case queue(String)
    case approve(pendingID: String)
    case deny(pendingID: String)
    case clarify(pendingID: String, text: String)

    var fields: [String: BighelpJSONValue] {
        switch self {
        case .cancel: ["action": .string("cancel")]
        case .steer(let text): ["action": .string("steer"), "text": .string(text)]
        case .queue(let text): ["action": .string("queue"), "text": .string(text)]
        case .approve(let id):
            ["action": .string("approval"), "pendingId": .string(id), "decision": .boolean(true)]
        case .deny(let id):
            ["action": .string("approval"), "pendingId": .string(id), "decision": .boolean(false)]
        case .clarify(let id, let text):
            ["action": .string("clarification"), "pendingId": .string(id), "decision": .string(text)]
        }
    }
}

/// Only this thin client knows operation names. Inject the existing authenticated
/// Link/Direct operation method, pinned to `owner`; never a provider URL/token.
@MainActor
final class LiveVoiceControlClient {
    typealias Operation = @MainActor (String, [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue]
    let owner: LiveVoiceOwner
    private let operation: Operation
    private let isOwnerCurrent: @MainActor (LiveVoiceOwner) -> Bool
    private let onInvalidate: @MainActor () -> Void
    private var invalidated = false

    init(
        owner: LiveVoiceOwner,
        operation: @escaping Operation,
        isOwnerCurrent: @escaping @MainActor (LiveVoiceOwner) -> Bool,
        onInvalidate: @escaping @MainActor () -> Void = {}
    ) {
        self.owner = owner
        self.operation = operation
        self.isOwnerCurrent = isOwnerCurrent
        self.onInvalidate = onInvalidate
    }

    var hasCurrentOwner: Bool { !invalidated && isOwnerCurrent(owner) }
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        onInvalidate()
    }

    func status(provider: LiveVoiceProvider) async throws -> [String: BighelpJSONValue] {
        try await request("voice.live.status", fields: ["provider": .string(provider.rawValue)])
    }

    func offer(voiceID: String, provider: LiveVoiceProvider, voice: String, sdp: String) async throws -> LiveVoiceAnswer {
        guard provider.voices.contains(voice), !voiceID.isEmpty else { throw LiveVoiceControlError.invalidResponse }
        if provider.usesHostMedia { try BighelpRealtimeAudioPeer.validateAudioSDP(sdp) }
        let result = try await request("voice.live.offer", fields: [
            "voiceId": .string(voiceID), "provider": .string(provider.rawValue),
            "voice": .string(voice), "sdp": .string(sdp),
        ], timeout: .seconds(45), onLateSuccess: { [weak self] value in
            guard value["voiceId"]?.string == voiceID else { return }
            // A cancelled/timed-out setup may still allocate remotely. Closing
            // this exact ID is safe; never retry creating a provider call.
            Task { @MainActor [weak self] in
                guard let self, self.hasCurrentOwner else { return }
                try? await self.close(voiceID: voiceID)
            }
        })
        guard result["voiceId"]?.string == voiceID else { throw LiveVoiceControlError.invalidResponse }
        guard provider.usesHostMedia else { return try Self.geminiAnswer(result) }
        guard let answer = result["sdp"]?.string else { throw LiveVoiceControlError.invalidResponse }
        try BighelpRealtimeAudioPeer.validateAudioSDP(answer)
        return .sdp(answer)
    }

    /// Only Gemini's own Live endpoint, over TLS, with a bounded single-use token.
    nonisolated static func geminiAnswer(_ result: [String: BighelpJSONValue]) throws -> LiveVoiceAnswer {
        guard result["transport"]?.string == "websocket",
              let address = result["url"]?.string, let url = URL(string: address), url.scheme == "wss",
              url.host == "generativelanguage.googleapis.com", url.user == nil, url.query == nil,
              let token = result["token"]?.string, token.hasPrefix("auth_tokens/"), token.utf8.count <= 600,
              let model = result["model"]?.string, model.hasPrefix("models/"), model.utf8.count <= 120 else {
            throw LiveVoiceControlError.invalidResponse
        }
        return .gemini(url: url, token: token, model: model)
    }

    /// Ending media is deliberately not cancelling any accepted task.
    func close(voiceID: String) async throws {
        _ = try await request("voice.live.close", fields: ["voiceId": .string(voiceID)])
    }

    func jobs(voiceID: String) async throws -> [LiveVoiceJob] {
        let result = try await request("voice.live.jobs", fields: ["voiceId": .string(voiceID)])
        if let returnedID = result["voiceId"]?.string, returnedID != voiceID {
            throw LiveVoiceControlError.invalidResponse
        }
        guard let rows = result["jobs"]?.array, rows.count <= 200 else {
            throw LiveVoiceControlError.invalidResponse
        }
        var seen: Set<String> = []
        return try rows.map { row in
            guard let document = row.object else { throw LiveVoiceControlError.invalidResponse }
            let job = try LiveVoiceJob(document: document)
            guard seen.insert(job.id).inserted else { throw LiveVoiceControlError.invalidResponse }
            return job
        }
    }

    func control(voiceID: String, job: LiveVoiceJob, action: LiveVoiceJobAction) async throws {
        var fields = action.fields
        fields["voiceId"] = .string(voiceID)
        guard job.isControllable else { throw LiveVoiceControlError.invalidResponse }
        fields["jobId"] = .string(job.id)
        fields["runId"] = .string(job.runID)
        fields["expectedRevision"] = .integer(job.revision)
        fields["requestId"] = .string("control_\(UUID().uuidString)")
        switch action {
        case .steer(let text), .queue(let text), .clarify(_, let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 3_072 else { throw LiveVoiceControlError.invalidResponse }
        default: break
        }
        switch action {
        case .approve(let id), .deny(let id):
            guard let pending = job.pending, pending.id == id, pending.kind == "approval" else {
                throw LiveVoiceControlError.invalidResponse
            }
            fields["pendingRevision"] = .integer(pending.revision)
        case .clarify(let id, _):
            guard let pending = job.pending, pending.id == id, pending.kind == "clarification" else {
                throw LiveVoiceControlError.invalidResponse
            }
            fields["pendingRevision"] = .integer(pending.revision)
        case .steer:
            guard job.pending == nil else { throw LiveVoiceControlError.invalidResponse }
        default: break
        }
        _ = try await request("voice.live.control", fields: fields)
    }

    /// Barge-in/audio clear is NOT a cancel-job request. Provider-controlled VAD
    /// also handles conversational interruption independently from these jobs.
    func interruptSpeech(voiceID: String) async throws {
        _ = try await request("voice.live.control", fields: [
            "voiceId": .string(voiceID), "action": .string("interrupt"),
        ])
    }

    private func request(
        _ name: String, fields: [String: BighelpJSONValue], timeout: Duration = .seconds(15),
        onLateSuccess: (@MainActor ([String: BighelpJSONValue]) -> Void)? = nil
    ) async throws -> [String: BighelpJSONValue] {
        guard hasCurrentOwner else { throw LiveVoiceControlError.wrongOwner }
        try Task.checkCancellation()
        var payload = fields
        payload["agentId"] = .string(owner.agentID)
        payload["sessionId"] = .string(owner.sessionID)
        let waiter = LiveVoiceOperationWaiter()
        let task = Task { @MainActor [operation] in
            do {
                let value = try await operation(name, payload)
                if !waiter.finish(.success(value)) { onLateSuccess?(value) }
            }
            catch { waiter.finish(.failure(error)) }
        }
        let timer = Task { @MainActor in
            do { try await Task.sleep(for: timeout) } catch { return }
            waiter.finish(.failure(LiveVoiceControlError.timedOut))
            task.cancel()
        }
        defer { timer.cancel(); task.cancel() }
        let result = try await withTaskCancellationHandler {
            try await waiter.value()
        } onCancel: {
            Task { @MainActor in
                waiter.finish(.failure(CancellationError()))
                task.cancel()
            }
        }
        guard hasCurrentOwner else { throw LiveVoiceControlError.wrongOwner }
        try Task.checkCancellation()
        return result
    }
}

/// Unlike a structured task-group race, the deadline does not await a transport
/// that ignores cancellation. Late completion cannot resume the waiter twice.
@MainActor
private final class LiveVoiceOperationWaiter {
    typealias Value = [String: BighelpJSONValue]
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?

    func value() async throws -> Value {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    @discardableResult
    func finish(_ result: Result<Value, any Error>) -> Bool {
        guard self.result == nil else { return false }
        self.result = result
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
        return true
    }
}
