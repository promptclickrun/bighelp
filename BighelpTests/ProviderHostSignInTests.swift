import Foundation
import Testing
@testable import Bighelp

/// Accounts that only sign in from a terminal on the host sign in from the
/// phone when the plugin can run the provider's own tool there.
@MainActor
struct ProviderHostSignInTests {
    // MARK: Plugin answers

    @Test func readsEachSignInStateAndDropsWhatItCantTrust() {
        let providers = HostSignInCodec.providers(["providers": .array([
            .object(["providerId": .string("claude-code"), "name": .string("Claude Code"), "client": .string("Claude Code"),
                     "flow": .string("paste"), "state": .string("ready"), "signedIn": .boolean(false),
                     "docsURL": .string("https://example.com/claude")]),
            .object(["providerId": .string("copilot-acp"), "name": .string("GitHub Copilot (ACP)"),
                     "client": .string("GitHub Copilot CLI"), "flow": .string("device"), "state": .string("notInstalled"),
                     "installCommand": .string("npm install -g @github/copilot"), "docsURL": .string("http://example.com")]),
            .object(["providerId": .string("qwen-oauth"), "name": .string("Qwen OAuth"), "state": .string("retired"),
                     "message": .string("Qwen ended it."), "replacementKey": .string("DASHSCOPE_API_KEY")]),
            .object(["providerId": .string("future"), "state": .string("somethingNew")]),
            .object(["providerId": .string("../bad"), "state": .string("ready")]),
            .object(["providerId": .string("sneaky"), "state": .string("notInstalled"),
                     "installCommand": .string("npm i x\nrm -rf ~")]),
        ])])
        #expect(providers.map(\.providerID) == ["claude-code", "copilot-acp", "qwen-oauth", "sneaky"])
        #expect(providers[0].state == .ready(signedIn: false))
        #expect(providers[0].flow == .paste)
        #expect(providers[0].documentationURL == URL(string: "https://example.com/claude"))
        #expect(providers[1].state == .notInstalled(installCommand: "npm install -g @github/copilot"))
        #expect(providers[1].documentationURL == nil, "Only https links")
        #expect(providers[2].state == .retired(message: "Qwen ended it.", replacementKey: "DASHSCOPE_API_KEY"))
        #expect(providers[2].client == "Qwen OAuth")
        #expect(providers[3].state == .notInstalled(installCommand: nil), "A command must be one line")
    }

