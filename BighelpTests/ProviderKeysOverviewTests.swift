import Foundation
import Testing
@testable import Bighelp

/// Provider Keys shows what you have first, then what you can sign in to, then
/// the API keys you can add. Technical settings stay under Advanced.
@MainActor
struct ProviderKeysOverviewTests {
    /// Refresh model catalogs asks Hermes to fetch every provider's models again, with time
    /// for slow providers, then shows the result.
    @Test func refreshModelCatalogsAsksHermesForEveryProvidersNewestModels() async throws {
        let authority = try WorkspaceAuthority.direct(endpointIdentity: "https://demo-mac.example", providerID: "demo", userID: "demo")
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        let transport = DemoProviderKeysTransport()
        let store = ProviderAccountsStore(hostName: "Demo Mac", profileID: "default", servingProfileID: "default",
            client: DirectHermesProviderClient(rpc: transport, http: transport, owner: owner, currentOwner: { owner }))
        await store.load()
        #expect(transport.catalogRefreshTimeouts.isEmpty, "Opening the screen reads the saved catalogs")
        await store.refreshModelCatalogs()
        #expect(transport.catalogRefreshTimeouts == [120])
        #expect(store.successMessage == "Hermes refreshed every provider's model catalog.")
        #expect(store.errorMessage == nil && !store.isBusy)
    }

    private func account(_ id: String, _ name: String, flow: DirectHermesOAuthProvider.Flow, loggedIn: Bool = false,
                         freeTier: Bool? = nil, tier: String? = nil, command: String? = nil,
                         canDisconnect: Bool = true, error: String? = nil) -> DirectHermesOAuthProvider {
        .init(id: id, name: name, flow: flow, documentationURL: URL(string: "https://example.com/\(id)"),
              canDisconnect: canDisconnect, disconnectHint: nil, cliCommand: command,
              status: .init(isLoggedIn: loggedIn, source: nil, sourceLabel: nil, expiresAt: nil,
                            hasRefreshToken: false, isFreeTier: freeTier, accountTier: tier, errorMessage: error))
    }

    private func key(_ id: String, provider: String? = nil, label: String? = nil, set: Bool = false,
                     secret: Bool = true, category: String = "provider",
                     channel: Bool = false) -> DirectHermesProviderCredential {
        .init(id: id, providerID: provider, providerName: label, description: "", category: category,
              isSet: set, isSecret: secret, isAdvanced: false, isCustom: false, isChannelManaged: channel)
    }

    private func snapshot(oauth: [DirectHermesOAuthProvider] = [],
                          keys: [DirectHermesProviderCredential] = []) -> DirectHermesProviderSnapshot {
        .init(providers: [], credentials: keys, oauthProviders: oauth, customEndpoints: [], credentialPools: [],
              setup: nil, runtime: nil, portal: nil)
    }

    @Test func whatYouHaveComesFirstAccountsThenKeys() {
        let overview = ProviderKeysOverview(snapshot: snapshot(
            oauth: [account("nous", "Nous Portal", flow: .deviceCode, loggedIn: true, freeTier: true),
                    account("openai-codex", "ChatGPT or Codex Subscription", flow: .deviceCode)],
            keys: [key("OPENROUTER_API_KEY", provider: "openrouter", label: "OpenRouter", set: true),
                   key("DEEPSEEK_API_KEY", provider: "deepseek", label: "DeepSeek", set: true),
                   key("OPENAI_API_KEY", provider: "openai", label: "OpenAI")]))
        #expect(overview.connected.map(\.name) == ["Nous Portal", "DeepSeek", "OpenRouter"])
        #expect(overview.connected.map(\.detail) == ["Signed in · Free tier", "API key saved", "API key saved"])
        #expect(overview.connected.first?.kind == .account(providerID: "nous", canDisconnect: true, hint: nil))
        #expect(overview.connected.last?.kind == .key(credentialID: "OPENROUTER_API_KEY"))
    }

