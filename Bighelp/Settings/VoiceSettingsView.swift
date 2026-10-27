import SwiftUI

private enum VoiceSettingsField { case voice, model, server, key }

enum CodexLiveVoicePluginAvailability: Equatable, Sendable {
    case unknown
    case missing
    case ready
    case unavailable
}

enum CodexLiveVoiceSettingsPresentation {
    static let title = "Codex Live Voice"
    static let installAccessibilityIdentifier = "settings.install-loopdy-plugin-for-live-voice"

    static func detail(for availability: CodexLiveVoicePluginAvailability) -> String {
        switch availability {
        case .unknown:
            "Codex Live Voice requires the bighelp plugin. Connect to a paired host to verify plugin readiness."
        case .missing:
            "Codex Live Voice requires the bighelp plugin on the selected host. Install it to use live voice with your Codex subscription."
        case .ready:
            "The bighelp plugin is ready for Codex Live Voice on the selected host."
        case .unavailable:
            "Codex Live Voice requires the bighelp plugin, but this host has not provided a verified readiness result."
        }
    }
}

@MainActor
struct VoiceSettingsView: View {
    @Bindable var settings: SettingsStore
    let agents: [AgentProfile]
    let client: (any VoiceSettingsClient)?
    let scope: String?
    let isCurrent: @MainActor () -> Bool
    @State private var agentID: String
    @State private var store: VoiceSettingsStore?
    @State private var confirmAPIBilling = false
    /// Choosing a provider or an on-device voice pushes a page; that isn't leaving Voice settings.
    @State private var isChoosingProvider = false
    @State private var isChoosingOnDeviceVoice = false
    @State private var loadedTaskID: String?
    @FocusState private var focusedField: VoiceSettingsField?
    @Environment(\.scenePhase) private var scenePhase

    init(settings: SettingsStore, agents: [AgentProfile], selectedAgentID: String?,
         client: (any VoiceSettingsClient)?, scope: String?,
         isCurrent: @escaping @MainActor () -> Bool) {
        self.settings = settings
        self.agents = agents
        self.client = client
        self.scope = scope
        self.isCurrent = isCurrent
        _agentID = State(initialValue: agents.first(where: { $0.id == selectedAgentID })?.id
            ?? agents.first(where: \.isDefault)?.id ?? agents.first?.id ?? "")
    }

    @BighelpThemeReader private var theme

    private var loadTaskID: String {
        (scope ?? "disconnected") + ":" + agentID
    }

    /// TTS voice mode and Auto TTS speak with each agent's speech provider; GPT Live 1 speaks
    /// for itself.
    private var showsSpeechProvider: Bool {
        settings.voiceConversationMode == .turnBased || settings.autoSpeakRepliesEnabled
    }

