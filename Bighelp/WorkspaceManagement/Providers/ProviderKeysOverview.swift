import Foundation

/// Provider Keys at a glance: what you're signed in to or have a key for, which
/// accounts you can sign in to (on the phone, or on the host's computer), and
/// which API keys you can add. Everything else is under Advanced.
///
/// Accounts Hermes only signs in to from a terminal sign in from the phone too
/// when the host's plugin can run the provider's own tool (`hostSignIns`).
struct ProviderKeysOverview: Equatable {
    struct Connected: Identifiable, Equatable {
        enum Kind: Equatable {
            /// A signed-in account; Disconnect is offered when Hermes can do it here.
            case account(providerID: String, canDisconnect: Bool, hint: String?)
            /// A saved key, managed in its own editor.
            case key(credentialID: String)
        }

        let id: String
        let logoID: String
        let name: String
        let detail: String
        let kind: Kind
        /// How to sign in to this account again (a new sign-in replaces the old one).
        var signInAgain: SignIn.Method? = nil
    }

    struct SignIn: Identifiable, Equatable {
        enum Method: Equatable {
            /// Hermes runs the sign-in and bighelp shows the code and page.
            case onPhone
            /// The host runs the provider's own sign-in tool; bighelp shows its link and code.
            case withHostTool(client: String, flow: HostSignInFlow)
            /// The provider's sign-in tool isn't on the host yet.
            case needsTool(client: String, install: String?, command: String?)
            /// Only a terminal on the host can sign in (the plugin has no sign-in for it).
            case onComputer(command: String?)
            /// The provider stopped offering this sign-in.
            case retired(message: String, replacementKey: String?)

            var isOnPhone: Bool {
                switch self {
                case .onPhone, .withHostTool: true
                default: false
                }
            }
        }

        let id: String
        let logoID: String
        let name: String
        let method: Method
        let documentationURL: URL?
        let problem: String?
    }

    struct KeyChoice: Identifiable, Equatable {
        let id: String
        let logoID: String
        let providerName: String
        let title: String
    }

    let connected: [Connected]
    let signIns: [SignIn]
    let keyChoices: [KeyChoice]

