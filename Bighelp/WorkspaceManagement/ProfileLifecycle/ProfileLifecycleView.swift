import SwiftUI

/// Parent composition contract:
/// - `retireProfileOwnership` runs after an exact review recheck and before a
///   rename/delete/default mutation. Retire affected retained sessions, prompt
///   routing, profile caches, and pending UI work, but keep this control-plane
///   owner alive through mutation/readback.
/// - `onProfileChanged` runs only after exact server readback. Refresh the shared
///   AgentDirectoryStore and session catalog, reconcile renamed/deleted IDs,
///   update selection/navigation, and preserve unrelated drafts and uncertain
///   submissions. Sticky-default changes must not retarget the live connection.
@MainActor
struct ProfileLifecycleView: View {
    @State private var store: ProfileLifecycleStore
    @State private var renameText = ""
    @State private var exportPath = ""
    @State private var importPath = ""
    @State private var importedName = ""
    @State private var overwriteDescription = false
    @State private var confirmsAutoDescription = false
    @State private var focusText = ""
    @State private var toolsText = ""

    init(
        hostName: String,
        selectedProfileID: String,
        client: any HermesProfileLifecycleManaging,
        retireProfileOwnership: @escaping @MainActor (HermesProfileLifecycleChange) async throws -> Void,
        onProfileChanged: @escaping @MainActor (HermesProfileLifecycleResult) async throws -> Void
    ) {
        _store = State(initialValue: ProfileLifecycleStore(
            hostName: hostName, selectedProfileID: selectedProfileID, client: client,
            retireProfileOwnership: retireProfileOwnership, onProfileChanged: onProfileChanged
        ))
    }

    var body: some View {
        Group {
            if store.ownsScope {
                Form {
                    scopeSection
                    statusSections
                    profileSection
                    lifecycleSection
                    descriptionSection
                    transferSection
                    setupSection
                    onboardingSection
                }
                .refreshable { await store.refresh() }
            } else {
                ContentUnavailableView(
                    "Profile lifecycle unavailable",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("The selected host changed. Reopen Profile Lifecycle from the current workspace.")
                )
            }
        }
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if store.catalog == nil { await store.load() }
            if let profile = store.selectedProfile {
                renameText = profile.isDefaultProfile ? profile.displayName : profile.id
            }
        }
        .onDisappear { if !store.ownsScope { store.retire() } }
        .bighelpSheet(isPresented: reviewBinding(\.renameReview, clear: store.clearRenameReview)) {
            if let review = store.renameReview { renameReviewSheet(review).bighelpSheetSize(.standard) }
        }
        .bighelpSheet(isPresented: reviewBinding(\.deleteReview, clear: store.clearDeleteReview)) {
            if let review = store.deleteReview { deleteReviewSheet(review).bighelpSheetSize(.standard) }
        }
        .bighelpSheet(isPresented: reviewBinding(\.activationReview, clear: store.clearActivationReview)) {
            if let review = store.activationReview { activationReviewSheet(review).bighelpSheetSize(.standard) }
        }
        .bighelpSheet(isPresented: reviewBinding(\.importReview, clear: store.clearImportReview)) {
            if let review = store.importReview { importReviewSheet(review).bighelpSheetSize(.standard) }
        }
        .confirmationDialog(
            "Generate a profile description?", isPresented: $confirmsAutoDescription,
            titleVisibility: .visible
        ) {
            Button(overwriteDescription ? "Replace Description" : "Generate Description") {
                Task { await store.describeAutomatically(overwrite: overwriteDescription) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(overwriteDescription
                 ? "Hermes will ask its configured auxiliary model to replace the existing description, then read the profile back."
                 : "Hermes will preserve a user-authored description unless you explicitly enable replacement.")
        }
        .accessibilityIdentifier("profile-lifecycle.root")
    }

    private var scopeSection: some View {
        Section {
            LabeledContent("Host", value: store.hostName)
            if let active = store.catalog?.active {
                LabeledContent("Sticky default", value: active.activeProfileID)
                LabeledContent("Serving this connection", value: active.currentProfileID)
            }
        } header: { Text("Workspace") } footer: {
            Text("The sticky default affects future Hermes commands and gateways. It does not retarget the profile serving this connection.")
        }
    }

    @ViewBuilder
    private var statusSections: some View {
        if store.isLoading || store.operationTitle != nil {
            Section { ProgressView(store.operationTitle ?? "Loading profiles") }
        }
        if let message = store.errorMessage {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Refresh") { Task { await store.refresh() } }.disabled(store.isBusy)
                Button("Dismiss") { store.clearMessages() }
            }
        }
        if let message = store.successMessage {
            Section {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Dismiss") { store.clearMessages() }
            }
        }
    }

