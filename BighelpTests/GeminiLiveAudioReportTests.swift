import AVFoundation
import Foundation
import Testing
@testable import Bighelp

/// The call audio report (`GeminiLiveAudioDiagnostics`): it has to say where a Gemini call's sound stops on
/// a device, from one call, so the fix follows the evidence.
struct GeminiLiveAudioReportTests {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000)
    }

    @Test func aPlayerThatTakesAudioButDoesntPlayItShowsAsStuck() {
        let clock = Clock()
        let diagnostics = GeminiLiveAudioDiagnostics(clock: { clock.now })
        diagnostics.begin()
        diagnostics.count { $0.receivedChunks = 12; $0.receivedBytes = 96_000; $0.scheduledBuffers = 12 }
        var state = GeminiLiveAudioState()
        state.engineRunning = true
        state.playerPlaying = true
        state.playerPosition = 4_800
        clock.now += 1
        _ = diagnostics.report(state)
        clock.now += 1
        let report = diagnostics.report(state)
        #expect(report.contains("Gemini sent 12 pieces (93 KB); 12 scheduled, 0 dropped (engine off), 0 finished"))
        #expect(report.contains("Mixer output now: silent"))
        #expect(report.contains("Player: playing, position 4800 (not moving)"))
        #expect(report.hasPrefix("Call audio, 2 s"))
    }

    @Test func theMixerMeterReadsWhatTheEngineRenders() throws {
        let diagnostics = GeminiLiveAudioDiagnostics()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        for channel in 0..<2 {
            for index in 0..<480 { buffer.floatChannelData![channel][index] = index.isMultiple(of: 2) ? 0.5 : -0.5 }
        }
        diagnostics.meter(buffer)
        #expect(diagnostics.report(GeminiLiveAudioState()).contains("Mixer output now: peak 0.500, RMS 0.500; loudest so far 0.500"))
        // Each report starts a new window; the loudest stays.
        #expect(diagnostics.report(GeminiLiveAudioState()).contains("Mixer output now: silent; loudest so far 0.500"))
    }

    @Test func eventsKeepTheirTimesAndOnlyTheNewestStay() {
        let clock = Clock()
        let diagnostics = GeminiLiveAudioDiagnostics(clock: { clock.now })
        diagnostics.begin()
        for index in 0..<50 {
            clock.now += 0.5
            diagnostics.event("change \(index)")
        }
        let events = diagnostics.report(GeminiLiveAudioState())
            .split(separator: "\n").drop { $0 != "Events:" }.dropFirst()
        #expect(events.count == GeminiLiveAudioDiagnostics.maximumEvents)
        #expect(events.first?.hasSuffix("change 10") == true)
        #expect(events.last == "  25.0 s change 49")
    }
}
