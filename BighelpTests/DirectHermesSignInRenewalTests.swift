import Foundation
import Network
import Testing
@testable import Bighelp

/// The chat socket stays signed in from when it connected, but every web
/// request (the plugin's routes, sessions, voice) carries the app's sign-in
/// again. When Hermes turns one away (a token renewed elsewhere, revoked, or
/// a new dashboard token after a restart), the app renews the sign-in and
/// sends the request once more instead of failing until it reconnects. That
/// failure showed up as "could not reach its native API" under Device access.
@MainActor
struct DirectHermesSignInRenewalTests {
    private nonisolated static let oldToken = String(repeating: "o", count: 43)
    private nonisolated static let newToken = String(repeating: "n", count: 43)

    private func authenticator(port: UInt16, _ authentication: DirectHermesStoredAuthentication,
                               rotations: @escaping (DirectHermesSavedConnection) -> Void = { _ in })
        throws -> DirectHermesAuthenticator {
        let endpoint = try DirectHermesEndpoint(address: "http://127.0.0.1:\(port)", allowPrivateHTTP: true)
        let authenticator = DirectHermesAuthenticator(endpoint: endpoint)
        var saved = DirectHermesSavedConnection(endpoint: endpoint, authentication: authentication)
        if case .bearer = authentication { (saved.provider, saved.userID) = ("basic", "fixture") }
        authenticator.adoptForTesting(saved)
        authenticator.persistRotation = { _, replacement in rotations(replacement) }
        return authenticator
    }

    private let context = DirectHermesHTTPRequest(path: "/api/plugins/loopdy/native/context", method: .get,
                                                  maximumResponseBytes: 16_384)

    @Test func aDashboardTokenTurnedAwayIsReadAgainAndTheRequestSentOnce() async throws {
        let host = try ScriptedHermes { request in
            if request.path == "/" {
                return .html("<script>window.__HERMES_SESSION_TOKEN__=\"\(Self.newToken)\";"
                             + "window.__HERMES_AUTH_REQUIRED__=false;</script>")
            }
            return request.header("x-hermes-session-token") == Self.newToken ? .json("{}") : .status(401)
        }
        var rotated: [DirectHermesSavedConnection] = []
        let authenticator = try authenticator(port: try await host.start(),
                                              .dashboardSession(token: Self.oldToken, automatic: true)) {
            rotated.append($0)
        }

        let response = try await authenticator.authenticatedResponse(context)

        #expect(response.http.statusCode == 200)
        #expect(host.paths == ["/api/plugins/loopdy/native/context", "/", "/api/plugins/loopdy/native/context"])
        #expect(rotated.map(\.authentication) == [.dashboardSession(token: Self.newToken, automatic: true)])
    }

