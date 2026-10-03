import Foundation
import Testing
@testable import Bighelp

@MainActor
private final class RowOnlySessionClient: SessionCatalogClient {
    var canDeleteConversation: Bool { false }
    var deleteCalls = 0
    func list() async throws -> [SessionRecord] { [] }
    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func delete(_ record: SessionRecord) async throws { deleteCalls += 1 }
}

@MainActor
private final class NativeControlLoadingFixture: BighelpLinkSessionControlMessaging {
    func openPicker(_ request: BighelpLinkPickerOpenRequest) async throws -> BighelpLinkPicker {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func selectPicker(_ selection: BighelpLinkPickerSelection) async throws -> BighelpLinkPickerResult {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
}

@MainActor
@Suite(.serialized)
struct NativeWorkspaceCompositionTests {
    @Test func nativeSubagentNavigationUsesTheCatalogIdentityAndRejectsAmbiguity() {
        let row = SessionRecord(id: "scoped-child", kind: .direct, agentIDs: ["default"],
                                title: "Child", remoteStoredID: "stored-child")
        #expect(NativeSubagentNavigation.recordID(childStoredID: "stored-child", records: [row]) == "scoped-child")
        #expect(NativeSubagentNavigation.recordID(childStoredID: "missing", records: [row]) == nil)
        let other = SessionRecord(id: "other-profile-child", kind: .direct, agentIDs: ["other"],
                                  title: "Other child", remoteStoredID: "stored-child")
        #expect(NativeSubagentNavigation.recordID(childStoredID: "stored-child", records: [row, other]) == nil)
    }

    @Test func retainedHistoryFailureDoesNotPreventCurrentOrLaterChatRecovery() async throws {
        var recovered: [String] = []
        let failed = try await NativeWorkspaceSessionRecovery.recover(
            ["deleted", "current", "other"], prioritizing: "current", requireCurrent: {}
        ) { id in
            recovered.append(id)
            if id == "deleted" { throw DirectHermesError.notConnected }
        }
        #expect(recovered == ["current", "deleted", "other"])
        #expect(failed == ["deleted"])
    }

    @Test func retainedHistoryRecoveryStopsAtAuthorityChange() async {
        var current = true
        var visited: [String] = []
        await #expect(throws: WorkspaceClientError.ownerChanged) {
            _ = try await NativeWorkspaceSessionRecovery.recover(
                ["first", "second"], prioritizing: nil,
                requireCurrent: { if !current { throw WorkspaceClientError.ownerChanged } }
            ) { id in
                visited.append(id)
                current = false
                throw DirectHermesError.notConnected
            }
        }
        #expect(visited == ["first"])
    }

    @Test func savedChatBindsItsNativeClientAfterHistoryPreparation() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = SessionRecord(id: "saved-native-chat", kind: .direct, agentIDs: ["default"], title: "Saved", remoteStoredID: "stored")
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(), records: [record])
        var client: any ConversationClient = NativeWorkspaceUnavailableClient()
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog, conversationClient: { _, _ in client })
        let route = AppRoute.chat(conversationID: record.id)
        #expect(features.prepare(route))
        guard case .chat(let model)? = features.preparedModel(for: route) else { Issue.record("Missing saved chat"); return }
        let owner = WorkspaceOwner(authority: try .dashboard(endpointIdentity: "https://host.example"),
            authenticationGeneration: UUID(), connectionGeneration: UUID())
        let coordinate = try WorkspaceSessionCoordinate(owner: owner, profileID: "default", sessionID: record.id,
            storedSessionID: "stored", runtimeSessionID: "runtime")
        let native = try DirectHermesConversationClient(rpc: CompositionNativeRPC(), hostIdentity: owner.cacheScopeID, profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Saved", epoch: "epoch", drafts: DirectHermesDraftStore(root: root), workspaceSession: coordinate)
        client = native
        #expect(features.prepare(route))
        #expect(model.nativeConversationClient === native)
    }

    @Test func appCompositionRetiresCloudChatRoutingAndPairedDirectEnrollment() throws {
        let suite = "loopdy.native-only-composition." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let composition = BighelpAppComposition(arguments: ["-use-demo-fixtures"], defaults: preferences)
        #expect(composition.workspaceConnectivity == .nativeOnly)
    }

    @Test func nativeNewSessionControlsDoNotAdoptProfileDefaultsAsCurrentState() throws {
        let session = SessionRecord(id: "native-control-session", kind: .direct, agentIDs: ["default"],
                                    title: "Native", remoteStoredID: "stored")
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(), records: [session])
        let features = ShellFeatureStore(
            timing: .immediate, catalog: catalog, allowsNewChatAgentDefaults: false,
            sessionControlMessaging: NativeControlLoadingFixture()
        )
        #expect(features.prepareNewChat(.chat(conversationID: session.id)))
        guard case .chat(let model)? = features.preparedModel(for: .chat(conversationID: session.id)) else {
            Issue.record("Native chat model was not prepared.")
            return
        }
        let controls = try #require(model.runtimeControls)
        controls.seedAgentDefaults(.init(providerID: "profile-provider", modelID: "profile-model", reasoningEffort: "high"))
        #expect(controls.modelDisplayName == "Session model")
        #expect(controls.currentModel == nil)
    }

    @Test func rowOnlyNativeDeletionCannotReachTheConversationDeleteAction() async throws {
        let client = RowOnlySessionClient()
        let record = SessionRecord(id: "native-row", kind: .direct, agentIDs: ["default"], title: "Native")
        let catalog = SessionCatalogStore(client: client, records: [record])
        #expect(!catalog.canDeleteConversation)
        await #expect(throws: WorkspaceClientError.unavailable(.conversationDeletionUnsupported)) {
            try await catalog.deleteSession(id: record.id)
        }
        #expect(client.deleteCalls == 0)
        #expect(catalog.session(id: record.id) != nil)
    }

    @Test func existingGroupPreviewUsesDiscoverableNativeRoomAndVersionedPersistence() async throws {
        let suite = "loopdy.native-composition-tests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let composition = BighelpAppComposition(
            arguments: ["-use-demo-fixtures", "-disable-demo-delays", "-preview-agent-groups"],
            defaults: preferences
        )
        await composition.botModeRooms.refreshNativeRoomCatalog()
        let summary = try #require(composition.botModeRooms.catalogRooms.first { $0.id == "demo-agent-group" })
        #expect(summary.canOpen)
        #expect(summary.members.map(\.profile) == ["finance", "home"])
        let room = try await composition.botModeRooms.openNativeRoom(roomID: summary.roomID)
        #expect(room.hasNativeRoom)
        #expect(room.profileIDs == ["finance", "home"])
        let record = try composition.sessionCatalog.installWorkspaceRecord(
            SessionRecord(id: "hermes-room:" + room.id, kind: .botMode, agentIDs: room.profileIDs,
                          title: room.title, remoteSource: "hermes-room", botModeRoomID: room.id),
            ownerIsCurrent: { true }
        )
        #expect(composition.featureStore.prepare(.chat(conversationID: record.id)))
    }

    @Test func testedReleaseContractDoesNotClaimUnknownVersionsOrOptionalCapabilities() throws {
        for version in ["0.21.2", "0.21.3", "0.21.4", "0.21.5"] {
            try DirectHermesReleaseContract.validateHealth([
                "ok": .boolean(true), "auth_required": .boolean(true), "version": .string(version)
            ])
        }
        for version in ["0.21.6", "1.0.0", "unknown", "0.21.2-custom", "0.21.4-custom"] {
            #expect(throws: WorkspaceClientError.unavailable(.unsupportedHermesVersion)) {
                try DirectHermesReleaseContract.validateHealth([
                    "ok": .boolean(true), "auth_required": .boolean(true), "version": .string(version)
                ])
            }
        }
        let common = DirectHermesReleaseContract.readOperations
            .union(DirectHermesReleaseContract.sessionOperations)
            .union(DirectHermesReleaseContract.profileOperations)
        #expect(common.contains(.sessionsFork))
        #expect(common.contains(.dashboardRead))
        #expect(common.contains(.dashboardEdit))
        #expect(!common.contains(.liveVoice))
        #expect(!common.contains(.groupActivity))
        #expect(!common.contains(.groupsSend))
        #expect(!common.contains(.cloudNotifications))
        #expect(!common.contains(.phoneTools))
    }

    @Test func nativeForkClientCannotCreateALocalSubstitute() async throws {
        let client: any SessionForkClient = NativeWorkspaceUnavailableClient()
        let request = SessionForkRequest(
            sourceSessionID: "native-source", forkSessionID: "requested-local-child", agentID: "default",
            checkpoint: SessionForkCheckpoint(userTurn: 1, role: .assistant, content: "Exact visible checkpoint"),
            title: "Branch"
        )
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            try await client.fork(request)
        }
    }
}

@MainActor private final class CompositionNativeRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        throw DirectHermesError.notConnected
    }
    func disconnect() async {}
}