    @Test func accountsYouCanSignInToOnThePhoneComeBeforeTerminalOnes() {
        let overview = ProviderKeysOverview(snapshot: snapshot(oauth: [
            account("nous", "Nous Portal", flow: .deviceCode),
            account("qwen-oauth", "Qwen (via Qwen CLI)", flow: .external, command: "hermes auth add qwen-oauth"),
            account("minimax-oauth", "MiniMax (OAuth)", flow: .deviceCode),
            account("copilot-acp", "GitHub Copilot (ACP)", flow: .external, command: "copilot login"),
            account("xai-oauth", "xAI Grok OAuth", flow: .deviceCode, error: "Token expired"),
        ]))
        #expect(overview.signIns.map(\.id) == ["nous", "minimax-oauth", "xai-oauth", "qwen-oauth", "copilot-acp"])
        #expect(overview.signIns[0].method == .onPhone)
        #expect(overview.signIns[3].method == .onComputer(command: "hermes auth add qwen-oauth"))
        #expect(overview.signIns[2].problem == "Token expired")
        #expect(overview.connected.isEmpty)
    }

    @Test func onlyProviderSecretsAreKeysToAdd() {
        let overview = ProviderKeysOverview(snapshot: snapshot(keys: [
            key("OPENAI_API_KEY", provider: "openai", label: "OpenAI"),
            key("ANTHROPIC_API_KEY", provider: "anthropic", label: "Anthropic"),
            key("OPENAI_BASE_URL", provider: "openai", label: "OpenAI", secret: false),
            key("TELEGRAM_BOT_TOKEN", category: "messaging", channel: true),
            key("FIRECRAWL_API_KEY", category: "tool"),
            key("GITHUB_TOKEN", provider: "copilot", label: "GitHub Copilot"),
        ]))
        #expect(overview.keyChoices.map(\.id) == ["ANTHROPIC_API_KEY", "GITHUB_TOKEN", "OPENAI_API_KEY"])
        #expect(overview.keyChoices.map(\.title) == ["Anthropic API key", "GitHub Copilot token", "OpenAI API key"])
    }

    @Test func searchKeepsOnlyTheProvidersItNames() {
        let overview = ProviderKeysOverview(snapshot: snapshot(
            oauth: [account("nous", "Nous Portal", flow: .deviceCode, loggedIn: true),
                    account("xai-oauth", "xAI Grok OAuth", flow: .deviceCode),
                    account("anthropic", "Anthropic Account", flow: .external, command: "hermes auth add anthropic")],
            keys: [key("OPENROUTER_API_KEY", provider: "openrouter", label: "OpenRouter", set: true),
                   key("XAI_API_KEY", provider: "xai", label: "xAI"),
                   key("ANTHROPIC_API_KEY", provider: "anthropic", label: "Anthropic")]))
        let grok = overview.matching(" xai ")
        #expect(grok.connected.isEmpty)
        #expect(grok.signIns.map(\.id) == ["xai-oauth"])
        #expect(grok.keyChoices.map(\.id) == ["XAI_API_KEY"])
        #expect(overview.matching("anthropic").signIns.map(\.id) == ["anthropic"])
        #expect(overview.matching("anthropic").keyChoices.map(\.id) == ["ANTHROPIC_API_KEY"])
        #expect(overview.matching("open").connected.map(\.name) == ["OpenRouter"])
        #expect(overview.matching("zzz").isEmpty)
        #expect(overview.matching("  ") == overview)
    }

    @Test func logosComeFromTheProvidersBrand() {
        #expect(ProviderKeysOverview.logoID("xai-oauth") == "xai")
        #expect(ProviderKeysOverview.logoID("minimax-oauth") == "minimax")
        #expect(ProviderKeysOverview.logoID("copilot-acp") == "copilot")
        #expect(ProviderKeysOverview.logoID("hermes-xai") == "xai")
        #expect(ProviderKeysOverview.logoID("openai-codex") == "openai-codex")
    }

    @Test func theHostsSignInCommandIsOneSafeLine() {
        #expect(DirectHermesProviderClient.terminalCommand("  hermes auth add qwen-oauth ") == "hermes auth add qwen-oauth")
        #expect(DirectHermesProviderClient.terminalCommand("claude setup-token\nrm -rf ~") == nil)
        #expect(DirectHermesProviderClient.terminalCommand("   ") == nil)
    }
}
