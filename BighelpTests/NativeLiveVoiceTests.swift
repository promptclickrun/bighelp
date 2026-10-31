import Foundation
import Testing
@testable import Bighelp

@MainActor
struct NativeLiveVoiceTests {
    @Test func distinctDelegationsRunSideBySideAndKeepTheirResultIDs() async throws {
        let fixture = VoiceFixture()
        let voice = fixture.makeSession()
        _ = try await voice.perform("voice.live.offer", fields: ["voiceId": .string("voice-one")])
        defer { fixture.finishAll() }

        voice.receiveEvent(["kind": .string("delegation"), "id": .string("delegation-a"),
            "text": .string("First request")], voiceID: "voice-one")
        voice.receiveEvent(["kind": .string("delegation"), "id": .string("delegation-b"),
            "text": .string("Second request")], voiceID: "voice-one")
        // The second starts while the first still works.
        for _ in 0..<100 where fixture.replies.count < 2 { await Task.yield() }
        #expect(fixture.submitted == ["First request", "Second request"])

        // The quicker one answers first, under its own ID.
        try #require(fixture.take("Second request")).resume(returning: "Second result")
        for _ in 0..<100 where fixture.results.isEmpty { await Task.yield() }
        #expect(fixture.results == ["delegation-b"])

        try #require(fixture.take("First request")).resume(returning: "First result")
        for _ in 0..<100 where fixture.results.count < 2 { await Task.yield() }
        #expect(fixture.results == ["delegation-b", "delegation-a"])
        _ = try await voice.perform("voice.live.close", fields: ["voiceId": .string("voice-one")])
    }

    @Test func repeatedProviderRequestsShareOnePendingNativeTurn() async throws {
        let fixture = VoiceFixture()
        let voice = fixture.makeSession()
        _ = try await voice.perform("voice.live.offer", fields: ["voiceId": .string("voice-one")])
        defer { fixture.finishAll() }
        voice.receiveEvent(["kind": .string("delegation"), "id": .string("one"), "text": .string("Check tomorrow")], voiceID: "voice-one")
        voice.receiveEvent(["kind": .string("delegation"), "id": .string("two"), "text": .string("Check tomorrow")], voiceID: "voice-one")
        voice.receiveEvent(["kind": .string("delegation"), "id": .string("one"), "text": .string("Check tomorrow")], voiceID: "voice-one")
        for _ in 0..<100 where fixture.replies.isEmpty { await Task.yield() }
        #expect(fixture.submitted == ["Check tomorrow"])
        try #require(fixture.take("Check tomorrow")).resume(returning: "Three events")
        for _ in 0..<100 where fixture.results.count < 2 { await Task.yield() }
        #expect(Set(fixture.results) == ["one", "two"])
        #expect(fixture.submitted.count == 1)
        _ = try await voice.perform("voice.live.close", fields: ["voiceId": .string("voice-one")])
    }

    @Test func closingMediaDoesNotCancelSubmittedNativeWorkOrSendItsResultToAnotherCall() async throws {
        let fixture = VoiceFixture()
        let voice = fixture.makeSession()
        _ = try await voice.perform("voice.live.offer", fields: ["voiceId": .string("voice-one")])
        voice.receiveEvent(["kind": .string("delegation"), "id": .string("one"), "text": .string("Do work")], voiceID: "voice-one")
        for _ in 0..<100 where fixture.replies.isEmpty { await Task.yield() }
        let pending = try #require(fixture.take("Do work"))
        _ = try await voice.perform("voice.live.close", fields: ["voiceId": .string("voice-one")])
        _ = try await voice.perform("voice.live.offer", fields: ["voiceId": .string("voice-two")])
        pending.resume(returning: "Work completed in Hermes")
        for _ in 0..<100 { await Task.yield() }
        #expect(fixture.submitted == ["Do work"])
        #expect(!fixture.submitWasCancelled)
        #expect(fixture.results.isEmpty)
        _ = try await voice.perform("voice.live.close", fields: ["voiceId": .string("voice-two")])
    }

