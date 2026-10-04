import Foundation

struct DirectHermesHTTPRequest: Equatable, Sendable {
    enum Method: String, Sendable {
        case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
    }
    let path: String
    let method: Method
    var query: [URLQueryItem] = []
    var body: [String: BighelpJSONValue]?
    var maximumResponseBytes = DirectHermesWire.maximumMessageBytes
    /// Seconds to wait for the host to start answering.
    var timeout: TimeInterval = 20
}

@MainActor
protocol DirectHermesAuthenticatedHTTP: AnyObject {
    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue
}

@MainActor
final class DirectHermesWorkspaceClient: WorkspaceOperationPerforming {
    private let rpc: any DirectHermesRPC
    private let http: any DirectHermesAuthenticatedHTTP
    private let capturedOwner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private(set) var capabilities: WorkspaceCapabilities
    private var nativePlugin: DirectHermesNativePluginClient?
    var nativeContext: DirectHermesNativeContext? { nativePlugin?.context }

    var owner: WorkspaceOwner? { currentOwner() == capturedOwner ? capturedOwner : nil }

    /// Prepares cleanup for one already allocated native voice call while this
    /// client still references the original Direct connection.
    func makeNativeVoiceCloseCleanup(agentID: String, sessionID: String,
                                     voiceID: String) -> (@MainActor () async -> Void)? {
        guard let nativePlugin,
              let cleanup = nativePlugin.makeNativeVoiceCloseCleanup(
                agentID: agentID, sessionID: sessionID, voiceID: voiceID
              ) else { return nil }
        return { await cleanup.close() }
    }

    init(rpc: any DirectHermesRPC, http: any DirectHermesAuthenticatedHTTP,
         owner: WorkspaceOwner, capabilities: WorkspaceCapabilities,
         currentOwner: @escaping @MainActor () -> WorkspaceOwner?) {
        self.rpc = rpc
        self.http = http
        capturedOwner = owner
        self.capabilities = capabilities.owner == owner ? capabilities : .disconnected
        self.currentOwner = currentOwner
    }

    func installCapabilities(_ value: WorkspaceCapabilities) throws {
        guard owner == capturedOwner, value.owner == capturedOwner else {
            throw WorkspaceClientError.ownerChanged
        }
        capabilities = value
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                 owner expectedOwner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        try check(expectedOwner)
        if DirectHermesNativePluginClient.supports(operation) {
            guard let transport = http as? any DirectHermesNativeHTTP else {
                throw WorkspaceClientError.unavailable(.pluginRequired)
            }
            let plugin = nativePlugin ?? DirectHermesNativePluginClient(
                http: transport, owner: capturedOwner, currentOwner: currentOwner
            )
            nativePlugin = plugin
            let result = try await plugin.perform(operation, payload: payload)
            try check(expectedOwner)
            return result
        }
        let route = try Self.route(operation, payload: payload)
        let result: BighelpJSONValue
        do {
            switch route {
            case .rpc(let method, let params):
                result = try await rpc.request(method, params: params)
            case .http(let request):
                result = try await http.request(request)
            }
            try check(expectedOwner)
        } catch {
            try check(expectedOwner)
            throw Self.workspaceError(error, for: operation)
        }
        if operation == .skillsToolsList, let rows = result.array { return ["skills": .array(rows)] }
        if operation == .toolsetsList, let rows = result.array { return ["toolsets": .array(rows)] }
        if operation == .scheduledTasksList, let rows = result.array { return ["jobs": .array(rows)] }
        guard let object = result.object else { throw WorkspaceClientError.invalidResponse }
        if operation == .sessionsList {
            return try Self.normalizedSessionList(object, payload: payload)
        }
        if operation == .sessionDetail {
            return try Self.normalizedSessionDetail(object, payload: payload)
        }
        if operation == .agentDefaultsGet { return try Self.projectDefaults(object) }
        return object
    }

    private func check(_ expectedOwner: WorkspaceOwner) throws {
        try Task.checkCancellation()
        guard capturedOwner == expectedOwner, owner == capturedOwner else {
            throw WorkspaceClientError.ownerChanged
        }
    }

