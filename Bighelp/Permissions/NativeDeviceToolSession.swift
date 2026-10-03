import Foundation

/// The phone lease belongs to the foreground workspace, not the visibility of
/// the navigation root. Retire one lease before opening its replacement.
@MainActor
final class NativeDeviceToolLifetime {
    private var signature: String?
    private var task: Task<Void, Never>?

    func update(_ signature: String, operation: @escaping @MainActor () async -> Void) {
        guard self.signature != signature else { return }
        self.signature = signature
        let previous = task
        previous?.cancel()
        task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func stop() {
        signature = nil
        task?.cancel()
        // Retain the cancelled task until its next replacement can await the
        // authenticated close, preventing overlapping phone registrations.
    }

    deinit { task?.cancel() }
}

/// A foreground phone channel mounted on the selected Hermes plugin. The
/// native session remains Hermes-owned; this channel only handles iOS tools.
@MainActor
final class NativeDeviceToolSession {
    typealias Handler = @MainActor (DeviceToolRequest, DeviceToolScope, @escaping @MainActor () -> Bool) async -> DeviceToolResult
    private let http: any DirectHermesNativeHTTP
    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private let scope: DeviceToolScope
    private let agentID: String
    private let sessionID: String
    private var enabled: Set<DeviceToolCapability>
    /// Tools turned on here that this host's plugin is too old to offer.
    private(set) var needsNewerPlugin: Set<DeviceToolCapability> = []
    private let isAvailable: @MainActor () -> Bool
    private let handle: Handler
    private let closeCleanupFactory: (@MainActor (String) -> (@MainActor () async -> Void)?)?
    private var closeCleanup: (@MainActor () async -> Void)?
    private var connectionAttempted = false
    private let channelID = UUID().uuidString.lowercased()
    private var context: DirectHermesNativeContext?
    private var cursor = 0
    private var connected = false
    private var consumed = false

    init(http: any DirectHermesNativeHTTP, owner: WorkspaceOwner,
         currentOwner: @escaping @MainActor () -> WorkspaceOwner?, scope: DeviceToolScope,
         agentID: String, sessionID: String, enabled: Set<DeviceToolCapability>,
         isAvailable: @escaping @MainActor () -> Bool,
         closeCleanupFactory: (@MainActor (String) -> (@MainActor () async -> Void)?)? = nil,
         handle: @escaping Handler) {
        self.http = http; self.owner = owner; self.currentOwner = currentOwner
        self.scope = scope; self.agentID = agentID; self.sessionID = sessionID
        self.enabled = enabled; self.isAvailable = isAvailable; self.handle = handle
        self.closeCleanupFactory = closeCleanupFactory
    }

    func connect() async throws {
        try check()
        guard !consumed, !enabled.isEmpty else { throw WorkspaceClientError.invalidRequest }
        consumed = true
        let plugin = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: currentOwner)
        let context = try await plugin.loadContext()
        try check()
        guard context.features.contains("native-device-tools-v1") else {
            throw WorkspaceClientError.unavailable(.pluginRequired)
        }
        // An older plugin refuses the whole channel over a tool name it doesn't know.
        let offered = enabled.filter { $0.pluginFeature.map(context.features.contains) ?? true }
        needsNewerPlugin = enabled.subtracting(offered)
        guard !offered.isEmpty else { throw WorkspaceClientError.unavailable(.pluginRequired) }
        enabled = offered
        self.context = context
        closeCleanup = closeCleanupFactory?(channelID)
        if closeCleanup == nil, let direct = http as? DirectHermesClient,
           direct.isConnected, direct.savedConnection.workspaceAuthority == owner.authority,
           direct.savedConnection.endpoint == direct.endpoint,
           let cleanup = DirectHermesDeviceToolCloseCleanup(direct: direct, etag: context.etag, channelID: channelID) {
            closeCleanup = { await cleanup.close() }
        }
        connectionAttempted = true
        let result = try await request("connect", ["channelId": .string(channelID),
            "deviceId": .string(scope.deviceID), "hostId": .string(scope.hostID),
            "authorizationEpoch": .integer(scope.authorizationEpoch), "agentId": .string(agentID),
            "sessionId": .string(sessionID), "enabled": .array(enabled.map(\.rawValue).sorted().map(BighelpJSONValue.string))])
        guard result["channelId"] == .string(channelID), result["connected"] == .boolean(true) else {
            throw WorkspaceClientError.invalidResponse
        }
        connected = true
    }

