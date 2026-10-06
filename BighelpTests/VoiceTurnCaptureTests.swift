import AVFoundation
import Foundation
import Testing
@testable import Bighelp

/// Hands-free voice must not send a message halfway through: it waits for a
/// real pause (longer for longer messages and sentences left hanging), and it
/// never loses words when Apple's recognizer starts over.
@MainActor
struct VoiceTurnCaptureTests {
    private func detector(_ ended: @escaping () -> Void) -> VoiceEndOfSpeechDetector {
        VoiceEndOfSpeechDetector(onEndOfSpeech: ended)
    }

    private func talk(_ detector: VoiceEndOfSpeechDetector, seconds: Double) {
        for _ in 0..<Int(seconds * 10) { detector.receiveLevel(0.3, duration: .milliseconds(100)) }
    }

    private func quiet(_ detector: VoiceEndOfSpeechDetector, seconds: Double) {
        for _ in 0..<Int(seconds * 10) { detector.receiveLevel(0.01, duration: .milliseconds(100)) }
    }

    /// A finished question goes about a second after the speaker stops.
    @Test func aShortQuestionEndsAfterAShortPause() {
        var ended = 0
        let detector = detector { ended += 1 }
        detector.receiveTranscript(.init(text: "What's on my calendar today?", isFinal: false))
        talk(detector, seconds: 2)
        quiet(detector, seconds: 0.7)
        #expect(ended == 0, "A breath isn't the end")
        quiet(detector, seconds: 0.4)
        #expect(ended == 1)
    }

    @Test func anUnfinishedShortTurnWaitsALittleLonger() {
        var ended = 0
        let detector = detector { ended += 1 }
        detector.receiveTranscript(.init(text: "Set a timer for ten minutes", isFinal: false))
        talk(detector, seconds: 2)
        quiet(detector, seconds: 1.1)
        #expect(ended == 0)
        quiet(detector, seconds: 0.2)
        #expect(ended == 1)
    }

    @Test func aLongMessageGetsLongerPauses() {
        var ended = 0
        let detector = detector { ended += 1 }
        // Words keep coming while someone talks.
        for second in 0..<30 {
            detector.receiveTranscript(.init(text: "So here's what I'm thinking about the trip, part \(second)", isFinal: false))
            talk(detector, seconds: 1)
        }
        #expect(detector.requiredSilence > .seconds(1.9))
        quiet(detector, seconds: 1.7)
        #expect(ended == 0, "Thirty seconds in, a pause under two seconds is still mid-thought")
        talk(detector, seconds: 1)
        quiet(detector, seconds: 1.7)
        #expect(ended == 0)
        quiet(detector, seconds: 0.3)
        #expect(ended == 1)
    }

    private func seconds(_ duration: Duration) -> Double {
        (duration / .milliseconds(1)).rounded() / 1_000
    }

    @Test func hermesSilenceDurationCapsThePause() {
        let detector = detector {}
        detector.silenceLimit = .seconds(2)
        detector.receiveTranscript(.init(text: "I need milk and", isFinal: false))
        #expect(seconds(detector.requiredSilence) == 2)
    }

    @Test func aSentenceLeftHangingWaitsLonger() {
        let detector = detector {}
        detector.receiveTranscript(.init(text: "I need milk and", isFinal: false))
        #expect(seconds(detector.requiredSilence) == 2.1)
        detector.receiveTranscript(.init(text: "I need milk and eggs.", isFinal: false))
        #expect(seconds(detector.requiredSilence) == 0.9, "A finished sentence goes sooner")
        detector.receiveTranscript(.init(text: "Book it for Friday and then", isFinal: false))
        #expect(seconds(detector.requiredSilence) == 2.1)
    }

    @Test func thePauseNeverGrowsPastItsLimit() {
        let detector = detector {}
        for second in 0..<120 {
            detector.receiveTranscript(.init(text: "point \(second) and the", isFinal: false))
            talk(detector, seconds: 1)
        }
        #expect(seconds(detector.requiredSilence) == 2.85, "Never past three seconds")
    }

