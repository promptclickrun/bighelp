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
    @State private var configuringProvider: HermesMemoryProvider?
    @State private var providerSelection: ProviderSelection?
    @State private var setupSelection: HermesMemoryProvider?
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
        .bighelpSheet(item: $configuringProvider) { provider in
            MemoryProviderConfigurationView(store: store, provider: provider)
                .bighelpSheetSize(.standard)
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
            "Install provider dependencies on this Hermes host?",
            isPresented: Binding(
                get: { setupSelection != nil },
                set: { if !$0 { setupSelection = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let provider = setupSelection {
                Button("Run setup") {
                    setupSelection = nil
                    Task { await store.setupProvider(provider) }
                }
            }
            Button("Cancel", role: .cancel) { setupSelection = nil }
        } message: {
            Text("Hermes may run the dependency-install commands declared by this provider. The action changes the host environment and may take several minutes.")
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

            Section {
                LabeledContent("Host", value: store.hostName)
                LabeledContent("Profile", value: store.profileName)
                if let status = store.memoryStatus {
                    LabeledContent(
                        "Active provider",
                        value: status.activeProvider.isEmpty ? "Built-in" : status.activeProvider)
                }
            } header: {
                Text("Current")
            } footer: {
                Text("Provider selection is host-wide. Settings and learned knowledge use this profile when the host supports it.")
            }

            if let status = store.memoryStatus {
                Section("Built-in memory") {
                    providerRow(
                        name: "Built-in",
                        description: "Hermes-managed memory files.",
                        state: status.activeProvider.isEmpty ? "Active" : "Available",
                        active: status.activeProvider.isEmpty
                    ) {
                        if !status.activeProvider.isEmpty {
                            providerSelection = .builtIn
                        }
                    }
                    LabeledContent(
                        "Learned memory",
                        value: ByteCountFormatter.string(fromByteCount: Int64(status.builtInFiles.memoryBytes), countStyle: .file))
                    LabeledContent(
                        "User profile memory",
                        value: ByteCountFormatter.string(fromByteCount: Int64(status.builtInFiles.userBytes), countStyle: .file))
                }

                Section("Providers") {
                    if status.providers.isEmpty {
                        ContentUnavailableView(
                            "No external providers",
                            systemImage: "externaldrive",
                            description: Text("Built-in memory remains available."))
                    }
                    ForEach(status.providers) { provider in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(provider.name).font(.bighelp(.headline))
                                    if !provider.description.isEmpty {
                                        Text(provider.description)
                                            .font(.bighelp(.subheadline))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 12)
                                if status.activeProvider == provider.name {
                                    Label("Active", systemImage: "checkmark.circle.fill")
                                        .labelStyle(.iconOnly)
                                        .foregroundStyle(.green)
                                        .accessibilityLabel("Active provider")
                                }
                            }

                            HStack {
                                Label(provider.state.title, systemImage: providerSymbol(provider))
                                    .font(.bighelp(.caption))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !provider.setup.dependenciesInstalled {
                                    Text("Dependencies needed")
                                        .font(.bighelp(.caption))
                                        .foregroundStyle(.orange)
                                }
                            }

                            HStack(spacing: 12) {
                                Button("Configure") {
                                    configuringProvider = provider
                                }
                                .buttonStyle(.bordered)

                                if provider.setup.hasInstallSteps && !provider.setup.dependenciesInstalled {
                                    Button("Set up") { setupSelection = provider }
                                        .buttonStyle(.bordered)
                                }

                                if provider.name == "honcho" {
                                    Button(store.providerOAuth[provider.name]?.isConnected == true ? "Connected" : "Connect") {
                                        Task { await store.startOAuth(provider) }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(store.providerOAuth[provider.name]?.isConnected == true)
                                    Button("Check sign-in") {
                                        Task { await store.refreshOAuth(provider) }
                                    }
                                    .font(.bighelp(.footnote))
                                }

                                Spacer()
                                if status.activeProvider != provider.name {
                                    Button("Use") { providerSelection = .provider(provider) }
                                        .bighelpProminentButtonStyle()
                                        .disabled(provider.state != .ready)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("memory.provider.\(provider.name)")
                    }
                }

                Section {
                    Menu("Reset built-in memory", systemImage: "trash") {
                        ForEach(HermesMemoryResetTarget.allCases) { target in
                            Button(target.title, role: .destructive) { resetTarget = target }
                        }
                    }
                    .disabled(store.isMutating)
                } header: { Text("Advanced") } footer: {
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
        }
        .listStyle(.insetGrouped)
    }

    private func providerRow(
        name: String,
        description: String,
        state: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "internaldrive")
                .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.bighelp(.headline))
                Text(description).font(.bighelp(.caption)).foregroundStyle(.secondary)
                Text(state).font(.bighelp(.caption2)).foregroundStyle(active ? .green : .secondary)
            }
            Spacer()
            if !active {
                Button("Use", action: action).buttonStyle(.bordered)
            }
        }
        .frame(minHeight: 44)
    }

    private func providerSymbol(_ provider: HermesMemoryProvider) -> String {
        switch provider.state {
        case .ready: "checkmark.circle"
        case .needsConfiguration: "slider.horizontal.3"
        case .missing, .unavailable: "exclamationmark.triangle"
        case .other: "questionmark.circle"
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