    @Test func aBearerTurnedAwayIsRefreshedAndTheRequestSentOnce() async throws {
        let host = try ScriptedHermes { request in
            if request.path == "/auth/native/refresh" {
                let expires = Int(Date().addingTimeInterval(3_600).timeIntervalSince1970)
                return .json("{\"token_type\":\"Bearer\",\"access_token\":\"\(Self.newToken)\","
                             + "\"refresh_token\":\"refresh-2\",\"provider\":\"basic\",\"user_id\":\"fixture\","
                             + "\"expires_at\":\(expires)}")
            }
            return request.header("authorization") == "Bearer \(Self.newToken)" ? .json("{}") : .status(401)
        }
        let authenticator = try authenticator(port: try await host.start(), .bearer(
            accessToken: Self.oldToken, refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(3_600)))

        let response = try await authenticator.authenticatedResponse(context)

        #expect(response.http.statusCode == 200)
        #expect(host.paths == ["/api/plugins/loopdy/native/context", "/auth/native/refresh",
                               "/api/plugins/loopdy/native/context"])
    }

    @Test func withNothingToRenewTheRejectionIsReturnedOnce() async throws {
        let host = try ScriptedHermes { _ in .status(401) }
        let authenticator = try authenticator(port: try await host.start(), .bearer(
            accessToken: Self.oldToken, refreshToken: nil, expiresAt: Date().addingTimeInterval(3_600)))

        let response = try await authenticator.authenticatedResponse(context)

        #expect(response.http.statusCode == 401)
        #expect(host.paths == ["/api/plugins/loopdy/native/context"])
    }

    @Test func otherFailuresAreNotRetried() async throws {
        let host = try ScriptedHermes { _ in .status(404) }
        let authenticator = try authenticator(port: try await host.start(),
                                              .dashboardSession(token: Self.oldToken, automatic: true))

        let response = try await authenticator.authenticatedResponse(context)

        #expect(response.http.statusCode == 404)
        #expect(host.paths == ["/api/plugins/loopdy/native/context"])
    }

    // MARK: Staying signed in (Nous Portal and other rotating sign-ins)

    private nonisolated static func renewed(_ refresh: String) -> ScriptedHermes.Reply {
        let expires = Int(Date().addingTimeInterval(3_600).timeIntervalSince1970)
        return .json("{\"token_type\":\"Bearer\",\"access_token\":\"\(newToken)\","
                     + "\"refresh_token\":\"\(refresh)\",\"provider\":\"basic\",\"user_id\":\"fixture\","
                     + "\"expires_at\":\(expires)}")
    }

    private static func refreshToken(_ saved: DirectHermesSavedConnection?) -> String? {
        guard case .bearer(_, let refresh, _)? = saved?.authentication else { return nil }
        return refresh
    }

    /// A bearer whose access token has run out, so the next request renews first.
    private func lapsed(port: UInt16, rotations: @escaping (DirectHermesSavedConnection) -> Void = { _ in })
        throws -> DirectHermesAuthenticator {
        try authenticator(port: port, .bearer(accessToken: Self.oldToken, refreshToken: "refresh-1",
                                              expiresAt: Date().addingTimeInterval(-60)), rotations: rotations)
    }

    /// Hermes answers 503 when the sign-in provider (the Portal) couldn't be reached: nothing
    /// was renewed, so the renewal token still works and must be kept, not signed out.
    @Test func aPortalOutageDuringRenewalKeepsTheSignIn() async throws {
        let calls = Counter()
        let host = try ScriptedHermes { request in
            guard request.path == "/auth/native/refresh" else { return .json("{}") }
            return calls.next() == 1 ? .status(503) : Self.renewed("refresh-2")
        }
        var rotated: [DirectHermesSavedConnection] = []
        let authenticator = try lapsed(port: try await host.start()) { rotated.append($0) }

        await #expect(throws: (any Error).self) { try await authenticator.authenticatedResponse(context) }
        let response = try await authenticator.authenticatedResponse(context)

        #expect(response.http.statusCode == 200)
        #expect(host.bodies.filter { $0.contains("refresh-1") }.count == 2, "The same renewal token, kept")
        #expect(Self.refreshToken(rotated.last) == "refresh-2", "The new renewal token is saved")
    }

    /// A renewal cut off before its answer arrived may or may not have happened. Hermes answers
    /// the same renewal token with the same new sign-in for 30 seconds, so sending it once more
    /// inside that window is safe and keeps the person signed in.
    @Test func aRenewalCutOffIsSentAgainWithinHermesSafeWindow() async throws {
        let calls = Counter()
        let host = try ScriptedHermes { request in
            guard request.path == "/auth/native/refresh" else { return .json("{}") }
            return calls.next() == 1 ? .drop : Self.renewed("refresh-2")
        }
        let authenticator = try lapsed(port: try await host.start())

        await #expect(throws: (any Error).self) { try await authenticator.authenticatedResponse(context) }
        let response = try await authenticator.authenticatedResponse(context)

        #expect(response.http.statusCode == 200)
        #expect(host.bodies.filter { $0.contains("refresh-1") }.count == 2)
    }

    /// After the window a resend could look like reuse to the Portal, which ends the whole sign-in.
    @Test func aRenewalCutOffIsNotResentAfterTheWindow() async throws {
        let host = try ScriptedHermes { request in
            request.path == "/auth/native/refresh" ? .drop : .json("{}")
        }
        let authenticator = try lapsed(port: try await host.start())
        var clock = Date()
        authenticator.now = { clock }

        await #expect(throws: (any Error).self) { try await authenticator.authenticatedResponse(context) }
        clock = clock.addingTimeInterval(31)
        await #expect(throws: DirectHermesError.authenticationRequired) {
            try await authenticator.authenticatedResponse(context)
        }
        #expect(host.paths.filter { $0 == "/auth/native/refresh" }.count == 1)
    }

    /// Leaving the app closes the connection; a renewal already on its way finishes first
    /// instead of being cut off (which used to leave the sign-in unusable).
    @Test func closingWaitsForARenewalOnItsWay() async throws {
        let host = try ScriptedHermes { request in
            request.path == "/auth/native/refresh" ? .after(0.6, Self.renewed("refresh-2")) : .json("{}")
        }
        let authenticator = try lapsed(port: try await host.start())
        let request = Task { try await authenticator.authenticatedResponse(context) }
        for _ in 0..<200 where !host.paths.contains("/auth/native/refresh") {
            try await Task.sleep(for: .milliseconds(10))
        }
        await authenticator.settlePendingRenewal(within: .seconds(5))
        authenticator.http.invalidate()
        #expect(Self.refreshToken(authenticator.savedConnection) == "refresh-2",
                "The renewal finished and its new token was kept")
        _ = try? await request.value
    }

    @Test func deviceAccessOnlyAsksForARestartWhenThePluginRouteIsMissing() {
        let restart = HostPluginFeatureSection.unreachableMessage(WorkspaceClientError.unavailable(.pluginRequired))
        let signIn = HostPluginFeatureSection.unreachableMessage(WorkspaceClientError.authenticationRequired)
        let quiet = HostPluginFeatureSection.unreachableMessage(WorkspaceClientError.transportUnavailable)

        #expect(restart.contains("restart the hermes serve process"))
        #expect(signIn.contains("Sign in to the host again"))
        #expect(!signIn.contains("restart"))
        #expect(quiet.contains("Check again in a moment"))
        #expect(!quiet.contains("restart"))
    }
}

