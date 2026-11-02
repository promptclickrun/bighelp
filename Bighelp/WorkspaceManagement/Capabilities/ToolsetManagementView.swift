import SwiftUI

/// Settings › Hermes tools › Toolsets: the profile's toolsets by state, each with its switch, or
/// Needs setup when it wants a provider or key first. A toolset's name opens its page.
@MainActor
struct ToolsetManagementView: View {
    @Bindable var model: ToolsetManagementModel
    let hostName: String
    let profileName: String
    @State private var search = ""
    @State private var filter: HermesToolFilter = .all
    /// The toolset whose switch is changing, so only its row shows the new value.
    @State private var changing: HermesToolChange?
    @State private var opened: String?

    var body: some View {
        List {
            HermesToolSearchSection(search: $search, prompt: String(localized: "Search toolsets"),
                                    searchIdentifier: "toolsets.search",
                                    filters: [.all, .on, .off, .needsSetup],
                                    filter: $filter, filtersIdentifier: "toolsets.filters")
            CapabilitiesStatusSections(
                support: model.support, isBusy: model.isBusy && changing == nil,
                errorMessage: model.errorMessage, successMessage: model.successMessage,
                retry: { Task { await model.load() } }
            )
            if let snapshot = model.snapshot {
                content(snapshot)
            }
            CapabilitiesScopeSection(hostName: hostName, profileName: profileName)
        }
        .bighelpFormSurface()
        .bighelpRefreshable { await model.load() }
        .task { if model.snapshot == nil { await model.load() } }
        .navigationDestination(item: $opened) { name in
            ToolsetDetailView(model: model, toolsetName: name)
        }
    }

