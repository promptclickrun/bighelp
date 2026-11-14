import Foundation
import Testing
@testable import Bighelp

@MainActor
struct VoiceSettingsWorkspaceClientTests {
    @Test func codexLiveVoiceSettingsExplainBighelpPluginRequirementAndInstallEntryPoint() {
        #expect(CodexLiveVoiceSettingsPresentation.title == "Codex Live Voice")
        #expect(CodexLiveVoiceSettingsPresentation.detail(for: .missing)
            .contains("requires the Bighelp plugin"))
        #expect(CodexLiveVoiceSettingsPresentation.installAccessibilityIdentifier
            == "settings.install-loopdy-plugin-for-live-voice")
    }

    @Test func operationsRequireNegotiatedVoiceSettingsSupport() throws {
        for raw in ["voice_settings.get", "voice_settings.set"] {
            let operation = try #require(BighelpLinkWorkspaceOperation(rawValue: raw))
            #expect(operation.requiresHostCapability)
            #expect(operation.requiredCapability == "voice-settings-v1")
        }
    }

    @Test func savesProfileSelectionAndConfirmationWhileOmittingAnUnchangedKey() async throws {
        let messaging = VoiceWorkspaceFixture()
        let client = BighelpVoiceSettingsClient(workspace: BighelpLinkWorkspaceClient(messaging: messaging))
        let loaded = try await client.load(agentID: "finance")
        let saved = try await client.update(agentID: "finance", settings: VoiceSettingsUpdate(
            expectedRevision: loaded.revision, providerID: "openai", voiceID: "nova", apiKey: nil))
        #expect(saved.providerID == "openai")
        #expect(messaging.requests.map(\.operation) == [.voiceSettingsGet, .voiceSettingsSet])
        #expect(messaging.requests.last?.payload == ["agentId": .string("finance"),
            "expectedRevision": .string("revision-1"), "providerId": .string("openai"),
            "voiceId": .string("nova"), "confirmed": .boolean(true)])
    }

    @Test func writesAnExplicitReplacementThroughEncryptedWorkspaceTransport() async throws {
        let messaging = VoiceWorkspaceFixture()
        let client = BighelpVoiceSettingsClient(workspace: BighelpLinkWorkspaceClient(messaging: messaging))
        _ = try await client.update(agentID: "finance", settings: VoiceSettingsUpdate(
            expectedRevision: "revision-1", providerID: "elevenlabs", voiceID: "fixture-voice", apiKey: "fixture-key"))
        #expect(messaging.requests.last?.payload["apiKey"] == .string("fixture-key"))
    }

    @Test func rejectsWrongProfileDuplicateProvidersAndInvalidConfiguration() async throws {
        let messaging = VoiceWorkspaceFixture()
        let client = BighelpVoiceSettingsClient(workspace: BighelpLinkWorkspaceClient(messaging: messaging))
        messaging.responseAgentID = "other-agent"
        await #expect(throws: VoiceSettingsError.self) { try await client.load(agentID: "finance") }
        messaging.responseAgentID = "finance"
        messaging.duplicateProvider = true
        await #expect(throws: VoiceSettingsError.self) { try await client.load(agentID: "finance") }
    }

    @Test func retiredOwnerNeverSendsAndLateReplyDoesNotReturnHostSettings() async throws {
        let messaging = VoiceWorkspaceFixture()
        var owner = true
        let client = BighelpVoiceSettingsClient(workspace: BighelpLinkWorkspaceClient(messaging: messaging),
            isCurrent: { owner })
        messaging.beforeReply = { owner = false }
        await #expect(throws: CancellationError.self) { try await client.load(agentID: "finance") }
        await #expect(throws: CancellationError.self) { try await client.load(agentID: "finance") }
        #expect(messaging.requests.count == 1)
    }
}

@MainActor
private final class VoiceWorkspaceFixture: BighelpLinkWorkspaceMessaging {
    var requests: [BighelpLinkWorkspaceRequest] = []
    var responseAgentID = "finance"
    var duplicateProvider = false
    var beforeReply: () -> Void = {}
    func performWorkspaceRequest(_ request: BighelpLinkWorkspaceRequest) async throws -> BighelpLinkWorkspaceResult {
        requests.append(request)
        beforeReply()
        let object: [String: Any] = [
            "version": 1, "type": "workspace.result", "requestId": request.requestID,
            "operation": request.operation.rawValue, "status": "completed", "sentAt": 1_788_000_001,
            "payload": ["agentId": responseAgentID, "revision": "revision-1", "providerId": "openai",
                "providers": [
                    ["providerId": "openai", "title": "OpenAI", "voiceId": "alloy", "apiKeyConfigured": true],
                    ["providerId": duplicateProvider ? "openai" : "elevenlabs", "title": "ElevenLabs",
                        "voiceId": "", "apiKeyConfigured": false],
                ]],
        ]
        return try JSONDecoder().decode(BighelpLinkWorkspaceResult.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
