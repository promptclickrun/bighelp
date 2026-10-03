import AVFoundation
import Foundation

/// Where TTS voice turns are turned into text.
enum VoiceTranscriptionSource: String, CaseIterable, Identifiable, Sendable {
    /// Apple's on-device speech recognition.
    case onDevice
    /// The speech-to-text provider set up in Hermes on the computer.
    case hermes

    var id: Self { self }

    var title: String {
        switch self {
        case .onDevice: "This device"
        case .hermes: "Hermes"
        }
    }

    var detail: String {
        switch self {
        case .onDevice:
            "Apple's speech recognition turns what you say into text right on this device."
        case .hermes:
            "Your computer turns what you say into text with the speech-to-text provider set up in Hermes."
        }
    }
}

/// Decides when someone has finished talking. People pause mid-thought, and
/// longer messages have longer pauses, so the quiet it waits for grows with how
/// long they've been talking, and a sentence left hanging ("…and", "…the")
/// gets extra time. Nothing ends before there's speech to end.
@MainActor
final class VoiceEndOfSpeechDetector {
    private let baseSilence: Duration
    private let maximumSilence: Duration
    private let activityThreshold: Float
    private let onEndOfSpeech: () -> Void
    /// Without live words to go on (Hermes transcription with no on-device
    /// captions), sustained voice counts as speech.
    var countsVoiceAsSpeech = false
    /// A cap on the pause from the host's settings (`voice.silence_duration`).
    var silenceLimit: Duration?
    private var hasSpeech = false
    private var accumulatedSilence: Duration = .zero
    /// Live words so far, and how long they've stayed the same. Road noise can keep
    /// the microphone from ever sounding quiet; words that stopped still end the turn.
    private var lastText: String?
    private var sinceWordsChanged: Duration = .zero
    private let wordsStoppedGrace: Duration = .seconds(2.5)
    private var talkingTime: Duration = .zero
    private var voiceTime: Duration = .zero
    private var lastWord: String?

    init(
        baseSilence: Duration = .seconds(1.8),
        maximumSilence: Duration = .seconds(4.5),
        activityThreshold: Float = 0.08,
        onEndOfSpeech: @escaping () -> Void
    ) {
        self.baseSilence = baseSilence
        self.maximumSilence = maximumSilence
        self.activityThreshold = activityThreshold
        self.onEndOfSpeech = onEndOfSpeech
    }

    /// Words that don't end a thought: the speaker is still going.
    nonisolated static let continuationWords: Set<String> = [
        "and", "but", "or", "so", "because", "cause", "the", "a", "an", "to", "of", "with", "that", "which",
        "if", "when", "then", "also", "plus", "like", "um", "uh", "er", "hmm", "my", "your", "our", "their",
        "is", "are", "was", "were", "i", "i'm", "we", "you", "it's", "and then", "maybe", "actually",
    ]

    /// How much quiet ends this turn.
    var requiredSilence: Duration {
        // A thirty-second message waits about a second longer than a quick question.
        let talked = min(talkingTime / .seconds(1), 45)
        var silence = baseSilence + .milliseconds(Int(talked * 35))
        if let lastWord, Self.continuationWords.contains(lastWord) { silence += .seconds(1.2) }
        return min(silence, maximumSilence, silenceLimit ?? maximumSilence)
    }

    func receiveTranscript(_ update: VoiceRecognitionUpdate) {
        if update.isFinal {
            reset()
            return
        }
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\0") else { return }
        hasSpeech = true
        accumulatedSilence = .zero
        lastWord = Self.trailingWord(text)
        if text != lastText {
            lastText = text
            sinceWordsChanged = .zero
        }
    }

    func receiveLevel(_ level: Float, duration: Duration) {
        guard duration > .zero else { return }
        if level >= activityThreshold {
            // Sound but no new words (only while noisy; real quiet is handled below).
            if lastText != nil, hasSpeech {
                sinceWordsChanged += duration
                if sinceWordsChanged >= requiredSilence + wordsStoppedGrace {
                    reset()
                    onEndOfSpeech()
                    return
                }
            }
            accumulatedSilence = .zero
            if countsVoiceAsSpeech {
                voiceTime += duration
                if voiceTime >= .milliseconds(500) { hasSpeech = true }
            }
            if hasSpeech { talkingTime += duration }
            return
        }
        guard hasSpeech else { return }
        accumulatedSilence += duration
        guard accumulatedSilence >= requiredSilence else { return }
        reset()
        onEndOfSpeech()
    }