    @Test func withoutCaptionsSustainedVoiceCountsAsSpeech() {
        var ended = 0
        let detector = detector { ended += 1 }
        quiet(detector, seconds: 5)
        #expect(ended == 0, "Room tone before speaking never ends a turn")
        talk(detector, seconds: 1)
        quiet(detector, seconds: 3)
        #expect(ended == 0, "Only live words count unless voice-only mode is on")

        detector.countsVoiceAsSpeech = true
        talk(detector, seconds: 0.3)
        quiet(detector, seconds: 3)
        #expect(ended == 0, "A cough isn't speech")
        talk(detector, seconds: 1)
        quiet(detector, seconds: 2)
        #expect(ended == 1)
    }

    @Test func trailingWordsIgnoreFinishedSentences() {
        #expect(VoiceEndOfSpeechDetector.trailingWord("go to the") == "the")
        #expect(VoiceEndOfSpeechDetector.trailingWord("I’m") == "i'm")
        #expect(VoiceEndOfSpeechDetector.trailingWord("Done.") == nil)
        #expect(VoiceEndOfSpeechDetector.trailingWord("Really?") == nil)
        #expect(VoiceEndOfSpeechDetector.trailingWord("   ") == nil)
    }

    // MARK: Keeping every word

    @Test func wordsBeforeAPauseAreKeptWhenTheRecognizerStartsOver() {
        // iOS 18: after a pause the next result drops the earlier words.
        var transcript = VoiceTranscriptAccumulator()
        transcript.receive("I need to book a flight", segmentEnded: false)
        transcript.receive("to Denver", segmentEnded: false)
        transcript.receive("to Denver on Friday", segmentEnded: false)
        #expect(transcript.text == "I need to book a flight to Denver on Friday")
    }

    @Test func aRecognizerThatKeepsEverythingIsNotDoubled() {
        var transcript = VoiceTranscriptAccumulator()
        transcript.receive("I need to boo", segmentEnded: true)
        transcript.receive("I need to book a flight", segmentEnded: false)
        #expect(transcript.text == "I need to book a flight")
        transcript.receive("I need to book a flight to Denver", segmentEnded: true)
        transcript.receive("I need to book a flight to Denver on Friday", segmentEnded: false)
        #expect(transcript.text == "I need to book a flight to Denver on Friday")
    }

    @Test func segmentMetadataAndRestartsKeepTheEarlierWords() {
        var transcript = VoiceTranscriptAccumulator()
        transcript.receive("First part of my thought.", segmentEnded: true)
        transcript.receive("second part", segmentEnded: false)
        #expect(transcript.text == "First part of my thought. second part")
        transcript.commitSegment()
        transcript.receive("and the rest", segmentEnded: false)
        #expect(transcript.text == "First part of my thought. second part and the rest")
        transcript.reset()
        #expect(transcript.text.isEmpty)
    }

    @Test func revisionsWithinASegmentReplaceRatherThanAppend() {
        var transcript = VoiceTranscriptAccumulator()
        transcript.receive("Wreck a nice beach", segmentEnded: false)
        transcript.receive("Recognize speech", segmentEnded: false)
        #expect(transcript.text == "Recognize speech")
        transcript.receive("Recognize speech with the app", segmentEnded: false)
        transcript.receive("Recognize speech with the application", segmentEnded: false)
        #expect(transcript.text == "Recognize speech with the application")
    }

    // MARK: Recording for Hermes

