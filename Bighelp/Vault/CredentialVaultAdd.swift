import SwiftUI
import Observation

/// What's typed for a new login, card or address. Secrets live only here until they're sent once,
/// and go when the sheet closes or the app leaves the screen (`clearSecrets`).
@MainActor
@Observable
final class CredentialVaultTyping {
    var loginLabel = ""
    var identifier = ""
    var password = ""
    var authenticatorKey = ""
    var showsAuthenticatorKey = false
    var cardLabel = ""
    var cardName = ""
    var cardNumber = ""
    var month = ""
    var year = ""
    var securityCode = ""
    var cardPostalCode = ""
    var addressLabel = ""
    var line1 = ""
    var line2 = ""
    var city = ""
    var state = ""
    var postalCode = ""
    var country = ""

    func entry(_ kind: CredentialVaultItem.Kind, sites: [String]) -> CredentialVaultEntry {
        switch kind {
        case .login:
            .login(label: loginLabel, sites: sites, identifier: identifier, password: password,
                   authenticatorKey: authenticatorKey)
        case .payment:
            .card(label: cardLabel, sites: sites, name: cardName, number: cardNumber, month: month, year: year,
                  securityCode: securityCode, postalCode: cardPostalCode)
        case .address:
            .address(label: addressLabel, sites: sites, line1: line1, line2: line2, city: city, state: state,
                     postalCode: postalCode, country: country)
        }
    }

    func clearSecrets() {
        clearSecrets(of: .login)
        clearSecrets(of: .payment)
    }

    /// One part's secrets, once that part is saved.
    func clearSecrets(of kind: CredentialVaultItem.Kind) {
        switch kind {
        case .login:
            password = ""
            authenticatorKey = ""
        case .payment:
            cardNumber = ""
            securityCode = ""
        case .address: break
        }
    }
}

/// Add a Website: the website and what to save for it (a login, a card, an address), then their
/// details, all saved with one Save. A saved card or address is copied on the computer instead of
/// typed again. Every part is checked before anything is sent; a part that fails stays to try
/// again, and the parts that saved aren't sent twice.
@MainActor
@Observable
final class CredentialVaultAddModel: Identifiable {
    enum Part: String, CaseIterable, Identifiable, Sendable {
        case login, card, address

        var id: Self { self }
        var kind: CredentialVaultItem.Kind {
            switch self {
            case .login: .login
            case .card: .payment
            case .address: .address
            }
        }
        var title: String {
            switch self {
            case .login: String(localized: "Login")
            case .card: String(localized: "Card")
            case .address: String(localized: "Address")
            }
        }
        /// "a login", for what Save will do.
        var noun: String {
            switch self {
            case .login: String(localized: "a login")
            case .card: String(localized: "a card")
            case .address: String(localized: "an address")
            }
        }
        var symbol: String { kind.symbol }

        init(_ kind: CredentialVaultItem.Kind) {
            switch kind {
            case .login: self = .login
            case .payment: self = .card
            case .address: self = .address
            }
        }
    }

    /// A saved card or address (its group's ID), or a new one typed here.
    enum Choice: Hashable {
        case new
        case saved(String)
    }

    let id = UUID()
    let vault: CredentialVaultModel
    let typing = CredentialVaultTyping()
    var sites: [String]
    var parts: Set<Part>
    var cardChoice: Choice
    var addressChoice: Choice
    private(set) var saved: Set<Part> = []
    private(set) var failed: Part?
    private(set) var message: String?
    private(set) var isSaving = false
    /// Copies already stored, by part and website, so trying again sends only the rest.
    @ObservationIgnored private var stored: Set<String> = []

    /// From a website's page, its own address and what it's missing come already filled in.
    init(vault: CredentialVaultModel, site: String? = nil, parts: Set<Part> = [.login]) {
        self.vault = vault
        sites = [site.map(CredentialVault.typedSite) ?? ""]
        self.parts = parts
        let cards = vault.canLink ? vault.wallet.filter { $0.kind == .payment } : []
        let addresses = vault.canLink ? vault.wallet.filter { $0.kind == .address } : []
        cardChoice = cards.first.map { .saved($0.id) } ?? .new
        addressChoice = addresses.first.map { .saved($0.id) } ?? .new
    }

