import SwiftUI

/// Voice in Simple Bot mode: a bar over the chat, so the chat stays in view and in use. The bot's face,
/// a visualizer from real audio levels (your voice in the page's ink, the bot's in its color, dots while
/// nobody speaks), the voice choices, the microphone, and End.
@MainActor
struct SimpleBotVoiceBar: View {
    let presentation: VoicePresentation
    let agentID: String
    let agentName: String
    let imageURL: URL?
    let permissionCenter: PermissionCenter
    let onSwitchMode: (VoiceConversationMode) -> Void
    let onEnded: () -> Void

    @State private var levels = Array(repeating: 0.0, count: SimpleBotVoiceVisualizer.barCount)
    @State private var speaker = SimpleBotVoiceVisualizer.Speaker.nobody
    @Environment(\.companionAgentScope) private var scope
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(spacing: BighelpTokens.space8) {
            HStack(spacing: BighelpTokens.space12) {
                SimpleBotFace(agentID: agentID, name: agentName, imageURL: imageURL, size: 44, blinks: true)
                SimpleBotVoiceVisualizer(levels: levels, speaker: speaker, agentColor: agentColor)
                    .frame(maxWidth: .infinity, maxHeight: 40)
                    .accessibilityElement()
                    .accessibilityLabel(speaker == .agent ? "\(agentName) is speaking"
                                        : speaker == .person ? "Listening to you" : "Voice is on")
                    .accessibilityIdentifier("simple-bots.voice.visualizer")
                choicesMenu
                microphoneButton
                endButton
            }
            Capsule().fill(theme.tertiaryText.opacity(0.5)).frame(width: 36, height: 4)
                .accessibilityHidden(true)
        }
        .padding(.leading, BighelpTokens.space16)
        .padding(.trailing, BighelpTokens.space12)
        .padding(.top, BighelpTokens.space12)
        .padding(.bottom, BighelpTokens.space8)
        .bighelpNavigationGlass(in: Capsule(), isInteractive: false)
        .padding(.horizontal, BighelpTokens.space12)
        .modifier(SimpleBotVoiceTurnLifecycle(model: presentation.liveModel == nil ? presentation.model : nil,
                                              permissionCenter: permissionCenter))
        .task { presentation.liveModel?.start() }
        .task { await sampleLevels() }
        .onDisappear {
            presentation.liveModel?.end()
            presentation.model.stopMonitoring()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple-bots.voice")
    }

    private var isLive: Bool { presentation.liveModel != nil }

    private var agentColor: Color {
        let mark = SimpleBotMarkStore.shared.mark(scope: scope, agentID: agentID)
        return (mark ?? (imageURL == nil ? .defaultMark(for: agentID) : nil))?.color.color ?? theme.action
    }

    private var isMicrophoneMuted: Bool {
        presentation.liveModel?.isMuted ?? presentation.model.isMicrophoneMuted
    }

    private var isAgentMuted: Bool {
        presentation.liveModel?.isSpeakerMuted ?? presentation.model.isAgentAudioMuted
    }

