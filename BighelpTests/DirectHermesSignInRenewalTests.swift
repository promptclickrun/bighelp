import Foundation
import Security
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

    // MARK: Renewing while bighelp is closed

    private func saved(port: UInt16, refresh: String?) throws -> DirectHermesSavedConnection {
        let endpoint = try DirectHermesEndpoint(address: "http://127.0.0.1:\(port)", allowPrivateHTTP: true)
        return DirectHermesSavedConnection(endpoint: endpoint, authentication: .bearer(
            accessToken: Self.oldToken, refreshToken: refresh, expiresAt: Date().addingTimeInterval(3_600)),
            provider: "basic", userID: "fixture")
    }

    /// The host's plugin wakes the phone every few hours with a quiet push, so a rotating
    /// sign-in (the Nous Portal's lasts a day) is renewed even if bighelp stays closed.
    @Test func aWakeRenewsTheSavedSignInWithoutConnecting() async throws {
        let host = try ScriptedHermes { request in
            request.path == "/auth/native/refresh" ? Self.renewed("refresh-2") : .status(500)
        }
        let vault = MemoryVault(try saved(port: try await host.start(), refresh: "refresh-1"))
        let store = DirectHermesWorkspaceStore(vault: vault)

        #expect(await store.renewSignInWhileAway())

        #expect(host.paths == ["/auth/native/refresh"])
        #expect(Self.refreshToken(vault.stored) == "refresh-2", "The new sign-in is saved for next time")
    }

    @Test func aWakeLeavesASignInWithNothingToRenewAlone() async throws {
        let host = try ScriptedHermes { _ in .status(500) }
        let saved = try saved(port: try await host.start(), refresh: nil)
        let vault = MemoryVault(saved)

        #expect(await !DirectHermesWorkspaceStore(vault: vault).renewSignInWhileAway())
        #expect(await !DirectHermesWorkspaceStore(vault: MemoryVault(nil)).renewSignInWhileAway())

        #expect(host.paths.isEmpty)
        #expect(vault.stored == saved)
    }

    @Test func theRenewalWakeIsAQuietPushTheWakeCenterAnswers() async {
        let grant = "11111111-1111-4111-8111-111111111111"
        let wake: [AnyHashable: Any] = [
            "aps": ["content-available": 1],
            "bighelp_wake": ["version": 1, "type": "renew-sign-in", "grantId": grant],
        ]
        #expect(BighelpSignInWake.isRenewal(wake))
        #expect(!BighelpSignInWake.isRenewal(["aps": ["alert": ["body": "x"], "content-available": 1],
                                               "bighelp_wake": ["version": 1, "type": "renew-sign-in"]]))
        #expect(!BighelpSignInWake.isRenewal(["aps": ["content-available": 1],
                                               "bighelp_wake": ["version": 2, "type": "renew-sign-in"]]))
        #expect(!BighelpSignInWake.isRenewal(["aps": ["content-available": 1],
                                               "bighelp_wake": ["version": 1, "type": "other"]]))

        let center = BighelpLinkWakeCenter()
        var wakes = 0
        center.install { wakes += 1; return true }
        #expect(await center.receive(wake) == .newData)
        #expect(wakes == 1)
    }

    /// A wake can arrive while the phone is locked, so a saved sign-in must be readable then.
    /// One saved by an older build (readable only while unlocked) moves over when it's next read.
    @Test func savedSignInsCanBeRenewedWhileThePhoneIsLocked() throws {
        let service = "app.loopdy.direct-test.locked-" + UUID().uuidString
        let saved = try saved(port: 9, refresh: "refresh-1")
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: "host",
                                   kSecAttrSynchronizable as String: false]
        defer { SecItemDelete(base as CFDictionary) }
        var older = base
        older[kSecValueData as String] = try JSONEncoder().encode(saved)
        older[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #expect(SecItemAdd(older as CFDictionary, nil) == errSecSuccess)
        func accessibility() -> String? {
            var query = base
            query[kSecReturnAttributes as String] = true
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
            return (result as? [String: Any])?[kSecAttrAccessible as String] as? String
        }

        let vault = DirectHermesKeychainVault(service: service, account: "host")
        #expect(try vault.load() == saved)
        #expect(accessibility() == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        try vault.save(saved)
        #expect(accessibility() == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
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

/// Counts calls from the test server's queue.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

@MainActor
final class MemoryVault: DirectHermesCredentialVault {
    private(set) var stored: DirectHermesSavedConnection?
    init(_ stored: DirectHermesSavedConnection?) { self.stored = stored }
    func load() throws -> DirectHermesSavedConnection? { stored }
    func save(_ connection: DirectHermesSavedConnection) throws { stored = connection }
    func delete() throws { stored = nil }
}
