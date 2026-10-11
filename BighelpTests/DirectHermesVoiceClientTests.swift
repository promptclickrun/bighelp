import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesVoiceClientTests {
    @Test func directSettingsLoadUsesCanonicalConfigAndEnvProjection() async throws {
        let owner = try Self.owner()
        let transport = DirectHermesVoiceTransportFixture(owner: owner)
        transport.results[WorkspaceOperation.workspaceConfigGet.rawValue] = Self.configResponse()
        transport.results[WorkspaceOperation.keysList.rawValue] = Self.keysResponse(openAI: true, elevenLabs: false)
        let client = DirectHermesVoiceSettingsClient(
            workspace: transport,
            owner: owner,
            currentOwner: { owner }
        )

        let result = try await client.load(agentID: "finance")

        #expect(result.revision.count == 64)
        let revisionIsHex = result.revision.allSatisfy { $0.isHexDigit }
        #expect(revisionIsHex)
        #expect(result.providerID == "openai")
        // Every Hermes speech provider is offered, local ones first.
        #expect(result.providers.map(\.id) == VoiceProviderSpec.builtIn.map(\.id))
        let openAI = try #require(result.providers.first { $0.id == "openai" })
        #expect(openAI.title == "OpenAI")
        #expect(openAI.voiceID == "alloy")
        #expect(openAI.model == "gpt-4o-mini-tts")
        #expect(openAI.apiKeyConfigured)
        #expect(openAI.supportsServerURL)
        let elevenLabs = try #require(result.providers.first { $0.id == "elevenlabs" })
        #expect(elevenLabs.voiceID == "pNInz6obpgDQGcFmaJgB")
        #expect(!elevenLabs.apiKeyConfigured)
        let piper = try #require(result.providers.first { $0.id == "piper" })
        #expect(piper.kind == .onYourComputer)
        #expect(piper.voiceID == "en_US-lessac-medium")
        #expect(!piper.needsAPIKey)
        let neuTTS = try #require(result.providers.first { $0.id == "neutts" })
        #expect(!neuTTS.hasVoice)
        #expect(transport.voiceCalls == [
            .init(operation: .workspaceConfigGet, payload: ["profile": .string("finance")], owner: owner),
            .init(operation: .keysList, payload: ["profile": .string("finance")], owner: owner),
        ])
    }

    @Test func directSettingsUpdateUsesDigestPreconditionAndCanonicalReadback() async throws {
        let owner = try Self.owner()
        let transport = DirectHermesVoiceTransportFixture(owner: owner)
        transport.results[WorkspaceOperation.workspaceConfigGet.rawValue] = Self.configResponse()
        transport.results[WorkspaceOperation.keysList.rawValue] = Self.keysResponse(openAI: true, elevenLabs: false)
        transport.results[WorkspaceOperation.keysSet.rawValue] = ["ok": .boolean(true)]
        transport.results[WorkspaceOperation.workspaceConfigSet.rawValue] = ["ok": .boolean(true)]
        let client = DirectHermesVoiceSettingsClient(
            workspace: transport,
            owner: owner,
            currentOwner: { owner }
        )
        let baseline = try await client.load(agentID: "finance")
        transport.sequences[WorkspaceOperation.workspaceConfigGet.rawValue] = [
            Self.configResponse(),
            Self.configResponse(providerID: "elevenlabs", elevenLabsVoice: "Rachel")
        ]
        transport.sequences[WorkspaceOperation.keysList.rawValue] = [
            Self.keysResponse(openAI: true, elevenLabs: false),
            Self.keysResponse(openAI: true, elevenLabs: true)
        ]
        transport.resetCalls()

        let result = try await client.update(agentID: "finance", settings: VoiceSettingsUpdate(
            expectedRevision: baseline.revision,
            providerID: "elevenlabs",
            voiceID: "Rachel",
            apiKey: "sk-test-secret"
        ))

        #expect(result.revision != baseline.revision)
        #expect(result.providerID == "elevenlabs")
        #expect(result.providers.first(where: { $0.id == "elevenlabs" })?.apiKeyConfigured == true)
        #expect(transport.voiceCalls == [
            .init(operation: .workspaceConfigGet, payload: ["profile": .string("finance")], owner: owner),
            .init(operation: .keysList, payload: ["profile": .string("finance")], owner: owner),
            .init(operation: .keysSet, payload: [
                "profile": .string("finance"), "key": .string("ELEVENLABS_API_KEY"),
                "value": .string("sk-test-secret"),
            ], owner: owner),
            .init(operation: .workspaceConfigSet, payload: [
                "profile": .string("finance"),
                "config": .object([
                    "tts": .object([
                        "provider": .string("elevenlabs"),
                        "elevenlabs": .object(["voice_id": .string("Rachel")]),
                    ])
                ])
            ], owner: owner),
            .init(operation: .workspaceConfigGet, payload: ["profile": .string("finance")], owner: owner),
            .init(operation: .keysList, payload: ["profile": .string("finance")], owner: owner),
        ])
    }

    @Test func directSettingsDoesNotAcceptAResultAfterOwnerChanges() async throws {
        let owner = try Self.owner()
        var current: WorkspaceOwner? = owner
        let transport = DirectHermesVoiceTransportFixture(owner: owner)
        transport.results[WorkspaceOperation.workspaceConfigGet.rawValue] = Self.configResponse()
        transport.results[WorkspaceOperation.keysList.rawValue] = Self.keysResponse(openAI: true, elevenLabs: false)
        transport.onVoiceCall = { current = nil }
        let client = DirectHermesVoiceSettingsClient(
            workspace: transport,
            owner: owner,
            currentOwner: { current }
        )

        await #expect(throws: WorkspaceClientError.ownerChanged) {
            try await client.load(agentID: "finance")
        }
    }

    @Test func directSpeechPostsTextToHermesAndPlaysReturnedAudio() async throws {
        let owner = try Self.owner()
        let transport = DirectHermesVoiceTransportFixture(owner: owner)
        transport.results[WorkspaceOperation.voiceSpeak.rawValue] = [
            "ok": .boolean(true),
            "data_url": .string("data:audio/mpeg;base64,AQID"),
            "mime_type": .string("audio/mpeg"),
            "provider": .string("openai"),
        ]
        let playback = VoiceAudioPlaybackFixture()
        let output = DirectHermesVoiceSpeechOutput(
            workspace: transport,
            owner: owner,
            profileID: "finance",
            playback: playback,
            currentOwner: { owner }
        )

        try await output.speak("Read the answer", rate: 1.25)

        // Warmed first, as Hermes desktop does: that's where Hermes installs a cloud voice's package.
        #expect(transport.voiceCalls.map(\.operation) == [.voiceWarm, .voiceWarm, .voiceSpeak])
        #expect(transport.voiceCalls.map { $0.payload["active"] } == [.boolean(true), .boolean(false), nil])
        #expect(transport.voiceCalls[0].payload["lease"] == transport.voiceCalls[1].payload["lease"])
        #expect(transport.voiceCalls.last == .init(operation: .voiceSpeak, payload: [
            "profile": .string("finance"),
            "text": .string("Read the answer"),
        ], owner: owner))
        #expect(playback.requests == [.init(audio: Data([1, 2, 3]), mimeType: "audio/mpeg")])
    }

    /// Hermes' lease reply when it installed ElevenLabs but the running process
    /// can't load it, and when the install itself failed.
    @Test(arguments: [
        ("venv: tts-premium installed; restart Hermes to activate it (dependency generation 7b91 was published "
            + "after this process loaded 2fdc) — retry, or run `hermes pm doctor`",
         DirectHermesVoiceError.hostRestartRequired),
        ("venv: sync failed — retry, or run `hermes pm doctor`",
         DirectHermesVoiceError.voicePackageMissing(extra: "tts-premium")),
    ])
    func aVoiceHermesCouldNotLoadSaysWhyInsteadOfBlamingTheKey(
        reason: String, expected: DirectHermesVoiceError
    ) async throws {
        let owner = try Self.owner()
        let transport = DirectHermesVoiceTransportFixture(owner: owner)
        transport.results[WorkspaceOperation.voiceWarm.rawValue] = [
            "ok": .boolean(true), "active": .boolean(true), "provider": .string("elevenlabs"),
            "warmed": .boolean(false), "action": .string("error"), "error": .string(reason),
        ]
        // Hermes' speak route answers 400 "package not installed", which reaches the app as this.
        transport.failures[WorkspaceOperation.voiceSpeak.rawValue] = WorkspaceClientError.invalidResponse
        let output = DirectHermesVoiceSpeechOutput(workspace: transport, owner: owner, profileID: "finance",
                                                   playback: VoiceAudioPlaybackFixture(), currentOwner: { owner })

        await #expect(throws: expected) { try await output.speak("Hi", rate: 1) }
    }

    @Test func aVoiceThatWarmedButStillFailsKeepsHermesError() async throws {
        let owner = try Self.owner()
        let transport = DirectHermesVoiceTransportFixture(owner: owner)
        transport.results[WorkspaceOperation.voiceWarm.rawValue] = [
            "ok": .boolean(true), "provider": .string("elevenlabs"), "warmed": .boolean(true), "action": .string("cached"),
        ]
        transport.failures[WorkspaceOperation.voiceSpeak.rawValue] = WorkspaceClientError.invalidResponse
        let output = DirectHermesVoiceSpeechOutput(workspace: transport, owner: owner, profileID: "finance",
                                                   playback: VoiceAudioPlaybackFixture(), currentOwner: { owner })

        await #expect(throws: WorkspaceClientError.invalidResponse) { try await output.speak("Hi", rate: 1) }
    }

    @Test func directSpeechRejectsMalformedAudioWithoutPlayback() async throws {
        let owner = try Self.owner()
        let transport = DirectHermesVoiceTransportFixture(owner: owner)
        transport.results[WorkspaceOperation.voiceSpeak.rawValue] = [
            "ok": .boolean(true),
            "data_url": .string("data:audio/mpeg;base64,not base64"),
            "mime_type": .string("audio/mpeg"),
        ]
        let playback = VoiceAudioPlaybackFixture()
        let output = DirectHermesVoiceSpeechOutput(
            workspace: transport,
            owner: owner,
            profileID: "finance",
            playback: playback,
            currentOwner: { owner }
        )

        await #expect(throws: DirectHermesVoiceError.invalidAudioResponse) {
            try await output.speak("Read the answer", rate: 1)
        }
        #expect(playback.requests.isEmpty)
    }

    @Test func directVoiceSessionUsesNativeVoiceSubmissionAndSteering() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectHermesVoiceRPCFixture()
        rpc.handler = { method, _ in
            switch method {
            case "prompt.submit": return .object(["status": .string("streaming")])
            case "session.steer": return .object(["status": .string("queued")])
            default: throw DirectHermesError.invalidResponse
            }
        }
        let conversation = try DirectHermesConversationClient(
            rpc: rpc,
            hostIdentity: "voice-host",
            profile: "finance",
            runtimeID: "voice-runtime",
            storedID: "voice-stored",
            title: "Voice",
            epoch: "voice-epoch",
            drafts: DirectHermesDraftStore(root: root)
        )
        let output = VoiceSpeechOutputFixture()
        let session = DirectHermesVoiceSessionClient(
            conversation: conversation,
            output: output,
            speechRate: { 1 }
        )

        let responseTask = Task {
            try await session.respond(
                to: "Read my calendar",
                conversationID: conversation.conversationID,
                onDraft: { _ in }
            )
        }
        for _ in 0..<100 where rpc.requests.isEmpty { await Task.yield() }
        conversation.receive(.init(type: "message.start", sessionID: "voice-runtime", payload: [:], sequence: 1))
        try await session.steer("Also include the first event", conversationID: conversation.conversationID)
        conversation.receive(.init(type: "message.complete", sessionID: "voice-runtime",
                                   payload: ["text": .string("Three events tomorrow.")], sequence: 2))
        conversation.receive(.init(type: "session.info", sessionID: "voice-runtime",
                                   payload: ["running": .boolean(false)], sequence: 3))
        let reply = try await responseTask.value
        try await session.speak("Read it aloud")

        #expect(reply.text == "Three events tomorrow.")
        #expect(rpc.requests.map(\.method) == ["prompt.submit", "session.steer"])
        #expect(rpc.requests[1].params["text"] == .string("Also include the first event"))
        #expect(output.requests.map(\.text) == ["Read it aloud"])
    }

    @Test func directVoiceSubmissionMarksHermesLiveVoiceSurface() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectHermesVoiceRPCFixture()
        rpc.handler = { method, _ in
            if method == "prompt.submit" { return .object(["status": .string("streaming")]) }
            return .object(["status": .string("streaming")])
        }
        let conversation = try DirectHermesConversationClient(
            rpc: rpc,
            hostIdentity: "voice-host",
            profile: "finance",
            runtimeID: "voice-runtime",
            storedID: "voice-stored",
            title: "Voice",
            epoch: "voice-epoch",
            drafts: DirectHermesDraftStore(root: root)
        )

        let responseTask = Task {
            try await conversation.sendForVoice(message: "Read my calendar")
        }
        for _ in 0..<100 where rpc.requests.isEmpty { await Task.yield() }
        let request = try #require(rpc.requests.first)
        #expect(request.method == "prompt.submit")
        #expect(request.params["surface"] == .string("voice-live"))
        #expect(request.params["voice_turn"] == .boolean(true), "Hermes runs it on the Voice Chat model")
        #expect(request.params["queued"] == .boolean(true))

        conversation.receive(.init(type: "message.start", sessionID: "voice-runtime", payload: [:], sequence: 1))
        conversation.receive(.init(type: "message.complete", sessionID: "voice-runtime",
                                   payload: ["text": .string("Three events tomorrow.")], sequence: 2))
        conversation.receive(.init(type: "session.info", sessionID: "voice-runtime",
                                   payload: ["running": .boolean(false)], sequence: 3))
        let reply = try await responseTask.value
        #expect(reply.items.last?.content == .message("Three events tomorrow."))
    }

    @Test func queuedVoiceSubmissionRetainsItsWaiterUntilItsTurnCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectHermesVoiceRPCFixture()
        rpc.handler = { method, _ in
            if method == "prompt.submit" { return .object(["status": .string("queued")]) }
            return .object(["status": .string("streaming")])
        }
        let conversation = try DirectHermesConversationClient(
            rpc: rpc,
            hostIdentity: "voice-host",
            profile: "finance",
            runtimeID: "voice-runtime",
            storedID: "voice-stored",
            title: "Voice",
            epoch: "voice-epoch",
            drafts: DirectHermesDraftStore(root: root)
        )

        let responseTask = Task {
            try await conversation.sendForVoice(message: "Read my queued calendar")
        }
        for _ in 0..<100 where rpc.requests.isEmpty { await Task.yield() }
        #expect(rpc.requests.first?.params["surface"] == .string("voice-live"))
        #expect(rpc.requests.first?.params["queued"] == .boolean(true))

        // A terminal snapshot without a turn start cannot settle this queued voice
        // request. The later native events are the only source of its assistant reply.
        conversation.receive(.init(type: "session.info", sessionID: "voice-runtime",
                                   payload: ["running": .boolean(false)], sequence: 1))
        conversation.receive(.init(type: "message.start", sessionID: "voice-runtime", payload: [:], sequence: 2))
        conversation.receive(.init(type: "message.delta", sessionID: "voice-runtime",
                                   payload: ["text": .string("Queued answer")], sequence: 3))
        conversation.receive(.init(type: "message.complete", sessionID: "voice-runtime",
                                   payload: ["text": .string("Queued answer")], sequence: 4))
        conversation.receive(.init(type: "session.info", sessionID: "voice-runtime",
                                   payload: ["running": .boolean(false)], sequence: 5))

        let reply = try await responseTask.value
        #expect(reply.items.map(\.content) == [.message("Queued answer")])
        #expect(conversation.journal.unresolved.isEmpty)
    }
}

