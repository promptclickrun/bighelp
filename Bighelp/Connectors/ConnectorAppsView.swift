import SwiftUI

/// Settings › Apps: the apps your agents can use through Hermes' connectors.
@MainActor
struct ConnectorAppsView: View {
    @State var model: ConnectorAppsModel

    var body: some View {
        Form {
            switch model.phase {
            case .intro: intro
            case .loading:
                Section { ProgressView("Loading apps…").frame(maxWidth: .infinity) }
            case .turnedOff:
                note("Apps are turned off on this computer.",
                     detail: "Turn on tools.connectors in Hermes' settings, then come back.")
            case .needsUpdate:
                note("Update Hermes to connect apps.",
                     detail: "Your computer runs a Hermes that's older than app connections.")
            case .failed(let message):
                note(message, detail: nil)
                Section { Button("Try again") { Task { await model.load() } } }
            case .ready: list
            }
        }
        .bighelpFormSurface()
        .navigationTitle("Apps")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.appear() }
        .refreshable { if model.phase == .ready { await model.load() } }
        .accessibilityIdentifier("connector.apps")
    }

    private var intro: some View {
        Section {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                Text("Let your agents use your other apps")
                    .font(.bighelp(.headline))
                Text("Sign in to an app once, like your email or notes, and your agents can use it in any chat.")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, BighelpTokens.space4)
            Button("Set up apps") { Task { await model.setUp() } }
                .fontWeight(.semibold)
                .accessibilityIdentifier("connector.apps.set-up")
        } footer: {
            Text("Your sign-ins are kept by the Hermes app service, not on this phone. Hermes makes a free account there for your computer.")
        }
    }

    @ViewBuilder
    private var list: some View {
        BighelpSearchField(text: $model.search, prompt: "Search apps", accessibilityIdentifier: "connector.apps.search")
            .bighelpListSearchRow()
        if let message = model.message {
            Section { Text(message).foregroundStyle(.secondary) }
        }
        if !model.connected.isEmpty {
            Section("Connected") {
                ForEach(model.connected) { app in appRow(app) }
            }
        }
        Section(model.connected.isEmpty ? "Apps" : "More apps") {
            if model.others.isEmpty {
                Text(model.search.isEmpty ? "Every app is connected." : "No apps match.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.others) { app in appRow(app) }
        }
    }

    private func appRow(_ app: ConnectorAppsModel.App) -> some View {
        NavigationLink {
            ConnectorAppDetailView(model: model, appID: app.id)
        } label: {
            HStack(spacing: BighelpTokens.space12) {
                ConnectorLogo(url: app.logoURL, name: app.name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.bighelp(.body))
                    Text(app.isConnected ? accountSummary(app) : app.summary)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityIdentifier("connector.apps.app.\(app.id)")
    }

    private func accountSummary(_ app: ConnectorAppsModel.App) -> String {
        let live = app.liveAccounts.filter(\.isWorking)
        return live.count == 1 ? (live.first?.title ?? "Connected") : "\(live.count) accounts"
    }

    private func note(_ title: String, detail: String?) -> some View {
        Section {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(title).font(.bighelp(.headline))
                if let detail { Text(detail).foregroundStyle(.secondary) }
            }
            .padding(.vertical, BighelpTokens.space4)
        }
    }
}

/// One app: its accounts, Connect or Add another account, Rename and Remove.
@MainActor
struct ConnectorAppDetailView: View {
    let model: ConnectorAppsModel
    let appID: String

    @State private var browser = ProviderSignInBrowser()
    @State private var naming: NameRequest?
    @State private var typedName = ""
    @State private var removing: ConnectorAppsModel.Account?
    @Environment(\.scenePhase) private var scenePhase

    private enum NameRequest: Identifiable {
        case newAccount
        case rename(ConnectorAppsModel.Account)
        var id: String {
            switch self {
            case .newAccount: "new"
            case .rename(let account): account.id
            }
        }
    }

    private var app: ConnectorAppsModel.App? { model.apps.first { $0.id == appID } }

    var body: some View {
        Form {
            if let app {
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
                if let message = model.message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
                if !app.liveAccounts.isEmpty {
                    Section {
                        ForEach(app.liveAccounts) { account in accountRow(account, in: app) }
                    } header: {
                        Text("Accounts")
                    } footer: {
                        if app.liveAccounts.count > 1 {
                            Text("Your agent asks which account to use, by its name.")
                        }
                    }
                }
                Section {
                    if model.signIn?.appID == app.id {
                        ProgressView("Waiting for the sign-in…")
                        Button("Stop waiting") { model.stopWaiting(); browser.finish() }
                            .accessibilityIdentifier("connector.apps.stop-waiting")
                    } else if app.liveAccounts.isEmpty {
                        Button("Connect") { Task { await connect(app) } }
                            .fontWeight(.semibold)
                            .disabled(model.isWorking(app.id))
                            .accessibilityIdentifier("connector.apps.connect")
                    } else {
                        Button("Add another account") { typedName = ""; naming = .newAccount }
                            .disabled(model.isWorking(app.id))
                            .accessibilityIdentifier("connector.apps.add-account")
                    }
                }
            }
        }
        .bighelpFormSurface()
        .navigationTitle(app?.name ?? "App")
        .navigationBarTitleDisplayMode(.inline)
        .alert(alertTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }), presenting: naming) { request in
            TextField("Name, like work or home", text: $typedName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("connector.apps.name-field")
            Button("Cancel", role: .cancel) {}
            Button(saveTitle(request)) { save(request) }
        } message: { _ in
            Text("Your agent uses this name to pick the account.")
        }
        .confirmationDialog(removing.map { "Remove \($0.title)?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { account in
            Button("Remove", role: .destructive) { Task { await model.remove(account) } }
                .accessibilityIdentifier("connector.apps.remove-confirm")
        } message: { _ in
            Text("Your agents can't use this account after that.")
        }
        .onChange(of: scenePhase) { _, phase in
            // The Mac signs in in the default browser; coming back to bighelp means done.
            guard phase == .active, model.signIn?.appID == appID else { return }
            Task { await model.pageClosed() }
        }
        .onDisappear { browser.finish() }
        .accessibilityIdentifier("connector.apps.detail.\(appID)")
    }

    private func accountRow(_ account: ConnectorAppsModel.Account, in app: ConnectorAppsModel.App) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.title).font(.bighelp(.body))
                if account.alias != nil, account.label != account.title {
                    Text(account.label).font(.bighelp(.footnote)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if account.isWorking {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
            } else {
                Button("Sign in again") { Task { await connect(app, repairing: account) } }
                    .font(.bighelp(.footnote))
            }
            Menu {
                Button("Rename", systemImage: "pencil") { typedName = account.alias ?? ""; naming = .rename(account) }
                Button("Remove", systemImage: "trash", role: .destructive) { removing = account }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(.rect)
            }
            .accessibilityLabel("More for \(account.title)")
            .accessibilityIdentifier("connector.apps.account-menu.\(account.id)")
        }
        .accessibilityIdentifier("connector.apps.account.\(account.id)")
    }

    private var alertTitle: String {
        guard let naming else { return "" }
        return switch naming {
        case .newAccount: "Name the new account"
        case .rename: "Rename account"
        }
    }

    private func saveTitle(_ request: NameRequest) -> String {
        if case .newAccount = request { return "Continue" }
        return "Save"
    }

    private func save(_ request: NameRequest) {
        let name = typedName
        guard let app else { return }
        switch request {
        case .newAccount:
            guard let alias = ConnectorAppsModel.alias(name) else {
                model.message = "Use 1 to 32 lowercase letters, numbers or dashes, like work or home."
                return
            }
            Task { await connect(app, alias: alias) }
        case .rename(let account):
            Task { _ = await model.rename(account, in: app, to: name) }
        }
    }

    private func connect(_ app: ConnectorAppsModel.App, alias: String? = nil,
                         repairing account: ConnectorAppsModel.Account? = nil) async {
        guard let url = await model.connect(app, alias: alias, repairing: account) else { return }
        let model = model
        browser.start(url) {
            Task { await model.pageClosed() }
        }
        // Closes the page for the person once Hermes sees the account.
        _ = await model.watchSignIn()
        browser.finish()
    }
}
