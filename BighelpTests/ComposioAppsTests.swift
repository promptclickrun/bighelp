import Foundation
import Testing
@testable import Bighelp

/// Composio Apps: the person's own Composio sign-in (OAuth with PKCE, kept in iCloud Keychain),
/// Composio Connect's connection tool, bighelp's catalog of Composio apps, and the plugin's
/// report of Composio in Hermes. The shapes come from Composio's and the plugin's real answers.
@MainActor
struct ComposioAppsTests {
    // MARK: Sign-in

    @Test func signInAsksForACodeWithPKCEForComposioConnect() throws {
        let verifier = ComposioOAuth.makeVerifier()
        #expect((43...128).contains(verifier.count))
        let url = ComposioOAuth.authorizeURL(clientID: "client-1", verifier: verifier, state: "state-1")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        #expect(url.host == "connect.composio.dev" && url.path == "/oauth/authorize")
        #expect(items["code_challenge"] == ComposioOAuth.challenge(for: verifier))
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["redirect_uri"] == "loopdy://composio-auth")
        #expect(items["resource"] == "https://connect.composio.dev/mcp")
        #expect(items["scope"]?.contains("offline_access") == true)
    }

    @Test func onlyThisSignInsReturnGivesACode() throws {
        let good = URL(string: "loopdy://composio-auth?code=abc123&state=s1")!
        #expect(try ComposioOAuth.code(from: good, state: "s1") == "abc123")
        #expect(throws: ComposioError.signInFailed) {
            try ComposioOAuth.code(from: URL(string: "loopdy://composio-auth?code=abc123&state=other")!, state: "s1")
        }
        #expect(throws: ComposioError.signInCancelled) {
            try ComposioOAuth.code(from: URL(string: "loopdy://composio-auth?error=access_denied&state=s1")!, state: "s1")
        }
        #expect(throws: ComposioError.signInFailed) {
            try ComposioOAuth.code(from: URL(string: "loopdy://elsewhere?code=abc123&state=s1")!, state: "s1")
        }
    }

    @Test func formBodiesEscapeEverythingButUnreservedCharacters() {
        #expect(ComposioOAuth.formBody(["a": "x+y=z&w", "b": "ok-._~"]) == "a=x%2By%3Dz%26w&b=ok-._~")
    }

    @Test func tokensDecodeWithTheEmailFromTheIDTokenAndNeverPrintThemselves() throws {
        let claims = ComposioOAuth.base64URL(Data(#"{"email":"alex@example.com"}"#.utf8))
        let body = Data(#"{"access_token":"at-1","token_type":"Bearer","expires_in":3600,"refresh_token":"rt-1","id_token":"h.\#(claims).s"}"#.utf8)
        let now = Date(timeIntervalSince1970: 1_000)
        let credential = try ComposioCredential.decode(body, clientID: "c1", previous: nil, now: now)
        #expect(credential.email == "alex@example.com")
        #expect(credential.accessExpiresAt == now.addingTimeInterval(3_600))
        #expect(!String(describing: credential).contains("at-1"))
        #expect(!String(reflecting: credential).contains("rt-1"))
        // A refresh that doesn't rotate the refresh token keeps the old one.
        let refreshed = try ComposioCredential.decode(Data(#"{"access_token":"at-2","token_type":"bearer"}"#.utf8),
                                                      clientID: "c1", previous: credential, now: now)
        #expect(refreshed.refreshToken == "rt-1" && refreshed.email == "alex@example.com")
    }

    @Test func anExpiredTokenIsRefreshedAndARefusedRefreshSignsOut() async throws {
        let vault = DemoComposioVault()
        try vault.save(ComposioCredential(clientID: "c1", accessToken: "old", refreshToken: "rt-1",
                                          accessExpiresAt: Date(timeIntervalSinceNow: -10), email: nil))
        let http = FakeComposioHTTP()
        http.answers = [(200, #"{"access_token":"new","token_type":"Bearer","expires_in":3600,"refresh_token":"rt-2"}"#)]
        let account = ComposioAccount(vault: vault, http: http)
        #expect(try await account.accessToken() == "new")
        #expect(vault.load()?.refreshToken == "rt-2", "The rotated token is saved")
        let form = String(data: http.requests.first?.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(form.contains("grant_type=refresh_token") && form.contains("refresh_token=rt-1"))

        http.answers = [(400, #"{"error":"invalid_grant"}"#)]
        await #expect(throws: ComposioError.signedOut) { try await account.tokenRejected() }
        #expect(!account.isSignedIn && vault.load() == nil)
    }

    // MARK: Composio Connect

    @Test func theConnectedAppsComeFromComposiosSearchToolDescription() {
        let description = "Tool Server Info: … \n- User has manually connected the apps: gmail, github, google_calendar. Prefer these apps when intent is unclear."
        #expect(ComposioConnectClient.connectedToolkits(inDescription: description) == ["gmail", "github", "google_calendar"])
        #expect(ComposioConnectClient.connectedToolkits(inDescription: "No apps yet.").isEmpty)
    }

    @Test func connectionListsReadAccountsAndEmails() throws {
        let data: [String: Any] = ["results": [
            "gmail": ["toolkit": "gmail", "status": "active", "accounts": [
                ["id": "gmail_abc-def", "status": "active", "is_default": true, "account_type": "PRIVATE",
                 "user_info": ["email": "alex@example.com"]],
            ]],
            "notion": ["toolkit": "notion", "status": "initiated", "accounts": [
                ["id": "notion_xyz", "status": "initiated", "is_default": true],
            ]],
            "Bad Slug": ["accounts": []],
        ]]
        let found = try ComposioConnectClient.connections(in: data)
        #expect(found["gmail"]?.isConnected == true)
        #expect(found["gmail"]?.accounts.first?.email == "alex@example.com")
        #expect(found["notion"]?.isConnected == false, "A sign-in that didn't finish isn't connected")
        #expect(found["Bad Slug"] == nil)
    }

    @Test func toolAnswersAndRPCMessagesReadFromJSONOrServerSentEvents() throws {
        let inner = #"{"successful":true,"data":{"results":{}},"error":null}"#
        let rpc: [String: Any] = ["jsonrpc": "2.0", "id": 7, "result": ["content": [["type": "text", "text": inner]]]]
        let json = try JSONSerialization.data(withJSONObject: rpc)
        let sse = Data("event: message\ndata: \(String(decoding: json, as: UTF8.self))\n\n".utf8)
        for body in [json, sse] {
            let result = try ComposioConnectClient.rpcMessage(body, id: 7)
            #expect(try ComposioConnectClient.toolData(result)["results"] != nil)
        }
        let refused: [String: Any] = ["content": [["type": "text", "text": #"{"successful":false,"data":null,"error":"Toolkit not found"}"#]]]
        #expect(throws: ComposioError.refused("Toolkit not found")) { try ComposioConnectClient.toolData(refused) }
    }

    // MARK: Catalog

    @Test func theCatalogKeepsGoodAppsAndDropsBadOnes() throws {
        let document: [String: Any] = [
            "schemaVersion": 1, "revision": "r1", "fetchedAt": "2026-10-16T00:00:00Z",
            "categories": [["id": "productivity", "name": "Productivity"], ["id": "unused", "name": "Unused"]],
            "toolkits": [
                ["slug": "gmail", "name": "Gmail", "description": "Email.", "logo": "https://logos.example.com/gmail.svg",
                 "categories": ["productivity", "unknown"], "noAuth": false],
                ["slug": "plain", "name": "Plain", "logo": "http://insecure.example.com/x.png", "categories": ["productivity"]],
                ["slug": "BAD", "name": "Bad"],
                ["slug": "gmail", "name": "Duplicate"],
            ],
        ]
        let catalog = try ComposioCatalog.decode(try JSONSerialization.data(withJSONObject: document))
        #expect(catalog.toolkits.map(\.slug) == ["gmail", "plain"])
        #expect(catalog.toolkits[0].categories == ["productivity"])
        #expect(catalog.toolkits[1].logoURL == nil, "Logos load over https only")
        #expect(catalog.categories.map(\.id) == ["productivity"], "Only categories in use")
        #expect(catalog.search("mail").map(\.slug) == ["gmail"])
    }

    // MARK: Hermes

    @Test func thePluginsReportSaysWhatTheAgentNeeds() throws {
        func status(_ servers: [BighelpJSONValue], connect: String?) throws -> ComposioAgentAccess {
            try ComposioAgentStatus.decode(["schemaVersion": .integer(1), "connect": connect.map(BighelpJSONValue.string) ?? .null,
                                            "servers": .array(servers)]).access
        }
        func server(_ name: String, enabled: Bool, signedIn: Bool?) -> BighelpJSONValue {
            .object(["name": .string(name), "url": .string("https://connect.composio.dev/mcp"), "enabled": .boolean(enabled),
                     "auth": .string("oauth"), "kind": .string("connect"),
                     "signedIn": signedIn.map(BighelpJSONValue.boolean) ?? .null])
        }
        #expect(try status([], connect: nil) == .notInstalled)
        #expect(try status([server("composio", enabled: false, signedIn: true)], connect: "composio") == .turnedOff(server: "composio"))
        #expect(try status([server("composio", enabled: true, signedIn: false)], connect: "composio") == .needsSignIn(server: "composio"))
        #expect(try status([server("composio", enabled: true, signedIn: nil)], connect: "composio") == .needsSignIn(server: "composio"))
        #expect(try status([server("composio", enabled: true, signedIn: true)], connect: "composio") == .ready(server: "composio"))
    }

    // MARK: The screen's model, on the demo

    @Test func connectingAnAppWaitsForTheNewAccountThenClosesThePage() async throws {
        let model = DemoComposio.model()
        await model.appear()
        #expect(model.connectedApps.map(\.slug) == ["github", "gmail"])
        #expect(try #require(await model.startConnect("slack")).host == "example.com")
        #expect(model.openSignIn?.slug == "slack", "The page stays open while Composio waits")
        await model.checkSignIn()
        #expect(model.openSignIn != nil, "Coming back to bighelp only looks; it doesn't end the sign-in")
        #expect(await model.waitForSignIn(), "The new account closes the page")
        #expect(model.isConnected("slack") && model.openSignIn == nil)
        #expect(model.connectedApps.first?.slug == "slack")
        let account = try #require(model.connections["gmail"]?.accounts.first)
        await model.remove("gmail", account: account.id)
        #expect(!model.isConnected("gmail"))
    }

    /// Closing the page before the sign-in finishes removes the pending account Composio made,
    /// so unfinished tries don't pile up in the person's Composio account.
    @Test func closingThePageEarlyRemovesThePendingAccount() async throws {
        let connect = DemoComposioConnect()
        let model = DemoComposio.model(connect: connect)
        await model.appear()
        _ = try #require(await model.startConnect("calendly"))
        let pending = try #require(model.openSignIn?.pendingAccountID)
        await model.signInPageClosed()
        #expect(connect.removed == [pending])
        #expect(!model.isConnected("calendly") && model.openSignIn == nil)
        #expect(model.connections["calendly"]?.accounts.isEmpty ?? true)
    }

    /// Composio's `add` answer: the page, the account that waits on it, or Composio's reason.
    @Test func connectAnswersGiveThePageAndPendingAccountOrComposiosReason() throws {
        let started = try ComposioConnectClient.connectStart(in: ["results": ["one_drive": [
            "toolkit": "one_drive", "status": "initiated", "redirect_url": "https://connect.composio.dev/link/lk_example",
            "accounts": [["id": "one_drive_old", "status": "active"], ["id": "one_drive_new", "status": "initiated"]],
        ]]], toolkit: "one_drive")
        #expect(started.url.absoluteString == "https://connect.composio.dev/link/lk_example")
        #expect(started.pendingAccountID == "one_drive_new")
        #expect(throws: ComposioError.refused("This app needs a paid plan.")) {
            try ComposioConnectClient.connectStart(in: ["results": ["one_drive": [
                "toolkit": "one_drive", "status": "failed", "instruction": "This app needs a paid plan.",
            ]]], toolkit: "one_drive")
        }
        #expect(ComposioConnectClient.errorText(#"{"successful":false,"error":"Toolkit one_drive is not enabled"}"#)
            == "Toolkit one_drive is not enabled")
        #expect(ComposioConnectClient.errorText("Rate limited") == "Rate limited")
    }

    @Test func signingInAndTurningOnForTheAgent() async throws {
        let model = DemoComposio.model(signedIn: false)
        await model.appear()
        #expect(!model.account.isSignedIn && model.agent == .notInstalled)
        await model.signIn()
        #expect(model.account.email == "alex@example.com")
        #expect(model.connectedApps.map(\.slug) == ["github", "gmail"])
        let flow = try #require(await model.turnOnForAgent { _ in })
        await model.finishAgentSignIn(flow)
        #expect(model.agent == .ready(server: "composio"))
        model.signOut()
        #expect(!model.account.isSignedIn && model.connectedApps.isEmpty)
    }
}

/// Answers Composio requests in order, keeping what was sent.
final class FakeComposioHTTP: ComposioHTTP, @unchecked Sendable {
    var answers: [(Int, String)] = []
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = answers.isEmpty ? (500, "{}") : answers.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
