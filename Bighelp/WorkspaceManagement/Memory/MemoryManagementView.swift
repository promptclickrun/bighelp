import SwiftUI

@MainActor
struct MemoryManagementView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case providers = "Providers"
        case knowledge = "Knowledge"
        case curator = "Curator"
        var id: Self { self }
    }

    @Bindable var store: MemoryGraphStore
    @State private var section: Tab = .providers
    @State private var providerSelection: ProviderSelection?
    @State private var openedProvider: String?
    @State private var resetTarget: HermesMemoryResetTarget?

    var body: some View {
        Group {
            if store.ownsScope {
                VStack(spacing: 0) {
                    Picker("Memory section", selection: $section) {
                        ForEach(Tab.allCases) { item in Text(item.rawValue).tag(item) }
                    }
                    .bighelpSegmentedPicker()
                    .padding(.horizontal)
                    .padding(.vertical, 12)

                    switch section {
                    case .providers:
                        providerList
                    case .knowledge:
                        MemoryGraphView(store: store)
                    case .curator:
                        CuratorView(store: store)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Memory is no longer connected",
                    systemImage: "brain",
                    description: Text("Return to Workspace and reopen Memory for the selected host."))
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.memoryStatus == nil { await store.refresh() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await store.refresh() }
                }
                .disabled(store.isLoading || store.isMutating)
            }
        }
        .confirmationDialog(
            providerSelection?.title ?? "Change memory provider?",
            isPresented: Binding(
                get: { providerSelection != nil },
                set: { if !$0 { providerSelection = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let selection = providerSelection {
                Button(selection.actionTitle) {
                    providerSelection = nil
                    Task { await store.selectProvider(selection.provider) }
                }
            }
            Button("Cancel", role: .cancel) { providerSelection = nil }
        } message: {
            Text(providerSelection?.message ?? "")
        }
        .confirmationDialog(
            resetTarget?.title ?? "Reset built-in memory?",
            isPresented: Binding(
                get: { resetTarget != nil },
                set: { if !$0 { resetTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = resetTarget {
                Button("Reset \(target.title)", role: .destructive) {
                    resetTarget = nil
                    Task { await store.reset(target) }
                }
            }
            Button("Cancel", role: .cancel) { resetTarget = nil }
        } message: {
            Text("This permanently erases the selected built-in memory files on the Hermes host. External provider data is not reset.")
        }
        .onChange(of: store.ownsScope) { _, ownsScope in
            if !ownsScope { store.retire() }
        }
    }

    private var providerList: some View {
        List {
            MemoryOperationMessages(store: store)

            if let status = store.memoryStatus {
                let active = status.providers.first { $0.name == status.activeProvider }
                Section(HermesTools.heading(String(localized: "In use"), 1)) {
                    if let active {
                        providerRow(active, isActive: true)
                    } else {
                        builtInRow(isActive: true)
                    }
                }
                let available = status.providers.filter { $0.name != status.activeProvider }
                Section(HermesTools.heading(String(localized: "Available"), available.count + (active == nil ? 0 : 1))) {
                    if active != nil { builtInRow(isActive: false) }
                    ForEach(available) { providerRow($0, isActive: false) }
                    if available.isEmpty, active == nil {
                        Text("No external providers. Built-in memory stays available.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    LabeledContent(
                        "Learned memory",
                        value: ByteCountFormatter.string(fromByteCount: Int64(status.builtInFiles.memoryBytes), countStyle: .file))
                    LabeledContent(
                        "User profile memory",
                        value: ByteCountFormatter.string(fromByteCount: Int64(status.builtInFiles.userBytes), countStyle: .file))
                    Menu("Reset built-in memory", systemImage: "trash") {
                        ForEach(HermesMemoryResetTarget.allCases) { target in
                            Button(target.title, role: .destructive) { resetTarget = target }
                        }
                    }
                    .disabled(store.isMutating)
                } header: {
                    Text("Advanced · Built-in memory")
                } footer: {
                    Text("Reset permanently erases only the selected built-in memory files on this host.")
                }
            } else if store.isLoading {
                Section { ProgressView("Loading memory providers…") }
            } else {
                Section {
                    ContentUnavailableView(
                        "Provider status unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Refresh to ask Hermes for its current provider state."))
                }
            }

            Section {
                LabeledContent("Host", value: store.hostName)
                LabeledContent("Profile", value: store.profileName)
            } header: {
                Text("Applies to")
            } footer: {
                Text("Provider selection is host-wide. Settings and learned knowledge use this profile when the host supports it.")
            }
        }
        .bighelpFormSurface()
        .navigationDestination(item: $openedProvider) { name in
            MemoryProviderPage(store: store, providerName: name)
        }
    }

    private func builtInRow(isActive: Bool) -> some View {
        HermesToolRow(art: .symbol("internaldrive", key: "built-in"), name: String(localized: "Built-in"),
                      detail: String(localized: "Hermes-managed memory files.")) {
            if isActive {
                HermesToolStatus(text: String(localized: "In use"), tone: .positive)
            } else {
                HermesToolGetButton(title: String(localized: "Use"), accessibilityLabel: "Use built-in memory",
                                    identifier: "memory.provider.built-in.use",
                                    isDisabled: store.isMutating) { providerSelection = .builtIn }
            }
        }
        .accessibilityIdentifier("memory.provider.built-in")
    }

    private func providerRow(_ provider: HermesMemoryProvider, isActive: Bool) -> some View {
        HermesToolRow(art: MemoryProviderPage.art(provider.name), name: provider.name,
                      detail: provider.rowDetail, open: { openedProvider = provider.name }) {
            if isActive {
                HermesToolStatus(text: String(localized: "In use"), tone: .positive)
                    .accessibilityLabel("Active provider")
            } else if provider.state == .ready {
                HermesToolGetButton(title: String(localized: "Use"), accessibilityLabel: "Use \(provider.name)",
                                    identifier: "memory.provider.use.\(provider.name)",
                                    isDisabled: store.isMutating) { providerSelection = .provider(provider) }
            } else {
                HermesToolStatus(text: String(localized: "Needs setup"), tone: .warning)
            }
        }
        .accessibilityIdentifier("memory.provider.\(provider.name)")
    }
}

private extension HermesMemoryProvider {
    /// A row's one line: what it is, else its state, and whether it still needs its dependencies.
    var rowDetail: String {
        HermesTools.line(description.isEmpty ? state.title : description,
                         setup.dependenciesInstalled ? nil : String(localized: "Dependencies needed"))
    }
}

/// One memory provider: Use, its settings and setup (dependencies, sign-in), Advanced details.
@MainActor
private struct MemoryProviderPage: View {
    @Bindable var store: MemoryGraphStore
    let providerName: String
    @State private var configuring: HermesMemoryProvider?
    @State private var selecting: HermesMemoryProvider?
    @State private var settingUp: HermesMemoryProvider?

    /// Memory providers have no logo from the host: a memory tile, its color by name.
    static func art(_ name: String) -> HermesToolArt {
        .symbol("brain.head.profile", key: name)
    }

    private var provider: HermesMemoryProvider? {
        store.memoryStatus?.providers.first { $0.name == providerName }
    }

    var body: some View {
        List {
            MemoryOperationMessages(store: store)
            if let provider {
                Section {
                    HermesToolHeader(art: Self.art(provider.name), name: provider.name, summary: provider.description)
                }
                useSection(provider)
                setupSection(provider)
                Section("Advanced") {
                    LabeledContent("State", value: provider.state.title)
                    LabeledContent("Dependencies", value: provider.setup.dependenciesInstalled ? "Installed" : "Needed")
                    if !provider.setup.requiredEnvironmentKeys.isEmpty {
                        LabeledContent("Keys", value: provider.setup.requiredEnvironmentKeys.joined(separator: ", "))
                    }
                    if !provider.setup.packageDependencies.isEmpty {
                        LabeledContent("Packages", value: provider.setup.packageDependencies.joined(separator: ", "))
                    }
                }
            } else {
                ContentUnavailableView("Provider unavailable", systemImage: "brain")
            }
        }
        .bighelpFormSurface()
        .navigationTitle(providerName)
        .navigationBarTitleDisplayMode(.inline)
        .bighelpSheet(item: $configuring) { provider in
            MemoryProviderConfigurationView(store: store, provider: provider)
                .bighelpSheetSize(.standard)
        }
        .confirmationDialog(
            "Change memory provider?",
            isPresented: Binding(get: { selecting != nil }, set: { if !$0 { selecting = nil } }),
            titleVisibility: .visible, presenting: selecting
        ) { provider in
            Button(ProviderSelection.provider(provider).actionTitle) {
                Task { await store.selectProvider(provider) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { provider in
            Text(ProviderSelection.provider(provider).message)
        }
        .confirmationDialog(
            "Install provider dependencies on this Hermes host?",
            isPresented: Binding(get: { settingUp != nil }, set: { if !$0 { settingUp = nil } }),
            titleVisibility: .visible, presenting: settingUp
        ) { provider in
            Button("Run setup") { Task { await store.setupProvider(provider) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Hermes may run the dependency-install commands declared by this provider. The action changes the host environment and may take several minutes.")
        }
    }

    @ViewBuilder
    private func useSection(_ provider: HermesMemoryProvider) -> some View {
        Section {
            if store.memoryStatus?.activeProvider == provider.name {
                LabeledContent("Memory") {
                    HermesToolStatus(text: String(localized: "In use"), tone: .positive)
                }
            } else {
                Button("Use \(provider.name)") { selecting = provider }
                    .disabled(provider.state != .ready || store.isMutating)
                    .accessibilityIdentifier("memory.provider.use")
            }
        } footer: {
            if provider.state != .ready {
                Text("\(provider.state.title). Configure it below first.")
            }
        }
    }

    @ViewBuilder
    private func setupSection(_ provider: HermesMemoryProvider) -> some View {
        Section("Setup") {
            Button("Configure", systemImage: "slider.horizontal.3") { configuring = provider }
                .accessibilityIdentifier("memory.provider.configure")
            if provider.setup.hasInstallSteps && !provider.setup.dependenciesInstalled {
                Button("Install dependencies", systemImage: "shippingbox") { settingUp = provider }
                    .disabled(store.isMutating)
            }
            if provider.name == "honcho" {
                let connected = store.providerOAuth[provider.name]?.isConnected == true
                Button(connected ? "Connected" : "Connect", systemImage: "person.badge.key") {
                    Task { await store.startOAuth(provider) }
                }
                .disabled(connected)
                Button("Check sign-in") {
                    Task { await store.refreshOAuth(provider) }
                }
            }
        }
    }
}

private enum ProviderSelection: Identifiable {
    case builtIn
    case provider(HermesMemoryProvider)

    var id: String { provider?.name ?? "built-in" }
    var provider: HermesMemoryProvider? {
        if case .provider(let provider) = self { return provider }
        return nil
    }
    var title: String { provider == nil ? "Use built-in memory?" : "Change memory provider?" }
    var actionTitle: String { provider == nil ? "Use built-in" : "Use \(provider!.name)" }
    var message: String {
        provider == nil
            ? "Hermes will stop sending new memories to the external provider. Existing external data is not deleted."
            : "Hermes will use \(provider!.name) for future memory operations. This does not copy or delete existing memory."
    }
}

@MainActor
struct MemoryOperationMessages: View {
    let store: MemoryGraphStore

    var body: some View {
        if let error = store.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("memory.error")
                Button("Dismiss") { store.dismissMessages() }
            }
        }
        if let success = store.successMessage {
            Section {
                Label(success, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("memory.success")
                Button("Dismiss") { store.dismissMessages() }
            }
        }
    }
}

@MainActor
private struct MemoryProviderConfigurationView: View {
    @Bindable var store: MemoryGraphStore
    let provider: HermesMemoryProvider

    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [String: String] = [:]
    @State private var hasSeededDrafts = false
    @State private var showingSaveConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                MemoryOperationMessages(store: store)
                if let configuration = matchingConfiguration {
                    if let url = configuration.documentationURL {
                        Section { Link("Provider documentation", destination: url) }
                    }
                    if configuration.fields.isEmpty {
                        Section {
                            ContentUnavailableView(
                                "No editable settings",
                                systemImage: "slider.horizontal.3",
                                description: Text("This provider does not publish a native configuration schema."))
                        }
                    } else {
                        if configuration.fields.contains(where: { !$0.isSecret }) {
                            Section("Settings") {
                                ForEach(configuration.fields.filter { !$0.isSecret }) { field in
                                    fieldEditor(field)
                                }
                            }
                        }
                        if configuration.fields.contains(where: \.isSecret) {
                            Section {
                                ForEach(configuration.fields.filter(\.isSecret)) { field in
                                    fieldEditor(field)
                                }
                            } header: {
                                Text("Credentials")
                            } footer: {
                                Text("Secrets are write-only. Blank fields keep their saved values.")
                            }
                        }
                    }
                } else if store.isLoadingProvider {
                    Section { ProgressView("Loading provider settings…") }
                } else {
                    Section {
                        ContentUnavailableView(
                            "Settings unavailable",
                            systemImage: "exclamationmark.triangle",
                            description: Text("Dismiss and reopen this provider after refreshing Memory."))
                    }
                }
            }
            .navigationTitle(provider.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review Save") { showingSaveConfirmation = true }
                        .disabled(!canSave)
                }
            }
            .task {
                if matchingConfiguration == nil { await store.loadProviderConfiguration(provider) }
                seedDraftsIfNeeded()
            }
            .onChange(of: store.providerConfiguration) { _, _ in seedDraftsIfNeeded() }
            .confirmationDialog(
                "Save provider settings on Hermes?",
                isPresented: $showingSaveConfirmation,
                titleVisibility: .visible
            ) {
                if let configuration = matchingConfiguration {
                    Button("Save settings") {
                        Task {
                            if await store.saveProviderConfiguration(configuration, drafts: changedDrafts(configuration)) {
                                dismiss()
                            }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Hermes will update only the fields changed in this form. A nonblank secret replaces the stored secret and cannot be displayed again.")
            }
            .onDisappear {
                drafts = [:]
                store.closeProviderConfiguration()
            }
        }
    }

    private var matchingConfiguration: HermesMemoryProviderConfiguration? {
        guard store.providerConfiguration?.provider == provider.name else { return nil }
        return store.providerConfiguration
    }

    private var canSave: Bool {
        guard let configuration = matchingConfiguration, !store.isMutating else { return false }
        return !changedDrafts(configuration).isEmpty && configuration.fields.allSatisfy { field in
            !field.isRequired || field.isSecret || !(drafts[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func changedDrafts(_ configuration: HermesMemoryProviderConfiguration) -> [String: String] {
        var changed: [String: String] = [:]
        for field in configuration.fields where field.isEditable {
            guard let draft = drafts[field.key] else { continue }
            if field.isSecret {
                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { changed[field.key] = draft }
            } else if draft != field.value {
                changed[field.key] = draft
            }
        }
        return changed
    }

    private func seedDraftsIfNeeded() {
        guard !hasSeededDrafts, let configuration = matchingConfiguration else { return }
        drafts = Dictionary(uniqueKeysWithValues: configuration.fields.map { ($0.key, $0.isSecret ? "" : $0.value) })
        hasSeededDrafts = true
    }

    @ViewBuilder
    private func fieldEditor(_ field: HermesMemoryProviderConfiguration.Field) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(field.label).font(.bighelp(.headline))
                if field.isRequired { Text("Required").font(.bighelp(.caption2)).foregroundStyle(.secondary) }
                Spacer()
                if field.isSecret, field.isSet {
                    Label("Saved", systemImage: "checkmark.circle")
                        .font(.bighelp(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            switch field.kind {
            case .secret:
                SecureField(field.placeholder ?? "New secret", text: binding(field.key))
                    .textContentType(.password)
            case .select:
                Picker(field.label, selection: binding(field.key)) {
                    ForEach(field.options) { option in Text(option.label).tag(option.value) }
                }
                .labelsHidden()
            case .toggle:
                Toggle(field.label, isOn: Binding(
                    get: { ["true", "1", "yes", "on"].contains((drafts[field.key] ?? "").lowercased()) },
                    set: { drafts[field.key] = $0 ? "true" : "false" }
                ))
                .labelsHidden()
            case .json:
                TextEditor(text: binding(field.key))
                    .font(.bighelp(.body).monospaced())
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            case .number, .integer:
                TextField(field.placeholder ?? "Value", text: binding(field.key))
                    .keyboardType(.numbersAndPunctuation)
            case .text:
                TextField(field.placeholder ?? "Value", text: binding(field.key), axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            case .unsupported(let kind):
                Label("This host field type (\(kind)) is not editable in bighelp.", systemImage: "exclamationmark.triangle")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(.secondary)
            }
            if let description = field.description, !description.isEmpty {
                Text(description).font(.bighelp(.footnote)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.provider.field.\(field.key)")
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { drafts[key] ?? "" }, set: { drafts[key] = $0 })
    }
}
