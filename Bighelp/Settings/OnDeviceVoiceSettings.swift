import SwiftUI

/// Voice settings' Save, on the page and on the voice list it pushes.
@MainActor
struct VoiceSettingsSaveButton: View {
    let store: VoiceSettingsStore?
    var beforeSave: () -> Void = {}

    var body: some View {
        Button {
            beforeSave()
            Task { await store?.save() }
        } label: {
            if store?.isSaving == true {
                ProgressView()
            } else if store?.confirmation != nil, store?.canSave != true {
                // Visible wherever the page is scrolled.
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                    Text("Saved")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Saved")
            } else {
                Text("Save")
            }
        }
        .disabled(store?.canSave != true)
        .accessibilityIdentifier("voice.settings.save")
    }
}

/// An on-device provider's rows in Voice settings: its model, the one-time download, and the
/// voice, which opens the voice list.
@MainActor
struct OnDeviceVoiceRows: View {
    let store: VoiceSettingsStore
    let model: OnDeviceVoiceModel
    let onChooseVoice: () -> Void
    @State private var confirmsRemoval = false

    private var installer: OnDeviceVoiceInstaller { .shared }

    var body: some View {
        LabeledContent("Model", value: model.detail)
        switch installer.state(of: model) {
        case .installed:
            Button(action: onChooseVoice) {
                HStack {
                    LabeledContent("Voice", value: model.voiceTitle(store.voiceID))
                    Image(systemName: "chevron.right")
                        .font(.bighelp(.footnote).weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(store.isSaving)
            .accessibilityIdentifier("voice.settings.on-device-voice")
            Button("Remove from this \(OnDeviceVoiceModel.deviceName)", role: .destructive) { confirmsRemoval = true }
                .accessibilityIdentifier("voice.settings.on-device-remove")
                .confirmationDialog("Remove \(model.title)?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { installer.remove(model) }
                } message: {
                    Text("Agents that use it speak with your computer's voice until you download it again.")
                }
        case .notInstalled:
            Button {
                installer.install(model)
            } label: {
                Label("Download voice (\(model.downloadSize))", systemImage: "arrow.down.circle")
            }
            .accessibilityIdentifier("voice.settings.on-device-download")
            Text("Downloads once, then speaks offline. Keep bighelp open while it downloads. Wi-Fi is best.")
                .bighelpFont(.metadata)
                .foregroundStyle(.secondary)
        case .downloading(let fraction):
            ProgressView(value: fraction) {
                Text("Downloading \(model.title)…")
            } currentValueLabel: {
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
            }
            .accessibilityIdentifier("voice.settings.on-device-progress")
            Button("Cancel download") { installer.cancel(model) }
        case .installing:
            ProgressView("Getting the voice ready…")
        case .failed(let message):
            Text(message)
                .bighelpFont(.metadata)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("voice.settings.on-device-error")
            Button("Try again") { installer.install(model) }
        }
    }
}

/// Every voice of an on-device model, each with a preview made live by the model itself, so
/// people can compare them before they choose one and save.
@MainActor
struct OnDeviceVoicePicker: View {
    @Bindable var store: VoiceSettingsStore
    let model: OnDeviceVoiceModel
    @State private var preview: Task<Void, Never>?
    @BighelpThemeReader private var theme

    private var engine: OnDeviceSpeechEngine { .shared }

    var body: some View {
        let voices = OnDeviceVoiceInstaller.shared.voices(for: model)
        List {
            Section {
                ForEach(voices.filter { !model.characterVoices.contains($0) }, id: \.self, content: row)
            } header: {
                Text("Voices")
            } footer: {
                Text(engine.isPreparing
                     ? "Getting the voice ready. The first time takes a few seconds."
                     : "\(BighelpPlatform.isMac ? "Click" : "Tap") Play to hear a voice. Choose one, then Save.")
            }
            .listRowBackground(theme.surface)
            let characters = voices.filter(model.characterVoices.contains)
            if !characters.isEmpty {
                Section("Characters") {
                    ForEach(characters, id: \.self, content: row)
                }
                .listRowBackground(theme.surface)
            }
        }
        .bighelpFormSurface()
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .foregroundStyle(theme.primaryText)
        .tint(theme.action)
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                VoiceSettingsSaveButton(store: store) { stopPreview() }
            }
        }
        .onDisappear(perform: stopPreview)
    }

    private func row(_ voice: String) -> some View {
        let title = model.voiceTitle(voice)
        let isSelected = store.voiceID == voice
        let isPlaying = engine.previewingVoice == voice
        return HStack(spacing: BighelpTokens.space8) {
            Button {
                store.voiceID = voice
            } label: {
                HStack {
                    Text(title).foregroundStyle(theme.primaryText)
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
            .accessibilityLabel(title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("voice.on-device." + voice)

            Button {
                if isPlaying { stopPreview() } else { play(voice) }
            } label: {
                Group {
                    if isPlaying, engine.isPreparing {
                        ProgressView()
                    } else {
                        Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                            .font(.title2)
                            .foregroundStyle(theme.action)
                    }
                }
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isPlaying ? "Stop \(title)" : "Play \(title)")
            .accessibilityIdentifier("voice.on-device.preview." + voice)
        }
    }

    private func play(_ voice: String) {
        preview?.cancel()
        preview = Task { await engine.preview(voice, model: model) }
    }

    private func stopPreview() {
        preview?.cancel()
        preview = nil
        engine.stopPreview()
    }
}
