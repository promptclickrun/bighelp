import SwiftUI

/// Settings › Apps › Native App Connections: the apps your agents can use through Hermes'
/// connectors, by the catalog's categories. Connect signs in from the row; a connected app opens
/// its accounts.
@MainActor
struct ConnectorAppsView: View {
    @State var model: ConnectorAppsModel
    @State private var browser = ProviderSignInBrowser()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            switch model.phase {
            case .loading:
                Section { ProgressView("Loading apps…").frame(maxWidth: .infinity) }
                    .accessibilityIdentifier("connector.apps.loading")
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
        .navigationTitle("Native App Connections")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.appear() }
        .refreshable { if model.phase == .ready { await model.load() } }
        .onChange(of: scenePhase) { _, phase in
            // The Mac signs in in the default browser; coming back to bighelp means done.
            guard phase == .active, model.signIn != nil else { return }
            Task { await model.pageClosed() }
        }
        .onDisappear { browser.finish() }
        .accessibilityIdentifier("connector.apps")
    }

    @ViewBuilder
    private var list: some View {
        Section {
            BighelpSearchField(text: $model.search, prompt: "Search apps", accessibilityIdentifier: "connector.apps.search")
                .bighelpListSearchRow()
            if model.categoryNames.count > 1 {
                ConnectorCategoryChips(names: model.categoryNames, selection: $model.category)
                    .templateChipsRow()
            }
        }
        if let message = model.message {
            Section { Text(message).foregroundStyle(.secondary) }
        }
        if !model.connected.isEmpty {
            Section("Connected") {
                ForEach(model.connected) { app in connectedRow(app) }
            }
        }
        let sections = model.sections
        if sections.isEmpty, model.connected.isEmpty {
            Section {
                Text(model.search.isEmpty && model.category == nil ? "Every app is connected." : "No apps match.")
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(sections) { category in
            Section {
                ForEach(category.apps) { app in appRow(app) }
            } header: {
                Text(category.name)
                    .accessibilityIdentifier("connector.apps.section.\(category.name)")
            }
        }
        Section {
        } footer: {
            Text("Your agents can use the apps you connect, in any chat. Hermes keeps your sign-ins in its app service, and makes a free account there for this computer when you connect your first app.")
        }
    }

    private func connectedRow(_ app: ConnectorAppsModel.App) -> some View {
        NavigationLink {
            ConnectorAppDetailView(model: model, appID: app.id)
        } label: {
            ConnectorAppLabel(app: app, detail: accountSummary(app))
        }
        .accessibilityIdentifier("connector.apps.app.\(app.id)")
    }

    private func appRow(_ app: ConnectorAppsModel.App) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            ConnectorAppLabel(app: app, detail: app.summary)
            Spacer(minLength: 0)
            if model.signIn?.appID == app.id {
                Button("Stop") { model.stopWaiting(); browser.finish() }
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .accessibilityLabel("Stop waiting for \(app.name)")
                    .accessibilityIdentifier("connector.apps.stop-waiting")
            } else {
                Button("Connect") {
                    Task { await ConnectorAppSignIn.connect(app, model: model, browser: browser) }
                }
                .font(.bighelp(.subheadline).weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(theme.action)
                .disabled(model.isWorking(app.id) || model.signIn != nil)
                .accessibilityLabel("Connect \(app.name)")
                .accessibilityIdentifier("connector.apps.connect.\(app.id)")
            }
        }
        .accessibilityElement(children: .contain)
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

    @BighelpThemeReader private var theme
}

/// An app's logo, name and one line about it, in the list and on its page.
private struct ConnectorAppLabel: View {
    let app: ConnectorAppsModel.App
    let detail: String

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            ConnectorLogo(url: app.logoURL, name: app.name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.bighelp(.body))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

/// All, then each category the catalog has. Tapping the chosen one again goes back to All.
private struct ConnectorCategoryChips: View {
    let names: [String]
    @Binding var selection: String?
    @BighelpThemeReader private var theme

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: BighelpTokens.space8) {
                chip(nil, title: String(localized: "All"))
                ForEach(names, id: \.self) { chip($0, title: $0) }
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Categories")
        .accessibilityIdentifier("connector.apps.categories")
    }

    private func chip(_ name: String?, title: String) -> some View {
        let isOn = selection == name
        return Button {
            withAnimation(.snappy) { selection = isOn ? nil : name }
        } label: {
            Text(title)
                .lineLimit(1)
                .font(.bighelp(.subheadline).weight(.semibold))
                .foregroundStyle(isOn ? theme.actionForeground : theme.primaryText)
                .padding(.horizontal, BighelpTokens.space12)
                .frame(minHeight: chipHeight)
                .background(isOn ? theme.action : theme.surface, in: .capsule)
                .overlay { Capsule().strokeBorder(isOn ? .clear : theme.border) }
                .contentShape(.capsule)
        }
        .bighelpPlainButtonStyle(.capsule)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("connector.apps.category.\(name ?? "all")")
    }

    private var chipHeight: CGFloat {
        #if os(visionOS)
        BighelpTokens.hitTarget
        #else
        BighelpTokens.scaled(36)
        #endif
    }
}

/// Signs in to an app: opens Hermes' page, then closes it for the person once Hermes sees the account.
@MainActor
enum ConnectorAppSignIn {
    static func connect(_ app: ConnectorAppsModel.App, model: ConnectorAppsModel, browser: ProviderSignInBrowser,
                        alias: String? = nil, repairing account: ConnectorAppsModel.Account? = nil) async {
        guard let url = await model.connect(app, alias: alias, repairing: account) else { return }
        browser.start(url) {
            Task { await model.pageClosed() }
        }
        _ = await model.watchSignIn()
        browser.finish()
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
        await ConnectorAppSignIn.connect(app, model: model, browser: browser, alias: alias, repairing: account)
    }
}
