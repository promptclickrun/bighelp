import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesAccessCredentialsTests {
    private let id = "0123456789abcdef.access"
    private let secret = String(repeating: "f", count: 64)

    @Test func serviceTokensAreHeaderSafe() throws {
        let token = try DirectHermesAccessCredentials(clientID: " \(id)\n", clientSecret: secret)
        #expect(token.headers == ["CF-Access-Client-Id": id, "CF-Access-Client-Secret": secret])
        for bad in ["", "has space", "line\nbreak", String(repeating: "a", count: 513), "émoji"] {
            #expect(throws: DirectHermesError.invalidAccessCredentials) {
                try DirectHermesAccessCredentials(clientID: bad, clientSecret: secret)
            }
        }
    }

    @Test func proxyPasswordsBecomeABasicAuthHeader() throws {
        let login = try DirectHermesAccessCredentials(username: " tester ", password: "bh proxy pass 1")
        #expect(login.kind == .basic)
        #expect(login.headers == ["Authorization": "Basic " + Data("tester:bh proxy pass 1".utf8).base64EncodedString()])
        for (user, password) in [("", "x"), ("a:b", "x"), ("tester", ""), ("line\nbreak", "x"), ("tester", "tab\tpass")] {
            #expect(throws: DirectHermesError.invalidAccessCredentials) {
                try DirectHermesAccessCredentials(username: user, password: password)
            }
        }
    }

    @Test func proxyPasswordsGoToPrivateHTTPButNeverToThePublicInternetInPlainHTTP() throws {
        let store = DirectHermesAccessCredentialStore(service: "app.loopdy.mobile.tests.cloudflare-access-\(UUID().uuidString)")
        let login = try DirectHermesAccessCredentials(username: "tester", password: "secret")
        let vpn = try DirectHermesEndpoint(address: "http://10.8.0.5:9119", allowPrivateHTTP: true)
        store.stage(login, for: vpn)
        #expect(store.headers(for: vpn)["Authorization"]?.hasPrefix("Basic ") == true)
        let secure = try DirectHermesEndpoint(address: "https://hermes.example.com")
        store.stage(login, for: secure)
        #expect(store.credentials(for: secure) == login)
        // Plain HTTP to a public address can't even be entered as a host.
        #expect(throws: (any Error).self) { try DirectHermesEndpoint(address: "http://hermes.example.com", allowPrivateHTTP: true) }
    }

    @Test func tokensSavedBeforeBasicAuthStillLoadAsCloudflareAccess() throws {
        let old = Data(#"{"clientID":"0123456789abcdef.access","clientSecret":"ffff"}"#.utf8)
        let decoded = try JSONDecoder().decode(DirectHermesAccessCredentials.self, from: old)
        #expect(decoded.kind == .cloudflareAccess)
        let login = try DirectHermesAccessCredentials(username: "tester", password: "has spaces ")
        let roundTrip = try JSONDecoder().decode(DirectHermesAccessCredentials.self, from: JSONEncoder().encode(login))
        #expect(roundTrip == login)
    }

    @Test func discoveryTellsAPasswordProxyFromOtherBlocks() {
        #expect(HostAuthenticationDiscovery.gate(challenge: #"Basic realm="restricted""#) == .passwordProxy)
        #expect(HostAuthenticationDiscovery.gate(challenge: "basic") == .passwordProxy)
        #expect(HostAuthenticationDiscovery.gate(challenge: "Bearer") == .blocked)
        #expect(HostAuthenticationDiscovery.gate(challenge: nil) == .blocked)
    }

    @Test func aStagedTokenIsUsedButOnlySavedAfterConnecting() throws {
        let store = DirectHermesAccessCredentialStore(service: "app.loopdy.mobile.tests.cloudflare-access-\(UUID().uuidString)")
        let endpoint = try DirectHermesEndpoint(address: "https://hermes-\(UUID().uuidString.prefix(8).lowercased()).example.com")
        defer { store.remove(for: endpoint) }
        let token = try DirectHermesAccessCredentials(clientID: id, clientSecret: secret)
        store.stage(token, for: endpoint)
        #expect(store.credentials(for: endpoint) == token)
        #expect(!store.hasSavedCredentials(for: endpoint))
        try store.commitStaged(for: endpoint)
        #expect(store.hasSavedCredentials(for: endpoint))
        // A fresh store (next launch) reads it back from Keychain.
        let relaunched = DirectHermesAccessCredentialStore(service: store.serviceForTesting)
        #expect(relaunched.credentials(for: endpoint) == token)
        store.remove(for: endpoint)
        #expect(!store.hasSavedCredentials(for: endpoint))
        #expect(store.credentials(for: endpoint) == nil)
    }

    /// iOS wakes bighelp while the phone is locked (widget refresh, a sign-in renewal push). A read that
    /// fails then must not count as "none saved" for the rest of the run, or every request after unlocking
    /// goes without the token and Access turns it away.
    @Test func aTokenUnreadableWhileLockedIsReadAgainOnceUnlocked() throws {
        let store = DirectHermesAccessCredentialStore(service: "app.loopdy.mobile.tests.cloudflare-access-\(UUID().uuidString)")
        let endpoint = try DirectHermesEndpoint(address: "https://hermes-\(UUID().uuidString.prefix(8).lowercased()).example.com")
        defer { store.remove(for: endpoint) }
        try store.replace(access: DirectHermesAccessCredentials(clientID: id, clientSecret: secret),
                          customHeaders: DirectHermesCustomHeader.list([("X-Access-Id", "id-1")]), for: endpoint)

        let woken = DirectHermesAccessCredentialStore(service: store.serviceForTesting)
        woken.keychainLockedForTesting = true
        #expect(woken.headers(for: endpoint).isEmpty)
        woken.keychainLockedForTesting = false
        #expect(woken.headers(for: endpoint)
            == ["X-Access-Id": "id-1", "CF-Access-Client-Id": id, "CF-Access-Client-Secret": secret])
    }

    /// Like the sign-in, saved items are readable after the phone's first unlock. Items from older builds
    /// (readable only while unlocked) move over when they're next read.
    @Test func savedTokensAndHeadersCanBeReadWhileThePhoneIsLocked() throws {
        let service = "app.loopdy.mobile.tests.cloudflare-access-\(UUID().uuidString)"
        let headerService = service + ".custom-headers"
        let store = DirectHermesAccessCredentialStore(service: service)
        let older = try DirectHermesEndpoint(address: "https://hermes-\(UUID().uuidString.prefix(8).lowercased()).example.com")
        let newer = try DirectHermesEndpoint(address: "https://hermes-\(UUID().uuidString.prefix(8).lowercased()).example.com")
        defer { store.remove(for: older); store.remove(for: newer) }
        let token = try DirectHermesAccessCredentials(clientID: id, clientSecret: secret)
        func item(_ service: String, _ endpoint: DirectHermesEndpoint) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
             kSecAttrAccount as String: endpoint.identity, kSecAttrSynchronizable as String: false]
        }
        func accessibility(_ service: String, _ endpoint: DirectHermesEndpoint) -> String? {
            var query = item(service, endpoint)
            query[kSecReturnAttributes as String] = true
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
            return (result as? [String: Any])?[kSecAttrAccessible as String] as? String
        }
        let afterFirstUnlock = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        for (service, data) in [(service, try JSONEncoder().encode(token)),
                                (headerService, try JSONEncoder().encode([["X-Access-Id", "id-1"]]))] {
            var saved = item(service, older)
            saved[kSecValueData as String] = data
            saved[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            #expect(SecItemAdd(saved as CFDictionary, nil) == errSecSuccess)
        }

        #expect(store.headers(for: older)["CF-Access-Client-Id"] == id)
        #expect(store.headers(for: older)["X-Access-Id"] == "id-1")
        #expect(accessibility(service, older) == afterFirstUnlock)
        #expect(accessibility(headerService, older) == afterFirstUnlock)

        try store.replace(access: token, customHeaders: DirectHermesCustomHeader.list([("X-Access-Id", "id-2")]), for: newer)
        #expect(accessibility(service, newer) == afterFirstUnlock)
        #expect(accessibility(headerService, newer) == afterFirstUnlock)
    }

    @Test func tokensNeverGoOverPlainHTTP() throws {
        let store = DirectHermesAccessCredentialStore(service: "app.loopdy.mobile.tests.cloudflare-access-\(UUID().uuidString)")
        let endpoint = try DirectHermesEndpoint(address: "http://10.8.0.5:9119", allowPrivateHTTP: true)
        store.stage(try DirectHermesAccessCredentials(clientID: id, clientSecret: secret), for: endpoint)
        #expect(store.headers(for: endpoint).isEmpty)
    }

    @Test func everyHostRequestAndSocketCarriesTheToken() throws {
        let endpoint = try DirectHermesEndpoint(address: "https://hermes-\(UUID().uuidString.prefix(8).lowercased()).example.com")
        let shared = DirectHermesAccessCredentialStore.shared
        shared.stage(try DirectHermesAccessCredentials(clientID: id, clientSecret: secret), for: endpoint)
        defer { shared.stage(nil, for: endpoint) }
        let http = DirectHermesHTTP(endpoint: endpoint)
        defer { http.invalidate() }
        let session = http.session.configuration.httpAdditionalHeaders as? [String: String]
        #expect(session?["CF-Access-Client-Id"] == id)
        #expect(session?["CF-Access-Client-Secret"] == secret)
        var socket = URLRequest(url: URL(string: "wss://example.com/api/ws")!)
        http.applyAccessHeaders(to: &socket)
        #expect(socket.value(forHTTPHeaderField: "CF-Access-Client-Id") == id)
        // Hosts without a token send nothing extra.
        let plain = DirectHermesHTTP(endpoint: try DirectHermesEndpoint(address: "https://other.example.com"))
        defer { plain.invalidate() }
        #expect(plain.accessHeaders.isEmpty)
    }

    // MARK: Custom headers (issue #1)

    @Test func customHeadersAreValidatedAndReservedNamesRefused() throws {
        let header = try DirectHermesCustomHeader(name: " X-Access-Id ", value: " abc123 ")
        #expect(header.name == "X-Access-Id" && header.value == "abc123")
        for reserved in ["Authorization", "cookie", "Host", "Sec-WebSocket-Key", "X-Hermes-Session-Token",
                         "X-Loopdy-Request-ID", "CF-Access-Client-Id", "Content-Type"] {
            #expect(throws: DirectHermesCustomHeader.Problem.reserved(reserved)) {
                try DirectHermesCustomHeader(name: reserved, value: "x")
            }
        }
        #expect(throws: DirectHermesCustomHeader.Problem.invalidName("Bad Name")) {
            try DirectHermesCustomHeader(name: "Bad Name", value: "x")
        }
        #expect(throws: DirectHermesCustomHeader.Problem.invalidValue("X-Id")) {
            try DirectHermesCustomHeader(name: "X-Id", value: "line\nbreak")
        }
        #expect(throws: DirectHermesCustomHeader.Problem.duplicate("x-id")) {
            try DirectHermesCustomHeader.list([("X-Id", "a"), ("x-id", "b")])
        }
        // Blank rows are ignored.
        #expect(try DirectHermesCustomHeader.list([("", ""), ("X-Id", "a")]).map(\.name) == ["X-Id"])
        #expect(throws: DirectHermesCustomHeader.Problem.tooMany) {
            try DirectHermesCustomHeader.list((0..<17).map { ("X-H\($0)", "v") })
        }
    }

    @Test func customHeadersAreSavedPerAddressAndSentAlongsideTheToken() throws {
        let store = DirectHermesAccessCredentialStore(service: "app.loopdy.mobile.tests.cloudflare-access-\(UUID().uuidString)")
        let endpoint = try DirectHermesEndpoint(address: "https://hermes-\(UUID().uuidString.prefix(8).lowercased()).example.com")
        let other = try DirectHermesEndpoint(address: "https://other-\(UUID().uuidString.prefix(8).lowercased()).example.com")
        defer { store.remove(for: endpoint) }
        let headers = try DirectHermesCustomHeader.list([("X-Access-Id", "id-1"), ("X-Access-Secret", "s3cret")])
        store.stageCustomHeaders(headers, for: endpoint)
        store.stage(try DirectHermesAccessCredentials(clientID: id, clientSecret: secret), for: endpoint)
        #expect(store.savedCustomHeaders(for: endpoint).isEmpty, "Staged, not saved, until the connection works")
        let sent = store.headers(for: endpoint)
        #expect(sent["X-Access-Id"] == "id-1" && sent["X-Access-Secret"] == "s3cret" && sent["CF-Access-Client-Id"] == id)
        #expect(store.headers(for: other).isEmpty, "Never to another address")
        try store.commitStaged(for: endpoint)
        let relaunched = DirectHermesAccessCredentialStore(service: store.serviceForTesting)
        #expect(relaunched.customHeaders(for: endpoint) == headers)
        // Editing a saved host replaces both at once; removing clears everything.
        try relaunched.replace(access: nil, customHeaders: [headers[0]], for: endpoint)
        #expect(DirectHermesAccessCredentialStore(service: store.serviceForTesting).headers(for: endpoint) == ["X-Access-Id": "id-1"])
        relaunched.remove(for: endpoint)
        #expect(DirectHermesAccessCredentialStore(service: store.serviceForTesting).headers(for: endpoint).isEmpty)
    }

    @Test func customHeadersStayOffThePublicInternetInPlainHTTP() throws {
        let store = DirectHermesAccessCredentialStore(service: "app.loopdy.mobile.tests.cloudflare-access-\(UUID().uuidString)")
        let vpn = try DirectHermesEndpoint(address: "http://10.8.0.5:9119", allowPrivateHTTP: true)
        let headers = try DirectHermesCustomHeader.list([("X-Access-Id", "id-1")])
        store.stageCustomHeaders(headers, for: vpn)
        #expect(store.headers(for: vpn) == ["X-Access-Id": "id-1"], "A private network the person allowed")
        #expect(DirectHermesAccessCredentialStore.mayCarrySecrets(vpn))
    }

    @Test func everyHostRequestAndSocketCarriesCustomHeaders() throws {
        let endpoint = try DirectHermesEndpoint(address: "https://hermes-\(UUID().uuidString.prefix(8).lowercased()).example.com")
        let shared = DirectHermesAccessCredentialStore.shared
        shared.stageCustomHeaders(try DirectHermesCustomHeader.list([("X-Pangolin-Id", "abc")]), for: endpoint)
        defer { shared.stageCustomHeaders(nil, for: endpoint) }
        let http = DirectHermesHTTP(endpoint: endpoint)
        defer { http.invalidate() }
        #expect((http.session.configuration.httpAdditionalHeaders as? [String: String])?["X-Pangolin-Id"] == "abc")
        var socket = URLRequest(url: URL(string: "wss://example.com/api/ws")!)
        http.applyAccessHeaders(to: &socket)
        #expect(socket.value(forHTTPHeaderField: "X-Pangolin-Id") == "abc")
    }

    @Test func cloudflareAccessRefusalsAreRecognized() throws {
        func response(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://hermes.example.com/api/status")!, statusCode: status,
                            httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        let login = response(302, ["Location": "https://team.cloudflareaccess.com/cdn-cgi/access/login/hermes.example.com"])
        #expect(DirectHermesHTTP.isCloudflareAccessDenial(login, sentAccessToken: false))
        let block = response(403, ["Content-Type": "text/html; charset=UTF-8", "CF-RAY": "8a1b2c3d4e5f-DFW"])
        #expect(DirectHermesHTTP.isCloudflareAccessDenial(block, sentAccessToken: true))
        // Hermes' own JSON errors and ordinary redirects are not Access.
        #expect(!DirectHermesHTTP.isCloudflareAccessDenial(response(403, ["Content-Type": "application/json", "CF-RAY": "x"]), sentAccessToken: true))
        #expect(!DirectHermesHTTP.isCloudflareAccessDenial(block, sentAccessToken: false))
        #expect(!DirectHermesHTTP.isCloudflareAccessDenial(response(302, ["Location": "https://evilcloudflareaccess.com/"]), sentAccessToken: true))
    }
}
