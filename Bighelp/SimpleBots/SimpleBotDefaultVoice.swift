import Observation
import SwiftUI

/// What a bot's profile needs to show and edit the voice the bot speaks with: its own voice type and
/// GPT Live 1 voice, kept on this device, and its speech provider on its computer.
@MainActor
struct SimpleBotVoiceSettings {
    let settings: SettingsStore
    var choices: AgentVoiceChoices = .shared
    /// The computer the bot's own choices are kept under (`cacheScopeID`).
    let computer: String
    /// The connection voice settings go through now, nil while there's none. Each reconnect is a new
    /// one, and a store made for the last one can't save, play or reload any more.
    let connection: @MainActor () -> String?
    /// A store on the connection of the moment; nil while it can't change the bot's speech provider.
    let makeStore: @MainActor () -> VoiceSettingsStore?
}

/// A bot's Default Voice: its store follows the connection the way Settings › Voice does, so Save,
/// Play and Reload keep working after the app comes back from the background.
@MainActor
@Observable
final class SimpleBotVoiceModel {
    let agentID: String
    let voice: SimpleBotVoiceSettings
    private(set) var store: VoiceSettingsStore?
    @ObservationIgnored private var storeConnection: String?

    init(agentID: String, voice: SimpleBotVoiceSettings) {
        self.agentID = agentID
        self.voice = voice
    }

    var settings: SettingsStore { voice.settings }

    /// What the profile's task follows: a new value makes a new store.
    var connection: String? { voice.connection() }

    var preference: AgentVoicePreference {
        settings.voicePreference(computer: voice.computer, agentID: agentID, choices: voice.choices)
    }

    /// The row under Default Model.
    var summary: String? { SimpleBotDefaultVoiceSummary.text(voice: preference, store: store) }

    /// A store for the connection of the moment, loaded. The one it has stays while the connection does,
    /// so edits survive the sheet closing and opening again.
    func follow() async {
        let current = voice.connection()
        if current != storeConnection || (store == nil && current != nil) {
            store?.invalidate()
            storeConnection = current
            store = current == nil ? nil : voice.makeStore()
        }
        guard let store, store.configuration == nil, !store.isLoading else { return }
        await store.load()
        await store.loadHostCatalog()
    }

    /// Voice type for this bot only.
    func setMode(_ mode: VoiceConversationMode) {
        settings.setVoiceConversationMode(mode, computer: voice.computer, agentID: agentID, choices: voice.choices)
    }

    /// Back to the default for every agent (Settings › Voice).
    func useDefaultMode() {
        voice.choices.setMode(nil, computer: voice.computer, agentID: agentID)
    }

    func setLiveVoice(_ value: String) {
        voice.choices.setLiveVoice(value, for: settings.liveVoiceProvider, computer: voice.computer, agentID: agentID)
    }
}

/// The short line the Default Voice row shows.
@MainActor
enum SimpleBotDefaultVoiceSummary {
    static func text(voice: AgentVoicePreference, store: VoiceSettingsStore?) -> String? {
        switch voice.mode {
        case .codexLive:
            return "\(VoiceConversationMode.codexLive.title) · \(voice.liveVoice.capitalized)"
        case .turnBased:
            // What the computer has saved, not edits still open in the sheet.
            guard let configuration = store?.configuration,
                  let provider = configuration.providers.first(where: { $0.id == configuration.providerID })
            else { return nil }
            guard provider.takesVoice else { return provider.title }
            let name = OnDeviceVoiceModel.model(providerID: provider.id)?.voiceTitle(provider.voiceID)
                ?? VoiceOptions.voiceName(provider.voiceID, provider: provider, model: provider.model,
                                          serverURL: provider.serverURL, host: store?.hostCatalogs[provider.id])
            return "\(provider.title) · \(name)"
        }
    }
}

struct SimpleBotDefaultVoiceSheet: View {
    let model: SimpleBotVoiceModel
    let botName: String
    let onClose: () -> Void

