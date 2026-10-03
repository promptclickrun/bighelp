import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class DirectHermesWorkspaceStore {
    let promptStore = DirectHermesPromptStore()
    let securePromptStore = DirectHermesSecurePromptStore()
    private(set) var address = ""
    private(set) var isConnecting = false
    private(set) var isConnected = false
    private(set) var status = "Connect your Hermes host."
    private(set) var profiles: [DirectHermesProfile] = []
    private(set) var sessions: [DirectHermesSessionSummary] = []
    private(set) var localRecovery: [DirectHermesDraftStore.RecoveryRecord] = []
    private(set) var selectedChat: DirectHermesChat?
    private(set) var hasSavedConnection = false
    private(set) var isLoadingSessions = false
    var selectedProfile = "" {
        didSet {
            if selectedProfile != oldValue {
                navigationGeneration = UUID()
                catalogGeneration = UUID()
                isOpening = false
                isLoadingSessions = false
                earlyEvents = []
                selectedChat = nil
                sessions = []
                localRecovery = []
            }
        }
    }
    @ObservationIgnored var onChatOpened: ((DirectHermesChat) -> Void)?
    @ObservationIgnored var prepareChat: ((DirectHermesChat) async -> Void)?
    @ObservationIgnored var onNativeEvent: ((DirectHermesEvent) -> Void)?
    /// Called synchronously before this store revokes its connection owner.
    /// Native live voice uses it to prepare a fixed cleanup handle while the
    /// original authority is still current.
    @ObservationIgnored var onBeforeConnectionRetired: (() -> Void)?
    @ObservationIgnored private let vault: any DirectHermesCredentialVault
    @ObservationIgnored private let drafts: DirectHermesDraftStore
    @ObservationIgnored private lazy var mediaResolver = DirectHermesStoreMediaProxy { [weak self] in
        guard let self, let client = self.nativeClient,
              let authority = client.savedConnection.workspaceAuthority else { throw WorkspaceClientError.ownerChanged }
        let generation = self.generation
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: generation, connectionGeneration: generation)
        let current: @MainActor () -> WorkspaceOwner? = { [weak self] in
            guard self?.generation == generation, self?.nativeClient === client else { return nil }
            return owner
        }
        let workspace = DirectHermesWorkspaceClient(rpc: client, http: client, owner: owner,
            capabilities: .init(owner: owner), currentOwner: current)
        return DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: current,
                                                cache: .shared, remoteFetch: LinkPreviewLoader.live.fetch)
    }
    @ObservationIgnored private var client: DirectHermesClient?
    @ObservationIgnored private var promptConnection: DirectHermesPromptConnection?
    @ObservationIgnored private var saved: DirectHermesSavedConnection?
    @ObservationIgnored private var epoch = ""
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var catalogGeneration = UUID()
    @ObservationIgnored private var navigationGeneration = UUID()
    @ObservationIgnored private var chats: [String: DirectHermesChat] = [:]
    @ObservationIgnored private var earlyEvents: [DirectHermesEvent] = []
    @ObservationIgnored private var isOpening = false
    @ObservationIgnored private var attemptedApprovalPresentationAcknowledgements = Set<Data>()

    var securePromptPresentation: Binding<DirectHermesSecurePrompt?> {
        _ = securePromptStore.revision
        return securePromptStore.presentationBinding()
    }

    init(vault: any DirectHermesCredentialVault = DirectHermesKeychainVault(),
         drafts: DirectHermesDraftStore = DirectHermesDraftStore()) {
        self.vault = vault
        self.drafts = drafts
        // Loading a credential is not permission to connect at app startup.
        do {
            saved = try vault.load()
            hasSavedConnection = saved != nil
            address = saved?.endpoint.baseURL.absoluteString ?? ""
            if let saved { localRecovery = try drafts.recoveryRecords(hostIdentity: saved.identity) }
        } catch { status = DirectHermesConversationClient.safeMessage(error) }
    }

    func connect(address: String, auth: DirectHermesAuthInput, allowPrivateHTTP: Bool) async {
        guard !isConnecting else { return }
        let previous = retireConnection()
        let owner = generation
        isConnecting = true
        status = "Connecting securely to Hermes…"
        defer { if generation == owner { isConnecting = false } }
        await previous?.disconnect()
        guard owner == generation else { return }
        do {
            let connection = try await DirectHermesClient.connect(address: address, auth: auth,
                allowPrivateHTTP: allowPrivateHTTP, vault: vault)
            guard owner == generation else { await connection.disconnect(); return }
            do { try vault.save(connection.savedConnection) }
            catch { await connection.disconnect(); throw error }
            if !DirectHermesIdentity.matches(saved?.identity, connection.savedConnection.identity) {
                chats.removeAll()
                localRecovery = []
                selectedChat = nil
                selectedProfile = ""
                sessions = []
                profiles = []
            }
            saved = connection.savedConnection
            hasSavedConnection = true
            self.address = connection.endpoint.baseURL.absoluteString
            do { try attach(connection, owner: owner) }
            catch { await connection.disconnect(); throw error }
            try await discoverProfiles(owner: owner)
            guard owner == generation else { return }
            await recoverRetainedChats(connection, owner: owner)
        } catch {
            guard owner == generation else { return }
            status = DirectHermesConversationClient.safeMessage(error)
        }
    }

    /// Called only when the user opens Direct or explicitly reconnects it.
    /// Checks the connection still answers; a silent one is replaced at once.
    func verifyConnection() async {
        guard isConnected, let client else { return }
        await client.verifyLiveness()
    }

    func reconnect() async {
        guard !isConnecting, !isConnected else { return }
        let previous = retireConnection()
        let owner = generation
        isConnecting = true
        status = "Reconnecting to your selected host…"
        defer { if owner == generation { isConnecting = false } }
        await previous?.disconnect()
        guard owner == generation else { return }
        do {
            // Refresh rotation may have reached the vault before the previous
            // connection callback. Never restore a cached, spent refresh token.
            try reloadSavedConnection()
            guard let saved else { return }
            let connection = try await DirectHermesClient.restore(saved, vault: vault)
            guard owner == generation else { await connection.disconnect(); return }
            do { try vault.save(connection.savedConnection) }
            catch { await connection.disconnect(); throw error }
            self.saved = connection.savedConnection
            do { try attach(connection, owner: owner) }
            catch { await connection.disconnect(); throw error }
            try await discoverProfiles(owner: owner)
            guard owner == generation else { return }
            await recoverRetainedChats(connection, owner: owner)
        } catch {
            guard owner == generation else { return }
            // A failed restore may still have rotated credentials successfully.
            // Re-read the exact vault target before offering the next attempt.
            do { try reloadSavedConnection() }
            catch {
                status = "The saved connection could not be reloaded. Reopen Direct before trying again."
                return
            }
            status = DirectHermesConnectionHint.message(
                for: DirectHermesHTTP.safeError(error), host: saved?.endpoint.baseURL.host() ?? "",
                vpnActive: NetworkPathSignature.latest?.vpnActive ?? true)
                ?? DirectHermesConversationClient.safeMessage(error)
        }
    }

    private func recoverRetainedChats(_ connection: DirectHermesClient, owner: UUID) async {
        // Resume every retained durable coordinate before asking its adapter to
        // replay or activate a runtime that belonged to the retired socket.
        let retained = Array(chats.values)
        var rebound: [(chat: DirectHermesChat, resumed: DirectHermesReleaseContract.ResumedSession)] = []
        for chat in retained {
            guard owner == generation else { return }
            let priorRuntimeID = chat.client.runtimeID
            var boundRuntimeIDs: [String] = []
            var retainedRuntimeID: String?
            defer {
                for runtimeID in boundRuntimeIDs where runtimeID != retainedRuntimeID {
                    unbindPromptSession(
                        profile: chat.client.profile,
                        runtimeID: runtimeID,
                        visibleSessionID: chat.client.conversationID,
                        expectedOwner: owner,
                        transport: connection
                    )
                }
            }
            do {
                // If the host kept the runtime alive, requests can race the
                // resume reply. Bind its former ID first, then bind the returned
                // ID before transferring adapter authority.
                let priorBinding = try bindPromptSession(
                    profile: chat.client.profile,
                    runtimeID: priorRuntimeID,
                    visibleSessionID: chat.client.conversationID,
                    expectedOwner: owner,
                    transport: connection
                )
                boundRuntimeIDs.append(priorRuntimeID)
                let snapshot = try await connection.request(
                    "session.resume",
                    params: DirectHermesReleaseContract.resumeParameters(
                        profile: chat.client.profile,
                        storedID: chat.client.storedID
                    )
                )
                guard owner == generation else { throw WorkspaceClientError.ownerChanged }
                let resumed = try DirectHermesReleaseContract.decodeResumedSession(
                    snapshot,
                    profile: chat.client.profile
                )
                let resumedBinding: (store: DirectHermesPromptStore, recovery: DirectHermesOpenRequestRecovery)
                if DirectHermesSessionValidation.same(resumed.runtimeID, priorRuntimeID) {
                    resumedBinding = priorBinding
                } else {
                    resumedBinding = try bindPromptSession(
                        profile: chat.client.profile,
                        runtimeID: resumed.runtimeID,
                        visibleSessionID: chat.client.conversationID,
                        expectedOwner: owner,
                        transport: connection
                    )
                    boundRuntimeIDs.append(resumed.runtimeID)
                }
                chat.client.suspend()
                try chat.client.adoptStandaloneRuntimeID(resumed.runtimeID)
                chat.client.rebind(connection, openRequestRecovery: resumedBinding.recovery)
                retainedRuntimeID = resumed.runtimeID
                rebound.append((chat, resumed))
            } catch {
                chat.client.suspend()
            }
        }
        for recovery in rebound {
            guard owner == generation else { return }
            let chat = recovery.chat
            do {
                try await chat.client.recover(epoch: epoch)
                guard DirectHermesSessionValidation.same(chat.client.runtimeID, recovery.resumed.runtimeID),
                      DirectHermesSessionValidation.same(chat.client.storedID, recovery.resumed.storedID) else {
                    throw WorkspaceClientError.invalidResponse
                }
            }
            catch {
                guard owner == generation else { return }
                unbindPromptSession(
                    profile: chat.client.profile,
                    runtimeID: chat.client.runtimeID,
                    visibleSessionID: chat.client.conversationID,
                    expectedOwner: owner,
                    transport: connection
                )
                chat.client.suspend()
                if selectedChat?.id == chat.id {
                    status = "This native session could not be reattached. Its text is preserved; nothing was resent."
                }
            }
        }
    }

    var savedConnection: DirectHermesSavedConnection? { saved }
    var nativeClient: DirectHermesClient? { isConnected ? client : nil }
    var connectionGeneration: UUID { generation }

    /// Discovery is intentionally separate from connection establishment so a
    /// malformed capability advertisement cannot erase retained chat state.
    /// The parent runtime installs the returned manifest for this exact owner.
    func discoverCapabilityManifest(expectedOwner owner: UUID) async throws -> DirectHermesCapabilityManifest {
        guard isConnected, generation == owner, let client else {
            throw WorkspaceClientError.ownerChanged
        }
        let manifest = try await DirectHermesCapabilityManifest.discover(using: client)
        guard isConnected, generation == owner, self.client === client else {
            throw WorkspaceClientError.ownerChanged
        }
        return manifest
    }

    func bindPromptSession(
        profile: String,
        runtimeID: String,
        visibleSessionID: String,
        expectedOwner owner: UUID,
        transport: DirectHermesClient
    ) throws -> (store: DirectHermesPromptStore, recovery: DirectHermesOpenRequestRecovery) {
        guard let context = promptConnection,
              ownsPromptConnection(context, owner: owner, transport: transport) else {
            throw WorkspaceClientError.ownerChanged
        }
        try promptStore.bind(
            profile: profile, runtimeID: runtimeID, visibleSessionID: visibleSessionID,
            connection: context
        )
        do {
            try securePromptStore.bind(
                profile: profile, runtimeID: runtimeID, visibleSessionID: visibleSessionID,
                connection: context
            )
            for event in earlyEvents where event.sessionID.map({
                Data($0.utf8) == Data(runtimeID.utf8)
            }) == true {
                securePromptStore.acceptLegacyEvent(event, connection: context)
            }
        } catch {
            promptStore.unbind(
                runtimeID: runtimeID, profile: profile, visibleSessionID: visibleSessionID,
                connection: context
            )
            throw error
        }
        let recovery: DirectHermesOpenRequestRecovery = { [weak self, weak transport] openRequests, runtime in
            guard let self, let transport,
                  self.ownsPromptConnection(context, owner: owner, transport: transport) else {
                throw WorkspaceClientError.ownerChanged
            }
            try transport.adoptOpenServerRequests(
                openRequests,
                forRuntimeID: runtime,
                generation: context.transportGeneration
            )
            guard self.ownsPromptConnection(context, owner: owner, transport: transport) else {
                throw WorkspaceClientError.ownerChanged
            }
        }
        return (promptStore, recovery)
    }

    func unbindPromptSession(
        profile: String,
        runtimeID: String,
        visibleSessionID: String,
        expectedOwner owner: UUID,
        transport: DirectHermesClient
    ) {
        guard let context = promptConnection,
              ownsPromptConnection(context, owner: owner, transport: transport) else { return }
        promptStore.unbind(
            runtimeID: runtimeID, profile: profile, visibleSessionID: visibleSessionID,
            connection: context
        )
        securePromptStore.unbind(
            runtimeID: runtimeID, profile: profile, visibleSessionID: visibleSessionID,
            connection: context
        )
    }

    /// Management stays on this exact authenticated socket, never a Link fallback.
    func managePlugins(_ params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        guard isConnected, let client else { throw DirectHermesError.notConnected }
        let owner = generation
        let result = try await client.request("plugins.manage", params: params)
        guard owner == generation else { throw DirectHermesError.secureStorageChanged }
        return result
    }

    /// Hermes' credential vault, on this same authenticated socket. Only the
    /// vault's own methods; a secret passes through once and is never kept.
    func vaultRequest(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        guard Self.vaultMethods.contains(method) else { throw DirectHermesError.invalidResponse }
        guard isConnected, let client else { throw DirectHermesError.notConnected }
        let owner = generation
        let result = try await client.request(method, params: params)
        guard owner == generation else { throw DirectHermesError.secureStorageChanged }
        return result
    }

    private static let vaultMethods: Set<String> = [
        "vault.list", "vault.sources", "vault.source.set", "vault.unlock", "vault.lock", "vault.add", "vault.remove",
    ]

    private func reloadSavedConnection() throws {
        let latest = try vault.load()
        if !DirectHermesIdentity.matches(latest?.identity, saved?.identity) {
            for chat in chats.values { chat.client.suspend() }
            chats = [:]
            selectedChat = nil
            selectedProfile = ""
            sessions = []
            profiles = []
            localRecovery = []
        }
        saved = latest
        hasSavedConnection = latest != nil
        address = latest?.endpoint.baseURL.absoluteString ?? ""
    }

    /// Revoke publication synchronously, before awaiting socket teardown. A
    /// foreground request cannot join the pre-suspension owner accidentally.
    private func retireConnection() -> DirectHermesClient? {
        onBeforeConnectionRetired?()
        if let promptConnection {
            securePromptStore.retireConnection(promptConnection)
            promptStore.retireConnection(promptConnection)
            self.promptConnection = nil
        }
        attemptedApprovalPresentationAcknowledgements.removeAll(keepingCapacity: false)
        generation = UUID()
        catalogGeneration = UUID()
        navigationGeneration = UUID()
        isOpening = false
        earlyEvents = []
        isConnecting = false
        isLoadingSessions = false
        isConnected = false
        for chat in chats.values { chat.model.flushPersistence(); chat.client.suspend() }
        let previous = client
        client = nil
        previous?.onEvent = nil
        previous?.onDisconnect = nil
        previous?.onSavedConnectionChanged = nil
        return previous
    }

    func suspend() async {
        let previous = retireConnection()
        await previous?.disconnect()
    }

    /// View lifecycle callbacks must revoke ownership before returning. A later
    /// task may close the old socket, but cannot suspend a newer presentation.
    func suspendForPresentationExit() {
        let previous = retireConnection()
        Task { await previous?.disconnect() }
    }

    func forgetConnection() async {
        let previous = retireConnection()
        let owner = generation
        await previous?.disconnect()
        guard owner == generation else { return }
        do {
            try vault.delete()
            saved = nil
            hasSavedConnection = false
            address = ""
            selectedChat = nil
            chats = [:]
            profiles = []
            sessions = []
            selectedProfile = ""
            status = "Connection removed. Local drafts remain scoped to their original host and profile."
        } catch { status = DirectHermesConversationClient.safeMessage(error) }
    }

    func loadSessions() async {
        guard isConnected, let client, !selectedProfile.isEmpty else { return }
        let owner = generation
        let profile = selectedProfile
        catalogGeneration = UUID()
        let request = catalogGeneration
        isLoadingSessions = true
        defer { if request == catalogGeneration { isLoadingSessions = false } }
        do {
            let result = try await client.request("session.list", params: ["profile": .string(profile), "limit": .integer(200)])
            guard owner == generation, request == catalogGeneration, profile == selectedProfile else { return }
            guard let values = result.object?["sessions"]?.array else { throw DirectHermesError.invalidResponse }
            sessions = values.compactMap { DirectHermesSessionSummary($0, profile: profile) }
            if let saved { localRecovery = try drafts.recoveryRecords(hostIdentity: saved.identity, profile: profile) }
        } catch {
            guard owner == generation, request == catalogGeneration else { return }
            status = DirectHermesConversationClient.safeMessage(error)
        }
    }

    func newChat() async { await open(nil) }
    func openSession(_ summary: DirectHermesSessionSummary) async {
        guard summary.supportsNativeResume else {
            status = "This history belongs to another Hermes surface. Continue it there; Direct will not take over its active gateway session."
            return
        }
        await open(summary)
    }
    func showSessions() {
        navigationGeneration = UUID()
        isOpening = false
        earlyEvents = []
        selectedChat?.model.flushPersistence()
        selectedChat = nil
        if let saved {
            do { localRecovery = try drafts.recoveryRecords(hostIdentity: saved.identity, profile: selectedProfile) }
            catch { status = "Some local recovery files could not be read. They have not been deleted." }
        }
        let owner = generation
        let navigation = navigationGeneration
        Task { @MainActor [weak self] in
            guard let self, self.generation == owner, self.navigationGeneration == navigation,
                  self.selectedChat == nil else { return }
            await self.loadSessions()
        }
    }

    private func open(_ summary: DirectHermesSessionSummary?) async {
        guard let client, let saved, isConnected, !isOpening, !selectedProfile.isEmpty else { return }
        isOpening = true
        let owner = generation
        let profile = summary?.profile ?? selectedProfile
        let navigation = navigationGeneration
        guard profile == selectedProfile else { isOpening = false; return }
        earlyEvents = []
        defer {
            if navigation == navigationGeneration, owner == generation { isOpening = false; earlyEvents = [] }
        }
        do {
            let value: BighelpJSONValue
            if let summary {
                value = try await client.request("session.resume", params: [
                    "session_id": .string(summary.storedID), "profile": .string(profile),
                    "source": .string(DirectHermesReleaseContract.sessionSource), "close_on_disconnect": .boolean(false)])
            } else {
                value = try await client.request("session.create", params: [
                    "profile": .string(profile), "source": .string(DirectHermesReleaseContract.sessionSource), "close_on_disconnect": .boolean(false)])
            }
            guard owner == generation, navigation == navigationGeneration, profile == selectedProfile else { return }
            guard let object = value.object, let runtime = object["session_id"]?.string,
                  let stored = object["stored_session_id"]?.string ?? object["session_key"]?.string ?? object["resumed"]?.string else {
                throw DirectHermesError.invalidResponse
            }
            // Reuse by exact host-auth/profile/durable coordinates, never title.
            let key = String(data: try JSONEncoder().encode([saved.identity, profile, stored]), encoding: .utf8)!
            let visibleSessionID = "direct-hermes:" + key
            let promptBinding = try bindPromptSession(
                profile: profile, runtimeID: runtime, visibleSessionID: visibleSessionID,
                expectedOwner: owner, transport: client
            )
            var retainsPromptBinding = false
            defer {
                if !retainsPromptBinding {
                    unbindPromptSession(
                        profile: profile, runtimeID: runtime, visibleSessionID: visibleSessionID,
                        expectedOwner: owner, transport: client
                    )
                }
            }
            let chat: DirectHermesChat
            if let retained = chats[key] ?? chats.values.first(where: {
                $0.client.profile == profile && $0.client.storedID == stored
            }) {
                chat = retained
                chat.client.rebind(client, openRequestRecovery: promptBinding.recovery)
                if chat.client.runtimeID != runtime {
                    unbindPromptSession(
                        profile: profile,
                        runtimeID: chat.client.runtimeID,
                        visibleSessionID: chat.client.conversationID,
                        expectedOwner: owner,
                        transport: client
                    )
                    chat.client.suspend()
                    try chat.client.adoptStandaloneRuntimeID(runtime)
                    chat.client.rebind(client, openRequestRecovery: promptBinding.recovery)
                    chat.client.applySnapshot(value, epoch: epoch)
                }
            } else {
                let adapter = try DirectHermesConversationClient(rpc: client, hostIdentity: saved.identity,
                    profile: profile, runtimeID: runtime, storedID: stored,
                    title: summary?.title ?? "New chat", epoch: epoch, drafts: drafts,
                    attachmentResolver: mediaResolver, promptStore: promptBinding.store,
                    openRequestRecovery: promptBinding.recovery)
                let model = ChatModel(conversationID: adapter.conversationID, client: adapter,
                    agentID: profile, initialItems: [], initialDraft: adapter.journal.draft,
                    persistenceCheckpointDelay: .milliseconds(250),
                    generatedMediaResolver: mediaResolver,
                    onSessionChange: { [weak adapter] draft, _, _, _ in adapter?.saveDraft(draft) })
                adapter.model = model
                adapter.applySnapshot(value, epoch: epoch)
                chat = DirectHermesChat(id: key, client: adapter, model: model)
                chats[key] = chat
            }
            guard owner == generation, navigation == navigationGeneration, profile == selectedProfile else { return }
            // Register before recovering so events racing the replay are held by
            // this exact adapter. The selected route isn't published until ready.
            chats[key] = chat
            try await chat.client.recover(epoch: epoch)
            guard owner == generation, navigation == navigationGeneration, profile == selectedProfile else { return }
            // A compression tip can change the durable lookup key while the
            // retained ChatModel and runtime socket owner remain the same.
            chats = chats.filter { $0.value.id != chat.id }
            chats[key] = chat
            await prepareChat?(chat)
            guard owner == generation, navigation == navigationGeneration, profile == selectedProfile else { return }
            selectedChat = chat
            onChatOpened?(chat)
            for event in earlyEvents where event.sessionID == runtime { chat.client.receive(event) }
            retainsPromptBinding = true
            status = "Connected directly · \(profile)"
        } catch {
            guard owner == generation, navigation == navigationGeneration, profile == selectedProfile else { return }
            status = DirectHermesConversationClient.safeMessage(error)
        }
    }

    private func attach(_ connection: DirectHermesClient, owner: UUID) throws {
        client = connection
        isConnected = true
        status = "Connected directly to Hermes"
        let promptConnection = DirectHermesPromptConnection(
            owner: owner,
            principalIdentity: connection.savedConnection.identity,
            client: connection,
            transportGeneration: connection.serverRequestGeneration
        )
        self.promptConnection = promptConnection
        promptStore.beginConnection(promptConnection)
        guard let authority = connection.savedConnection.workspaceAuthority else {
            promptStore.retireConnection(promptConnection)
            self.promptConnection = nil
            client = nil
            isConnected = false
            throw WorkspaceClientError.ownerChanged
        }
        let workspaceOwner = WorkspaceOwner(
            authority: authority,
            authenticationGeneration: owner,
            connectionGeneration: owner
        )
        let currentWorkspaceOwner: @MainActor () -> WorkspaceOwner? = { [weak self, weak connection] in
            guard let self, let connection,
                  self.ownsPromptConnection(promptConnection, owner: owner, transport: connection) else {
                return nil
            }
            return workspaceOwner
        }
        let actionStatusClient = DirectHermesHostOperationsClient(
            rpc: connection,
            http: connection,
            owner: workspaceOwner,
            currentOwner: currentWorkspaceOwner
        )
        let secureDependencies = DirectHermesSecurePromptDependencies(
            respondToLegacyPrompt: { [weak self, weak connection] method, params in
                guard let self, let connection,
                      self.ownsPromptConnection(promptConnection, owner: owner, transport: connection) else {
                    throw WorkspaceClientError.ownerChanged
                }
                let result = try await connection.request(method, params: params)
                guard self.ownsPromptConnection(promptConnection, owner: owner, transport: connection),
                      let status = result.object?["status"]?.string,
                      status == "ok" || status == "expired" else {
                    throw WorkspaceClientError.invalidResponse
                }
                return result
            },
            makeMCPClient: { [weak self, weak connection] profile in
                guard let self, let connection,
                      self.ownsPromptConnection(promptConnection, owner: owner, transport: connection) else {
                    throw WorkspaceClientError.ownerChanged
                }
                return DirectHermesMCPClient(
                    http: connection,
                    rpc: connection,
                    owner: workspaceOwner,
                    profileID: profile,
                    currentOwner: currentWorkspaceOwner,
                    actionStatusClient: actionStatusClient
                )
            },
            reloadMCP: { [weak self, weak connection] runtimeID in
                guard let self, let connection,
                      self.ownsPromptConnection(promptConnection, owner: owner, transport: connection) else {
                    throw WorkspaceClientError.ownerChanged
                }
                let result = try await connection.request("reload.mcp", params: [
                    "session_id": .string(runtimeID),
                    "confirm": .boolean(true),
                ])
                guard self.ownsPromptConnection(promptConnection, owner: owner, transport: connection),
                      result.object?["status"]?.string == "reloaded" else {
                    throw WorkspaceClientError.invalidResponse
                }
            }
        )
        securePromptStore.beginConnection(promptConnection, dependencies: secureDependencies)
        do {
            try connection.setServerRequestHandler(for: "approval") { [weak self, weak connection] request in
                guard let self, let connection,
                      self.ownsPromptConnection(promptConnection, owner: owner, transport: connection) else {
                    return .error(code: -32000, message: "Prompt is no longer active")
                }
                let response = await self.promptStore.handle(request, connection: promptConnection)
                guard self.ownsPromptConnection(promptConnection, owner: owner, transport: connection) else {
                    return .error(code: -32000, message: "Prompt is no longer active")
                }
                return response
            }
            try connection.setServerRequestHandler(for: "clarify") { [weak self, weak connection] request in
                guard let self, let connection,
                      self.ownsPromptConnection(promptConnection, owner: owner, transport: connection) else {
                    return .error(code: -32000, message: "Prompt is no longer active")
                }
                let response = await self.promptStore.handle(request, connection: promptConnection)
                guard self.ownsPromptConnection(promptConnection, owner: owner, transport: connection) else {
                    return .error(code: -32000, message: "Prompt is no longer active")
                }
                return response
            }
            // vault.*: Hermes' browser vault asks for a site's one-time code, a login
            // to save, or a password manager's master password.
            for method in ["secret", "sudo", "mcp.setup", "vault.code", "vault.save_login", "vault.unlock_prompt"] {
                try connection.setServerRequestHandler(for: method) { [weak self, weak connection] request in
                    guard let self, let connection,
                          self.ownsPromptConnection(promptConnection, owner: owner, transport: connection) else {
                        return .error(code: -32000, message: "Secure prompt is no longer active")
                    }
                    let response = await self.securePromptStore.handle(
                        request,
                        connection: promptConnection
                    )
                    guard self.ownsPromptConnection(promptConnection, owner: owner, transport: connection) else {
                        return .error(code: -32000, message: "Secure prompt is no longer active")
                    }
                    return response
                }
            }
        } catch {
            securePromptStore.retireConnection(promptConnection)
            promptStore.retireConnection(promptConnection)
            self.promptConnection = nil
            client = nil
            isConnected = false
            throw error
        }
        connection.onSavedConnectionChanged = { [weak self] updated in
            guard let self, self.generation == owner else { return }
            self.saved = updated
        }
        connection.onDisconnect = { [weak self] error in
            guard let self, self.generation == owner else { return }
            self.securePromptStore.retireConnection(promptConnection)
            self.promptStore.retireConnection(promptConnection)
            self.promptConnection = nil
            self.attemptedApprovalPresentationAcknowledgements.removeAll(keepingCapacity: false)
            self.generation = UUID()
            self.catalogGeneration = UUID()
            self.navigationGeneration = UUID()
            self.isConnecting = false
            self.isOpening = false
            self.isLoadingSessions = false
            self.earlyEvents = []
            self.isConnected = false
            for chat in self.chats.values { chat.client.suspend() }
            self.status = DirectHermesConversationClient.safeMessage(error)
        }
        connection.onEvent = { [weak self] event in
            guard let self, self.generation == owner else { return }
            if event.type == "gateway.ready" { self.epoch = event.payload["replay_epoch"]?.string ?? self.epoch }
            if event.type == "request.cancel",
               let cancellation = try? DirectHermesWire.cancellation(in: event) {
                self.securePromptStore.acceptCancellation(cancellation, connection: promptConnection)
                self.promptStore.acceptCancellation(cancellation, connection: promptConnection)
            }
            self.securePromptStore.acceptLegacyEvent(event, connection: promptConnection)
            if self.isOpening { self.earlyEvents.append(event) }
            for chat in self.chats.values where event.type == "session.reclaimed" || chat.client.runtimeID == event.sessionID {
                // Reclaim is a global envelope; the client validates both exact
                // runtime and durable payload identities before revoking itself.
                chat.client.receive(event)
            }
            self.onNativeEvent?(event)
        }
    }

    /// Called only by a mounted legacy approval card. The attempt is scoped to
    /// this socket generation and is never replayed after an ambiguous result.
    @discardableResult
    func acknowledgePresentation(of prompt: DirectHermesPrompt) async -> Bool {
        // The connection outlives a quick trip to the background; a card drawn
        // then wasn't seen, and the host must still send its notification.
        guard UIApplication.shared.applicationState == .active,
              let acknowledgement = prompt.presentationAcknowledgement,
              let context = promptConnection,
              let transport = client,
              ownsPromptConnection(context, owner: context.owner, transport: transport),
              Data(prompt.hostIdentity.utf8) == context.principalIdentity else { return false }
        let visible = promptStore.prompts(
            hostIdentity: prompt.hostIdentity,
            profile: prompt.profile,
            runtimeID: prompt.runtimeSessionID,
            visibleSessionID: prompt.visibleSessionID
        ).filter {
            Data($0.id.utf8) == Data(prompt.id.utf8)
                && $0.origin == .legacyEvent
                && $0.kind == .approval
                && $0.presentationAcknowledgement == acknowledgement
        }
        guard visible.count == 1 else { return false }
        var attemptKey = Data(context.transportGeneration.rawValue.uuidString.utf8)
        attemptKey.append(0)
        attemptKey.append(contentsOf: prompt.id.utf8)
        guard attemptedApprovalPresentationAcknowledgements.insert(attemptKey).inserted else { return false }
        do {
            let result = try await transport.request("approval.received", params: [
                "session_id": .string(acknowledgement.runtimeSessionID),
                "profile": .string(acknowledgement.profile),
                "request_id": .string(acknowledgement.requestID),
            ])
            return ownsPromptConnection(context, owner: context.owner, transport: transport)
                && result.object?["acknowledged"]?.boolean == true
        } catch {
            return false
        }
    }

    private func ownsPromptConnection(
        _ context: DirectHermesPromptConnection,
        owner: UUID,
        transport: DirectHermesClient
    ) -> Bool {
        generation == owner
            && promptConnection == context
            && client === transport
            && isConnected
            && transport.serverRequestGeneration == context.transportGeneration
            && Data(transport.savedConnection.identity.utf8) == context.principalIdentity
    }

    private func discoverProfiles(owner: UUID) async throws {
        guard let client else { throw DirectHermesError.notConnected }
        let result = try await client.request("profiles.list", params: ["include_sessions": .boolean(false)])
        guard owner == generation else { return }
        guard let rows = result.object?["profiles"]?.array else { throw DirectHermesError.invalidResponse }
        profiles = rows.compactMap(DirectHermesProfile.init)
        if !profiles.contains(where: { $0.id == selectedProfile }) {
            selectedProfile = profiles.first(where: \.isDefault)?.id ?? profiles.first?.id ?? ""
        }
        // Capture the process epoch through the supported replay read even when
        // gateway.ready preceded callback installation during authentication.
        let replay = try await client.request("session.events.since", params: ["session_id": .string(""), "last_seen": .integer(0)])
        guard owner == generation else { return }
        epoch = replay.object?["epoch"]?.string ?? ""
        await loadSessions()
    }
}

