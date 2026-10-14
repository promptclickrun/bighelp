import SwiftUI

/// Mount once above the selected workspace, beside `DirectHermesSecurePromptOverlay`. Closing the
/// sheet any way skips what's still open, so the agent goes on at once instead of waiting out
/// Hermes' deadline.
@MainActor
struct ConnectorCardOverlay: View {
    let store: ConnectorCardStore

    var body: some View {
        let _ = store.revision
        // A sheet needs a real view to hang from; EmptyView never presents one.
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .bighelpSheet(item: presentation) { card in
                ConnectorCardView(store: store, card: card)
                    .bighelpSheetSize(card.operation.targets.count > 1
                        || card.operation.targets.contains { !$0.requiredEnvironment.isEmpty } ? .standard : .compact)
            }
    }

    private var presentation: Binding<ConnectorCardStore.Card?> {
        let shown = store.activeCard
        return Binding(
            get: { store.activeCard },
            set: { value in
                guard value == nil, let shown else { return }
                Task { await store.skipAll(shown) }
            }
        )
    }
}

/// One connect card: each app or tool the agent asked for, with Connect (or Install, Allow) and Skip.
@MainActor
struct ConnectorCardView: View {
    let store: ConnectorCardStore
    let card: ConnectorCardStore.Card

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var browser = ProviderSignInBrowser()
    /// The row whose sign-in page is open.
    @State private var signingIn: String?
    @State private var environment: [String: String] = [:]

    /// The newest frame of this card; the sheet's own copy once Hermes has settled it.
    private var operation: ConnectorOperation {
        store.activeCard.flatMap { $0.id == card.id ? $0.operation : nil } ?? card.operation
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(intro)
                } footer: {
                    if operation.targets.contains(where: { $0.kind == .connector }) {
                        Text("Your sign-in is kept by the Hermes app service, not on this phone or in the chat.")
                    }
                }
                ForEach(operation.targets) { target in
                    Section { row(target) }
                }
                if let message = store.message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
                Section {
                } footer: {
                    Text(waitNote)
                }
            }
            .bighelpFormSurface()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { notNow() }
                        .keyboardShortcut(.cancelAction)
                        .bighelpToolbarText()
                        .accessibilityIdentifier("connector.card.not-now")
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
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connector.card")
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ target: ConnectorOperation.Target) -> some View {
        let app = store.app(target.name)
        HStack(spacing: BighelpTokens.space12) {
            ConnectorLogo(url: app.logoURL, name: app.name, kind: target.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.alias.map { "\(app.name) (\($0))" } ?? app.name)
                    .font(.bighelp(.headline))
                Text(status(target))
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if target.state == .connected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connector.card.row.\(target.name)")
        if let instructions = target.instructions, target.isOpen {
            Text(instructions)
                .font(.bighelp(.footnote))
                .foregroundStyle(.secondary)
        }
        if target.isOpen {
            if needsApproval(target) {
                ForEach(target.requiredEnvironment) { field in
                    environmentField(field)
                }
            }
            primaryButton(target)
            Button("Skip", role: .cancel) {
                Task { await store.skip([target.name], in: card) }
            }
            .foregroundStyle(.secondary)
            .disabled(store.isWorking(target, in: card))
            .accessibilityIdentifier("connector.card.skip.\(target.name)")
        }
    }

    @ViewBuilder
    private func primaryButton(_ target: ConnectorOperation.Target) -> some View {
        let working = store.isWorking(target, in: card)
        if target.canRetry {
            Button("Try again") { Task { await store.retry(target, in: card) } }
                .disabled(working)
                .accessibilityIdentifier("connector.card.retry.\(target.name)")
        } else if needsApproval(target) {
            Button(approveTitle(target)) {
                let values = environment
                Task { await store.approve(target, in: card, environment: values) }
            }
            .disabled(working || !requiredFilled(target))
            .accessibilityIdentifier("connector.card.approve.\(target.name)")
        } else if let url = target.connectURL {
            Button(target.kind == .connector ? "Connect" : "Sign in") { open(url, for: target) }
                .fontWeight(.semibold)
                .disabled(working)
                .accessibilityIdentifier("connector.card.connect.\(target.name)")
        } else if working || target.state == .initiated {
            ProgressView("Checking…")
        }
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

    private var waitNote: String {
        let minutes = max(1, Int(((operation.timeout ?? 300) / 60).rounded()))
        return "Your agent waits up to \(minutes) minute\(minutes == 1 ? "" : "s"), then goes on without it."
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
        case .authorize: "Allow"
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

    private func notNow() {
        browser.finish()
        let card = card
        let store = store
        Task { await store.skipAll(card) }
        dismiss()
    }
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
/// `-test-connector-card`: an agent asking to connect two apps and add a tool, with made-up names.
enum ConnectorCardFixture {
    static let launchArgument = "-test-connector-card"

    @MainActor
    static func rootView() -> some View { FixtureHost() }

    @MainActor
    private struct FixtureHost: View {
        @State private var store = ConnectorCardStore()
        @State private var identity = NSObject()
        @State private var answers: [String] = []
        @State private var answered: Set<String> = []

        var body: some View {
            NavigationStack {
                VStack(spacing: 12) {
                    Text("Chat").font(.bighelp(.title2))
                    Text(answers.isEmpty ? "No answers yet" : answers.joined(separator: "\n"))
                        .font(.bighelp(.footnote))
                        .accessibilityIdentifier("connector.fixture.answers")
                }
                .navigationTitle("Juniper")
            }
            .overlay { ConnectorCardOverlay(store: store) }
            .task { open() }
        }

        private func open() {
            let connection = DirectHermesPromptConnection(owner: UUID(), principalIdentity: "host",
                clientIdentity: ObjectIdentifier(identity), transportGeneration: .init(UUID()))
            store.beginConnection(connection) { method, params in
                let names = params["result"]?.object?["targets"]?.array?.compactMap { $0.object?["name"]?.string } ?? []
                answers.append("\(method) \(names.joined(separator: ","))")
                answered.formUnion(names)
                // Like Hermes: the operation settles once every row has its answer.
                return .object(["status": .string("ok"), "settled": .boolean(answered.count == 3)])
            }
            store.bind(profile: "juniper", runtimeID: "runtime", visibleSessionID: "chat", connection: connection)
            store.accept(.init(type: "connection.request", sessionID: "runtime", payload: [
                "op_id": .string("op-fixture"), "seq": .integer(1), "timeout_seconds": .integer(300),
                "deadline_at": .number(Date().addingTimeInterval(300).timeIntervalSince1970),
                "targets": .array([
                    .object(["name": .string("example_mail"), "kind": .string("connector"), "action": .string("connect"),
                             "state": .string("initiated"), "resolved": .boolean(false),
                             "connect_url": .string("https://connect.example.com/start/sample")]),
                    .object(["name": .string("example_notes"), "kind": .string("connector"), "action": .string("connect"),
                             "state": .string("expired"), "resolved": .boolean(false)]),
                    .object(["name": .string("weather"), "kind": .string("mcp"), "action": .string("install"),
                             "state": .string("pending"), "resolved": .boolean(false),
                             "required_env": .array([.object(["name": .string("WEATHER_API_KEY"), "required": .boolean(true),
                                                              "secret": .boolean(true), "default": .string(""),
                                                              "prompt": .string("Weather API key")])])]),
                ]),
            ], sequence: nil), connection: connection)
        }
    }
}
#endif