    /// Saved ones to pick from, when the computer can copy them.
    var savedCards: [CredentialVaultGroup] { vault.canLink ? vault.wallet.filter { $0.kind == .payment } : [] }
    var savedAddresses: [CredentialVaultGroup] { vault.canLink ? vault.wallet.filter { $0.kind == .address } : [] }

    /// At least one website, and every one typed is a web address.
    var origins: Result<[String], CredentialVault.EntryProblem> {
        CredentialVault.origins(from: sites).flatMap { $0.isEmpty ? .failure(.site) : .success($0) }
    }

    var canContinue: Bool {
        !parts.isEmpty && sites.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The first website, for the details' title.
    var siteName: String {
        (try? origins.get().first).map(CredentialVault.siteName) ?? String(localized: "Add a Website")
    }

    /// Checks the websites before the details; says what's wrong when they can't be used.
    func continueToDetails() -> Bool {
        switch origins {
        case .success:
            message = nil
            failed = nil
            return true
        case .failure(let problem):
            message = problem.message
            return false
        }
    }

    func toggle(_ part: Part) {
        guard !saved.contains(part) else { return }
        if parts.contains(part) { parts.remove(part) } else { parts.insert(part) }
    }

    /// The parts still to save, in order.
    var pending: [Part] { Part.allCases.filter { parts.contains($0) && !saved.contains($0) } }

    /// What Save does, in words: "Saves a login and a card for shop.example.org".
    var summary: String {
        let list = ListFormatter.localizedString(byJoining: pending.map(\.noun))
        guard saved.isEmpty else {
            return String(localized: "What's saved won't be saved twice.")
        }
        return String(localized: "Saves \(list) for \(siteName)")
    }

    var saveTitle: String {
        guard !saved.isEmpty, pending.count == 1, let part = pending.first else { return String(localized: "Save") }
        return String(localized: "Save the \(part.title)")
    }

    /// Saves every part still to save. True once all of them are.
    func save() async -> Bool {
        guard !isSaving else { return false }
        message = nil
        failed = nil
        let targets: [String]
        switch origins {
        case .success(let value): targets = value
        case .failure(let problem):
            message = problem.message
            return false
        }
        // A saved card or address removed meanwhile can't be copied: a new one is typed instead.
        if case .saved(let id) = cardChoice, vault.group(id) == nil { cardChoice = .new }
        if case .saved(let id) = addressChoice, vault.group(id) == nil { addressChoice = .new }
        // Everything is checked before anything is sent.
        var plan: [(part: Part, step: Step)] = []
        for part in pending {
            switch step(for: part, on: targets) {
            case .success(let step): plan.append((part, step))
            case .failure(let problem):
                failed = part
                message = problem.message
                return false
            }
        }
        isSaving = true
        defer { isSaving = false }
        for (part, step) in plan {
            do {
                switch step {
                case .requests(let requests):
                    for request in requests {
                        let key = part.rawValue + "|" + (request["origin"]?.string ?? "")
                        guard !stored.contains(key) else { continue }
                        try await vault.add(request)
                        stored.insert(key)
                    }
                case .copy(let group):
                    try await vault.link(group, to: targets)
                }
                saved.insert(part)
                typing.clearSecrets(of: part.kind)
            } catch {
                failed = part
                message = Self.failure(part, error)
                await vault.load()
                return false
            }
        }
        typing.clearSecrets()
        await vault.load()
        return true
    }

    private enum Step {
        case requests([[String: BighelpJSONValue]])
        case copy(CredentialVaultGroup)
    }

    private func step(for part: Part, on targets: [String]) -> Result<Step, CredentialVault.EntryProblem> {
        let choice: Choice = switch part {
        case .login: .new
        case .card: cardChoice
        case .address: addressChoice
        }
        if case .saved(let id) = choice, let group = vault.group(id) { return .success(.copy(group)) }
        return CredentialVault.requests(for: typing.entry(part.kind, sites: targets)).map(Step.requests)
    }

    private static func failure(_ part: Part, _ error: any Error) -> String {
        if CredentialVaultModel.isUnsupported(error) {
            return String(localized: "This needs a newer Hermes on your computer.")
        }
        if case WorkspaceClientError.unavailable = error {
            return String(localized: "Update the bighelp plugin on your computer to use a saved one here, or add a new one.")
        }
        return switch part {
        case .login: String(localized: "The login didn't save. Everything's still here, so try again.")
        case .card: String(localized: "The card didn't save. Everything's still here, so try again.")
        case .address: String(localized: "The address didn't save. Everything's still here, so try again.")
        }
    }
}

/// The Add a Website sheet: what to save, then the details.
@MainActor
struct CredentialVaultAddFlow: View {
    @State var model: CredentialVaultAddModel
    @State private var showsDetails = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            CredentialVaultAddPicks(model: model) {
                if model.continueToDetails() { showsDetails = true }
            } onCancel: { dismiss() }
            .navigationDestination(isPresented: $showsDetails) {
                CredentialVaultAddDetails(model: model) { dismiss() }
            }
        }
        .interactiveDismissDisabled(model.isSaving)
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.typing.clearSecrets() } }
        .onDisappear { model.typing.clearSecrets() }
    }
}

