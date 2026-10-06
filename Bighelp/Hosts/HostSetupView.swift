import SwiftUI

/// Editing the Cloudflare Access token starts discovery over, like the address.
private struct HostSetupAccessChanges: ViewModifier {
    let values: [String]
    let onChange: () -> Void
    func body(content: Content) -> some View {
        content.onChange(of: values) { _, _ in onChange() }
    }
}

enum HostSetupAccessError: LocalizedError {
    case needsHTTPS
    /// A proxy in front of Hermes asked for a username and password.
    case proxyPasswordRequired
    case proxyPasswordRejected
    case blockedBeforeSignIn
    case loginPage
    case invalidProxyCredentials
    case customHeader(String)
    case customHeadersNeedPrivateOrHTTPS
    case cloudflareAccessTokenRejected

    var errorDescription: String? {
        switch self {
        case .needsHTTPS:
            "Cloudflare Access needs an https:// address."
        case .proxyPasswordRequired:
            "This address asks for a username and password."
        case .proxyPasswordRejected:
            "That username and password didn't work. Check them and try again."
        case .blockedBeforeSignIn:
            "Something in front of Hermes, like a proxy or firewall, turned bighelp away. If it needs a password or a Cloudflare Access token, add it under More options."
        case .invalidProxyCredentials:
            "Check the username and password. A username can't contain a colon."
        case .customHeader(let message):
            message
        case .customHeadersNeedPrivateOrHTTPS:
            "Custom headers only go to https:// addresses or a private network."
        case .cloudflareAccessTokenRejected:
            "Cloudflare Access didn't accept that service token. Check the Client ID and secret, and that a Service Auth policy allows it."
        case .loginPage:
            "This address opens a login page bighelp can't use. Try the address that reaches Hermes directly."
        }
    }
}

struct HostSetupDraft: Equatable {
    var address = ""
    var port = ""
    var name = ""
}

/// The address-first host wizard, used both at first run and by Add Host.
@MainActor
struct HostSetupView: View {
    let registry: BighelpHostRegistry
    var allowsDismiss = true
    var hostToAuthenticate: BighelpConfiguredHost? = nil
    var firstRunPresentation = false
    var completionActionTitle = "Start chatting"
    var retainedDraft: Binding<HostSetupDraft>? = nil
    var onConnectionCommitted: ((BighelpConfiguredHost) -> Void)? = nil
    var onFinished: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isAddressFocused: Bool
    @State private var showsConnectionOptions = false
    /// What stands in front of Hermes at this address, found by trying it.
    @State private var protection: Protection?
    @State private var address = ""
    @State private var port = ""
    @State private var name = ""
    /// Cloudflare Access service token; never kept in the retained draft.
    @State private var usesCloudflareAccess = false
    @State private var accessClientID = ""
    @State private var accessClientSecret = ""
    /// A proxy's basic-auth username and password; never kept in the retained draft.
    @State private var usesProxyPassword = false
    /// Set when the address itself asked for a password; opening the fields
    /// this way must not restart discovery and clear the explanation.
    @State private var needsProxyPassword = false
    @State private var proxyUsername = ""
    @State private var proxyPassword = ""
    /// Headers a reverse proxy wants; never kept in the retained draft.
    @State private var customHeaderRows: [HostCustomHeaderRow] = []
    @State private var token = ""
    @State private var username = ""
    @State private var password = ""
    @State private var method = Method.token
    @State private var provider = ""
    @State private var discovery: HostAuthenticationDiscovery?
    @State private var pendingID: UUID?
    @State private var workspace: DirectHermesWorkspaceStore?
    @State private var connectedHost: BighelpConfiguredHost?
    @State private var notifications: HostNotificationSetupModel?
    @State private var task: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var browserTransactionID: UUID?
    @State private var isWorking = false
    @State private var errorMessage: String?

    private enum Method: String, Identifiable { case dashboard, token, password, browser; var id: Self { self } }
    private enum Protection: Equatable { case cloudflareAccess, password }
    private enum Step { case address, protection(Protection), signIn(HostAuthenticationDiscovery), connected }

