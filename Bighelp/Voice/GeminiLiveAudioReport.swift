import AVFoundation
import Foundation
import os

/// A call whose peer keeps an audio report: Nerd Mode shows it on the call screen, with Restart sound.
@MainActor
protocol LiveVoiceAudioReporting: AnyObject {
    func audioReport() -> String
    /// Stops and starts the player only (an experiment: if the agent is heard after it, the player was stuck).
    func restartPlayback()
}

/// What happened to a Gemini call's sound on this device: what Gemini sent, what the player took and
/// finished, what the main mixer put out, and every change to the engine, route and session, with
/// times. Gemini's voice played in the simulator and on the Mac but not on an iPhone, and only the
/// device can say where it stops. Numbers, enums and port types only: never device names or words.
final class GeminiLiveAudioDiagnostics: @unchecked Sendable {
    static let log = Logger(subsystem: "app.loopdy.mobile", category: "LiveVoiceAudio")
    static let maximumEvents = 40

    struct Counts: Equatable {
        var receivedChunks = 0
        var receivedBytes = 0
        var scheduledBuffers = 0
        var droppedChunks = 0
        var finishedBuffers = 0
        /// Scheduled, then cleared by a player stop before they played: their completion runs too.
        var clearedBuffers = 0
        var configurationChanges = 0
        var routeChanges = 0
        var interruptions = 0
        var geminiStops = 0
        var engineRestarts = 0
    }

    private let lock = NSLock()
    private let clock: () -> Date
    private var startedAt: Date
    private var counts = Counts()
    private var events: [(at: TimeInterval, text: String)] = []
    private var windowPeak: Float = 0
    private var windowSquares: Double = 0
    private var windowFrames = 0
    private var loudest: Float = 0
    private var lastPlayerPosition: Int64?
    /// Player stops so far: a buffer counts as finished only if none came after it was scheduled.
    private var playerStops = 0

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        startedAt = clock()
    }

    func begin() {
        lock.withLock {
            startedAt = clock()
            counts = Counts()
            events = []
            windowPeak = 0; windowSquares = 0; windowFrames = 0; loudest = 0
            lastPlayerPosition = nil
            playerStops = 0
        }
    }

    /// Before each `player.stop()`: what the player holds then is cleared, not played.
    func playerStopping() { lock.withLock { playerStops += 1 } }

    var stopsSoFar: Int { lock.withLock { playerStops } }

    private func bufferCompleted(scheduledAfter stops: Int) {
        lock.withLock {
            if stops == playerStops { counts.finishedBuffers += 1 } else { counts.clearedBuffers += 1 }
        }
    }

    func event(_ text: String) {
        let at = lock.withLock { () -> TimeInterval in
            let at = clock().timeIntervalSince(startedAt)
            events.append((at, text))
            if events.count > Self.maximumEvents { events.removeFirst(events.count - Self.maximumEvents) }
            return at
        }
        Self.log.notice("\(String(format: "%.1f", at), privacy: .public) s \(text, privacy: .public)")
    }

    func count(_ change: (inout Counts) -> Void) { lock.withLock { change(&counts) } }

    var current: Counts { lock.withLock { counts } }

    /// The main mixer's output, from the audio thread.
    func meter(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        var peak: Float = 0
        var squares = 0.0
        let frames = Int(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            for index in 0..<frames {
                let sample = channels[channel][index]
                peak = max(peak, abs(sample))
                squares += Double(sample * sample)
            }
        }
        let samples = frames * Int(buffer.format.channelCount)
        lock.withLock {
            windowPeak = max(windowPeak, peak)
            windowSquares += squares
            windowFrames += samples
            loudest = max(loudest, peak)
        }
    }

    /// The mixer's peak and RMS since the last report, then starts a new window.
    private func takeWindow() -> (peak: Float, rms: Double, loudest: Float) {
        defer { windowPeak = 0; windowSquares = 0; windowFrames = 0 }
        return (windowPeak, windowFrames > 0 ? (windowSquares / Double(windowFrames)).squareRoot() : 0, loudest)
    }

    /// Built here, outside the main actor: the engine calls these on its audio threads.
    nonisolated static func mixerTap(_ diagnostics: GeminiLiveAudioDiagnostics) -> AVAudioNodeTapBlock {
        { buffer, _ in diagnostics.meter(buffer) }
    }

    /// A buffer's completion runs when it played and also when a player stop cleared it.
    nonisolated static func finished(_ diagnostics: GeminiLiveAudioDiagnostics,
                                     scheduledAfter stops: Int) -> AVAudioPlayerNodeCompletionHandler {
        { _ in diagnostics.bufferCompleted(scheduledAfter: stops) }
    }

    /// The report, from what the engine, player and session look like now.
    func report(_ state: GeminiLiveAudioState) -> String {
        lock.withLock {
            let now = clock().timeIntervalSince(startedAt)
            let window = takeWindow()
            let moving: String = switch (lastPlayerPosition, state.playerPosition) {
            case (_, nil): "no position"
            case (nil, .some): "first reading"
            case let (before?, after?): after > before ? "moving" : "not moving"
            }
            lastPlayerPosition = state.playerPosition ?? lastPlayerPosition
            return Self.text(seconds: now, counts: counts, mixer: window, moving: moving, state: state,
                             events: events, lastDeactivation: GeminiLiveAudioHold.lastDeactivation.map {
                                 $0.timeIntervalSince(startedAt) })
        }
    }

    static func text(seconds: TimeInterval, counts: Counts, mixer: (peak: Float, rms: Double, loudest: Float),
                     moving: String, state: GeminiLiveAudioState,
                     events: [(at: TimeInterval, text: String)], lastDeactivation: TimeInterval?) -> String {
        func level(_ value: Double) -> String { String(format: "%.3f", value) }
        let mixerLine = mixer.peak == 0 && mixer.rms == 0
            ? "silent" : "peak \(level(Double(mixer.peak))), RMS \(level(mixer.rms))"
        let deactivation: String = switch lastDeactivation {
        case nil: "none"
        case let at? where at < 0: String(format: "%.0f s before the call", -at)
        case let at?: String(format: "during the call, at %.1f s", at)
        }
        var lines = [
            String(format: "Call audio, %.0f s", seconds),
            "Gemini sent \(counts.receivedChunks) pieces (\(counts.receivedBytes / 1_024) KB); "
                + "\(counts.scheduledBuffers) scheduled, \(counts.droppedChunks) dropped (engine off), "
                + "\(counts.finishedBuffers) finished, \(counts.clearedBuffers) cleared",
            "Mixer output now: \(mixerLine); loudest so far \(level(Double(mixer.loudest)))",
            "Player: \(state.playerPlaying ? "playing" : "stopped"), position "
                + "\(state.playerPosition.map(String.init) ?? "none") (\(moving)); volume \(level(Double(state.playerVolume)))",
            "Engine: \(state.engineRunning ? "running" : "stopped"); voice processing \(state.voiceProcessing); "
                + "output \(state.outputFormat); mixer \(state.mixerFormat)",
            "Session: \(state.category), \(state.mode), volume \(level(Double(state.outputVolume))), "
                + "\(Int(state.sampleRate)) Hz; out \(state.outputs.joined(separator: "+")); in \(state.inputs.joined(separator: "+"))",
            "Changes: \(counts.configurationChanges) configuration, \(counts.routeChanges) route, "
                + "\(counts.interruptions) interruptions, \(counts.geminiStops) Gemini stops, \(counts.engineRestarts) engine restarts",
            "Last session deactivation: \(deactivation)",
            "Events:",
        ]
        lines += events.map { String(format: "%6.1f s ", $0.at) + $0.text }
        return lines.joined(separator: "\n")
    }
}