    /// The stock authenticated endpoint enforces resolved host media roots.
    /// Do not fall back to arbitrary filesystem reads or provider URLs.
    func readGeneratedImage(path: String, owner expectedOwner: WorkspaceOwner) async throws -> BighelpJSONValue {
        try check(expectedOwner)
        guard DirectHermesGeneratedMediaClient.isImagePath(path) else { throw WorkspaceClientError.invalidRequest }
        let result = try await http.request(.init(
            path: "/api/media", method: .get, query: [.init(name: "path", value: path)],
            maximumResponseBytes: DirectHermesHTTP.maximumMediaResponseBytes))
        try check(expectedOwner)
        return result
    }

    /// Stock Hermes's read-only folder listing (it expands "~" and hides
    /// credential folders). Used to browse for a workspace folder.
    func listFolder(path: String, owner expectedOwner: WorkspaceOwner) async throws -> BighelpJSONValue {
        try check(expectedOwner)
        guard !path.isEmpty, path.utf8.count <= 4_096 else { throw WorkspaceClientError.invalidRequest }
        let result = try await http.request(.init(
            path: "/api/fs/list", method: .get, query: [.init(name: "path", value: path)],
            maximumResponseBytes: 4_194_304))
        try check(expectedOwner)
        return result
    }

    /// Explicit file deliveries use the existing stock managed-file policy.
    /// Never retry a refused image or broaden the host's configured root here.
    func readDeliveredFile(path: String, owner expectedOwner: WorkspaceOwner) async throws -> BighelpJSONValue {
        try check(expectedOwner)
        guard DirectHermesGeneratedMediaClient.isDeliveredFilePath(path) else { throw WorkspaceClientError.invalidRequest }
        let result = try await http.request(.init(
            path: "/api/files/read", method: .get, query: [.init(name: "path", value: path)],
            maximumResponseBytes: DirectHermesHTTP.maximumMediaResponseBytes))
        try check(expectedOwner)
        return result
    }

    enum Route: Equatable, Sendable {
        case rpc(String, [String: BighelpJSONValue])
        case http(DirectHermesHTTPRequest)
    }

