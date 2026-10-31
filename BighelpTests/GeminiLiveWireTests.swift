import Foundation
import Testing
@testable import Bighelp

/// Frames recorded from Gemini Live (gemini-3.8-live, 2026-10-30), reduced to the fields the app reads.
struct GeminiLiveWireTests {
    private func frame(_ json: String) -> Data { Data(json.utf8) }
    private func json(_ data: Data) throws -> BighelpJSONValue { try JSONDecoder().decode(BighelpJSONValue.self, from: data) }

    @Test func oneFrameCarriesAudioTranscriptsAndTheEndOfATurn() {
        let audio = Data([0x01, 0x00, 0xFF, 0x7F])
        let messages = GeminiLiveWire.decode(frame("""
        {"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"\(audio.base64EncodedString())"}}]},
         "inputTranscription":{"text":"What's the weather"},"outputTranscription":{"text":"It's clear"},"turnComplete":true}}
        """))
        #expect(messages == [.audio(audio), .userText("What's the weather"), .assistantText("It's clear"), .turnComplete])
        #expect(GeminiLiveWire.decode(frame(#"{"setupComplete":{}}"#)) == [.setupComplete])
        #expect(GeminiLiveWire.decode(frame(#"{"serverContent":{"interrupted":true}}"#)) == [.interrupted])
        #expect(GeminiLiveWire.decode(frame(#"{"voiceActivity":{"type":"ACTIVITY_START"}}"#)).isEmpty)
        #expect(GeminiLiveWire.decode(frame("not json")).isEmpty)
    }

    @Test func functionCallsKeepTheirIDsAndArguments() {
        let messages = GeminiLiveWire.decode(frame("""
        {"toolCall":{"functionCalls":[{"id":"call_594282","name":"start_work","args":{"request":"tidy Downloads"}},
         {"name":"no_id"}]}}
        """))
        #expect(messages == [.functionCalls([.init(id: "call_594282", name: "start_work",
                                                   arguments: ["request": .string("tidy Downloads")])])])
    }

    @Test func outgoingFramesUseGeminisShapes() throws {
        #expect(try json(GeminiLiveWire.setup(model: "models/gemini-3.8-live"))
                == .object(["setup": .object(["model": .string("models/gemini-3.8-live")])]))
        #expect(try json(GeminiLiveWire.audio(Data([1, 2, 3, 4]))) == .object(["realtimeInput": .object(["audio": .object([
            "data": .string("AQIDBA=="), "mimeType": .string("audio/pcm;rate=16000")])])]))
        #expect(try json(GeminiLiveWire.text("UPDATE: done")) == .object(["realtimeInput": .object(["text": .string("UPDATE: done")])]))
        #expect(try json(GeminiLiveWire.functionResponse(id: "c1", name: "start_work", response: ["status": .string("started")]))
                == .object(["toolResponse": .object(["functionResponses": .array([.object([
                    "id": .string("c1"), "name": .string("start_work"),
                    "response": .object(["status": .string("started")])])])])]))
    }

    @Test func aReplyEndsThePersonsWordsAndFinishesItsOwn() {
        var translator = GeminiLiveTranslator()
        #expect(translator.outputs(for: .setupComplete) == [.event(["kind": .string("started")])])
        #expect(translator.outputs(for: .userText("Who are you?")) == [.event([
            "kind": .string("transcript_delta"), "role": .string("user"), "text": .string("Who are you?")])])
        let pcm = Data([0, 1])
        #expect(translator.outputs(for: .audio(pcm)) == [
            .event(["kind": .string("transcript_done"), "role": .string("user"), "text": .string("Who are you?")]),
            .play(pcm)])
        _ = translator.outputs(for: .assistantText("I'm Juniper."))
        #expect(translator.outputs(for: .turnComplete) == [.event([
            "kind": .string("transcript_done"), "role": .string("assistant"), "text": .string("I'm Juniper.")])])
    }

    @Test func afterACutInTheAbandonedTurnsEmptyEndIsIgnored() {
        var translator = GeminiLiveTranslator()
        _ = translator.outputs(for: .audio(Data([0, 1])))
        _ = translator.outputs(for: .assistantText("Old Elias kept the light"))
        #expect(translator.outputs(for: .interrupted) == [
            .stopPlayback, .event(["kind": .string("audio_cleared")]),
            .event(["kind": .string("transcript_done"), "role": .string("assistant"), "text": .string("Old Elias kept the light")])])
        // Gemini then ends the abandoned turn with nothing in it; the reply to the cut-in still comes.
        #expect(translator.outputs(for: .turnComplete).isEmpty)
        _ = translator.outputs(for: .audio(Data([0, 1])))
        _ = translator.outputs(for: .assistantText("I need your approval."))
        #expect(translator.outputs(for: .turnComplete) == [.event([
            "kind": .string("transcript_done"), "role": .string("assistant"), "text": .string("I need your approval.")])])
    }

    @Test func startWorkIsAnsweredAtOnceAndBecomesADelegation() {
        var translator = GeminiLiveTranslator()
        let call = GeminiLiveWire.FunctionCall(id: "c1", name: "start_work", arguments: ["request": .string(" Tidy Downloads ")])
        #expect(translator.outputs(for: .functionCalls([call])) == [
            .answer(id: "c1", name: "start_work", response: ["status": .string("started")]),
            .event(["kind": .string("delegation"), "id": .string("c1"), "text": .string("Tidy Downloads")])])
        // A turn that only called a function has nothing to finish.
        #expect(translator.outputs(for: .turnComplete).isEmpty)

        let empty = GeminiLiveWire.FunctionCall(id: "c2", name: "start_work", arguments: [:])
        guard case .answer(_, _, let response)? = translator.outputs(for: .functionCalls([empty])).first else {
            Issue.record("An empty request must be answered")
            return
        }
        #expect(response["error"] != nil)
        let check = GeminiLiveWire.FunctionCall(id: "c3", name: "check_work", arguments: [:])
        #expect(translator.outputs(for: .functionCalls([check])) == [.event([
            "kind": .string("tool"), "name": .string("check_work"), "id": .string("c3")])])
        let unknown = GeminiLiveWire.FunctionCall(id: "c4", name: "delete_everything", arguments: [:])
        #expect(translator.outputs(for: .functionCalls([unknown])) == [
            .answer(id: "c4", name: "delete_everything", response: ["error": .string("Unknown function.")])])
    }

    @Test func onlyGeminisOwnEndpointAndATokenAreAccepted() throws {
        let good: [String: BighelpJSONValue] = [
            "voiceId": .string("v"), "transport": .string("websocket"), "token": .string("auth_tokens/abc"),
            "url": .string("wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained"),
            "model": .string("models/gemini-3.8-live")]
        guard case let .gemini(url, token, model) = try LiveVoiceControlClient.geminiAnswer(good) else {
            Issue.record("A valid answer must read")
            return
        }
        #expect(url.host == "generativelanguage.googleapis.com")
        #expect(token == "auth_tokens/abc")
        #expect(model == "models/gemini-3.8-live")
        for (key, value) in [("url", "wss://evil.example/ws"), ("url", "ws://generativelanguage.googleapis.com/ws"),
                             ("url", "wss://generativelanguage.googleapis.com/ws?key=secret"),
                             ("token", "AIzaSy-a-real-key"), ("model", "gemini"), ("transport", "webrtc")] {
            var bad = good
            bad[key] = .string(value)
            #expect(throws: LiveVoiceControlError.self) { try LiveVoiceControlClient.geminiAnswer(bad) }
        }
    }
}