    @Test func readsSessionsSafely() throws {
        let id = UUID().uuidString.lowercased()
        let session = try HostSignInCodec.session([
            "sessionId": .string(id), "providerId": .string("copilot-acp"), "flow": .string("device"),
            "status": .string("waiting"), "link": .string("https://github.com/login/device"), "code": .string("WDJB-MJHT"),
        ])
        #expect(session.status == .waiting)
        #expect(session.link == URL(string: "https://github.com/login/device"))
        #expect(session.code == "WDJB-MJHT")
        #expect(session.isRunning)
        let odd = try HostSignInCodec.session([
            "sessionId": .string(id), "providerId": .string("x"), "status": .string("teleporting"),
            "link": .string("http://github.com/login/device"), "code": .string("has space"),
        ])
        #expect(odd.status == .failed, "An unknown status ends the sign-in instead of waiting forever")
        #expect(odd.link == nil)
        #expect(odd.code == nil)
        #expect(throws: WorkspaceClientError.invalidResponse) {
            try HostSignInCodec.session(["sessionId": .string("nope"), "providerId": .string("x")])
        }
    }

    // MARK: Provider Keys overview

    private func account(_ id: String, _ name: String, loggedIn: Bool = false,
                         flow: DirectHermesOAuthProvider.Flow = .external) -> DirectHermesOAuthProvider {
        .init(id: id, name: name, flow: flow, documentationURL: nil, canDisconnect: true, disconnectHint: nil,
              cliCommand: "hermes auth add \(id)",
              status: .init(isLoggedIn: loggedIn, source: nil, sourceLabel: nil, expiresAt: nil, hasRefreshToken: false,
                            isFreeTier: nil, accountTier: nil, errorMessage: nil))
    }

    private func host(_ id: String, _ client: String, _ state: HostSignInProvider.State,
                      flow: HostSignInFlow = .paste) -> HostSignInProvider {
        .init(providerID: id, name: id, client: client, flow: flow, state: state, documentationURL: nil)
    }

    private func overview(_ accounts: [DirectHermesOAuthProvider], _ hosts: [HostSignInProvider]) -> ProviderKeysOverview {
        ProviderKeysOverview(snapshot: .init(providers: [], credentials: [], oauthProviders: accounts, customEndpoints: [],
                                             credentialPools: [], setup: nil, runtime: nil, portal: nil),
                             hostSignIns: hosts)
    }

    @Test func terminalOnlyAccountsSignInOnThePhoneWhenTheHostCan() {
        let result = overview([
            account("qwen-oauth", "Qwen"),
            account("copilot-acp", "GitHub Copilot (ACP)"),
            account("unknown-cli", "Some CLI"),
            account("claude-code", "Claude Code"),
            account("nous", "Nous Portal", flow: .deviceCode),
        ], [
            host("claude-code", "Claude Code", .ready(signedIn: false)),
            host("copilot-acp", "GitHub Copilot CLI", .notInstalled(installCommand: "npm install -g @github/copilot"),
                 flow: .device),
            host("qwen-oauth", "Qwen Code", .retired(message: "Ended.", replacementKey: "DASHSCOPE_API_KEY")),
            // The plugin lists only providers this Hermes has, including ones it doesn't show as accounts.
            host("key-only", "Tool", .ready(signedIn: nil)),
        ])
        #expect(result.signIns.map(\.id) == ["claude-code", "nous", "key-only", "copilot-acp", "unknown-cli", "qwen-oauth"])
        #expect(result.signIns[0].method == .withHostTool(client: "Claude Code", flow: .paste))
        #expect(result.signIns[2].method == .withHostTool(client: "Tool", flow: .paste))
        #expect(result.signIns[3].method == .needsTool(client: "GitHub Copilot CLI",
                                                       install: "npm install -g @github/copilot",
                                                       command: "hermes auth add copilot-acp"))
        #expect(result.signIns[4].method == .onComputer(command: "hermes auth add unknown-cli"))
        #expect(result.signIns[5].method == .retired(message: "Ended.", replacementKey: "DASHSCOPE_API_KEY"))
    }

    @Test func theToolsOwnLoginCheckWinsOverHermesGuess() {
        let result = overview([
            account("claude-subscription-directsdk-experimental", "DirectSDK", loggedIn: true),
            account("claude-code", "Claude Code"),
        ], [
            host("claude-subscription-directsdk-experimental", "Claude Code", .ready(signedIn: false)),
            host("claude-code", "Claude Code", .ready(signedIn: true)),
        ])
        #expect(result.signIns.map(\.id) == ["claude-subscription-directsdk-experimental"])
        #expect(result.connected.map(\.name) == ["Claude Code"])
        #expect(result.connected[0].detail == "Signed in with Claude Code")
        #expect(result.connected[0].kind == .account(providerID: "claude-code", canDisconnect: false,
                                                     hint: "Sign out with Claude Code on the computer."))
    }

    @Test func gitHubCopilotSignsInThoughHermesKeepsItAsAKey() {
        func overview(signedIn: Bool?, tokenSaved: Bool) -> ProviderKeysOverview {
            let token = DirectHermesProviderCredential(
                id: "COPILOT_GITHUB_TOKEN", providerID: "copilot", providerName: "GitHub Copilot", description: "",
                category: "provider", isSet: tokenSaved, isSecret: true, isAdvanced: false, isCustom: false,
                isChannelManaged: false)
            return ProviderKeysOverview(
                snapshot: .init(providers: [], credentials: [token], oauthProviders: [account("copilot-acp", "ACP")],
                                customEndpoints: [], credentialPools: [], setup: nil, runtime: nil, portal: nil),
                hostSignIns: [.init(providerID: "copilot", name: "GitHub Copilot", client: "Hermes", flow: .device,
                                    state: .ready(signedIn: signedIn), documentationURL: nil)])
        }
        let signedOut = overview(signedIn: false, tokenSaved: false)
        #expect(signedOut.signIns.first?.id == "copilot")
        #expect(signedOut.signIns.first?.method == .withHostTool(client: "Hermes", flow: .device))
        #expect(signedOut.connected.isEmpty)
        let withToken = overview(signedIn: true, tokenSaved: true)
        #expect(!withToken.signIns.contains { $0.id == "copilot" })
        #expect(withToken.connected.map(\.id) == ["key:COPILOT_GITHUB_TOKEN"], "The token row shows it, once")
        let viaGitHubCLI = overview(signedIn: true, tokenSaved: false)
        #expect(viaGitHubCLI.connected.map(\.id) == ["account:copilot"])
        #expect(viaGitHubCLI.connected.first?.detail == "Signed in")
    }

    // MARK: Signing in

    @Test func aDeviceSignInFinishesOnItsOwnAndReloadsProviderKeys() async throws {
        let client = FakeHostSignInClient(flow: .device)
        let store = ProviderHostSignInStore(profileID: "default", hostName: "Test Mac", client: client,
                                            pollInterval: .milliseconds(20))
        var reloads = 0
        store.onSignedIn = { reloads += 1 }
        await store.load()
        #expect(store.isSupported)
        #expect(await store.start(providerID: "copilot-acp"))
        #expect(store.session?.status == .waiting)
        #expect(store.session?.code == "WDJB-MJHT")
        try await waitUntil { store.session?.status == .signedIn && reloads == 1 }
        #expect(client.calls.first(where: { $0.hasPrefix("status") }) != nil)
    }

    @Test func aPasteSignInSendsThePagesCode() async throws {
        let client = FakeHostSignInClient(flow: .paste)
        let store = ProviderHostSignInStore(profileID: "default", hostName: "Test Mac", client: client,
                                            pollInterval: .milliseconds(20))
        await store.start(providerID: "claude-code")
        #expect(store.session?.status == .needsCode)
        await store.submit(code: "  page#code \n")
        #expect(client.calls.contains("submit:page#code"))
        try await waitUntil { store.session?.status == .signedIn }
    }

    @Test func refusalsAreSaidInPlainWords() async {
        let client = FakeHostSignInClient(flow: .paste)
        let store = ProviderHostSignInStore(profileID: "default", hostName: "Test Mac", client: client)
        await store.load()
        client.startError = .rejected(code: "sign_in_tool_missing")
        #expect(await store.start(providerID: "claude-code") == false)
        #expect(store.errorMessage == "Claude Code isn't installed on Test Mac.")
        client.startError = .unavailable(.unsupportedOperation)
        await store.start(providerID: "claude-code")
        #expect(store.errorMessage == "Update the Bighelp plugin on Test Mac to sign in from your phone.")
        client.listError = .unavailable(.pluginRequired)
        await store.load()
        #expect(!store.isSupported)
        #expect(store.providers.isEmpty)
    }

    @Test func closingTheSheetStopsARunningSignIn() async {
        let client = FakeHostSignInClient(flow: .device, approvesAfter: 1_000)
        let store = ProviderHostSignInStore(profileID: "default", hostName: "Test Mac", client: client,
                                            pollInterval: .seconds(30))
        await store.start(providerID: "copilot-acp")
        await store.close()
        #expect(client.calls.last?.hasPrefix("cancel") == true)
        #expect(store.session == nil)
    }

    @Test func theSheetShowsTheHostSignInsProgress() async throws {
        guard let store = DemoProviderKeys.store() else { Issue.record("demo store"); return }
        await store.load()
        let target = ProviderSignInTarget(id: "anthropic", name: "Anthropic Account", logoID: "anthropic",
                                          client: "Claude Code")
        await store.startSignIn(target)
        let progress = store.signInProgress(for: target)
        #expect(progress.step == .waiting)
        #expect(progress.pastes)
        #expect(progress.code == nil)
        #expect(progress.link?.host() == "claude.com")
        await store.submitSignInCode("wrong-code", for: target)
        #expect(store.signInProgress(for: target).step == .failed("Claude Code didn't accept that code. Try again."))
        await store.closeSignIn(target)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}