    static func route(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue]) throws -> Route {
        try DirectHermesWire.validateValueSize(.object(payload),
                                              limit: operation == .profilesSetAsset ? 2_800_000 : 1_048_576)
        switch operation {
        case .hostHealth:
            guard payload.isEmpty else { throw WorkspaceClientError.invalidRequest }
            return .http(.init(path: "/api/health", method: .get, maximumResponseBytes: 16_384))
        case .groupsCapabilities:
            return try rpc(operation, payload, allowed: [])
        case .groupsList:
            return try rpc(operation, payload, allowed: ["limit", "offset", "include_disbanded"])
        case .groupsCreate:
            return try rpc(operation, payload, allowed: ["room_id", "name", "members"],
                           required: ["room_id", "name", "members"])
        case .groupsState:
            return try rpc(operation, payload, allowed: ["room_id", "include_disbanded"], required: ["room_id"])
        case .groupsSend:
            return try rpc(operation, payload, allowed: ["room_id", "event_id", "payload"],
                           required: ["room_id", "event_id", "payload"])
        case .groupsRename:
            return try rpc(operation, payload, allowed: ["room_id", "event_id", "name"],
                           required: ["room_id", "event_id", "name"])
        case .groupsLog:
            return try rpc(operation, payload, allowed: ["room_id", "since_seq", "limit", "include_disbanded"],
                           required: ["room_id"])
        case .groupsStop, .groupsDisband:
            return try rpc(operation, payload, allowed: ["room_id", "cancel_id"], required: ["room_id"])
        case .groupsRetry:
            return try rpc(operation, payload, allowed: ["room_id", "task_id"], required: ["room_id", "task_id"])
        case .groupsApprove:
            return try rpc(operation, payload,
                           allowed: ["room_id", "member_id", "task_id", "execution_generation", "request_id", "choice"],
                           required: ["room_id", "member_id", "task_id", "execution_generation", "request_id", "choice"])
        case .profilesList:
            return try rpc(operation, payload, allowed: ["include_sessions"])
        case .profilesDescribe:
            return try rpc(operation, payload, allowed: ["name"], required: ["name"])
        case .profilesSoulGet, .profilesSoulSet:
            let profile = try pathIdentifier(payload["profile"])
            try fields(payload, allowed: operation == .profilesSoulGet ? ["profile"] : ["profile", "content"],
                       required: operation == .profilesSoulGet ? ["profile"] : ["profile", "content"])
            if operation == .profilesSoulGet {
                return .http(.init(path: "/api/profiles/\(profile)/soul", method: .get))
            }
            guard let content = payload["content"]?.string, content.utf8.count <= 512 * 1_024 else {
                throw WorkspaceClientError.invalidRequest
            }
            return .http(.init(path: "/api/profiles/\(profile)/soul", method: .put,
                               body: ["content": .string(content)]))
        case .profilesGetAsset:
            try fields(payload, allowed: ["name", "asset"], required: ["name", "asset"])
            guard payload["asset"] == .string("avatar") else { throw WorkspaceClientError.invalidRequest }
            return .rpc(operation.rawValue, payload)
        case .profilesSetAsset:
            try fields(payload, allowed: ["name", "asset", "data", "clear"], required: ["name", "asset"])
            guard payload["asset"] == .string("avatar"),
                  (payload["data"]?.string != nil && payload["clear"] == nil)
                    || (payload["data"] == nil && payload["clear"] == .boolean(true)) else {
                throw WorkspaceClientError.invalidRequest
            }
            return .rpc(operation.rawValue, payload)
        case .profilesConfigure:
            return try rpc(operation, payload,
                           allowed: ["name", "description", "soul", "model", "provider", "confirm_expensive_model",
                                     "ui_meta", "ui_meta_expected_revisions"],
                           required: ["name"])
        case .petGallery:
            return try rpc(operation, payload, allowed: ["localOnly"])
        case .petThumb:
            return try rpc(operation, payload, allowed: ["slug", "url"], required: ["slug"])
        case .profilesCreate, .profilesClone:
            try fields(payload, allowed: ["name", "clone_from", "clone_all", "no_alias", "mirror_credentials", "description", "no_skills"],
                       required: ["name"])
            return .rpc("profiles.create", payload)
        case .sessionCreate:
            return try rpc(operation, payload,
                           allowed: ["profile", "source", "close_on_disconnect", "cwd", "cwd_explicit",
                                     "omit_messages", "title", "hidden", "follow_profile_config"],
                           required: ["profile"])
        case .nativeSessionList:
            return try rpc(operation, payload,
                           allowed: ["profile", "title", "include_hidden", "limit", "offset"],
                           required: ["profile"])
        case .nativeSessionActiveList:
            return try rpc(operation, payload,
                           allowed: ["profile", "current_session_id"])
        case .sessionTitle:
            return try rpc(operation, payload, allowed: ["session_id", "title"], required: ["session_id", "title"])
        case .sessionResume:
            return try rpc(operation, payload,
                           allowed: ["profile", "session_id", "defer_history", "omit_messages", "close_on_disconnect",
                                     "source"],
                           required: ["profile", "session_id"])
        case .sessionActivate:
            return try rpc(operation, payload, allowed: ["session_id", "profile", "omit_messages"], required: ["session_id"])
        case .sessionEvents:
            return try rpc(operation, payload, allowed: ["session_id", "last_seen"], required: ["session_id", "last_seen"])
        case .sessionBranch:
            return try rpc(operation, payload, allowed: ["session_id", "count", "name"], required: ["session_id"])
        case .promptSubmit:
            return try rpc(operation, payload, allowed: ["session_id", "profile", "text", "queued", "images"],
                           required: ["session_id", "text"])
        case .sessionInterrupt:
            return try rpc(operation, payload, allowed: ["session_id", "profile"], required: ["session_id"])
        case .sessionSteer, .sessionQueue:
            return try rpc(operation, payload, allowed: ["session_id", "profile", "text"], required: ["session_id", "text"])
        case .slashExecute:
            return try rpc(operation, payload, allowed: ["session_id", "profile", "command"], required: ["session_id", "command"])
        case .commandsCatalog:
            return try rpc(operation, payload, allowed: ["session_id", "profile"])
        case .modelOptions:
            return try rpc(operation, payload,
                           allowed: ["profile", "session_id", "explicit_only", "include_unconfigured", "refresh"])
        case .configGet, .configSet:
            try fields(payload, allowed: ["profile", "session_id", "key", "value", "scope", "confirm_expensive_model"],
                       required: operation == .configGet ? ["key"] : ["key", "value"])
            // display.message_reactions mirrors the app's reactions switch onto the
            // host, as Hermes Desktop does: the agent's react tool and reaction notes.
            if payload["key"]?.string == "display.message_reactions", payload["session_id"] == nil,
               payload["scope"] == nil {
                return .rpc(operation.rawValue, payload)
            }
            // The agent's working folder, picked in Files when Hermes can't find its workspace: a full
            // path on the host, never a session's.
            if operation == .configSet, payload["key"]?.string == "terminal.cwd", payload["session_id"] == nil,
               payload["scope"] == nil, let path = payload["value"]?.string, path.hasPrefix("/"),
               path.utf8.count <= 4_096, !path.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                return .rpc(operation.rawValue, payload)
            }
            guard let key = payload["key"]?.string, ["reasoning", "model"].contains(key),
                  payload["scope"] == nil || payload["scope"] == .string("global")
                    || (payload["scope"] == .string("session") && payload["session_id"]?.string != nil),
                  operation != .configSet || key != "model" || payload["session_id"]?.string != nil else {
                throw WorkspaceClientError.invalidRequest
            }
            return .rpc(operation.rawValue, payload)
        case .agentDefaultsGet:
            try fields(payload, allowed: ["profile"], required: ["profile"])
            var query = payload
            query["include_defaults"] = .boolean(false)
            return try get("/api/config", query, allowed: ["profile", "include_defaults"])
        case .agentDefaultsSet:
            try fields(payload, allowed: ["profile", "config"], required: ["profile", "config"])
            guard let config = payload["config"]?.object else { throw WorkspaceClientError.invalidRequest }
            try fields(config, allowed: ["agent", "delegation", "cron"])
            for (namespace, value) in config {
                guard let section = value.object else { throw WorkspaceClientError.invalidRequest }
                let allowed: Set<String>
                switch namespace {
                case "agent":
                    allowed = ["reasoning_effort"]
                    guard section["reasoning_effort"] == .string("") else {
                        throw WorkspaceClientError.invalidRequest
                    }
                case "delegation": allowed = ["provider", "model", "reasoning_effort"]
                default: allowed = ["model", "model_provider"]
                }
                try fields(section, allowed: allowed)
                guard section.values.allSatisfy({ $0.string.map { $0.utf8.count <= 512 } == true }) else {
                    throw WorkspaceClientError.invalidRequest
                }
            }
            return .http(.init(path: "/api/config", method: .put, body: payload))
        case .projectsList:
            return try rpc(operation, payload, allowed: ["profile"])
        case .projectsGet:
            return try rpc(operation, payload, allowed: ["profile", "id"], required: ["id"])
        case .projectsForCwd:
            return try rpc(operation, payload, allowed: ["profile", "cwd"], required: ["profile", "cwd"])
        case .projectsCreate:
            return try rpc(operation, payload,
                           allowed: ["profile", "name", "folders", "slug", "primary_path", "description", "icon", "color", "board_slug", "use"],
                           required: ["name"])
        case .projectsUpdate:
            return try rpc(operation, payload, allowed: ["profile", "id", "name", "description", "icon", "color", "board_slug"],
                           required: ["id"])
        case .projectsArchive:
            return try rpc(operation, payload, allowed: ["profile", "id", "restore"], required: ["id"])
        case .projectsSetActive:
            return try rpc(operation, payload, allowed: ["profile", "id"], required: ["id"])
        case .sessionWorkspaceMove:
            return try rpc(operation, payload, allowed: ["profile", "session_key", "cwd"], required: ["session_key", "cwd"])
        case .subagentsList:
            return try rpc(operation, payload, allowed: ["session_id"], required: ["session_id"])
        case .subagentTail, .subagentInterrupt:
            return try rpc(operation, payload, allowed: ["session_id", "subagent_id"], required: ["session_id", "subagent_id"])
        case .subagentSteer:
            return try rpc(operation, payload, allowed: ["session_id", "subagent_id", "text"],
                           required: ["session_id", "subagent_id", "text"])
        case .approvalPending:
            return try rpc(operation, payload, allowed: ["session_id", "profile"], required: ["session_id"])
        case .approvalRespond:
            return try rpc(operation, payload, allowed: ["session_id", "profile", "request_id", "choice", "all"],
                           required: ["session_id", "request_id", "choice"])
        case .clarificationRespond:
            return try rpc(operation, payload, allowed: ["session_id", "profile", "request_id", "question_id", "answer"],
                           required: ["session_id", "request_id", "answer"])
        case .skillsToolsList:
            return try get("/api/skills", payload, allowed: ["profile"])
        case .skillsToolsGet:
            return try get("/api/skills/content", payload, allowed: ["profile", "name"])
        case .skillsToolsCreate:
            try fields(payload, allowed: ["profile", "name", "content", "category"], required: ["profile", "name", "content"])
            return .http(.init(path: "/api/skills", method: .post, body: payload))
        case .skillsToolsUpdate:
            if payload["enabled"] != nil {
                try fields(payload, allowed: ["profile", "name", "enabled"], required: ["profile", "name", "enabled"])
                guard payload["enabled"]?.boolean != nil else { throw WorkspaceClientError.invalidRequest }
                return .http(.init(path: "/api/skills/toggle", method: .put, body: payload))
            }
            try fields(payload, allowed: ["profile", "name", "content"], required: ["profile", "name", "content"])
            return .http(.init(path: "/api/skills/content", method: .put, body: payload))
        case .workspaceConfigGet:
            return try get("/api/config", payload, allowed: ["profile", "include_defaults"])
        case .workspaceConfigSet:
            try fields(payload, allowed: ["profile", "config"], required: ["profile", "config"])
            guard payload["config"]?.object != nil else { throw WorkspaceClientError.invalidRequest }
            return .http(.init(path: "/api/config", method: .put, body: payload))
        case .personalitiesList:
            try fields(payload, allowed: ["profile", "action", "name", "config"], required: ["profile", "action"])
            if payload["action"] == .string("load") {
                return try get("/api/config", ["profile": payload["profile"]!], allowed: ["profile"])
            }
            guard [.string("save"), .string("activate")].contains(payload["action"]),
                  let config = payload["config"]?.object else { throw WorkspaceClientError.invalidRequest }
            return .http(.init(path: "/api/config", method: .put,
                              body: ["profile": payload["profile"]!, "config": .object(config)]))
        case .voiceSpeak:
            try fields(payload, allowed: ["profile", "text"], required: ["profile", "text"])
            return .http(.init(path: "/api/audio/speak", method: .post,
                              query: try queryItems(["profile": payload["profile"]!]), body: ["text": payload["text"]!]))
        case .pluginsList:
            try fields(payload, allowed: ["profile", "action"])
            guard payload["action"] == nil || payload["action"] == .string("list") else {
                throw WorkspaceClientError.invalidRequest
            }
            return .rpc("plugins.manage", payload.merging(["action": .string("list")]) { _, forced in forced })
        case .mcpServersList:
            try fields(payload, allowed: ["profile"])
            return .rpc("mcp.servers.list", payload)
        case .sessionsList:
            return try get("/api/sessions", payload,
                           allowed: ["profile", "limit", "offset", "archived", "order", "source", "sources", "exclude_sources", "cwd_prefix"])
        case .sessionSearch:
            return try get("/api/sessions/search", payload, allowed: ["q", "profile", "limit", "source", "sources", "exclude_sources"])
        case .sessionHistory:
            let id = try pathIdentifier(payload["session_id"])
            return try get("/api/sessions/\(id)/messages", removing("session_id", from: payload),
                           allowed: ["profile", "limit", "offset", "order", "include_compacted"])
        case .sessionDetail:
            let id = try pathIdentifier(payload["session_id"])
            return try get("/api/sessions/\(id)", removing("session_id", from: payload), allowed: ["profile"])
        case .sessionUpdate:
            let id = try pathIdentifier(payload["session_id"])
            let body = removing("session_id", from: payload)
            try fields(body, allowed: ["profile", "title", "archived", "hidden", "pinned", "unread"], required: ["profile"])
            return .http(.init(path: "/api/sessions/\(id)", method: .patch, body: body))
        case .sessionDelete:
            let id = try pathIdentifier(payload["session_id"])
            try fields(payload, allowed: ["session_id", "profile"], required: ["session_id", "profile"])
            return .http(.init(path: "/api/sessions/\(id)", method: .delete,
                               query: try queryItems(removing("session_id", from: payload))))
        case .toolsetsList:
            return try get("/api/tools/toolsets", payload, allowed: ["profile"])
        case .usageSummary:
            return try get("/api/analytics/usage", payload, allowed: ["profile", "days"])
        case .usageModels:
            return try get("/api/analytics/models", payload, allowed: ["profile", "days"])
        case .messagingPlatformsList:
            return try get("/api/messaging/platforms", payload, allowed: ["profile"])
        case .systemStatus:
            return try get("/api/system/stats", payload, allowed: [])
        case .logsList:
            try fields(payload, allowed: ["file", "lines"])
            guard payload["file"] == nil || payload["file"] == .string("agent"),
                  payload["lines"] == nil || payload["lines"] == .integer(100) else {
                throw WorkspaceClientError.invalidRequest
            }
            return try get("/api/logs", ["file": .string("agent"), "lines": .integer(100)], allowed: ["file", "lines"])
        case .memoryGet:
            return try get("/api/memory", payload, allowed: [])
        case .webhooksList:
            return try get("/api/webhooks", payload, allowed: [])
        case .webhooksSetEnabled:
            let name = try pathIdentifier(payload["name"])
            try fields(payload, allowed: ["name", "enabled"], required: ["name", "enabled"])
            guard let enabled = payload["enabled"]?.boolean else { throw WorkspaceClientError.invalidRequest }
            return .http(.init(path: "/api/webhooks/\(name)/enabled", method: .put,
                               body: ["enabled": .boolean(enabled)]))
        case .keysList:
            return try get("/api/env", payload, allowed: ["profile"])
        case .keysSet:
            try fields(payload, allowed: ["profile", "key", "value"], required: ["profile", "key", "value"])
            guard let key = payload["key"]?.string, !key.isEmpty, key.utf8.count <= 128,
                  key.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }),
                  let value = payload["value"]?.string, value.utf8.count <= 16_384 else {
                throw WorkspaceClientError.invalidRequest
            }
            return .http(.init(path: "/api/env", method: .put, body: payload))
        case .filesList:
            return try get("/api/files", payload, allowed: ["path"])
        case .filesRead:
            return try get("/api/files/read", payload, allowed: ["path"])
        case .managedFilesCapabilities:
            return try get("/api/plugins/loopdy/workspace-files/capabilities", payload, allowed: [])
        case .managedFilesList, .managedFilesRead:
            let allowed: Set<String> = operation == .managedFilesList
                ? ["workspace_id", "path", "offset", "limit", "query", "revision"]
                : ["workspace_id", "path", "offset", "limit", "revision"]
            try fields(payload, allowed: allowed, required: ["workspace_id", "path", "offset", "limit"])
            let action = operation == .managedFilesList ? "list" : "read"
            return .http(.init(path: "/api/plugins/loopdy/workspace-files/\(action)", method: .post, body: payload))
        case .scheduledTasksList:
            return try get("/api/cron/jobs", payload, allowed: ["profile"])
        case .scheduledTaskDeliveryTargets:
            return try get("/api/cron/delivery-targets", payload, allowed: [])
        case .scheduledTaskCreate:
            try fields(payload, allowed: ["profile", "schedule", "prompt", "name", "paused", "paused_reason",
                                          "deliver", "skills", "model", "provider", "context_from", "workdir"],
                       required: ["profile", "schedule"])
            return .http(.init(path: "/api/cron/jobs", method: .post,
                               query: try queryItems(["profile": payload["profile"] ?? .null]),
                               body: removing("profile", from: payload)))
        case .scheduledTaskUpdate:
            let id = try pathIdentifier(payload["id"])
            try fields(payload, allowed: ["id", "profile", "updates"], required: ["id", "profile", "updates"])
            guard payload["updates"]?.object != nil else { throw WorkspaceClientError.invalidRequest }
            return .http(.init(path: "/api/cron/jobs/\(id)", method: .put,
                               query: try queryItems(["profile": payload["profile"] ?? .null]),
                               body: removing("profile", from: removing("id", from: payload))))
        case .scheduledTaskPause, .scheduledTaskResume, .scheduledTaskRun, .scheduledTaskDelete:
            let id = try pathIdentifier(payload["id"])
            try fields(payload, allowed: ["id", "profile"], required: ["id", "profile"])
            let action = operation == .scheduledTaskPause ? "pause" : operation == .scheduledTaskResume ? "resume" : "trigger"
            let path = operation == .scheduledTaskDelete ? "/api/cron/jobs/\(id)" : "/api/cron/jobs/\(id)/\(action)"
            return .http(.init(path: path, method: operation == .scheduledTaskDelete ? .delete : .post,
                               query: try queryItems(removing("id", from: payload))))
        default:
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
    }

    private static func rpc(_ operation: WorkspaceOperation, _ payload: [String: BighelpJSONValue],
                            allowed: Set<String>, required: Set<String> = []) throws -> Route {
        try fields(payload, allowed: allowed, required: required)
        return .rpc(operation.rawValue, payload)
    }

    private static func get(_ path: String, _ payload: [String: BighelpJSONValue],
                            allowed: Set<String>) throws -> Route {
        try fields(payload, allowed: allowed)
        return .http(.init(path: path, method: .get, query: try queryItems(payload)))
    }

    private static func fields(_ payload: [String: BighelpJSONValue],
                               allowed: Set<String>, required: Set<String> = []) throws {
        let keys = Set(payload.keys)
        guard keys.isSubset(of: allowed), required.isSubset(of: keys) else {
            throw WorkspaceClientError.invalidRequest
        }
    }

    private static func queryItems(_ payload: [String: BighelpJSONValue]) throws -> [URLQueryItem] {
        try payload.keys.sorted().map { key in
            let text: String
            switch payload[key] {
            case .string(let value): text = value
            case .integer(let value): text = String(value)
            case .boolean(let value): text = value ? "true" : "false"
            default: throw WorkspaceClientError.invalidRequest
            }
            guard text.utf8.count <= 4_096 else { throw WorkspaceClientError.capacityExceeded }
            return URLQueryItem(name: key, value: text)
        }
    }

    private static func removing(_ key: String, from payload: [String: BighelpJSONValue]) -> [String: BighelpJSONValue] {
        var value = payload
        value.removeValue(forKey: key)
        return value
    }

    /// Hermes' HTTP session catalog uses the standard list/resource envelopes.
    /// The native catalog client consumes the equivalent internal projection,
    /// so unwrap the official envelope at this transport boundary and retain
    /// the profile scope carried by the request when Hermes omits it per row.
    private static func normalizedSessionList(
        _ envelope: [String: BighelpJSONValue],
        payload: [String: BighelpJSONValue]
    ) throws -> [String: BighelpJSONValue] {
        let rows: [BighelpJSONValue]
        let hasMore: Bool?
        if envelope["object"] == .string("list") {
            guard let data = envelope["data"]?.array, let more = envelope["has_more"]?.boolean else {
                throw WorkspaceClientError.invalidResponse
            }
            rows = data; hasMore = more
        } else {
            // Hermes 0.21.1 and existing dashboard deployments expose the
            // original typed catalog, without the newer REST wrapper.
            guard envelope["object"] == nil, envelope["data"] == nil,
                  let legacy = envelope["sessions"]?.array,
                  let total = envelope["total"]?.integer, total >= 0,
                  envelope["has_more"] == nil else { throw WorkspaceClientError.invalidResponse }
            rows = legacy; hasMore = nil
        }
        guard let limit = envelope["limit"]?.integer,
              let offset = envelope["offset"]?.integer,
              (1...200).contains(limit), offset >= 0, rows.count <= 10_000 else {
            throw WorkspaceClientError.invalidResponse
        }
        let profile = payload["profile"]?.string
        let normalizedRows = try rows.map { value -> BighelpJSONValue in
            guard var row = value.object,
                  let id = row["id"]?.string,
                  !id.isEmpty,
                  !id.contains("\0") else {
                throw WorkspaceClientError.invalidResponse
            }
            if let profile {
                if let returnedProfile = row["profile"]?.string {
                    guard returnedProfile == profile else { throw WorkspaceClientError.invalidResponse }
                } else {
                    row["profile"] = .string(profile)
                }
            }
            return .object(row)
        }
        var result: [String: BighelpJSONValue] = [
            "sessions": .array(normalizedRows),
            "limit": .integer(limit),
            "offset": .integer(offset),
        ]
        if let hasMore { result["has_more"] = .boolean(hasMore) }
        switch envelope["total"] {
        case nil, .null:
            break
        case .integer(let total):
            guard total >= 0 else { throw WorkspaceClientError.invalidResponse }
            result["total"] = .integer(total)
        default:
            throw WorkspaceClientError.invalidResponse
        }
        return result
    }

    private static func normalizedSessionDetail(
        _ envelope: [String: BighelpJSONValue],
        payload: [String: BighelpJSONValue]
    ) throws -> [String: BighelpJSONValue] {
        var session: [String: BighelpJSONValue]
        if envelope["object"] == .string("hermes.session"), let detail = envelope["session"]?.object {
            session = detail
        } else {
            guard envelope["object"] == nil, envelope["session"] == nil else {
                throw WorkspaceClientError.invalidResponse
            }
            session = envelope
        }
        guard let id = session["id"]?.string,
              !id.isEmpty,
              !id.contains("\0") else {
            throw WorkspaceClientError.invalidResponse
        }
        if let profile = payload["profile"]?.string {
            if let returnedProfile = session["profile"]?.string {
                guard returnedProfile == profile else { throw WorkspaceClientError.invalidResponse }
            } else {
                session["profile"] = .string(profile)
            }
        }
        return session
    }

    private static func pathIdentifier(_ value: BighelpJSONValue?) throws -> String {
        guard let text = value?.string, !text.isEmpty, text.utf8.count <= 512,
              text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || [45, 95, 46, 58].contains($0) }),
              text != ".", text != ".." else { throw WorkspaceClientError.invalidRequest }
        return text
    }

    private static func projectDefaults(_ source: [String: BighelpJSONValue]) throws -> [String: BighelpJSONValue] {
        var result: [String: BighelpJSONValue] = [:]
        let keys: [String: Set<String>] = [
            "agent": ["reasoning_effort"],
            "delegation": ["provider", "model", "reasoning_effort"],
            "cron": ["model", "model_provider"],
        ]
        for (namespace, allowed) in keys {
            guard let value = source[namespace], value != .null else {
                if namespace == "delegation" {
                    result[namespace] = .object(["has_base_url_override": .boolean(false)])
                }
                continue
            }
            guard let fields = value.object else { throw WorkspaceClientError.invalidResponse }
            var projected = fields.filter { allowed.contains($0.key) }
            guard projected.allSatisfy({ key, value in
                value == .null || value.string.map { $0.utf8.count <= 512 } == true
                    || (key == "reasoning_effort" && value.boolean != nil)
            }) else {
                throw WorkspaceClientError.invalidResponse
            }
            if namespace == "delegation" {
                projected["has_base_url_override"] = .boolean(fields["base_url"]?.string?.isEmpty == false)
            }
            result[namespace] = .object(projected)
        }
        return result
    }

    /// What callers see when Hermes or the transport fails an operation.
    static func workspaceError(_ error: any Error, for operation: WorkspaceOperation) -> any Error {
        if operation == .projectsGet, (error as? DirectHermesError) == .rpcRejected(code: 5062) {
            return WorkspaceClientError.rejected(code: "project_not_found")
        }
        // Hermes refuses parameters it doesn't know with 4000, so a caller can
        // retry without a field an older release lacks.
        if operation == .sessionCreate, (error as? DirectHermesError) == .rpcRejected(code: 4000) {
            return WorkspaceClientError.rejected(code: "invalid_params")
        }
        return safeError(error)
    }

    private static func safeError(_ error: any Error) -> any Error {
        if error is CancellationError || error is WorkspaceClientError { return error }
        guard let direct = error as? DirectHermesError else { return WorkspaceClientError.transportUnavailable }
        if direct.outcomeIsUnknown { return WorkspaceClientError.outcomeUnknown }
        switch direct {
        case .invalidCredentials, .authenticationRequired: return WorkspaceClientError.authenticationRequired
        case .rpcRejected(let code) where code == -32601: return WorkspaceClientError.unavailable(.unsupportedOperation)
        case .rpcRejected: return WorkspaceClientError.rejected(code: nil)
        case .invalidResponse: return WorkspaceClientError.invalidResponse
        case .messageTooLarge, .tooManyRequests: return WorkspaceClientError.capacityExceeded
        default: return WorkspaceClientError.transportUnavailable
        }
    }
}
