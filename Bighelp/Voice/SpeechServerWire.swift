import Foundation

/// A speech server the person runs themselves, spoken to over the OpenAI Realtime WebSocket
/// dialect: the server hears and speaks, Hermes thinks. Any server that implements the frames
/// below can carry a Full Duplex call — a local model, a home server, or the same speech server a
/// different client already uses.
///
/// The contract, and why each part of it exists:
///
/// - `session.update` fixes the audio formats and turns VAD on with `create_response: false`.
///   Without that, a server with a model of its own answers each utterance itself, and the person
///   hears two voices — the server's guess and Hermes' answer.
/// - The phone sends only microphone audio, as 24 kHz 16-bit mono PCM in
///   `input_audio_buffer.append`.
/// - A finished utterance comes back as `conversation.item.input_audio_transcription.completed`.
///   That text is the request; Hermes' answer returns to the server as a `response.create` whose
///   instructions ask for it to be read out word for word.
/// - The reply's audio arrives in `response.audio.delta`, the same 24 kHz PCM shape Gemini Live
///   sends, so the call's playback and barge-in behave exactly as they do there.
///
/// Both names OpenAI has used for the same events are accepted (`response.audio.delta` and the
/// newer `response.output_audio.delta`), because servers in the wild predate the rename.
enum SpeechServerWire {
    static let inputSampleRate = 24_000.0
    static let outputSampleRate = 24_000.0
    /// Far above a real frame (a few hundred KB of audio). A larger one would be a broken server.
    static let maximumFrameBytes = 8 * 1_024 * 1_024
    /// A reply's transcript, for the call screen's caption.
    static let maximumTextBytes = 8_192

    enum Message: Equatable, Sendable {
        /// The server accepted the session (or confirmed its update). Audio may follow.
        case ready
        /// 24 kHz 16-bit mono PCM.
        case audio(Data)
        case assistantText(String)
        /// The person started talking: their voice, not ours, is what the call should carry.
        case personSpoke
        /// The person finished an utterance, transcribed by the server. This is the request.
        case utterance(String)
        case serverError(String)
    }

    /// What the app tells the server about this call. The server has no tools and no knowledge of
    /// Hermes; it is told to be a voice, and that the app hands it exactly what to say.
    static func instructions(agentName: String) -> String {
        """
        You are the voice of \(agentName), speaking with the person out loud. You have no tools and \
        no knowledge of your own: the app sends you text to read, and you read it in a natural, \
        spoken voice, then stop. Never invent facts, results or status. Keep acknowledgements to a \
        few words.
        """
    }

    static func sessionUpdate(agentName: String, voice: String) -> Data {
        var output: [String: BighelpJSONValue] = [
            "format": .object(["type": .string("audio/pcm"), "rate": .integer(Int(outputSampleRate))]),
        ]
        // A name the server doesn't know is not worth failing the call over: it keeps its own voice.
        if !voice.isEmpty, voice != "default" { output["voice"] = .string(voice) }
        let audio: [String: BighelpJSONValue] = [
            "input": .object([
                "format": .object(["type": .string("audio/pcm"), "rate": .integer(Int(inputSampleRate))]),
                // The app decides when Hermes answers; the server only detects speech.
                "turn_detection": .object([
                    "type": .string("server_vad"),
                    "create_response": .boolean(false),
                    "interrupt_response": .boolean(true),
                ]),
                "transcription": .object(["model": .string("whisper-1")]),
            ]),
            "output": .object(output),
        ]
        return encode([
            "type": .string("session.update"),
            "session": .object([
                "type": .string("realtime"),
                "output_modalities": .array([.string("audio")]),
                "instructions": .string(instructions(agentName: agentName)),
                "audio": .object(audio),
            ]),
        ])
    }

    /// One piece of microphone audio, already 24 kHz 16-bit mono.
    static func audio(_ pcm: Data) -> Data {
        encode(["type": .string("input_audio_buffer.append"),
                "audio": .string(pcm.base64EncodedString())])
    }

