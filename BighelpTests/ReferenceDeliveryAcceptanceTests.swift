import CryptoKit
import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import Bighelp

@MainActor
@Suite(.serialized)
struct ReferenceDeliveryAcceptanceTests {
    @Test func retiredProvidersAreNotConnectedAndOrdinaryChatStillSends() async throws {
        let mounted = try await MountedReferenceComposition()
        defer { mounted.close() }
        let hub = try #require(mounted.authority.hub)
        #expect(hub.owner == nil)
        for category in [ReferenceCategory.wiki, .repos, .issues, .prs] {
            hub.selectCategory(category)
            #expect(!hub.isCategoryConfigured)
            #expect(!hub.canConnectCategory)
        }
        let model = mounted.model
        model.draft = "Keep this ordinary message"
        #expect(model.canSend)
        await model.send()
        #expect(model.items.contains { $0.role == .human && $0.content == .message("Keep this ordinary message") })
        #expect(model.draft.isEmpty)
    }

    @Test func accountBoundaryRetiresComposerWithoutOptionalProviders() async throws {
        let mounted = try await MountedReferenceComposition()
        defer { mounted.close() }
        let model = mounted.model
        mounted.store.resetForAccountBoundary()
        model.draft = "Late callback must not send"
        #expect(!model.canSend)
        await model.send()
        #expect(model.items.isEmpty)
    }

    @Test func selectingAnotherAgentPreservesOrdinaryDraftWithoutProviders() async throws {
        let mounted = try await MountedReferenceComposition()
        defer { mounted.close() }
        let model = mounted.model
        model.draft = "Send this to the selected agent"
        #expect(mounted.store.reassignDirectChat(sessionID: model.conversationID, to: "home") == .reassigned)
        #expect(model.draft == "Send this to the selected agent")
        #expect(model.canSend)
        await model.send()
        #expect(model.items.contains { $0.role == .human && $0.content == .message("Send this to the selected agent") })
    }

