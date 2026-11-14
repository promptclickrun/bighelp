import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct VoiceConfigurationView: View {
    @Bindable var store: VoiceConfigurationStore
    let recordingSource: VoiceConfigurationRecordingSource?
    let onUseTranscript: ((String) -> Void)?

    @State private var recordingController: VoiceConfigurationRecordingController
    @State private var isImportingAudio = false
    @State private var transcriptionTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedField: Field?

    private enum Field {
        case voiceID
        case transcript
        case playback
    }

    init(
        store: VoiceConfigurationStore,
        recordingSource: VoiceConfigurationRecordingSource? = nil,
        onUseTranscript: ((String) -> Void)? = nil,
        permissionCenter: PermissionCenter? = nil
    ) {
        self.store = store
        self.recordingSource = recordingSource
        self.onUseTranscript = onUseTranscript
        _recordingController = State(initialValue: VoiceConfigurationRecordingController(
            permissionCenter: permissionCenter ?? PermissionCenter()
        ))
    }

    var body: some View {
        Form {
            identitySection

            if let configuration = store.configuration {
                voiceSelectionSection
                dictationSection
                playbackSection
                transportSection(configuration)
                stockLiveSection
            } else if store.isLoading {
                Section {
                    ProgressView("Loading voice configuration…")
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "Voice Configuration Unavailable",
                        systemImage: "waveform.slash",
                        description: Text("Refresh after reconnecting to this host and profile.")
                    )
                    Button("Refresh") {
                        Task { await store.refresh() }
                    }
                    .frame(minHeight: 44)
                }
            }

            if let notice = store.noticeMessage {
                Section {
                    Label(notice, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("voice.configuration.notice")
                }
            }

            if let error = store.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("voice.configuration.error")
                    Button("Dismiss") { store.clearMessages() }
                        .frame(minHeight: 44)
                }
            }
        }
        .navigationTitle("Host Voice")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.defaultMinListRowHeight, 44)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    focusedField = nil
                    Task { await store.refresh() }
                } label: {
                    if store.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(!store.canAct)
                .accessibilityLabel("Refresh voice configuration")
                .accessibilityIdentifier("voice.configuration.refresh")
            }
        }
        .task { await store.refresh() }
        .fileImporter(
            isPresented: $isImportingAudio,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            guard recordingSource == nil, case .success(let urls) = result,
                  urls.count == 1, let url = urls.first else { return }
            recordingController.importRecording(from: url)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.refresh() }
            } else {
                focusedField = nil
                transcriptionTask?.cancel()
                transcriptionTask = nil
                recordingController.cancelAndCleanUp()
                store.clearSensitiveConfiguration()
            }
        }
        .onChange(of: store.ownsScope) { _, ownsScope in
            guard !ownsScope else { return }
            transcriptionTask?.cancel()
            transcriptionTask = nil
            recordingController.retire()
        }
        .onDisappear {
            transcriptionTask?.cancel()
            transcriptionTask = nil
            recordingController.retire()
            store.retire()
        }
    }

    private var identitySection: some View {
        Section("Workspace") {
            LabeledContent("Host", value: store.hostName)
            LabeledContent("Profile", value: store.profileID)
        }
    }

    private func transportSection(
        _ configuration: DirectHermesVoiceConfigurationSnapshot
    ) -> some View {
        Section {
            transportRow(
                title: "Dictation",
                configuration: configuration.speechToText,
                accessibilityID: "voice.configuration.stt"
            )
            transportRow(
                title: "Playback",
                configuration: configuration.textToSpeech,
                accessibilityID: "voice.configuration.tts"
            )
        } header: {
            Text("Advanced · Routing")
        } footer: {
            Text("Client-direct provider credentials stay in memory only and are destroyed when this screen, scene, host, or profile retires. Relay providers keep credentials on the Hermes host.")
        }
    }

    private func transportRow(
        title: String,
        configuration: DirectHermesVoiceRouteConfiguration,
        accessibilityID: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(configuration.isClientDirect ? "Client direct" : "Host relay")
                    .foregroundStyle(.secondary)
            }
            if case .direct(let resolved) = configuration {
                Text("\(resolved.providerID) · \(resolved.wire.rawValue)")
                    .font(.bighelp(.caption))
                    .foregroundStyle(.secondary)
            } else if case .relay(let reason) = configuration, let reason, !reason.isEmpty {
                Text(reason)
                    .font(.bighelp(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(accessibilityID)
    }

    private var voiceSelectionSection: some View {
        Section {
            Picker("Provider", selection: Binding(
                get: { store.selectedProvider },
                set: { store.chooseProvider($0) }
            )) {
                ForEach(DirectHermesSelectableVoiceProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .disabled(!store.canAct)
            .accessibilityIdentifier("voice.configuration.provider")

            if store.selectedProvider == .elevenLabs, store.voiceCatalog.isAvailable,
               !store.voiceCatalog.voices.isEmpty {
                Picker("Voice", selection: Binding(
                    get: { store.selectedVoiceID },
                    set: { store.chooseVoice($0) }
                )) {
                    ForEach(store.voiceCatalog.voices) { voice in
                        Text(voice.label).tag(voice.id)
                    }
                }
                .disabled(!store.canAct)
                .accessibilityIdentifier("voice.configuration.voice-picker")
            } else {
                TextField(
                    store.selectedProvider == .openAI ? "OpenAI voice" : "ElevenLabs voice ID",
                    text: Binding(
                        get: { store.selectedVoiceID },
                        set: { store.chooseVoice($0) }
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .voiceID)
                .disabled(!store.canAct)
                .accessibilityIdentifier("voice.configuration.voice-id")
            }

            Button {
                focusedField = nil
                Task { await store.saveSelection() }
            } label: {
                if store.isSavingSelection {
                    ProgressView()
                } else {
                    Label("Save Voice", systemImage: "checkmark")
                }
            }
            .disabled(!store.canSaveSelection)
            .frame(minHeight: 44)
            .accessibilityIdentifier("voice.configuration.save-voice")
        } header: {
            Text("Voice")
        } footer: {
            if store.selectedProvider == .elevenLabs,
               let reason = store.voiceCatalog.unavailableReason, !reason.isEmpty {
                Text(reason)
            } else {
                Text("Saving changes only the selected host profile’s TTS provider and voice. It does not change Bighelp’s live-voice provider or sign-in mode.")
            }
        }
    }

    private var dictationSection: some View {
        Section {
            if let recordingSource {
                Button {
                    focusedField = nil
                    beginTranscription(from: recordingSource)
                } label: {
                    if store.isTranscribing {
                        ProgressView()
                    } else {
                        Label("Transcribe Recording", systemImage: "waveform.badge.mic")
                    }
                }
                .disabled(!store.canTranscribe)
                .frame(minHeight: 44)
                .accessibilityIdentifier("voice.configuration.transcribe")
            } else {
                VoiceConfigurationRecordingControls(
                    controller: recordingController,
                    canPrepareRecording: store.canAct,
                    canTranscribe: store.canTranscribe,
                    onImport: {
                        focusedField = nil
                        isImportingAudio = true
                    },
                    onTranscribe: {
                        focusedField = nil
                        guard let recording = try? recordingController.finalizedRecording() else { return }
                        beginTranscription(recording)
                    }
                )
            }

            if !store.transcriptDraft.isEmpty {
                TextEditor(text: $store.transcriptDraft)
                    .frame(minHeight: 96)
                    .focused($focusedField, equals: .transcript)
                    .accessibilityLabel("Editable transcript")
                    .accessibilityIdentifier("voice.configuration.transcript")

                if let onUseTranscript {
                    Button("Use Transcript") {
                        let text = store.transcriptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        focusedField = nil
                        onUseTranscript(text)
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("voice.configuration.use-transcript")
                }
            }
        } header: {
            Text("Dictation")
        } footer: {
            Text(store.supportsFullRelayTranscription
                ? "Record or import up to two minutes of finalized audio, then explicitly transcribe it. Review the editable transcript before using it; Bighelp never sends the transcript automatically."
                : "Record or import up to two minutes of finalized audio, then explicitly transcribe it. Short recordings use the existing authenticated JSON route; larger host-relay recordings require the fixed voice-media transport extension.")
        }
    }

    private func beginTranscription(from source: @escaping VoiceConfigurationRecordingSource) {
        transcriptionTask?.cancel()
        transcriptionTask = Task { @MainActor in
            await store.transcribeFrom(source)
            if !Task.isCancelled {
                transcriptionTask = nil
            }
        }
    }

    private func beginTranscription(_ recording: DirectHermesVoiceRecording) {
        transcriptionTask?.cancel()
        transcriptionTask = Task { @MainActor in
            await store.transcribe(recording)
            if !Task.isCancelled {
                transcriptionTask = nil
            }
        }
    }

    private var playbackSection: some View {
        Section {
            TextEditor(text: $store.playbackText)
                .frame(minHeight: 96)
                .focused($focusedField, equals: .playback)
                .accessibilityLabel("Text to preview")
                .accessibilityIdentifier("voice.configuration.playback-text")

            HStack {
                Button {
                    focusedField = nil
                    Task { await store.playPreview() }
                } label: {
                    if store.playbackState == .preparing {
                        ProgressView()
                    } else {
                        Label("Play", systemImage: "play.fill")
                    }
                }
                .disabled(!store.canPlay)
                .frame(minWidth: 88, minHeight: 44)
                .accessibilityIdentifier("voice.configuration.play")

                Spacer()

                Button(role: .cancel) {
                    store.stopPlayback()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(store.playbackState == .idle)
                .frame(minWidth: 88, minHeight: 44)
                .accessibilityIdentifier("voice.configuration.stop")
            }
        } header: {
            Text("Playback preview")
        } footer: {
            Text(store.supportsStreamingPlayback
                ? "Streaming playback uses a fresh authenticated audio socket and falls back to buffered host speech only when Hermes explicitly requests fallback."
                : "Buffered provider or host playback is available now. Real streamed PCM playback remains unavailable until the parent adds the fresh-ticket audio WebSocket transport.")
        }
    }

    private var stockLiveSection: some View {
        Section {
            if let status = store.stockLiveStatus {
                LabeledContent("Host mode", value: status.mode == .gptLive ? "GPT-Live" : "Chained")
                LabeledContent("Host readiness", value: status.isAvailable ? "Available" : "Unavailable")
                LabeledContent("Model", value: status.modelID)
                LabeledContent("Voice", value: status.voiceID)
                if let reason = status.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.bighelp(.caption))
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Stock live voice", value: "Not advertised")
            }
        } header: {
            Text("Advanced · Live voice")
        } footer: {
            Text("This is read-only discovery. Bighelp’s existing Codex subscription live voice remains the primary selected system, and its optional API-key mode remains explicit. This screen does not mount stock GPT-Live, switch engines, or add a fallback.")
        }
        .accessibilityIdentifier("voice.configuration.stock-live-status")
    }
}