    var body: some View {
        Form {
            VoicePreferenceSections(settings: settings, confirmAPIBilling: $confirmAPIBilling)

            if !showsSpeechProvider {
                // GPT Live 1 speaks for itself.
            } else if client != nil, scope != nil, !agents.isEmpty {
                Section {
                    Picker("Agent", selection: $agentID) {
                        ForEach(agents) { Text($0.name).tag($0.id) }
                    }
                    .accessibilityIdentifier("voice.settings.agent")
                } header: {
                    Text("Agent")
                } footer: {
                    Text("Each agent has its own speech provider and voice, saved on your computer. A voice that runs on this \(OnDeviceVoiceModel.deviceName) is saved here.")
                }
                if agents.contains(where: { $0.id == agentID }) {
                    if let store, store.agentID == agentID {
                        VoiceSettingsEditor(store: store, focusedField: $focusedField,
                                            isChoosingProvider: $isChoosingProvider,
                                            isChoosingOnDeviceVoice: $isChoosingOnDeviceVoice)
                    }
                }
            } else {
                Section("Speech provider") {
                    Text("Connect to your computer to choose your agents' speech provider and voice.")
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .bighelpFormSurface()
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .foregroundStyle(theme.primaryText)
        .tint(theme.action)
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Use separately billed API voice?", isPresented: $confirmAPIBilling,
                            titleVisibility: .visible) {
            Button("Use API key provider") { settings.liveVoiceProvider = .apiKey }
            Button("Keep Codex subscription", role: .cancel) {}
        } message: {
            Text("The host's API key may incur separate usage charges. Subscription failures never switch providers automatically.")
        }
        .onChange(of: agents.map(\.id)) { _, ids in
            if !ids.contains(agentID) { agentID = agents.first(where: \.isDefault)?.id ?? ids.first ?? "" }
        }
        .toolbar {
            if showsSpeechProvider {
                ToolbarItem(placement: .topBarTrailing) {
                    VoiceSettingsSaveButton(store: store) { focusedField = nil }
                }
            }
        }
        .navigationDestination(isPresented: $isChoosingProvider) {
            if let store, let configuration = store.configuration {
                VoiceProviderList(providers: configuration.providers, selection: store.providerID) {
                    store.selectProvider($0)
                }
            }
        }
        .navigationDestination(isPresented: $isChoosingOnDeviceVoice) {
            if let store, let model = OnDeviceVoiceModel.model(providerID: store.providerID) {
                OnDeviceVoicePicker(store: store, model: model)
            }
        }
        .task(id: loadTaskID) {
            // Back from the provider list: keep the loaded settings and edits.
            if loadedTaskID == loadTaskID, store?.configuration != nil { return }
            loadedTaskID = loadTaskID
            store?.invalidate()
            store = nil
            guard let client, scope != nil, agents.contains(where: { $0.id == agentID }) else { return }
            let current = VoiceSettingsStore(agentID: agentID, client: client, isCurrent: isCurrent)
            store = current
            await current.load()
        }
        .onDisappear { if !isChoosingProvider, !isChoosingOnDeviceVoice { store?.invalidate() } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store?.clearAPIKey() }
        }
    }
}

@MainActor
private struct VoicePreferenceSections: View {
    @Bindable var settings: SettingsStore
    @Binding var confirmAPIBilling: Bool

    private var provider: Binding<LiveVoiceProvider> {
        Binding(
            get: { settings.liveVoiceProvider },
            set: { value in
                if value == .apiKey { confirmAPIBilling = true }
                else { settings.liveVoiceProvider = value }
            }
        )
    }

    private var voice: Binding<String> {
        Binding(
            get: { settings.liveVoice(for: settings.liveVoiceProvider) },
            set: { settings.setLiveVoice($0, for: settings.liveVoiceProvider) }
        )
    }