/// A loopback stand-in for Hermes that answers each request from a script.
private final class ScriptedHermes: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        var body = ""
        func header(_ name: String) -> String? { headers[name] }
    }

    enum Reply {
        case status(Int)
        case json(String)
        case html(String)
        /// Hangs up without answering, like a connection cut off mid-request.
        case drop
        /// Answers after a pause.
        indirect case after(TimeInterval, Reply)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "bighelp.test.scripted-hermes")
    private let lock = NSLock()
    private let script: @Sendable (Request) -> Reply
    private var seen: [String] = []
    private var seenBodies: [String] = []
    private var started = false
    var paths: [String] { lock.withLock { seen } }
    var bodies: [String] { lock.withLock { seenBodies } }

    init(_ script: @escaping @Sendable (Request) -> Reply) throws {
        self.script = script
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    deinit { listener.cancel() }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    guard lock.withLock({ defer { started = true }; return !started }) else { return }
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    guard lock.withLock({ defer { started = true }; return !started }) else { return }
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                receive(connection, prefix: Data())
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, prefix: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
            guard error == nil, let data else { connection.cancel(); return }
            let buffer = prefix + data
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { connection.cancel() } else { receive(connection, prefix: buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let line = head.first?.split(separator: " ") ?? []
            guard line.count >= 2 else { connection.cancel(); return }
            var headers: [String: String] = [:]
            for field in head.dropFirst() {
                guard let colon = field.firstIndex(of: ":") else { continue }
                headers[field[..<colon].lowercased()] = field[field.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            // Wait for the whole body before answering.
            let expected = Int(headers["content-length"] ?? "0") ?? 0
            let received = buffer.count - end.upperBound
            guard received >= expected || complete else { receive(connection, prefix: buffer); return }
            let requestBody = String(decoding: buffer[end.upperBound...], as: UTF8.self)
            let path = String(line[1].split(separator: "?").first ?? "")
            lock.withLock { seen.append(path); seenBodies.append(requestBody) }
            answer(connection, script(Request(method: String(line[0]), path: path, headers: headers, body: requestBody)))
        }
    }

    private func answer(_ connection: NWConnection, _ reply: Reply) {
        let (status, type, body): (Int, String, String)
        switch reply {
        case .drop:
            connection.cancel()
            return
        case .after(let delay, let later):
            queue.asyncAfter(deadline: .now() + delay) { [self] in answer(connection, later) }
            return
        case .status(let code): (status, type, body) = (code, "application/json", "{\"detail\":\"fixture\"}")
        case .json(let text): (status, type, body) = (200, "application/json", text)
        case .html(let text): (status, type, body) = (200, "text/html; charset=utf-8", text)
        }
        let bytes = Data(body.utf8)
        let response = "HTTP/1.1 \(status) Fixture\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8) + bytes, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Counts calls from the test server's queue.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
