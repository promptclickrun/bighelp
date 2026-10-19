import Foundation
import Testing
@testable import Bighelp

@MainActor
struct NativeDeviceToolSessionTests {
    @Test func phoneLifetimeSurvivesNavigationTaskAndSerializesReplacement() async {
        let lifetime = NativeDeviceToolLifetime()
        var started = false
        var closed = false
        var replacementStarted = false
        var duplicateStarted = false
        var releaseClose: CheckedContinuation<Void, Never>?
        let navigation = Task { @MainActor in
            lifetime.update("host-a:chat-a:foreground") {
                started = true
                while !Task.isCancelled { await Task.yield() }
                await withCheckedContinuation { releaseClose = $0 }
                closed = true
            }
        }
        await navigation.value
        for _ in 0..<100 where !started { await Task.yield() }
        navigation.cancel()
        #expect(started && !closed)

        lifetime.update("host-a:chat-a:foreground") { duplicateStarted = true }
        lifetime.update("host-b:chat-b:foreground") { replacementStarted = true }
        for _ in 0..<100 where releaseClose == nil { await Task.yield() }
        #expect(releaseClose != nil)
        #expect(!replacementStarted && !duplicateStarted)
        releaseClose?.resume()
        for _ in 0..<100 where !replacementStarted { await Task.yield() }
        #expect(closed && replacementStarted)
        lifetime.stop()
        var resumedAfterUnlock = false
        lifetime.update("host-b:chat-b:foreground") { resumedAfterUnlock = true }
        for _ in 0..<100 where !resumedAfterUnlock { await Task.yield() }
        #expect(resumedAfterUnlock)
        lifetime.stop()
    }

    @Test func directPhoneToolUsesNativePluginAndReturnsResultToSameChannel() async throws {
        let fixture = try Fixture()
        let session = fixture.session()
        try await session.connect()
        try await session.pollOnce()
        #expect(fixture.handled == 1)
        #expect(fixture.http.paths == ["context", "device-tools/connect", "device-tools/poll", "device-tools/result"])
        #expect(fixture.http.results.first?["requestId"]?.string == "tool-call")
        #expect(fixture.http.results.first?["sessionId"]?.string == "session")
    }

    @Test func anotherSessionOrDeviceCannotExecutePhoneTool() async throws {
        for field in ["sessionId", "deviceId", "agentId", "hostId"] {
            let fixture = try Fixture()
            fixture.http.request[field] = .string("another")
            let session = fixture.session()
            try await session.connect()
            await #expect(throws: WorkspaceClientError.self) { try await session.pollOnce() }
            #expect(fixture.handled == 0)
            #expect(fixture.http.results.isEmpty)
        }
    }

    @Test func ownerRetiredDuringPollCannotExecuteOrDeliverPhoneData() async throws {
        let fixture = try Fixture()
        let session = fixture.session()
        try await session.connect()
        fixture.http.beforePollReply = { fixture.current = false }
        await #expect(throws: WorkspaceClientError.self) { try await session.pollOnce() }
        #expect(fixture.handled == 0 && fixture.http.results.isEmpty)
    }

    @Test func missingCapabilityNeverRegistersPhoneOrChangesAnyPermissions() async throws {
        let fixture = try Fixture()
        fixture.http.features = ["native-context-v1", "serving-profile-v1"]
        await #expect(throws: WorkspaceClientError.self) { try await fixture.session().connect() }
        #expect(fixture.http.paths == ["context"])
        #expect(fixture.handled == 0)
    }

    @Test func olderPluginNeverHearsAboutLocationButKeepsTheOtherTools() async throws {
        let fixture = try Fixture()
        let session = fixture.session(enabled: [.calendar, .location])
        try await session.connect()
        #expect(fixture.http.connectedEnabled == ["calendar"])
        #expect(session.needsNewerPlugin == [.location])
    }

    @Test func locationAloneOnAnOlderPluginAsksForAnUpdate() async throws {
        let fixture = try Fixture()
        let session = fixture.session(enabled: [.location])
        await #expect(throws: WorkspaceClientError.unavailable(.pluginRequired)) { try await session.connect() }
        #expect(fixture.http.paths == ["context"])
        #expect(session.needsNewerPlugin == [.location])
    }