    @Test func aTurnIsRecordedAsSmallWAVAndTheFileIsRemoved() throws {
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let recorder = try VoiceTurnRecorder(inputFormat: input)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for index in 0..<48_000 { buffer.floatChannelData![0][index] = sin(Float(index) / 20) * 0.4 }
        #expect(recorder.append(buffer))
        #expect(abs(recorder.recordedSeconds - 1) < 0.05)
        let data = try #require(recorder.finish())
        #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        // One second of 16 kHz mono 16-bit audio, plus its (padded) header.
        #expect((32_000...40_000).contains(data.count))
        #expect(try DirectHermesVoiceRecording(bytes: data, mimeType: "audio/wav").mimeType == "audio/wav")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())
            .filter { $0.hasPrefix("bighelp-voice-") }
        #expect(leftovers.isEmpty)
    }

    @Test func nothingRecordedMeansNothingToSend() throws {
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let recorder = try VoiceTurnRecorder(inputFormat: input)
        #expect(recorder.finish() == nil)
    }

    // MARK: In the car

    /// Road noise can keep the microphone from ever going quiet. Once the words stop
    /// changing for a while, the turn ends anyway.
    @Test func aNoisyCarStillEndsTheTurnWhenTheWordsStop() {
        var ended = 0
        let detector = detector { ended += 1 }
        detector.receiveTranscript(.init(text: "Remind me to call the dentist", isFinal: false))
        talk(detector, seconds: 1)
        detector.receiveTranscript(.init(text: "Remind me to call the dentist tomorrow.", isFinal: false))
        talk(detector, seconds: 2)
        #expect(ended == 0, "Still within a pause")
        talk(detector, seconds: 3)
        #expect(ended == 1, "Noise all along, but the words stopped")
    }

    @Test func wordsStillComingKeepTheTurnOpenInNoise() {
        var ended = 0
        let detector = detector { ended += 1 }
        for index in 0..<8 {
            detector.receiveTranscript(.init(text: "Plan a trip " + String(repeating: "and more ", count: index), isFinal: false))
            talk(detector, seconds: 1)
        }
        #expect(ended == 0)
    }

    /// The car's microphone arrives with its own format part way into a turn; the recording
    /// for Hermes keeps every part instead of dropping what came after the switch.
    @Test func aRecordingKeepsSoundAfterTheFormatChanges() throws {
        let phone = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let car = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let recorder = try VoiceTurnRecorder(inputFormat: phone)
        defer { recorder.discard() }
        func second(_ format: AVAudioFormat) throws -> AVAudioPCMBuffer {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)))
            buffer.frameLength = buffer.frameCapacity
            for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = sin(Float(index) * 0.05) * 0.3 }
            return buffer
        }
        _ = recorder.append(try second(phone))
        let afterPhone = recorder.recordedSeconds
        _ = recorder.append(try second(car))
        #expect(afterPhone > 0.9)
        #expect(recorder.recordedSeconds > afterPhone + 0.9, "The car's sound is recorded too")
    }

    /// A voice chat stops music rather than playing under it: in the car, music mixed with
    /// the microphone goes through the car's phone-call channel and sounds like an old radio.
    @Test func aVoiceChatPausesOtherAudioAndLetsItResume() {
        let options = SystemVoiceAudioSession.conversationOptions
        #expect(!options.contains(.duckOthers) && !options.contains(.mixWithOthers)
                && !options.contains(.interruptSpokenAudioAndMixWithOthers))
        #expect(options.contains(.defaultToSpeaker), "Still loud on the phone's speaker")
        #expect(options.contains(.allowBluetooth), "Car and headset microphones work")
    }

    /// Replies and the hold music play at media volume, not phone-call volume, wherever the
    /// iPhone can cancel the speaker's echo in that mode; others keep a call mode's echo
    /// cancellation so the agent doesn't hear itself.
    @Test func aVoiceChatPlaysAtMediaVolumeWhereEchoCanBeCancelled() {
        #expect(SystemVoiceAudioSession.conversationMode(echoCancellationAvailable: true) == .default)
        #expect(SystemVoiceAudioSession.conversationMode(echoCancellationAvailable: false) == .videoChat)
        #expect(SystemVoiceAudioSession.conversationMode(echoCancellationAvailable: false) != .voiceChat,
                "Never the hold-it-to-your-ear tuning")
    }
}
