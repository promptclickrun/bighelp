import AVFoundation
import Foundation

/// Full Duplex on a speech server the person runs themselves: the phone's own WebSocket to that
/// server, and the same one voice-processing audio engine Gemini Live uses. The server hears and
/// speaks; every request goes to Hermes through the chat, and Hermes' answer comes back to the
/// server to be read out.
///
/// This is deliberately its own peer rather than a mode inside Gemini's: a fault here can only
/// cost a call on a server the person chose, never the shipped Gemini path. The microphone
/// pipeline (`GeminiLiveUplink`), the echo gate and the call's audio lease are shared, so the two
/// peers differ only in what they put on the wire.
@MainActor
final class SpeechServerAudioPeer: LiveVoiceAudioPeer, LiveVoiceLocalSession {
    var onConnectionState: (@MainActor (BighelpRealtimeAudioPeer.ConnectionState) -> Void)?
    var onAudioRoute: (@MainActor (String) -> Void)?
    var onInterruption: (@MainActor (Bool) -> Void)?
    var onEvent: (@MainActor ([String: BighelpJSONValue]) -> Void)?

    private let agentName: String
    /// The voice the person chose for this agent, passed on the offer; a server may ignore it.
    private var voice = "default"
    private let sessionCoordinator: VoiceAudioSessionCoordinator
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let uplink = GeminiLiveUplink(sampleRate: SpeechServerWire.inputSampleRate,
                                          encoder: SpeechServerWire.audio)
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: SpeechServerWire.outputSampleRate,
                                               channels: 1, interleaved: false)!
    private let hold = GeminiLiveAudioHold()
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private let translator = SpeechServerTranslator()
    private var observers: [any NSObjectProtocol] = []
    private var state: BighelpRealtimeAudioPeer.ConnectionState = .idle
    private var received = (bytes: UInt64(0), frames: UInt64(0))
    private var outputLevel = (value: 0.0, at: Date.distantPast)
    /// When the audio already scheduled finishes playing: a server sends it faster than it plays.
    private var playbackEndsAt = Date.distantPast
    /// The newest audio or words of the reply.
    private var lastOutputAt = Date.distantPast
    /// Since the server heard the person start talking.
    private var personSpeakingSince: Date?
    /// News for the person, waiting for a quiet moment (`sendText`).
    private var pendingTexts: [String] = []
    private var awaitingReplySince: Date?
    private var quietDelivery: Task<Void, Never>?
    private var speakerOutputPolicy: BighelpSpeakerOutputPolicy = .none
    /// The server accepted the session (`session.created`/`session.updated`).
    private var ready = false
    private var closed = false

    init(agentName: String, sessionCoordinator: VoiceAudioSessionCoordinator = .shared) {
        self.agentName = agentName
        self.sessionCoordinator = sessionCoordinator
    }

    /// A speech server has no SDP. This takes the microphone and the audio session, so the
    /// permission prompt comes with Start, as it does for GPT-Live.
    func makeOffer() async throws -> String {
        guard !closed else { throw BighelpRealtimeAudioPeer.Failure.closed }
        let granted = await AVAudioApplication.requestRecordPermission()
        // The call may have ended while the prompt was up: never take audio for a closed peer.
        try Task.checkCancellation()
        guard !closed else { throw BighelpRealtimeAudioPeer.Failure.closed }
        guard granted else { throw BighelpRealtimeAudioPeer.Failure.microphoneDenied }
        try startAudio()
        return ""
    }

    func applyAnswer(_ sdp: String) async throws {
        throw BighelpRealtimeAudioPeer.Failure.invalidSDP
    }

    func apply(_ answer: LiveVoiceAnswer) async throws {
        guard !closed, case let .speechServer(url, key, chosen) = answer else {
            throw BighelpRealtimeAudioPeer.Failure.invalidSDP
        }
        voice = chosen
        var request = URLRequest(url: url)
        // Many private servers have no key at all; one that does wants it in the handshake.
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = SpeechServerWire.maximumFrameBytes
        socket = task
        publish(.connecting)
        task.resume()
        do {
            let setup = SpeechServerWire.sessionUpdate(agentName: agentName, voice: voice)
            try await task.send(.string(String(decoding: setup, as: UTF8.self)))
        } catch {
            // The socket never opened: the server refused it, or the network failed on the way.
            guard !closed else { throw error }
            onEvent?(["kind": .string("closed")])
            throw BighelpRealtimeAudioPeer.Failure.audioUnavailable
        }
        receiver = Task { [weak self] in await self?.receive(from: task) }
    }

    // MARK: LiveVoiceLocalSession

    /// Hermes' answer, read out by the server. A `response.create` interrupts whatever it is
    /// saying, so news waits until nobody is speaking and the phone has played what it already
    /// has, and goes one at a time: a result never talks over another one, or over the person.
    func sendText(_ text: String) {
        guard !closed else { return }
        pendingTexts.append(text)
        guard quietDelivery == nil else { return }
        quietDelivery = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.closed, !self.pendingTexts.isEmpty else { break }
                self.deliverIfQuiet()
                try? await Task.sleep(for: .milliseconds(250))
            }
            self?.quietDelivery = nil
        }
    }

    /// The server has no functions of its own: anything it says is either audio or a transcript.
    func answerFunction(id: String, name: String, response: [String: BighelpJSONValue]) {}

    private func deliverIfQuiet() {
        if translator.isReplying { awaitingReplySince = nil }
        guard GeminiLiveAudioPeer.isQuiet(replying: translator.isReplying, lastOutputAt: lastOutputAt,
                                          personSpeakingSince: personSpeakingSince, now: Date(),
                                          playbackEndsAt: playbackEndsAt, awaitingReplySince: awaitingReplySince),
              !pendingTexts.isEmpty else { return }
        awaitingReplySince = Date()
        send(SpeechServerWire.speak(pendingTexts.removeFirst()))
    }

    // MARK: Audio controls

    func setMuted(_ muted: Bool) {
        uplink.setMuted(muted)
        if muted { personSpeakingSince = nil }
    }

    func setPlaybackMuted(_ muted: Bool) { player.volume = muted ? 0 : 1 }

    func setSpeakerEnabled(_ enabled: Bool) throws {
        guard !closed, hold.isHeld else { throw BighelpRealtimeAudioPeer.Failure.closed }
        do { try AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none) }
        catch { throw BighelpRealtimeAudioPeer.Failure.audioUnavailable }
        speakerOutputPolicy = enabled ? .forceSpeaker : .systemRoute
        onAudioRoute?(Self.routeName())
    }

    /// The built-in speaker for a fresh call, unless the person already chose headphones or a car.
    func setDefaultSpeakerOutput() throws {
        guard !closed, hold.isHeld else { throw BighelpRealtimeAudioPeer.Failure.closed }
        speakerOutputPolicy = .defaultSpeaker
        try reapplySpeakerOutputIfNeeded()
    }

    /// iOS forgets the speaker whenever the route changes, so it's chosen again each time.
    private func reapplySpeakerOutputIfNeeded() throws {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        let external = outputs.contains { !($0.portType == .builtInReceiver || $0.portType == .builtInSpeaker) }
        if BighelpRealtimeAudioPeer.shouldApplySpeakerOutput(
            policy: speakerOutputPolicy, hasExternalRoute: external,
            currentBuiltInSpeaker: outputs.contains { $0.portType == .builtInSpeaker }) {
            do { try session.overrideOutputAudioPort(.speaker) }
            catch { throw BighelpRealtimeAudioPeer.Failure.audioUnavailable }
        }
        onAudioRoute?(Self.routeName())
    }

    func resumeAudio() throws {
        guard !closed, hold.isHeld else { throw BighelpRealtimeAudioPeer.Failure.closed }
        guard !engine.isRunning else { return }
        do {
            try SystemVoiceAudioSession().setActive(true)
            try Self.restart(player) {
                try engine.start()
                player.play()
            }
        } catch {
            throw BighelpRealtimeAudioPeer.Failure.audioUnavailable
        }
        playbackEndsAt = Date()
        uplink.agentPlays(until: playbackEndsAt)
        try? reapplySpeakerOutputIfNeeded()
    }

    /// Starts the engine again after it stopped (a configuration change, the end of an interruption).
    /// The player stops first: started again while it still said it was playing, it took every new
    /// piece of audio and played none.
    static func restart(_ player: AVAudioPlayerNode, start: () throws -> Void) rethrows {
        player.stop()
        try start()
    }

    func statistics() async throws -> BighelpRealtimeAudioPeer.MediaStatistics {
        var statistics = BighelpRealtimeAudioPeer.MediaStatistics()
        let sent = uplink.counters
        statistics.bytesSent = sent.bytes
        statistics.packetsSent = sent.frames
        statistics.inputAudioLevel = sent.level
        statistics.bytesReceived = received.bytes
        statistics.packetsReceived = received.frames
        // A server sends audio ahead of playback; the level fades once nothing new arrives.
        statistics.outputAudioLevel = Date().timeIntervalSince(outputLevel.at) < 0.4 ? outputLevel.value : 0
        statistics.audioDeviceRunning = engine.isRunning
        statistics.peerConnectionState = state.rawValue
        statistics.localSenderTrackEnabled = !sent.muted
        statistics.inputRoutePresent = !AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty
        return statistics
    }

    func close() {
        guard !closed else { return }
        closed = true
        quietDelivery?.cancel()
        pendingTexts.removeAll()
        receiver?.cancel()
        receiver = nil
        uplink.detach()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        stopAudio()
    }

    // MARK: Private

    private func startAudio() throws {
        guard !hold.isHeld else { return }
        guard let lease = try? sessionCoordinator.holdForLiveCall() else {
            throw BighelpRealtimeAudioPeer.Failure.busy
        }
        hold.take(lease)
        do {
            let session = SystemVoiceAudioSession()
            try session.configureForLiveCall()
            try session.setActive(true)
            hold.sessionActivated()
            try engine.inputNode.setVoiceProcessingEnabled(true)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            // Before the engine starts: the route and configuration changes its start causes are
            // the ones that matter.
            observeSession()
            try startEngine()
        } catch {
            stopAudio()
            throw BighelpRealtimeAudioPeer.Failure.audioUnavailable
        }
        onAudioRoute?(Self.routeName())
    }

    /// (Re)builds the microphone side for the input's current format and starts the engine.
    private func startEngine() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        try uplink.prepare(from: input.outputFormat(forBus: 0))
        input.installTap(onBus: 0, bufferSize: 2_048, format: input.outputFormat(forBus: 0),
                         block: GeminiLiveUplink.tap(uplink))
        engine.prepare()
        try engine.start()
        player.play()
    }

    /// AirPods, a car or a sample-rate change stop the engine and change the input's format.
    private func restartAfterConfigurationChange() {
        guard !closed, hold.isHeld else { return }
        do {
            try SystemVoiceAudioSession().setActive(true)
            try Self.restart(player) { try startEngine() }
        } catch {
            publish(.failed)
            return
        }
        // What was scheduled went with the stopped player.
        playbackEndsAt = Date()
        uplink.agentPlays(until: playbackEndsAt)
        try? reapplySpeakerOutputIfNeeded()
    }

    private func stopAudio() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        // Never attached when the call ended before its audio started: stop() would raise.
        if player.engine != nil { player.stop() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        hold.release()
    }

    private func receive(from task: URLSessionWebSocketTask) async {
        while !Task.isCancelled, socket === task {
            let frame: Data
            do {
                switch try await task.receive() {
                case .data(let data): frame = data
                case .string(let text): frame = Data(text.utf8)
                @unknown default: continue
                }
            } catch {
                // The server closed the session or the network went away: the call is over, and
                // work it started keeps going.
                guard socket === task, !closed else { return }
                publish(.failed)
                onEvent?(["kind": .string("closed")])
                return
            }
            guard socket === task, !closed else { return }
            for message in SpeechServerWire.decode(frame) {
                if message == .ready, !ready {
                    // Audio before the session is accepted is not the server's order.
                    ready = true
                    uplink.attach(task)
                    publish(.connected)
                }
                switch message {
                case .audio, .assistantText: lastOutputAt = Date()
                case .personSpoke: personSpeakingSince = Date()
                default: break
                }
                for output in translator.outputs(for: message) { perform(output) }
            }
        }
    }

    private func perform(_ output: SpeechServerTranslator.Output) {
        switch output {
        case .event(let event): onEvent?(event)
        case .play(let pcm): play(pcm)
        case .stopPlayback:
            player.stop()
            playbackEndsAt = Date()
            uplink.agentPlays(until: playbackEndsAt)
            // play() on a stopped engine raises an exception Swift can't catch.
            if engine.isRunning { player.play() }
        case .answer:
            break // The server has no functions; nothing to answer.
        }
    }

    /// 24 kHz 16-bit little-endian mono, scheduled behind what is already playing.
    private func play(_ pcm: Data) {
        let count = pcm.count / 2
        guard count > 0, engine.isRunning,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        var peak: Float = 0
        pcm.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32_768
                channel[index] = sample
                peak = max(peak, abs(sample))
            }
        }
        received.bytes &+= UInt64(pcm.count)
        received.frames &+= 1
        let now = Date()
        outputLevel = (Double(peak), now)
        playbackEndsAt = max(now, playbackEndsAt).addingTimeInterval(Double(count) / SpeechServerWire.outputSampleRate)
        uplink.agentPlays(until: playbackEndsAt)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func send(_ frame: Data) {
        guard let socket, !closed else { return }
        socket.send(.string(String(decoding: frame, as: UTF8.self))) { _ in }
    }

    private func publish(_ next: BighelpRealtimeAudioPeer.ConnectionState) {
        guard state != next else { return }
        state = next
        onConnectionState?(next)
    }

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if !began {
                    do { try self.resumeAudio() } catch {
                        self.publish(.failed)
                        return
                    }
                }
                self.onInterruption?(began)
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAfterConfigurationChange() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.closed, self.hold.isHeld else { return }
                try? self.reapplySpeakerOutputIfNeeded()
            }
        })
    }

    private static func routeName() -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? ""
    }
}