    @Test func newerPluginGetsLocationAndRunsIt() async throws {
        let fixture = try Fixture()
        fixture.http.features.append("native-device-location-v1")
        fixture.http.request["operation"] = .string("location.current")
        let session = fixture.session(enabled: [.calendar, .location])
        try await session.connect()
        #expect(fixture.http.connectedEnabled == ["calendar", "location"])
        try await session.pollOnce()
        #expect(fixture.handled == 1)
        #expect(session.needsNewerPlugin.isEmpty)
    }

    @Test func appearanceAloneOnAnOlderPluginNeverOpensAChannel() async throws {
        let fixture = try Fixture()
        let session = fixture.session(enabled: [.appearance])
        await #expect(throws: WorkspaceClientError.unavailable(.pluginRequired)) { try await session.connect() }
        #expect(fixture.http.paths == ["context"])
        #expect(session.needsNewerPlugin == [.appearance])
    }

    @Test func newerPluginGetsAppearanceAndAQuietChannelPollsLessOften() async throws {
        let fixture = try Fixture()
        fixture.http.features.append("native-device-appearance-v1")
        fixture.http.request["operation"] = .string("appearance.set")
        let quiet = fixture.session(enabled: [.appearance])
        try await quiet.connect()
        #expect(fixture.http.connectedEnabled == ["appearance"])
        #expect(quiet.pollInterval == .seconds(8))
        try await quiet.pollOnce()
        #expect(fixture.handled == 1)
        let busy = fixture.session(enabled: [.calendar, .appearance])
        try await busy.connect()
        #expect(fixture.http.connectedEnabled == ["appearance", "calendar"])
        #expect(busy.pollInterval == .milliseconds(750))
    }

    /// Hermes loads the plugin's phone tools only into the agent it serves, and the plugin refuses any
    /// other agent's channel (`profile_not_served`). Another agent's chat asks the host nothing more.
    @Test func anotherAgentsChatNeverOpensOrClosesAChannel() async throws {
        let fixture = try Fixture()
        fixture.http.features.append("native-device-appearance-v1")
        let session = fixture.session(enabled: [.calendar, .appearance], agentID: "researcher")
        await #expect(throws: WorkspaceClientError.self) { try await session.run() }
        #expect(fixture.http.paths == ["context"])
        #expect(fixture.http.refusals.isEmpty)
        #expect(session.servingAgentID == "default")
        #expect(fixture.handled == 0)
    }

    @Test func theServedAgentsChatStillOpensItsChannel() async throws {
        let fixture = try Fixture()
        let session = fixture.session(agentID: "default")
        try await session.connect()
        #expect(session.servingAgentID == nil)
        #expect(fixture.http.paths == ["context", "device-tools/connect"])
        await session.close()
        #expect(fixture.http.paths == ["context", "device-tools/connect", "device-tools/close"])
        #expect(fixture.http.refusals.isEmpty)
    }