    @Test func hostSelectionSynchronouslyRetiresTheMountedComposer() async throws {
        let suite = "host-selection-boundary-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let composition = BighelpAppComposition(
            arguments: ["bighelp", "-use-demo-fixtures", "-use-multi-host-fixtures"], defaults: defaults)
        // Let initial discovery settle before preparing the old-host composer.
        for _ in 0..<20 { await Task.yield() }
        let session = try await composition.sessionCatalog.createDirect(agentID: "finance")
        #expect(composition.featureStore.prepare(.chat(conversationID: session.id)))
        guard case .chat(let model) = composition.featureStore.preparedModel(for: .chat(conversationID: session.id)) else {
            Issue.record("Missing prepared composer")
            return
        }
        model.draft = "Belongs only to the original host"
        #expect(model.canSend)
        let replacement = try #require(composition.demoHosts.hosts.first {
            $0.id != composition.demoHosts.selectedHostID
        })
        #expect(composition.demoHosts.selectHost(replacement.id))
        // Fixture host changes synchronously retire the previous composer.
        #expect(!model.canSend)
        await model.send()
        #expect(model.items.isEmpty)
    }



    @Test func canonicalAcceptanceStoresExactSourceWithoutWaitingForFinal() async throws {
        let messaging = ReferenceAcceptanceMessaging()
        let frozen = try frozenDraft()
        var stored = ""
        var receipt: ReferenceCanonicalState?
        let model = makeModel(messaging: messaging,
            persistence: { stored = $0; receipt = $1 })
        model.bindReferenceOwner(frozen.owner)
        try model.updateReferenceDraft(source: frozen.routingSource, selections: frozen.selections)
        let result = await model.sendReferenceDraft(frozen, remainsOwned: { true })
        #expect(result == .accepted)
        #expect(messaging.messages.count == 1)
        #expect(Data(messaging.messages[0].text.utf8) == Data(frozen.canonicalText.utf8))
        #expect(messaging.messages[0].messageID == ReferenceCanonicalSubmission.messageID(for: frozen.submissionID))
        #expect(model.referenceSubmission == nil)
        #expect(model.draft.isEmpty && stored.isEmpty && receipt == nil)
        let human = try #require(model.items.first(where: { $0.role == .human }))
        guard case .message(let source) = human.content else { Issue.record("Missing canonical human row"); return }
        #expect(Data(source.utf8) == Data(frozen.canonicalText.utf8))
        #expect(ReferenceCodec.decode(source).references == frozen.snapshots)
        #expect(messaging.ordinaryCalls == 0)
    }

    @Test func lostAcknowledgementRetainsOneImmutableIntentAndBlocksRetry() async throws {
        let messaging = ReferenceAcceptanceMessaging()
        messaging.refuseWith = CancellationError()
        let frozen = try frozenDraft()
        var checkpoint: ReferenceCanonicalState?
        let model = makeModel(messaging: messaging, persistence: { _, state in checkpoint = state })
        model.bindReferenceOwner(frozen.owner)
        try model.updateReferenceDraft(source: frozen.routingSource, selections: frozen.selections)
        #expect(await model.sendReferenceDraft(frozen, remainsOwned: { true }) == .indeterminate)
        #expect(model.referenceSubmission?.submissionID == frozen.submissionID)
        #expect(checkpoint?.submission?.phase == .indeterminate)
        #expect(Data(model.canonicalReferenceDraft.utf8) == Data(frozen.canonicalText.utf8))
        #expect(await model.sendReferenceDraft(frozen, remainsOwned: { true }) == .indeterminate)
        await model.send()
        #expect(messaging.messages.count == 1 && messaging.ordinaryCalls == 0)
    }

    @Test func failedDurableCheckpointPreventsAnyUploadOrSend() async throws {
        let messaging = ReferenceAcceptanceMessaging()
        let frozen = try frozenDraft()
        let model = makeModel(messaging: messaging, persistence: { _, _ in throw CancellationError() })
        model.bindReferenceOwner(frozen.owner)
        try model.updateReferenceDraft(source: frozen.routingSource, selections: frozen.selections)
        #expect(await model.sendReferenceDraft(frozen, remainsOwned: { true }) == .unavailable)
        #expect(messaging.messages.isEmpty)
        #expect(model.referenceSnapshots == frozen.snapshots)
    }

    @Test func reopeningAndCredentialChoiceUseOnlyExistingCanonicalRecord() throws {
        let frozen = try frozenDraft()
        let state = ReferenceCanonicalState(selections: frozen.selections.map(ReferenceCanonicalSelectionBinding.init), submission: nil)
        let record = SessionRecord(id: frozen.owner.sessionID, kind: .direct, agentIDs: ["finance"], title: "Fixture",
            draft: frozen.canonicalText, referenceState: state, referenceGitHubCredentialID: "opaque-record-1")
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.referenceGitHubCredentialID == "opaque-record-1")
        let messaging = ReferenceAcceptanceMessaging()
        let client = client(messaging)
        let model = ChatModel(conversationID: record.id, client: client, agentID: "finance",
            initialDraft: decoded.draft, sourceSession: decoded)
        #expect(model.referenceSnapshots == frozen.snapshots)
        #expect(Data(model.canonicalReferenceDraft.utf8) == Data(frozen.canonicalText.utf8))
        #expect(messaging.messages.isEmpty && messaging.ordinaryCalls == 0)
    }

    @Test func recipientChangeInvalidatesReviewWithoutDestroyingOrdinaryDraft() throws {
        let original = try frozenDraft().owner
        let model = makeModel(messaging: ReferenceAcceptanceMessaging(), persistence: { _, _ in })
        model.bindReferenceOwner(original)
        model.draft = "Keep this ordinary draft"
        let changed = ReferenceHubOwner(accountID: original.accountID, hostID: original.hostID,
            deviceID: original.deviceID, authorizationEpoch: original.authorizationEpoch,
            sessionID: original.sessionID, agentID: original.agentID, recipientIDs: ["finance", "home"])
        model.bindReferenceOwner(changed)
        #expect(model.draft == "Keep this ordinary draft")
        #expect(model.referenceOwner == changed)
        #expect(model.canSend)
    }

    private func client(_ messaging: ReferenceAcceptanceMessaging) -> ReferenceAcceptanceMessaging {
        messaging
    }
    private func makeModel(messaging: ReferenceAcceptanceMessaging,
                           persistence: @escaping (String, ReferenceCanonicalState?) throws -> Void) -> ChatModel {
        ChatModel(conversationID: "session_fixture_0001", client: client(messaging), agentID: "finance",
            onSessionChange: { _, _, _, _ in }, onReferenceStateChange: persistence)
    }
    private func frozenDraft() throws -> ReferenceFrozenDraft {
        let snapshot = try ReferenceSnapshot(kind: .wiki,
            identity: .wiki(WikiReferenceIdentity(namespace: "fixture", relativePath: "index.md")),
            title: "Fixture", selectedContent: "\u{FEFF}/stop @everyone\r\n```\ne\u{0301}\n```",
            sourceRevision: "revision-1", fetchedAt: Date(timeIntervalSince1970: 1))
        let source = "\u{FEFF}Review\r\n" + snapshot.anchor
        return ReferenceFrozenDraft(submissionID: UUID(), draftID: UUID(), revision: 1,
            owner: ReferenceHubOwner(accountID: "mobile_fixture", hostID: "host_fixture",
                deviceID: "mobile_fixture", authorizationEpoch: "3", sessionID: "session_fixture_0001",
                agentID: "finance", recipientIDs: ["finance"]), routingSource: source,
            canonicalText: try ReferenceCodec.encode(source: source, references: [snapshot]),
            selections: [.init(providerID: ReferenceWikiAdapter.providerID, sourceKindLabel: "Wiki", snapshot: snapshot)])
    }

}