    @Test func ownerRetirementUsesPreparedCloseAfterOwnerFencing() async throws {
        let ownerState = OwnerState()
        var preparedCount = 0
        var preparedCloseCount = 0
        var ordinaryCloseCount = 0
        let voice = NativeLiveVoiceSession(
            owner: .init(hostID: "native", authorizationID: "auth", agentID: "default", sessionID: "stored"),
            operation: { operation, payload in
                switch operation {
                case .nativeVoiceOffer:
                    return ["voiceId": payload["voiceId"]!, "sdp": .string("fixture")]
                case .nativeVoiceClose:
                    ordinaryCloseCount += 1
                    return ["closed": .boolean(true)]
                default:
                    throw LiveVoiceControlError.unavailable
                }
            },
            isCurrent: { ownerState.isCurrent },
            closeCleanupFactory: { voiceID in
                preparedCount += 1
                guard voiceID == "voice-one" else { return nil }
                return { preparedCloseCount += 1 }
            },
            submit: { _ in "" }
        )
        let model = voice.makeModel(agentName: "Hermes")
        _ = try await voice.perform("voice.live.offer", fields: ["voiceId": .string("voice-one")])
        #expect(preparedCount == 1)

        ownerState.isCurrent = false
        model.invalidateOwner()
        for _ in 0..<100 where preparedCloseCount == 0 { await Task.yield() }

        #expect(preparedCount == 1)
        #expect(preparedCloseCount == 1)
        #expect(ordinaryCloseCount == 0)
    }

    @Test func ownerRetirementSuppressesOrdinaryCloseWhenNoPreparedHandleExists() async throws {
        let ownerState = OwnerState()
        var ordinaryCloseCount = 0
        let voice = NativeLiveVoiceSession(
            owner: .init(hostID: "native", authorizationID: "auth", agentID: "default", sessionID: "stored"),
            operation: { operation, payload in
                switch operation {
                case .nativeVoiceOffer:
                    return ["voiceId": payload["voiceId"]!, "sdp": .string("fixture")]
                case .nativeVoiceClose:
                    ordinaryCloseCount += 1
                    return ["closed": .boolean(true)]
                default:
                    throw LiveVoiceControlError.unavailable
                }
            },
            isCurrent: { ownerState.isCurrent },
            submit: { _ in "" }
        )
        let model = voice.makeModel(agentName: "Hermes")
        _ = try await voice.perform("voice.live.offer", fields: ["voiceId": .string("voice-one")])

        ownerState.isCurrent = false
        model.invalidateOwner()
        for _ in 0..<100 { await Task.yield() }

        #expect(ordinaryCloseCount == 0)
    }

    @MainActor private final class OwnerState {
        var isCurrent = true
    }

    @MainActor private final class VoiceFixture {
        var submitted: [String] = []
        var results: [String] = []
        var voiceID = ""
        /// Each pending request's answer, by its text.
        var replies: [String: CheckedContinuation<String, Never>] = [:]
        var submitWasCancelled = false
        /// The pending request's answer, taken out of `replies`.
        func take(_ text: String) -> CheckedContinuation<String, Never>? {
            replies.removeValue(forKey: text)
        }
        func finishAll() {
            for reply in replies.values { reply.resume(returning: "Fixture ended") }
            replies = [:]
        }
        func makeSession() -> NativeLiveVoiceSession {
            NativeLiveVoiceSession(owner: .init(hostID: "native", authorizationID: "auth", agentID: "default", sessionID: "stored"),
                operation: { operation, payload in
                    switch operation {
                    case .nativeVoiceStatus: return ["available": .boolean(true)]
                    case .nativeVoiceOffer:
                        self.voiceID = payload["voiceId"]!.string!
                        return ["voiceId": payload["voiceId"]!, "sdp": .string(NativeVoicePeer.sdp)]
                    case .nativeVoicePoll: return ["voiceId": payload["voiceId"]!, "events": .array([]), "next": payload["after"]!, "closed": .boolean(false)]
                    case .nativeVoiceClose: return ["closed": .boolean(true)]
                    case .nativeVoiceResult:
                        self.results.append(payload["delegationId"]!.string!)
                        return ["appended": .boolean(true)]
                    default: throw LiveVoiceControlError.unavailable
                    }
                }, isCurrent: { true }, submit: { text in
                    self.submitted.append(text)
                    let result = await withCheckedContinuation { self.replies[text] = $0 }
                    self.submitWasCancelled = Task.isCancelled
                    return result
                })
        }
    }

