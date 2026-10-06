import Foundation
import Testing
@testable import Bighelp

/// Voice opened right after launch, before the computer's connection is ready: the first answer and
/// End must still work once it is, without reopening the app.
@MainActor
struct DeferredVoiceSessionClientTests {
    /// The computer's own voice client, once connected: answers at once, and records what it was asked.
    @MainActor final class ConnectedClient: VoiceSessionClient {
        var requests: [String] = []
        var spoken: [String] = []
        var stops = 0
        var ends = 0

        func respond(to transcript: String, conversationID: String,
                     onDraft: @escaping (String) -> Void) async throws -> VoiceAgentReply {
            requests.append(transcript)
            return VoiceAgentReply(speaker: "Alfie", text: "Hi there.", timelineItems: [])
        }
        func steer(_ transcript: String, conversationID: String) async throws {}
        func speak(_ text: String) async throws { spoken.append(text) }
        func stopSpeaking() { stops += 1 }
        func endSession(conversationID: String) async throws { ends += 1 }
        func transcribe(_ audio: Data) async throws -> String { "" }
    }

    /// The connection: not ready until `connect()`, and a new one after `reconnect()`.
    @MainActor final class Connection {
        var owner: Int?
        var made: [ConnectedClient] = []
        func connect() { owner = 1 }
        func reconnect() { owner = (owner ?? 0) + 1 }
        func client() -> DeferredVoiceSessionClient {
            DeferredVoiceSessionClient(wait: .milliseconds(10), attempts: 100,
                                       currentKey: { [unowned self] in owner.map(AnyHashable.init) },
                                       make: { [unowned self] in
                                           guard owner != nil else { return nil }
                                           let client = ConnectedClient()
                                           made.append(client)
                                           return client
                                       })
        }
    }

    @Test func voiceOpenedBeforeTheConnectionAnswersOnceItIsReadyAndEnds() async {
        let connection = Connection()
        let model = VoiceModel(conversationID: "chat-1", agentName: "Alfie", client: connection.client())
        // Voice is open; the connection comes a moment later, while the first words are on their way.
        #expect(model.submitTranscript("Hello"))
        try? await Task.sleep(for: .milliseconds(40))
        connection.connect()
        await model.waitUntilTurnSettles()
        #expect(model.turnErrorMessage == nil, "The first answer arrives")
        #expect(connection.made.first?.requests == ["Hello"])
        #expect(await model.end(), "End closes voice")
        #expect(model.endErrorMessage == nil)
    }

    @Test func endingBeforeAnythingReachedTheComputerStillCloses() async {
        let connection = Connection()
        let model = VoiceModel(conversationID: "chat-1", client: connection.client())
        #expect(await model.end(), "Nothing to end on the computer: voice just closes")
        #expect(connection.made.isEmpty)
    }

    @Test func aNewConnectionGetsANewClientAndStopsTheOldOnesSpeech() async throws {
        let connection = Connection()
        connection.connect()
        let client = connection.client()
        _ = try await client.respond(to: "One", conversationID: "chat-1", onDraft: { _ in })
        connection.reconnect()
        _ = try await client.respond(to: "Two", conversationID: "chat-1", onDraft: { _ in })
        #expect(connection.made.map(\.requests) == [["One"], ["Two"]])
        try #require(connection.made.count == 2)
        #expect(connection.made[0].stops == 1, "The old connection's speech stops")
        client.stopSpeaking()
        #expect(connection.made[1].stops == 1)
    }

    @Test func noConnectionAtAllFailsTheTurnButNeverTrapsVoice() async {
        let connection = Connection()
        let client = DeferredVoiceSessionClient(wait: .milliseconds(5), attempts: 3,
                                                currentKey: { connection.owner.map(AnyHashable.init) },
                                                make: { nil })
        let model = VoiceModel(conversationID: "chat-1", client: client)
        #expect(model.submitTranscript("Hello"))
        await model.waitUntilTurnSettles()
        #expect(model.turnErrorMessage != nil, "It says the answer didn't come")
        #expect(await model.end(), "End still closes voice")
    }
}
