import SwiftUI

@MainActor
struct PluginLifecycleManagementView: View {
    @Bindable var model: PluginLifecycleManagementModel
    let hostName: String
    @State private var installCandidate: PluginCatalogEntry?
    @State private var search = ""

    var body: some View {
        List {
            CapabilitiesScopeSection(hostName: hostName, profileName: nil)
            CapabilitiesStatusSections(
                support: model.support, isBusy: model.isBusy,
                errorMessage: model.errorMessage, successMessage: model.successMessage,
                retry: { Task { await model.load() } }
            )
            if let snapshot = model.snapshot {
                let installed = snapshot.installed.filter {
                    ManagementSearch.matches(search, $0.name, $0.source, $0.runtimeStatus)
                }
                let catalog = snapshot.catalog.filter {
                    ManagementSearch.matches(search, $0.name, $0.summary, $0.tier, $0.maintainer)
                }
                if ManagementSearch.isActive(search), installed.isEmpty, catalog.isEmpty {
                    ManagementSearchEmptySection(search: search)
                } else {
                    Section {
                        if snapshot.installed.isEmpty { Text("No installed plugins were reported.").foregroundStyle(.secondary) }
                        ForEach(installed) { plugin in
                            NavigationLink {
                                InstalledPluginDetailView(model: model, pluginName: plugin.name)
                            } label: {
                                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                    Text(plugin.name)
                                    Text("\(plugin.source) • \(plugin.runtimeStatus.capitalized)")
                                        .font(.bighelp(.caption)).foregroundStyle(.secondary)
                                }
                                .frame(minHeight: BighelpTokens.hitTarget)
                            }
                        }
                        Button("Rescan installed plugins", systemImage: "arrow.clockwise") {
                            Task { await model.rescan() }
                        }
                        .disabled(model.isBusy)
                        .frame(minHeight: BighelpTokens.hitTarget)
                    } header: { Text("Installed") }
                      footer: { Text("Rescan refreshes discovery only; it does not install, enable, or restart plugins.") }

                    Section {
                        ForEach(catalog) { entry in
                            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                                HStack {
                                    Text(entry.name).font(.bighelp(.headline))
                                    Spacer()
                                    Text(entry.tier.capitalized).font(.bighelp(.caption)).foregroundStyle(.secondary)
                                }
                                if !entry.summary.isEmpty { Text(entry.summary).font(.bighelp(.subheadline)) }
                                LabeledContent("Capabilities", value: capabilitySummary(entry.capabilities))
                                if entry.isInstalled {
                                    Label(entry.updateAvailable ? "Update available" : "Installed", systemImage: "checkmark.circle")
                                } else {
                                    Button("Review pinned installation") { installCandidate = entry }
                                        .buttonStyle(.bordered)
                                        .disabled(model.isBusy)
                                }
                            }
                            .padding(.vertical, BighelpTokens.space4)
                        }
                    } header: { Text("Available plugins") }
                      footer: {
                        Text("Review the pinned source and declared access before installing. bighelp never force-installs plugins.")
                    }

                    if !snapshot.removedCatalogEntries.isEmpty, !ManagementSearch.isActive(search) {
                        Section("Advanced · Removed from catalog") {
                            ForEach(snapshot.removedCatalogEntries, id: \.self) { Text($0).font(.bighelp(.footnote)) }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Search plugins")
        .refreshable { await model.load() }
        .task { if model.snapshot == nil { await model.load() } }
        .bighelpSheet(item: $installCandidate) { entry in
            PluginInstallReviewView(entry: entry, isBusy: model.isBusy) {
                installCandidate = nil
                Task { await model.install(entry) }
            }
            .bighelpSheetSize(.standard)
        }
    }

    private func capabilitySummary(_ capabilities: PluginCapabilitySummary) -> String {
        let values = [
            capabilities.tools.isEmpty ? nil : "\(capabilities.tools.count) tools",
            capabilities.hooks.isEmpty ? nil : "\(capabilities.hooks.count) hooks",
            capabilities.middleware.isEmpty ? nil : "\(capabilities.middleware.count) middleware",
            capabilities.requiredEnvironment.isEmpty ? nil : "\(capabilities.requiredEnvironment.count) environment fields",
        ].compactMap { $0 }
        return values.isEmpty ? "No declared additions" : values.joined(separator: ", ")
    }
}

private struct PluginInstallReviewView: View {
    let entry: PluginCatalogEntry
    let isBusy: Bool
    let install: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Plugin") {
                    LabeledContent("Plugin", value: entry.name)
                    LabeledContent("Repository", value: entry.repository).textSelection(.enabled)
                    LabeledContent("Commit", value: entry.commitSHA).textSelection(.enabled)
                    LabeledContent("Maintainer", value: entry.maintainer)
                    LabeledContent("Trust tier", value: entry.tier.capitalized)
                    if !entry.platforms.isEmpty {
                        LabeledContent("Platforms", value: entry.platforms.joined(separator: ", "))
                    }
                    if !entry.requiredHermesVersion.isEmpty {
                        LabeledContent("Requires Hermes", value: entry.requiredHermesVersion)
                    }
                    if let url = entry.documentationURL { Link("Open documentation", destination: url) }
                }
                Section("Access") {
                    declared("Tools", entry.capabilities.tools)
                    declared("Hooks", entry.capabilities.hooks)
                    declared("Middleware", entry.capabilities.middleware)
                    declared("Environment fields", entry.capabilities.requiredEnvironment)
                }
                Section {
                    Button("Install and enable this plugin") { install() }
                        .disabled(isBusy)
                        .frame(minHeight: BighelpTokens.hitTarget)
                } footer: {
                    Text("Hermes installs the displayed commit and performs its normal security review. bighelp does not force approval or restart Hermes.")
                }
            }
            .navigationTitle("Review plugin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
        }
    }