@MainActor
private extension DirectHermesVoiceClientTests {
    static func owner() throws -> WorkspaceOwner {
        let authority = try WorkspaceAuthority.fixture(id: "direct-voice-tests")
        return WorkspaceOwner(authority: authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    @Test func directSettingsListsTheHostsCustomCommandProviders() async throws {
        let owner = try Self.owner()
        let transport = DirectHermesVoiceTransportFixture(owner: owner)
        var config = Self.configResponse(providerID: "kokoro")
        var tts = config["tts"]?.object ?? [:]
        tts["providers"] = .object([
            "kokoro": .object(["type": .string("command"), "command": .string("kokoro -o {output_path}")]),
            "empty": .object(["command": .string("  ")]),
        ])
        config["tts"] = .object(tts)
        transport.results[WorkspaceOperation.workspaceConfigGet.rawValue] = config
        transport.results[WorkspaceOperation.keysList.rawValue] = Self.keysResponse(openAI: false, elevenLabs: false)
        let client = DirectHermesVoiceSettingsClient(workspace: transport, owner: owner, currentOwner: { owner })

        let result = try await client.load(agentID: "finance")

        #expect(result.providerID == "kokoro")
        let custom = result.providers.filter { $0.kind == .custom }
        #expect(custom.map(\.id) == ["kokoro"])
        #expect(custom.first?.hasVoice == false)
        #expect(custom.first?.needsAPIKey == false)
    }

    @Test func directSettingsSelectingALocalProviderWritesItsVoiceAndNoKey() async throws {
        let owner = try Self.owner()
        let transport = DirectHermesVoiceTransportFixture(owner: owner)
        transport.results[WorkspaceOperation.keysList.rawValue] = Self.keysResponse(openAI: true, elevenLabs: false)
        transport.results[WorkspaceOperation.workspaceConfigSet.rawValue] = ["ok": .boolean(true)]
        var saved = Self.configResponse(providerID: "piper")
        var tts = saved["tts"]?.object ?? [:]
        tts["piper"] = .object(["voice": .string("en_GB-alba-medium")])
        saved["tts"] = .object(tts)
        transport.sequences[WorkspaceOperation.workspaceConfigGet.rawValue] = [
            Self.configResponse(), Self.configResponse(), saved,
        ]
        let client = DirectHermesVoiceSettingsClient(workspace: transport, owner: owner, currentOwner: { owner })
        let baseline = try await client.load(agentID: "finance")
        transport.resetCalls()

        let result = try await client.update(agentID: "finance", settings: VoiceSettingsUpdate(
            expectedRevision: baseline.revision, providerID: "piper", voiceID: "en_GB-alba-medium", apiKey: nil))

        #expect(result.providerID == "piper")
        #expect(!transport.voiceCalls.contains { $0.operation == .keysSet })
        #expect(transport.voiceCalls.contains(.init(operation: .workspaceConfigSet, payload: [
            "profile": .string("finance"),
            "config": .object(["tts": .object([
                "provider": .string("piper"),
                "piper": .object(["voice": .string("en_GB-alba-medium")]),
            ])]),
        ], owner: owner)))
    }

    @Test func directSettingsPointsOpenAIAtASelfHostedServer() async throws {
        let owner = try Self.owner()
        let transport = DirectHermesVoiceTransportFixture(owner: owner)
        transport.results[WorkspaceOperation.keysList.rawValue] = Self.keysResponse(openAI: true, elevenLabs: false)
        transport.results[WorkspaceOperation.workspaceConfigSet.rawValue] = ["ok": .boolean(true)]
        var saved = Self.configResponse()
        var tts = saved["tts"]?.object ?? [:]
        tts["openai"] = .object(["voice": .string("af_bella"), "base_url": .string("http://10.0.0.5:8880/v1"),
                                 "model": .string("kokoro")])
        saved["tts"] = .object(tts)
        transport.sequences[WorkspaceOperation.workspaceConfigGet.rawValue] = [
            Self.configResponse(), Self.configResponse(), saved,
        ]
        let client = DirectHermesVoiceSettingsClient(workspace: transport, owner: owner, currentOwner: { owner })
        let baseline = try await client.load(agentID: "finance")
        transport.resetCalls()

        let result = try await client.update(agentID: "finance", settings: VoiceSettingsUpdate(
            expectedRevision: baseline.revision, providerID: "openai", voiceID: "af_bella", apiKey: nil,
            model: "kokoro", serverURL: "http://10.0.0.5:8880/v1"))

        #expect(result.providers.first { $0.id == "openai" }?.serverURL == "http://10.0.0.5:8880/v1")
        #expect(transport.voiceCalls.contains(.init(operation: .workspaceConfigSet, payload: [
            "profile": .string("finance"),
            "config": .object(["tts": .object([
                "provider": .string("openai"),
                "openai": .object(["voice": .string("af_bella"), "model": .string("kokoro"),
                                   "base_url": .string("http://10.0.0.5:8880/v1")]),
            ])]),
        ], owner: owner)))
    }

    static func configResponse(
        providerID: String = "openai",
        openAIVoice: String = "alloy",
        elevenLabsVoice: String = "pNInz6obpgDQGcFmaJgB",
        openAIInlineKey: String = ""
    ) -> [String: BighelpJSONValue] {
        [
            "tts": .object([
                "provider": .string(providerID),
                "openai": .object([
                    "voice": .string(openAIVoice),
                    "api_key": .string(openAIInlineKey),
                ]),
                "elevenlabs": .object(["voice_id": .string(elevenLabsVoice)]),
            ]),
        ]
    }

    static func keysResponse(openAI: Bool, elevenLabs: Bool) -> [String: BighelpJSONValue] {
        [
            "VOICE_TOOLS_OPENAI_KEY": keyRow(isSet: openAI, provider: "openai"),
            "OPENAI_API_KEY": keyRow(isSet: false, provider: "openai"),
            "ELEVENLABS_API_KEY": keyRow(isSet: elevenLabs, provider: "elevenlabs"),
        ]
    }

    static func keyRow(isSet: Bool, provider: String) -> BighelpJSONValue {
        .object([
            "is_set": .boolean(isSet),
            "redacted_value": .null,
            "description": .string("Voice provider key"),
            "url": .null,
            "category": .string("voice"),
            "is_password": .boolean(true),
            "tools": .array([]),
            "advanced": .boolean(false),
            "channel_managed": .boolean(false),
            "provider": .string(provider),
            "provider_label": .string(provider),
            "custom": .boolean(false),
        ])
    }
}

