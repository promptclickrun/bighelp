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
        #expect(GeminiLiveWire.decode(frame(#"{"usageMetadata":{"totalTokenCount":12}}"#)).isEmpty)
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
        guard case .answer(_, _, let response, _)? = translator.outputs(for: .functionCalls([empty])).first else {
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

    @Test func aCallAfterItsOwnSpokenLineIsAnsweredSilently() throws {
        // Recorded: "I'm on it." then start_work; a plain answer made Gemini say "On it." again.
        var translator = GeminiLiveTranslator()
        _ = translator.outputs(for: .audio(Data([0, 1])))
        _ = translator.outputs(for: .assistantText("I'm on it."))
        let call = GeminiLiveWire.FunctionCall(id: "c1", name: "start_work", arguments: ["request": .string("Check Monday")])
        #expect(translator.outputs(for: .functionCalls([call])).first
                == .answer(id: "c1", name: "start_work", response: ["status": .string("started")], silent: true))
        #expect(try json(GeminiLiveWire.functionResponse(id: "c1", name: "start_work", response: [:], silent: true))
                .object?["toolResponse"]?.object?["functionResponses"]?.array?.first?.object?["scheduling"] == .string("SILENT"))

        // A call made before saying anything gets a plain answer, so Gemini still says it's on it.
        var quiet = GeminiLiveTranslator()
        #expect(quiet.outputs(for: .functionCalls([call])).first
                == .answer(id: "c1", name: "start_work", response: ["status": .string("started")], silent: false))
    }

    @Test func geminisSpeechDetectionSaysWhenThePersonTalks() {
        #expect(GeminiLiveWire.decode(frame(#"{"voiceActivity":{"type":"ACTIVITY_START","audioOffset":"0.160s"}}"#))
                == [.userActivity(true)])
        #expect(GeminiLiveWire.decode(frame(#"{"voiceActivity":{"type":"ACTIVITY_END"}}"#)) == [.userActivity(false)])
        var translator = GeminiLiveTranslator()
        _ = translator.outputs(for: .userActivity(true))
        #expect(translator.isUserSpeaking)
        _ = translator.outputs(for: .userActivity(false))
        #expect(!translator.isUserSpeaking)
        // Gemini replies only once it decided the person finished, END or not.
        _ = translator.outputs(for: .userActivity(true))
        _ = translator.outputs(for: .assistantText("Sure."))
        #expect(!translator.isUserSpeaking)
    }

    @Test func newsWaitsUntilNobodyIsSpeaking() {
        let now = Date()
        func quiet(replying: Bool = false, lastOutput: TimeInterval = 0, speakingFor: TimeInterval? = nil,
                   playsFor: TimeInterval = -1, awaiting: TimeInterval? = nil) -> Bool {
            GeminiLiveAudioPeer.isQuiet(replying: replying, lastOutputAt: now.addingTimeInterval(-lastOutput),
                                        personSpeakingSince: speakingFor.map { now.addingTimeInterval(-$0) }, now: now,
                                        playbackEndsAt: now.addingTimeInterval(playsFor),
                                        awaitingReplySince: awaiting.map { now.addingTimeInterval(-$0) })
        }
        #expect(quiet())
        #expect(!quiet(replying: true), "Gemini is still generating its answer")
        #expect(!quiet(playsFor: 3), "Monday's results are still playing")
        #expect(!quiet(playsFor: -0.3), "A short pause after the voice stops")
        #expect(!quiet(speakingFor: 2), "The person is talking")
        #expect(!quiet(awaiting: 1), "The last news hasn't been answered yet")
        #expect(quiet(awaiting: 6), "An unanswered news item doesn't block the next one forever")
        // Gemini never closed the turn, or never saw the speech end (muted mid-sentence): news still goes.
        #expect(quiet(replying: true, lastOutput: 4), "A reply that went quiet without turnComplete")
        #expect(quiet(speakingFor: 40), "Speech Gemini never saw end")
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