    @Test func nativeDelegationStatusFollowsVerifiedResultReceipt() async throws {
        let fixture = VoiceFixture()
        let voice = fixture.makeSession()
        let peer = NativeVoicePeer()
        let model = voice.makeModel(agentName: "Hermes", makePeer: { peer })
        defer { model.end() }

        model.start()
        for _ in 0..<100 where fixture.voiceID.isEmpty { await Task.yield() }
        #expect(!fixture.voiceID.isEmpty)

        voice.receiveEvent(["kind": .string("delegation"), "id": .string("delegation-status"),
            "text": .string("Check tomorrow")], voiceID: fixture.voiceID)
        #expect(model.workStatus == .working)
        for _ in 0..<100 where fixture.replies.isEmpty { await Task.yield() }
        try #require(fixture.take("Check tomorrow")).resume(returning: "Tomorrow is clear")
        for _ in 0..<100 where fixture.results.isEmpty { await Task.yield() }
        #expect(fixture.results == ["delegation-status"])
        #expect(model.workStatus == .resultSent)
    }

    @MainActor private final class NativeVoicePeer: LiveVoiceAudioPeer {
        static let sdp = "v=0\r\na=fingerprint:sha-256 00:11\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"
        var onConnectionState: (@MainActor (BighelpRealtimeAudioPeer.ConnectionState) -> Void)?
        var onAudioRoute: (@MainActor (String) -> Void)?
        var onInterruption: (@MainActor (Bool) -> Void)?
        func makeOffer() async throws -> String { Self.sdp }
        func applyAnswer(_ sdp: String) async throws {}
        func setMuted(_ muted: Bool) {}
        func setPlaybackMuted(_ muted: Bool) {}
        func setSpeakerEnabled(_ enabled: Bool) throws {}
        func setDefaultSpeakerOutput() throws {}
        func resumeAudio() throws {}
        func statistics() async throws -> BighelpRealtimeAudioPeer.MediaStatistics { .init(audioDeviceRunning: true) }
        func close() {}
    }

