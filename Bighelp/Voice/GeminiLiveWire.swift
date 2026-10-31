import Foundation

/// Gemini Live's WebSocket frames for a session the plugin locked with a single-use token
/// (docs/LIVE_VOICE.md in bighelp-plugin): the phone sends only the model name, its microphone audio,
/// text updates and answers to the two app functions; everything else is fixed in the token.
enum GeminiLiveWire {
    static let inputSampleRate = 16_000.0
    static let outputSampleRate = 24_000.0
    /// Far above a real frame (a few hundred KB of audio). The socket refuses a larger one, which ends the call.
    static let maximumFrameBytes = 8 * 1_024 * 1_024

    struct FunctionCall: Equatable, Sendable {
        let id: String
        let name: String
        let arguments: [String: BighelpJSONValue]
    }

    enum Message: Equatable, Sendable {
        case setupComplete
        /// 24 kHz 16-bit mono PCM.
        case audio(Data)
        case userText(String)
        case assistantText(String)
        case interrupted
        case turnComplete
        case functionCalls([FunctionCall])
        /// Gemini's own speech detection: the person started (true) or stopped talking.
        case userActivity(Bool)
        case goAway
    }

    /// One frame can carry audio, both transcripts and the end of a turn, in that order.
    static func decode(_ data: Data) -> [Message] {
        guard data.count <= maximumFrameBytes,
              let frame = try? JSONDecoder().decode(BighelpJSONValue.self, from: data).object else { return [] }
        var messages: [Message] = []
        if frame["setupComplete"] != nil { messages.append(.setupComplete) }
        if let content = frame["serverContent"]?.object {
            for part in content["modelTurn"]?.object?["parts"]?.array ?? [] {
                if let encoded = part.object?["inlineData"]?.object?["data"]?.string,
                   let audio = Data(base64Encoded: encoded), !audio.isEmpty {
                    messages.append(.audio(audio))
                }
            }
            if let text = content["inputTranscription"]?.object?["text"]?.string, !text.isEmpty {
                messages.append(.userText(text))
            }
            if let text = content["outputTranscription"]?.object?["text"]?.string, !text.isEmpty {
                messages.append(.assistantText(text))
            }
            if content["interrupted"]?.boolean == true { messages.append(.interrupted) }
            if content["turnComplete"]?.boolean == true { messages.append(.turnComplete) }
        }
        if let calls = frame["toolCall"]?.object?["functionCalls"]?.array {
            let parsed = calls.prefix(16).compactMap { value -> FunctionCall? in
                guard let call = value.object, let id = call["id"]?.string, !id.isEmpty, id.utf8.count <= 180,
                      let name = call["name"]?.string, !name.isEmpty, name.utf8.count <= 64 else { return nil }
                return FunctionCall(id: id, name: name, arguments: call["args"]?.object ?? [:])
            }
            if !parsed.isEmpty { messages.append(.functionCalls(parsed)) }
        }
        switch frame["voiceActivity"]?.object?["type"]?.string {
        case "ACTIVITY_START": messages.append(.userActivity(true))
        case "ACTIVITY_END": messages.append(.userActivity(false))
        default: break
        }
        if frame["goAway"] != nil { messages.append(.goAway) }
        return messages
    }

    static func setup(model: String) -> Data {
        encode(["setup": .object(["model": .string(model)])])
    }

    static func audio(_ pcm: Data) -> Data {
        encode(["realtimeInput": .object(["audio": .object([
            "data": .string(pcm.base64EncodedString()),
            "mimeType": .string("audio/pcm;rate=\(Int(inputSampleRate))"),
        ])])])
    }

    static func text(_ text: String) -> Data {
        encode(["realtimeInput": .object(["text": .string(text)])])
    }

    /// `silent` asks Gemini not to speak about the answer: it already did, in the same turn.
    static func functionResponse(id: String, name: String, response: [String: BighelpJSONValue],
                                 silent: Bool = false) -> Data {
        var answer: [String: BighelpJSONValue] = ["id": .string(id), "name": .string(name), "response": .object(response)]
        if silent { answer["scheduling"] = .string("SILENT") }
        return encode(["toolResponse": .object(["functionResponses": .array([.object(answer)])])])
    }