/// Step 1: the website, and a tile for each thing to save there.
private struct CredentialVaultAddPicks: View {
    @Bindable var model: CredentialVaultAddModel
    let onNext: () -> Void
    let onCancel: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @BighelpThemeReader private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                CredentialVaultStep(text: String(localized: "Step 1 of 2"))
                SimpleBotsSectionLabel(title: String(localized: "Website"))
                CredentialVaultSitesCard(sites: $model.sites, identifier: "vault.add.site")
                SimpleBotsSectionLabel(title: String(localized: "What should \(model.vault.agentName) use there?"))
                    .padding(.top, BighelpTokens.space16)
                tiles
                Text("Pick any mix. You can add the rest later from the website's page.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, BighelpTokens.space20)
                    .padding(.top, BighelpTokens.space4)
                if let message = model.message {
                    CredentialVaultProblem(text: message)
                }
            }
            .modifier(CredentialVaultColumn())
        }
        .dismissesKeyboardOnScroll(true)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle(String(localized: "Add a Website"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel"), action: onCancel)
                    #if targetEnvironment(macCatalyst)
                    .keyboardShortcut(.cancelAction)
                    #endif
                    .bighelpToolbarText()
                    .accessibilityIdentifier("vault.add.cancel")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(String(localized: "Next"), action: onNext)
                .buttonStyle(SimpleBotsPrimaryButtonStyle())
                .disabled(!model.canContinue)
                .padding(.horizontal, BighelpTokens.space20)
                .padding(.vertical, BighelpTokens.space12)
                .background(theme.canvas.ignoresSafeArea(edges: .bottom))
                .accessibilityIdentifier("vault.add.next")
        }
    }

    @ViewBuilder
    private var tiles: some View {
        if dynamicTypeSize >= .xxLarge {
            VStack(spacing: BighelpTokens.space8) {
                ForEach(CredentialVaultAddModel.Part.allCases) { tile($0) }
            }
        } else {
            HStack(spacing: BighelpTokens.space8) {
                ForEach(CredentialVaultAddModel.Part.allCases) { tile($0) }
            }
        }
    }

    private func tile(_ part: CredentialVaultAddModel.Part) -> some View {
        let isOn = model.parts.contains(part)
        let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius20, style: .continuous)
        return Button { model.toggle(part) } label: {
            VStack(spacing: BighelpTokens.space8) {
                Image(systemName: part.symbol)
                    .font(.bighelp(.title2))
                Text(part.title)
                    .font(.bighelp(.body, weight: .semibold))
                Text(detail(part))
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
            }
            .foregroundStyle(theme.primaryText)
            .frame(maxWidth: .infinity, minHeight: dynamicTypeSize >= .xxLarge ? 88 : 132)
            .background(theme.surface, in: shape)
            .overlay { shape.strokeBorder(isOn ? theme.action : .clear, lineWidth: 2) }
            .overlay(alignment: .topTrailing) {
                CredentialVaultCheck(isOn: isOn).padding(BighelpTokens.space12)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("vault.add.part.\(part.rawValue)")
    }

    private func detail(_ part: CredentialVaultAddModel.Part) -> String {
        switch part {
        case .login: String(localized: "Sign in")
        case .card: String(localized: "Pay")
        case .address: String(localized: "Ship to")
        }
    }
}