    private var step: Step {
        if connectedHost != nil { return .connected }
        if let protection { return .protection(protection) }
        if let discovery { return .signIn(discovery) }
        return .address
    }

    var body: some View {
        Form {
            header
            connectionCheck
            switch step {
            case .connected:
                connectedStep
            case .address:
                addressStep
            case .protection(let protection):
                protectionStep(protection)
            case .signIn(let discovery):
                authenticationSection(discovery)
                    .disabled(isWorking)
                    .listRowBackground(theme.surface)
            }
            if let errorMessage, connectedHost == nil {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .bighelpFont(.body).foregroundStyle(theme.primaryText)
                        .accessibilityIdentifier("host-setup.error")
                }
                .listRowBackground(theme.surface)
            }
            if connectedHost == nil, !firstRunPresentation {
                Section { connectionAction }
                    .listRowBackground(Color.clear)
            }
            if case .address = step {
                Section {
                    Link("Need help connecting?", destination: URL(string: "https://hermes-agent.nousresearch.com/docs/user-guide/desktop#connecting-to-a-remote-backend")!)
                        .bighelpFont(.label, weight: .regular)
                }
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .tint(theme.action)
        .navigationTitle(hostToAuthenticate == nil ? "" : "Sign in again")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.defaultMinListRowHeight, 44)
        .toolbar {
            if allowsDismiss {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { finish() }.keyboardShortcut(.cancelAction).bighelpToolbarText() }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if firstRunPresentation {
                VStack(spacing: 0) {
                    Divider().overlay(theme.border)
                    if connectedHost != nil {
                        primaryAction(
                            completionActionTitle,
                            identifier: "host-setup.continue",
                            disabled: false
                        ) { finish() }
                    } else {
                        connectionAction
                    }
                }
                .padding(.horizontal, BighelpTokens.space24)
                .padding(.vertical, BighelpTokens.space12)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .task {
            #if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))
            if await holdCheckForTesting() { return }
            #endif
            if firstRunPresentation, connectedHost == nil,
               let onboardingHostID = registry.onboardingHostID,
               let host = registry.hosts.first(where: { $0.id == onboardingHostID }) {
                connectedHost = host
                notifications = HostNotificationSetupModel(host: host, registry: registry)
                onConnectionCommitted?(host)
                return
            }
            if let retainedDraft {
                let draft = retainedDraft.wrappedValue
                address = draft.address
                port = draft.port
                name = draft.name
            }
            guard let host = hostToAuthenticate else { return }
            address = host.endpoint.identity
            name = host.name
            pendingID = host.id
            workspace = registry.workspace(for: host)
            discover()
        }
        .onChange(of: address) { _, _ in needsProxyPassword = false; invalidateDiscovery(); saveRetainedDraft() }
        .onChange(of: port) { _, _ in invalidateDiscovery(); saveRetainedDraft() }
        .onChange(of: name) { _, _ in saveRetainedDraft() }
        .modifier(HostSetupAccessChanges(values: [usesCloudflareAccess ? "on" : "off", accessClientID, accessClientSecret,
                                                  usesProxyPassword ? "on" : "off", proxyUsername, proxyPassword]
                                                  + customHeaderRows.flatMap { [$0.name, $0.value] },
                                          onChange: invalidateDiscovery))
        // One kind of gate per address.
        .onChange(of: usesProxyPassword) { _, on in if on { usesCloudflareAccess = false } }
        .onChange(of: usesCloudflareAccess) { _, on in if on { usesProxyPassword = false; needsProxyPassword = false } }
        .onChange(of: method) { _, _ in token = ""; password = ""; provider = defaultProvider }
        .onChange(of: provider) { _, _ in password = "" }
        .onChange(of: registry.accountScope) { _, _ in cancel(); dismiss() }
        .onChange(of: scenePhase) { _, phase in
            // The system-browser transaction owns its bounded listener while the
            // app visits Safari, MFA, or a password manager. All other setup work
            // retains the existing true-background cancellation behavior.
            if phase == .background, browserTransactionID == nil {
                notifications?.cancel()
                cancel()
            }
        }
        .onDisappear {
            saveRetainedDraft()
            notifications?.cancel()
            cancel()
            if connectedHost == nil, let pendingID { registry.discardPending(pendingID) }
        }
        .accessibilityIdentifier("host-setup.screen")
    }

    @BighelpThemeReader private var theme

    /// One question per step, with a way back.
    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                if canGoBack {
                    Button { goBack() } label: {
                        HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("Back") }
                    }
                        .bighelpFont(.label, weight: .regular)
                        .disabled(isWorking)
                        .accessibilityIdentifier("host-setup.back")
                } else if !firstRunPresentation {
                    BighelpLogo(presentation: .mark, height: 36).accessibilityHidden(true)
                }
                Text(headerTitle)
                    .bighelpFont(.sectionTitle)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(headerDetail)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(isSigningIn ? "host-setup.method-detail" : "host-setup.detail")
            }
            .padding(.vertical, firstRunPresentation ? 4 : 16)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var headerTitle: String {
        switch step {
        case .address: hostToAuthenticate == nil ? "Connect your computer" : "Sign in again"
        case .protection(.cloudflareAccess): "Cloudflare Access"
        case .protection(.password): "Password needed"
        case .signIn: hostToAuthenticate == nil ? "Sign in to Hermes" : "Sign in again"
        case .connected: "Connected"
        }
    }

