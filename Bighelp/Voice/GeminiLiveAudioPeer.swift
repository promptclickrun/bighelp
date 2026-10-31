import AVFoundation
import Foundation

/// Full Duplex on Gemini Live: the phone's own WebSocket to Gemini, opened with the plugin's single-use
/// token, and one voice-processing audio engine. Voice processing cancels the agent's voice from the
/// microphone without muting it, so the person can talk over the agent and it stops.
@MainActor
final class GeminiLiveAudioPeer: LiveVoiceAudioPeer, LiveVoiceLocalSession {
    var onConnectionState: (@MainActor (BighelpRealtimeAudioPeer.ConnectionState) -> Void)?
    var onAudioRoute: (@MainActor (String) -> Void)?
    var onInterruption: (@MainActor (Bool) -> Void)?
    var onEvent: (@MainActor ([String: BighelpJSONValue]) -> Void)?

    private let sessionCoordinator: VoiceAudioSessionCoordinator
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let uplink = GeminiLiveUplink()
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: GeminiLiveWire.outputSampleRate,
                                               channels: 1, interleaved: false)!
    private let hold = GeminiLiveAudioHold()
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var translator = GeminiLiveTranslator()
    private var observers: [any NSObjectProtocol] = []
    private var state: BighelpRealtimeAudioPeer.ConnectionState = .idle
    private var received = (bytes: UInt64(0), frames: UInt64(0))
    private var outputLevel = (value: 0.0, at: Date.distantPast)
    /// When the audio already scheduled finishes playing: Gemini sends it faster than it plays.
    private var playbackEndsAt = Date.distantPast
    /// The newest audio or words of Gemini's reply.
    private var lastOutputAt = Date.distantPast
    /// Since Gemini heard the person start talking.
    private var personSpeakingSince: Date?
    /// News for the voice model, waiting for a quiet moment (`sendText`).
    private var pendingTexts: [String] = []
    private var awaitingReplySince: Date?
    private var quietDelivery: Task<Void, Never>?
    private var speakerOutputPolicy: BighelpSpeakerOutputPolicy = .none
    private var closed = false

    init(sessionCoordinator: VoiceAudioSessionCoordinator = .shared) {
        self.sessionCoordinator = sessionCoordinator
    }

    /// Gemini has no SDP. This takes the microphone and the audio session, so the permission prompt
    /// comes with Start, as it does for GPT-Live.
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
        guard !closed, case let .gemini(url, token, model) = answer else {
            throw BighelpRealtimeAudioPeer.Failure.invalidSDP
        }
        var request = URLRequest(url: url)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = GeminiLiveWire.maximumFrameBytes
        socket = task
        publish(.connecting)
        task.resume()
        do {
            try await task.send(.string(String(decoding: GeminiLiveWire.setup(model: model), as: UTF8.self)))
        } catch {
            throw BighelpRealtimeAudioPeer.Failure.negotiation
        }
        receiver = Task { [weak self] in await self?.receive(from: task) }
    }

    // MARK: LiveVoiceLocalSession

    /// Text goes in as the person's turn, and Gemini answers it at once, cutting off whatever it is
    /// saying. So news waits until nobody is speaking and the phone has played what it already has,
    /// and goes one at a time: a result never talks over another one, or over the person.
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

    func answerFunction(id: String, name: String, response: [String: BighelpJSONValue]) {
        send(GeminiLiveWire.functionResponse(id: id, name: name, response: response))
    }

    /// Nobody is speaking: Gemini isn't generating, its audio has finished playing (with a short
    /// pause after it), the person isn't talking, and the last news already got its reply started.
    /// A reply that went quiet without its turnComplete, or speech whose end Gemini never sent, stops
    /// counting after a while, so news is never held for good.
    nonisolated static func isQuiet(replying: Bool, lastOutputAt: Date, personSpeakingSince: Date?, now: Date,
                                    playbackEndsAt: Date, awaitingReplySince: Date?) -> Bool {
        let stillReplying = replying && now.timeIntervalSince(lastOutputAt) < 3
        let personSpeaking = personSpeakingSince.map { now.timeIntervalSince($0) < 30 } ?? false
        guard !stillReplying, !personSpeaking, now >= playbackEndsAt.addingTimeInterval(0.6) else { return false }
        guard let awaitingReplySince else { return true }
        return now.timeIntervalSince(awaitingReplySince) > 5
    }

    private func deliverIfQuiet() {
        if translator.isReplying { awaitingReplySince = nil }
        guard Self.isQuiet(replying: translator.isReplying, lastOutputAt: lastOutputAt,
                           personSpeakingSince: personSpeakingSince, now: Date(),
                           playbackEndsAt: playbackEndsAt, awaitingReplySince: awaitingReplySince),
              !pendingTexts.isEmpty else { return }
        awaitingReplySince = Date()
        send(GeminiLiveWire.text(pendingTexts.removeFirst()))
    }

    // MARK: Audio controls

    func setMuted(_ muted: Bool) {
        uplink.setMuted(muted)
        if muted {
            translator.personStoppedSpeaking()
            personSpeakingSince = nil
        }
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

    /// iOS forgets the speaker whenever the route changes (the engine's voice processing starting, a
    /// configuration change, an interruption), so it's chosen again each time, as GPT-Live's peer does.
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
            try engine.start()
        } catch {
            throw BighelpRealtimeAudioPeer.Failure.audioUnavailable
        }
        player.play()
        try? reapplySpeakerOutputIfNeeded()
    }

    func statistics() async throws -> BighelpRealtimeAudioPeer.MediaStatistics {
        var statistics = BighelpRealtimeAudioPeer.MediaStatistics()
        let sent = uplink.counters
        statistics.bytesSent = sent.bytes
        statistics.packetsSent = sent.frames
        statistics.inputAudioLevel = sent.level
        statistics.bytesReceived = received.bytes
        statistics.packetsReceived = received.frames
        // Gemini sends audio ahead of playback; the level fades once nothing new arrives.
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
            // Before the engine starts: the route and configuration changes its start causes are the
            // ones that matter.
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
        let format = input.outputFormat(forBus: 0)
        try uplink.prepare(from: format)
        input.installTap(onBus: 0, bufferSize: 2_048, format: format, block: GeminiLiveUplink.tap(uplink))
        engine.prepare()
        try engine.start()
        player.play()
    }

    /// AirPods, a car or a sample-rate change stop the engine and change the input's format.
    private func restartAfterConfigurationChange() {
        guard !closed, hold.isHeld else { return }
        do {
            try SystemVoiceAudioSession().setActive(true)
            try startEngine()
        } catch {
            publish(.failed)
            return
        }
        try? reapplySpeakerOutputIfNeeded()
    }

    private func stopAudio() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        player.stop()
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
                // Gemini ended the session (it sends goAway first), or the network went away: the
                // call is over, and work it started keeps going in the chat.
                if socket === task, !closed { onEvent?(["kind": .string("closed")]) }
                return
            }
            guard socket === task, !closed else { return }
            for message in GeminiLiveWire.decode(frame) {
                if message == .setupComplete {
                    // Audio before the session is set up is not Gemini's order.
                    uplink.attach(task)
                    publish(.connected)
                }
                switch message {
                case .audio, .assistantText: lastOutputAt = Date()
                default: break
                }
                for output in translator.outputs(for: message) { perform(output) }
                if !translator.isUserSpeaking { personSpeakingSince = nil }
                else if personSpeakingSince == nil { personSpeakingSince = Date() }
            }
        }
    }

    private func perform(_ output: GeminiLiveTranslator.Output) {
        switch output {
        case .event(let event): onEvent?(event)
        case .play(let pcm): play(pcm)
        case .stopPlayback:
            player.stop()
            playbackEndsAt = Date()
            uplink.agentPlays(until: playbackEndsAt)
            // play() on a stopped engine raises an exception Swift can't catch.
            if engine.isRunning { player.play() }
        case let .answer(id, name, response, silent):
            send(GeminiLiveWire.functionResponse(id: id, name: name, response: response, silent: silent))
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
        playbackEndsAt = max(now, playbackEndsAt).addingTimeInterval(Double(count) / GeminiLiveWire.outputSampleRate)
        uplink.agentPlays(until: playbackEndsAt)
        player.scheduleBuffer(buffer)
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

/// The live-call lease and the active audio session. A peer dropped without `close()` (a call that ended
/// while the microphone prompt was up) still releases them, or every later TTS and call would be refused.
final class GeminiLiveAudioHold: @unchecked Sendable {
    private let lock = NSLock()
    private var lease: VoiceAudioSessionLiveCallLease?
    private var sessionActive = false

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lease != nil
    }

    func take(_ lease: VoiceAudioSessionLiveCallLease) {
        lock.lock()
        defer { lock.unlock() }
        self.lease = lease
    }

    func sessionActivated() {
        lock.lock()
        defer { lock.unlock() }
        sessionActive = true
    }

    func release() {
        lock.lock()
        let lease = self.lease
        let active = sessionActive
        self.lease = nil
        sessionActive = false
        lock.unlock()
        if active { try? SystemVoiceAudioSession().setActive(false) }
        lease?.release()
    }

    deinit { release() }
}

/// The microphone side, used from the audio thread: it converts to 16 kHz 16-bit mono and sends
/// 100 ms pieces straight to Gemini. Nothing here touches the main actor.
final class GeminiLiveUplink: @unchecked Sendable {
    private static let chunkBytes = Int(GeminiLiveWire.inputSampleRate / 10) * 2
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?
    private var pending = Data()
    private var muted = false
    private var level = 0.0
    private var bytes: UInt64 = 0
    private var frames: UInt64 = 0
    private var echoGate = GeminiLiveEchoGate()
    /// When the agent's voice already scheduled stops playing (`timeIntervalSinceReferenceDate`).
    private var agentPlaysUntil = 0.0

    var counters: (bytes: UInt64, frames: UInt64, level: Double, muted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (bytes, frames, muted ? 0 : level, muted)
    }

    func prepare(from format: AVAudioFormat) throws {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: GeminiLiveWire.inputSampleRate,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw BighelpRealtimeAudioPeer.Failure.audioUnavailable
        }
        lock.lock()
        defer { lock.unlock() }
        self.target = target
        self.converter = converter
    }

    func attach(_ socket: URLSessionWebSocketTask) {
        lock.lock()
        defer { lock.unlock() }
        self.socket = socket
        pending.removeAll()
    }

    func detach() {
        lock.lock()
        defer { lock.unlock() }
        socket = nil
        pending.removeAll()
    }

    func setMuted(_ muted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.muted = muted
        if muted { pending.removeAll() }
    }

    /// The agent's voice plays until then; the echo it leaves in the room fades a moment after.
    func agentPlays(until end: Date) {
        lock.lock()
        defer { lock.unlock() }
        agentPlaysUntil = end.timeIntervalSinceReferenceDate + GeminiLiveEchoGate.echoTail
    }

    /// Built here, outside the main actor: the engine calls it on its realtime thread.
    static func tap(_ uplink: GeminiLiveUplink) -> AVAudioNodeTapBlock {
        { buffer, _ in uplink.push(buffer) }
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        level = Self.level(of: buffer)
        guard !muted, let socket, let converter, let target, buffer.frameLength > 0 else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var failure: NSError?
        _ = converter.convert(to: output, error: &failure) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard failure == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
        pending.append(Data(bytes: samples, count: Int(output.frameLength) * 2))
        let playing = Date().timeIntervalSinceReferenceDate < agentPlaysUntil
        while pending.count >= Self.chunkBytes {
            let chunk = Data(pending.prefix(Self.chunkBytes))
            pending.removeFirst(Self.chunkBytes)
            for piece in echoGate.pass(chunk, level: Self.level(of: chunk), agentPlaying: playing) {
                bytes &+= UInt64(piece.count)
                frames &+= 1
                socket.send(.string(String(decoding: GeminiLiveWire.audio(piece), as: UTF8.self))) { _ in }
            }
        }
    }

    /// RMS of 16-bit little-endian samples, 0–1.
    private static func level(of pcm: Data) -> Double {
        let count = pcm.count / 2
        guard count > 0 else { return 0 }
        let sum = pcm.withUnsafeBytes { raw in
            (0..<count).reduce(0.0) { total, index in
                let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32_768
                return total + sample * sample
            }
        }
        return (sum / Double(count)).squareRoot()
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        return Double((sum / Float(buffer.frameLength)).squareRoot())
    }
}