struct DirectHermesProfile: Identifiable {
    let id: String
    let name: String
    let isDefault: Bool
    init?(_ value: BighelpJSONValue) {
        guard let object = value.object, let name = object["name"]?.string, !name.isEmpty else { return nil }
        id = name
        self.name = object["display_name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? name
        isDefault = object["is_default"]?.boolean ?? false
    }
}

struct DirectHermesSessionSummary: Identifiable {
    let storedID: String
    let profile: String
    let title: String
    let preview: String
    let source: String
    var id: String { storedID }
    var supportsNativeResume: Bool { [DirectHermesReleaseContract.sessionSource, "desktop", "tui", "cli"].contains(source) }
    init?(_ value: BighelpJSONValue, profile: String) {
        guard let object = value.object, let id = object["id"]?.string, !id.isEmpty else { return nil }
        storedID = object["resolved_id"]?.string ?? id
        self.profile = profile
        title = object["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled chat"
        preview = object["preview"]?.string ?? ""
        source = object["source"]?.string ?? ""
    }
}

struct DirectHermesChat: Identifiable {
    let id: String
    let client: DirectHermesConversationClient
    let model: ChatModel
}

private struct DirectHermesWorkspaceKey: EnvironmentKey {
    static let defaultValue: DirectHermesWorkspaceStore? = nil
}

extension EnvironmentValues {
    var directHermesWorkspace: DirectHermesWorkspaceStore? {
        get { self[DirectHermesWorkspaceKey.self] }
        set { self[DirectHermesWorkspaceKey.self] = newValue }
    }
}

/// A clearer reason when a computer can't be reached for a reason the person can fix here.
enum DirectHermesConnectionHint {
    static func message(for error: DirectHermesError, host: String, vpnActive: Bool) -> String? {
        switch error {
        case .connectionFailed, .timedOut: break
        default: return nil
        }
        guard !vpnActive, isTailscale(host) else { return nil }
        return "Can't reach this computer over Tailscale. Turn on Tailscale on this device, then try again."
    }

    /// MagicDNS names and Tailscale's 100.64.0.0/10 addresses.
    static func isTailscale(_ host: String) -> Bool {
        let host = host.lowercased()
        if host.hasSuffix(".ts.net") { return true }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }
}