    private var choicesMenu: some View {
        Menu {
            Picker("Voice", selection: Binding(
                get: { presentation.conversationMode },
                set: { mode in if mode != presentation.conversationMode { onSwitchMode(mode) } })) {
                Text("Live voice").tag(VoiceConversationMode.codexLive)
                Text("TTS voice").tag(VoiceConversationMode.turnBased)
            }
            Button(isAgentMuted ? "Unmute \(agentName)" : "Mute \(agentName)",
                   systemImage: isAgentMuted ? "speaker.wave.2" : "speaker.slash") {
                if let live = presentation.liveModel { live.setSpeakerMuted(!live.isSpeakerMuted) }
                else { presentation.model.toggleAgentAudio() }
            }
        } label: {
            circle("gearshape", tint: theme.primaryText)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Voice choices")
        .accessibilityIdentifier("simple-bots.voice.choices")
    }

    @ViewBuilder
    private var microphoneButton: some View {
        let model = presentation.model
        if !isLive, model.mode == .walkieTalkie {
            // Walkie-talkie: tap to talk, tap again to send.
            Button {
                if model.isWalkieTalkieCapturing {
                    _ = model.endWalkieTalkieCapture(submit: true)
                } else if let generation = model.armWalkieTalkieCapture() {
                    Task { _ = await model.startArmedWalkieTalkieCapture(generation: generation) }
                }
            } label: {
                circle(model.isWalkieTalkieCapturing ? "waveform" : "mic", tint: theme.primaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isWalkieTalkieCapturing ? "Send what you said" : "Talk")
            .accessibilityIdentifier("simple-bots.voice.microphone")
        } else {
            Button {
                if let live = presentation.liveModel { live.setMuted(!live.isMuted) } else { model.toggleMicrophone() }
            } label: {
                circle(isMicrophoneMuted ? "mic.slash" : "mic", tint: theme.primaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isMicrophoneMuted ? "Unmute microphone" : "Mute microphone")
            .accessibilityIdentifier("simple-bots.voice.microphone")
        }
    }

    private var endButton: some View {
        Button {
            if let live = presentation.liveModel {
                live.end()
                onEnded()
            } else {
                Task { if await presentation.model.end() { onEnded() } }
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .background(Circle().fill(theme.danger))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("End voice")
        .accessibilityIdentifier("simple-bots.voice.end")
    }

    private func circle(_ systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
            .background(Circle().fill(theme.incomingMessageBackground))
            .contentShape(.circle)
    }

    /// Several readings a second of the real levels: the microphone's and the voice playing back.
    private func sampleLevels() async {
        while !Task.isCancelled {
            let input: Double
            let output: Double
            if let live = presentation.liveModel {
                await live.refreshLevels()
                input = live.isMuted ? 0 : live.inputLevel
                output = live.outputLevel
            } else {
                input = presentation.model.isMicrophoneMuted ? 0 : Double(presentation.model.inputLevel)
                output = presentation.model.outputLevel
            }
            let next = SimpleBotVoiceVisualizer.next(levels: levels, input: input, output: output)
            levels = next.levels
            speaker = next.speaker
            try? await Task.sleep(for: .milliseconds(120))
        }
    }
}

/// Bars from the newest levels (oldest on the left), or a row of dots while nobody speaks.
struct SimpleBotVoiceVisualizer: View {
    enum Speaker: Equatable { case nobody, person, agent }
    static let barCount = 26
    /// Below this, a reading is room noise, not speech.
    static let quiet = 0.04

    let levels: [Double]
    let speaker: Speaker
    let agentColor: Color
    @BighelpThemeReader private var theme

    /// The levels after one more reading: who's speaking, and their loudness, slightly boosted so quiet
    /// speech still shows.
    static func next(levels: [Double], input: Double, output: Double) -> (levels: [Double], speaker: Speaker) {
        let speaker: Speaker = max(input, output) < quiet ? .nobody : output >= input ? .agent : .person
        let level = speaker == .nobody ? 0 : min(1, sqrt(max(input, output)) * 1.2)
        return (Array((levels + [level]).suffix(barCount)), speaker)
    }

    var body: some View {
        let color = speaker == .person ? theme.primaryText : agentColor
        GeometryReader { proxy in
            let step = proxy.size.width / CGFloat(Self.barCount)
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Group {
                        if speaker == .nobody || level < Self.quiet {
                            Circle().fill(color.opacity(0.45)).frame(width: 4, height: 4)
                        } else {
                            Capsule().fill(color)
                                .frame(width: max(3, step * 0.45), height: max(6, proxy.size.height * level))
                        }
                    }
                    .frame(width: step, height: proxy.size.height)
                }
            }
            .animation(.easeOut(duration: 0.12), value: levels)
        }
    }
}

/// What turn-based voice needs while it's on screen, as its full-screen view does it: microphone and
/// speech permission, and listening only while the app is in front and the microphone is on.
private struct SimpleBotVoiceTurnLifecycle: ViewModifier {
    let model: VoiceModel?
    let permissionCenter: PermissionCenter
    @State private var isVisible = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard let model else { return }
                isVisible = true
                model.setReduceMotion(reduceMotion)
                reconcile(model)
            }
            .task {
                guard let model else { return }
                guard await permissionCenter.authorizeContextualAccess(.microphone),
                      await permissionCenter.authorizeContextualAccess(.speech) || model.transcription == .hermes
                else { model.stopMonitoring(); return }
                reconcile(model)
            }
            .onDisappear {
                isVisible = false
                model?.setMonitoringAllowed(false)
                model?.cancelWalkieTalkieCapture()
                model?.stopMonitoring()
            }
            .onChange(of: scenePhase) { _, phase in
                guard let model else { return }
                if phase != .active { model.cancelWalkieTalkieCapture() }
                reconcile(model)
            }
            .onChange(of: model?.status) { _, _ in if let model { reconcile(model) } }
            .onChange(of: model?.isMicrophoneMuted) { _, _ in if let model { reconcile(model) } }
    }

    private func reconcile(_ model: VoiceModel) {
        let authorized = permissionCenter.status(for: .microphone).authorization == .authorized
            && (model.transcription == .hermes || permissionCenter.status(for: .speech).authorization == .authorized)
        let allowed = isVisible && scenePhase == .active && authorized
        model.setMonitoringAllowed(allowed)
        guard allowed, model.isActive, !model.isMicrophoneMuted, model.allowsInputMonitoring else {
            model.stopMonitoring()
            return
        }
        Task { await model.startMonitoring() }
    }
}