@MainActor
private final class DirectHermesVoiceTransportFixture: WorkspaceOperationPerforming {
    struct Call: Equatable {
        let operation: WorkspaceOperation
        let payload: [String: BighelpJSONValue]
        let owner: WorkspaceOwner
    }

    let owner: WorkspaceOwner?
    let capabilities: WorkspaceCapabilities
    var results: [String: [String: BighelpJSONValue]] = [:]
    var sequences: [String: [[String: BighelpJSONValue]]] = [:]
    var failures: [String: any Error] = [:]
    var onVoiceCall: (() -> Void)?
    private(set) var voiceCalls: [Call] = []

    init(owner: WorkspaceOwner) {
        self.owner = owner
        capabilities = .init(owner: owner, values: [.voiceOutput: .available])
    }

    func perform(
        _ operation: WorkspaceOperation,
        payload: [String: BighelpJSONValue],
        owner: WorkspaceOwner
    ) async throws -> [String: BighelpJSONValue] {
        guard [.workspaceConfigGet, .workspaceConfigSet, .keysList, .keysSet, .voiceSpeak, .voiceWarm]
            .contains(operation) else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        voiceCalls.append(.init(operation: operation, payload: payload, owner: owner))
        onVoiceCall?()
        if let failure = failures[operation.rawValue] { throw failure }
        if var sequence = sequences[operation.rawValue], !sequence.isEmpty {
            let value = sequence.removeFirst()
            sequences[operation.rawValue] = sequence
            return value
        }
        return results[operation.rawValue] ?? [:]
    }

