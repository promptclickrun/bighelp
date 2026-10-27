import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ChatReplyReaderTests {
    @Test func readsTheReplyAsPlainTextOnceItsTurnEnds() async {
        let reader = ChatReplyReader()
        let voice = ReplySpeechSpy()
        reader.update(reply: reply("old", "Earlier answer"), isTurnActive: false, isOn: true, rate: 1) { voice }
        reader.update(reply: nil, isTurnActive: true, isOn: true, rate: 1) { voice }
        reader.update(reply: reply("r1", "**Done.** It's"), isTurnActive: true, isOn: true, rate: 1) { voice }
        await settle()
        #expect(voice.spoken.isEmpty, "A reply was read while it was still being written")

        reader.update(reply: reply("r1", "**Done.** It's saved."), isTurnActive: false, isOn: true, rate: 1.15) { voice }
        await settle()
        #expect(voice.spoken == ["Done. It's saved."])
        #expect(voice.rates == [1.15])
    }

    @Test func opensQuietOnWhatTheChatAlreadyHolds() async {
        let reader = ChatReplyReader()
        let voice = ReplySpeechSpy()
        reader.update(reply: reply("old", "Earlier answer"), isTurnActive: false, isOn: true, rate: 1) { voice }
        // The host's saved copy comes in after the chat opens.
        reader.update(reply: reply("saved-old", "Earlier answer"), isTurnActive: false, isOn: true, rate: 1) { voice }
        await settle()
        #expect(voice.spoken.isEmpty)
    }

    /// Opened while the agent works: its answer is read when the turn ends.
    @Test func readsTheAnswerOfATurnRunningWhenTheChatOpened() async {
        let reader = ChatReplyReader()
        let voice = ReplySpeechSpy()
        reader.update(reply: nil, isTurnActive: true, isOn: true, rate: 1) { voice }
        reader.update(reply: reply("r1", "Here it is."), isTurnActive: false, isOn: true, rate: 1) { voice }
        await settle()
        #expect(voice.spoken == ["Here it is."])
    }

    @Test func aSavedCopyOfTheSameReplyIsNotReadAgain() async {
        let reader = ChatReplyReader()
        let voice = ReplySpeechSpy()
        reader.update(reply: nil, isTurnActive: true, isOn: true, rate: 1) { voice }
        reader.update(reply: reply("live", "All set."), isTurnActive: false, isOn: true, rate: 1) { voice }
        await settle()
        // Reconnecting reports the turn once more, then the host's copy under its own ID.
        reader.update(reply: reply("live", "All set."), isTurnActive: true, isOn: true, rate: 1) { voice }
        reader.update(reply: reply("host", "All set."), isTurnActive: false, isOn: true, rate: 1) { voice }
        await settle()
        #expect(voice.spoken == ["All set."])
    }

    /// Short answers repeat: the same words in the next turn are a new reply.
    @Test func theSameWordsInTheNextTurnAreReadAgain() async {
        let reader = ChatReplyReader()
        let voice = ReplySpeechSpy()
        reader.update(reply: nil, isTurnActive: true, isOn: true, rate: 1) { voice }
        reader.update(reply: reply("r1", "Done."), isTurnActive: false, isOn: true, rate: 1) { voice }
        await settle()
        reader.update(reply: nil, isTurnActive: true, isOn: true, rate: 1) { voice }
        reader.update(reply: reply("r2", "Done."), isTurnActive: false, isOn: true, rate: 1) { voice }
        await settle()
        #expect(voice.spoken == ["Done.", "Done."])
    }

    @Test func aNewMessageStopsTheReplyBeingRead() async {
        let reader = ChatReplyReader()
        let voice = ReplySpeechSpy()
        voice.holdsUntilStopped = true
        reader.update(reply: nil, isTurnActive: true, isOn: true, rate: 1) { voice }
        reader.update(reply: reply("r1", "A long answer."), isTurnActive: false, isOn: true, rate: 1) { voice }
        await settle()
        reader.update(reply: nil, isTurnActive: true, isOn: true, rate: 1) { voice }
        #expect(voice.stops == 1)
    }

    @Test func leavingTheChatStopsItAndComingBackStaysQuiet() async {
        let reader = ChatReplyReader()
        let voice = ReplySpeechSpy()
        voice.holdsUntilStopped = true
        reader.update(reply: nil, isTurnActive: true, isOn: true, rate: 1) { voice }
        reader.update(reply: reply("r1", "First."), isTurnActive: false, isOn: true, rate: 1) { voice }
        await settle()
        reader.reset()
        #expect(voice.stops == 1)
        reader.update(reply: reply("r1", "First."), isTurnActive: false, isOn: true, rate: 1) { voice }
        await settle()
        #expect(voice.spoken == ["First."])
    }

    @Test func whileOffRepliesCountAsHeard() async {
        let reader = ChatReplyReader()
        let voice = ReplySpeechSpy()
        reader.update(reply: nil, isTurnActive: true, isOn: false, rate: 1) { voice }
        reader.update(reply: reply("r1", "Quiet answer."), isTurnActive: false, isOn: false, rate: 1) { voice }
        // Turned on afterwards: the earlier reply stays unread.
        reader.update(reply: reply("r1", "Quiet answer."), isTurnActive: false, isOn: true, rate: 1) { voice }
        await settle()
        #expect(voice.spoken.isEmpty)
    }

    @Test func theLatestReplyIsTheAgentsAnswerAfterThePersonsLastMessage() {
        let answered = [message("h1", .human, "Hi"), message("a1", .assistant, "Hello!"),
                        message("a2", .assistant, "  How can I help?  ")]
        #expect(ChatReplyReader.latestReply(in: answered) == reply("a2", "How can I help?"))

        let waiting = answered + [message("h2", .human, "Plan my week")]
        #expect(ChatReplyReader.latestReply(in: waiting) == nil)
    }

    private func reply(_ id: String, _ text: String) -> ChatReplyReader.Reply {
        ChatReplyReader.Reply(id: id, text: text)
    }

    private func message(_ id: String, _ role: TimelineRole, _ text: String) -> TimelineItem {
        TimelineItem(id: id, role: role,
                     sender: role == .human ? .user(snapshot: .init(name: "Sam"))
                         : .agent(id: "finance", snapshot: .init(name: "Finley")),
                     content: .message(text), metadata: .init(delivery: "Delivered"))
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
final class ReplySpeechSpy: VoiceSpeechOutput {
    /// Keeps speaking until stopped, like a long reply.
    var holdsUntilStopped = false
    private(set) var spoken: [String] = []
    private(set) var rates: [Float] = []
    private(set) var stops = 0
    private var release: CheckedContinuation<Void, Never>?

    func speak(_ text: String, rate: Float) async throws {
        spoken.append(text)
        rates.append(rate)
        if holdsUntilStopped { await withCheckedContinuation { release = $0 } }
    }

    func stop() {
        stops += 1
        release?.resume()
        release = nil
    }
}
