import SwiftUI
import UniformTypeIdentifiers

/// Where the vault's pages go: a website, a saved card or address, or the password managers.
enum CredentialVaultRoute: Hashable {
    case site(String)
    case item(String)
    case managers
}

/// The Credential Vault (a bot's profile › Info, and ☰ › Secure credential vault): what an
/// agent's browser can sign in and check out with. The wallet holds saved cards and addresses,
/// each once however many websites use it; under it, every website and what's saved for it.
/// Lists only names and websites; secrets are typed here once and go straight to Hermes.
struct CredentialVaultView: View {
    @Bindable var model: CredentialVaultModel
    @Environment(\.dismiss) private var dismiss
    @State private var adding: CredentialVaultAddModel?
    @State private var editing: CredentialVaultGroup?
    @State private var unlocking: CredentialVaultSource?
    @State private var isPickingFile = false
    @State private var found: FoundLogins?
    @BighelpThemeReader private var theme

    /// A read export, held only while its preview sheet is open.
    struct FoundLogins: Identifiable {
        let id = UUID()
        let file: CredentialVaultImport
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    intro
                    if let message = model.message {
                        CredentialVaultProblem(text: message).accessibilityIdentifier("vault.message")
                    }
                    content
                }
                .modifier(CredentialVaultColumn())
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(String(localized: "Credential Vault"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                        #endif
                        .accessibilityIdentifier("vault.done")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.state == .ready {
                    Button(String(localized: "Add a Website")) { add() }
                        .buttonStyle(SimpleBotsPrimaryButtonStyle())
                        .padding(.horizontal, BighelpTokens.space20)
                        .padding(.vertical, BighelpTokens.space12)
                        .background(theme.canvas.ignoresSafeArea(edges: .bottom))
                        .accessibilityIdentifier("vault.add")
                }
            }
            .bighelpRefreshable { await model.load() }
            .navigationDestination(for: CredentialVaultRoute.self) { route in
                switch route {
                case .site(let origin):
                    CredentialVaultSitePage(model: model, origin: origin, onAdd: { add(site: $0, parts: $1) },
                                            onEdit: { editing = $0 })
                case .item(let id):
                    CredentialVaultItemPage(model: model, groupID: id, onEdit: { editing = $0 })
                case .managers:
                    CredentialVaultManagersPage(model: model) { unlocking = $0 }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vault.home")
        .task { await model.load() }
        .bighelpSheet(item: $adding) { CredentialVaultAddFlow(model: $0).bighelpSheetSize(.standard) }
        .bighelpSheet(item: $editing) { CredentialVaultEditView(model: model, group: $0).bighelpSheetSize(.standard) }
        .bighelpSheet(item: $unlocking) { source in
            CredentialVaultUnlockView(model: model, source: source).bighelpSheetSize(.compact)
        }
        .bighelpSheet(item: $found) { CredentialVaultImportView(model: model, file: $0.file).bighelpSheetSize(.standard) }
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
            if case .success(let url) = result { read(url) }
        }
    }

    @ViewBuilder
    private var intro: some View {
        if model.agents.count > 1 {
            SimpleBotsCard {
                SimpleBotsRow(title: String(localized: "Agent")) {
                    Picker(String(localized: "Agent"), selection: Binding(get: { model.agentID },
                                                                          set: { id in Task { await model.select(agentID: id) } })) {
                        ForEach(model.agents) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("vault.agent")
                }
            }
        }
        if !(model.state == .ready && model.items.isEmpty) {
            Text("What \(model.agentName) can sign in and check out with. It's kept on your computer, and \(model.agentName) never sees the passwords or card numbers.")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, BighelpTokens.space20)
                .padding(.bottom, BighelpTokens.space8)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView(String(localized: "Opening the vault…"))
                .frame(maxWidth: .infinity, minHeight: 160)
        case .unsupported:
            Text("This needs a newer Hermes on your computer. Update Hermes, then come back.")
                .font(.bighelp(.body))
                .foregroundStyle(theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: 160)
                .accessibilityIdentifier("vault.unsupported")
        case .failed:
            VStack(spacing: BighelpTokens.space12) {
                Text("The vault didn't answer. Check your connection to your computer.")
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.center)
                Button(String(localized: "Try Again")) { Task { await model.load() } }
                    .buttonStyle(SimpleBotsPrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        case .ready:
            if model.items.isEmpty {
                firstOpen
            } else {
                saved
            }
        }
    }

    /// Nothing saved yet: what the vault is for, and the two promises that matter.
    private var firstOpen: some View {
        VStack(spacing: BighelpTokens.space16) {
            Image(systemName: "lock.shield")
                .font(.bighelp(.largeTitle))
                .foregroundStyle(theme.primaryText)
                .frame(width: 96, height: 96)
                .background(theme.surface, in: Circle())
                .accessibilityHidden(true)
                .padding(.top, BighelpTokens.space32)
            Text("Let \(model.agentName) sign in and check out for you")
                .font(.bighelp(.title2, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
            Text("Save a website's login, card and address once. \(model.agentName) fills them in on that website and never sees them.")
                .font(.bighelp(.body))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            SimpleBotsCard {
                SimpleBotsRow(title: String(localized: "Kept on your computer. bighelp doesn't keep a copy."),
                              leading: Image(systemName: "lock")) { EmptyView() }
                SimpleBotsDivider()
                SimpleBotsRow(title: String(localized: "Before \(model.agentName) pays with a card, you're asked every time."),
                              leading: Image(systemName: "creditcard")) { EmptyView() }
            }
            .padding(.top, BighelpTokens.space16)
            moreLinks
        }
        .padding(.horizontal, BighelpTokens.space12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vault.empty")
    }

    private var saved: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            if !model.wallet.isEmpty {
                SimpleBotsSectionLabel(title: String(localized: "Wallet"))
                ScrollView(.horizontal) {
                    HStack(spacing: BighelpTokens.space12) {
                        ForEach(model.wallet) { group in
                            NavigationLink(value: CredentialVaultRoute.item(group.id)) {
                                CredentialVaultWalletTile(group: group)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("vault.wallet.\(group.firstItemID)")
                        }
                    }
                    .padding(.vertical, BighelpTokens.space4)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
            if !model.sites.isEmpty {
                SimpleBotsSectionLabel(title: String(localized: "Websites"))
                    .padding(.top, model.wallet.isEmpty ? 0 : BighelpTokens.space16)
                SimpleBotsCard {
                    ForEach(Array(model.sites.enumerated()), id: \.element.id) { index, site in
                        if index > 0 { SimpleBotsDivider() }
                        NavigationLink(value: CredentialVaultRoute.site(site.origin)) {
                            CredentialVaultSiteRow(site: site, sourceName: sourceName)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("vault.site.\(site.name)")
                    }
                }
            }
            moreLinks.padding(.top, BighelpTokens.space16)
        }
    }

    /// Password managers and Import, side by side, or stacked when larger text can't fit them.
    private var moreLinks: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: BighelpTokens.space8) { managersLink; importButton }
            VStack(spacing: BighelpTokens.space8) { managersLink; importButton }
        }
    }

    private var managersLink: some View {
        NavigationLink(value: CredentialVaultRoute.managers) {
            CredentialVaultPill(title: String(localized: "Password managers"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("vault.managers")
    }

    private var importButton: some View {
        Button {
            #if DEBUG
            if let fixture = CredentialVaultImport.testFixture {
                found = (try? CredentialVaultImport.read(fixture)).map { FoundLogins(file: $0) }
                return
            }
            #endif
            isPickingFile = true
        } label: {
            CredentialVaultPill(title: String(localized: "Import from a file"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("vault.import")
    }

    private func add(site: String? = nil, parts: Set<CredentialVaultAddModel.Part> = [.login]) {
        model.message = nil
        adding = CredentialVaultAddModel(vault: model, site: site, parts: parts)
    }

    private func sourceName(_ name: String) -> String {
        model.sources.first { $0.name == name }?.displayName ?? name
    }

    /// Reads the export where it is, in memory; it's never copied into bighelp.
    private func read(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= CredentialVaultImport.maximumBytes else { throw CredentialVaultImport.Problem.tooLarge }
            found = FoundLogins(file: try CredentialVaultImport.read(Data(contentsOf: url, options: .uncached)))
            model.message = nil
        } catch let problem as CredentialVaultImport.Problem {
            model.message = problem.message
        } catch {
            model.message = String(localized: "That file couldn't be opened. If it's in iCloud Drive, download it first.")
        }
    }
}

/// A website in the list: its letter, its name, the login it signs in with, and what's saved there.
private struct CredentialVaultSiteRow: View {
    let site: CredentialVaultSite
    let sourceName: (String) -> String
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            CredentialVaultMonogram(name: site.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(site.name)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                Text(detail)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: BighelpTokens.space8)
            HStack(spacing: 6) {
                ForEach(site.kinds, id: \.self) { kind in
                    Image(systemName: kind.symbol)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .accessibilityHidden(true)
            SimpleBotsDisclosure()
        }
        .padding(.horizontal, BighelpTokens.space20)
        .padding(.vertical, BighelpTokens.space12)
        .frame(minHeight: 64)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(site.kinds.map { CredentialVaultGroup.title($0) }.joined(separator: ", "))
    }

    private var detail: String {
        guard let login = site.logins.first else { return String(localized: "No login") }
        var parts = [login.identifier ?? login.label]
        if login.generatesCodes { parts.append(String(localized: "makes its codes")) }
        if !login.isLocal { parts = [String(localized: "From \(sourceName(login.source))")] }
        return parts.joined(separator: " · ")
    }
}

/// One website's page: what an agent can use there, adding more, and removing the website.
private struct CredentialVaultSitePage: View {
    let model: CredentialVaultModel
    let origin: String
    let onAdd: (String, Set<CredentialVaultAddModel.Part>) -> Void
    let onEdit: (CredentialVaultGroup) -> Void
    @State private var confirmsRemove = false
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                if let message = model.message {
                    CredentialVaultProblem(text: message).accessibilityIdentifier("vault.message")
                }
                if let site = model.site(origin) {
                    content(site)
                } else {
                    Text("Nothing is saved for this website anymore.")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .modifier(CredentialVaultColumn())
        }
        .background(theme.canvas.ignoresSafeArea())
        // The page's own header names the website; the bar doesn't say it again.
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vault.site-page")
        .onAppear { model.message = nil }
        .onChange(of: model.site(origin) == nil) { _, isGone in if isGone { dismiss() } }
        .confirmationDialog(String(localized: "Remove \(CredentialVault.siteName(origin))?"), isPresented: $confirmsRemove,
                            titleVisibility: .visible) {
            Button(String(localized: "Remove"), role: .destructive) {
                // The page closes once the website is gone; a failed remove keeps it open with the reason.
                guard let site = model.site(origin) else { return }
                Task { await model.remove(site) }
            }
        } message: {
            Text("\(model.agentName) won't be able to use what's saved here. A card or address used only on this website is removed too.")
        }
    }

    @ViewBuilder
    private func content(_ site: CredentialVaultSite) -> some View {
        VStack(spacing: BighelpTokens.space8) {
            CredentialVaultMonogram(name: site.name, size: 72)
            Text(site.name)
                .font(.bighelp(.title2, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
            Text("\(model.agentName) can use these on this website.")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, BighelpTokens.space16)
        .accessibilityElement(children: .combine)

        SimpleBotsCard {
            ForEach(site.items) { item in
                row(item)
                SimpleBotsDivider()
            }
            CredentialVaultLinkRow(title: String(localized: "Add to this website"), identifier: "vault.site.add") {
                let missing = Set(CredentialVaultAddModel.Part.allCases.filter { part in
                    !site.kinds.contains(part.kind)
                })
                onAdd(site.origin, missing.isEmpty ? [.card] : missing)
            }
        }
        if site.hasLocalItems {
            SimpleBotsCard {
                Button { confirmsRemove = true } label: {
                    Text("Remove this website")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.danger)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(.horizontal, BighelpTokens.space20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(model.isWorking)
                .accessibilityIdentifier("vault.site.remove")
            }
            .padding(.top, BighelpTokens.space16)
            CredentialVaultNote(text: String(localized: "Removes the login here and stops using cards and addresses here. One used only on this website is removed too."))
        }
    }

    @ViewBuilder
    private func row(_ item: CredentialVaultItem) -> some View {
        let group = model.groups.first { $0.items.contains { $0.id == item.id } }
        switch item.kind {
        case .login:
            Button { if item.isLocal, let group { onEdit(group) } } label: {
                SimpleBotsRow(title: item.identifier ?? item.label, detail: loginDetail(item),
                              leading: Image(systemName: item.kind.symbol)) {
                    if item.isLocal { SimpleBotsDisclosure() }
                }
            }
            .buttonStyle(.plain)
            .disabled(!item.isLocal)
            .accessibilityHint(item.isLocal ? String(localized: "Opens it to change the password") : "")
            .accessibilityIdentifier("vault.site-item.\(item.id)")
        case .payment, .address:
            if let group {
                NavigationLink(value: CredentialVaultRoute.item(group.id)) {
                    SimpleBotsRow(title: item.label, detail: item.kind == .payment
                                  ? String(localized: "Card · You're asked before each use") : String(localized: "Address"),
                                  leading: Image(systemName: item.kind.symbol))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("vault.site-item.\(item.id)")
            }
        }
    }

    private func loginDetail(_ item: CredentialVaultItem) -> String {
        var parts = [String(localized: "Login")]
        if item.generatesCodes { parts.append(String(localized: "Makes its own codes")) }
        if !item.isLocal {
            let source = model.sources.first { $0.name == item.source }?.displayName ?? item.source
            parts.append(String(localized: "From \(source)"))
        }
        return parts.joined(separator: " · ")
    }
}

/// A saved card's or address's page: its face, the websites that use it, adding one without
/// typing it again, changing its details and removing it.
private struct CredentialVaultItemPage: View {
    let model: CredentialVaultModel
    let groupID: String
    let onEdit: (CredentialVaultGroup) -> Void
    @State private var asksSite = false
    @State private var typedSite = ""
    @State private var confirmsRemove = false
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                if let message = model.message {
                    CredentialVaultProblem(text: message).accessibilityIdentifier("vault.message")
                }
                if let group = model.group(groupID) {
                    content(group)
                } else {
                    Text("This isn't saved anymore.")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .modifier(CredentialVaultColumn())
        }
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle(model.group(groupID).map { $0.typedLabel.isEmpty ? $0.kindTitle : $0.typedLabel } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vault.item-page")
        .onAppear { model.message = nil }
        // Renamed or given another number in Change details, it's another item now: back to the list.
        .onChange(of: model.group(groupID) == nil) { _, isGone in if isGone { dismiss() } }
        .alert(String(localized: "Use on another website"), isPresented: $asksSite) {
            TextField(String(localized: "Website, like example.com"), text: $typedSite)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("vault.item.site-field")
            Button(String(localized: "Cancel"), role: .cancel) { typedSite = "" }
            Button(String(localized: "Add")) {
                let site = typedSite
                typedSite = ""
                guard let group = model.group(groupID) else { return }
                Task { _ = await model.use(group, on: site) }
            }
        } message: {
            Text("It's copied on your computer, so nothing is typed again.")
        }
        .confirmationDialog(removeTitle, isPresented: $confirmsRemove, titleVisibility: .visible) {
            Button(String(localized: "Remove"), role: .destructive) {
                guard let group = model.group(groupID) else { return }
                Task { await model.remove(group) }
            }
        } message: {
            Text("\(model.agentName) won't be able to use it on any website anymore.")
        }
    }

    private var removeTitle: String {
        model.group(groupID)?.kind == .payment ? String(localized: "Remove this card?") : String(localized: "Remove this address?")
    }

    @ViewBuilder
    private func content(_ group: CredentialVaultGroup) -> some View {
        HStack {
            Spacer(minLength: 0)
            if group.kind == .payment {
                CredentialVaultCardFace(group: group, isLarge: true)
            } else {
                CredentialVaultAddressFace(group: group, isLarge: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, BighelpTokens.space12)
        Text(group.kind == .payment
             ? String(localized: "\(model.agentName) can pay with this card only on these websites, and you're asked first every time.")
             : String(localized: "\(model.agentName) can fill this address only on these websites."))
            .font(.bighelp(.subheadline))
            .foregroundStyle(theme.secondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, BighelpTokens.space20)

        SimpleBotsSectionLabel(title: String(localized: "Used on")).padding(.top, BighelpTokens.space16)
        SimpleBotsCard {
            if group.origins.isEmpty {
                SimpleBotsRow(title: String(localized: "Not on a website yet"),
                              detail: String(localized: "\(model.agentName) can't use it until you add one.")) { EmptyView() }
                SimpleBotsDivider()
            }
            ForEach(group.origins, id: \.self) { origin in
                HStack(spacing: BighelpTokens.space12) {
                    CredentialVaultMonogram(name: CredentialVault.siteName(origin), size: 32)
                    Text(CredentialVault.siteName(origin))
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.primaryText)
                    Spacer(minLength: BighelpTokens.space8)
                    if group.origins.count > 1 {
                        Button(String(localized: "Stop")) { Task { await model.stop(group, on: origin) } }
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.secondaryText)
                            .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                            .contentShape(.rect)
                            .buttonStyle(.plain)
                            .disabled(model.isWorking)
                            .accessibilityLabel(String(localized: "Stop using it on \(CredentialVault.siteName(origin))"))
                            .accessibilityIdentifier("vault.item.stop.\(CredentialVault.siteName(origin))")
                    }
                }
                .padding(.leading, BighelpTokens.space20)
                .padding(.trailing, BighelpTokens.space12)
                .frame(minHeight: 60)
                SimpleBotsDivider()
            }
            CredentialVaultLinkRow(title: String(localized: "Use on another website"), identifier: "vault.item.use-on-site") {
                if model.canLink { asksSite = true } else { onEdit(group) }
            }
            .disabled(model.isWorking)
        }
        CredentialVaultNote(text: model.canLink
            ? String(localized: "Adding a website copies it on your computer. You don't type it again.")
            : String(localized: "To add a website without typing it again, update the bighelp plugin on your computer."))

        SimpleBotsCard {
            CredentialVaultLinkRow(title: String(localized: "Change details"), systemImage: "pencil",
                                   identifier: "vault.item.change") { onEdit(group) }
            SimpleBotsDivider()
            Button { confirmsRemove = true } label: {
                Text(group.kind == .payment ? String(localized: "Remove Card") : String(localized: "Remove Address"))
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.danger)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .padding(.horizontal, BighelpTokens.space20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(model.isWorking)
            .accessibilityIdentifier("vault.item.remove")
        }
        .padding(.top, BighelpTokens.space16)
    }
}

/// Password managers the computer has: on or off, and unlocked so an agent can use their logins.
private struct CredentialVaultManagersPage: View {
    let model: CredentialVaultModel
    let onUnlock: (CredentialVaultSource) -> Void
    @BighelpThemeReader private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                if model.managers.isEmpty {
                    CredentialVaultNote(text: String(localized: "1Password and Bitwarden show up here when their command-line tools are installed on your computer."))
                } else {
                    SimpleBotsCard {
                        ForEach(Array(model.managers.enumerated()), id: \.element.id) { index, source in
                            if index > 0 { SimpleBotsDivider() }
                            manager(source)
                        }
                    }
                    CredentialVaultNote(text: String(localized: "\(model.agentName) can use logins from an unlocked manager. It stays unlocked on your computer for 30 minutes after its last use."))
                }
                if let message = model.message { CredentialVaultProblem(text: message) }
            }
            .modifier(CredentialVaultColumn())
        }
        .background(theme.canvas.ignoresSafeArea())
        .bighelpSwitches()
        .navigationTitle(String(localized: "Password managers"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func manager(_ source: CredentialVaultSource) -> some View {
        SimpleBotsRow(title: source.displayName,
                      detail: !source.enabled ? String(localized: "Off")
                          : source.unlocked ? String(localized: "Unlocked") : String(localized: "Locked")) {
            Toggle(source.displayName, isOn: Binding(get: { source.enabled },
                                                     set: { on in Task { await model.setEnabled(source, on) } }))
                .labelsHidden()
                .disabled(model.isWorking)
        }
        .accessibilityIdentifier("vault.source.\(source.name)")
        if source.enabled {
            SimpleBotsDivider()
            if source.unlocked {
                CredentialVaultLinkRow(title: String(localized: "Lock \(source.displayName)"), systemImage: "lock",
                                       identifier: "vault.lock.\(source.name)") { Task { await model.lock(source) } }
            } else {
                CredentialVaultLinkRow(title: String(localized: "Unlock \(source.displayName)"), systemImage: "lock.open",
                                       identifier: "vault.unlock.\(source.name)") { onUnlock(source) }
            }
        }
    }
}

// MARK: - Faces and tiles

/// A website's first letter on a rounded tile, in place of a picture the app doesn't have.
struct CredentialVaultMonogram: View {
    let name: String
    var size: CGFloat = 36
    @BighelpThemeReader private var theme

    var body: some View {
        let letter = (name.hasPrefix("www.") ? name.dropFirst(4) : Substring(name)).first.map { String($0).uppercased() } ?? "?"
        Text(letter)
            .font(size > 48 ? .bighelp(.title, weight: .semibold) : .bighelp(.body, weight: .semibold))
            .foregroundStyle(theme.primaryText)
            .frame(width: size, height: size)
            .background(size > 48 ? theme.surface : theme.canvas,
                        in: .rect(cornerRadius: size * 0.28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(theme.separator, lineWidth: size > 48 ? 0 : BighelpTokens.hairline)
            }
            .accessibilityHidden(true)
    }
}

/// A saved card or address in the wallet; a ring and a check when it's the one picked.
struct CredentialVaultWalletTile: View {
    let group: CredentialVaultGroup
    var isSelected = false
    @BighelpThemeReader private var theme

    var body: some View {
        Group {
            if group.kind == .payment {
                CredentialVaultCardFace(group: group)
            } else {
                CredentialVaultAddressFace(group: group)
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(theme.action, lineWidth: 3)
                    .padding(-6)
            }
        }
        .padding(6)
        // On the ring's corner, clear of the card's own name and icon.
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.bighelp(.caption2, weight: .heavy))
                    .foregroundStyle(theme.actionForeground)
                    .frame(width: 24, height: 24)
                    .background(theme.action, in: Circle())
                    .overlay { Circle().strokeBorder(theme.canvas, lineWidth: 2) }
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A card as a small dark card: its name, its last digits and where it's used.
struct CredentialVaultCardFace: View {
    let group: CredentialVaultGroup
    var isLarge = false
    /// Wider with larger text, so the name and digits stay whole.
    @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 156
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: isLarge ? 22 : 18, style: .continuous)
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(spacing: BighelpTokens.space8) {
                Text(group.typedLabel.isEmpty ? String(localized: "Card") : group.typedLabel)
                    .font(.bighelp(isLarge ? .title3 : .subheadline, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Image(systemName: "creditcard")
                    .font(.bighelp(isLarge ? .title3 : .subheadline))
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength: 0)
            Text("•••• \(group.lastDigits ?? "")")
                .font(.bighelp(isLarge ? .title2 : .body).monospacedDigit())
                .kerning(isLarge ? 2 : 1)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            CredentialVaultUsage(group: group, onDark: true, isLarge: isLarge)
        }
        .foregroundStyle(.white)
        .padding(isLarge ? BighelpTokens.space20 : BighelpTokens.space16)
        .frame(width: isLarge ? nil : tileWidth, alignment: .leading)
        .frame(maxWidth: isLarge ? 320 : nil, alignment: .leading)
        .frame(minHeight: isLarge ? 184 : 104)
        .background(colorScheme == .dark ? Color(hex: "2A2A2E") : Color(hex: "1C1C1E"), in: shape)
        .overlay { shape.strokeBorder(.white.opacity(colorScheme == .dark ? 0.14 : 0), lineWidth: 1) }
        .shadow(color: .black.opacity(isLarge ? 0.18 : 0), radius: 15, y: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.label), \(CredentialVaultUsage.text(for: group))")
    }
}

/// An address as a gray tile: its name and where it's used.
struct CredentialVaultAddressFace: View {
    let group: CredentialVaultGroup
    var isLarge = false
    @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 156
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(spacing: BighelpTokens.space8) {
                Text(group.label)
                    .font(.bighelp(isLarge ? .title3 : .subheadline, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "house")
                    .font(.bighelp(isLarge ? .title3 : .subheadline))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
            Text("Address")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
            CredentialVaultUsage(group: group, onDark: false, isLarge: isLarge)
        }
        .foregroundStyle(theme.primaryText)
        .padding(isLarge ? BighelpTokens.space20 : BighelpTokens.space16)
        .frame(width: isLarge ? nil : tileWidth, alignment: .leading)
        .frame(maxWidth: isLarge ? 320 : nil, alignment: .leading)
        .frame(minHeight: isLarge ? 184 : 104)
        .background(theme.surface, in: .rect(cornerRadius: isLarge ? 22 : 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Where a saved card or address is used: one website by name, else how many.
private struct CredentialVaultUsage: View {
    let group: CredentialVaultGroup
    let onDark: Bool
    let isLarge: Bool
    @BighelpThemeReader private var theme

    static func text(for group: CredentialVaultGroup) -> String {
        let sites = group.sites
        return sites.isEmpty ? String(localized: "No website yet")
            : sites.count == 1 ? String(localized: "On \(sites[0])")
            : String(localized: "\(sites.count) websites")
    }

    var body: some View {
        Text(Self.text(for: group))
            .font(.bighelp(.footnote))
            .foregroundStyle(group.sites.isEmpty ? (onDark ? Color(hex: "FFC266") : theme.warning)
                             : onDark ? .white.opacity(0.78) : theme.secondaryText)
            .lineLimit(2)
    }
}

/// The last tile in a picker: a new card or address, typed here.
struct CredentialVaultNewTile: View {
    let title: String
    let isSelected: Bool
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus").font(.bighelp(.title3, weight: .semibold))
            Text(title).font(.bighelp(.subheadline))
        }
        .foregroundStyle(theme.primaryText)
        .frame(width: 112)
        .frame(minHeight: 104)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isSelected ? theme.action : theme.tertiaryText,
                              style: StrokeStyle(lineWidth: isSelected ? 3 : 2, dash: isSelected ? [] : [6, 5]))
        }
        .contentShape(.rect)
        .padding(6)
    }
}

/// A gray capsule link under the lists (Password managers, Import from a file).
private struct CredentialVaultPill: View {
    let title: String
    @BighelpThemeReader private var theme

    var body: some View {
        Text(title)
            .font(.bighelp(.subheadline))
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, BighelpTokens.space16)
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
            .background(theme.surface, in: Capsule())
            .contentShape(Capsule())
    }
}

extension CredentialVaultGroup {
    static func title(_ kind: CredentialVaultItem.Kind) -> String {
        switch kind {
        case .login: String(localized: "Login")
        case .payment: String(localized: "Card")
        case .address: String(localized: "Address")
        }
    }
}

/// A password manager's master password, sent once to unlock it on the computer.
private struct CredentialVaultUnlockView: View {
    let model: CredentialVaultModel
    let source: CredentialVaultSource
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Master password", text: $password)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .submitLabel(.go)
                        .onSubmit(unlock)
                        .accessibilityIdentifier("vault.master-password")
                } footer: {
                    Text("Unlocks \(source.displayName) on your computer so your agent can use its logins. bighelp doesn't keep your master password.")
                }
                if let message = model.message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
            }
            .bighelpFormSurface()
            .navigationTitle("Unlock \(source.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { password = ""; dismiss() }
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                        #endif
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unlock", action: unlock)
                        .disabled(password.isEmpty || model.isWorking)
                        .accessibilityIdentifier("vault.unlock-confirm")
                }
            }
            .onAppear { model.message = nil; focused = true }
            .onChange(of: scenePhase) { _, phase in if phase != .active { password = "" } }
            .onDisappear { password = "" }
        }
    }

    private func unlock() {
        let typed = password
        password = ""
        guard !typed.isEmpty else { return }
        Task { if await model.unlock(source, password: typed) { dismiss() } }
    }
}

/// Presents the vault from the root, outside RootShellView's large body.
struct CredentialVaultSheet: ViewModifier {
    @Binding var model: CredentialVaultModel?

    func body(content: Content) -> some View {
        content.bighelpSheet(item: $model) { CredentialVaultView(model: $0).bighelpSheetSize(.standard) }
    }
}

extension RootShellView {
    /// Any host can open it; one without a vault says to update Hermes.
    var canOpenCredentialVault: Bool {
        hostRegistry?.selectedHost != nil || usesWorkspaceFixtures
    }

    /// The selected computer's vault, or demo mode's; nil while the computer isn't connected.
    func makeCredentialVaultService() -> (any CredentialVaultService)? {
        if let workspace = hostRegistry?.selectedWorkspace {
            guard workspace.isConnected else { return nil }
            return DirectHermesCredentialVaultService(workspace: workspace,
                                                      plugin: { [weak workspaceConnections] in workspaceConnections?.workspace })
        }
        return usesWorkspaceFixtures ? DemoCredentialVaultService() : nil
    }

    /// ☰ › Secure credential vault: every agent's, starting on the home agent's.
    func openCredentialVault() {
        guard let service = makeCredentialVaultService() else {
            if hostRegistry?.selectedWorkspace != nil { actionErrorMessage = "Connect to your computer to open the vault." }
            return
        }
        var list = agents.profiles.map { CredentialVaultModel.Agent(id: $0.id, name: $0.name) }
        if list.isEmpty { list = [.init(id: "default", name: "Default agent")] }
        credentialVault = CredentialVaultModel(service: service, agents: list, agentID: homeAgent?.id ?? "default")
    }

    /// One bot's own vault, for its profile in Bots mode; nil while the computer isn't connected.
    func makeCredentialVault(for agentID: String) -> CredentialVaultModel? {
        guard let service = makeCredentialVaultService() else { return nil }
        let name = agents.profiles.first { $0.id == agentID }?.name ?? agentID
        return CredentialVaultModel(service: service, agents: [.init(id: agentID, name: name)], agentID: agentID)
    }
}

/// What an export holds, before anything is sent: sites and usernames only.
private struct CredentialVaultImportView: View {
    let model: CredentialVaultModel
    let file: CredentialVaultImport
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var result: (imported: Int, failed: Int)?

    var body: some View {
        let pending = file.excluding(model.items)
        NavigationStack {
            Form {
                if let result {
                    Section {
                        Label(result.imported == 1 ? "Imported 1 login." : "Imported \(result.imported) logins.",
                              systemImage: "checkmark.circle")
                            .accessibilityIdentifier("vault.import-done")
                        if result.failed > 0 {
                            Text(result.failed == 1 ? "1 login couldn't be saved." : "\(result.failed) logins couldn't be saved.")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Now delete the exported file. It has your passwords in plain text.")
                    }
                } else {
                    Section {
                        Text(summary(pending))
                            .accessibilityIdentifier("vault.import-summary")
                        if let progress = model.importProgress {
                            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                                Text("Saving \(progress.done) of \(progress.total)…")
                            }
                        }
                    } footer: {
                        Text("Passwords go straight to the vault on your computer for \(model.agentName). bighelp doesn't keep them.")
                    }
                    if !pending.logins.isEmpty {
                        Section("Logins") {
                            ForEach(pending.logins.prefix(300)) { login in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(login.site)
                                    Text(login.identifier).bighelpFont(.metadata).foregroundStyle(.secondary)
                                }
                            }
                            if pending.logins.count > 300 {
                                Text("And \(pending.logins.count - 300) more").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .bighelpFormSurface()
            .navigationTitle("Import logins")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(model.isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if result == nil {
                        Button("Cancel") { dismiss() }
                            .disabled(model.isWorking)
                            #if targetEnvironment(macCatalyst)
                            .keyboardShortcut(.cancelAction)
                            #endif
                            .bighelpToolbarText()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if result != nil {
                        Button("Done") { dismiss() }
                            #if targetEnvironment(macCatalyst)
                            .keyboardShortcut(.cancelAction)
                            #endif
                            .accessibilityIdentifier("vault.import-close")
                    } else {
                        Button(pending.logins.count == 1 ? "Import 1" : "Import \(pending.logins.count)") {
                            Task { result = await model.importLogins(pending.logins) }
                        }
                        .disabled(pending.logins.isEmpty || model.isWorking)
                        .accessibilityIdentifier("vault.import-confirm")
                    }
                }
            }
            // The export's passwords leave memory with this sheet.
            .onChange(of: scenePhase) { _, phase in if phase == .background, !model.isWorking { dismiss() } }
        }
    }

    private func summary(_ pending: (logins: [CredentialVaultImport.Login], alreadySaved: Int)) -> String {
        var parts = [pending.logins.count == 1 ? "Found 1 login to import." : "Found \(pending.logins.count) logins to import."]
        if pending.alreadySaved > 0 {
            parts.append(pending.alreadySaved == 1 ? "1 is already saved." : "\(pending.alreadySaved) are already saved.")
        }
        if file.skipped > 0 {
            parts.append(file.skipped == 1 ? "1 row was skipped: it has no website, username or password."
                         : "\(file.skipped) rows were skipped: they have no website, username or password.")
        }
        return parts.joined(separator: " ")
    }
}