    private var headerDetail: String {
        switch step {
        case .address: hostToAuthenticate?.name ?? "Where is Hermes running?"
        case .protection(.cloudflareAccess): "This address is protected by Cloudflare Access. Enter its service token."
        case .protection(.password): "This address asks for a username and password before Hermes."
        case .signIn(let discovery): signInDetail(discovery)
        case .connected: "Your agents are ready to chat."
        }
    }

    private var isSigningIn: Bool {
        if case .signIn = step { true } else { false }
    }

    /// This device and the computer, joined by a line that shows the check
    /// while it runs and stays, connected, once it's in. A failed check says
    /// why in the error below instead.
    @ViewBuilder
    private var connectionCheck: some View {
        if let status = HostConnectionStatus(setupIsWorking: isWorking, isConnected: connectedHost != nil) {
            Section {
                // Kept to a phone's width so the line doesn't stretch across a Mac window.
                BighelpConnectionLine(phase: status.phase, hostName: checkedHostName, label: status.label)
                    .padding(.vertical, BighelpTokens.space8)
                    .frame(maxWidth: 440)
                    .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    /// The computer's name, or the address being checked until it has one.
    private var checkedHostName: String {
        if let connectedHost { return connectedHost.name }
        if let hostToAuthenticate { return hostToAuthenticate.name }
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        if let discovery { return discovery.endpoint.host }
        let entered = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return URLComponents(string: entered.contains("://") ? entered : "https://" + entered)?.host ?? entered
    }

    private var canGoBack: Bool {
        switch step {
        case .protection: true
        case .signIn: hostToAuthenticate == nil
        case .address, .connected: false
        }
    }

    private func goBack() {
        BighelpKeyboard.dismiss()
        cancel()
        if isSigningIn, usesCloudflareAccess || usesProxyPassword || needsProxyPassword {
            // Back from sign-in to the protection step it came through.
            protection = usesCloudflareAccess ? .cloudflareAccess : .password
            invalidateDiscovery()
            return
        }
        protection = nil
        usesCloudflareAccess = false
        usesProxyPassword = false
        needsProxyPassword = false
        accessClientSecret = ""
        proxyPassword = ""
        invalidateDiscovery()
    }

    private var addressStep: some View {
        Section {
            TextField("hermes.example.com or 192.168.1.20", text: $address)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.continue)
                .onSubmit { if !isWorking { discover() } }
                .accessibilityLabel("Host URL or IP address")
                .accessibilityIdentifier("host-setup.address")
                .focused($isAddressFocused)
                .disabled(hostToAuthenticate != nil)
                .padding(.vertical, 6)
            DisclosureGroup(isExpanded: $showsConnectionOptions) {
                TextField("Name (optional)", text: $name)
                    .accessibilityIdentifier("host-setup.name")
                TextField("Port (optional)", text: $port)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("host-setup.port")
                Button("It's behind Cloudflare Access") {
                    BighelpKeyboard.dismiss()
                    protection = .cloudflareAccess; usesCloudflareAccess = true
                }
                    .accessibilityIdentifier("host-setup.choose-cloudflare-access")
                Button("It asks for a username and password") {
                    BighelpKeyboard.dismiss()
                    protection = .password; usesProxyPassword = true
                }
                    .accessibilityIdentifier("host-setup.choose-password")
                Text("Custom headers").bighelpFont(.label, weight: .semibold)
                    .padding(.top, BighelpTokens.space8)
                HostCustomHeaderFields(rows: $customHeaderRows)
            } label: {
                Text("More options")
                    .bighelpFont(.label, weight: .regular)
                    .frame(minHeight: 44)
            }
            .disabled(hostToAuthenticate != nil)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("host-setup.options")
        }
        .listRowBackground(theme.surface)
    }

    @ViewBuilder
    private func protectionStep(_ protection: Protection) -> some View {
        Section {
            switch protection {
            case .cloudflareAccess:
                TextField("Client ID", text: $accessClientID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textContentType(.username)
                    .accessibilityIdentifier("host-setup.cloudflare-client-id")
                SecureField("Client secret", text: $accessClientSecret)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .privacySensitive()
                    .accessibilityIdentifier("host-setup.cloudflare-client-secret")
                Link("How to make a service token", destination: URL(string:
                    "https://github.com/promptclickrun/bighelp/blob/main/docs/HOST_ACCESS.md#cloudflare-access-service-token")!)
                    .bighelpFont(.label, weight: .regular)
            case .password:
                TextField("Username", text: $proxyUsername)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textContentType(.username)
                    .accessibilityIdentifier("host-setup.proxy-username")
                SecureField("Password", text: $proxyPassword)
                    .textContentType(.password)
                    .privacySensitive()
                    .accessibilityIdentifier("host-setup.proxy-password-field")
            }
        }
        .disabled(isWorking)
        .listRowBackground(theme.surface)
    }

    @ViewBuilder
    private var connectedStep: some View {
        if let host = connectedHost, let notifications {
            if host.endpoint.baseURL.scheme == "http" {
                Section { plainHTTPNote }
                    .listRowBackground(theme.surface)
            }
            if !firstRunPresentation {
                Section {
                    primaryAction(completionActionTitle, identifier: "host-setup.continue", disabled: false) { finish() }
                }
                .listRowBackground(Color.clear)
            }
            HostNotificationSetupSection(model: notifications)
                .listRowBackground(theme.surface)
        }
    }

    @ViewBuilder
    private func primaryAction(_ title: String, identifier: String, disabled: Bool,
                               action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text(title).bighelpFont(.label, weight: .semibold)
                Spacer(minLength: 0)
            }
            .frame(minHeight: firstRunPresentation ? BighelpTokens.primaryActionSize : 44)
            .contentShape(.rect)
        }
        .controlSize(.large)
        .disabled(disabled)
        .accessibilityIdentifier(identifier)
        #if os(visionOS) // No glass button styles on visionOS.
        button.bighelpProminentButtonStyle()
        #else
        if #available(iOS 26.0, *) {
            button.buttonStyle(.glassProminent).foregroundStyle(Color.bighelpActionInk)
        } else {
            button.bighelpProminentButtonStyle()
        }
        #endif
    }