    @Test func anotherAgentsChatSaysWhichAgentCanUseSharedData() {
        #expect(DeviceToolChannelNote.otherAgent(enabled: [.calendar, .appearance], servingAgentName: "Sol")
            == "Open a chat with Sol to use this iPhone’s shared data.")
        #expect(DeviceToolChannelNote.otherAgent(enabled: [.appearance], servingAgentName: "Sol") == nil)
    }

    @Test func duplicateRequestIDsInOnePollBatchAreRejectedAtomically() async throws {
        let fixture = try Fixture()
        fixture.http.duplicateRequest = true
        let session = fixture.session()
        try await session.connect()
        await #expect(throws: WorkspaceClientError.self) { try await session.pollOnce() }
        #expect(fixture.handled == 0 && fixture.http.results.isEmpty)
    }

    @Test func expiredPollRequestDoesNotInvokeHandler() async throws {
        let fixture = try Fixture()
        fixture.http.request["expiresAt"] = .integer(Int(Date().timeIntervalSince1970) - 1)
        let session = fixture.session()
        try await session.connect()
        await #expect(throws: WorkspaceClientError.self) { try await session.pollOnce() }
        #expect(fixture.handled == 0 && fixture.http.results.isEmpty)
    }

    @Test func mismatchedHandlerResultCannotAdvanceCursor() async throws {
        let fixture = try Fixture()
        fixture.wrongResult = true
        let session = fixture.session()
        try await session.connect()
        await #expect(throws: WorkspaceClientError.self) { try await session.pollOnce() }
        #expect(fixture.handled == 1 && fixture.http.results.isEmpty)
    }

    @Test func connectAcceptedAfterForegroundRetiresStillClosesChannel() async throws {
        let fixture = try Fixture()
        fixture.http.beforeConnectReply = { fixture.available = false }
        await #expect(throws: WorkspaceClientError.self) { try await fixture.session().run() }
        #expect(fixture.http.paths == ["context", "device-tools/connect", "device-tools/close"])
    }

    @Test func acceptedConnectThenOwnerRetiresUsesPreparedCleanupOnce() async throws {
        let fixture = try Fixture()
        fixture.http.beforeConnectReply = { fixture.current = false }
        var cleanupCount = 0
        let session = NativeDeviceToolSession(http: fixture.http, owner: fixture.owner,
            currentOwner: { fixture.current ? fixture.owner : nil }, scope: fixture.scope,
            agentID: "default", sessionID: "session", enabled: [.calendar], isAvailable: { true },
            closeCleanupFactory: { _ in { cleanupCount += 1 } },
            handle: { request, _, _ in DeviceToolResult(request: request, status: "failed", sentAt: 1) })
        await #expect(throws: WorkspaceClientError.self) { try await session.run() }
        await session.close()
        #expect(cleanupCount == 1)
        #expect(fixture.http.paths == ["context", "device-tools/connect"])
    }

    @MainActor private final class Fixture {
        let http = HTTP()
        let owner: WorkspaceOwner
        let scope = DeviceToolScope(deviceID: "e8cc487e-36ed-442f-a2c5-834f0dc5a953", authorizationEpoch: 1, hostID: "native-host")
        var current = true
        var handled = 0
        var available = true
        var wrongResult = false
        init() throws {
            owner = WorkspaceOwner(authority: try .dashboard(endpointIdentity: "https://host.example:9119"),
                                   authenticationGeneration: UUID(), connectionGeneration: UUID())
            http.request = ["version": .integer(1), "type": .string("device.tool.request"),
                "requestId": .string("tool-call"), "deviceId": .string(scope.deviceID), "hostId": .string(scope.hostID),
                "authorizationEpoch": .integer(1), "sessionId": .string("session"), "agentId": .string("default"),
                "turnId": .string("turn"), "operation": .string("calendar.list"), "arguments": .object([:]),
                "sentAt": .integer(Int(Date().timeIntervalSince1970)), "expiresAt": .integer(Int(Date().timeIntervalSince1970) + 60)]
        }
        func session(enabled: Set<DeviceToolCapability> = [.calendar], agentID: String = "default") -> NativeDeviceToolSession {
            NativeDeviceToolSession(http: http, owner: owner, currentOwner: { self.current ? self.owner : nil },
                scope: scope, agentID: agentID, sessionID: "session", enabled: enabled,
                isAvailable: { self.available }, handle: { request, _, _ in
                    self.handled += 1
                    var resultRequest = request
                    if self.wrongResult {
                        var raw = self.http.request
                        raw["sessionId"] = .string("different-session")
                        resultRequest = try! JSONDecoder().decode(DeviceToolRequest.self, from: JSONEncoder().encode(raw))
                    }
                    return DeviceToolResult(request: resultRequest, status: "completed", payload: ["items": .array([])],
                                            sentAt: Int(Date().timeIntervalSince1970))
                })
        }
    }

    private final class HTTP: DirectHermesNativeHTTP {
        var request: [String: BighelpJSONValue] = [:]
        var features = ["native-context-v1", "serving-profile-v1", "native-device-tools-v1"]
        var paths: [String] = []
        var results: [[String: BighelpJSONValue]] = []
        var connectedEnabled: [String] = []
        var beforePollReply: () -> Void = {}
        var beforeConnectReply: () -> Void = {}
        var duplicateRequest = false
        /// Like the plugin: it serves one Hermes profile and knows the channels it opened.
        let servingProfile = "default"
        var channels: Set<String> = []
        /// The codes the plugin would answer and log (`bighelp native request rejected: …`).
        var refusals: [String] = []
        func nativeResponse(_ request: DirectHermesHTTPRequest, requestGuard: DirectHermesNativeRequestGuard?) async throws -> DirectHermesHTTP.Response {
            let path = String(request.path.dropFirst("/api/plugins/loopdy/native/".count))
            paths.append(path)
            let channel = request.body?["channelId"] ?? .null
            let value: [String: BighelpJSONValue]
            switch path {
            case "context": value = ["schemaVersion": .integer(1), "pluginVersion": .string("test"),
                "runtimeId": .string("runtime"), "servingProfileId": .string(servingProfile), "principal": .null,
                "features": .array(features.map(BighelpJSONValue.string))]
            case "device-tools/connect":
                guard request.body?["agentId"] == .string(servingProfile) else {
                    return try refusal("profile_not_served", status: 403, request: request, requestGuard: requestGuard)
                }
                connectedEnabled = request.body?["enabled"]?.array?.compactMap(\.string) ?? []
                beforeConnectReply()
                if let id = channel.string { channels.insert(id) }
                value = ["channelId": channel, "connected": .boolean(true)]
            case "device-tools/poll":
                beforePollReply()
                let count = duplicateRequest ? 2 : 1
                value = ["channelId": channel, "next": .integer(count),
                         "requests": .array((1...count).map { .object(["sequence": .integer($0), "request": .object(self.request)]) })]
            case "device-tools/result":
                if let result = request.body?["result"]?.object { results.append(result) }
                value = ["accepted": .boolean(true)]
            case "device-tools/close":
                guard let id = channel.string, channels.remove(id) != nil else {
                    return try refusal("channel_not_found", status: 409, request: request, requestGuard: requestGuard)
                }
                value = ["closed": .boolean(true)]
            default: throw WorkspaceClientError.invalidRequest
            }
            var headers = ["ETag": requestGuard?.etag ?? "\"sha256:\(String(repeating: "a", count: 64))\"", "Cache-Control": "no-store"]
            if let requestGuard { headers["X-Loopdy-Request-ID"] = requestGuard.requestIDHeader }
            let response = try #require(HTTPURLResponse(url: URL(string: "https://host.example:9119" + request.path)!,
                                                       statusCode: 200, httpVersion: nil, headerFields: headers))
            return .init(http: response, body: try JSONEncoder().encode(BighelpJSONValue.object(value)))
        }

        /// The plugin's `_error_response`: no ETag, the request ID echoed.
        private func refusal(_ code: String, status: Int, request: DirectHermesHTTPRequest,
                             requestGuard: DirectHermesNativeRequestGuard?) throws -> DirectHermesHTTP.Response {
            refusals.append(code)
            var headers = ["Cache-Control": "no-store"]
            if let requestGuard { headers["X-Loopdy-Request-ID"] = requestGuard.requestIDHeader }
            let response = try #require(HTTPURLResponse(url: URL(string: "https://host.example:9119" + request.path)!,
                                                       statusCode: status, httpVersion: nil, headerFields: headers))
            let body: BighelpJSONValue = .object(["error": .object(["code": .string(code),
                "message": .string("The native iPhone tool channel is unavailable."),
                "retryable": .boolean(false), "details": .object([:])])])
            return .init(http: response, body: try JSONEncoder().encode(body))
        }
    }
}