@MainActor
private final class FakeHostSignInClient: HostSignInClient {
    let flow: HostSignInFlow
    let approvesAfter: Int
    var calls: [String] = []
    var startError: WorkspaceClientError?
    var listError: WorkspaceClientError?
    private var checks = 0
    private var status: HostSignInSession.Status = .starting
    private let id = UUID().uuidString.lowercased()

    init(flow: HostSignInFlow, approvesAfter: Int = 2) {
        self.flow = flow
        self.approvesAfter = approvesAfter
    }

    func providers(agentID: String) async throws -> [HostSignInProvider] {
        if let listError { throw listError }
        return [.init(providerID: "claude-code", name: "Claude Code", client: "Claude Code", flow: flow,
                      state: .ready(signedIn: false), documentationURL: nil)]
    }

    func start(agentID: String, providerID: String) async throws -> HostSignInSession {
        calls.append("start:\(providerID)")
        if let startError { throw startError }
        status = flow == .paste ? .needsCode : .waiting
        return session()
    }

    func status(agentID: String, sessionID: String) async throws -> HostSignInSession {
        calls.append("status")
        checks += 1
        if (status == .waiting && checks >= approvesAfter) || status == .finishing { status = .signedIn }
        return session()
    }

    func submit(agentID: String, sessionID: String, code: String) async throws -> HostSignInSession {
        calls.append("submit:\(code)")
        status = .finishing
        return session()
    }

    func cancel(agentID: String, sessionID: String) async throws -> HostSignInSession {
        calls.append("cancel")
        status = .cancelled
        return session()
    }

    private func session() -> HostSignInSession {
        .init(id: id, providerID: "claude-code", flow: flow, status: status,
              link: URL(string: flow == .paste ? "https://claude.com/sign-in" : "https://github.com/login/device"),
              code: flow == .device ? "WDJB-MJHT" : nil, message: nil)
    }
}