    func pollOnce() async throws {
        try check()
        guard connected else { throw WorkspaceClientError.transportUnavailable }
        let response = try await request("poll", ["channelId": .string(channelID), "after": .integer(cursor)])
        guard response["channelId"] == .string(channelID), let next = response["next"]?.integer,
              let rows = response["requests"]?.array, rows.count <= 8, next >= cursor else {
            throw WorkspaceClientError.invalidResponse
        }
        // Validate the complete batch before allowing any iOS execution.
        var expected = cursor
        var requestIDs: Set<String> = []
        let now = Int(Date().timeIntervalSince1970)
        var requests: [(Int, DeviceToolRequest)] = []
        for row in rows {
            guard let sequence = row.object?["sequence"]?.integer,
                  expected < Int.max, sequence == expected + 1,
                  let raw = row.object?["request"] else { throw WorkspaceClientError.invalidResponse }
            let data = try JSONEncoder().encode(raw)
            guard data.count <= 20_480 else { throw WorkspaceClientError.capacityExceeded }
            let value = try JSONDecoder().decode(DeviceToolRequest.self, from: data)
            guard value.version == 1, value.type == "device.tool.request",
                  value.sentAt > 0, value.sentAt <= now + 5,
                  value.expiresAt > now, value.expiresAt > value.sentAt,
                  value.expiresAt - value.sentAt <= 120,
                  !value.requestId.isEmpty, requestIDs.insert(value.requestId).inserted,
                  value.scope == scope, value.sessionId == sessionID, value.agentId == agentID,
                  let capability = value.operation.split(separator: ".").first.flatMap({ DeviceToolCapability(rawValue: String($0)) }),
                  enabled.contains(capability) else { throw WorkspaceClientError.invalidResponse }
            requests.append((sequence, value)); expected = sequence
        }
        guard next == expected else { throw WorkspaceClientError.invalidResponse }
        for (sequence, value) in requests {
            try check()
            guard value.expiresAt > Int(Date().timeIntervalSince1970) else { throw WorkspaceClientError.invalidResponse }
            let result = await handle(value, scope, { [self] in owns() })
            try check()
            guard result.version == 1, result.type == "device.tool.result",
                  result.requestId == value.requestId, result.deviceId == value.deviceId,
                  result.hostId == value.hostId, result.authorizationEpoch == value.authorizationEpoch,
                  result.sessionId == value.sessionId, result.agentId == value.agentId,
                  result.turnId == value.turnId, result.operation == value.operation else {
                throw WorkspaceClientError.invalidResponse
            }
            // Do not deliver data obtained before a grant/owner was retired.
            let encoded = try JSONEncoder().encode(result)
            guard encoded.count <= 256_000 else { throw WorkspaceClientError.capacityExceeded }
            let payload = try JSONDecoder().decode(BighelpJSONValue.self, from: encoded)
            let receipt = try await request("result", ["channelId": .string(channelID), "result": payload])
            guard receipt["accepted"] == .boolean(true) else { throw WorkspaceClientError.outcomeUnknown }
            cursor = sequence
        }
    }

    func run(onConnected: @MainActor () -> Void = {}) async throws {
        do {
            try await connect()
            onConnected()
            while owns() {
                try await pollOnce()
                try await Task.sleep(for: .milliseconds(750))
            }
        } catch {
            await close()
            throw error
        }
        await close()
    }

    func close() async {
        guard connectionAttempted else { return }
        connectionAttempted = false
        connected = false
        if let cleanup = closeCleanup {
            closeCleanup = nil
            // An independent cleanup task survives the cancelled foreground
            // task. Its immutable authority can only close this one channel.
            await Task { @MainActor in await cleanup() }.value
            return
        }
        guard currentOwner() == owner else { return }
        _ = try? await request("close", ["channelId": .string(channelID)], closing: true)
    }

    private func request(_ action: String, _ payload: [String: BighelpJSONValue], closing: Bool = false) async throws -> [String: BighelpJSONValue] {
        if !closing { try check() }
        guard currentOwner() == owner, let context else { throw WorkspaceClientError.ownerChanged }
        let guardValue = try DirectHermesNativeRequestGuard(etag: context.etag)
        let response = try await http.nativeResponse(.init(path: "/api/plugins/loopdy/native/device-tools/" + action,
            method: .post, body: payload, maximumResponseBytes: 262_144), requestGuard: guardValue)
        if !closing { try check() }
        guard currentOwner() == owner else { throw WorkspaceClientError.ownerChanged }
        guard response.body.count <= 262_144,
              DirectHermesNativeRequestGuard.contextTag(response.http.value(forHTTPHeaderField: "ETag")) == guardValue.etag,
              response.http.value(forHTTPHeaderField: "X-Loopdy-Request-ID") == guardValue.requestIDHeader else {
            throw WorkspaceClientError.invalidResponse
        }
        guard response.http.statusCode == 200 else {
            throw WorkspaceClientError.rejected(code: nil)
        }
        return try response.object()
    }
    private func owns() -> Bool { currentOwner() == owner && isAvailable() && !Task.isCancelled }
    private func check() throws { guard owns() else { throw WorkspaceClientError.ownerChanged } }
}

/// One fixed-route cleanup prepared before allocating a phone channel. It
/// cannot refresh credentials, reconnect, or access a newly selected host.
@MainActor
private final class DirectHermesDeviceToolCloseCleanup {
    private let endpoint: DirectHermesEndpoint
    private let bearer: String?
    private let sessionToken: String?
    private let guardValue: DirectHermesNativeRequestGuard
    private let channelID: String
    private var consumed = false

    init?(direct: DirectHermesClient, etag: String, channelID: String) {
        guard UUID(uuidString: channelID) != nil,
              let guardValue = try? DirectHermesNativeRequestGuard(etag: etag) else { return nil }
        let saved = direct.savedConnection
        switch saved.authentication {
        case .bearer(let token, _, _):
            guard (try? DirectHermesSecretValidation.validate(token)) != nil else { return nil }
            bearer = token; sessionToken = nil
        case .dashboardSession(let token, _), .legacyLoopbackToken(let token):
            guard (try? DirectHermesSecretValidation.validate(token)) != nil else { return nil }
            bearer = nil; sessionToken = token
        }
        endpoint = direct.endpoint
        self.guardValue = guardValue; self.channelID = channelID
    }

    func close() async {
        guard !consumed else { return }
        consumed = true
        let http = DirectHermesHTTP(endpoint: endpoint)
        defer { http.invalidate() }
        _ = try? await http.send(route: "/api/plugins/loopdy/native/device-tools/close", method: "POST",
            body: ["channelId": .string(channelID)], bearer: bearer, legacyToken: sessionToken,
            maximumResponseBytes: 16_384, nativeGuard: guardValue)
    }
}
