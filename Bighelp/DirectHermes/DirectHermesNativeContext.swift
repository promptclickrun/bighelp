import Foundation

struct DirectHermesNativeRequestGuard: Equatable, Sendable {
    let etag: String
    let requestID: UUID
    var requestIDHeader: String { requestID.uuidString.lowercased() }

    init(etag: String, requestID: UUID = UUID()) throws {
        guard Self.validETag(etag) else { throw WorkspaceClientError.invalidResponse }
        self.etag = etag
        self.requestID = requestID
    }

    /// The plugin context a reply's ETag names. A proxy that compresses the
    /// reply marks it weak (`W/`; a Cloudflare Tunnel does for every iPhone, which always
    /// accepts compression); the tag inside is the same context.
    static func contextTag(_ header: String?) -> String? {
        guard var value = header else { return nil }
        if value.hasPrefix("W/") { value.removeFirst(2) }
        return validETag(value) ? value : nil
    }

    static func validETag(_ value: String) -> Bool {
        guard value.utf8.count == 73, value.hasPrefix("\"sha256:"), value.hasSuffix("\"") else { return false }
        return value.dropFirst(8).dropLast().utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

struct DirectHermesNativeContext: Equatable, Sendable {
    let owner: WorkspaceOwner
    let pluginVersion: String
    let runtimeID: String
    let servingProfileID: String?
    let providerID: String?
    let userID: String?
    let displayName: String?
    let features: Set<String>
    let etag: String

    init(response: DirectHermesHTTP.Response, owner: WorkspaceOwner) throws {
        guard response.http.statusCode == 200, response.body.count <= 16_384,
              owner.authority.kind == .direct,
              let etag = DirectHermesNativeRequestGuard.contextTag(response.http.value(forHTTPHeaderField: "ETag")),
              response.http.value(forHTTPHeaderField: "Cache-Control")?.lowercased().contains("no-store") == true else {
            throw WorkspaceClientError.invalidResponse
        }
        let value = try response.object()
        guard value["schemaVersion"]?.integer == 1,
              let version = value["pluginVersion"]?.string,
              let runtime = value["runtimeId"]?.string,
              let values = value["features"]?.array, values.count <= 64 else {
            throw WorkspaceClientError.invalidResponse
        }
        let principal: [String: BighelpJSONValue]
        let provider: String?
        let user: String?
        if owner.authority.providerID == nil {
            guard owner.authority.principalID == "dashboard-session", value["principal"] == .null else {
                throw WorkspaceClientError.invalidResponse
            }
            principal = [:]; provider = nil; user = nil
        } else {
            guard let identity = value["principal"]?.object,
                  let p = identity["provider"]?.string, let u = identity["userId"]?.string,
                  DirectHermesIdentity.matches(p, owner.authority.providerID),
                  DirectHermesIdentity.matches(u, owner.authority.principalID) else {
                throw WorkspaceClientError.invalidResponse
            }
            principal = identity; provider = p; user = u
        }
        try WorkspaceAuthority.validateIdentifier(version, maximumBytes: 128)
        try WorkspaceAuthority.validateIdentifier(runtime, maximumBytes: 256)
        let features = try Set(values.map { value in
            guard let text = value.string else { throw WorkspaceClientError.invalidResponse }
            try WorkspaceAuthority.validateIdentifier(text, maximumBytes: 128)
            return text
        })
        guard features.contains("native-context-v1"), features.count == values.count else {
            throw WorkspaceClientError.invalidResponse
        }
        let profile: String?
        switch value["servingProfileId"] {
        case .null?: profile = nil
        case .string(let value)?:
            try WorkspaceAuthority.validateIdentifier(value, maximumBytes: 128)
            guard features.contains("serving-profile-v1") else { throw WorkspaceClientError.invalidResponse }
            profile = value
        default: throw WorkspaceClientError.invalidResponse
        }
        let display: String?
        switch principal["displayName"] {
        case nil, .null?: display = nil
        case .string(let value)?:
            guard value.utf8.count <= 200 else { throw WorkspaceClientError.invalidResponse }
            display = value
        default: throw WorkspaceClientError.invalidResponse
        }
        self.owner = owner
        pluginVersion = version
        runtimeID = runtime
        servingProfileID = profile
        providerID = provider
        userID = user
        displayName = display
        self.features = features
        self.etag = etag
    }

    var projection: [String: BighelpJSONValue] {
        [
            "schemaVersion": .integer(1), "pluginVersion": .string(pluginVersion),
            "runtimeId": .string(runtimeID), "servingProfileId": servingProfileID.map(BighelpJSONValue.string) ?? .null,
            "principal": providerID.map { provider in .object([
                "provider": .string(provider), "userId": userID.map(BighelpJSONValue.string) ?? .null,
                "displayName": displayName.map(BighelpJSONValue.string) ?? .null,
            ]) } ?? .null,
            "features": .array(features.sorted().map(BighelpJSONValue.string)),
        ]
    }
}

@MainActor
protocol DirectHermesNativeHTTP: AnyObject {
    func nativeResponse(_ request: DirectHermesHTTPRequest,
                        requestGuard: DirectHermesNativeRequestGuard?) async throws -> DirectHermesHTTP.Response
}

@MainActor
final class DirectHermesNativePluginClient {
    private let http: any DirectHermesNativeHTTP
    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private(set) var context: DirectHermesNativeContext?

    init(http: any DirectHermesNativeHTTP, owner: WorkspaceOwner,
         currentOwner: @escaping @MainActor () -> WorkspaceOwner?) {
        self.http = http
        self.owner = owner
        self.currentOwner = currentOwner
    }

    /// Snapshot the active Direct authority while the workspace still owns it.
    /// The resulting handle is restricted to one close request and does not use
    /// this client's mutable authenticator after the owner is retired.
    func makeNativeVoiceCloseCleanup(agentID: String, sessionID: String,
                                     voiceID: String) -> DirectHermesVoiceCloseCleanup? {
        guard currentOwner() == owner,
              let context, context.owner == owner,
              let direct = http as? DirectHermesClient, direct.isConnected else { return nil }
        let saved = direct.savedConnection
        guard saved.endpoint == direct.endpoint, saved.workspaceAuthority == owner.authority else { return nil }
        return DirectHermesVoiceCloseCleanup(
            endpoint: direct.endpoint,
            authentication: saved.authentication,
            owner: owner,
            nativeContextETag: context.etag,
            agentID: agentID,
            sessionID: sessionID,
            voiceID: voiceID
        )
    }

    func loadContext(force: Bool = false) async throws -> DirectHermesNativeContext {
        try check()
        if !force, let context { return context }
        let response = try await http.nativeResponse(
            .init(path: "/api/plugins/loopdy/native/context", method: .get, maximumResponseBytes: 16_384),
            requestGuard: nil
        )
        try check()
        guard response.http.statusCode == 200 else {
            context = nil
            throw responseError(response, mutation: false)
        }
        let value = try DirectHermesNativeContext(response: response, owner: owner)
        context = value
        return value
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        try check()
        if operation == .nativeContext {
            guard payload.isEmpty else { throw WorkspaceClientError.invalidRequest }
            return try await loadContext(force: true).projection
        }
        let route = try Self.route(operation)
        let requestLimit = route.feature == "native-card-templates-v1" ? 196_608 : 1_048_576
        try DirectHermesWire.validateValueSize(.object(payload), limit: requestLimit)
        guard try JSONEncoder().encode(BighelpJSONValue.object(payload)).count <= requestLimit else {
            throw WorkspaceClientError.capacityExceeded
        }
        let context = try await loadContext()
        guard context.features.contains(route.feature) else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        let requestGuard = try DirectHermesNativeRequestGuard(etag: context.etag)
        let request = DirectHermesHTTPRequest(
            path: "/api/plugins/loopdy/native/" + route.path, method: .post, body: payload,
            maximumResponseBytes: route.maximumResponseBytes, timeout: route.timeout
        )
        let response: DirectHermesHTTP.Response
        do {
            try check()
            response = try await http.nativeResponse(request, requestGuard: requestGuard)
            try check()
        } catch {
            try check()
            if route.isMutation { throw WorkspaceClientError.outcomeUnknown }
            throw error
        }
        let echoedID = response.http.value(forHTTPHeaderField: "X-Loopdy-Request-ID")
        if let echoedID, echoedID != requestGuard.requestIDHeader {
            throw route.isMutation ? WorkspaceClientError.outcomeUnknown : WorkspaceClientError.invalidResponse
        }
        guard (200...299).contains(response.http.statusCode) else {
            if [401, 403, 412, 428].contains(response.http.statusCode) { self.context = nil }
            throw responseError(response, mutation: route.isMutation)
        }
        guard echoedID == requestGuard.requestIDHeader,
              DirectHermesNativeRequestGuard.contextTag(response.http.value(forHTTPHeaderField: "ETag")) == requestGuard.etag else {
            self.context = nil
            throw route.isMutation ? WorkspaceClientError.outcomeUnknown : WorkspaceClientError.invalidResponse
        }
        do { return try response.object() }
        catch { throw route.isMutation ? WorkspaceClientError.outcomeUnknown : WorkspaceClientError.invalidResponse }
    }

    /// Plugins from 2.16.1 can restart the Hermes process that serves them.
    static let hostRestartFeature = "native-host-restart-v1"

    /// Asks the plugin to restart the Hermes process serving this connection in
    /// place, so an updated plugin loads. The connection drops right after.
    func restartHost() async throws {
        let context = try await loadContext(force: true)
        guard context.features.contains(Self.hostRestartFeature) else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        let requestGuard = try DirectHermesNativeRequestGuard(etag: context.etag)
        let response = try await http.nativeResponse(.init(
            path: "/api/plugins/loopdy/native/host/restart", method: .post,
            body: ["confirm": .boolean(true)], maximumResponseBytes: 16_384
        ), requestGuard: requestGuard)
        try check()
        guard (200...299).contains(response.http.statusCode),
              try response.object()["restarting"]?.boolean == true else {
            throw responseError(response, mutation: true)
        }
    }

    static func supports(_ operation: WorkspaceOperation) -> Bool {
        operation == .nativeContext || (try? route(operation)) != nil
    }

    private struct Route {
        let path: String
        let feature: String
        let isMutation: Bool
        var maximumResponseBytes = DirectHermesWire.maximumMessageBytes
        var timeout: TimeInterval = 20
    }

    private static func route(_ operation: WorkspaceOperation) throws -> Route {
        switch operation {
        case .nativeVoiceStatus, .nativeVoiceOffer, .nativeVoicePoll, .nativeVoiceResult, .nativeVoiceClose:
            return Route(path: "voice/" + operation.rawValue.replacingOccurrences(of: "native.voice.", with: ""),
                         feature: "native-voice-v1", isMutation: ![.nativeVoiceStatus, .nativeVoicePoll].contains(operation),
                         maximumResponseBytes: 196_608)
        case .projectsGitCapabilities:
            return Route(path: "projects/git/capabilities", feature: "native-project-git-read-v1",
                         isMutation: false, maximumResponseBytes: 196_608)
        case .projectsGitStatus:
            return Route(path: "projects/git/status", feature: "native-project-git-read-v1",
                         isMutation: false, maximumResponseBytes: 196_608)
        case .projectsGitDiff:
            return Route(path: "projects/git/diff", feature: "native-project-git-read-v1",
                         isMutation: false, maximumResponseBytes: 196_608)
        case .cardsTemplatesList:
            return Route(path: "cards/templates/list", feature: "native-card-templates-v1", isMutation: false, maximumResponseBytes: 196_608)
        case .cardsTemplatesInstall:
            return Route(path: "cards/templates/install", feature: "native-card-templates-v1", isMutation: true, maximumResponseBytes: 196_608)
        case .cardsTemplatesRemove:
            return Route(path: "cards/templates/remove", feature: "native-card-templates-v1", isMutation: true, maximumResponseBytes: 196_608)
        case .wikiRoots: return Route(path: "wiki/roots", feature: "native-wiki-v1", isMutation: false)
        case .wikiConnect: return Route(path: "wiki/connect", feature: "native-wiki-v1", isMutation: true)
        case .wikiResolve: return Route(path: "wiki/resolve", feature: "native-wiki-v1", isMutation: false)
        case .wikiList: return Route(path: "wiki/list", feature: "native-wiki-v1", isMutation: false)
        case .wikiRead: return Route(path: "wiki/read", feature: "native-wiki-v1", isMutation: false)
        case .wikiSearch: return Route(path: "wiki/search", feature: "native-wiki-v1", isMutation: false)
        case .wikiImage: return Route(path: "wiki/image", feature: "native-wiki-v1", isMutation: false)
        case .wikiSaveBegin: return Route(path: "wiki/save/begin", feature: "native-wiki-v1", isMutation: true)
        case .wikiSaveChunk: return Route(path: "wiki/save/chunk", feature: "native-wiki-v1", isMutation: true)
        case .wikiSaveCommit: return Route(path: "wiki/save/commit", feature: "native-wiki-v1", isMutation: true)
        case .wikiSaveStatus: return Route(path: "wiki/save/status", feature: "native-wiki-v1", isMutation: false)
        case .wikiDisconnect: return Route(path: "wiki/disconnect", feature: "native-wiki-disconnect-v1", isMutation: true)
        // A big file takes the host a while to copy in, and a 4 MB piece takes
        // a slow phone link longer than an ordinary request.
        case .attachmentsResolve:
            return Route(path: "attachments/resolve", feature: "native-agent-attachments-v1",
                         isMutation: false, maximumResponseBytes: 1_048_576, timeout: 60)
        case .attachmentsFetch:
            return Route(path: "attachments/fetch", feature: "native-agent-attachments-v1",
                         isMutation: false, maximumResponseBytes: 4 * 1_024 * 1_024 + 65_536, timeout: 60)
        case .groupActivityOpen:
            return Route(path: "groups/activity/open", feature: "native-room-activity-v1", isMutation: true, maximumResponseBytes: 196_608)
        case .groupActivityPoll:
            return Route(path: "groups/activity/poll", feature: "native-room-activity-v1", isMutation: false, maximumResponseBytes: 196_608)
        case .groupActivityClose:
            return Route(path: "groups/activity/close", feature: "native-room-activity-v1", isMutation: true, maximumResponseBytes: 196_608)
        case .attachmentsBoard:
            // The host copies the file in before it answers, as for a chat file.
            return Route(path: "attachments/board", feature: "native-agent-board-files-v1",
                         isMutation: false, maximumResponseBytes: 16_384, timeout: 60)
        case .attachmentsRecent:
            return Route(path: "attachments/recent", feature: "native-agent-media-v1", isMutation: false,
                         maximumResponseBytes: 196_608)
        case .boardList:
            return Route(path: "board/list", feature: "native-agent-board-v1", isMutation: false,
                         maximumResponseBytes: 2 * 1_024 * 1_024)
        case .boardUpdate:
            return Route(path: "board/update", feature: "native-agent-board-v1", isMutation: true,
                         maximumResponseBytes: 196_608)
        case .boardMedia:
            return Route(path: "board/media", feature: "native-agent-board-v1", isMutation: false,
                         maximumResponseBytes: 12 * 1_024 * 1_024)
        case .boardActivity:
            return Route(path: "board/activity", feature: "native-agent-board-v1", isMutation: false,
                         maximumResponseBytes: 2 * 1_024 * 1_024)
        case .boardApprovals:
            return Route(path: "board/approvals", feature: "native-agent-board-v1", isMutation: false,
                         maximumResponseBytes: 2 * 1_024 * 1_024)
        case .usageList:
            // The host asks every provider before answering: finding them, then up to 20 seconds.
            return Route(path: "usage/list", feature: "native-provider-usage-v1", isMutation: false,
                         maximumResponseBytes: 196_608, timeout: 60)
        case .usageActivity:
            // Reads the agent's own sessions; a 90-day range of a busy agent is a few thousand rows.
            return Route(path: "usage/activity", feature: "native-usage-activity-v1", isMutation: false,
                         maximumResponseBytes: 1_048_576, timeout: 30)
        case .peopleSpeaking:
            // Sent before each message; a slow host never holds a message for long.
            return Route(path: "people/speaking", feature: "native-people-v1", isMutation: true,
                         maximumResponseBytes: 16_384, timeout: 5)
        // The host holds a listen up to 25 seconds; the rest is the trip there and back.
        case .liveAlertsListen:
            return Route(path: "alerts/listen", feature: BighelpLiveAlertListener.feature, isMutation: false,
                         maximumResponseBytes: 1_048_576, timeout: 40)
        case .liveAlertsAck:
            return Route(path: "alerts/ack", feature: BighelpLiveAlertListener.feature, isMutation: false,
                         maximumResponseBytes: 16_384, timeout: 5)
        case .liveAlertsStop:
            return Route(path: "alerts/stop", feature: BighelpLiveAlertListener.feature, isMutation: false,
                         maximumResponseBytes: 16_384, timeout: 5)
        case .providerSignInList:
            // Claude Code answers its own status check on the host (a few seconds at most).
            return Route(path: "provider-sign-in/list", feature: "native-provider-sign-in-v1", isMutation: false,
                         maximumResponseBytes: 65_536, timeout: 30)
        case .providerSignInStart:
            // The host waits up to 12 seconds for the provider's tool to show its link.
            return Route(path: "provider-sign-in/start", feature: "native-provider-sign-in-v1", isMutation: true,
                         maximumResponseBytes: 16_384, timeout: 30)
        case .providerSignInStatus:
            return Route(path: "provider-sign-in/status", feature: "native-provider-sign-in-v1", isMutation: false,
                         maximumResponseBytes: 16_384)
        case .providerSignInSubmit:
            return Route(path: "provider-sign-in/submit", feature: "native-provider-sign-in-v1", isMutation: true,
                         maximumResponseBytes: 16_384)
        case .providerSignInCancel:
            return Route(path: "provider-sign-in/cancel", feature: "native-provider-sign-in-v1", isMutation: true,
                         maximumResponseBytes: 16_384)
        case .boardIdentity:
            return Route(path: "board/identity", feature: "native-agent-board-v1", isMutation: false,
                         maximumResponseBytes: 2 * 1_024 * 1_024)
        case .boardRead:
            return Route(path: "board/read", feature: "native-agent-board-feedback-v1", isMutation: true,
                         maximumResponseBytes: 16_384)
        case .boardPromote:
            return Route(path: "board/promote", feature: "native-agent-board-feedback-v1", isMutation: true,
                         maximumResponseBytes: 196_608)
        case .boardAccept:
            return Route(path: "board/accept", feature: "native-agent-board-answers-v1", isMutation: true,
                         maximumResponseBytes: 196_608)
        default: throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
    }

    private func check() throws {
        try Task.checkCancellation()
        guard currentOwner() == owner, owner.authority.kind == .direct else { throw WorkspaceClientError.ownerChanged }
    }

    private func responseError(_ response: DirectHermesHTTP.Response, mutation: Bool) -> WorkspaceClientError {
        switch response.http.statusCode {
        case 401, 403: return .authenticationRequired
        case 412: return .conflict
        case 413: return .capacityExceeded
        case 428: return .unavailable(.unsupportedOperation)
        case 500...599: return mutation ? .outcomeUnknown : .transportUnavailable
        default: break
        }
        let document = try? response.object()
        let code = document?["error"]?.object?["code"]?.string
        if let code, !code.isEmpty, code.utf8.count <= 128,
           code.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
               || (48...57).contains($0) || [45, 46, 95].contains($0) }) {
            return .rejected(code: code)
        }
        return response.http.statusCode == 404 ? .unavailable(.pluginRequired) : .invalidResponse
    }
}
