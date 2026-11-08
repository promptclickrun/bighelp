import Foundation
import Testing
@testable import Bighelp

/// A speech server speaks the OpenAI Realtime WebSocket dialect: the frames here are the ones the
/// app sends and the ones it reads, reduced to the fields it uses.
struct SpeechServerWireTests {
    private func frame(_ json: String) -> Data { Data(json.utf8) }
    private func json(_ data: Data) throws -> BighelpJSONValue {
        try JSONDecoder().decode(BighelpJSONValue.self, from: data)
    }

    @Test func theSessionAsksForSpeechDetectionWithoutResponses() throws {
        let update = try json(SpeechServerWire.sessionUpdate(agentName: "Tandy", voice: "default"))
        #expect(update.object?["type"]?.string == "session.update")
        let session = update.object?["session"]?.object
        #expect(session?["output_modalities"] == .array([.string("audio")]))
        #expect(session?["instructions"]?.string?.contains("Tandy") == true)
        let input = session?["audio"]?.object?["input"]?.object
        // A server with a model of its own must not answer each utterance itself.
        #expect(input?["turn_detection"]?.object?["create_response"] == .boolean(false))
        #expect(input?["format"]?.object?["rate"] == .integer(24_000))
        #expect(session?["audio"]?.object?["output"]?.object?["format"]?.object?["rate"] == .integer(24_000))
        // "default" is what an unset voice sends: the server keeps its own.
        #expect(session?["audio"]?.object?["output"]?.object?["voice"] == nil)

        let named = try json(SpeechServerWire.sessionUpdate(agentName: "Tandy", voice: "Aoede"))
        #expect(named.object?["session"]?.object?["audio"]?.object?["output"]?.object?["voice"] == .string("Aoede"))
    }

    @Test func outgoingFramesUseTheRealtimeShapes() throws {
        #expect(try json(SpeechServerWire.audio(Data([1, 2, 3, 4]))) == .object([
            "type": .string("input_audio_buffer.append"), "audio": .string("AQIDBA==")]))
        let speak = try json(SpeechServerWire.speak("It's done."))
        #expect(speak.object?["type"]?.string == "response.create")
        #expect(speak.object?["response"]?.object?["instructions"]?.string?.contains("It's done.") == true)
        #expect(speak.object?["response"]?.object?["output_modalities"] == .array([.string("audio")]))
    }

    @Test func aSessionIsReadyOnCreateOrUpdate() {
        #expect(SpeechServerWire.decode(frame(#"{"type":"session.created"}"#)) == [.ready])
        // Some servers only confirm the update.
        #expect(SpeechServerWire.decode(frame(#"{"type":"session.updated"}"#)) == [.ready])
        #expect(SpeechServerWire.decode(frame(#"{"type":"response.done"}"#)).isEmpty)
        #expect(SpeechServerWire.decode(frame("not json")).isEmpty)
    }

    @Test func replyAudioArrivesUnderEitherNaming() {
        let audio = Data([0x01, 0x00, 0xFF, 0x7F])
        let encoded = audio.base64EncodedString()
        #expect(SpeechServerWire.decode(frame(#"{"type":"response.audio.delta","delta":"\#(encoded)"}"#)) == [.audio(audio)])
        // The newer OpenAI name for the same event.
        #expect(SpeechServerWire.decode(frame(#"{"type":"response.output_audio.delta","delta":"\#(encoded)"}"#)) == [.audio(audio)])
        #expect(SpeechServerWire.decode(frame(#"{"type":"response.audio.delta","delta":"not base64"}"#)).isEmpty)
    }

    @Test func thePersonsFinishedSentenceIsTheRequest() {
        #expect(SpeechServerWire.decode(frame(#"{"type":"input_audio_buffer.speech_started"}"#)) == [.personSpoke])
        #expect(SpeechServerWire.decode(frame("""
        {"type":"conversation.item.input_audio_transcription.completed","transcript":"Tidy Downloads"}
        """)) == [.utterance("Tidy Downloads")])
        #expect(SpeechServerWire.decode(frame("""
        {"type":"conversation.item.input_audio_transcription.completed","transcript":"   "}
        """)).isEmpty)
    }

    @Test func aServerErrorIsNotFatal() throws {
        let messages = SpeechServerWire.decode(frame(#"{"type":"error","error":{"message":"no such session"}}"#))
        #expect(messages == [.serverError("no such session")])
        let translator = SpeechServerTranslator()
        #expect(translator.outputs(for: .serverError("no such session"))
                == [.event(["kind": .string("provider_error"), "fatal": .boolean(false)])])
    }

    @Test func aFinishedUtteranceBecomesOneDelegation() {
        let translator = SpeechServerTranslator()
        #expect(translator.outputs(for: .ready) == [.event(["kind": .string("started")])])
        let outputs = translator.outputs(for: .utterance("Turn the lights off"))
        #expect(outputs.last == .event(["kind": .string("delegation"), "id": .string("utterance_1"),
                                        "text": .string("Turn the lights off")]))
        // The call screen shows the request as the person's words too.
        #expect(outputs.first == .event(["kind": .string("transcript_delta"), "role": .string("user"),
                                         "text": .string("Turn the lights off")]))
        // Each request keeps its own id: results come back against it.
        #expect(translator.outputs(for: .utterance("And the kitchen")).last
                == .event(["kind": .string("delegation"), "id": .string("utterance_2"),
                           "text": .string("And the kitchen")]))
    }

    @Test func anEmptyOrOversizedUtteranceIsNotWork() {
        let translator = SpeechServerTranslator()
        #expect(translator.outputs(for: .utterance("   ")).isEmpty)
        #expect(translator.outputs(for: .utterance(String(repeating: "a", count: 4_000))).isEmpty)
    }

    @Test func thePersonTalkingStopsTheReply() {
        let translator = SpeechServerTranslator()
        let pcm = Data([0, 1])
        #expect(translator.outputs(for: .audio(pcm)) == [.play(pcm)])
        _ = translator.outputs(for: .assistantText("Working on it"))
        let outputs = translator.outputs(for: .personSpoke)
        #expect(outputs.first == .stopPlayback)
        #expect(outputs.contains(.event(["kind": .string("audio_cleared")])))
        #expect(outputs.last == .event(["kind": .string("transcript_done"), "role": .string("assistant"),
                                        "text": .string("Working on it")]))
        #expect(translator.isReplying == false)
    }
}

/// The address a person types, as what the peer can dial.
struct SpeechServerSettingsTests {
    @Test func aTypedAddressBecomesTheWebSocketURL() {
        #expect(SpeechServerSettings.serverURL(from: "ws://box:8765/v1/realtime")?.absoluteString
                == "ws://box:8765/v1/realtime")
        // A bare host on a private network is the common case.
        #expect(SpeechServerSettings.serverURL(from: " 192.168.1.20:8765 ")?.absoluteString
                == "ws://192.168.1.20:8765")
        // A server's own docs give an http address.
        #expect(SpeechServerSettings.serverURL(from: "https://voice.example.com/v1/realtime")?.absoluteString
                == "wss://voice.example.com/v1/realtime")
    }

    @Test func anAddressWithAKeyInItIsRefused() {
        #expect(SpeechServerSettings.serverURL(from: "ws://user:secret@box:8765") == nil)
        #expect(SpeechServerSettings.serverURL(from: "ftp://box") == nil)
        #expect(SpeechServerSettings.serverURL(from: "   ") == nil)
        #expect(SpeechServerSettings.serverURL(from: String(repeating: "a", count: 600)) == nil)
    }
}