    /// News for the person, spoken by the server's own voice: Hermes' answer, read out verbatim.
    static func speak(_ text: String) -> Data {
        encode([
            "type": .string("response.create"),
            "response": .object([
                "output_modalities": .array([.string("audio")]),
                "instructions": .string("Read this to the person exactly as written, then stop: \(text)"),
            ]),
        ])
    }

    /// One frame can carry one event, or an error alongside it.
    static func decode(_ data: Data) -> [Message] {
        guard data.count <= maximumFrameBytes,
              let frame = try? JSONDecoder().decode(BighelpJSONValue.self, from: data).object else { return [] }
        let type = frame["type"]?.string
        switch type {
        case "session.created", "session.updated":
            return [.ready]
        case "response.audio.delta", "response.output_audio.delta":
            guard let encoded = frame["delta"]?.string, encoded.utf8.count <= maximumFrameBytes,
                  let audio = Data(base64Encoded: encoded), !audio.isEmpty else { return [] }
            return [.audio(audio)]
        case "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            guard let text = frame["delta"]?.string, !text.isEmpty else { return [] }
            return [.assistantText(String(text.suffix(maximumTextBytes)))]
        case "input_audio_buffer.speech_started":
            return [.personSpoke]
        case "conversation.item.input_audio_transcription.completed",
             "conversation.item.input_audio_transcription.done":
            guard let text = frame["transcript"]?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return [.utterance(text)]
        case "error":
            // The message is the server's own words about this call; the screen already shows it.
            guard let message = frame["error"]?.object?["message"]?.string else { return [.serverError("")] }
            return [.serverError(String(message.prefix(200)))]
        default:
            return []
        }
    }

    private static func encode(_ frame: [String: BighelpJSONValue]) -> Data {
        (try? JSONEncoder().encode(BighelpJSONValue.object(frame))) ?? Data()
    }
}

/// Turns a speech server's messages into the events the call screen and `NativeLiveVoiceSession`
/// already understand, so work is routed exactly as it is for GPT-Live and Gemini.
///
/// A speech server has no `start_work` function to call: the person's own transcribed sentence is
/// the request, and it is handed over the moment the server says they finished it.
final class SpeechServerTranslator {
    typealias Output = GeminiLiveTranslator.Output

    /// The same bound GPT-Live's delegations have.
    static let maximumRequestBytes = 3_072

    private var assistant = ""
    private var utteranceCount = 0
    private(set) var isReplying = false

    /// The server detected the person talking, so its own reply is not what should be heard.
    func personSpoke() -> [Output] {
        var outputs: [Output] = []
        if isReplying || !assistant.isEmpty {
            outputs.append(.stopPlayback)
            outputs.append(.event(["kind": .string("audio_cleared")]))
        }
        if !assistant.isEmpty {
            outputs.append(transcript("transcript_done", role: "assistant", assistant))
            assistant = ""
        }
        isReplying = false
        return outputs
    }

    func outputs(for message: SpeechServerWire.Message) -> [Output] {
        switch message {
        case .ready:
            return [.event(["kind": .string("started")])]
        case .audio(let pcm):
            isReplying = true
            return [.play(pcm)]
        case .assistantText(let text):
            isReplying = true
            assistant += text
            return [transcript("transcript_delta", role: "assistant", text)]
        case .personSpoke:
            return personSpoke()
        case .utterance(let text):
            let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !request.isEmpty, request.utf8.count <= Self.maximumRequestBytes else { return [] }
            utteranceCount += 1
            // The id is the call's own: results come back against it and are never replayed.
            return [transcript("transcript_delta", role: "user", request),
                    transcript("transcript_done", role: "user", request),
                    .event(["kind": .string("delegation"),
                            "id": .string("utterance_\(utteranceCount)"),
                            "text": .string(request)])]
        case .serverError:
            return [.event(["kind": .string("provider_error"), "fatal": .boolean(false)])]
        }
    }

    private func transcript(_ kind: String, role: String, _ text: String) -> Output {
        .event(["kind": .string(kind), "role": .string(role), "text": .string(String(text.suffix(8_000)))])
    }
}
