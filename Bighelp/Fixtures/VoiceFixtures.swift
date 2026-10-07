import Foundation

enum VoiceFixtureFailure: Error {
    case unavailable
}

@MainActor
struct VoiceFixtureClient: VoiceSessionClient {
    enum Outcome {
        case confirmEnd
        case fail
    }

    let outcome: Outcome
    let confirmationDelay: Duration

    init(
        outcome: Outcome = .confirmEnd,
        confirmationDelay: Duration = .milliseconds(180)
    ) {
        self.outcome = outcome
        self.confirmationDelay = confirmationDelay
    }

    func endSession(conversationID: String) async throws {
        try await Task.sleep(for: confirmationDelay)

        switch outcome {
        case .confirmEnd:
            return
        case .fail:
            throw VoiceFixtureFailure.unavailable
        }
    }
}

#if DEBUG
/// Demo replies "play" for a moment, without sound.
@MainActor
final class SilentVoiceSpeechOutput: VoiceSpeechOutput {
    func speak(_ text: String, rate: Float) async throws {
        try await Task.sleep(for: .seconds(2))
    }

    func stop() {}
}
#endif

enum VoiceFixture {
    static let transcript = [
        VoiceTranscriptRow(
            id: "voice-transcript-you-0941",
            speaker: "You",
            time: "9:41 AM",
            text: "Can you summarize today’s priorities?"
        ),
        VoiceTranscriptRow(
            id: "voice-transcript-loopdy-0942",
            speaker: "bighelp",
            time: "9:42 AM",
            text: "Your top priorities are the vendor approval, budget review, and Seattle itinerary."
        )
    ]
}
