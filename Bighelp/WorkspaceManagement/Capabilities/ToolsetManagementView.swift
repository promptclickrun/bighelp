import SwiftUI

@MainActor
struct ToolsetManagementView: View {
    @Bindable var model: ToolsetManagementModel
    let hostName: String
    let profileName: String
    @State private var search = ""

    var body: some View {
        List {
            CapabilitiesScopeSection(hostName: hostName, profileName: profileName)
            CapabilitiesStatusSections(
                support: model.support, isBusy: model.isBusy,
                errorMessage: model.errorMessage, successMessage: model.successMessage,
                retry: { Task { await model.load() } }
            )
            if let snapshot = model.snapshot {
                let toolsets = snapshot.toolsets.filter {
                    ManagementSearch.matches(search, $0.label, $0.name, $0.summary, $0.platformLabel)
                }
                if ManagementSearch.isActive(search), toolsets.isEmpty {
                    ManagementSearchEmptySection(search: search)
                } else {
                    Section {
                        if snapshot.toolsets.isEmpty { Text("No configurable toolsets were reported.").foregroundStyle(.secondary) }
                        ForEach(toolsets) { toolset in
                            NavigationLink {
                                ToolsetDetailView(model: model, toolsetName: toolset.name)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                        Text(toolset.label)
                                        Text("\(toolset.platformLabel) • \(toolset.isEnabled ? "Enabled" : "Disabled")")
                                            .font(.bighelp(.caption)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if toolset.isConfigured { Image(systemName: "checkmark.seal").accessibilityLabel("Configured") }
                                }
                                .frame(minHeight: BighelpTokens.hitTarget)
                            }
                        }
                    } header: { Text("Toolsets") }
                      footer: {
                        Text("Changes apply to new sessions in this profile; the current conversation and Hermes process are unchanged.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Search toolsets")
        .refreshable { await model.load() }
        .task { if model.snapshot == nil { await model.load() } }
    }
}

@MainActor
private struct ToolsetDetailView: View {
    @Bindable var model: ToolsetManagementModel
    let toolsetName: String
    @State private var confirmsToggle = false
    @State private var credentialProvider: ToolsetProvider?

    private var toolset: ToolsetSummary? {
        model.details[toolsetName]?.summary ?? model.snapshot?.toolsets.first { $0.name == toolsetName }
    }
    private var detail: ToolsetDetail? { model.details[toolsetName] }

    var body: some View {
        List {
            CapabilitiesStatusSections(
                support: model.support, isBusy: model.isBusy,
                errorMessage: model.errorMessage, successMessage: model.successMessage,
                retry: { Task { await model.loadDetail(toolsetName) } }
            )
            if let toolset {
                Section("Overview") {
                    LabeledContent("Status", value: toolset.isEnabled ? "Enabled" : "Disabled")
                    LabeledContent("Configuration", value: toolset.isConfigured ? "Ready" : "Needs setup")
                    LabeledContent("Platform", value: toolset.platformLabel)
                    if !toolset.summary.isEmpty { Text(toolset.summary) }
                    Button(toolset.isEnabled ? "Disable" : "Enable") { confirmsToggle = true }
                        .disabled(model.isBusy)
                }
                if let detail {
                    providerSections(detail, toolset: toolset)
                    modelSection(detail, toolset: toolset)
                    Section("Advanced · Included tools") {
                        if toolset.tools.isEmpty { Text("No concrete tools were reported.").foregroundStyle(.secondary) }
                        ForEach(toolset.tools.prefix(200), id: \.self) { Text($0).font(.bighelp(.footnote).monospaced()) }
                    }
                }
            } else {
                ContentUnavailableView("Toolset unavailable", systemImage: "wrench.and.screwdriver")
            }
        }
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
        .confirmationDialog("Change this toolset?", isPresented: $confirmsToggle, titleVisibility: .visible) {
            if let toolset {
                Button(toolset.isEnabled ? "Disable \(toolset.label)" : "Enable \(toolset.label)") {
                    Task { await model.setEnabled(!toolset.isEnabled, toolset: toolset) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only the selected toolset is changed for this profile. New sessions receive the updated tool inventory.")
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
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        HStack {
                            Text(provider.name).font(.bighelp(.headline))
                            Spacer()
                            if provider.isActive { Image(systemName: "checkmark").accessibilityLabel("Active provider") }
                        }
                        if !provider.badge.isEmpty || !provider.tag.isEmpty {
                            Text([provider.badge, provider.tag].filter { !$0.isEmpty }.joined(separator: " • "))
                                .font(.bighelp(.caption)).foregroundStyle(.secondary)
                        }
                        LabeledContent("Readiness", value: provider.status.replacingOccurrences(of: "_", with: " ").capitalized)
                        if provider.requiresNousAuthentication {
                            Text("Requires Nous Portal authentication.").font(.bighelp(.footnote)).foregroundStyle(.secondary)
                        }
                        providerButtons(provider, toolset: toolset)
                    }
                    .padding(.vertical, BighelpTokens.space4)
                }
            }
        }
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
        } else {
            Button(provider.isActive ? "Selected provider" : "Select provider") {
                Task { await model.selectProvider(provider.name, capability: nil, toolset: toolset) }
            }
            .disabled(provider.isActive)
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
            .navigationTitle(provider.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
        }
    }
}