    @ViewBuilder
    private var profileSection: some View {
        if let catalog = store.catalog {
            Section("Profile") {
                Picker("Manage", selection: Binding(
                    get: { store.selectedProfileID },
                    set: { selected in
                        Task {
                            await store.select(selected)
                            if let profile = store.selectedProfile {
                                renameText = profile.isDefaultProfile ? profile.displayName : profile.id
                            }
                        }
                    }
                )) {
                    ForEach(catalog.profiles) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }
                if let profile = store.selectedProfile {
                    LabeledContent("Identifier", value: profile.id)
                    LabeledContent("Description", value: profile.description.isEmpty ? "Not set" : profile.description)
                    LabeledContent("Description source", value: profile.descriptionIsAutomatic ? "Generated" : "User-authored")
                    LabeledContent("Model", value: [profile.providerID, profile.modelID].compactMap { $0 }.joined(separator: " / ").nonEmpty ?? "Inherited")
                    LabeledContent("Skills", value: profile.skillCount.formatted())
                    LabeledContent("Gateway", value: profile.gatewayRunning ? "Running" : "Stopped")
                    if let distribution = profile.distributionName {
                        LabeledContent("Distribution", value: [distribution, profile.distributionVersion].compactMap { $0 }.joined(separator: " "))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var lifecycleSection: some View {
        if let profile = store.selectedProfile, let active = store.catalog?.active {
            Section {
                TextField(profile.isDefaultProfile ? "Default display name" : "New profile identifier", text: $renameText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(profile.isDefaultProfile ? "Review Display Name Change" : "Review Rename", systemImage: "pencil") {
                    Task { await store.prepareRename(newName: renameText) }
                }
                .disabled(store.isBusy || profile.id == active.currentProfileID || renameText.isEmpty)

                if profile.id != active.activeProfileID {
                    Button("Review Make Sticky Default", systemImage: "star") {
                        Task { await store.prepareDefaultActivation() }
                    }
                    .disabled(store.isBusy)
                }

                if !profile.isDefaultProfile {
                    Button("Review Profile Deletion", systemImage: "trash", role: .destructive) {
                        Task { await store.prepareDelete() }
                    }
                    .disabled(
                        store.isBusy || profile.id == active.currentProfileID
                            || profile.id == active.activeProfileID
                    )
                }
            } header: { Text("Changes") }
              footer: {
                  if profile.id == active.currentProfileID {
                      Text("Rename and delete are disabled because this profile serves the active connection. Open this screen through another serving profile to change it safely.")
                  } else {
                      Text("Rename/delete use a complete profile and active-state snapshot, retire affected app-owned state, then require exact profile-catalog readback.")
                  }
              }
        }
    }

    @ViewBuilder
    private var descriptionSection: some View {
        if let profile = store.selectedProfile {
            Section {
                Toggle("Replace user-authored description", isOn: $overwriteDescription)
                    .disabled(profile.description.isEmpty || profile.descriptionIsAutomatic)
                Button("Generate Description", systemImage: "wand.and.sparkles") {
                    confirmsAutoDescription = true
                }
                .disabled(store.isBusy)
            } header: { Text("Advanced · Automatic description") }
              footer: { Text("Generation uses the profile’s configured auxiliary model. A non-OK result preserves the current description and is shown without a blind retry.") }
        }
    }

    private var transferSection: some View {
        Section {
            TextField("Optional host export path", text: $exportPath)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Export Profile on Host", systemImage: "archivebox") {
                Task { await store.exportProfile(outputPath: exportPath.isEmpty ? nil : exportPath) }
            }
            .disabled(store.isBusy)

            if let export = store.archiveExport {
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text("Host archive").font(.bighelp(.caption).weight(.semibold)).foregroundStyle(.secondary)
                    Text(export.archivePath).font(.bighelp(.caption).monospaced()).textSelection(.enabled)
                }
                Button("Dismiss Export Path") { store.clearArchiveExport() }
            }

            TextField("Existing archive path on Hermes host", text: $importPath)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Optional imported profile identifier", text: $importedName)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Review Host Archive Import", systemImage: "archivebox.fill") {
                store.prepareImport(
                    archivePath: importPath,
                    requestedProfileID: importedName.isEmpty ? nil : importedName
                )
            }
            .disabled(store.isBusy || importPath.isEmpty)
        } header: { Text("Advanced · Import & export") }
          footer: {
              Text("These stock APIs exchange paths on the selected Hermes backend. Hermes performs archive confinement, validation, and scanning. bighelp does not open, extract, or reinterpret the archive.")
          }
    }

    private var setupSection: some View {
        Section {
            Button("Show Setup Command", systemImage: "terminal") {
                Task { await store.loadSetupCommand() }
            }
            .disabled(store.isBusy)
            if let command = store.setupCommand {
                Text(command.command).font(.bighelp(.body).monospaced()).textSelection(.enabled)
            }
        } header: { Text("Advanced · Host setup") }
          footer: { Text("This is a read-only command supplied by Hermes. bighelp does not execute it or open a host terminal.") }
    }

    @ViewBuilder
    private var onboardingSection: some View {
        if store.selectedProfileID == "default" {
            Section {
                TextField("Preferred name", text: $store.onboardingFacts.preferredName)
                TextField("What you’re working on", text: $store.onboardingFacts.context, axis: .vertical)
                    .lineLimit(2...5)
                TextField("Focus areas, comma separated", text: $focusText)
                TextField("Tools used, comma separated", text: $toolsText)
                TextField("Desktop theme", text: $store.onboardingFacts.desktopTheme)
                TextField("Desktop accent", text: $store.onboardingFacts.desktopAccent)
                TextField("Desktop layout", text: $store.onboardingFacts.desktopLayout)
                Button("Review and Save Agreed Facts", systemImage: "brain.head.profile") {
                    store.onboardingFacts.focusAreas = commaSeparated(focusText)
                    store.onboardingFacts.tools = commaSeparated(toolsText)
                    Task { await store.saveOnboardingFacts() }
                }
                .disabled(store.isBusy)
            } header: { Text("Advanced · Onboarding memory") }
              footer: {
                  Text("Hermes saves these explicit facts only to the default profile’s user memory. The host verifies the durable write before reporting success. Tool names describe usage, not connection status.")
              }
        }
    }

    private func renameReviewSheet(_ review: HermesProfileRenameReview) -> some View {
        NavigationStack {
            List {
                profileSnapshot(review.profile, active: review.active)
                Section {
                    LabeledContent("Current", value: review.profile.id)
                    LabeledContent(review.profile.isDefaultProfile ? "Display name" : "New identifier", value: review.requestedName)
                } header: { Text("Requested change") }
                Section {
                    Button(review.profile.isDefaultProfile ? "Change Display Name" : "Rename Profile") {
                        Task { await store.renameReviewedProfile() }
                    }
                    .disabled(store.isBusy)
                } footer: {
                    Text("The snapshot is re-read immediately before mutation. The serving connection itself is never renamed.")
                }
            }
            .navigationTitle("Review Rename")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.clearRenameReview() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
        }
    }

    private func deleteReviewSheet(_ review: HermesProfileDeleteReview) -> some View {
        NavigationStack {
            List {
                profileSnapshot(review.profile, active: review.active)
                Section {
                    Button("Delete This Profile", role: .destructive) {
                        Task { await store.deleteReviewedProfile() }
                    }
                    .disabled(store.isBusy)
                } footer: {
                    Text("This permanently removes the profile on Hermes. App-owned sessions, prompt routing, and caches for this exact identifier are retired first; fresh catalog readback must prove absence.")
                }
            }
            .navigationTitle("Review Profile Deletion")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.clearDeleteReview() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
        }
    }

    private func activationReviewSheet(_ review: HermesProfileActivationReview) -> some View {
        NavigationStack {
            List {
                profileSnapshot(review.profile, active: review.active)
                Section {
                    LabeledContent("Current sticky default", value: review.active.activeProfileID)
                    LabeledContent("New sticky default", value: review.profile.id)
                    LabeledContent("Serving connection remains", value: review.active.currentProfileID)
                }
                Section {
                    Button("Make Sticky Default") {
                        Task { await store.activateReviewedDefault() }
                    }
                    .disabled(store.isBusy)
                } footer: {
                    Text("The selected profile becomes the default for future Hermes commands and gateways. This screen verifies that the running connection’s current profile did not change.")
                }
            }
            .navigationTitle("Review Default Profile")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.clearActivationReview() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
        }
    }

    private func importReviewSheet(_ review: HermesProfileArchiveImportReview) -> some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Host", value: store.hostName)
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        Text("Archive path").font(.bighelp(.caption).weight(.semibold)).foregroundStyle(.secondary)
                        Text(review.archivePath).font(.bighelp(.caption).monospaced()).textSelection(.enabled)
                    }
                    LabeledContent("Imported identifier", value: review.requestedProfileID ?? "From archive")
                }
                Section {
                    Button("Import This Host Archive") {
                        Task { await store.importReviewedProfile() }
                    }
                    .disabled(store.isBusy)
                } footer: {
                    Text("Hermes rejects unsafe, missing, malformed, or colliding archives. bighelp waits for the imported profile to appear in a fresh catalog before notifying shared app state.")
                }
            }
            .navigationTitle("Review Profile Import")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.clearImportReview() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
        }
    }

    private func profileSnapshot(
        _ profile: HermesProfileLifecycleItem,
        active: HermesActiveProfileSnapshot
    ) -> some View {
        Section("Reviewed profile snapshot") {
            LabeledContent("Identifier", value: profile.id)
            LabeledContent("Display name", value: profile.displayName)
            LabeledContent("Description", value: profile.description.isEmpty ? "Not set" : profile.description)
            LabeledContent("Description source", value: profile.descriptionIsAutomatic ? "Generated" : "User-authored")
            LabeledContent("Skills", value: profile.skillCount.formatted())
            LabeledContent("Gateway", value: profile.gatewayRunning ? "Running" : "Stopped")
            LabeledContent("Sticky default", value: active.activeProfileID)
            LabeledContent("Serving connection", value: active.currentProfileID)
        }
    }

    private func reviewBinding<Value>(
        _ keyPath: KeyPath<ProfileLifecycleStore, Value?>,
        clear: @escaping () -> Void
    ) -> Binding<Bool> {
        Binding(get: { store[keyPath: keyPath] != nil }, set: { if !$0 { clear() } })
    }

    private func commaSeparated(_ value: String) -> [String] {
        value.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