    @Test func voiceDelegationUsesChatClientWithoutChangingComposerOrRetrying() async throws {
        let client = Reply()
        let chat = ChatModel(conversationID: "native", client: client, initialItems: [])
        chat.draft = "Keep my draft"
        let response = try await chat.sendNativeVoiceMessage("Check my calendar")
        #expect(client.messages == ["Check my calendar"])
        #expect(chat.draft == "Keep my draft")
        #expect(response.items.count == 1)
        #expect(!chat.isSending)
        #expect(chat.items.contains { $0.content == .message("Check my calendar") })
        // A free chat takes voice work as its own turn and hands back the answer.
        #expect(try await chat.runNativeVoiceRequest("Check tomorrow") == "Tomorrow is clear.")
        #expect(client.messages == ["Check my calendar", "Check tomorrow"])
        client.fail = true
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            _ = try await chat.sendNativeVoiceMessage("Uncertain work")
        }
        #expect(client.messages == ["Check my calendar", "Check tomorrow", "Uncertain work"])
        #expect(!chat.isSending)
    }

    @MainActor private final class LocalPeer: LiveVoiceAudioPeer, LiveVoiceLocalSession {
        var onConnectionState: (@MainActor (BighelpRealtimeAudioPeer.ConnectionState) -> Void)?
        var onAudioRoute: (@MainActor (String) -> Void)?
        var onInterruption: (@MainActor (Bool) -> Void)?
        var onEvent: (@MainActor ([String: BighelpJSONValue]) -> Void)?
        var answers: [LiveVoiceAnswer] = []
        var texts: [String] = []
        var functionAnswers: [String: [String: BighelpJSONValue]] = [:]
        func makeOffer() async throws -> String { "" }
        func applyAnswer(_ sdp: String) async throws { Issue.record("Gemini takes no SDP") }
        func apply(_ answer: LiveVoiceAnswer) async throws {
            answers.append(answer)
            onConnectionState?(.connected)
        }
        func sendText(_ text: String) { texts.append(text) }
        func answerFunction(id: String, name: String, response: [String: BighelpJSONValue]) { functionAnswers[id] = response }
        func setMuted(_ muted: Bool) {}
        func setPlaybackMuted(_ muted: Bool) {}
        func setSpeakerEnabled(_ enabled: Bool) throws {}
        func setDefaultSpeakerOutput() throws {}
        func resumeAudio() throws {}
        func statistics() async throws -> BighelpRealtimeAudioPeer.MediaStatistics { .init(audioDeviceRunning: true) }
        func close() {}
    }

    @MainActor private final class GeminiLog {
        var operations: [WorkspaceOperation] = []
        var offer: [String: BighelpJSONValue] = [:]
        var submitted: [String] = []
    }

    @Test func geminiKeepsEventsAndResultsOnThePhonesOwnConnection() async throws {
        let log = GeminiLog()
        let voice = NativeLiveVoiceSession(
            owner: .init(hostID: "native", authorizationID: "auth", agentID: "juniper", sessionID: "stored"),
            operation: { operation, payload in
                log.operations.append(operation)
                switch operation {
                case .nativeVoiceGeminiStatus: return ["available": .boolean(true), "enabled": .boolean(true)]
                case .nativeVoiceGeminiOffer:
                    log.offer = payload
                    return ["voiceId": payload["voiceId"]!, "transport": .string("websocket"),
                            "url": .string("wss://generativelanguage.googleapis.com/ws/live"),
                            "token": .string("auth_tokens/one"), "model": .string("models/gemini-3.8-live")]
                case .nativeVoiceClose: return ["closed": .boolean(true)]
                default: throw LiveVoiceControlError.unavailable
                }
            }, isCurrent: { true }, submit: { text in
                log.submitted.append(text)
                return "Moved 42 files into 5 folders."
            })
        let peer = LocalPeer()
        let model = voice.makeModel(agentName: "Juniper", makeLocalPeer: { peer })
        defer { model.end() }
        model.configure(provider: .gemini, voice: "Kore")
        model.start()
        for _ in 0..<500 where peer.answers.isEmpty { await Task.yield() }

        #expect(peer.answers == [.gemini(url: URL(string: "wss://generativelanguage.googleapis.com/ws/live")!,
                                         token: "auth_tokens/one", model: "models/gemini-3.8-live")])
        #expect(log.operations == [.nativeVoiceGeminiStatus, .nativeVoiceGeminiOffer])
        #expect(log.offer["provider"] == .string("gemini"))
        #expect(log.offer["voice"] == .string("Kore"))
        #expect(log.offer["agentId"] == .string("juniper"))

        peer.onEvent?(["kind": .string("started")])
        peer.onEvent?(["kind": .string("delegation"), "id": .string("call-1"), "text": .string("Tidy my Downloads")])
        for _ in 0..<500 where peer.texts.isEmpty { await Task.yield() }
        #expect(log.submitted == ["Tidy my Downloads"])
        #expect(peer.texts == [NativeLiveVoiceSession.update(request: "Tidy my Downloads",
                                                             result: "Moved 42 files into 5 folders.")])
        #expect(peer.texts.first?.hasPrefix("UPDATE: ") == true)
        #expect(model.workStatus == .resultSent)

        peer.onEvent?(["kind": .string("tool"), "name": .string("check_work"), "id": .string("call-2")])
        #expect(peer.functionAnswers["call-2"] == ["work": .array([.object([
            "request": .string("Tidy my Downloads"), "state": .string("finished")])])])
        // The host has no feed for this call: nothing polled, nothing appended there.
        #expect(!log.operations.contains(.nativeVoicePoll))
        #expect(!log.operations.contains(.nativeVoiceResult))
    }

    @Test func geminiNeverCallsUnconfirmedWorkDone() async throws {
        let voice = NativeLiveVoiceSession(
            owner: .init(hostID: "native", authorizationID: "auth", agentID: "juniper", sessionID: "stored"),
            operation: { operation, payload in
                switch operation {
                case .nativeVoiceGeminiStatus: return ["available": .boolean(true), "enabled": .boolean(true)]
                case .nativeVoiceGeminiOffer:
                    return ["voiceId": payload["voiceId"]!, "transport": .string("websocket"),
                            "url": .string("wss://generativelanguage.googleapis.com/ws/live"),
                            "token": .string("auth_tokens/one"), "model": .string("models/gemini-3.8-live")]
                case .nativeVoiceClose: return ["closed": .boolean(true)]
                default: throw LiveVoiceControlError.unavailable
                }
            }, isCurrent: { true }, submit: { _ in throw WorkspaceClientError.outcomeUnknown })
        let peer = LocalPeer()
        let model = voice.makeModel(agentName: "Juniper", makeLocalPeer: { peer })
        defer { model.end() }
        model.configure(provider: .gemini, voice: "Kore")
        model.start()
        for _ in 0..<500 where peer.answers.isEmpty { await Task.yield() }

        peer.onEvent?(["kind": .string("delegation"), "id": .string("call-1"), "text": .string("Pay the invoice")])
        for _ in 0..<500 where peer.texts.isEmpty { await Task.yield() }
        let update = try #require(peer.texts.first)
        #expect(update.contains("is not confirmed, so do not say it is done"))
        #expect(!update.contains("is done. What came back"))

        peer.onEvent?(["kind": .string("tool"), "name": .string("check_work"), "id": .string("call-2")])
        #expect(peer.functionAnswers["call-2"] == ["work": .array([])], "Unconfirmed work is never listed as finished")

        // Gemini ends the call; the next call can start.
        peer.onEvent?(["kind": .string("closed")])
        #expect(model.phase == .ended)
        _ = try await voice.perform("voice.live.offer", fields: ["voiceId": .string("voice-next"), "provider": .string("gemini")])
    }

    @Test func nativeVoiceOperationsHaveNativePluginRoutes() {
        for operation in [WorkspaceOperation.nativeVoiceStatus, .nativeVoiceOffer, .nativeVoicePoll,
                          .nativeVoiceResult, .nativeVoiceClose, .nativeVoiceGeminiStatus, .nativeVoiceGeminiOffer] {
            #expect(DirectHermesNativePluginClient.supports(operation))
        }
    }

    @MainActor private final class Reply: ConversationClient {
        var messages: [String] = []
        var fail = false
        func send(message: String, conversationID: String) async throws -> ConversationResponse {
            messages.append(message)
            if fail { throw WorkspaceClientError.outcomeUnknown }
            return ConversationResponse(items: [TimelineItem(id: "answer-\(messages.count)", role: .assistant,
                sender: .agent(id: "default", snapshot: .init(name: "Hermes")),
                content: .message("Tomorrow is clear."), metadata: .init(source: "Hermes", delivery: "Received"))])
        }
        func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
            throw LiveVoiceControlError.unavailable
        }
    }
}
