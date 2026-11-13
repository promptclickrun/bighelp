import Observation
import SwiftUI

/// What Settings › Models › Advanced › Mixture of Agents reads and saves: the bot's model snapshot,
/// which carries its Mixture of Agents presets.
@MainActor @Observable
final class ModelAdministrationStore {
    let hostName: String
    let profileID: String

    private(set) var snapshot: DirectHermesModelAdministrationSnapshot?
    private(set) var isLoading = false
    private(set) var operationTitle: String?
    private(set) var errorMessage: String?
    private(set) var successMessage: String?

    @ObservationIgnored private let client: DirectHermesModelAdministrationClient
    @ObservationIgnored private var generation = UUID()

    init(hostName: String, profileID: String, client: DirectHermesModelAdministrationClient) {
        self.hostName = hostName
        self.profileID = profileID
        self.client = client
    }

    var ownsScope: Bool { client.ownsScope }
    var isBusy: Bool { isLoading || operationTitle != nil }

    func load() async {
        guard ownsScope, !isBusy else { return }
        let request = UUID()
        generation = request
        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer { if generation == request { isLoading = false } }
        do {
            let value = try await client.loadSnapshot(profileID: profileID, refreshModels: false)
            guard ownsScope, generation == request, !Task.isCancelled else { return }
            snapshot = value
        } catch is CancellationError {
        } catch {
            guard ownsScope, generation == request else { return }
            errorMessage = Self.message(error)
        }
    }

    func saveMoA(_ configuration: DirectHermesMoAConfiguration) async -> Bool {
        guard ownsScope, !isBusy else { return false }
        operationTitle = "Saving Mixture of Agents"
        errorMessage = nil
        successMessage = nil
        defer { operationTitle = nil }
        do {
            try await client.saveMoAConfiguration(profileID: profileID, configuration: configuration)
            guard ownsScope else { return false }
            let value = try await client.loadSnapshot(profileID: profileID)
            guard ownsScope else { return false }
            snapshot = value
            successMessage = "Hermes confirmed the complete Mixture of Agents configuration."
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    private static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "Hermes could not confirm this model operation. Refresh before trying it again."
    }
}

/// A bot on the computer, for Settings › Models' Default model rows.
struct ModelAdministrationAgent: Identifiable, Equatable {
    let id: String
    let name: String
    let imageURL: URL?
}

/// Settings › Models › Advanced › Mixture of Agents: the presets of the bot in use, and their editor.
@MainActor
struct ModelsMixtureOfAgentsView: View {
    @State private var store: ModelAdministrationStore

    init(hostName: String, profileID: String, client: DirectHermesModelAdministrationClient) {
        _store = State(initialValue: ModelAdministrationStore(hostName: hostName, profileID: profileID, client: client))
    }

    var body: some View {
        Form {
            if store.isLoading || store.operationTitle != nil {
                Section { ProgressView(store.operationTitle ?? "Loading…") }
            }
            if let error = store.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Button("Refresh") { Task { await store.load() } }.disabled(store.isBusy)
                }
                .accessibilityIdentifier("models.error")
            }
            if let success = store.successMessage {
                Section { Label(success, systemImage: "checkmark.circle") }
                    .accessibilityIdentifier("models.confirmed")
            }
            if let snapshot = store.snapshot {
                if let configuration = snapshot.moa {
                    Section {
                        LabeledContent("Default preset", value: configuration.defaultPreset)
                        LabeledContent("Presets", value: configuration.presets.count.formatted())
                        NavigationLink("Edit model assignments") {
                            ModelAdministrationMoAView(store: store, initial: configuration)
                        }
                        .disabled(store.isBusy)
                        if !configuration.privacyFilter.isEmpty {
                            Label("This computer has a MoA privacy-filter override. The pinned write API cannot preserve it, so bighelp keeps this page read-only.", systemImage: "lock")
                                .font(.bighelp(.footnote)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        Text("This computer has no Mixture of Agents presets.")
                            .foregroundStyle(.secondary)
                    }
                }
                SkippedPartsNote(parts: snapshot.skippedParts)
            }
        }
        .bighelpFormSurface()
        .navigationTitle("Mixture of Agents")
        .navigationBarTitleDisplayMode(.inline)
        .bighelpRefreshable { await store.load() }
        .task { if store.snapshot == nil { await store.load() } }
        .accessibilityIdentifier("models.moa")
    }
}

@MainActor
private struct ModelAdministrationMoAView: View {
    /// A reference or aggregator model being chosen in the shared picker.
    private enum SlotTarget: Identifiable, Hashable {
        case reference(preset: Int, index: Int)
        case aggregator(preset: Int)
        var id: Self { self }
    }

    let store: ModelAdministrationStore
    @State private var configuration: DirectHermesMoAConfiguration
    @State private var confirmSave = false
    @State private var slotTarget: SlotTarget?
    @Environment(\.dismiss) private var dismiss

    init(store: ModelAdministrationStore, initial: DirectHermesMoAConfiguration) {
        self.store = store
        _configuration = State(initialValue: initial)
    }

    private var providers: [DirectHermesModelProvider] {
        (store.snapshot?.providers ?? []).filter { $0.id.lowercased() != "moa" && !$0.models.isEmpty }
    }