/// Step 2: the details of each part, a saved card or address to pick, then Save.
private struct CredentialVaultAddDetails: View {
    @Bindable var model: CredentialVaultAddModel
    let onDone: () -> Void
    @BighelpThemeReader private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                CredentialVaultStep(text: String(localized: "Step 2 of 2"))
                ForEach(CredentialVaultAddModel.Part.allCases.filter { model.parts.contains($0) }) { part in
                    section(part)
                }
                let others = CredentialVaultAddModel.Part.allCases.filter { !model.parts.contains($0) }
                if !others.isEmpty {
                    SimpleBotsCard {
                        ForEach(Array(others.enumerated()), id: \.element) { index, part in
                            if index > 0 { SimpleBotsDivider() }
                            CredentialVaultLinkRow(title: addToo(part), identifier: "vault.add.too.\(part.rawValue)") {
                                model.parts.insert(part)
                            }
                        }
                    }
                    .padding(.top, BighelpTokens.space16)
                }
            }
            .modifier(CredentialVaultColumn())
        }
        .dismissesKeyboardOnScroll(true)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle(model.siteName)
        .navigationBarTitleDisplayMode(.inline)
        // Once a part is saved for this website, the website stays: Close leaves with what's saved.
        .navigationBarBackButtonHidden(model.isSaving || !model.saved.isEmpty)
        .toolbar {
            if !model.saved.isEmpty {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close"), action: onDone)
                        .disabled(model.isSaving)
                        .bighelpToolbarText()
                        .accessibilityIdentifier("vault.add.close")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: BighelpTokens.space8) {
                Text(model.summary)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                Button {
                    Task { if await model.save() { onDone() } }
                } label: {
                    if model.isSaving { ProgressView().tint(theme.actionForeground) } else { Text(model.saveTitle) }
                }
                .buttonStyle(SimpleBotsPrimaryButtonStyle())
                .disabled(model.isSaving || model.pending.isEmpty)
                .accessibilityIdentifier("vault.save")
            }
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.vertical, BighelpTokens.space12)
            .background(theme.canvas.ignoresSafeArea(edges: .bottom))
        }
    }

    @ViewBuilder
    private func section(_ part: CredentialVaultAddModel.Part) -> some View {
        let isFirst = CredentialVaultAddModel.Part.allCases.first { model.parts.contains($0) } == part
        SimpleBotsSectionLabel(title: part.title)
            .padding(.top, isFirst ? 0 : BighelpTokens.space16)
        if model.saved.contains(part) {
            SimpleBotsCard {
                SimpleBotsRow(title: part.title, detail: savedDetail(part), leading: Image(systemName: part.symbol)) {
                    Label(String(localized: "Saved"), systemImage: "checkmark")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.success)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("vault.add.saved.\(part.rawValue)")
        } else {
            switch part {
            case .login:
                SimpleBotsCard { CredentialVaultLoginFields(typing: model.typing) }
            case .card:
                choices(part, saved: model.savedCards, choice: $model.cardChoice)
                if model.cardChoice == .new {
                    SimpleBotsCard { CredentialVaultCardFields(typing: model.typing) }
                }
                CredentialVaultNote(text: String(localized: "You're asked before \(model.vault.agentName) pays with it."))
            case .address:
                choices(part, saved: model.savedAddresses, choice: $model.addressChoice)
                if model.addressChoice == .new {
                    SimpleBotsCard { CredentialVaultAddressFields(typing: model.typing) }
                }
            }
            if model.failed == part, let message = model.message {
                CredentialVaultProblem(text: message)
                    .accessibilityIdentifier("vault.add.message")
            }
        }
    }

    /// Saved cards (or addresses) as tiles, then New, when the computer can copy them.
    @ViewBuilder
    private func choices(_ part: CredentialVaultAddModel.Part, saved: [CredentialVaultGroup],
                         choice: Binding<CredentialVaultAddModel.Choice>) -> some View {
        if !saved.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: BighelpTokens.space16) {
                    ForEach(saved) { group in
                        let isOn = choice.wrappedValue == .saved(group.id)
                        Button { choice.wrappedValue = .saved(group.id) } label: {
                            CredentialVaultWalletTile(group: group, isSelected: isOn)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                        .accessibilityIdentifier("vault.add.\(part.rawValue).saved.\(group.firstItemID)")
                    }
                    Button { choice.wrappedValue = .new } label: {
                        CredentialVaultNewTile(title: part == .card ? String(localized: "New card")
                                                                    : String(localized: "New address"),
                                               isSelected: choice.wrappedValue == .new)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(choice.wrappedValue == .new ? .isSelected : [])
                    .accessibilityIdentifier("vault.add.\(part.rawValue).new")
                }
                .padding(.horizontal, BighelpTokens.space4)
                .padding(.vertical, BighelpTokens.space8)
            }
            .scrollIndicators(.hidden)
            if case .saved = choice.wrappedValue {
                CredentialVaultNote(text: String(localized: "It's copied on your computer, so nothing is typed again."))
            }
        }
    }

    private func savedDetail(_ part: CredentialVaultAddModel.Part) -> String? {
        let choice: CredentialVaultAddModel.Choice
        switch part {
        case .login: return model.typing.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        case .card: choice = model.cardChoice
        case .address: choice = model.addressChoice
        }
        guard case .saved(let id) = choice else { return nil }
        return model.vault.group(id)?.label
    }

    private func addToo(_ part: CredentialVaultAddModel.Part) -> String {
        switch part {
        case .login: String(localized: "Add a login too")
        case .card: String(localized: "Add a card too")
        case .address: String(localized: "Add an address too")
        }
    }
}

