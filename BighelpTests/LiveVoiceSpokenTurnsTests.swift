import Foundation
import Testing
@testable import Bighelp

/// A call's finished lines go into its chat in the order they were said, once the chat can take them.
@MainActor
struct LiveVoiceSpokenTurnsTests {
    /// Stands in for the plugin's `voice/transcript`: answers each send from `outcomes`, then saves.
    @MainActor final class Chat {
        var outcomes: [LiveVoiceSpokenTurns.Outcome] = []
        var sends: [(voiceID: String, lines: [BighelpJSONValue])] = []
        var saved: [String] = []

        func send(_ voiceID: String, _ lines: [BighelpJSONValue]) async -> LiveVoiceSpokenTurns.Outcome {
            sends.append((voiceID, lines))
            let outcome = outcomes.isEmpty ? .saved : outcomes.removeFirst()
            if outcome == .saved { saved += lines.compactMap { $0.object?["text"]?.string } }
            return outcome
        }
    }

    private func journal(_ chat: Chat) -> LiveVoiceSpokenTurns {
        let journal = LiveVoiceSpokenTurns(retryWaits: [.milliseconds(5)], giveUpAfter: .milliseconds(200))
        journal.send = { [chat] voiceID, lines in await chat.send(voiceID, lines) }
        return journal
    }

    private func settle(_ journal: LiveVoiceSpokenTurns) async {
        for _ in 0..<400 where !journal.pending.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func linesGoInTheOrderTheyWereSaidWithTheirRoles() async {
        let chat = Chat()
        let journal = journal(chat)
        var refreshes = 0
        journal.onSaved = { refreshes += 1 }
        journal.add(voiceID: "voice-one", role: "user", text: " My bike is blue. ")
        journal.add(voiceID: "voice-one", role: "assistant", text: "Noted, a blue", interrupted: true)
        await journal.flush()
        await settle(journal)
        #expect(chat.saved == ["My bike is blue.", "Noted, a blue"])
        let lines = chat.sends.flatMap(\.lines).compactMap(\.object)
        #expect(lines.map { $0["role"]?.string } == ["user", "assistant"])
        #expect(lines.map { $0["interrupted"]?.boolean } == [false, true])
        #expect(Set(lines.compactMap { $0["id"]?.string }).count == 2, "Each line has its own ID")
        #expect(refreshes >= 1, "The chat reads what was saved")
    }

    @Test func aBusyChatGetsTheSameLinesAgainUntilItTakesThem() async {
        let chat = Chat()
        chat.outcomes = [.wait, .wait]
        let journal = journal(chat)
        journal.add(voiceID: "voice-one", role: "user", text: "Remind me at six.")
        await settle(journal)
        #expect(chat.saved == ["Remind me at six."])
        #expect(chat.sends.count == 3)
        let ids = chat.sends.map { $0.lines.compactMap { $0.object?["id"]?.string } }
        #expect(Set(ids.map { $0.joined() }).count == 1, "A retry sends the same line ID, so the plugin saves it once")
    }

    @Test func eachCallsLinesGoUnderTheirOwnCall() async {
        let chat = Chat()
        chat.outcomes = [.wait]
        let journal = journal(chat)
        journal.add(voiceID: "voice-one", role: "user", text: "First call.")
        journal.add(voiceID: "voice-two", role: "user", text: "Second call.")
        await settle(journal)
        #expect(chat.saved == ["First call.", "Second call."])
        #expect(chat.sends.last?.voiceID == "voice-two")
    }

    @Test func aChatThatRefusesNeverHoldsUpLaterLines() async {
        let chat = Chat()
        chat.outcomes = [.refused]
        let journal = journal(chat)
        journal.add(voiceID: "voice-one", role: "user", text: "Lost.")
        await journal.flush()
        journal.add(voiceID: "voice-one", role: "user", text: "Kept.")
        await settle(journal)
        #expect(chat.saved == ["Kept."])
    }

    @Test func linesAChatNeverTakesAreLetGoInTheEnd() async {
        let chat = Chat()
        chat.outcomes = Array(repeating: .wait, count: 1_000)
        let journal = journal(chat)
        journal.add(voiceID: "voice-one", role: "user", text: "Waiting.")
        await settle(journal)
        #expect(journal.pending.isEmpty)
        #expect(chat.saved.isEmpty)
    }

    @Test func longLinesGoInSendsTheComputerTakes() async {
        let chat = Chat()
        let journal = journal(chat)
        // Four bytes a character, 16,000 a line: nine lines are over one send's size.
        let long = String(repeating: "🌱", count: LiveVoiceSpokenTurns.maximumTextLength + 50)
        for _ in 0..<9 { journal.add(voiceID: "voice-one", role: "user", text: long) }
        await settle(journal)
        #expect(chat.saved.count == 9)
        #expect(chat.saved.allSatisfy { $0.unicodeScalars.count == LiveVoiceSpokenTurns.maximumTextLength })
        #expect(chat.sends.count >= 2, "No send is over the computer's limit")
        #expect(chat.sends.allSatisfy { send in
            send.lines.count == 1 || send.lines.compactMap { $0.object?["text"]?.string?.utf8.count }.reduce(0, +)
                <= LiveVoiceSpokenTurns.maximumBatchBytes
        })
    }

    @Test func emptyLinesAndOtherRolesAreLeftOut() {
        let journal = LiveVoiceSpokenTurns()
        journal.add(voiceID: "voice-one", role: "user", text: "   ")
        journal.add(voiceID: "voice-one", role: "system", text: "Be brief.")
        #expect(journal.pending.isEmpty)
    }

    @Test func eachChatOnEachComputerHasItsOwnJournal() {
        let one = LiveVoiceSpokenTurns.shared(hostID: "computer-a", agentID: "nova", sessionID: "chat-1")
        #expect(LiveVoiceSpokenTurns.shared(hostID: "computer-a", agentID: "nova", sessionID: "chat-1") === one)
        for (host, agent, session) in [("computer-b", "nova", "chat-1"), ("computer-a", "miso", "chat-1"),
                                       ("computer-a", "nova", "chat-2")] {
            #expect(LiveVoiceSpokenTurns.shared(hostID: host, agentID: agent, sessionID: session) !== one)
        }
    }
}