    private var connectionAction: some View {
        primaryAction(
            isWorking ? (discovery == nil ? "Finding your agents…" : "Connecting…")
                      : (discovery == nil ? "Continue" : "Connect"),
            identifier: "host-setup.connect-host",
            disabled: isWorking || !stepIsFilledIn
        ) {
            if let discovery { connect(discovery) }
            else if address.isEmpty { isAddressFocused = true }
            else { discover() }
        }
    }

    private var stepIsFilledIn: Bool {
        switch step {
        case .protection(.cloudflareAccess): !accessClientID.isEmpty && !accessClientSecret.isEmpty
        case .protection(.password): !proxyUsername.isEmpty && !proxyPassword.isEmpty
        case .signIn(let discovery): canConnect(discovery)
        case .address, .connected: true
        }
    }

    private var plainHTTPNote: some View {
        Label("Not encrypted. Use plain HTTP only on a network you trust.", systemImage: "lock.open")
            .bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
            .accessibilityIdentifier("host-setup.plain-http")
    }

    @ViewBuilder
    private func authenticationSection(_ discovery: HostAuthenticationDiscovery) -> some View {
        Section {
            if offeredMethods(discovery) > 1 {
                Picker("Sign in with", selection: $method) {
                    if discovery.supportsDashboard { Text("No sign-in").tag(Method.dashboard) }
                    if discovery.supportsToken { Text(discovery.requiresAuthentication ? "Access token" : "Session token").tag(Method.token) }
                    if discovery.supportsPassword { Text("Username & password").tag(Method.password) }
                    if discovery.nativePKCE { Text("Browser sign-in").tag(Method.browser) }
                }.accessibilityIdentifier("direct-hermes.auth-picker")
            }
            if method == .token && discovery.supportsToken {
                SecureField(discovery.requiresAuthentication ? "Access token" : "Dashboard session token", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("direct-hermes.token")
            } else if method == .browser && discovery.nativePKCE {
                // One provider needs no choice.
                if discovery.providers.count > 1 {
                    Picker("Provider", selection: $provider) {
                        Text("Automatic").tag("")
                        ForEach(discovery.providers) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }.accessibilityIdentifier("host-setup.provider")
                }
            } else if method == .password && discovery.supportsPassword {
                if discovery.providers.filter(\.supportsPassword).count > 1 {
                    Picker("Provider", selection: $provider) {
                        ForEach(discovery.providers.filter(\.supportsPassword)) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    .accessibilityIdentifier("host-setup.provider")
                }
                TextField("Username", text: $username).textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("direct-hermes.username")
                SecureField("Password", text: $password).textContentType(.password)
                    .accessibilityIdentifier("direct-hermes.password")
            }
            if discovery.endpoint.baseURL.scheme == "http" { plainHTTPNote }
        }
    }

    private func offeredMethods(_ discovery: HostAuthenticationDiscovery) -> Int {
        [discovery.supportsDashboard, discovery.supportsToken, discovery.supportsPassword, discovery.nativePKCE]
            .filter { $0 }.count
    }

    private func signInDetail(_ discovery: HostAuthenticationDiscovery) -> String {
        switch method {
        case .dashboard:
            "This computer doesn't need a sign-in."
        case .token where discovery.requiresAuthentication:
            "Paste an access token from your sign-in provider."
        case .token:
            "Paste the dashboard's session token (HERMES_DASHBOARD_SESSION_TOKEN)."
        case .password:
            "Use your Hermes username and password."
        case .browser:
            if discovery.providers.count == 1, let only = discovery.providers.first {
                "Sign in with \(only.name) in \(Self.signInBrowser), then come back here."
            } else {
                "Sign in on your Hermes sign-in page in \(Self.signInBrowser), then come back here."
            }
        }
    }

    private var defaultProvider: String {
        guard method == .password else { return "" }
        return discovery?.providers.first(where: \.supportsPassword)?.id ?? ""
    }
    private func canConnect(_ discovery: HostAuthenticationDiscovery) -> Bool {
        switch method {
        case .dashboard: discovery.supportsDashboard
        case .token: discovery.supportsToken && !token.isEmpty
        case .password: discovery.supportsPassword && !provider.isEmpty && !username.isEmpty && !password.isEmpty
        case .browser: discovery.nativePKCE
        }
    }
    private func discover() {
        // Each step swaps the form's rows. A field still holding the keyboard when its
        // row goes, while the keyboard closes, trips a UICollectionView assertion.
        BighelpKeyboard.dismiss()
        cancel()
        discovery = nil
        let owner = UUID(); requestID = owner
        let account = registry.accountScope
        let accountGeneration = registry.generation
        guard account != nil else { return }
        isWorking = true; errorMessage = nil
        task = Task { @MainActor in
            defer { if requestID == owner { isWorking = false } }
            do {
                let result = try await discoverFirstReachable(try endpointCandidates(), owner: owner)
                guard requestID == owner, registry.accountScope == account, registry.generation == accountGeneration, !Task.isCancelled else { return }
                protection = nil
                discovery = result
                method = Method(rawValue: HostAuthenticationDiscovery.preferredMethod(for: result).rawValue) ?? .token
                provider = defaultProvider
                // A computer that needs no sign-in connects straight away.
                if method == .dashboard { connect(result) }
            } catch {
                guard requestID == owner, registry.accountScope == account, registry.generation == accountGeneration else { return }
                if let next = nextProtection(after: error) {
                    protection = next
                    return
                }
                errorMessage = (error as? HostSetupAccessError)?.localizedDescription
                    ?? DirectHermesConversationClient.safeMessage(error)
            }
        }
    }

    /// A bare private address (home Wi-Fi, a VPN or Tailscale) tries HTTPS, then
    /// plain HTTP. Internet addresses only ever use HTTPS; a typed http:// is
    /// accepted for private addresses alone.
    private func endpointCandidates() throws -> [DirectHermesEndpoint] {
        if let host = hostToAuthenticate { return [host.endpoint] }
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.contains("://") {
            let plain = typed.lowercased().hasPrefix("http://")
            return [try HostAddressInput.endpoint(address: typed, port: port, allowPrivateHTTP: plain)]
        }
        let secure = try HostAddressInput.endpoint(address: typed, port: port, allowPrivateHTTP: false)
        guard DirectHermesEndpoint.isPrivateNetworkHost(secure.host), !usesCloudflareAccess else { return [secure] }
        return [secure, try HostAddressInput.endpoint(address: typed, port: port, allowPrivateHTTP: true)]
    }

    private func discoverFirstReachable(_ candidates: [DirectHermesEndpoint], owner: UUID) async throws -> HostAuthenticationDiscovery {
        var firstError: (any Error)?
        for (index, endpoint) in candidates.enumerated() {
            let sentProxyPassword = try stageAccess(for: endpoint)
            do {
                return try await HostAuthenticationDiscovery.discover(endpoint: endpoint)
            } catch let error as DirectHermesError where Self.mayBePlainHTTP(error) {
                unstage(endpoint)
                guard index < candidates.count - 1 else { throw firstError ?? error }
                firstError = firstError ?? error
            } catch let gate as HostAuthenticationDiscovery.Gate {
                guard requestID == owner else { throw CancellationError() }
                switch gate {
                case .passwordProxy:
                    needsProxyPassword = true
                    throw sentProxyPassword ? HostSetupAccessError.proxyPasswordRejected
                                            : HostSetupAccessError.proxyPasswordRequired
                case .blocked:
                    throw sentProxyPassword ? HostSetupAccessError.proxyPasswordRejected
                                            : HostSetupAccessError.blockedBeforeSignIn
                case .loginPage:
                    throw HostSetupAccessError.loginPage
                }
            } catch DirectHermesError.cloudflareAccessDenied where usesCloudflareAccess {
                throw HostSetupAccessError.cloudflareAccessTokenRejected
            }
        }
        throw firstError ?? DirectHermesError.connectionFailed
    }

    /// TLS failing or nothing answering on HTTPS can mean the computer serves plain HTTP.
    /// Where browser sign-in opens: the Mac uses your default browser.
    private static var signInBrowser: String { BighelpPlatform.isMac ? "your browser" : "Safari" }

    private static func mayBePlainHTTP(_ error: DirectHermesError) -> Bool {
        error == .tlsRequired || error == .connectionFailed
    }

    /// A gate seen for the first time becomes the next step instead of an error.
    private func nextProtection(after error: any Error) -> Protection? {
        if case DirectHermesError.cloudflareAccessDenied = error, !usesCloudflareAccess {
            usesCloudflareAccess = true
            return .cloudflareAccess
        }
        if case HostSetupAccessError.proxyPasswordRequired = error { return .password }
        return nil
    }

    private func connect(_ discovery: HostAuthenticationDiscovery) {
        guard canConnect(discovery), registry.canConfigureHosts else { return }
        BighelpKeyboard.dismiss()
        let auth: DirectHermesAuthInput
        switch method {
        case .dashboard: auth = .dashboard
        case .token: auth = .token(token)
        case .password: auth = .passwordProvider(provider: provider, username: username, password: password)
        case .browser: auth = .browser(provider: provider.isEmpty ? nil : provider)
        }
        cancel()
        let owner = UUID(); requestID = owner
        if case .browser = auth { browserTransactionID = owner }
        let account = registry.accountScope
        let accountGeneration = registry.generation
        isWorking = true; errorMessage = nil
        task = Task { @MainActor in
            defer {
                if browserTransactionID == owner { browserTransactionID = nil }
                if requestID == owner { isWorking = false; token = ""; password = "" }
            }
            do {
                if workspace == nil {
                    let pending = try registry.makePendingWorkspace()
                    pendingID = pending.0; workspace = pending.1
                }
                guard let pendingID, let workspace else { return }
                await workspace.connect(address: discovery.endpoint.identity, auth: auth, allowPrivateHTTP: discovery.endpoint.allowPrivateHTTP)
                guard requestID == owner, registry.accountScope == account, registry.generation == accountGeneration, !Task.isCancelled else { return }
                guard workspace.isConnected else { errorMessage = workspace.status; return }
                let host: BighelpConfiguredHost
                if let existing = hostToAuthenticate {
                    host = try registry.acceptAuthentication(for: existing, workspace: workspace)
                } else {
                    host = try registry.commit(pendingID, workspace: workspace, name: name)
                }
                connectedHost = host
                notifications = HostNotificationSetupModel(host: host, registry: registry)
                onConnectionCommitted?(host)
            } catch {
                guard requestID == owner, registry.accountScope == account, registry.generation == accountGeneration else { return }
                errorMessage = error is HostSetupError ? HostSetupError.alreadyConfigured.localizedDescription : DirectHermesConversationClient.safeMessage(error)
            }
        }
    }
    private func invalidateDiscovery() {
        cancel()
        unstageAccess()
        if hostToAuthenticate == nil, connectedHost == nil, let pendingID {
            registry.discardPending(pendingID)
            self.pendingID = nil
            workspace = nil
        }
        discovery = nil; token = ""; password = ""; errorMessage = nil
    }
    private func cancel() {
        requestID = UUID(); browserTransactionID = nil; task?.cancel(); task = nil; isWorking = false
        if connectedHost == nil { workspace?.suspendForPresentationExit() }
        token = ""; password = ""
    }
    private func finish() {
        notifications?.cancel()
        cancel()
        unstageAccess()
        onFinished?()
        registry.finishSetup()
        dismiss()
    }

    /// Requests during setup use the entered credentials; they're saved once the
    /// connection works. Returns whether a proxy password is being sent.
    @discardableResult
    private func stageAccess(for endpoint: DirectHermesEndpoint) throws -> Bool {
        let store = DirectHermesAccessCredentialStore.shared
        guard hostToAuthenticate == nil else {
            store.stage(nil, for: endpoint)
            store.stageCustomHeaders(nil, for: endpoint)
            return false
        }
        let headers: [DirectHermesCustomHeader]
        do { headers = try HostCustomHeaderRow.headers(customHeaderRows) }
        catch { throw HostSetupAccessError.customHeader(error.localizedDescription) }
        guard headers.isEmpty || DirectHermesAccessCredentialStore.mayCarrySecrets(endpoint) else {
            throw HostSetupAccessError.customHeadersNeedPrivateOrHTTPS
        }
        store.stageCustomHeaders(headers.isEmpty ? nil : headers, for: endpoint)
        if usesProxyPassword || needsProxyPassword, !proxyUsername.isEmpty, !proxyPassword.isEmpty {
            guard let credentials = try? DirectHermesAccessCredentials(username: proxyUsername, password: proxyPassword)
            else { throw HostSetupAccessError.invalidProxyCredentials }
            // Never to a plain-HTTP address on the open internet.
            guard credentials.canSend(to: endpoint) else { throw HostSetupAccessError.blockedBeforeSignIn }
            store.stage(credentials, for: endpoint)
            return true
        }
        guard usesCloudflareAccess else {
            store.stage(nil, for: endpoint)
            return false
        }
        guard endpoint.baseURL.scheme == "https" else { throw HostSetupAccessError.needsHTTPS }
        store.stage(try DirectHermesAccessCredentials(clientID: accessClientID, clientSecret: accessClientSecret),
                    for: endpoint)
        return false
    }

    /// An abandoned setup never leaves a token in use; a connected host already saved it.
    private func unstageAccess() {
        guard connectedHost == nil, let endpoint = discovery?.endpoint else { return }
        unstage(endpoint)
    }

    private func unstage(_ endpoint: DirectHermesEndpoint) {
        DirectHermesAccessCredentialStore.shared.stage(nil, for: endpoint)
        DirectHermesAccessCredentialStore.shared.stageCustomHeaders(nil, for: endpoint)
    }

    private func saveRetainedDraft() {
        retainedDraft?.wrappedValue = HostSetupDraft(
            address: address,
            port: port,
            name: name
        )
    }
}

#if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))
extension HostSetupView {
    /// "-test-host-setup connecting|connected|check" holds the connection check
    /// on a made-up computer for screenshots; "check" connects after a moment.
    fileprivate func holdCheckForTesting() async -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-test-host-setup"), arguments.indices.contains(index + 1),
              let scope = registry.accountScope,
              let endpoint = try? DirectHermesEndpoint(address: "https://studio.example.com") else { return false }
        let mode = arguments[index + 1]
        name = "Studio Mac"
        if mode != "connected" {
            isWorking = true
            guard mode == "check" else { return true }
            try? await Task.sleep(for: .seconds(3))
            isWorking = false
        }
        let host = BighelpConfiguredHost(id: UUID(), accountScope: scope, accountID: nil, endpoint: endpoint,
                                         principalIdentity: "demo", name: name)
        notifications = HostNotificationSetupModel(host: host, registry: registry)
        connectedHost = host
        return true
    }
}
#endif

@MainActor
struct HostNotificationSetupSection: View {
    let model: HostNotificationSetupModel
    var hostName: String? = nil
    var hostEndpoint: String? = nil
    var onCompletion: @MainActor () async -> Void = {}
    @State private var showsReview = false