    init(snapshot: DirectHermesProviderSnapshot, hostSignIns: [HostSignInProvider] = []) {
        var connected: [Connected] = []
        var phone: [SignIn] = []
        var computer: [SignIn] = []
        var retired: [SignIn] = []
        let hosts = Dictionary(hostSignIns.map { ($0.providerID, $0) }, uniquingKeysWith: { first, _ in first })
        for provider in snapshot.oauthProviders {
            let logo = Self.logoID(provider.id)
            let host = hosts[provider.id]
            // The provider's own tool knows its login better than Hermes' guess
            // (Hermes counts a Claude Code install as signed in).
            var signedIn = provider.status.isLoggedIn
            if case .ready(let verified?)? = host?.state { signedIn = verified }
            let method: SignIn.Method
            if provider.flow == .deviceCode || provider.flow == .pkce {
                method = .onPhone
            } else if let host {
                switch host.state {
                case .ready: method = .withHostTool(client: host.client, flow: host.flow)
                case .notInstalled(let install):
                    method = .needsTool(client: host.client, install: install, command: provider.cliCommand)
                case .retired(let message, let key): method = .retired(message: message, replacementKey: key)
                }
            } else {
                method = .onComputer(command: provider.cliCommand)
            }
            if signedIn {
                let tier = provider.status.accountTier
                    ?? (provider.status.isFreeTier == true ? "Free tier" : nil)
                let hermesKnows = provider.status.isLoggedIn
                connected.append(.init(
                    id: "account:\(provider.id)", logoID: logo, name: provider.name,
                    detail: hermesKnows || host == nil
                        ? ["Signed in", tier].compactMap { $0 }.joined(separator: " · ")
                        : "Signed in with \(host?.client ?? "its own tool")",
                    kind: .account(providerID: provider.id, canDisconnect: provider.canDisconnect && hermesKnows,
                                   hint: provider.disconnectHint
                                       ?? host.map { "Sign out with \($0.client) on the computer." }),
                    signInAgain: { if case .retired = method { return nil } else { return method } }()
                ))
                continue
            }
            let row = SignIn(
                id: provider.id, logoID: logo, name: provider.name, method: method,
                documentationURL: provider.documentationURL ?? host?.documentationURL,
                problem: provider.status.errorMessage.flatMap { $0.isEmpty ? nil : $0 }
            )
            if row.method.isOnPhone {
                phone.append(row)
            } else if case .retired = row.method {
                retired.append(row)
            } else {
                computer.append(row)
            }
        }

        // Sign-ins Hermes doesn't list as accounts: GitHub Copilot keeps its token as a key in
        // Hermes but signs in with GitHub. Signed in, its key row (or an account row) shows it.
        let listed = Set(snapshot.oauthProviders.map(\.id))
        var signedInWithoutAccount: [HostSignInProvider] = []
        for host in hostSignIns where !listed.contains(host.providerID) {
            let method: SignIn.Method
            switch host.state {
            case .ready(let signedIn):
                if signedIn == true {
                    signedInWithoutAccount.append(host)
                    continue
                }
                method = .withHostTool(client: host.client, flow: host.flow)
            case .notInstalled(let install):
                method = .needsTool(client: host.client, install: install, command: nil)
            case .retired(let message, let key):
                method = .retired(message: message, replacementKey: key)
            }
            let row = SignIn(id: host.providerID, logoID: Self.logoID(host.providerID), name: host.name,
                             method: method, documentationURL: host.documentationURL, problem: nil)
            if row.method.isOnPhone {
                phone.append(row)
            } else if case .retired = row.method {
                retired.append(row)
            } else {
                computer.append(row)
            }
        }
        let savedKeyProviders = Set(snapshot.credentials.filter { $0.isSet && Self.isProviderKey($0) }
            .compactMap(\.providerID))
        for host in signedInWithoutAccount where !savedKeyProviders.contains(host.providerID) {
            connected.append(.init(
                id: "account:\(host.providerID)", logoID: Self.logoID(host.providerID), name: host.name,
                detail: "Signed in",
                kind: .account(providerID: host.providerID, canDisconnect: false, hint: nil),
                signInAgain: .withHostTool(client: host.client, flow: host.flow)
            ))
        }

        var keys: [Connected] = []
        var choices: [KeyChoice] = []
        for credential in snapshot.credentials where Self.isProviderKey(credential) {
            let provider = ProviderCredentialPresentation.providerName(credential)
            let logo = Self.logoID(credential.providerID ?? provider)
            if credential.isSet {
                let field = ProviderCredentialPresentation.field(for: credential.id) ?? "key"
                keys.append(.init(
                    id: "key:\(credential.id)", logoID: logo, name: provider,
                    detail: "\(field.prefix(1).uppercased() + field.dropFirst()) saved",
                    kind: .key(credentialID: credential.id)
                ))
            } else {
                choices.append(.init(id: credential.id, logoID: logo, providerName: provider,
                                     title: ProviderCredentialPresentation.title(credential)))
            }
        }
        keys.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.connected = connected + keys
        signIns = phone + computer + retired
        keyChoices = choices.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private init(connected: [Connected], signIns: [SignIn], keyChoices: [KeyChoice]) {
        self.connected = connected
        self.signIns = signIns
        self.keyChoices = keyChoices
    }

    var isEmpty: Bool { connected.isEmpty && signIns.isEmpty && keyChoices.isEmpty }

    /// Just the providers a search names, in the same order.
    func matching(_ search: String) -> ProviderKeysOverview {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return self }
        func matches(_ fields: String...) -> Bool { fields.contains { $0.localizedCaseInsensitiveContains(query) } }
        return .init(connected: connected.filter { matches($0.name, $0.logoID) },
                     signIns: signIns.filter { matches($0.name, $0.id) },
                     keyChoices: keyChoices.filter { matches($0.providerName, $0.title, $0.id) })
    }

    /// A secret that stands for an AI model provider: API keys, tokens and secrets, not
    /// base URLs, regions, messaging channels, tool keys or your own custom settings
    /// (those stay under Advanced).
    static func isProviderKey(_ credential: DirectHermesProviderCredential) -> Bool {
        guard credential.isSecret, !credential.isChannelManaged, !credential.isCustom,
              credential.category == "provider" || credential.providerID != nil else {
            return false
        }
        return ["API key", "token", "secret", "key", "sign-in token"]
            .contains(ProviderCredentialPresentation.field(for: credential.id) ?? "")
    }

    /// The brand a provider's logo comes from: "xai-oauth" is xAI, "copilot-acp"
    /// is GitHub Copilot, "hermes-xai" and "codex-hermes" are their brands.
    static func logoID(_ providerID: String) -> String {
        var id = providerID.lowercased()
        for suffix in ["-oauth", "-acp", "-cli"] where id.hasSuffix(suffix) { id = String(id.dropLast(suffix.count)) }
        return ProviderUsagePresentation.logoProviderID(id)
    }
}
