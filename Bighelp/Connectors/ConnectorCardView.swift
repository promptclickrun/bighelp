import SwiftUI

/// One connect card inline in the chat: each app or tool the agent asked for, with Connect (or
/// Install, Allow, Try again) and Skip. Several cards can wait in one chat; each is answered on its
/// own, and the chat stays readable around them.
@MainActor
struct ConnectorInlineCard: View {
    let store: ConnectorCardStore
    let card: ConnectorCardStore.Card

    @Environment(\.scenePhase) private var scenePhase
    @State private var browser = ProviderSignInBrowser()
    /// The row whose sign-in page is open.
    @State private var signingIn: String?
    @State private var environment: [String: String] = [:]

    /// The newest frame of this card; the row's own copy once Hermes has settled it.
    private var operation: ConnectorOperation { store.current(card)?.operation ?? card.operation }

    var body: some View {
        BighelpCard {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                Label(title, systemImage: "app.connected.to.app.below.fill")
                    .bighelpFont(.sectionTitle)
                    .foregroundStyle(theme.primaryText)
                Text(intro)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                ForEach(Array(operation.targets.enumerated()), id: \.element.id) { index, target in
                    if index > 0 { Divider() }
                    row(target)
                }
                if let message = store.message {
                    Text(message)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                }
                Text(footnote)
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        .onChange(of: operation) { _, updated in
            // The account is connected: close the sign-in page for the person.
            guard let signingIn, updated.targets.first(where: { $0.name == signingIn })?.isOpen != true else { return }
            self.signingIn = nil
            browser.finish()
        }
        .onChange(of: scenePhase) { _, phase in
            // The Mac signs in in the default browser; coming back to bighelp means done.
            guard phase == .active, signingIn != nil else { return }
            Task { await store.signInClosed(card) }
        }
        .onDisappear {
            browser.finish()
            environment.removeAll()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connector.card.\(card.id)")
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ target: ConnectorOperation.Target) -> some View {
        let app = store.app(target.name)
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(spacing: BighelpTokens.space12) {
                ConnectorLogo(url: app.logoURL, name: app.name, kind: target.kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.alias.map { "\(app.name) (\($0))" } ?? app.name)
                        .font(.bighelp(.headline))
                        .foregroundStyle(theme.primaryText)
                    Text(status(target))
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
                if target.state == .connected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.success)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("connector.card.row.\(target.name)")
            if let instructions = target.instructions, target.isOpen {
                Text(instructions)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
            }
            if target.isOpen {
                if needsApproval(target) {
                    ForEach(target.requiredEnvironment) { field in environmentField(field) }
                }
                HStack(spacing: BighelpTokens.space8) {
                    Button(role: .cancel) {
                        Task { await store.skip([target.name], in: card) }
                    } label: {
                        Text("Skip").frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                    }
                    .buttonStyle(.bordered)
                    .tint(theme.action)
                    .disabled(store.isWorking(target, in: card))
                    .accessibilityIdentifier("connector.card.skip.\(target.name)")
                    primaryButton(target)
                }
            }
        }
    }

    @ViewBuilder
    private func primaryButton(_ target: ConnectorOperation.Target) -> some View {
        let working = store.isWorking(target, in: card)
        if target.canRetry {
            prominent("Try again", identifier: "connector.card.retry.\(target.name)", disabled: working) {
                Task { await store.retry(target, in: card) }
            }
        } else if needsApproval(target) {
            prominent(approveTitle(target), identifier: "connector.card.approve.\(target.name)",
                      disabled: working || !requiredFilled(target)) {
                let values = environment
                Task { await store.approve(target, in: card, environment: values) }
            }
        } else if let url = target.connectURL {
            prominent(target.kind == .connector ? "Connect" : "Sign in",
                      identifier: "connector.card.connect.\(target.name)", disabled: working) {
                open(url, for: target)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                .accessibilityLabel("Checking")
        }
    }

    private func prominent(_ title: String, identifier: String, disabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
        }
        .bighelpProminentButtonStyle()
        .tint(theme.action)
        .disabled(disabled)
        .accessibilityIdentifier(identifier)
    }

    private func environmentField(_ field: ConnectorOperation.EnvironmentField) -> some View {
        let label = field.prompt ?? field.name
        let binding = Binding(get: { environment[field.name] ?? field.defaultValue },
                              set: { environment[field.name] = $0 })
        return Group {
            if field.isSecret {
                SecureField(field.isRequired ? label : "\(label) (optional)", text: binding)
            } else {
                TextField(field.isRequired ? label : "\(label) (optional)", text: binding)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .privacySensitive()
        .padding(.horizontal, BighelpTokens.space12)
        .frame(minHeight: BighelpTokens.hitTarget)
        .background(theme.incomingMessageBackground, in: .rect(cornerRadius: BighelpTokens.radius12))
        .accessibilityIdentifier("connector.card.env.\(field.name)")
    }

    // MARK: Words

    private var title: String {
        let targets = operation.targets
        guard targets.count == 1, let target = targets.first else { return "Connect apps" }
        let name = store.app(target.name).name
        return switch (target.kind, target.action) {
        case (.mcp, .install): "Add \(name)"
        case (.mcp, .enable): "Turn on \(name)"
        case (.mcp, .authorize): "Sign in to \(name)"
        default: "Connect \(name)"
        }
    }

    private var intro: String {
        let names = ListFormatter.localizedString(byJoining: operation.targets.map { store.app($0.name).name })
        if operation.targets.allSatisfy({ $0.kind == .connector }) {
            return "Your agent wants to use \(names). Sign in once, and it can use \(operation.targets.count == 1 ? "it" : "them") right away."
        }
        return "Your agent wants to use \(names) on your computer."
    }

    private var footnote: String {
        let minutes = max(1, Int(((operation.timeout ?? 300) / 60).rounded()))
        let wait = "Your agent waits up to \(minutes) minute\(minutes == 1 ? "" : "s"), then goes on without it."
        guard operation.targets.contains(where: { $0.kind == .connector }) else { return wait }
        return wait + " Sign-ins are kept by the Hermes app service, not on this phone or in the chat."
    }

    private func status(_ target: ConnectorOperation.Target) -> String {
        switch target.state {
        case .connected: "Connected"
        case .skipped: "Skipped"
        case .notConnected: "Not connected"
        case .failed: target.detail ?? "The sign-in didn't work."
        case .expired: "The sign-in link expired."
        case .initiated where signingIn == target.name: "Finish signing in, then come back."
        case .initiated, .pending:
            switch (target.kind, target.action) {
            case (.mcp, .install): "A tool for your computer"
            case (.mcp, .enable): "Turned off on your computer"
            case (.mcp, .authorize): "Needs you to sign in"
            default: target.action == .reconnect ? "Needs you to sign in again" : "Not connected yet"
            }
        case .other: target.detail ?? ""
        }
    }

    private func approveTitle(_ target: ConnectorOperation.Target) -> String {
        switch target.action {
        case .install: "Install"
        case .enable: "Turn on"
        default: "Allow"
        }
    }

    /// An MCP row waits for the person's yes before it does anything.
    private func needsApproval(_ target: ConnectorOperation.Target) -> Bool {
        target.kind == .mcp && target.state == .pending && target.connectURL == nil
    }

    private func requiredFilled(_ target: ConnectorOperation.Target) -> Bool {
        target.requiredEnvironment.filter(\.isRequired).allSatisfy {
            !(environment[$0.name] ?? $0.defaultValue).isEmpty
        }
    }

    // MARK: Actions

    private func open(_ url: URL, for target: ConnectorOperation.Target) {
        signingIn = target.name
        let card = card
        let store = store
        browser.start(url) {
            Task { await store.signInClosed(card) }
        }
    }

    @BighelpThemeReader private var theme
}

/// The app's own logo from Hermes' catalog, or a plain symbol.
struct ConnectorLogo: View {
    let url: URL?
    let name: String
    var kind: ConnectorOperation.TargetKind = .connector
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    symbol
                }
            } else {
                symbol
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }

    private var symbol: some View {
        Image(systemName: kind == .mcp ? "wrench.and.screwdriver.fill" : "app.connected.to.app.below.fill")
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Color.secondary.opacity(0.12))
    }
}

