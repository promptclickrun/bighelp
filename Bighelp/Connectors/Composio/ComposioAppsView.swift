import SwiftUI

/// Settings › Apps › Composio Apps: one Composio sign-in, then any of its apps by category.
@MainActor
struct ComposioAppsView: View {
    @State var model: ComposioAppsModel
    @State private var browser = ProviderSignInBrowser()
    @State private var agentFlow: MCPOAuthFlow?

    var body: some View {
        Form {
            if model.account.isSignedIn { signedIn } else { signedOut }
        }
        .bighelpFormSurface()
        .navigationTitle("Composio Apps")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.appear() }
        .refreshable {
            await model.refreshConnected()
            await model.refreshAgent()
        }
        .task(id: agentFlow?.id) {
            guard let flow = agentFlow else { return }
            await model.finishAgentSignIn(flow)
            browser.finish()
            agentFlow = nil
        }
        .accessibilityIdentifier("composio.apps")
    }

    // MARK: Signed out

    private var signedOut: some View {
        Section {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                Text("Connect hundreds of apps with Composio")
                    .font(.bighelp(.headline))
                Text("Sign in to Composio once. Then pick apps like your email, calendar or code, and your agent can use them.")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, BighelpTokens.space4)
            Button {
                Task { await model.signIn() }
            } label: {
                HStack {
                    Text("Sign in to Composio").fontWeight(.semibold)
                    if model.isSigningIn { Spacer(); ProgressView() }
                }
            }
            .disabled(model.isSigningIn)
            .accessibilityIdentifier("composio.sign-in")
            if let message = model.message {
                Text(message).font(.bighelp(.footnote)).foregroundStyle(.secondary)
            }
        } footer: {
            Text("You sign in on Composio's own page with your own Composio account. bighelp never sees your password.")
        }
    }

    // MARK: Signed in

    @ViewBuilder
    private var signedIn: some View {
        agentSection
        BighelpSearchField(text: $model.search, prompt: "Search apps", accessibilityIdentifier: "composio.search")
            .bighelpListSearchRow()
        if let message = model.message {
            Section { Text(message).foregroundStyle(.secondary) }
        }
        if !model.search.trimmingCharacters(in: .whitespaces).isEmpty {
            searchResults
        } else {
            connectedSection
            categoriesSection
        }
        Section {
            Button("Sign out of Composio", role: .destructive) { model.signOut() }
                .accessibilityIdentifier("composio.sign-out")
        } footer: {
            Text(model.account.email.map { "Signed in as \($0). This sign-in works on all your devices." }
                ?? "This sign-in works on all your devices.")
        }
    }

    @ViewBuilder
    private var agentSection: some View {
        if let host = model.hostName {
            let agent = model.agentName ?? "Your agent"
            Section {
                switch model.agent {
                case .ready:
                    Label("\(agent) on \(host) can use these apps", systemImage: "checkmark.circle.fill")
                        .accessibilityIdentifier("composio.agent.ready")
                case .needsPluginUpdate:
                    Label("Update the bighelp plugin on \(host) so your agent can use these apps.",
                          systemImage: "arrow.down.circle")
                        .accessibilityIdentifier("composio.agent.update-plugin")
                case .unknown:
                    Label("Checking \(host)…", systemImage: "hourglass")
                case .notInstalled, .turnedOff, .needsSignIn:
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        Text("Let \(agent) use these apps").font(.bighelp(.headline))
                        Text(agentDetail(host)).font(.bighelp(.footnote)).foregroundStyle(.secondary)
                    }
                    Button {
                        Task {
                            agentFlow = await model.turnOnForAgent { url in browser.start(url) }
                        }
                    } label: {
                        HStack {
                            Text(agentButtonTitle).fontWeight(.semibold)
                            if model.agentWorking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(model.agentWorking)
                    .accessibilityIdentifier("composio.agent.turn-on")
                }
            }
        }
    }

    private func agentDetail(_ host: String) -> String {
        switch model.agent {
        case .needsSignIn: "Sign in to the same Composio account for your agent on \(host)."
        default: "Turns on Composio on \(host), then you sign in to the same Composio account for your agent."
        }
    }

    private var agentButtonTitle: String {
        if case .needsSignIn = model.agent { return "Sign in for my agent" }
        return "Turn on for my agent"
    }

    @ViewBuilder
    private var connectedSection: some View {
        let apps = model.connectedApps
        Section("Connected") {
            if apps.isEmpty {
                Text(model.isLoadingConnections ? "Loading your apps…" : "No apps yet. Pick one below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(apps) { app in ComposioAppRow(model: model, app: app) }
        }
    }

    @ViewBuilder
    private var categoriesSection: some View {
        if let catalog = model.catalog {
            Section("Browse apps") {
                ForEach(catalog.categories) { category in
                    NavigationLink {
                        ComposioCategoryView(model: model, category: category)
                    } label: {
                        LabeledContent(category.name, value: "\(catalog.toolkits(in: category.id).count)")
                    }
                    .accessibilityIdentifier("composio.category.\(category.id)")
                }
            }
        } else if model.catalogFailed {
            Section {
                Text("The app list didn't load. You can still search for an app by name.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section { ProgressView().frame(maxWidth: .infinity) }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let found = model.catalog?.search(model.search) ?? []
        Section {
            if found.isEmpty {
                Text("No apps match.").foregroundStyle(.secondary)
            }
            ForEach(found.prefix(60)) { app in ComposioAppRow(model: model, app: app) }
        }
        .task(id: model.search) { await model.loadStatus(for: Array(found.prefix(50))) }
    }
}

/// One category's apps, most used first.
@MainActor
struct ComposioCategoryView: View {
    let model: ComposioAppsModel
    let category: ComposioCatalog.Category
    @State private var search = ""

    private var apps: [ComposioCatalog.Toolkit] {
        let all = model.catalog?.toolkits(in: category.id) ?? []
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            BighelpSearchField(text: $search, prompt: "Search \(category.name)",
                               accessibilityIdentifier: "composio.category.search")
                .bighelpListSearchRow()
            ForEach(apps) { app in ComposioAppRow(model: model, app: app) }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: search) { await model.loadStatus(for: apps) }
        .accessibilityIdentifier("composio.category.screen")
    }
}

/// An app: logo, name, and whether it's connected.
@MainActor
struct ComposioAppRow: View {
    let model: ComposioAppsModel
    let app: ComposioCatalog.Toolkit

    var body: some View {
        NavigationLink {
            ComposioAppDetailView(model: model, app: app)
        } label: {
            HStack(spacing: BighelpTokens.space12) {
                ConnectorLogo(url: app.logoURL, name: app.name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.bighelp(.body))
                    Text(detail).font(.bighelp(.footnote)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if model.isConnected(app.slug) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityLabel("Connected")
                }
            }
        }
        .accessibilityIdentifier("composio.app.\(app.slug)")
    }

    private var detail: String {
        if app.noAuth { return "Ready, no sign-in needed" }
        let active = model.connections[app.slug]?.accounts.filter(\.isActive) ?? []
        if active.count > 1 { return "\(active.count) accounts" }
        if let email = active.first?.email { return email }
        if model.isConnected(app.slug) { return "Connected" }
        return app.summary.isEmpty ? "Not connected" : app.summary
    }
}

/// One app: its accounts, Connect or Add another account, and Remove.
@MainActor
struct ComposioAppDetailView: View {
    let model: ComposioAppsModel
    let app: ComposioCatalog.Toolkit

    @State private var browser = ProviderSignInBrowser()
    @State private var pending = false
    @State private var removing: ComposioConnection.Account?
    @Environment(\.scenePhase) private var scenePhase

    private var accounts: [ComposioConnection.Account] {
        (model.connections[app.slug]?.accounts ?? []).filter { $0.isActive || $0.status.lowercased() == "failed" }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: BighelpTokens.space12) {
                    ConnectorLogo(url: app.logoURL, name: app.name, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.bighelp(.title3).weight(.semibold))
                        if !app.summary.isEmpty {
                            Text(app.summary).font(.bighelp(.subheadline)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, BighelpTokens.space4)
            }
            if app.noAuth {
                Section {
                    Text("This app needs no account. Your agent can use it once Composio is on for your agent.")
                        .foregroundStyle(.secondary)
                }
            } else {
                if !accounts.isEmpty {
                    Section("Accounts") {
                        ForEach(accounts) { account in
                            HStack {
                                Label(account.email ?? (account.isActive ? "Connected" : "Needs sign-in"),
                                      systemImage: account.isActive ? "checkmark.circle.fill" : "exclamationmark.circle")
                                Spacer(minLength: 0)
                                Button("Remove", role: .destructive) { removing = account }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.red)
                                    .disabled(model.busySlug == app.slug)
                                    .accessibilityIdentifier("composio.app.remove.\(account.id)")
                            }
                        }
                    }
                }
                Section {
                    Button {
                        Task { await open() }
                    } label: {
                        HStack {
                            Text(accounts.contains(where: \.isActive) ? "Add another account" : "Connect")
                                .fontWeight(.semibold)
                            if model.busySlug == app.slug || pending { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(model.busySlug == app.slug)
                    .accessibilityIdentifier("composio.app.connect")
                } footer: {
                    Text("You sign in to \(app.name) on its own page, through Composio.")
                }
            }
            if let message = model.message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .bighelpFormSurface()
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadStatus(for: [app]) }
        .onChange(of: scenePhase) { _, phase in
            // On the Mac the sign-in opens in the browser; coming back is the signal.
            if phase == .active, pending { Task { await finish() } }
        }
        .confirmationDialog(
            "Remove this \(app.name) account?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            if let account = removing {
                Button("Remove", role: .destructive) {
                    removing = nil
                    Task { await model.remove(app.slug, account: account.id) }
                }
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Your agent can't use this account until you connect it again.")
        }
        .accessibilityIdentifier("composio.app.screen")
    }

    private func open() async {
        guard let url = await model.connectLink(app.slug) else { return }
        pending = true
        browser.start(url) { Task { @MainActor in await finish() } }
    }

    private func finish() async {
        guard pending else { return }
        pending = false
        browser.finish()
        await model.confirm(app.slug)
    }
}