    func resetCalls() { voiceCalls.removeAll() }
}

@MainActor
private final class VoiceAudioPlaybackFixture: VoiceAudioPlayback {
    struct Request: Equatable {
        let audio: Data
        let mimeType: String
    }

    private(set) var requests: [Request] = []

    func play(_ audio: Data, mimeType: String) async throws {
        requests.append(.init(audio: audio, mimeType: mimeType))
    }

    func stop() {}
}

@MainActor
private final class VoiceSpeechOutputFixture: VoiceSpeechOutput {
    struct Request: Equatable {
        let text: String
        let rate: Float
    }

    private(set) var requests: [Request] = []

    func speak(_ text: String, rate: Float) async throws {
        requests.append(.init(text: text, rate: rate))
    }

    func stop() {}
}

@MainActor
private final class DirectHermesVoiceRPCFixture: DirectHermesRPC {
    struct Request {
        let method: String
        let params: [String: BighelpJSONValue]
    }

    var onEvent: ((DirectHermesEvent) -> Void)?
    var handler: (@MainActor (String, [String: BighelpJSONValue]) async throws -> BighelpJSONValue)?
    private(set) var requests: [Request] = []

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        requests.append(.init(method: method, params: params))
        guard let handler else { throw DirectHermesError.notConnected }
        return try await handler(method, params)
    }

    func disconnect() async {}
}