#if DEBUG && targetEnvironment(simulator)
/// `-test-connector-card`: two requests waiting in one chat, with made-up names: two apps (one link
/// expired), then an MCP tool that needs a key.
enum ConnectorCardFixture {
    static let launchArgument = "-test-connector-card"

    @MainActor
    static func rootView() -> some View { FixtureHost() }

    @MainActor
    private struct FixtureHost: View {
        @State private var store = ConnectorCardStore()
        @State private var identity = NSObject()
        @State private var answers: [String] = []
        @State private var answered: [String: Set<String>] = [:]
        @BighelpThemeReader private var theme

        var body: some View {
            let cards = store.cards(runtimeID: "runtime", visibleSessionID: "chat")
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                        Text("Can you check my inbox and add the weather tool?")
                            .padding(BighelpTokens.space12)
                            .background(theme.outgoingMessageBackground, in: .rect(cornerRadius: 18))
                            .foregroundStyle(theme.outgoingMessageForeground)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        ForEach(cards) { card in ConnectorInlineCard(store: store, card: card) }
                        Text(answers.isEmpty ? "No answers yet" : answers.joined(separator: "\n"))
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                            .accessibilityIdentifier("connector.fixture.answers")
                    }
                    .padding(BighelpTokens.space12)
                }
                .background(theme.canvas.ignoresSafeArea())
                .navigationTitle("Juniper")
                .navigationBarTitleDisplayMode(.inline)
            }
            .task { open() }
        }

        private func open() {
            let connection = DirectHermesPromptConnection(owner: UUID(), principalIdentity: "host",
                clientIdentity: ObjectIdentifier(identity), transportGeneration: .init(UUID()))
            let sizes = ["op-apps": 2, "op-tool": 1]
            store.beginConnection(connection) { method, params in
                let names = params["result"]?.object?["targets"]?.array?.compactMap { $0.object?["name"]?.string } ?? []
                let op = params["op_id"]?.string ?? ""
                answers.append("\(method) \(names.joined(separator: ","))")
                answered[op, default: []].formUnion(names)
                // Like Hermes: an operation settles once every row has its answer.
                return .object(["status": .string("ok"), "settled": .boolean(answered[op]?.count == sizes[op])])
            }
            store.bind(profile: "juniper", runtimeID: "runtime", visibleSessionID: "chat", connection: connection)
            let deadline = Date().addingTimeInterval(300).timeIntervalSince1970
            store.accept(.init(type: "connection.request", sessionID: "runtime", payload: [
                "op_id": .string("op-apps"), "seq": .integer(1), "timeout_seconds": .integer(300),
                "deadline_at": .number(deadline),
                "targets": .array([
                    .object(["name": .string("example_mail"), "kind": .string("connector"), "action": .string("connect"),
                             "state": .string("initiated"), "resolved": .boolean(false),
                             "connect_url": .string("https://connect.example.com/start/sample")]),
                    .object(["name": .string("example_notes"), "kind": .string("connector"), "action": .string("connect"),
                             "state": .string("expired"), "resolved": .boolean(false)]),
                ]),
            ], sequence: nil), connection: connection)
            store.accept(.init(type: "connection.request", sessionID: "runtime", payload: [
                "op_id": .string("op-tool"), "seq": .integer(1), "timeout_seconds": .integer(300),
                "deadline_at": .number(deadline + 20),
                "targets": .array([
                    .object(["name": .string("weather"), "kind": .string("mcp"), "action": .string("install"),
                             "state": .string("pending"), "resolved": .boolean(false),
                             "instructions": .string("Needs an API key from your weather service."),
                             "required_env": .array([.object(["name": .string("WEATHER_API_KEY"), "required": .boolean(true),
                                                              "secret": .boolean(true), "default": .string(""),
                                                              "prompt": .string("Weather API key")])])]),
                ]),
            ], sequence: nil), connection: connection)
        }
    }
}
#endif