/// Changes a saved login, card or address. Its secrets are never read back, so they're typed again;
/// the old copies go once the new ones are saved.
struct CredentialVaultEditView: View {
    let model: CredentialVaultModel
    let group: CredentialVaultGroup
    @State private var typing = CredentialVaultTyping()
    @State private var sites: [String] = [""]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @BighelpThemeReader private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    Text("For your security, bighelp never reads back what's saved. Enter the \(secretWords) again to save your changes; the old copy goes once the new one is saved.")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, BighelpTokens.space20)
                    SimpleBotsSectionLabel(title: String(localized: "Name"))
                    SimpleBotsCard {
                        CredentialVaultField(title: String(localized: "Name"), text: nameBinding,
                                             prompt: namePrompt, identifier: "vault.label")
                    }
                    SimpleBotsSectionLabel(title: group.kindTitle).padding(.top, BighelpTokens.space8)
                    SimpleBotsCard {
                        switch group.kind {
                        case .login: CredentialVaultLoginFields(typing: typing)
                        case .payment: CredentialVaultCardFields(typing: typing, asksForName: false)
                        case .address: CredentialVaultAddressFields(typing: typing, asksForName: false)
                        }
                    }
                    SimpleBotsSectionLabel(title: String(localized: "Websites")).padding(.top, BighelpTokens.space8)
                    CredentialVaultSitesCard(sites: $sites, identifier: "vault.site")
                    if let message = model.message { CredentialVaultProblem(text: message) }
                }
                .modifier(CredentialVaultColumn())
            }
            .dismissesKeyboardOnScroll(true)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(String(localized: "Edit \(group.kindTitle.lowercased())"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { typing.clearSecrets(); dismiss() }
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                        #endif
                        .bighelpToolbarText()
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(String(localized: "Save")) { save() }
                    .buttonStyle(SimpleBotsPrimaryButtonStyle())
                    .disabled(model.isWorking)
                    .padding(.horizontal, BighelpTokens.space20)
                    .padding(.vertical, BighelpTokens.space12)
                    .background(theme.canvas.ignoresSafeArea(edges: .bottom))
                    .accessibilityIdentifier("vault.save")
            }
        }
        .interactiveDismissDisabled(model.isWorking)
        .onAppear(perform: fill)
        .onChange(of: scenePhase) { _, phase in if phase != .active { typing.clearSecrets() } }
        .onDisappear { typing.clearSecrets() }
    }

    private var secretWords: String {
        switch group.kind {
        case .login: String(localized: "password")
        case .payment: String(localized: "card details")
        case .address: String(localized: "address")
        }
    }

    private var namePrompt: String {
        switch group.kind {
        case .login: String(localized: "Like Work email (optional)")
        case .payment: String(localized: "Like Everyday Visa (optional)")
        case .address: String(localized: "Like Home or Office")
        }
    }

    private var nameBinding: Binding<String> {
        switch group.kind {
        case .login: $typing.loginLabel
        case .payment: $typing.cardLabel
        case .address: $typing.addressLabel
        }
    }

    private func fill() {
        model.message = nil
        switch group.kind {
        case .login: typing.loginLabel = group.typedLabel
        case .payment: typing.cardLabel = group.typedLabel
        case .address: typing.addressLabel = group.typedLabel
        }
        typing.identifier = group.identifier ?? ""
        sites = group.origins.isEmpty ? [""] : group.origins.map(CredentialVault.typedSite)
    }

    private func save() {
        let entry = typing.entry(group.kind, sites: sites)
        Task {
            guard await model.save(entry, replacing: group) else { return }
            typing.clearSecrets()
            dismiss()
        }
    }
}