    func reset() {
        hasSpeech = false
        lastText = nil
        sinceWordsChanged = .zero
        accumulatedSilence = .zero
        talkingTime = .zero
        voiceTime = .zero
        lastWord = nil
    }

    /// The last word, lowercased, or nil when the text ends a sentence.
    nonisolated static func trailingWord(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".?!".contains(last) else { return nil }
        let words = trimmed.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
        guard let word = words.last else { return nil }
        let normalized = word.replacingOccurrences(of: "’", with: "'")
        if normalized == "then", words.count >= 2, words[words.count - 2] == "and" { return "and then" }
        return String(normalized)
    }
}

/// One spoken turn's text across the recognizer's segments. After a pause,
/// Apple's recognizer on iOS 18 starts a new segment and drops the words
/// before it; newer systems keep them. Either way nothing said is lost.
struct VoiceTranscriptAccumulator: Equatable, Sendable {
    private(set) var committed = ""
    private(set) var segment = ""

    var text: String { Self.combine(committed, segment) }

    /// A result from the current recognition. `segmentEnded` marks the end of
    /// an utterance (the recognizer's metadata, a final result, or a restart).
    mutating func receive(_ text: String, segmentEnded: Bool) {
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A shorter result that no longer starts like the last one means the
        // recognizer started over after a pause: keep what it had.
        if Self.startedOver(from: segment, to: incoming) {
            committed = Self.combine(committed, segment)
        }
        segment = incoming
        if segmentEnded { commitSegment() }
    }

    /// Keeps the current words when the recognizer is replaced mid-turn.
    mutating func commitSegment() {
        committed = Self.combine(committed, segment)
        segment = ""
    }

    mutating func reset() {
        committed = ""
        segment = ""
    }

    private static func combine(_ committed: String, _ segment: String) -> String {
        guard !committed.isEmpty else { return segment }
        guard !segment.isEmpty else { return committed }
        // A recognizer that kept everything repeats the committed words first
        // (maybe with its last word revised).
        let kept = words(committed)
        let next = words(segment)
        let prefix = kept.dropLast(kept.count > 1 ? 1 : 0)
        if next.count >= kept.count, next.starts(with: prefix) { return segment }
        return committed + " " + segment
    }

    /// A long result replaced by one less than half its length that starts
    /// differently: a fresh utterance, not a revision of the same words.
    private static func startedOver(from previous: String, to next: String) -> Bool {
        let before = words(previous)
        let after = words(next)
        guard before.count >= 5, !after.isEmpty, after.count * 2 <= before.count else { return false }
        return before.first != after.first
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}

/// A spoken turn's audio for Hermes to transcribe: 16 kHz mono 16-bit WAV in a
/// private temporary file, removed as soon as it's read. Used from the audio
/// tap thread behind the buffer gate's lock.
final class VoiceTurnRecorder: @unchecked Sendable {
    /// Hermes accepts 25 MB; twelve minutes of this WAV is about 23 MB.
    static let maximumSeconds: Double = 12 * 60
    static let sampleRate: Double = 16_000

    private let url: URL
    private var file: AVAudioFile?
    /// Replaced when the input's format changes mid-turn (a car or headset taking over).
    private var converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private(set) var recordedSeconds: Double = 0

    init(inputFormat: AVAudioFormat) throws {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: output) else {
            throw VoiceInputLevelError.engineFailed
        }
        outputFormat = output
        self.converter = converter
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bighelp-voice-\(UUID().uuidString.lowercased()).wav")
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Adds one tap buffer. False once the turn is as long as Hermes accepts.
    func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let file, buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return file != nil }
        if buffer.format != converter.inputFormat {
            guard let replacement = AVAudioConverter(from: buffer.format, to: outputFormat) else { return true }
            converter = replacement
        }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return true }
        let input = VoiceConverterInput(buffer)
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in input.next(status) }
        guard error == nil, converted.frameLength > 0 else { return true }
        do { try file.write(from: converted) } catch { return true }
        recordedSeconds += Double(converted.frameLength) / Self.sampleRate
        return recordedSeconds < Self.maximumSeconds
    }

    /// The finished WAV, or nil if nothing was recorded. The file is removed.
    func finish() -> Data? {
        file = nil
        defer { try? FileManager.default.removeItem(at: url) }
        guard recordedSeconds > 0 else { return nil }
        return try? Data(contentsOf: url)
    }

    func discard() {
        file = nil
        try? FileManager.default.removeItem(at: url)
    }
}

/// Feeds one buffer to the converter, then reports that no more is ready.
private final class VoiceConverterInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