    @State private var page: VoiceSettingsPage?
    @State private var confirmAPIBilling = false
    @State private var confirmsDiscard = false
    @FocusState private var focusedField: VoiceSettingsField?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.bighelpHostRegistry) private var hostRegistry
    @BighelpThemeReader private var theme

    private var store: VoiceSettingsStore? { model.store }
    private var settings: SettingsStore { model.settings }
    private var preference: AgentVoicePreference { model.preference }

    /// TTS speaks with the speech provider, and so does Auto TTS while the bot talks with GPT Live 1.
    private var showsSpeechProvider: Bool {
        preference.mode == .turnBased || settings.autoSpeakRepliesEnabled
    }

    private var hasUnsavedChanges: Bool { showsSpeechProvider && store?.hasUnsavedChanges == true }

    var body: some View {
        NavigationStack {
            Form {
                modeSection
                if preference.mode == .codexLive { gptLiveSections }
                if showsSpeechProvider {
                    if let store {
                        VoiceSettingsEditor(store: store, focusedField: $focusedField, page: $page)
                    } else {
                        Section("Speech provider") {
                            Text("Connect to your computer to choose \(botName)'s speech provider and voice.")
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
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
            .modifier(VoiceSettingsPages(store: store, page: $page))
            .confirmationDialog(String(localized: "Use separately billed API voice?"),
                                isPresented: $confirmAPIBilling, titleVisibility: .visible) {
                Button(String(localized: "Use API key provider")) { settings.liveVoiceProvider = .apiKey }
                Button(String(localized: "Keep Codex subscription"), role: .cancel) {}
            } message: {
                Text("An API key may add separate OpenAI charges.")
            }
            .confirmationDialog(String(localized: "Save changes?"), isPresented: $confirmsDiscard,
                                titleVisibility: .visible) {
                if store?.canSave == true {
                    Button(String(localized: "Save")) { saveAndClose() }
                }
                Button(String(localized: "Discard"), role: .destructive) {
                    store?.discardEdits()
                    close()
                }
                Button(String(localized: "Keep editing"), role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
        .task { await model.follow() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store?.clearAPIKey() }
        }
        .onDisappear {
            store?.clearAPIKey()
            store?.discardEdits()
        }
    }

    private var modeSection: some View {
        Section {
            Picker(String(localized: "Voice type"), selection: mode) {
                Text(VoiceConversationMode.turnBased.title).tag(VoiceConversationMode.turnBased)
                Text(VoiceConversationMode.codexLive.title).tag(VoiceConversationMode.codexLive)
            }
            .bighelpSegmentedPicker()
            .frame(minHeight: BighelpTokens.hitTarget)
            .accessibilityIdentifier("simple-bots.default-voice.mode")
            Text(preference.mode.detail)
                .bighelpFont(.metadata)
                .foregroundStyle(.secondary)
            if preference.hasOwnMode {
                Button(String(localized: "Use the default for every agent")) { model.useDefaultMode() }
                    .accessibilityIdentifier("simple-bots.default-voice.use-default")
            }
        } header: {
            Text(botName)
        } footer: {
            Text(preference.hasOwnMode
                 ? String(localized: "Just for \(botName). Settings › Voice sets the default for every other agent.")
                 : String(localized: "\(botName) uses the default for every agent, from Settings › Voice. A choice here is just for \(botName)."))
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
            Text(VoiceConversationMode.codexLive.title)
        } footer: {
            Text(settings.autoSpeakRepliesEnabled
                 ? String(localized: "The voice is just for \(botName); the sign-in is the same for every agent. Auto TTS reads replies with the speech provider below.")
                 : String(localized: "The voice is just for \(botName); the sign-in is the same for every agent."))
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
        if showsSpeechProvider {
            ToolbarItem(placement: .topBarTrailing) {
                VoiceSettingsSaveButton(store: store, identifier: "simple-bots.default-voice.save") {
                    focusedField = nil
                }
            }
        }
    }

    private var mode: Binding<VoiceConversationMode> {
        Binding(
            get: { preference.mode },
            set: { value in
                focusedField = nil
                model.setMode(value)
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
        Binding(get: { preference.liveVoice }, set: { model.setLiveVoice($0) })
    }

    private func finish() {
        focusedField = nil
        if hasUnsavedChanges {
            confirmsDiscard = true
        } else {
            close()
        }
    }

    private func saveAndClose() {
        Task {
            await store?.save()
            if store?.hasUnsavedChanges != true { close() }
        }
    }

    private func close() {
        store?.clearAPIKey()
        onClose()
    }
}
