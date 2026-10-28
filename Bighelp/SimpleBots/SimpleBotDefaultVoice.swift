import SwiftUI

/// What the Bot Profile needs to show and edit the voice one bot speaks with.
struct SimpleBotVoiceSettings {
    let store: VoiceSettingsStore
    let settings: SettingsStore
}

/// The short line the Default Voice row shows.
@MainActor
enum SimpleBotDefaultVoiceSummary {
    static func text(
        mode: VoiceConversationMode,
        liveProvider: LiveVoiceProvider,
        liveVoice: String,
        store: VoiceSettingsStore
    ) -> String? {
        switch mode {
        case .codexLive:
            let name = liveVoice.isEmpty ? liveProvider.defaultVoice : liveVoice
            return "\(String(localized: "GPT Live")) · \(name.capitalized)"
        case .turnBased:
            guard let provider = store.selectedProvider else { return nil }
            guard provider.hasVoice, !provider.voiceID.isEmpty else { return provider.title }
            return "\(provider.title) · \(provider.voiceID)"
        }
    }
}

/// GPT Live is one choice for the whole device, so picking it here is the same
/// as picking it in Voice settings.
enum SimpleBotDefaultVoiceChoice {
    @MainActor
    static func apply(_ mode: VoiceConversationMode, to settings: SettingsStore) {
        guard settings.voiceConversationMode != mode else { return }
        settings.voiceConversationMode = mode
    }
}

struct SimpleBotDefaultVoiceSheet: View {
    let voice: SimpleBotVoiceSettings
    let botName: String
    let onClose: () -> Void

    @State private var isChoosingProvider = false
    @State private var isChoosingOnDeviceVoice = false
    @State private var confirmAPIBilling = false
    @State private var confirmsDiscard = false
    @FocusState private var focusedField: VoiceSettingsField?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.bighelpHostRegistry) private var hostRegistry
    @BighelpThemeReader private var theme

    private var store: VoiceSettingsStore { voice.store }
    private var settings: SettingsStore { voice.settings }
    private var isGPTLive: Bool { settings.voiceConversationMode == .codexLive }

    var body: some View {
        NavigationStack {
            Form {
                modeSection
                if isGPTLive {
                    gptLiveSections
                } else {
                    VoiceSettingsEditor(store: store, focusedField: $focusedField,
                                        isChoosingProvider: $isChoosingProvider,
                                        isChoosingOnDeviceVoice: $isChoosingOnDeviceVoice)
                }
            }
            .bighelpFormSurface()
            .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .foregroundStyle(theme.primaryText)
            .tint(theme.action)
            .navigationTitle(String(localized: "Default Voice"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .navigationDestination(isPresented: $isChoosingProvider) {
                if let configuration = store.configuration {
                    VoiceProviderList(providers: configuration.providers, selection: store.providerID) {
                        store.selectProvider($0)
                    }
                }
            }
            .navigationDestination(isPresented: $isChoosingOnDeviceVoice) {
                if let model = OnDeviceVoiceModel.model(providerID: store.providerID) {
                    OnDeviceVoicePicker(store: store, model: model)
                }
            }
            .confirmationDialog(String(localized: "Use separately billed API voice?"),
                                isPresented: $confirmAPIBilling, titleVisibility: .visible) {
                Button(String(localized: "Use API key provider")) { settings.liveVoiceProvider = .apiKey }
                Button(String(localized: "Keep Codex subscription"), role: .cancel) {}
            } message: {
                Text("An API key may add separate OpenAI charges.")
            }
            .confirmationDialog(String(localized: "Save changes?"), isPresented: $confirmsDiscard,
                                titleVisibility: .visible) {
                if store.canSave {
                    Button(String(localized: "Save")) { saveAndClose() }
                }
                Button(String(localized: "Discard"), role: .destructive) {
                    store.discardEdits()
                    close()
                }
                Button(String(localized: "Keep editing"), role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(!isGPTLive && store.hasUnsavedChanges)
        .task { if store.configuration == nil { await store.load() } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.clearAPIKey() }
        }
        .onDisappear {
            store.clearAPIKey()
            store.discardEdits()
        }
    }

    private var modeSection: some View {
        Section {
            Picker(String(localized: "Voice type"), selection: mode) {
                Text(VoiceConversationMode.turnBased.title).tag(VoiceConversationMode.turnBased)
                Text(VoiceConversationMode.codexLive.title).tag(VoiceConversationMode.codexLive)
            }
            .pickerStyle(.segmented)
            .bighelpSegmentedPicker()
            .frame(minHeight: BighelpTokens.hitTarget)
            .accessibilityIdentifier("simple-bots.default-voice.mode")
            Text(settings.voiceConversationMode.detail)
                .bighelpFont(.metadata)
                .foregroundStyle(.secondary)
        } header: {
            Text(botName)
        }
    }

    @ViewBuilder
    private var gptLiveSections: some View {
        Section {
            Picker(String(localized: "Sign in with"), selection: liveProvider) {
                Text(LiveVoiceProvider.codexSubscription.title).tag(LiveVoiceProvider.codexSubscription)
                Text(LiveVoiceProvider.apiKey.title).tag(LiveVoiceProvider.apiKey)
            }
            .accessibilityIdentifier("simple-bots.default-voice.live-provider")
            Picker(String(localized: "Voice"), selection: liveVoice) {
                ForEach(settings.liveVoiceProvider.voices, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .accessibilityIdentifier("simple-bots.default-voice.live-voice")
        } header: {
            Text("GPT Live")
        } footer: {
            Text("Applies to every bot on this device.")
                .bighelpFont(.metadata)
                .foregroundStyle(.secondary)
        }
        if hostRegistry?.selectedHost != nil {
            HostPluginFeatureSection(feature: .liveVoice)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(String(localized: "Done")) { finish() }
                .accessibilityIdentifier("simple-bots.default-voice.done")
        }
        if !isGPTLive {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    focusedField = nil
                    Task { await store.save() }
                } label: {
                    if store.isSaving {
                        ProgressView()
                    } else if store.confirmation != nil, !store.canSave {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                            Text("Saved")
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(String(localized: "Saved"))
                    } else {
                        Text("Save")
                    }
                }
                .disabled(!store.canSave)
                .accessibilityIdentifier("simple-bots.default-voice.save")
            }
        }
    }

    private var mode: Binding<VoiceConversationMode> {
        Binding(
            get: { settings.voiceConversationMode },
            set: { value in
                focusedField = nil
                SimpleBotDefaultVoiceChoice.apply(value, to: settings)
            }
        )
    }

    private var liveProvider: Binding<LiveVoiceProvider> {
        Binding(
            get: { settings.liveVoiceProvider },
            set: { value in
                if value == .apiKey {
                    confirmAPIBilling = true
                } else {
                    settings.liveVoiceProvider = value
                }
            }
        )
    }

    private var liveVoice: Binding<String> {
        Binding(
            get: { settings.liveVoice(for: settings.liveVoiceProvider) },
            set: { settings.setLiveVoice($0, for: settings.liveVoiceProvider) }
        )
    }

    private func finish() {
        focusedField = nil
        if !isGPTLive, store.hasUnsavedChanges {
            confirmsDiscard = true
        } else {
            close()
        }
    }

    private func saveAndClose() {
        Task {
            await store.save()
            if !store.hasUnsavedChanges { close() }
        }
    }

    private func close() {
        store.clearAPIKey()
        onClose()
    }
}
