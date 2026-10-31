import AVFoundation
import Foundation
import Testing
@testable import Bighelp

/// Real Gemini Live, opt-in: set `TEST_RUNNER_BIGHELP_GEMINI_KEY` (and `TEST_RUNNER_BIGHELP_SPEECH_WAV`, a
/// spoken question, for the microphone side). The test makes the token the way the plugin does.
@MainActor
struct GeminiLiveRealServiceTests {
    nonisolated private static var key: String? { ProcessInfo.processInfo.environment["BIGHELP_GEMINI_KEY"] }
    nonisolated private static var speech: String? { ProcessInfo.processInfo.environment["BIGHELP_SPEECH_WAV"] }
    private static let socket = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained")!

    private final class Log {
        var events: [[String: BighelpJSONValue]] = []
        var states: [BighelpRealtimeAudioPeer.ConnectionState] = []
        func has(_ kind: String, role: String? = nil) -> Bool {
            events.contains { $0["kind"] == .string(kind) && (role == nil || $0["role"] == .string(role!)) }
        }
    }

    /// `gemini_live.mint` in the plugin, in Swift.
    private static func mint(_ key: String) async throws -> String {
        let iso = ISO8601DateFormatter()
        let now = Date()
        let body: [String: Any] = [
            "uses": 1,
            "expireTime": iso.string(from: now.addingTimeInterval(1_800)),
            "newSessionExpireTime": iso.string(from: now.addingTimeInterval(60)),
            "bidiGenerateContentSetup": [
                "model": "models/gemini-3.8-live",
                "generationConfig": ["responseModalities": ["AUDIO"],
                                     "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": "Charon"]]]],
                "systemInstruction": ["parts": [["text": "You are Gordie. Answer briefly, in the first person."]]],
                "inputAudioTranscription": [String: Any](),
                "outputAudioTranscription": [String: Any](),
                "contextWindowCompression": ["slidingWindow": [String: Any]()],
            ],
        ]
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1alpha/auth_tokens")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(object?["name"] as? String, "token: \(String(decoding: data, as: UTF8.self))")
    }

    @Test(.enabled(if: key != nil))
    func thePeerConnectsPlaysGeminisVoiceAndSendsTheMicrophone() async throws {
        let log = Log()
        let peer = GeminiLiveAudioPeer()
        peer.onEvent = { log.events.append($0) }
        peer.onConnectionState = { log.states.append($0) }
        defer { peer.close() }

        _ = try await peer.makeOffer()
        try await peer.apply(.gemini(url: Self.socket, token: try await Self.mint(Self.key!), model: "models/gemini-3.8-live"))
        for _ in 0..<100 where !log.has("started") { try await Task.sleep(for: .milliseconds(100)) }
        peer.sendText("Say hello in five words.")
        for _ in 0..<150 where !log.has("transcript_done", role: "assistant") { try await Task.sleep(for: .milliseconds(100)) }
        let stats = try await peer.statistics()
        print("GEMINI-REAL states=\(log.states) kinds=\(log.events.compactMap { $0["kind"]?.string }) sent=\(stats.bytesSent) received=\(stats.bytesReceived) running=\(stats.audioDeviceRunning)")

        #expect(log.states.contains(.connected))
        #expect(log.has("started"))
        #expect(log.has("transcript_done", role: "assistant"), "Gemini answered")
        #expect(stats.bytesReceived > 0, "Gemini's voice reached the phone")
        #expect(stats.audioDeviceRunning)
        #expect(stats.bytesSent > 0, "The microphone reached Gemini")
    }

    @Test(.enabled(if: key != nil && speech != nil))
    func spokenAudioThroughTheUplinkIsHeardAndAnswered() async throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: Self.speech!))
        let format = file.processingFormat
        var request = URLRequest(url: Self.socket)
        request.setValue("Token \(try await Self.mint(Self.key!))", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = GeminiLiveWire.maximumFrameBytes
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        try await task.send(.string(String(decoding: GeminiLiveWire.setup(model: "models/gemini-3.8-live"), as: UTF8.self)))

        var heard = "", said = "", audio = 0
        func read(until done: () -> Bool) async throws {
            while !done() {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: continue
                }
                for decoded in GeminiLiveWire.decode(data) {
                    switch decoded {
                    case .userText(let text): heard += text
                    case .assistantText(let text): said += text
                    case .audio(let pcm): audio += pcm.count
                    case .setupComplete: said += ""
                    default: break
                    }
                    if decoded == .setupComplete { return }
                    if decoded == .turnComplete, audio > 0 { return }
                }
            }
        }
        try await read { false } // setupComplete

        let uplink = GeminiLiveUplink()
        try uplink.prepare(from: format)
        uplink.attach(task)
        let chunk: AVAudioFrameCount = AVAudioFrameCount(format.sampleRate / 10)
        while file.framePosition < file.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk))
            try file.read(into: buffer, frameCount: chunk)
            uplink.push(buffer)
            try await Task.sleep(for: .milliseconds(100))
        }
        let silence = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk))
        silence.frameLength = chunk
        for _ in 0..<20 {
            uplink.push(silence)
            try await Task.sleep(for: .milliseconds(100))
        }
        try await read { false } // the reply's turnComplete
        print("GEMINI-UPLINK heard=\(heard) said=\(said) audio=\(audio) sent=\(uplink.counters.bytes)")
        #expect(uplink.counters.bytes > 0)
        #expect(heard.localizedCaseInsensitiveContains("weather"), "Gemini heard the words")
        #expect(audio > 0, "Gemini answered out loud")
    }
}
