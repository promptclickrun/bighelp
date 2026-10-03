import Foundation

/// Opaque ownership token for one concrete WebSocket generation. Conversation
/// leases may carry this token for recovery, but they cannot create one.
struct DirectHermesServerRequestGeneration: Hashable, Sendable {
    let rawValue: UUID

    init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Standalone stock-Hermes JSON-RPC transport. There is no Link fallback, polling
/// event feed, implicit prompt replay, or process/session takeover in this layer.
@MainActor
final class DirectHermesClient: DirectHermesRPC, DirectHermesAuthenticatedHTTP,
    DirectHermesNativeHTTP, DirectHermesManagedFileBinaryHTTP,
    DirectHermesAdmissionPreparing {
    var onEvent: ((DirectHermesEvent) -> Void)? {
        didSet {
            // connect returns only after readiness. A newly installed consumer must
            // still receive the epoch/capabilities carried by that initial event.
            if let onEvent, let readyEvent, isConnected { onEvent(readyEvent) }
        }
    }
    var onDisconnect: ((DirectHermesError) -> Void)?
    /// Rotation is already persisted before this notification. Consumers should
    /// replace any cached saved-connection snapshot, never re-save an old one.
    var onSavedConnectionChanged: ((DirectHermesSavedConnection) -> Void)?
    private(set) var isConnected = false
    var savedConnection: DirectHermesSavedConnection { authenticator.savedConnection ?? initialConnection }
    var endpoint: DirectHermesEndpoint { initialConnection.endpoint }
    var serverRequestGeneration: DirectHermesServerRequestGeneration {
        DirectHermesServerRequestGeneration(connectionGeneration)
    }

    private let authenticator: DirectHermesAuthenticator
    private let initialConnection: DirectHermesSavedConnection
    private let vault: any DirectHermesCredentialVault
    private var socket: URLSessionWebSocketTask?
    /// Stable for this authenticated client object. Socket epochs rotate below,
    /// but retained prompt handlers remain owned by this logical connection.
    private let connectionGeneration = UUID()
    private var generation = UUID()
    private var readerTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var openingTask: Task<Void, any Error>?
    private var automaticRecoveryTask: Task<Void, Never>?
    private var terminallyClosed = false
    private var readyEvent: DirectHermesEvent?
    private var readyContinuation: CheckedContinuation<Void, any Error>?
    private var readyDeadline: Task<Void, Never>?
    private var pending: [String: Pending] = [:]
    private var serverRequestHandlers: [String: DirectHermesServerRequestHandler] = [:]
    /// The socket that last announced it answers server requests (see advertiseServerRequests).
    private var advertisedGeneration: UUID?
    private var serverRequestTasks: [Data: ServerRequestTask] = [:]
    private var serverRequestState = DirectHermesServerRequestState()
    private var outbox: [Outbound] = []
    private var queuedBytes = 0
    private var queuedServerResponseBytes = 0
    private var attachmentRequestID: String?

    private struct Pending: Sendable {
        let continuation: CheckedContinuation<BighelpJSONValue, any Error>
        let deadline: Task<Void, Never>
        let readOnly: Bool
        var sendStarted: Bool
    }
    private struct Outbound: Sendable {
        let id: String
        /// Non-nil only for a response to a server-authored request.
        let serverMethod: String?
        let text: String
        let byteCount: Int
    }
    private struct ServerRequestTask {
        let token: UUID
        let task: Task<Void, Never>
    }
    private static let maximumPending = 64
    private static let maximumOutboundBytes = 2 * 1_024 * 1_024
    private static let maximumQueuedBytes = 8 * 1_024 * 1_024
    private static let maximumQueuedServerResponseBytes = 4 * 1_024 * 1_024
    // An allowlist is deliberately conservative. Unknown methods may mutate state.
    private static let readOnlyMethods: Set<String> = [
        "gateway.ping", "session.list", "session.active_list", "session.history",
        "session.status", "session.usage", "session.events.since", "commands.catalog",
        "config.get", "delegation.status", "spawn_tree.list",
        "profiles.list", "profiles.describe", "profiles.get_asset", "model.options",
        "projects.list", "projects.get", "subagent.list", "subagent.tail", "client.capabilities",
        "groups.capabilities", "groups.list", "groups.state", "groups.log", "pet.gallery", "pet.thumb"
    ]

    static func connect(address: String, auth: DirectHermesAuthInput,
                        allowPrivateHTTP: Bool = false) async throws -> DirectHermesClient {
        try await connect(address: address, auth: auth, allowPrivateHTTP: allowPrivateHTTP,
                          vault: DirectHermesKeychainVault())
    }

    /// Dependency seam: production uses the default device-local Keychain vault.
    static func connect(address: String, auth: DirectHermesAuthInput,
                        allowPrivateHTTP: Bool = false,
                        vault: any DirectHermesCredentialVault) async throws -> DirectHermesClient {
        let endpoint = try DirectHermesEndpoint(address: address, allowPrivateHTTP: allowPrivateHTTP)
        let authenticator = DirectHermesAuthenticator(endpoint: endpoint)
        do {
            try await authenticator.signIn(auth)
            try Task.checkCancellation()
            guard let saved = authenticator.savedConnection else { throw DirectHermesError.invalidResponse }
            let client = DirectHermesClient(authenticator: authenticator, saved: saved, vault: vault)
            do {
                try await client.openSocket()
                try Task.checkCancellation()
                // A Cloudflare Access token entered during setup is kept once it worked.
                try DirectHermesAccessCredentialStore.shared.commitStaged(for: endpoint)
                // The workspace owns initial persistence AFTER its host-selection
                // generation check. A superseded Connect must not replace a host.
                return client
            } catch {
                await client.disconnect()
                throw DirectHermesHTTP.safeError(error)
            }
        } catch {
            authenticator.http.invalidate()
            throw DirectHermesHTTP.safeError(error)
        }
    }

    static func restore(_ saved: DirectHermesSavedConnection) async throws -> DirectHermesClient {
        try await restore(saved, vault: DirectHermesKeychainVault())
    }

    static func restore(_ saved: DirectHermesSavedConnection,
                        vault: any DirectHermesCredentialVault) async throws -> DirectHermesClient {
        try saved.validate()
        // A retained stale UI snapshot must not overwrite a newer rotation/account.
        guard try vault.load() == saved else { throw DirectHermesError.secureStorageChanged }
        let authenticator = DirectHermesAuthenticator(endpoint: saved.endpoint)
        let client = DirectHermesClient(authenticator: authenticator, saved: saved, vault: vault)
        do {
            try await authenticator.restore(saved)
            try Task.checkCancellation()
            try await client.openSocket()
            try Task.checkCancellation()
            return client
        } catch {
            await client.disconnect()
            throw DirectHermesHTTP.safeError(error)
        }
    }

    private init(authenticator: DirectHermesAuthenticator, saved: DirectHermesSavedConnection,
                 vault: any DirectHermesCredentialVault) {
        self.authenticator = authenticator
        initialConnection = saved
        self.vault = vault
        authenticator.persistRotation = { [weak self] old, replacement in
            guard let self, !self.terminallyClosed else { throw DirectHermesError.notConnected }
            // Synchronous on the main actor: concurrent clients cannot interleave
            // load/compare/save. This item is deliberately not extension-shared.
            guard try self.vault.load() == old else { throw DirectHermesError.secureStorageChanged }
            try self.vault.save(replacement)
            self.onSavedConnectionChanged?(replacement)
        }
    }

    /// Voice turns transcribed by the profile's speech-to-text provider on the
    /// host (stock `/api/audio/transcribe`), over this connection only.
    func makeVoiceTranscriber(
        profileID: String,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) -> @MainActor (Data) async throws -> String {
        let mediaGeneration = generation
        let media = DirectHermesVoiceMediaTransport(
            authenticator: authenticator,
            isCurrent: { [weak self] in
                guard let self else { return false }
                return !self.terminallyClosed && self.isConnected
                    && self.generation == mediaGeneration && currentOwner() == owner
                    && owner.authority.kind == .direct
            }
        )
        return { audio in
            let recording = try DirectHermesVoiceRecording(bytes: audio, mimeType: "audio/wav")
            let response = try await media.transcribeVoice(profileID: profileID, recording: recording)
            return try DirectHermesVoiceConfigurationClient.transcription(response, clientDirect: false).text
        }
    }

    /// Creates the fixed stock-voice client from this connection's retained
    /// authenticator. The media transport is retired by socket generation as
    /// well as the workspace owner, so reconnects cannot inherit old PCM work.
    func makeVoiceConfigurationClient(
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) -> DirectHermesVoiceConfigurationClient {
        let mediaGeneration = generation
        let media = DirectHermesVoiceMediaTransport(
            authenticator: authenticator,
            isCurrent: { [weak self] in
                guard let self else { return false }
                return !self.terminallyClosed && self.isConnected
                    && self.generation == mediaGeneration && currentOwner() == owner
                    && owner.authority.kind == .direct
            }
        )
        return DirectHermesVoiceConfigurationClient(
            http: self,
            relayMediaHTTP: media,
            streamingPlayback: media,
            owner: owner,
            currentOwner: currentOwner
        )
    }

    /// Creates the native Kanban client from this connection's retained
    /// authenticator. Multipart and the separate event socket share its ephemeral
    /// URLSession and token rotation; no second login or connection owner exists.
    func makeKanbanClient(
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) -> DirectHermesKanbanClient {
        let transportGeneration = generation
        let transport = DirectHermesKanbanTransport(
            authenticator: authenticator,
            isCurrent: { [weak self] in
                guard let self else { return false }
                return !self.terminallyClosed && self.isConnected
                    && self.generation == transportGeneration && currentOwner() == owner
                    && owner.authority.kind == .direct
            }
        )
        return DirectHermesKanbanClient(
            rpc: self,
            http: self,
            owner: owner,
            currentOwner: currentOwner,
            eventTransport: transport,
            attachmentTransport: transport
        )
    }

    deinit {
        socket?.cancel(with: .goingAway, reason: nil)
        readerTask?.cancel()
        writerTask?.cancel()
        heartbeatTask?.cancel()
        openingTask?.cancel()
        automaticRecoveryTask?.cancel()
        readyDeadline?.cancel()
        for task in serverRequestTasks.values { task.task.cancel() }
        readyContinuation?.resume(throwing: DirectHermesError.notConnected)
        for request in pending.values {
            request.deadline.cancel()
            request.continuation.resume(throwing: DirectHermesError.disconnected(
                outcomeUnknown: request.sendStarted && !request.readOnly))
        }
    }

    /// Explicit reconnect after a transport loss. Obtains a fresh ticket and never
    /// resends pending RPCs. The session owner reattaches/replays/reads history.
    /// disconnect() is terminal; use restore() after intentionally leaving a host.
    func reconnect() async throws {
        guard !terminallyClosed else { throw DirectHermesError.notConnected }
        if isConnected { return }
        if let openingTask { return try await openingTask.value }
        let epoch = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { throw DirectHermesError.notConnected }
            try await self.authenticator.verifyModeAndSession()
            try Task.checkCancellation()
            guard self.generation == epoch, !self.terminallyClosed else { throw DirectHermesError.notConnected }
            try await self.openSocket()
        }
        openingTask = task
        defer { openingTask = nil }
        do { try await task.value }
        catch { throw DirectHermesHTTP.safeError(error) }
    }

