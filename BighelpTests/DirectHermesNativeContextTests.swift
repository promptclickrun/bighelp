import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesNativeContextTests {
    @Test func dashboardGrantCannotBeConfusedWithAProviderPerson() throws {
        let authority = try WorkspaceAuthority.dashboard(endpointIdentity: "https://host.example:9119")
        let dashboard = WorkspaceOwner(authority: authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        var value = context(); value["principal"] = .null
        let request = DirectHermesHTTPRequest(path: "/api/plugins/loopdy/native/context", method: .get)
        let response = try response(request, body: value)
        let decoded = try DirectHermesNativeContext(response: response, owner: dashboard)
        #expect(decoded.providerID == nil && decoded.userID == nil)
        #expect(throws: WorkspaceClientError.invalidResponse) { try DirectHermesNativeContext(response: response, owner: owner()) }
        let personResponse = try self.response(request, body: context())
        #expect(throws: WorkspaceClientError.invalidResponse) { try DirectHermesNativeContext(response: personResponse, owner: dashboard) }
    }

    @Test(arguments: [WorkspaceOperation.projectsGitCapabilities, .projectsGitStatus, .projectsGitDiff])
    func nativeGitReadsUseOnlyAdvertisedFixedRoutes(operation: WorkspaceOperation) async throws {
        let owner = try owner()
        let http = HTTP()
        var payload: [String: BighelpJSONValue] = [
            "agentId": .string("default"), "sessionId": .string("full-native-stored-id"),
            "workspaceId": .string("registered-project")
        ]
        if operation == .projectsGitDiff {
            payload.merge(["path": .string("README.md"), "side": .string("worktree"),
                           "statusToken": .string(String(repeating: "a", count: 64)),
                           "offset": .integer(0), "limit": .integer(50)]) { _, value in value }
        }
        http.handler = { request, guardValue in
            if let guardValue {
                return try self.response(request, body: ["observed": .boolean(true)],
                                         headers: ["ETag": guardValue.etag, "X-Loopdy-Request-ID": guardValue.requestIDHeader])
            }
            return try self.response(request, body: self.context(features: [
                "native-context-v1", "serving-profile-v1", "native-project-git-read-v1"
            ]))
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        _ = try await client.perform(operation, payload: payload)
        #expect(http.calls.count == 2)
        let suffix = try #require(operation.rawValue.split(separator: ".").last)
        #expect(http.calls[1].request.path == "/api/plugins/loopdy/native/projects/git/" + suffix)
        #expect(http.calls[1].request.method == .post)
        #expect(http.calls[1].request.maximumResponseBytes == 196_608)
        #expect(http.calls[1].request.body == payload)
        #expect(http.calls[1].guardValue?.etag == etag)
        #expect(!DirectHermesNativePluginClient.supports(.projectsGitPrepare))
        #expect(!DirectHermesNativePluginClient.supports(.projectsGitExecute))
    }

    /// The host asks every provider before it answers (up to 20 seconds, after
    /// finding them). Giving up at 20 seconds showed "couldn't be loaded".
    @Test func usageWaitsLongerThanTheHostTakesToAskEveryProvider() async throws {
        let owner = try owner()
        let http = HTTP()
        http.handler = { request, guardValue in
            if let guardValue {
                return try self.response(request, body: ["providers": .array([])],
                                         headers: ["ETag": guardValue.etag, "X-Loopdy-Request-ID": guardValue.requestIDHeader])
            }
            return try self.response(request, body: self.context(features: [
                "native-context-v1", "serving-profile-v1", "native-provider-usage-v1"
            ]))
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        _ = try await client.perform(.usageList, payload: ["agentId": .string("default"), "refresh": .boolean(false)])
        #expect(http.calls.count == 2)
        #expect(http.calls[0].request.timeout == 20, "Everything else keeps the usual wait")
        #expect(http.calls[1].request.path == "/api/plugins/loopdy/native/usage/list")
        #expect(http.calls[1].request.timeout >= 45)
        #expect(http.calls[1].request.timeout <= DirectHermesHTTP.longestRequestSeconds)
    }

    /// A Cloudflare Tunnel compresses replies for iPhones (which always accept
    /// compression) and marks their ETag weak: `W/"sha256:…"`. The app refused
    /// that, so every plugin feature behind a Cloudflare tunnel failed
    /// ("Usage couldn't be loaded", Device access "couldn't reach"). The tag
    /// inside is the same plugin context; the plugin gets it back unchanged.
    @Test func aProxysWeakETagStillMatchesThePluginContext() async throws {
        let owner = try owner()
        let http = HTTP()
        let weak = "W/" + etag
        http.handler = { request, guardValue in
            if let guardValue {
                return try self.response(request, body: ["providers": .array([])],
                    headers: ["ETag": "W/" + guardValue.etag, "X-Loopdy-Request-ID": guardValue.requestIDHeader,
                              "Cache-Control": "no-store"])
            }
            return try self.response(request, body: self.context(features: [
                "native-context-v1", "serving-profile-v1", "native-provider-usage-v1"
            ]), headers: ["ETag": weak, "Cache-Control": "no-store"])
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        let result = try await client.perform(.usageList, payload: ["agentId": .string("default"), "refresh": .boolean(false)])
        #expect(result["providers"] == .array([]))
        #expect(http.calls.last?.guardValue?.etag == etag, "If-Match carries the plugin's own tag")
    }

    @Test func verifiedContextBindsPrincipalAndDiscardsUnrecognizedFields() async throws {
        let owner = try owner()
        let http = HTTP()
        http.handler = { request, _ in
            var context = self.context()
            context["unrecognized_secret"] = .string("never projected")
            return try self.response(request, body: context)
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        let result = try await client.loadContext()
        #expect(result.providerID == "basic")
        #expect(result.userID == "person")
        #expect(result.servingProfileID == "default")
        #expect(result.projection["unrecognized_secret"] == nil)
        #expect(http.calls.first?.request.maximumResponseBytes == 16_384)
        #expect(http.calls.first?.guardValue == nil)
    }

    @Test func missingAdvertisedFeatureNeverDispatchesAnOperation() async throws {
        let owner = try owner()
        let http = HTTP()
        http.handler = { request, _ in
            try self.response(request, body: self.context(features: ["native-context-v1", "serving-profile-v1"]))
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            try await client.perform(.wikiConnect, payload: ["agentId": .string("default")])
        }
        #expect(http.calls.count == 1)
    }

    /// Let's do it reaches only plugins that list `native-agent-board-answers-v1`; older ones
    /// never see the request, and the app falls back to the chat message alone.
    @Test func ideaAcceptanceUsesItsOwnFeatureAndFixedRoute() async throws {
        let owner = try owner()
        let http = HTTP()
        var features = ["native-context-v1", "serving-profile-v1", "native-agent-board-v1",
                        "native-agent-board-feedback-v1"]
        http.handler = { request, guardValue in
            if let guardValue {
                return try self.response(request, body: ["agentId": .string("default"), "item": .object([
                    "id": .string("idea-7f3a91"), "kind": .string("idea"), "title": .string("Plan a trip"),
                    "answer": .string("yes"),
                ])], headers: ["ETag": guardValue.etag, "X-Loopdy-Request-ID": guardValue.requestIDHeader])
            }
            return try self.response(request, body: self.context(features: features))
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        let payload: [String: BighelpJSONValue] = ["agentId": .string("default"), "itemId": .string("idea-7f3a91")]
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            try await client.perform(.boardAccept, payload: payload)
        }
        #expect(http.calls.count == 1, "An older plugin is never asked")

        features.append("native-agent-board-answers-v1")
        _ = try await client.loadContext(force: true)
        _ = try await client.perform(.boardAccept, payload: payload)
        let call = try #require(http.calls.last)
        #expect(call.request.path == "/api/plugins/loopdy/native/board/accept")
        #expect(call.request.method == .post)
        #expect(call.request.body == payload)
        #expect(call.guardValue?.etag == etag)
        #expect(call.guardValue?.requestIDHeader == call.guardValue?.requestIDHeader.lowercased())
    }

    @Test func templateReadUsesOnlyFixedPathAndExactContextHeaders() async throws {
        let owner = try owner()
        let http = HTTP()
        http.handler = { request, guardValue in
            if let guardValue {
                return try self.response(request, body: ["agentId": .string("default"), "templates": .array([])],
                                         headers: ["ETag": guardValue.etag, "X-Loopdy-Request-ID": guardValue.requestIDHeader])
            }
            return try self.response(request, body: self.context())
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        _ = try await client.perform(.cardsTemplatesList, payload: ["agentId": .string("default")])
        #expect(http.calls.count == 2)
        #expect(http.calls[1].request.path == "/api/plugins/loopdy/native/cards/templates/list")
        #expect(http.calls[1].request.method == .post)
        let guardValue = try #require(http.calls[1].guardValue)
        #expect(guardValue.etag == etag)
        #expect(guardValue.requestIDHeader == guardValue.requestID.uuidString.lowercased())
    }

    @Test func contextPreconditionFailureRetiresContextWithoutReplayingMutation() async throws {
        let owner = try owner()
        let http = HTTP()
        http.handler = { request, guardValue in
            if guardValue != nil {
                return try self.response(request, status: 412,
                                         body: ["error": .object(["code": .string("context_changed")])], headers: [:])
            }
            return try self.response(request, body: self.context())
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        await #expect(throws: WorkspaceClientError.conflict) {
            try await client.perform(.cardsTemplatesRemove, payload: ["agentId": .string("default")])
        }
        #expect(client.context == nil)
        #expect(http.calls.count == 2)
    }

    @Test func lostMutationReplyRemainsUnknownAndIsNotRetried() async throws {
        let owner = try owner()
        let http = HTTP()
        http.handler = { request, guardValue in
            if guardValue != nil { throw WorkspaceClientError.transportUnavailable }
            return try self.response(request, body: self.context())
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await client.perform(.cardsTemplatesInstall, payload: ["agentId": .string("default")])
        }
        #expect(http.calls.count == 2)
    }

    @Test func aRefusalBeforeAnyWorkIsKnownNotUnknown() async throws {
        let owner = try owner()
        let http = HTTP()
        var code = "runner_unavailable"
        http.handler = { request, guardValue in
            if guardValue != nil {
                return try self.response(request, status: 503, body: [
                    "error": .object(["code": .string(code), "message": .string("details")]),
                ])
            }
            return try self.response(request, body: self.context())
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        await #expect(throws: WorkspaceClientError.rejected(code: "runner_unavailable")) {
            try await client.perform(.cardsTemplatesInstall, payload: ["agentId": .string("default")])
        }
        // Any other 503 to a change may have run: still unknown.
        code = "busy"
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await client.perform(.cardsTemplatesInstall, payload: ["agentId": .string("default")])
        }
    }

    @Test func successRequiresEchoedRequestAndContextWhileErrorsDoNotRequireETag() async throws {
        let owner = try owner()
        let http = HTTP()
        http.handler = { request, guardValue in
            if guardValue != nil { return try self.response(request, body: [:], headers: [:]) }
            return try self.response(request, body: self.context())
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await client.perform(.cardsTemplatesInstall, payload: ["agentId": .string("default")])
        }
        #expect(client.context == nil)
        http.handler = { request, guardValue in
            if guardValue != nil {
                return try self.response(request, status: 404, body: [
                    "error": .object(["code": .string("WIKI_AUTHORITY_CONFLICT"), "message": .string("private details")]),
                ], headers: [:])
            }
            return try self.response(request, body: self.context())
        }
        await #expect(throws: WorkspaceClientError.rejected(code: "WIKI_AUTHORITY_CONFLICT")) {
            try await client.perform(.wikiRead, payload: ["agentId": .string("default")])
        }
    }

    @Test func changedOwnerOrByteDistinctPrincipalCannotAdoptContext() async throws {
        let owner = try owner()
        var current: WorkspaceOwner? = owner
        let http = HTTP()
        http.handler = { request, _ in
            current = nil
            return try self.response(request, body: self.context())
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { current })
        await #expect(throws: WorkspaceClientError.ownerChanged) { try await client.loadContext() }
        #expect(client.context == nil)
        let composed = try self.owner(userID: "caf\u{e9}")
        let mismatch = try response(.init(path: "/api/plugins/loopdy/native/context", method: .get),
                                    body: context(userID: "cafe\u{301}"))
        #expect(throws: WorkspaceClientError.invalidResponse) {
            try DirectHermesNativeContext(response: mismatch, owner: composed)
        }
    }

    @Test func hostRestartIsOnlyRequestedFromAPluginThatAdvertisesIt() async throws {
        let owner = try owner()
        let http = HTTP()
        var features = ["native-context-v1", "serving-profile-v1"]
        http.handler = { request, guardValue in
            if guardValue != nil { return try self.response(request, body: ["restarting": .boolean(true)]) }
            return try self.response(request, body: self.context(features: features))
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) { try await client.restartHost() }
        #expect(http.calls.count == 1)

        features.append(DirectHermesNativePluginClient.hostRestartFeature)
        try await client.restartHost()
        let restart = try #require(http.calls.last)
        #expect(restart.request.path == "/api/plugins/loopdy/native/host/restart")
        #expect(restart.request.method == .post)
        #expect(restart.request.body == ["confirm": .boolean(true)])
        #expect(restart.guardValue?.etag == etag)
    }

    @Test func hostRestartThatIsNotAcknowledgedIsAnError() async throws {
        let owner = try owner()
        let http = HTTP()
        http.handler = { request, guardValue in
            if guardValue != nil { return try self.response(request, body: ["restarting": .boolean(false)]) }
            return try self.response(request, body: self.context(features: [
                "native-context-v1", "serving-profile-v1", DirectHermesNativePluginClient.hostRestartFeature,
            ]))
        }
        let client = DirectHermesNativePluginClient(http: http, owner: owner, currentOwner: { owner })
        await #expect(throws: (any Error).self) { try await client.restartHost() }
    }

    @Test func contextGuardRejectsUnboundedOrMalformedHeaders() {
        for value in ["sha256:" + String(repeating: "a", count: 64), "\"sha256:bad\"", etag + "\r\nx: y",
                      "W/W/" + etag, "w/" + etag] {
            #expect(throws: WorkspaceClientError.invalidResponse) { try DirectHermesNativeRequestGuard(etag: value) }
        }
    }

    private var etag: String { "\"sha256:" + String(repeating: "a", count: 64) + "\"" }

    private func owner(userID: String = "person") throws -> WorkspaceOwner {
        WorkspaceOwner(authority: try .direct(endpointIdentity: "https://host.example", providerID: "basic", userID: userID),
                       authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    private func context(userID: String = "person", features: [String] = [
        "native-context-v1", "serving-profile-v1", "native-card-templates-v1", "native-wiki-v1",
    ]) -> [String: BighelpJSONValue] {
        [
            "schemaVersion": .integer(1), "pluginVersion": .string("test"), "runtimeId": .string("runtime-test"),
            "servingProfileId": .string("default"),
            "principal": .object(["provider": .string("basic"), "userId": .string(userID), "displayName": .null]),
            "features": .array(features.map(BighelpJSONValue.string)),
        ]
    }

    private func response(_ request: DirectHermesHTTPRequest, status: Int = 200,
                          body: [String: BighelpJSONValue], headers: [String: String]? = nil) throws -> DirectHermesHTTP.Response {
        let url = try #require(URL(string: "https://host.example" + request.path))
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers ?? ["ETag": etag, "Cache-Control": "no-store"]
        ))
        return .init(http: response, body: try JSONEncoder().encode(BighelpJSONValue.object(body)))
    }

    @MainActor private final class HTTP: DirectHermesNativeHTTP {
        struct Call {
            let request: DirectHermesHTTPRequest
            let guardValue: DirectHermesNativeRequestGuard?
        }
        var calls: [Call] = []
        var handler: ((DirectHermesHTTPRequest, DirectHermesNativeRequestGuard?) throws -> DirectHermesHTTP.Response)?
        func nativeResponse(_ request: DirectHermesHTTPRequest,
                            requestGuard: DirectHermesNativeRequestGuard?) async throws -> DirectHermesHTTP.Response {
            calls.append(Call(request: request, guardValue: requestGuard))
            guard let handler else { throw WorkspaceClientError.transportUnavailable }
            return try handler(request, requestGuard)
        }
    }
}

extension DirectHermesNativeContextTests {
    /// The plugin says why this computer can't run Workflows (`unavailable`).
    /// The reason must reach Workflows, or the app wrongly says "Update the plugin".
    @Test func unavailableReasonsReachWorkflows() throws {
        var value = context()
        value["unavailable"] = .object(["native-workflows-v1": .string("chat_runner_missing"),
                                        "native-workflows-edit-v1": .string("chat_runner_missing")])
        let request = DirectHermesHTTPRequest(path: "/api/plugins/loopdy/native/context", method: .get)
        let decoded = try DirectHermesNativeContext(response: try response(request, body: value), owner: owner())
        #expect(WorkflowsSupport(context: decoded.projection) == .unavailable(code: "chat_runner_missing"))

        // Bad entries are left out; the rest of the context still loads.
        value["unavailable"] = .object(["native-workflows-v1": .integer(3), " padded": .string("x")])
        let lenient = try DirectHermesNativeContext(response: try response(request, body: value), owner: owner())
        #expect(lenient.unavailable.isEmpty)
        #expect(WorkflowsSupport(context: lenient.projection) == .missing)
    }
}