    private static func encode(_ frame: [String: BighelpJSONValue]) -> Data {
        (try? JSONEncoder().encode(BighelpJSONValue.object(frame))) ?? Data()
    }
}

/// Turns Gemini's messages into the call events GPT-Live gets from the host's feed (`transcript_delta`,
/// `delegation`, …), so `NativeLiveVoiceSession` routes work the same way for both.
struct GeminiLiveTranslator {
    enum Output: Equatable {
        case event([String: BighelpJSONValue])
        case play(Data)
        case stopPlayback
        case answer(id: String, name: String, response: [String: BighelpJSONValue], silent: Bool = false)
    }

    static let startWork = "start_work"
    static let checkWork = "check_work"
    /// The same bound GPT-Live's delegations have.
    static let maximumRequestBytes = 3_072

    private var user = ""
    private var assistant = ""
    private var turnHasOutput = false
    private(set) var isUserSpeaking = false

    /// Gemini is generating a reply. Its audio may still be playing after this turns false.
    var isReplying: Bool { turnHasOutput || !assistant.isEmpty }

    mutating func outputs(for message: GeminiLiveWire.Message) -> [Output] {
        switch message {
        case .setupComplete:
            return [.event(["kind": .string("started")])]
        case .audio(let pcm):
            return beginOutput() + [.play(pcm)]
        case .userText(let text):
            user += text
            return [transcript("transcript_delta", role: "user", text)]
        case .assistantText(let text):
            let begun = beginOutput()
            assistant += text
            return begun + [transcript("transcript_delta", role: "assistant", text)]
        case .interrupted:
            var outputs: [Output] = [.stopPlayback, .event(["kind": .string("audio_cleared")])]
            if !assistant.isEmpty { outputs.append(transcript("transcript_done", role: "assistant", assistant)) }
            assistant = ""
            turnHasOutput = false
            return outputs
        case .turnComplete:
            // After an interruption Gemini ends the abandoned turn on its own, with nothing in it; the
            // reply to the interruption is still coming. A turn that only called a function is empty too.
            guard turnHasOutput || !assistant.isEmpty else { return [] }
            var outputs = finishUser()
            if !assistant.isEmpty { outputs.append(transcript("transcript_done", role: "assistant", assistant)) }
            assistant = ""
            turnHasOutput = false
            return outputs
        case .functionCalls(let calls):
            // Answered after its own spoken line ("On it"), a call is answered silently; otherwise
            // Gemini acknowledges the answer too, and the person hears "On it" twice.
            let spoke = isReplying
            return calls.flatMap { outputs(for: $0, spoke: spoke) }
        case .userActivity(let speaking):
            isUserSpeaking = speaking
            return []
        case .goAway:
            return []
        }
    }

    private func outputs(for call: GeminiLiveWire.FunctionCall, spoke: Bool) -> [Output] {
        switch call.name {
        case Self.startWork:
            let request = (call.arguments["request"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !request.isEmpty, request.utf8.count <= Self.maximumRequestBytes else {
                return [.answer(id: call.id, name: call.name, response: ["error": .string("The request was empty or too long.")])]
            }
            // Gemini waits for an answer before it speaks again, so it gets one now; the work's own
            // result arrives later as an UPDATE text.
            return [.answer(id: call.id, name: call.name, response: ["status": .string("started")], silent: spoke),
                    .event(["kind": .string("delegation"), "id": .string(call.id), "text": .string(request)])]
        case Self.checkWork:
            return [.event(["kind": .string("tool"), "name": .string(call.name), "id": .string(call.id)])]
        default:
            return [.answer(id: call.id, name: call.name, response: ["error": .string("Unknown function.")])]
        }
    }

    /// The person's words end where the reply begins.
    private mutating func beginOutput() -> [Output] {
        guard !turnHasOutput else { return [] }
        turnHasOutput = true
        return finishUser()
    }

    private mutating func finishUser() -> [Output] {
        guard !user.isEmpty else { return [] }
        defer { user = "" }
        return [transcript("transcript_done", role: "user", user)]
    }

    private func transcript(_ kind: String, role: String, _ text: String) -> Output {
        .event(["kind": .string(kind), "role": .string(role), "text": .string(String(text.suffix(8_000)))])
    }
}
