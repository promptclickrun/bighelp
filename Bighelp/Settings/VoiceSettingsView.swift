import SwiftUI

enum VoiceSettingsField { case server, key }

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
    /// A pushed picker (provider, voice, model); that isn't leaving Voice settings.
    @State private var page: VoiceSettingsPage?
    @State private var loadedTaskID: String?
    @FocusState private var focusedField: VoiceSettingsField?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.workspaceConnections) private var workspaceConnections

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
    /// for itself. A bot that has TTS as its own voice type (Bots mode) still needs its provider.
    private var showsSpeechProvider: Bool {
        settings.voiceConversationMode == .turnBased || settings.autoSpeakRepliesEnabled
            || agents.contains { ownMode($0.id) == .turnBased }
    }

    /// An agent's own voice type from its Default Voice, if it has one.
    private func ownMode(_ agentID: String) -> VoiceConversationMode? {
        guard let computer = workspaceConnections?.owner?.cacheScopeID else { return nil }
        return AgentVoiceChoices.shared.mode(computer: computer, agentID: agentID)
    }

    private var agentFooter: String {
        let base = String(localized: "Each agent has its own speech provider and voice, saved on your computer. A voice that runs on this \(OnDeviceVoiceModel.deviceName) is saved here.")
        guard let mode = ownMode(agentID), let name = agents.first(where: { $0.id == agentID })?.name else { return base }
        return base + " " + String(localized: "\(name) uses \(mode.title) for voice, its own choice in Bots mode.")
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
                    Text(agentFooter)
                }
                if agents.contains(where: { $0.id == agentID }) {
                    if let store, store.agentID == agentID {
                        VoiceSettingsEditor(store: store, focusedField: $focusedField, page: $page)
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
        .modifier(VoiceSettingsPages(store: store, page: $page))
        .task(id: loadTaskID) {
            // Back from a picker: keep the loaded settings and edits.
            if loadedTaskID == loadTaskID, store?.configuration != nil { return }
            loadedTaskID = loadTaskID
            store?.invalidate()
            store = nil
            guard let client, scope != nil, agents.contains(where: { $0.id == agentID }) else { return }
            let current = VoiceSettingsStore(agentID: agentID, client: client,
                                             options: DirectHermesVoiceOptionsClient.connected(workspaceConnections),
                                             isCurrent: isCurrent)
            store = current
            await current.load()
        }
        .onDisappear { if page == nil { store?.invalidate() } }
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
            Text("Default voice mode")
        } footer: {
            Text("Used when you \(BighelpPlatform.isMac ? "click" : "tap") the microphone in a chat. It's the default for every agent; in Bots mode, a bot's Default Voice can pick its own.")
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
                Text("Sign-ins stay on your computer. An API key may add separate OpenAI charges. The voice is the default for every agent.")
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

/// One agent's speech provider, voice and model, with the API key and server address where the
/// provider has them. Voices and models are picked from lists on pages of their own (`VoiceSettingsPages`).
@MainActor
struct VoiceSettingsEditor: View {
    @Bindable var store: VoiceSettingsStore
    @FocusState.Binding var focusedField: VoiceSettingsField?
    @Binding var page: VoiceSettingsPage?

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
            VoiceSettingsChoiceRow(title: "Provider", value: selected?.title ?? store.providerID) { open(.provider) }
                .accessibilityIdentifier("voice.settings.provider")
                .disabled(store.isSaving || store.isLoading)
                // So the voice row can name a voice the computer lists (ElevenLabs' by name, not its ID).
                .task(id: store.providerID) { await store.loadHostCatalog() }

            if let selected {
                Text(summary(for: selected))
                    .bighelpFont(.metadata)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("voice.settings.provider-summary")
            }
            if let selected, let model = OnDeviceVoiceModel.model(providerID: selected.id) {
                OnDeviceVoiceRows(store: store, model: model) { open(.onDeviceVoice) }
            } else if selected?.takesVoice == true {
                VoiceSettingsChoiceRow(title: "Voice", value: store.voiceName) { open(.voice) }
                    .accessibilityIdentifier("voice.settings.voice-id")
                    .disabled(store.isSaving)
            }
            if selected?.hasModel == true {
                VoiceSettingsChoiceRow(title: "Model", value: store.modelName) { open(.model) }
                    .accessibilityIdentifier("voice.settings.model")
                    .disabled(store.isSaving)
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

    private func open(_ destination: VoiceSettingsPage) {
        focusedField = nil
        page = destination
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
        case .custom:
            provider.voiceLocation == .plugin ? "A speech plugin on your computer." : "A speech command set up on your computer."
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
struct VoiceProviderList: View {
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
        case .custom: provider.voiceLocation == .plugin ? "A speech plugin on your computer" : "A speech command on your computer"
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

/// A row that opens a picker page: its title, what's chosen, and a chevron.
@MainActor
struct VoiceSettingsChoiceRow: View {
    let title: LocalizedStringKey
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                LabeledContent(title, value: value)
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The pages Voice settings pushes from an agent's speech provider.
enum VoiceSettingsPage: Hashable, Identifiable {
    case provider, onDeviceVoice, voice, model
    var id: Self { self }
}

/// Pushes `page` for `store`; Settings › Voice and a bot's Default Voice share it.
@MainActor
struct VoiceSettingsPages: ViewModifier {
    let store: VoiceSettingsStore?
    @Binding var page: VoiceSettingsPage?

    func body(content: Content) -> some View {
        content.navigationDestination(item: $page) { page in
            if let store {
                switch page {
                case .provider:
                    if let configuration = store.configuration {
                        VoiceProviderList(providers: configuration.providers, selection: store.providerID) {
                            store.selectProvider($0)
                        }
                    }
                case .onDeviceVoice:
                    if let model = OnDeviceVoiceModel.model(providerID: store.providerID) {
                        OnDeviceVoicePicker(store: store, model: model)
                    }
                case .voice:
                    VoiceOptionPicker(store: store, kind: .voice)
                case .model:
                    VoiceOptionPicker(store: store, kind: .model)
                }
            }
        }
    }
}

/// A provider's voices or models on one page, grouped where they have groups (a language), with a
/// checkmark on the one chosen. Other takes a value that isn't listed, only where the provider accepts one.
@MainActor
struct VoiceOptionPicker: View {
    enum Kind { case voice, model }

    @Bindable var store: VoiceSettingsStore
    let kind: Kind
    @State private var other = ""
    @FocusState private var isOtherFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    private var list: VoiceOptionList {
        (kind == .voice ? store.voiceChoices : store.modelChoices) ?? VoiceOptionList(options: [])
    }

    private var selection: String {
        (kind == .voice ? store.voiceID : store.model).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var providerTitle: String { store.selectedProvider?.title ?? store.providerID }

    var body: some View {
        let choices = list
        List {
            if kind == .voice, let note { noteSection(note) }
            ForEach(groups(choices.options), id: \.title) { group in
                Section {
                    ForEach(group.options) { row($0) }
                } header: {
                    if let title = group.title { Text(title) }
                }
                .listRowBackground(theme.surface)
            }
            if choices.allowsOther { otherSection }
        }
        .bighelpFormSurface()
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .foregroundStyle(theme.primaryText)
        .tint(theme.action)
        .navigationTitle(kind == .voice ? Text("Voice") : Text("Model"))
        .navigationBarTitleDisplayMode(.inline)
        .task { if kind == .voice { await store.loadHostCatalog() } }
    }

    private var note: String? {
        switch store.hostCatalog {
        case .loading: String(localized: "Getting \(providerTitle) voices from your computer…")
        case .needsPluginUpdate:
            String(localized: "Update the bighelp plugin on your computer to choose from its voices. Until then, the agent keeps the voice it has.")
        case .unavailable(let reason): reason
        case .loaded, nil: nil
        }
    }

    private func noteSection(_ note: String) -> some View {
        Section {
            HStack(spacing: BighelpTokens.space8) {
                if store.hostCatalog == .loading { ProgressView() }
                Text(note)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("voice.option.note")
        }
        .listRowBackground(theme.surface)
    }

    private struct OptionSection { let title: String?; let options: [VoiceOption] }

    /// Sections in the order their first option comes.
    private func groups(_ options: [VoiceOption]) -> [OptionSection] {
        var order: [String?] = []
        var rows: [String?: [VoiceOption]] = [:]
        for option in options {
            if rows[option.group] == nil { order.append(option.group) }
            rows[option.group, default: []].append(option)
        }
        return order.map { OptionSection(title: $0, options: rows[$0] ?? []) }
    }

    private func row(_ option: VoiceOption) -> some View {
        let isSelected = option.id == selection
        return Button {
            choose(option.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name).foregroundStyle(theme.primaryText)
                    if let detail = option.detail {
                        Text(detail).bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(theme.action).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(store.isSaving)
        .accessibilityLabel(option.name)
        .accessibilityValue(option.detail ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("voice.option." + (option.id.isEmpty ? "default" : option.id))
    }

    private var otherSection: some View {
        Section {
            let hint: LocalizedStringKey = kind == .voice ? "Voice name or ID" : "Model name"
            TextField(hint, text: $other, prompt: Text(hint).bighelpFieldHint(theme))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isOtherFocused)
                .submitLabel(.done)
                .onSubmit(useOther)
                .accessibilityIdentifier("voice.option.other-field")
            Button(kind == .voice ? LocalizedStringKey("Use this voice") : LocalizedStringKey("Use this model"),
                   action: useOther)
                .disabled(other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSaving)
                .accessibilityIdentifier("voice.option.other-use")
        } header: {
            Text("Other")
        } footer: {
            Text(kind == .voice
                 ? String(localized: "For a voice \(providerTitle) has that isn't listed, such as one you made yourself.")
                 : String(localized: "For a model your server has that isn't listed."))
        }
        .listRowBackground(theme.surface)
    }

    private func useOther() {
        let value = other.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        isOtherFocused = false
        choose(value)
    }

    private func choose(_ id: String) {
        if kind == .voice { store.chooseVoice(id) } else { store.chooseModel(id) }
        dismiss()
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