    var body: some View {
        Form {
            Section {
                Picker("Default preset", selection: $configuration.defaultPreset) {
                    ForEach(configuration.presets) { Text($0.name).tag($0.name) }
                }
                Picker("Active preset", selection: $configuration.activePreset) {
                    Text("Default").tag("")
                    ForEach(configuration.presets) { Text($0.name).tag($0.name) }
                }
            } header: {
                Text("Preset routing")
            } footer: {
                Text("All visible preset fields are round-tripped together. Hidden computer overrides outside this typed document are not cleared.")
            }

            ForEach(configuration.presets.indices, id: \.self) { presetIndex in
                Section(configuration.presets[presetIndex].name) {
                    Toggle("Enabled", isOn: $configuration.presets[presetIndex].isEnabled)
                    Picker("Fan-out", selection: Binding(
                        get: { configuration.presets[presetIndex].fanout ?? "user_turn" },
                        set: { configuration.presets[presetIndex].fanout = $0 }
                    )) {
                        Text("Once per user turn").tag("user_turn")
                        Text("Every tool iteration").tag("per_iteration")
                    }
                    Picker("Failed reference policy", selection: $configuration.presets[presetIndex].degradedReferencePolicy) {
                        Text("Report failures").tag("loud")
                        Text("Continue silently").tag("silent")
                    }
                    ForEach(configuration.presets[presetIndex].referenceModels.indices, id: \.self) { referenceIndex in
                        DisclosureGroup("Reference \(referenceIndex + 1)") {
                            moaSlotEditor(slot: $configuration.presets[presetIndex].referenceModels[referenceIndex],
                                          target: .reference(preset: presetIndex, index: referenceIndex), allowsDisable: true)
                            if configuration.presets[presetIndex].referenceModels.count > 1 {
                                Button("Remove reference", role: .destructive) {
                                    configuration.presets[presetIndex].referenceModels.remove(at: referenceIndex)
                                }
                            }
                        }
                    }
                    Button("Add reference model", systemImage: "plus") {
                        if let provider = providers.first, let model = provider.models.first {
                            configuration.presets[presetIndex].referenceModels.append(.init(
                                providerID: provider.id, modelID: model,
                                reasoningEffort: nil, isEnabled: true
                            ))
                        }
                    }
                    .disabled(providers.isEmpty || configuration.presets[presetIndex].referenceModels.count >= 32)
                    DisclosureGroup("Aggregator") {
                        moaSlotEditor(slot: $configuration.presets[presetIndex].aggregator,
                                      target: .aggregator(preset: presetIndex), allowsDisable: false)
                    }
                }
            }

            if !configuration.privacyFilter.isEmpty {
                Section {
                    Label("Saving is unavailable because this computer's MoA privacy filter cannot be represented by the pinned write API without resetting it.", systemImage: "lock")
                }
            }
            Section {
                Button("Review Mixture of Agents changes") { confirmSave = true }
                    .disabled(store.isBusy || !configuration.privacyFilter.isEmpty || providers.isEmpty)
            }
        }
        .navigationTitle("Mixture of Agents")
        .navigationBarTitleDisplayMode(.inline)
        .bighelpSheet(item: $slotTarget) { target in
            slotPicker(target)
                .bighelpSheetSize(.standard)
        }
        .confirmationDialog("Save all MoA preset assignments?", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("Save") {
                let submitted = configuration
                Task { if await store.saveMoA(submitted) { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will validate and replace the typed MoA preset document for this bot. This can change model spend for future MoA runs.")
        }
    }

    @ViewBuilder
    private func moaSlotEditor(slot: Binding<DirectHermesMoAModelSlot>, target: SlotTarget, allowsDisable: Bool) -> some View {
        if allowsDisable { Toggle("Use this reference", isOn: slot.isEnabled) }
        BighelpModelChoiceRow(
            providerID: slot.wrappedValue.providerID,
            providerName: providers.first(where: { $0.id == slot.wrappedValue.providerID })?.name
                ?? slot.wrappedValue.providerID,
            modelID: slot.wrappedValue.modelID,
            emptyTitle: "Choose a model",
            isEnabled: !providers.isEmpty
        ) {
            slotTarget = target
        }
    }

    /// The chat's model picker for one reference or aggregator slot. The choice is
    /// saved with the rest of the presets when you review and save.
    private func slotPicker(_ target: SlotTarget) -> some View {
        let slot = self.slot(target)
        return BighelpModelPickerSheet(
            title: "Choose model",
            scopeLabel: {
                switch target {
                case .reference(let preset, let index): "\(configuration.presets[preset].name) · Reference \(index + 1)"
                case .aggregator(let preset): "\(configuration.presets[preset].name) · Aggregator"
                }
            }(),
            providers: providers.map(BighelpLinkModelProvider.init(administration:)),
            currentProviderID: slot?.providerID,
            currentModelID: slot?.modelID,
            isLoading: false,
            isApplying: false,
            errorMessage: nil,
            onClearError: {},
            onRetry: nil,
            onSelect: { _, _ in },
            applyTitle: "Use this model",
            onApply: { draft in
                guard let providerID = draft.providerID, let modelID = draft.modelID else { return }
                switch target {
                case .reference(let preset, let index):
                    configuration.presets[preset].referenceModels[index].providerID = providerID
                    configuration.presets[preset].referenceModels[index].modelID = modelID
                case .aggregator(let preset):
                    configuration.presets[preset].aggregator.providerID = providerID
                    configuration.presets[preset].aggregator.modelID = modelID
                }
                slotTarget = nil
            }
        )
        .presentationDetents([.large])
    }

    private func slot(_ target: SlotTarget) -> DirectHermesMoAModelSlot? {
        switch target {
        case .reference(let preset, let index):
            guard configuration.presets.indices.contains(preset),
                  configuration.presets[preset].referenceModels.indices.contains(index) else { return nil }
            return configuration.presets[preset].referenceModels[index]
        case .aggregator(let preset):
            guard configuration.presets.indices.contains(preset) else { return nil }
            return configuration.presets[preset].aggregator
        }
    }
}