/// The microphone while the agent's voice plays, one 100 ms chunk at a time. Echo cancelling never
/// takes all of the agent's voice out of the microphone, and Gemini stops talking for its own voice
/// however faint (and for a room that starts talking under a reply), so the first replies of a call,
/// before echo cancelling settles, were cut off before they could be heard. While the agent plays, Gemini
/// gets silence unless the person talks over it: two chunks in a row clearly louder than the room was
/// while the agent was quiet. Then the microphone stays open half a second after the last loud chunk,
/// and the first loud chunk goes too, so Gemini hears the start of the words. Measured on the real
/// service: the agent's echo and a TV under its reply no longer cut it off; talking over it still does.
struct GeminiLiveEchoGate {
    /// The quietest talking over the agent that opens the microphone, above the loudest echo measured.
    static let minimumLevel = 0.06
    /// How much louder than the room the person must be.
    static let roomFactor = 2.5
    static let echoTail: TimeInterval = 0.3
    private static let openChunks = 5
    private static let roomChunks = 20

    private var room: [Double] = []
    private var loudRun = 0
    private var openFor = 0
    private var held: Data?

    /// What to send for `chunk`, whose RMS is `level`: the chunk, silence, or the held chunk and this one.
    mutating func pass(_ chunk: Data, level: Double, agentPlaying: Bool) -> [Data] {
        if !agentPlaying {
            room.append(level)
            if room.count > Self.roomChunks { room.removeFirst(room.count - Self.roomChunks) }
        }
        let roomLevel = room.isEmpty ? 0 : room.sorted()[Int(0.3 * Double(room.count - 1))]
        let loud = level >= max(Self.minimumLevel, Self.roomFactor * roomLevel)
        loudRun = loud ? loudRun + 1 : 0
        let previous = held
        held = loud ? chunk : nil
        if loudRun >= 2 {
            let opening = openFor == 0
            openFor = Self.openChunks
            if opening, agentPlaying, let previous { return [previous, chunk] }
            return [chunk]
        }
        if openFor > 0 {
            openFor -= 1
            return [chunk]
        }
        return agentPlaying ? [Data(count: chunk.count)] : [chunk]
    }
}