// MARK: - Parts shared by adding and editing

/// A labeled field in a vault card: a small caption over what's typed.
struct CredentialVaultField: View {
    let title: String
    @Binding var text: String
    var prompt = ""
    var isSecure = false
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?
    var capitalizes = true
    let identifier: String
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
                .accessibilityHidden(true)
            Group {
                if isSecure {
                    SecureField(title, text: $text, prompt: Text(prompt).bighelpFieldHint(theme))
                        .privacySensitive()
                } else {
                    TextField(title, text: $text, prompt: Text(prompt).bighelpFieldHint(theme))
                }
            }
            .font(.bighelp(.body))
            .foregroundStyle(theme.primaryText)
            .keyboardType(keyboard)
            .textContentType(contentType)
            .textInputAutocapitalization(capitalizes ? .sentences : .never)
            .autocorrectionDisabled()
            .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, BighelpTokens.space20)
        .padding(.vertical, BighelpTokens.space8)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }
}

/// Email or username, password, and the authenticator key behind its own button: two password
/// fields in a row read to AutoFill as "confirm password".
struct CredentialVaultLoginFields: View {
    @Bindable var typing: CredentialVaultTyping

    var body: some View {
        CredentialVaultField(title: String(localized: "Email or username"), text: $typing.identifier,
                             keyboard: .emailAddress, contentType: .username, capitalizes: false,
                             identifier: "vault.username")
        SimpleBotsDivider()
        CredentialVaultField(title: String(localized: "Password"), text: $typing.password, isSecure: true,
                             contentType: .password, capitalizes: false, identifier: "vault.password")
        SimpleBotsDivider()
        if typing.showsAuthenticatorKey {
            CredentialVaultField(title: String(localized: "Authenticator key"), text: $typing.authenticatorKey,
                                 prompt: String(localized: "The setup code or otpauth link"), isSecure: true,
                                 contentType: .oneTimeCode, capitalizes: false, identifier: "vault.authenticator")
        } else {
            CredentialVaultLinkRow(title: String(localized: "Add an authenticator key"),
                                   identifier: "vault.add-authenticator") {
                typing.showsAuthenticatorKey = true
            }
        }
    }
}

struct CredentialVaultCardFields: View {
    @Bindable var typing: CredentialVaultTyping
    var asksForName = true
    @BighelpThemeReader private var theme

    var body: some View {
        CredentialVaultField(title: String(localized: "Name on card"), text: $typing.cardName,
                             contentType: .name, identifier: "vault.card-name")
        SimpleBotsDivider()
        CredentialVaultField(title: String(localized: "Card number"), text: $typing.cardNumber, isSecure: true,
                             keyboard: .numberPad, identifier: "vault.card-number")
        SimpleBotsDivider()
        HStack(spacing: 0) {
            CredentialVaultField(title: String(localized: "Month"), text: $typing.month, prompt: "MM",
                                 keyboard: .numberPad, identifier: "vault.card-month")
            Rectangle().fill(theme.separator).frame(width: BighelpTokens.hairline)
            CredentialVaultField(title: String(localized: "Year"), text: $typing.year, prompt: "YYYY",
                                 keyboard: .numberPad, identifier: "vault.card-year")
        }
        SimpleBotsDivider()
        CredentialVaultField(title: String(localized: "Security code"), text: $typing.securityCode, isSecure: true,
                             keyboard: .numberPad, identifier: "vault.card-code")
        SimpleBotsDivider()
        CredentialVaultField(title: String(localized: "Billing postal code (optional)"), text: $typing.cardPostalCode,
                             contentType: .postalCode, identifier: "vault.card-postal")
        if asksForName {
            SimpleBotsDivider()
            CredentialVaultField(title: String(localized: "Name (optional)"), text: $typing.cardLabel,
                                 prompt: String(localized: "Like Everyday Visa"), identifier: "vault.card-label")
        }
    }
}

struct CredentialVaultAddressFields: View {
    @Bindable var typing: CredentialVaultTyping
    var asksForName = true