@MainActor @Observable
private final class ReferenceCompositionAuthority {
    var owner: WikiOwner? = WikiOwner(accountID: "account_fixture", hostID: "host_fixture",
        profileID: "finance", deviceID: "mobile_fixture", authorizationEpoch: "3")
    var hub: ReferenceHubStore?
}

@MainActor
private final class MountedReferenceComposition {
    let authority = ReferenceCompositionAuthority()
    let store: ShellFeatureStore
    let catalog: SessionCatalogStore
    let model: ChatModel
    let window: UIWindow
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    init(messaging: ReferenceAcceptanceMessaging? = nil) async throws {
        let record = SessionRecord(id: "reference_context_fixture", kind: .direct,
            agentIDs: ["finance"], title: "Context recovery")
        let repository = DemoRepository<[SessionRecord]>(directory: directory, name: "sessions", seed: [record])
        catalog = SessionCatalogStore(client: SessionCatalogFixtureClient(), records: [record], repository: repository)
        store = ShellFeatureStore(timing: .immediate, catalog: catalog,
            conversationClient: messaging.map { messaging in { _, _ in messaging } })
        #expect(store.prepare(.chat(conversationID: record.id)))
        guard case .chat(let prepared) = store.preparedModel(for: .chat(conversationID: record.id)) else {
            throw ReferenceCanonicalSendError.unavailable
        }
        model = prepared
        let authority = authority
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView:
            ReferenceChatComposition(model: prepared, catalog: catalog, featureStore: store,
                appState: AppState()) { hub, _ in
                Color.clear.onAppear { authority.hub = hub }
            })
        window.makeKeyAndVisible()
        await waitUntil { authority.hub != nil }
        #expect(model.referenceOwner == nil)
    }

    func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Exercises the model's durable submission boundary without reviving a retired transport.
@MainActor
private final class ReferenceAcceptanceMessaging: ReferenceCanonicalConversationClient {
    var messages: [BighelpLinkUserMessage] = []
    var ordinaryCalls = 0
    var refuseWith: (any Error)?

    func prepareReferenceSubmission(_ frozen: ReferenceFrozenDraft,
        attachments: [ChatAttachment], behavior: MidSessionChatBehavior?) throws -> ReferenceCanonicalSubmission {
        #expect(attachments.isEmpty && behavior == nil)
        let message = BighelpLinkUserMessage(
            messageID: ReferenceCanonicalSubmission.messageID(for: frozen.submissionID),
            sessionID: frozen.owner.sessionID, agentID: frozen.owner.agentID,
            actorID: "person_fixture", actorName: "Fixture", deviceName: "Fixture iPhone",
            text: frozen.canonicalText, sentAt: 1_788_000_000)
        return ReferenceCanonicalSubmission(frozen: frozen, message: message, attachments: attachments)
    }

    func submitReference(_ submission: ReferenceCanonicalSubmission,
        remainsOwned: @escaping @MainActor () -> Bool) async throws {
        guard remainsOwned() else { throw CancellationError() }
        messages.append(submission.message)
        if let refuseWith { throw refuseWith }
    }

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        ordinaryCalls += 1
        throw ReferenceCanonicalSendError.unavailable
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        try await send(message: action.intent, conversationID: conversationID)
    }
}
