import AVFoundation
import Foundation
import Testing
@testable import Bighelp

/// Gemini's voice after the engine stops and starts again (`GeminiLiveAudioPeer.restart`): voice processing
/// makes a configuration change right after the engine starts, on iPhone and in the simulator alike.
@MainActor
struct GeminiLivePlayerRestartTests {
    private final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }

    nonisolated private static func handler(_ finished: Finished) -> AVAudioPlayerNodeCompletionHandler {
        { _ in finished.add() }
    }

    private func schedule(_ player: AVAudioPlayerNode, _ format: AVAudioFormat, into finished: Finished) throws {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400))
        buffer.frameLength = 2_400
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: Self.handler(finished))
    }

    private func wait(for count: Int, _ finished: Finished) async throws {
        for _ in 0..<60 where finished.count < count { try await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func audioScheduledAfterAnEngineRestartPlays() async throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                                channels: 1, interleaved: false))
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        defer { engine.stop() }
        try engine.start()
        player.play()
        let finished = Finished()
        try schedule(player, format, into: finished)
        try await wait(for: 1, finished)
        #expect(finished.count == 1, "Plays before the restart")

        engine.stop()
        try GeminiLiveAudioPeer.restart(player) {
            try engine.start()
            player.play()
        }
        try schedule(player, format, into: finished)
        try await wait(for: 2, finished)
        #expect(finished.count == 2, "Audio scheduled after the restart plays")
    }
}