    @ViewBuilder private func declared(_ title: String, _ values: [String]) -> some View {
        if values.isEmpty { LabeledContent(title, value: "None") }
        else { LabeledContent(title, value: values.prefix(50).joined(separator: ", ")) }
    }
}

@MainActor
private struct InstalledPluginDetailView: View {
    @Bindable var model: PluginLifecycleManagementModel
    let pluginName: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsRemoval = false
    @State private var confirmsToggle = false

    private var plugin: InstalledPlugin? { model.snapshot?.installed.first { $0.name == pluginName } }

    var body: some View {
        List {
            CapabilitiesStatusSections(
                support: model.support, isBusy: model.isBusy,
                errorMessage: model.errorMessage, successMessage: model.successMessage,
                retry: { Task { await model.load() } }
            )
            if let plugin {
                Section("Overview") {
                    LabeledContent("Version", value: plugin.version.isEmpty ? "Not reported" : plugin.version)
                    LabeledContent("Source", value: plugin.source)
                    LabeledContent("Runtime", value: plugin.runtimeStatus.capitalized)
                    if !plugin.summary.isEmpty { Text(plugin.summary) }
                    if let removed = plugin.removedReason {
                        Label(removed, systemImage: "exclamationmark.shield").foregroundStyle(.red)
                    }
                }
                if plugin.requiresAuthentication {
                    Section("Authentication") {
                        Text("This plugin requires host-side authentication.")
                        if !plugin.authenticationCommand.isEmpty {
                            Text(plugin.authenticationCommand).font(.bighelp(.footnote).monospaced()).textSelection(.enabled)
                        }
                    }
                }
                Section("Manage plugin") {
                    Button(plugin.isEnabled ? "Disable" : "Enable") { confirmsToggle = true }
                    if plugin.canUpdate {
                        Button("Update from its configured Git source") { Task { await model.update(plugin) } }
                    }
                    if plugin.canRemove {
                        Button("Remove plugin", role: .destructive) { confirmsRemoval = true }
                    }
                }
            } else {
                ContentUnavailableView("Plugin unavailable", systemImage: "puzzlepiece.extension")
            }
        }
        .navigationTitle(pluginName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Change this plugin’s runtime state?", isPresented: $confirmsToggle, titleVisibility: .visible) {
            if let plugin {
                Button(plugin.isEnabled ? "Disable \(plugin.name)" : "Enable \(plugin.name)") {
                    Task { await model.setEnabled(!plugin.isEnabled, plugin: plugin) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only the selected plugin is changed. Hermes may require a later restart before runtime-loaded code changes take effect.")
        }
        .confirmationDialog("Remove this plugin?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            if let plugin {
                Button("Remove \(plugin.name)", role: .destructive) {
                    Task { await model.remove(plugin); if model.errorMessage == nil { dismiss() } }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Hermes will remove only this user or Git plugin. Bundled and project plugins are not presented as removable.")
        }
    }
}