@MainActor
struct HostPluginFeatureReadinessTests {
    @Test func staleFeatureCheckAfterHostSwitchCannotPublishReadiness() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let hostID = try #require(fixture.registry.selectedHostID)
        let registryGeneration = fixture.registry.generation
        let connectionGeneration = try #require(fixture.registry.selectedWorkspace?.connectionGeneration)
        let token = fixture.registry.deviceToolFeatureReadinessToken
        let ownsCapturedConnection: @MainActor () -> Bool = {
            fixture.registry.selectedHostID == hostID
                && fixture.registry.generation == registryGeneration
                && fixture.registry.selectedWorkspace?.connectionGeneration == connectionGeneration
        }

        fixture.registry.select(fixture.hostB.id)

        let accepted = fixture.registry.recordPluginFeatureReadiness(
            feature: .deviceAccess, hostID: hostID, registryGeneration: registryGeneration,
            connectionGeneration: connectionGeneration, contextETag: "etag-a",
            capabilities: ["native-context-v1", "native-device-tools-v1"],
            isCurrent: ownsCapturedConnection
        )

        #expect(!accepted)
        #expect(fixture.registry.deviceToolFeatureReadinessToken == token)
    }

    @Test func repeatedFeatureCheckForSameContextDoesNotChangeReadinessToken() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let hostID = try #require(fixture.registry.selectedHostID)
        let registryGeneration = fixture.registry.generation
        let connectionGeneration = try #require(fixture.registry.selectedWorkspace?.connectionGeneration)
        let ownsCapturedConnection: @MainActor () -> Bool = {
            fixture.registry.selectedHostID == hostID
                && fixture.registry.generation == registryGeneration
                && fixture.registry.selectedWorkspace?.connectionGeneration == connectionGeneration
        }
        let first = fixture.registry.recordPluginFeatureReadiness(
            feature: .deviceAccess, hostID: hostID, registryGeneration: registryGeneration,
            connectionGeneration: connectionGeneration, contextETag: "etag-a",
            capabilities: ["native-context-v1", "native-device-tools-v1"],
            isCurrent: ownsCapturedConnection
        )
        let token = fixture.registry.deviceToolFeatureReadinessToken
        let repeated = fixture.registry.recordPluginFeatureReadiness(
            feature: .deviceAccess, hostID: hostID, registryGeneration: registryGeneration,
            connectionGeneration: connectionGeneration, contextETag: "etag-a",
            capabilities: ["native-context-v1", "native-device-tools-v1"],
            isCurrent: ownsCapturedConnection
        )

        #expect(first)
        #expect(repeated)
        #expect(token == fixture.registry.deviceToolFeatureReadinessToken)
    }

    @Test func newlyAvailableFeatureCapabilityAdvancesReadinessToken() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let hostID = try #require(fixture.registry.selectedHostID)
        let registryGeneration = fixture.registry.generation
        let connectionGeneration = try #require(fixture.registry.selectedWorkspace?.connectionGeneration)
        let ownsCapturedConnection: @MainActor () -> Bool = {
            fixture.registry.selectedHostID == hostID
                && fixture.registry.generation == registryGeneration
                && fixture.registry.selectedWorkspace?.connectionGeneration == connectionGeneration
        }
        let before = fixture.registry.deviceToolFeatureReadinessToken
        let missing = fixture.registry.recordPluginFeatureReadiness(
            feature: .deviceAccess, hostID: hostID, registryGeneration: registryGeneration,
            connectionGeneration: connectionGeneration, contextETag: "etag-a",
            capabilities: ["native-context-v1"], isCurrent: ownsCapturedConnection
        )
        let ready = fixture.registry.recordPluginFeatureReadiness(
            feature: .deviceAccess, hostID: hostID, registryGeneration: registryGeneration,
            connectionGeneration: connectionGeneration, contextETag: "etag-b",
            capabilities: ["native-context-v1", "native-device-tools-v1"],
            isCurrent: ownsCapturedConnection
        )

        #expect(!missing)
        #expect(ready)
        #expect(fixture.registry.deviceToolFeatureReadinessToken == before + 1)
    }

    @MainActor
    private final class Fixture {
        let registry: BighelpHostRegistry
        let hostA: BighelpConfiguredHost
        let hostB: BighelpConfiguredHost
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            registry = BighelpHostRegistry(
                root: root,
                keychainService: "app.loopdy.test.feature-readiness." + UUID().uuidString
            )
            registry.bind(deviceID: "readiness-account", authorizationEpoch: 1)
            let scope = try #require(registry.accountScope)
            let endpointA = try DirectHermesEndpoint(address: "https://readiness-a.example")
            let endpointB = try DirectHermesEndpoint(address: "https://readiness-b.example")
            let savedA = DirectHermesSavedConnection(
                endpoint: endpointA,
                authentication: .bearer(accessToken: UUID().uuidString, refreshToken: nil, expiresAt: nil),
                provider: "basic", userID: "readiness-a"
            )
            let savedB = DirectHermesSavedConnection(
                endpoint: endpointB,
                authentication: .bearer(accessToken: UUID().uuidString, refreshToken: nil, expiresAt: nil),
                provider: "basic", userID: "readiness-b"
            )
            hostA = BighelpConfiguredHost(
                id: UUID(), accountScope: scope, accountID: "readiness-account",
                endpoint: endpointA, principalIdentity: savedA.identity, name: "Readiness A"
            )
            hostB = BighelpConfiguredHost(
                id: UUID(), accountScope: scope, accountID: "readiness-account",
                endpoint: endpointB, principalIdentity: savedB.identity, name: "Readiness B"
            )
            struct Snapshot: Encodable {
                let version = 1
                let hosts: [BighelpConfiguredHost]
                let selected: UUID?
            }
            try JSONEncoder().encode(Snapshot(hosts: [hostA, hostB], selected: hostA.id))
                .write(to: root.appending(path: scope + ".json"))
            registry.bind(deviceID: "readiness-account", authorizationEpoch: 1, forceReload: true)
        }

        func cleanup() {
            registry.bind(deviceID: nil, authorizationEpoch: nil)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