    var body: some View {
        Section {
            if let hostName {
                LabeledContent("Computer", value: hostName)
                    .accessibilityIdentifier("host-setup.notification-host")
            }
            if let hostEndpoint {
                DisclosureGroup("Connection Details") {
                    Text(hostEndpoint).bighelpFont(.code).textSelection(.enabled)
                }
                .accessibilityIdentifier("host-setup.notification-host-address")
            }
            if model.state != .notConfigured && model.state != .enabled && !model.isWorking {
                BighelpInlineNotice(message: model.message,
                                   tone: model.providerFailure == nil ? .warning : .danger)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .accessibilityIdentifier("host-setup.notification-status")
            }
            if model.isWorking {
                ProgressView(model.state == .installing ? "Installing the plugin…" : "Checking notification setup…")
                    .accessibilityIdentifier("host-setup.notification-progress")
            } else if model.state == .enabled {
                Label("Notifications Enabled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("host-setup.notification-enabled")
            } else if showsReview {
                Text("Get alerts for replies, tasks, questions, and approvals.")
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle = model.actionTitle {
                    Button(actionTitle) {
                        Task {
                            await model.enable()
                            await onCompletion()
                        }
                    }
                    .accessibilityIdentifier("host-setup.install-plugin")
                }
                Button("Not Now", role: .cancel) { showsReview = false }
                    .accessibilityIdentifier("host-setup.notifications-not-now")
            } else {
                Button(notificationReviewTitle) { showsReview = true }
                    .accessibilityIdentifier("host-setup.enable-notifications")
            }
        } header: {
            Text("Notifications")
        }
    }

    private var notificationReviewTitle: String {
        switch model.state {
        case .notConfigured: "Enable Notifications"
        case .verificationRequired, .backendRestartRequired, .outcomeUnknown, .signInChanged: "Check Again"
        default: "Try Again"
        }
    }
}