    var body: some View {
        if asksForName {
            CredentialVaultField(title: String(localized: "Name"), text: $typing.addressLabel,
                                 prompt: String(localized: "Like Home or Office"), identifier: "vault.address-label")
            SimpleBotsDivider()
        }
        CredentialVaultField(title: String(localized: "Street address"), text: $typing.line1,
                             contentType: .streetAddressLine1, identifier: "vault.address-line1")
        SimpleBotsDivider()
        CredentialVaultField(title: String(localized: "Apartment, suite (optional)"), text: $typing.line2,
                             contentType: .streetAddressLine2, identifier: "vault.address-line2")
        SimpleBotsDivider()
        CredentialVaultField(title: String(localized: "City"), text: $typing.city,
                             contentType: .addressCity, identifier: "vault.address-city")
        SimpleBotsDivider()
        CredentialVaultField(title: String(localized: "State or region (optional)"), text: $typing.state,
                             contentType: .addressState, identifier: "vault.address-state")
        SimpleBotsDivider()
        CredentialVaultField(title: String(localized: "Postal code"), text: $typing.postalCode,
                             contentType: .postalCode, identifier: "vault.address-postal")
        SimpleBotsDivider()
        CredentialVaultField(title: String(localized: "Country"), text: $typing.country,
                             contentType: .countryName, identifier: "vault.address-country")
    }
}

/// The websites typed for an item, one per field, with Add another website.
struct CredentialVaultSitesCard: View {
    @Binding var sites: [String]
    let identifier: String
    @BighelpThemeReader private var theme

    var body: some View {
        SimpleBotsCard {
            ForEach(sites.indices, id: \.self) { index in
                if index > 0 { SimpleBotsDivider() }
                HStack(spacing: BighelpTokens.space12) {
                    Image(systemName: "globe")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    TextField(index == 0 ? String(localized: "Website, like example.com") : String(localized: "Another website"),
                              text: $sites[index])
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.primaryText)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier(index == 0 ? identifier : "\(identifier).\(index)")
                    if sites.count > 1 {
                        Button { sites.remove(at: index) } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(theme.tertiaryText)
                                .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Remove this website"))
                    }
                }
                .padding(.horizontal, BighelpTokens.space20)
                .frame(minHeight: 56)
            }
            if sites.count < CredentialVault.maximumSites {
                SimpleBotsDivider()
                CredentialVaultLinkRow(title: String(localized: "Add another website"), identifier: "vault.add-site") {
                    sites.append("")
                }
            }
        }
    }
}

/// A row in a card that does something: a plus and the action's name, in the tinted text color.
struct CredentialVaultLinkRow: View {
    let title: String
    var systemImage = "plus"
    let identifier: String
    let action: () -> Void
    @BighelpThemeReader private var theme

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.bighelp(.body))
                .foregroundStyle(theme.information)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .padding(.horizontal, BighelpTokens.space20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// Where the person is in Add a Website, small and gray at the top of the page.
private struct CredentialVaultStep: View {
    let text: String
    @BighelpThemeReader private var theme

    var body: some View {
        Text(text)
            .font(.bighelp(.footnote, weight: .semibold))
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.bottom, BighelpTokens.space4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A short gray note under a card.
struct CredentialVaultNote: View {
    let text: String
    @BighelpThemeReader private var theme

    var body: some View {
        Text(text)
            .font(.bighelp(.footnote))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, BighelpTokens.space20)
    }
}

/// What went wrong, in the danger color, under the part it's about.
struct CredentialVaultProblem: View {
    let text: String
    @BighelpThemeReader private var theme

    var body: some View {
        Text(text)
            .font(.bighelp(.subheadline))
            .foregroundStyle(theme.danger)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.top, BighelpTokens.space4)
            .accessibilityAddTraits(.isStaticText)
    }
}

/// A filled check in the action color when on, an empty ring when off.
struct CredentialVaultCheck: View {
    let isOn: Bool
    @BighelpThemeReader private var theme

    var body: some View {
        if isOn {
            Image(systemName: "checkmark")
                .font(.bighelp(.caption2, weight: .heavy))
                .foregroundStyle(theme.actionForeground)
                .frame(width: 22, height: 22)
                .background(theme.action, in: Circle())
                .accessibilityHidden(true)
        } else {
            Circle()
                .strokeBorder(theme.tertiaryText, lineWidth: 2)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }
}

/// The vault's pages: one readable column, as Advanced Options lays it out.
struct CredentialVaultColumn: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.top, BighelpTokens.space8)
            .padding(.bottom, BighelpTokens.space32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
    }
}