/// The engine, player and session as they are now, read on the main actor.
struct GeminiLiveAudioState: Sendable {
    var engineRunning = false
    var playerPlaying = false
    var playerPosition: Int64?
    var playerVolume: Float = 1
    var voiceProcessing = ""
    var outputFormat = ""
    var mixerFormat = ""
    var category = ""
    var mode = ""
    var outputVolume: Float = 0
    var sampleRate = 0.0
    var outputs: [String] = []
    var inputs: [String] = []

    @MainActor
    init(engine: AVAudioEngine, player: AVAudioPlayerNode, session: AVAudioSession = .sharedInstance()) {
        engineRunning = engine.isRunning
        playerPlaying = player.isPlaying
        if let render = player.lastRenderTime, let time = player.playerTime(forNodeTime: render) {
            playerPosition = time.sampleTime
        }
        playerVolume = player.volume
        voiceProcessing = "in \(engine.inputNode.isVoiceProcessingEnabled ? "on" : "off"), "
            + "out \(engine.outputNode.isVoiceProcessingEnabled ? "on" : "off")"
            + (engine.inputNode.isVoiceProcessingBypassed ? ", bypassed" : "")
        outputFormat = Self.describe(engine.outputNode.outputFormat(forBus: 0))
        mixerFormat = Self.describe(engine.mainMixerNode.outputFormat(forBus: 0))
        category = session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")
        mode = session.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: "")
        outputVolume = session.outputVolume
        sampleRate = session.sampleRate
        // Port types only: a port's name can be a person's ("Sam's AirPods").
        outputs = session.currentRoute.outputs.map { Self.short($0.portType) }
        inputs = session.currentRoute.inputs.map { Self.short($0.portType) }
    }

    init() {}

    private static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate)) Hz × \(format.channelCount)"
    }

    private static func short(_ port: AVAudioSession.Port) -> String {
        port.rawValue.replacingOccurrences(of: "AVAudioSessionPort", with: "")
    }
}