    /// Proves the current socket immediately before a prompt admission. A failed
    /// ping may trigger the bounded automatic reconnect below, but the caller's
    /// mutation is never constructed or sent until the replacement socket is
    /// ready and the conversation bridge has begun its checkpoint catch-up.
    func prepareForAdmission() async throws {
        if let automaticRecoveryTask { await automaticRecoveryTask.value }
        guard !terminallyClosed, isConnected else { throw DirectHermesError.notConnected }
        do {
            _ = try await request("gateway.ping", params: [:], timeoutNanoseconds: 5_000_000_000)
        } catch {
            if let automaticRecoveryTask { await automaticRecoveryTask.value }
            guard !terminallyClosed, isConnected else { throw DirectHermesHTTP.safeError(error) }
            _ = try await request("gateway.ping", params: [:], timeoutNanoseconds: 5_000_000_000)
        }
    }

    func disconnect() async {
        terminallyClosed = true
        automaticRecoveryTask?.cancel()
        automaticRecoveryTask = nil
        openingTask?.cancel()
        openingTask = nil
        closeConnection(.disconnected(outcomeUnknown: false), notify: false)
        // Cancelling a renewal on its way used to leave the sign-in unusable.
        await authenticator.settlePendingRenewal(within: .seconds(8))
        authenticator.http.invalidate()
        onEvent = nil
        onDisconnect = nil
        onSavedConnectionChanged = nil
    }

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        try await request(method, params: params, timeoutNanoseconds: 45_000_000_000)
    }

    /// Registers only methods the app can actually fulfill. Missing handlers are
    /// rejected with -32601; registration itself never advertises a capability.
    func setServerRequestHandler(for method: String,
                                 handler: DirectHermesServerRequestHandler?) throws {
        guard !terminallyClosed, DirectHermesWire.validMethod(method), method != "event" else {
            throw DirectHermesError.invalidResponse
        }
        serverRequestHandlers[method] = handler
        if handler != nil { advertiseServerRequests() }
    }

    /// Hermes sends clarify, approval, secret and sudo requests only to a socket that announced
    /// `client.capabilities {server_requests: true}`; to any other app it answers them blank itself
    /// (hermes #112548). Announce once per socket, as soon as this client has handlers. Older Hermes
    /// has no such method and needs none, so a rejection is fine; a lost socket re-announces.
    private func advertiseServerRequests() {
        guard isConnected, socket != nil, !terminallyClosed, !serverRequestHandlers.isEmpty,
              advertisedGeneration != generation else { return }
        advertisedGeneration = generation
        let epoch = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.request("client.capabilities", params: ["server_requests": .boolean(true)],
                                           timeoutNanoseconds: 15_000_000_000)
            } catch DirectHermesError.rpcRejected(_) {
                return
            } catch {
                if self.generation == epoch { self.advertisedGeneration = nil }
            }
        }
    }

    /// Adopts the final `session.events.since.open_requests` snapshot into the
    /// same dispatch path used by live server requests. Validation completes
    /// before any entry mutates transport state.
    func adoptOpenServerRequests(
        _ value: BighelpJSONValue,
        forRuntimeID runtimeID: String,
        generation expected: DirectHermesServerRequestGeneration
    ) throws {
        guard expected.rawValue == connectionGeneration, isConnected, socket != nil, !terminallyClosed,
              !runtimeID.isEmpty, runtimeID.utf8.count <= 4_096,
              let rows = value.array,
              rows.count <= DirectHermesServerRequestState.maximumOpenRequests else {
            throw DirectHermesError.invalidResponse
        }
        var requests: [DirectHermesServerRequest] = []
        requests.reserveCapacity(rows.count)
        for row in rows {
            guard let object = row.object,
                  Set(object.keys) == Set(["id", "method", "params"]),
                  let id = object["id"]?.string, DirectHermesWire.validRequestID(id),
                  let method = object["method"]?.string, DirectHermesWire.validMethod(method),
                  let params = object["params"]?.object,
                  let sessionID = params["session_id"]?.string,
                  sessionID.utf8.elementsEqual(runtimeID.utf8) else {
                throw DirectHermesError.invalidResponse
            }
            requests.append(DirectHermesServerRequest(id: id, method: method, params: params))
        }
        guard expected.rawValue == connectionGeneration, isConnected, socket != nil, !terminallyClosed else {
            throw DirectHermesError.notConnected
        }
        for request in requests {
            acceptServerRequest(request, epoch: generation)
        }
    }

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        guard !terminallyClosed, isConnected else { throw DirectHermesError.notConnected }
        let owner = generation
        var receivedStatus: Int?
        do {
            let response = try await authenticator.authenticatedResponse(request)
            receivedStatus = response.http.statusCode
            guard generation == owner, !terminallyClosed else { throw WorkspaceClientError.ownerChanged }
            try Task.checkCancellation()
            try DirectHermesHTTP.requireSuccess(response)
            return try response.value()
        } catch {
            if request.method != .get,
               ![400, 401, 403, 404, 405, 409, 422, 429].contains(receivedStatus ?? -1) {
                throw WorkspaceClientError.outcomeUnknown
            }
            throw error
        }
    }

    /// Executes only the fixed multipart host-import operation. Generation is
    /// checked after token refresh at the dispatch boundary and after the await.
    /// No error after bytes may leave causes an automatic replay.
    func hostImportUploadTransportResponse(
        _ request: DirectHermesHostImportUploadRequest
    ) async throws -> DirectHermesHTTP.Response {
        guard !terminallyClosed, isConnected else { throw DirectHermesError.notConnected }
        let owner = generation
        var bytesMayHaveLeft = false
        var receivedStatus: Int?
        do {
            let response = try await authenticator.authenticatedHostImportUploadResponse(
                request,
                willDispatch: { [weak self] in
                    guard let self,
                          self.generation == owner,
                          self.isConnected,
                          !self.terminallyClosed else {
                        throw WorkspaceClientError.ownerChanged
                    }
                    try Task.checkCancellation()
                    bytesMayHaveLeft = true
                },
                didReceiveStatus: { statusCode in
                    receivedStatus = statusCode
                }
            )
            receivedStatus = response.http.statusCode
            guard generation == owner, isConnected, !terminallyClosed else {
                throw WorkspaceClientError.ownerChanged
            }
            try Task.checkCancellation()
            try DirectHermesHTTP.requireSuccess(response)
            return response
        } catch {
            if bytesMayHaveLeft,
               !DirectHermesHostImportTransportBoundary.isDefinitiveRejection(receivedStatus) {
                throw WorkspaceClientError.outcomeUnknown
            }
            throw error
        }
    }

    func managedFileTransportResponse(
        _ request: DirectHermesManagedFileTransportRequest,
        requireOriginalOwner: @escaping @MainActor () throws -> Void = {}
    ) async throws -> DirectHermesHTTP.Response {
        guard !terminallyClosed, isConnected else { throw DirectHermesError.notConnected }
        let owner = generation
        var bytesMayHaveLeft = false
        var receivedStatus: Int?
        do {
            let response = try await authenticator.authenticatedManagedFileResponse(
                request,
                willDispatch: { [weak self] in
                    guard let self,
                          self.generation == owner,
                          self.isConnected,
                          !self.terminallyClosed else {
                        throw WorkspaceClientError.ownerChanged
                    }
                    try Task.checkCancellation()
                    try requireOriginalOwner()
                    bytesMayHaveLeft = true
                },
                didReceiveStatus: { statusCode in
                    receivedStatus = statusCode
                }
            )
            receivedStatus = response.http.statusCode
            guard generation == owner, isConnected, !terminallyClosed else {
                throw WorkspaceClientError.ownerChanged
            }
            try Task.checkCancellation()
            try DirectHermesHTTP.requireSuccess(response)
            return response
        } catch {
            if request.isMutation,
               bytesMayHaveLeft,
               ![400, 401, 403, 404, 405, 409, 413, 415, 422, 429].contains(receivedStatus ?? -1) {
                // Once a multipart request may have left the process, transport
                // failure, cancellation, or generation retirement cannot prove
                // the host rejected the write. The managed-files client performs
                // authoritative list and byte readback instead of replaying it.
                throw WorkspaceClientError.outcomeUnknown
            }
            throw error
        }
    }

    func nativeResponse(_ request: DirectHermesHTTPRequest,
                        requestGuard: DirectHermesNativeRequestGuard?) async throws -> DirectHermesHTTP.Response {
        guard !terminallyClosed, isConnected else { throw DirectHermesError.notConnected }
        let owner = generation
        let response = try await authenticator.authenticatedResponse(request, nativeGuard: requestGuard)
        guard generation == owner, !terminallyClosed else { throw WorkspaceClientError.ownerChanged }
        try Task.checkCancellation()
        return response
    }

    private func request(_ method: String, params: [String: BighelpJSONValue],
                         timeoutNanoseconds: UInt64) async throws -> BighelpJSONValue {
        guard isConnected, socket != nil, !terminallyClosed else { throw DirectHermesError.notConnected }
        guard !method.isEmpty, method.utf8.count <= 256,
              method.utf8.allSatisfy({ (33...126).contains($0) }) else { throw DirectHermesError.invalidResponse }
        guard pending.count < Self.maximumPending else { throw DirectHermesError.tooManyRequests }
        let isAttachment = method == "file.attach" || method == "image.attach_bytes"
        guard !isAttachment || attachmentRequestID == nil else { throw DirectHermesError.tooManyRequests }
        let id = UUID().uuidString
        let epoch = generation
        let object: BighelpJSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": .object(params)
        ])
        let outboundLimit = Self.outboundLimit(method: method, params: params)
        try DirectHermesWire.validateValueSize(object, limit: outboundLimit)
        let data: Data
        do { data = try JSONEncoder().encode(object) }
        catch { throw DirectHermesError.invalidResponse }
        guard data.count <= outboundLimit else { throw DirectHermesError.messageTooLarge }
        let queuedLimit = isAttachment ? DirectHermesFileAttachments.maximumFrameBytes : Self.maximumQueuedBytes
        guard queuedBytes + data.count <= queuedLimit else { throw DirectHermesError.tooManyRequests }
        try DirectHermesWire.validateNesting(data)
        guard let text = String(data: data, encoding: .utf8) else { throw DirectHermesError.invalidResponse }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, self.generation == epoch, self.isConnected else {
                    continuation.resume(throwing: DirectHermesError.cancelled(outcomeUnknown: false))
                    return
                }
                let deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
                    catch { return }
                    self?.expire(id: id, epoch: epoch)
                }
                pending[id] = Pending(continuation: continuation, deadline: deadline,
                                      readOnly: Self.readOnlyMethods.contains(method), sendStarted: false)
                if isAttachment { attachmentRequestID = id }
                outbox.append(Outbound(id: id, serverMethod: nil, text: text, byteCount: data.count))
                queuedBytes += data.count
                startWriter(epoch: epoch)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRequest(id: id, epoch: epoch) }
        }
    }

    static func outboundLimit(method: String, params: [String: BighelpJSONValue]) -> Int {
        if DirectHermesAttachmentClient.permitsLargeFrame(method: method, params: params) {
            return DirectHermesFileAttachments.maximumFrameBytes
        }
        return method == "profiles.set_asset" ? 2_800_000 : maximumOutboundBytes
    }

    private func openSocket() async throws {
        guard !terminallyClosed, socket == nil else { throw DirectHermesError.notConnected }
        let epoch = generation
        let request = try await authenticator.websocketRequest()
        try Task.checkCancellation()
        guard generation == epoch, !terminallyClosed else { throw DirectHermesError.notConnected }
        let socket = authenticator.http.session.webSocketTask(with: request)
        socket.maximumMessageSize = DirectHermesWire.maximumMessageBytes
        self.socket = socket
        socket.resume()
        readerTask = Task { @MainActor [weak self, socket] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .data(let bytes): data = bytes
                    case .string(let text):
                        guard text.utf8.count <= DirectHermesWire.maximumMessageBytes else { throw DirectHermesError.messageTooLarge }
                        data = Data(text.utf8)
                    @unknown default: throw DirectHermesError.invalidResponse
                    }
                    // Decode off the main actor, but await each frame before reading
                    // another: callbacks see strict wire order, including batches.
                    let decoded = try await Task.detached(priority: .userInitiated) {
                        try DirectHermesWire.decode(data)
                    }.value
                    guard let owner = self, owner.generation == epoch, !Task.isCancelled else { return }
                    owner.accept(decoded, epoch: epoch)
                }
            } catch {
                guard let owner = self, owner.generation == epoch else { return }
                let response = socket.response as? HTTPURLResponse
                let safe: DirectHermesError
                if let status = response?.statusCode, status == 401 || status == 403 { safe = .invalidCredentials }
                else if let status = response?.statusCode, (300...399).contains(status) { safe = .redirectRefused }
                else { safe = DirectHermesHTTP.safeError(error) }
                owner.closeConnection(safe, notify: true)
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    guard !Task.isCancelled, generation == epoch else {
                        continuation.resume(throwing: DirectHermesError.cancelled(outcomeUnknown: false))
                        return
                    }
                    readyContinuation = continuation
                    readyDeadline = Task { @MainActor [weak self] in
                        do { try await Task.sleep(nanoseconds: 20_000_000_000) }
                        catch { return }
                        guard let self, self.generation == epoch, !self.isConnected else { return }
                        self.closeConnection(.timedOut(outcomeUnknown: false), notify: true)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == epoch else { return }
                    self.closeConnection(.cancelled(outcomeUnknown: false), notify: true)
                }
            }
        } catch {
            if generation == epoch { closeConnection(DirectHermesHTTP.safeError(error), notify: false) }
            throw DirectHermesHTTP.safeError(error)
        }
        // A replacement socket after a drop keeps the handlers; announce them again.
        advertiseServerRequests()
    }

    private func accept(_ messages: [DirectHermesWire.Message], epoch: UUID) {
        for message in messages {
            guard generation == epoch else { return }
            switch message {
            case .event(let event):
                if event.type == "request.cancel",
                   let cancellation = try? DirectHermesWire.cancellation(in: event) {
                    retireServerRequest(cancellation)
                }
                if event.type == "gateway.ready" {
                    guard !isConnected, readyContinuation != nil else {
                        closeConnection(.invalidResponse, notify: true)
                        return
                    }
                    isConnected = true
                    readyEvent = event
                    let waiter = readyContinuation
                    readyContinuation = nil
                    readyDeadline?.cancel()
                    readyDeadline = nil
                    waiter?.resume()
                    startHeartbeat(epoch: epoch)
                    // A server request may precede ready in the same decoded
                    // frame. Its response remains ordered and starts only now.
                    startWriter(epoch: epoch)
                }
                onEvent?(event)
            case .request(let request):
                acceptServerRequest(request, epoch: epoch)
            case .result(let id, let value): finish(id: id, result: .success(value))
            case .failure(let id, let code): finish(id: id, result: .failure(.rpcRejected(code: code)))
            }
        }
    }

    private func acceptServerRequest(_ request: DirectHermesServerRequest, epoch: UUID) {
        switch serverRequestState.register(request) {
        case .duplicate, .atCapacity:
            // Keep the existing request authoritative and bounded. A duplicate
            // must never create a second UI decision or response.
            return
        case .accepted:
            break
        }
        guard let handler = serverRequestHandlers[request.method] else {
            queueServerResponse(
                request,
                response: .error(code: -32601, message: "Method not supported by this client"),
                epoch: epoch
            )
            return
        }
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            let response = await handler(request)
            self?.completeServerRequestHandler(
                request, token: token, response: response, epoch: epoch,
                wasCancelled: Task.isCancelled
            )
        }
        serverRequestTasks[Data(request.id.utf8)] = ServerRequestTask(token: token, task: task)
    }

    private func completeServerRequestHandler(_ request: DirectHermesServerRequest,
                                              token: UUID,
                                              response: DirectHermesServerResponse,
                                              epoch: UUID,
                                              wasCancelled: Bool) {
        let key = Data(request.id.utf8)
        guard serverRequestTasks[key]?.token == token else { return }
        serverRequestTasks.removeValue(forKey: key)
        guard !wasCancelled, generation == epoch, !terminallyClosed else { return }
        queueServerResponse(request, response: response, epoch: epoch)
    }

    private func queueServerResponse(_ request: DirectHermesServerRequest,
                                     response: DirectHermesServerResponse,
                                     epoch: UUID) {
        guard generation == epoch, !terminallyClosed else { return }
        var text: String
        do {
            text = try DirectHermesWire.encodeServerResponse(id: request.id, response: response)
        } catch {
            // Never reflect handler/server content in a protocol failure. A
            // bounded constant error still answers the exact original ID.
            guard let fallback = try? DirectHermesWire.encodeServerResponse(
                id: request.id,
                response: .error(code: -32603, message: "Client could not encode the response")
            ) else {
                serverRequestState.retire(id: request.id, method: request.method)
                return
            }
            text = fallback
        }
        var byteCount = text.utf8.count
        if queuedServerResponseBytes + byteCount > Self.maximumQueuedServerResponseBytes {
            guard let fallback = try? DirectHermesWire.encodeServerResponse(
                id: request.id,
                response: .error(code: -32603, message: "Client response queue is full")
            ) else {
                serverRequestState.retire(id: request.id, method: request.method)
                return
            }
            text = fallback
            byteCount = fallback.utf8.count
        }
        guard queuedServerResponseBytes + byteCount <= Self.maximumQueuedServerResponseBytes else {
            serverRequestState.retire(id: request.id, method: request.method)
            return
        }
        guard serverRequestState.stageResponse(id: request.id, method: request.method) else { return }
        outbox.append(Outbound(id: request.id, serverMethod: request.method,
                               text: text, byteCount: byteCount))
        queuedBytes += byteCount
        queuedServerResponseBytes += byteCount
        startWriter(epoch: epoch)
    }

    private func retireServerRequest(_ cancellation: DirectHermesServerRequestCancellation) {
        guard serverRequestState.cancel(cancellation) else { return }
        serverRequestTasks.removeValue(forKey: Data(cancellation.id.utf8))?.task.cancel()
        if let index = outbox.firstIndex(where: {
            DirectHermesIdentity.matches($0.id, cancellation.id) && $0.serverMethod == cancellation.method
        }) {
            let byteCount = outbox.remove(at: index).byteCount
            queuedBytes -= byteCount
            queuedServerResponseBytes -= byteCount
        }
    }

    private func startWriter(epoch: UUID) {
        guard writerTask == nil, let socket, generation == epoch else { return }
        writerTask = Task { @MainActor [weak self, socket] in
            while !Task.isCancelled, let item = self?.nextOutbound(epoch: epoch) {
                do { try await socket.send(.string(item.text)) }
                catch {
                    guard let self, self.generation == epoch else { return }
                    self.closeConnection(DirectHermesHTTP.safeError(error), notify: true)
                    return
                }
            }
            guard let self, self.generation == epoch else { return }
            self.writerTask = nil
        }
    }

    private func nextOutbound(epoch: UUID) -> Outbound? {
        guard generation == epoch, isConnected else { return nil }
        while !outbox.isEmpty {
            let item = outbox.removeFirst()
            queuedBytes -= item.byteCount
            if let method = item.serverMethod {
                queuedServerResponseBytes -= item.byteCount
                guard serverRequestState.beginSendingResponse(id: item.id, method: method) else { continue }
                return item
            }
            guard var request = pending[item.id] else { continue }
            // Set BEFORE the first suspension in send. A send failure can occur
            // after the server received the frame, so it is never proof of rejection.
            request.sendStarted = true
            pending[item.id] = request
            return item
        }
        return nil
    }

    private func finish(id: String, result: Result<BighelpJSONValue, DirectHermesError>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        if attachmentRequestID == id { attachmentRequestID = nil }
        request.deadline.cancel()
        if let index = outbox.firstIndex(where: { $0.id == id && $0.serverMethod == nil }) {
            queuedBytes -= outbox.remove(at: index).byteCount
        }
        switch result {
        case .success(let value): request.continuation.resume(returning: value)
        case .failure(let error): request.continuation.resume(throwing: error)
        }
    }

    private func expire(id: String, epoch: UUID) {
        guard generation == epoch, let request = pending[id] else { return }
        finish(id: id, result: .failure(.timedOut(outcomeUnknown: request.sendStarted && !request.readOnly)))
        if request.sendStarted {
            // Also unpark a stalled send before any queued action could be sent.
            closeConnection(.timedOut(outcomeUnknown: false), notify: true)
        }
    }

    private func cancelRequest(id: String, epoch: UUID) {
        guard generation == epoch, let request = pending[id] else { return }
        finish(id: id, result: .failure(.cancelled(outcomeUnknown: request.sendStarted && !request.readOnly)))
        // Cancellation is local ownership retirement, NOT a server-side interrupt.
        // An already dispatched action may still complete; never resend it here.
    }

    /// Every connection is kept awake, whether or not Hermes asked for a heartbeat: proxies
    /// (Cloudflare closes a connection after 100 quiet seconds), phone networks and Tailscale
    /// relays drop idle ones without telling either side. A ping that goes unanswered means the
    /// connection is gone, so it's replaced now rather than when a message times out.
    private func startHeartbeat(epoch: UUID) {
        heartbeatTask?.cancel()
        let interval = DirectHermesKeepalive.interval(
            heartbeatAdvertised: readyEvent?.payload["heartbeat"]?.boolean == true)
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) }
                catch { return }
                guard let self, self.generation == epoch, self.isConnected else { return }
                do {
                    _ = try await self.request("gateway.ping", params: [:],
                                               timeoutNanoseconds: DirectHermesKeepalive.pingTimeoutNanoseconds)
                } catch {
                    guard self.generation == epoch else { return }
                    switch DirectHermesKeepalive.outcome(of: error) {
                    case .alive: continue
                    case .unsupported: return // It answered; this Hermes just has no ping.
                    case .dead:
                        self.closeConnection(DirectHermesHTTP.safeError(error), notify: true)
                        return
                    }
                }
            }
        }
    }

    /// A quick check that the connection still answers, after the network changed or the app
    /// came back. A silent one is replaced right away (the usual automatic reconnect), so the
    /// next message doesn't wait out a full timeout on a connection that's already gone.
    func verifyLiveness() async {
        guard isConnected, !terminallyClosed, automaticRecoveryTask == nil else { return }
        let epoch = generation
        do {
            _ = try await request("gateway.ping", params: [:],
                                  timeoutNanoseconds: DirectHermesKeepalive.livenessTimeoutNanoseconds)
        } catch {
            guard generation == epoch, isConnected, DirectHermesKeepalive.outcome(of: error) == .dead else { return }
            closeConnection(DirectHermesHTTP.safeError(error), notify: true)
        }
    }

    private func startAutomaticRecovery(after initialError: DirectHermesError) {
        guard automaticRecoveryTask == nil, !terminallyClosed else { return }
        automaticRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastError = initialError
            let delays: [UInt64] = [0, 1_000_000_000, 3_000_000_000]
            for delay in delays {
                if delay > 0 {
                    do { try await Task.sleep(nanoseconds: delay) }
                    catch { return }
                }
                guard !Task.isCancelled, !self.terminallyClosed else { return }
                do {
                    try await self.reconnect()
                    guard self.isConnected else { throw DirectHermesError.notConnected }
                    self.automaticRecoveryTask = nil
                    return
                } catch {
                    lastError = DirectHermesHTTP.safeError(error)
                }
            }
            guard !Task.isCancelled, !self.terminallyClosed else { return }
            self.automaticRecoveryTask = nil
            self.serverRequestHandlers.removeAll()
            self.onDisconnect?(lastError)
        }
    }

    private func closeConnection(_ reason: DirectHermesError, notify: Bool) {
        let hadConnection = socket != nil || readyContinuation != nil || isConnected
        let requests = pending
        let hasUncertainMutation = requests.values.contains {
            $0.sendStarted && !$0.readOnly
        }
        let shouldRecover = notify && hadConnection && !terminallyClosed && !hasUncertainMutation
        let preservesHandlers = shouldRecover || automaticRecoveryTask != nil
        generation = UUID()
        isConnected = false
        readyEvent = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        readerTask?.cancel()
        readerTask = nil
        writerTask?.cancel()
        writerTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        readyDeadline?.cancel()
        readyDeadline = nil
        let ready = readyContinuation
        readyContinuation = nil
        ready?.resume(throwing: reason)
        pending.removeAll()
        for task in serverRequestTasks.values { task.task.cancel() }
        serverRequestTasks.removeAll()
        serverRequestState.removeAll()
        // A same-owner automatic reconnect keeps the registered handlers but
        // never their in-flight requests/responses. Terminal/manual retirement
        // clears both the socket and its logical capability owner.
        if !preservesHandlers { serverRequestHandlers.removeAll() }
        outbox.removeAll()
        queuedBytes = 0
        queuedServerResponseBytes = 0
        attachmentRequestID = nil
        for request in requests.values {
            request.deadline.cancel()
            let error = request.sendStarted && !request.readOnly
                ? DirectHermesError.disconnected(outcomeUnknown: true) : reason
            request.continuation.resume(throwing: error)
        }
        if shouldRecover {
            startAutomaticRecovery(after: reason)
        } else if notify, hadConnection {
            onDisconnect?(reason)
        }
    }
}

/// How a host connection is kept awake and checked.
enum DirectHermesKeepalive {
    enum Outcome: Equatable { case alive, unsupported, dead }

    /// Hermes' own heartbeat pace when it asks; a little slower otherwise. Both stay well
    /// under the idle limits of proxies and phone networks.
    static func interval(heartbeatAdvertised: Bool) -> Duration {
        heartbeatAdvertised ? .seconds(15) : .seconds(20)
    }

    static let pingTimeoutNanoseconds: UInt64 = 15_000_000_000
    /// A quick check: a live connection answers a ping in well under a second.
    static let livenessTimeout: Duration = .seconds(4)
    static var livenessTimeoutNanoseconds: UInt64 { UInt64(livenessTimeout / .milliseconds(1)) * 1_000_000 }

    /// Any answer, even "no such method", proves the connection works.
    static func outcome(of error: (any Error)?) -> Outcome {
        guard let error else { return .alive }
        if case DirectHermesError.rpcRejected = error { return .unsupported }
        return .dead
    }
}