    @ViewBuilder
    private func content(_ snapshot: ToolsetSnapshot) -> some View {
        let toolsets = snapshot.toolsets.filter {
            ManagementSearch.matches(search, $0.label, $0.name, $0.summary, $0.platformLabel)
                && filter.admits(isOn: $0.isEnabled, needsSetup: !$0.isConfigured)
        }
        if ManagementSearch.isActive(search), toolsets.isEmpty {
            ManagementSearchEmptySection(search: search)
        } else if snapshot.toolsets.isEmpty {
            Section { Text("No configurable toolsets were reported.").foregroundStyle(.secondary) }
        } else if toolsets.isEmpty {
            Section { Text("No toolsets match this filter.").foregroundStyle(.secondary) }
        } else {
            section(String(localized: "On"), toolsets.filter(\.isEnabled))
            section(String(localized: "Off"), toolsets.filter { !$0.isEnabled })
            Section {
            } footer: {
                Text("Changes apply to new sessions in this profile; the current conversation and Hermes process are unchanged.")
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ toolsets: [ToolsetSummary]) -> some View {
        if !toolsets.isEmpty {
            Section(HermesTools.heading(title, toolsets.count)) {
                ForEach(toolsets) { row($0) }
            }
        }
    }

    private func row(_ toolset: ToolsetSummary) -> some View {
        HermesToolRow(art: ToolsetSummary.art(toolset.name), name: toolset.label,
                      detail: toolset.summary.isEmpty ? toolset.platformLabel : toolset.summary,
                      open: { opened = toolset.name }) {
            if toolset.isConfigured {
                HermesToolSwitch(title: toolset.label, isOn: toolset.isEnabled,
                                 pending: changing?.pending(for: toolset.id), isLocked: model.isBusy,
                                 identifier: "toolsets.switch.\(toolset.name)") { set($0, toolset) }
            } else {
                HermesToolStatus(text: String(localized: "Needs setup"), tone: .warning)
            }
        }
        .accessibilityIdentifier("toolsets.toolset.\(toolset.name)")
    }

    private func set(_ isOn: Bool, _ toolset: ToolsetSummary) {
        guard changing == nil, !model.isBusy else { return }
        changing = HermesToolChange(id: toolset.id, isOn: isOn)
        Task {
            await model.setEnabled(isOn, toolset: toolset)
            changing = nil
        }
    }
}

private extension ToolsetSummary {
    /// Toolsets have no logo or topic from the host: a symbol for what they do, colored by name.
    static func art(_ name: String) -> HermesToolArt {
        .symbol(HermesTools.toolsetSymbol(name), key: name)
    }
}

/// One toolset: its switch, its providers and keys, model routing, the tools it adds, Advanced.
@MainActor
private struct ToolsetDetailView: View {
    @Bindable var model: ToolsetManagementModel
    let toolsetName: String
    @State private var credentialProvider: ToolsetProvider?
    /// The new value while this page's switch is changing.
    @State private var changing: Bool?

    private var toolset: ToolsetSummary? {
        model.details[toolsetName]?.summary ?? model.snapshot?.toolsets.first { $0.name == toolsetName }
    }
    private var detail: ToolsetDetail? { model.details[toolsetName] }

    var body: some View {
        List {
            if let toolset {
                Section {
                    HermesToolHeader(art: ToolsetSummary.art(toolset.name), name: toolset.label,
                                     summary: toolset.summary)
                }
                CapabilitiesStatusSections(
                    support: model.support, isBusy: model.isBusy && changing == nil,
                    errorMessage: model.errorMessage, successMessage: model.successMessage,
                    retry: { Task { await model.loadDetail(toolsetName) } }
                )
                Section {
                    HermesToolSwitch(title: String(localized: "Turned on"), isOn: toolset.isEnabled,
                                     pending: changing, isLocked: model.isBusy, showsTitle: true,
                                     identifier: "toolsets.enabled") { set($0, toolset) }
                    if !toolset.isConfigured {
                        LabeledContent("Setup") {
                            HermesToolStatus(text: String(localized: "Needs setup"), tone: .warning)
                        }
                    }
                } footer: {
                    Text("Only this toolset changes, for this profile. New chats get the change.")
                }
                if let detail {
                    providerSections(detail, toolset: toolset)
                    modelSection(detail, toolset: toolset)
                    Section("Tools it adds") {
                        if toolset.tools.isEmpty { Text("No concrete tools were reported.").foregroundStyle(.secondary) }
                        ForEach(toolset.tools.prefix(200), id: \.self) { Text($0).font(.bighelp(.footnote).monospaced()) }
                    }
                }
                Section("Advanced") {
                    LabeledContent("Name", value: toolset.name)
                    LabeledContent("Platform", value: toolset.platformLabel)
                    LabeledContent("Configuration", value: toolset.isConfigured ? "Ready" : "Needs setup")
                }
            } else {
                ContentUnavailableView("Toolset unavailable", systemImage: "wrench.and.screwdriver")
            }
        }
        .bighelpFormSurface()
        .navigationTitle(toolset?.label ?? toolsetName)
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.details[toolsetName] == nil { await model.loadDetail(toolsetName) } }
        .bighelpSheet(item: $credentialProvider) { provider in
            if let toolset {
                ToolsetCredentialForm(provider: provider, isBusy: model.isBusy) { values in
                    credentialProvider = nil
                    Task { await model.saveEnvironment(values, toolset: toolset) }
                }
                .bighelpSheetSize(.standard)
            }
        }
    }

    private func set(_ isOn: Bool, _ toolset: ToolsetSummary) {
        guard changing == nil, !model.isBusy else { return }
        changing = isOn
        Task {
            await model.setEnabled(isOn, toolset: toolset)
            changing = nil
        }
    }

    @ViewBuilder
    private func providerSections(_ detail: ToolsetDetail, toolset: ToolsetSummary) -> some View {
        if detail.configuration.hasCategory {
            Section("Providers") {
                if detail.configuration.providers.isEmpty {
                    Text("No providers are available for this toolset.").foregroundStyle(.secondary)
                }
                ForEach(detail.configuration.providers) { provider in
                    providerRow(provider, toolset: toolset)
                }
            }
        }
    }

    private func providerRow(_ provider: ToolsetProvider, toolset: ToolsetSummary) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(spacing: BighelpTokens.space12) {
                HermesToolLabel(
                    art: .brand(id: provider.name, name: provider.name,
                                fallback: .symbol(HermesTools.toolsetSymbol(toolset.name), key: provider.name)),
                    name: provider.name,
                    detail: HermesTools.line(HermesTools.readable(provider.status), provider.badge, provider.tag)
                )
                Spacer(minLength: 0)
                if provider.isActive {
                    HermesToolStatus(text: String(localized: "In use"), tone: .positive)
                        .accessibilityLabel("Active provider")
                }
            }
            if provider.requiresNousAuthentication {
                Text("Requires Nous Portal authentication.").font(.bighelp(.footnote)).foregroundStyle(.secondary)
            }
            providerButtons(provider, toolset: toolset)
        }
        .padding(.vertical, BighelpTokens.space4)
    }

    @ViewBuilder
    private func providerButtons(_ provider: ToolsetProvider, toolset: ToolsetSummary) -> some View {
        if toolset.name == "web" && !provider.capabilities.isEmpty {
            Menu("Use provider for…") {
                if provider.capabilities.contains("search") {
                    Button("Web search") { Task { await model.selectProvider(provider.name, capability: .search, toolset: toolset) } }
                }
                if provider.capabilities.contains("extract") {
                    Button("Page extraction") { Task { await model.selectProvider(provider.name, capability: .extract, toolset: toolset) } }
                }
                Button("Both capabilities") { Task { await model.selectProvider(provider.name, capability: nil, toolset: toolset) } }
            }
            .disabled(model.isBusy)
        } else if !provider.isActive {
            Button("Use this provider") {
                Task { await model.selectProvider(provider.name, capability: nil, toolset: toolset) }
            }
            .disabled(model.isBusy)
        }
        if !provider.environment.isEmpty {
            Button("Enter provider credentials") { credentialProvider = provider }
                .buttonStyle(.bordered)
        }
        if let key = provider.postSetupKey {
            Button("Run \(provider.name) setup") { Task { await model.runPostSetup(key: key, toolset: toolset) } }
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func modelSection(_ detail: ToolsetDetail, toolset: ToolsetSummary) -> some View {
        if detail.models.hasModels {
            Section("Model routing") {
                LabeledContent("Current", value: detail.models.current ?? "Host default")
                ForEach(detail.models.models) { modelOption in
                    Button {
                        Task {
                            await model.selectModel(modelOption.id, provider: detail.models.provider, toolset: toolset)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                Text(modelOption.displayName)
                                Text([modelOption.speed, modelOption.strengths, modelOption.price].filter { !$0.isEmpty }.joined(separator: " • "))
                                    .font(.bighelp(.caption)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if detail.models.current == modelOption.id { Image(systemName: "checkmark") }
                        }
                    }
                    .disabled(detail.models.current == modelOption.id || model.isBusy)
                }
            }
        }
    }
}

private struct ToolsetCredentialForm: View {
    let provider: ToolsetProvider
    let isBusy: Bool
    let save: ([String: String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section("Credentials") {
                    ForEach(provider.environment) { field in
                        SecureField(field.prompt, text: Binding(
                            get: { values[field.key] ?? "" },
                            set: { values[field.key] = $0 }
                        ))
                        .textContentType(.password)
                        HStack {
                            Text(field.key).font(.bighelp(.caption)).foregroundStyle(.secondary)
                            Spacer()
                            if field.isSet { Label("Already set", systemImage: "checkmark.circle").font(.bighelp(.caption)) }
                        }
                        if let url = field.helpURL { Link("Provider help", destination: url).font(.bighelp(.footnote)) }
                    }
                }
                Section {
                    Button("Save entered fields") {
                        save(values.filter { !$0.value.isEmpty })
                    }
                    .disabled(isBusy || values.values.allSatisfy(\.isEmpty))
                } footer: {
                    Text("Blank fields stay unchanged. Entered secrets go only to this Hermes profile and are discarded when the form closes.")
                }
            }
            .bighelpFormSurface()
            .navigationTitle(provider.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
        }
    }
}
