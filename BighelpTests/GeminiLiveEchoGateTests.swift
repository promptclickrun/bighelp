import Foundation
import Testing
@testable import Bighelp

/// The microphone while the agent's voice plays (`GeminiLiveEchoGate`). Gemini stops for its own voice
/// coming back through the microphone, however faint, and for a room that starts talking.
struct GeminiLiveEchoGateTests {
    private static let silence = Data(count: 3_200)

    private func chunk(_ tag: UInt8) -> Data { Data(repeating: tag, count: 3_200) }

    @Test func theAgentsEchoBecomesSilence() {
        var gate = GeminiLiveEchoGate()
        for _ in 0..<10 { _ = gate.pass(chunk(1), level: 0.005, agentPlaying: false) }
        for _ in 0..<20 {
            #expect(gate.pass(chunk(2), level: 0.04, agentPlaying: true) == [Self.silence])
        }
    }

    @Test func talkingOverTheAgentGetsThroughFromTheFirstLoudChunk() {
        var gate = GeminiLiveEchoGate()
        for _ in 0..<10 { _ = gate.pass(chunk(1), level: 0.005, agentPlaying: false) }
        #expect(gate.pass(chunk(2), level: 0.03, agentPlaying: true) == [Self.silence])
        #expect(gate.pass(chunk(3), level: 0.15, agentPlaying: true) == [Self.silence], "One loud chunk isn't enough")
        #expect(gate.pass(chunk(4), level: 0.15, agentPlaying: true) == [chunk(3), chunk(4)],
                "The second opens it, and the first goes too")
        #expect(gate.pass(chunk(5), level: 0.15, agentPlaying: true) == [chunk(5)])
    }

    @Test func itStaysOpenBetweenWordsThenCloses() {
        var gate = GeminiLiveEchoGate()
        _ = gate.pass(chunk(1), level: 0.15, agentPlaying: true)
        _ = gate.pass(chunk(2), level: 0.15, agentPlaying: true)
        for tag in UInt8(10)..<15 {
            #expect(gate.pass(chunk(tag), level: 0.02, agentPlaying: true) == [chunk(tag)])
        }
        #expect(gate.pass(chunk(20), level: 0.02, agentPlaying: true) == [Self.silence])
    }

    @Test func aLoudRoomRaisesTheBar() {
        var gate = GeminiLiveEchoGate()
        // A TV the whole time, quieter than the person.
        for _ in 0..<20 { _ = gate.pass(chunk(1), level: 0.05, agentPlaying: false) }
        for _ in 0..<5 {
            #expect(gate.pass(chunk(2), level: 0.07, agentPlaying: true) == [Self.silence], "The TV doesn't open it")
        }
        _ = gate.pass(chunk(3), level: 0.2, agentPlaying: true)
        #expect(gate.pass(chunk(4), level: 0.2, agentPlaying: true) == [chunk(3), chunk(4)], "The person does")
    }

    @Test func nothingChangesWhileTheAgentIsQuiet() {
        var gate = GeminiLiveEchoGate()
        for level in [0.001, 0.04, 0.3] {
            #expect(gate.pass(chunk(7), level: level, agentPlaying: false) == [chunk(7)])
        }
    }
}