    var body: some View {
        Section {
            Picker("Voice mode", selection: $settings.voiceConversationMode) {
                Text(VoiceConversationMode.turnBased.title).tag(VoiceConversationMode.turnBased)
                Text(VoiceConversationMode.codexLive.title).tag(VoiceConversationMode.codexLive)
            }
            .bighelpSegmentedPicker()
            .frame(minHeight: BighelpTokens.hitTarget)
            .accessibilityIdentifier("voice.settings.conversation-mode")
            Text(settings.voiceConversationMode.detail)
                .bighelpFont(.metadata)
                .foregroundStyle(.secondary)
        } header: {
            Text("Voice mode")
        } footer: {
            Text("Used when you \(BighelpPlatform.isMac ? "click" : "tap") the microphone in a chat.")
        }

        Section {
            Toggle("Use TTS on every response", isOn: $settings.autoSpeakRepliesEnabled)
                .accessibilityIdentifier("voice.settings.auto-tts")
        } header: {
            Text("In chats")
        } footer: {
            Text("Reads each reply aloud in the agent's voice as it arrives. Sending a message or leaving the chat stops it. Also in a chat's + menu as Auto TTS.")
        }

        if settings.voiceConversationMode == .codexLive {
            Section {
                Picker("Sign in with", selection: provider) {
                    Text(LiveVoiceProvider.codexSubscription.title)
                        .tag(LiveVoiceProvider.codexSubscription)
                    Text(LiveVoiceProvider.apiKey.title)
                        .tag(LiveVoiceProvider.apiKey)
                }
                .accessibilityIdentifier("voice.settings.live-provider")
                Picker("Voice", selection: voice) {
                    ForEach(settings.liveVoiceProvider.voices, id: \.self) { option in
                        Text(option.capitalized).tag(option)
                    }
                }
                .accessibilityIdentifier("voice.settings.live-voice")
            } header: {
                Text("GPT Live 1")
            } footer: {
                Text("Sign-ins stay on your computer. An API key may add separate OpenAI charges.")
            }
            HostPluginFeatureSection(feature: .liveVoice)
        } else {
            Section {
                Picker("Speaking mode", selection: $settings.voiceMode) {
                    ForEach(VoiceMode.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .accessibilityIdentifier("settings.chat.voice-mode")
                Picker("Speech to text", selection: $settings.voiceTranscription) {
                    ForEach(VoiceTranscriptionSource.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .accessibilityIdentifier("voice.settings.transcription")
                Picker("Voice speed", selection: $settings.voiceSpeed) {
                    ForEach(VoiceSpeed.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Toggle("Hold music", isOn: $settings.voiceHoldMusicEnabled)
                    .accessibilityIdentifier("voice.settings.hold-music")
            } header: {
                Text("Listening")
            } footer: {
                Text(settings.voiceMode.detail + " " + settings.voiceTranscription.detail + " "
                     + (settings.voiceHoldMusicEnabled
                        ? String(localized: "Hold music plays while your agent works on a reply.")
                        : String(localized: "The wait for a reply is silent.")))
            }
        }
    }
}

@MainActor
private struct VoiceSettingsEditor: View {
    @Bindable var store: VoiceSettingsStore
    @FocusState.Binding var focusedField: VoiceSettingsField?
    @Binding var isChoosingProvider: Bool
    @Binding var isChoosingOnDeviceVoice: Bool

    var body: some View {
        Group {
            if let configuration = store.configuration {
                providerSection(configuration)
            }
            if let confirmation = store.confirmation {
                Section {
                    Label(confirmation, systemImage: "checkmark.circle")
                        .accessibilityIdentifier("voice.settings.confirmation")
                }
            }
            if store.configuration != nil {
                sampleSection
            }

            if store.isLoading {
                Section { ProgressView("Loading voice settings…") }
            }
            if let error = store.errorMessage {
                Section {
                    Text(error).bighelpFont(.metadata)
                    Button("Reload settings") { Task { await store.load() } }
                        .disabled(store.isLoading || store.isSaving)
                }
            }
        }
    }

    private func providerSection(_ configuration: VoiceSettingsConfiguration) -> some View {
        let selected = store.selectedProvider
        return Section {
            Button {
                focusedField = nil
                isChoosingProvider = true
            } label: {
                HStack {
                    LabeledContent("Provider", value: selected?.title ?? store.providerID)
                    Image(systemName: "chevron.right")
                        .font(.bighelp(.footnote).weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("voice.settings.provider")
            .disabled(store.isSaving || store.isLoading)

            if let selected {
                Text(summary(for: selected))
                    .bighelpFont(.metadata)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("voice.settings.provider-summary")
            }
            if let selected, let model = OnDeviceVoiceModel.model(providerID: selected.id) {
                OnDeviceVoiceRows(store: store, model: model) {
                    focusedField = nil
                    isChoosingOnDeviceVoice = true
                }
            } else if selected?.hasVoice == true {
                field("Voice", placeholder: "Voice name or ID", text: $store.voiceID, focus: .voice,
                      identifier: "voice.settings.voice-id")
            }
            if selected?.hasModel == true {
                field("Model", placeholder: "Automatic", text: $store.model, focus: .model,
                      identifier: "voice.settings.model")
            }
            if selected?.supportsServerURL == true {
                field("Server", placeholder: "OpenAI (leave blank)", text: $store.serverURL, focus: .server,
                      identifier: "voice.settings.server-url", keyboard: .URL)
            }
            if let selected, selected.needsAPIKey {
                VStack(alignment: .leading, spacing: 6) {
                    Text("API key")
                    SecureField(selected.apiKeyConfigured ? "Saved — enter a replacement" : "Enter API key",
                                text: $store.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .focused($focusedField, equals: .key)
                        .accessibilityIdentifier("voice.settings.api-key")
                }
                Text(selected.apiKeyConfigured ? "API key saved on your computer" : "API key required")
                    .bighelpFont(.metadata)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("voice.settings.key-status")
            }
        } header: {
            Text("Speech provider")
        } footer: {
            Text(footer(for: selected))
        }
        .disabled(store.isSaving)
    }

    private var sampleSection: some View {
        Section {
            Button {
                focusedField = nil
                Task { await store.playSample() }
            } label: {
                HStack {
                    Label("Play a sample", systemImage: "play.circle")
                    Spacer()
                    if store.isPlayingSample { ProgressView() }
                }
            }
            .disabled(!store.canPlaySample)
            .accessibilityIdentifier("voice.settings.play-sample")
            if let error = store.sampleError {
                Text(error)
                    .bighelpFont(.metadata)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("voice.settings.sample-error")
            }
        } footer: {
            if store.hasUnsavedChanges { Text("Save to hear your changes.") }
        }
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>, focus: VoiceSettingsField,
                       identifier: String, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .focused($focusedField, equals: focus)
                .accessibilityIdentifier(identifier)
        }
    }

    private func summary(for provider: VoiceProviderConfiguration) -> String {
        switch provider.kind {
        case .onThisDevice:
            "Runs on this \(OnDeviceVoiceModel.deviceName), even offline. No account or key."
        case .onYourComputer:
            provider.hasVoice ? "Runs on your computer. Your agent's words never leave it."
                : "Runs on your computer. Its voice is set up there."
        case .custom: "A speech command set up on your computer."
        case .free: "Free Microsoft voices. No account or key needed."
        case .cloud:
            provider.needsAPIKey ? "Uses your own \(provider.title) account." : "Set up on your computer."
        }
    }

    private func footer(for provider: VoiceProviderConfiguration?) -> String {
        switch provider?.kind {
        case .onThisDevice:
            "Saved on this \(OnDeviceVoiceModel.deviceName) for this agent. Your computer keeps its own voice for its other apps."
        case .onYourComputer:
            "Install it once by running hermes setup tts on your computer, then play a sample here."
        case .cloud where provider?.supportsServerURL == true:
            "To use your own OpenAI-compatible server, like Kokoro or Speaches, enter its address. Those servers usually accept any key. Leave the key blank to keep the saved one."
        case .cloud where provider?.needsAPIKey == true:
            "Leave the API key blank to keep the saved one. Changes apply to this agent's next spoken reply."
        default:
            "Changes apply to this agent's next spoken reply."
        }
    }
}

/// Every speech provider on one page, grouped by where it runs.
@MainActor
private struct VoiceProviderList: View {
    let providers: [VoiceProviderConfiguration]
    let selection: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    var body: some View {
        List {
            ForEach(VoiceProviderSpec.Kind.allCases, id: \.self) { kind in
                let items = providers.filter { $0.kind == kind }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { row($0) }
                    } header: {
                        Text(kind.title)
                    } footer: {
                        Text(footer(kind))
                    }
                    .listRowBackground(theme.surface)
                }
            }
        }
        .bighelpFormSurface()
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .foregroundStyle(theme.primaryText)
        .tint(theme.action)
        .navigationTitle("Speech provider")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ provider: VoiceProviderConfiguration) -> some View {
        let isSelected = provider.id == selection
        return Button {
            onSelect(provider.id)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.title).foregroundStyle(theme.primaryText)
                    Text(detail(provider)).bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(theme.action).accessibilityHidden(true)
                }
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(provider.title)
        .accessibilityValue(detail(provider))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("voice.provider." + provider.id)
    }

    private func detail(_ provider: VoiceProviderConfiguration) -> String {
        switch provider.kind {
        case .onThisDevice: "No account or key, works offline"
        case .onYourComputer, .free: "No account or key"
        case .custom: "A speech command on your computer"
        case .cloud:
            !provider.needsAPIKey ? "Set up on your computer"
                : provider.apiKeyConfigured ? "API key saved" : "Needs an API key"
        }
    }

    private func footer(_ kind: VoiceProviderSpec.Kind) -> String {
        switch kind {
        case .onThisDevice: "Speaks on this \(OnDeviceVoiceModel.deviceName), with no voice service. The voice downloads once."
        case .onYourComputer: "Your agent's words never leave your computer. Install one once by running hermes setup tts there."
        case .custom: "Set up in your agent's config.yaml under tts.providers."
        case .free: "Microsoft's free online voices."
        case .cloud: "Billed to your own account with that service. OpenAI also works with self-hosted OpenAI-compatible servers."
        }
    }
}

private extension VoiceSpeed {
    var title: String {
        switch self {
        case .slow: "Slow"
        case .normal: "Normal"
        case .fast: "Fast"
        }
    }
}
