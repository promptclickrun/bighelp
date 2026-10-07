import SwiftUI

/// Native live voice keeps configuration in Settings. This surface owns only
/// the explicit media lifecycle and the two local audio mute controls.
struct LiveVoiceView: View {
    @State private var model: LiveVoiceModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let agentID: String?
    let agentImageURL: URL?
    let onEnded: () -> Void
    /// Switches Settings to turn-based voice (listens on the phone, answers
    /// with the host's text-to-speech) and reopens voice. Offered only after
    /// live voice fails.
    let onUseTurnBased: (() -> Void)?
    /// The chat's live work (a running tool, thinking), for the avatar's moves.
    var chatActivity: () -> AgentActivityKind = { .idle }
    /// The step the agent is on while it works for the call, in plain words.
    var chatStep: () -> String? = { nil }

    init(
        model: LiveVoiceModel,
        agentID: String? = nil,
        agentImageURL: URL? = nil,
        onEnded: @escaping () -> Void = {},
        onUseTurnBased: (() -> Void)? = nil,
        chatActivity: @escaping () -> AgentActivityKind = { .idle },
        chatStep: @escaping () -> String? = { nil }
    ) {
        _model = State(initialValue: model)
        self.chatActivity = chatActivity
        self.chatStep = chatStep
        self.agentID = agentID
        self.agentImageURL = agentImageURL
        self.onEnded = onEnded
        self.onUseTurnBased = onUseTurnBased
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: BighelpTokens.space24) {
                        Text(model.phase.title)
                            .bighelpFont(.metadata, weight: .semibold)
                            .foregroundStyle(theme.secondaryText)
                            .accessibilityIdentifier("live-voice.status")
                        Spacer(minLength: BighelpTokens.space16)
                        AgentLiveAvatar(
                            agentID: agentID ?? model.agentName,
                            displayName: model.agentName,
                            imageURL: agentImageURL,
                            activity: avatarActivity,
                            size: dynamicTypeSize.isAccessibilitySize ? 140 : 200,
                            showsBadge: false,
                            restingState: liveState
                        )
                        .accessibilityHidden(true)
                        Text(captionText)
                            .bighelpFont(.screenTitle, weight: .semibold)
                            .tracking(-0.2)
                            .foregroundStyle(hasCaption ? theme.primaryText : theme.secondaryText)
                            .multilineTextAlignment(.center)
                            .lineLimit(6)
                            .truncationMode(.head)
                            .frame(maxWidth: 520)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.workStatus == .resultSent {
                            Label(model.workStatus.title, systemImage: model.workStatus.systemImage)
                                .bighelpFont(.label, weight: .semibold)
                                .foregroundStyle(theme.secondaryText)
                        } else {
                            // While Hermes works for the call: its step, else that it's working.
                            VoiceStepLine(step: { [model, chatStep] in
                                model.workStatus == .working ? chatStep() ?? model.workStatus.title : nil
                            })
                        }
                        messages
                        Spacer(minLength: BighelpTokens.space16)
                        Text("Stopping voice does not cancel work Hermes already accepted.")
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.tertiaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, BighelpTokens.space20)
                    .padding(.vertical, BighelpTokens.space12)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            controls
                .frame(maxWidth: 560)
                .padding(.horizontal, BighelpTokens.space16)
                .padding(.top, BighelpTokens.space8)
                .padding(.bottom, BighelpTokens.space16)
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(theme.primaryText)
        .tint(theme.action)
        .background { VoiceStageBackground(agentColor: AgentPersona(stableID: agentID ?? model.agentName).color) }
        .navigationTitle("Live voice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    model.end()
                    onEnded()
                }
                .keyboardShortcut(.cancelAction)
                .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                .accessibilityHint("Stops live audio. Accepted tasks are not cancelled.")
                .accessibilityIdentifier("live-voice.close")
                    .bighelpToolbarText()
            }
            ToolbarItem(placement: .principal) {
                statusPill
            }
        }
        .onDisappear { model.end() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.end() }
        }
        // Contain, so the controls keep their own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live-voice.screen")
    }

    /// "● Agent · state" — the same pill as turn-based voice.
    private var statusPill: some View {
        HStack(spacing: BighelpTokens.space8) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)
            Text("\(model.agentName) · \(statusText)")
                .bighelpFont(.label, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(theme.primaryText)
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space8)
        .background(theme.surface.opacity(theme.isDarkPalette ? 0.72 : 0.6), in: .capsule)
        .overlay { Capsule().stroke(theme.border, lineWidth: BighelpTokens.hairline) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.agentName), \(statusText)")
        .accessibilityAddTraits(.isHeader)
    }

    /// Derived only from live-call facts: delegated Hermes work, streaming
    /// assistant speech, or an open microphone.
    private var avatarActivity: AgentActivityKind {
        guard model.phase == .live else { return .idle }
        let working = model.workStatus == .working
        return VoiceAvatarActivity.resolve(isSpeaking: !working && !model.assistantCaption.isEmpty,
                                           isWorking: working, chatActivity: chatActivity())
    }

    private var liveState: AgentLiveState {
        guard model.phase == .live else { return .idle }
        if model.workStatus == .working { return .thinking }
        if !model.assistantCaption.isEmpty { return .speaking }
        return model.isMuted ? .idle : .listening
    }

    private var statusText: String {
        model.phase == .live ? liveState.label : model.phase.title
    }

    private var statusDotColor: Color {
        switch model.phase {
        case .live: liveState.dotColor
        case .failed: theme.danger
        case .interrupted, .preparing, .connecting: theme.warning
        case .idle, .ended: AgentLiveState.idle.dotColor
        }
    }

    private var captionText: String {
        if !model.assistantCaption.isEmpty { return model.assistantCaption }
        if !model.userCaption.isEmpty { return model.userCaption }
        if let last = model.transcripts.last { return last.text }
        if model.isCallOpen { return "Start speaking when you’re ready" }
        if model.phase == .failed { return "Live voice didn’t connect" }
        return BighelpPlatform.isMac ? "Click Start to talk live" : "Tap Start to talk live"
    }

    private var hasCaption: Bool {
        !model.assistantCaption.isEmpty || !model.userCaption.isEmpty || !model.transcripts.isEmpty
    }

    @ViewBuilder
    private var controls: some View {
        if model.isCallOpen {
            HStack(alignment: .center, spacing: BighelpTokens.space20) {
                audioButton(
                    title: model.isMuted ? "Unmute microphone" : "Mute microphone",
                    systemImage: model.isMuted ? "mic.slash.fill" : "mic.fill",
                    isSelected: model.isMuted,
                    identifier: "live-voice.mute"
                ) { model.setMuted(!model.isMuted) }
                    .disabled(!model.canControlAudio)

                Button(role: .destructive) { model.end() } label: {
                    HStack(spacing: BighelpTokens.space8) {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .accessibilityHidden(true)
                        Text("End")
                            .bighelpFont(.body, weight: .semibold)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, BighelpTokens.space24)
                    .frame(minWidth: 112, minHeight: 64)
                    .background(Color(hex: "D33F42"), in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop live voice")
                .accessibilityHint("Stops microphone and playback. Accepted tasks continue independently.")
                .accessibilityIdentifier("live-voice.end")

                audioButton(
                    title: model.isSpeakerMuted ? "Unmute speaker" : "Mute speaker",
                    systemImage: model.isSpeakerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    isSelected: model.isSpeakerMuted,
                    identifier: "live-voice.speaker"
                ) { model.setSpeakerMuted(!model.isSpeakerMuted) }
                    .disabled(!model.canControlAudio)
            }
        } else {
            VStack(spacing: BighelpTokens.space12) {
                Button { model.start() } label: {
                    Label(model.phase == .failed ? "Try again" : "Start live voice",
                          systemImage: model.phase == .failed ? "arrow.clockwise" : "waveform")
                        .bighelpFont(.body, weight: .semibold)
                        .foregroundStyle(theme.actionForeground)
                        .padding(.horizontal, BighelpTokens.space24)
                        .frame(maxWidth: 320, minHeight: 56)
                        .background(theme.action, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .opacity(model.canStart ? 1 : 0.5)
                .disabled(!model.canStart)
                .accessibilityIdentifier("live-voice.start")
                if model.phase == .failed, let onUseTurnBased {
                    Button("Use TTS voice mode", action: onUseTurnBased)
                        .bighelpFont(.body, weight: .semibold)
                        .foregroundStyle(theme.action)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .accessibilityHint("Listens on this phone and answers in the voice set up on your computer. You can switch back in Settings › Voice.")
                        .accessibilityIdentifier("live-voice.use-turn-based")
                }
            }
        }
    }

    private func audioButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isSelected ? theme.actionForeground : theme.primaryText)
                .frame(width: 64, height: 64)
                .background(isSelected ? theme.action : theme.surface, in: .circle)
                .overlay {
                    Circle().stroke(isSelected ? theme.action : theme.border, lineWidth: BighelpTokens.hairline)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Muted" : "On")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var messages: some View {
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(theme.danger)
                .bighelpFont(.label)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("live-voice.error")
        }
        if let cleanup = model.cleanupMessage {
            Text(cleanup)
                .foregroundStyle(theme.secondaryText)
                .bighelpFont(.metadata)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @BighelpThemeReader private var theme
}
