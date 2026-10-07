import SwiftUI

struct VoiceView: View {
    @Environment(\.companionStore) private var companionStore
    @Environment(\.companionAgentScope) private var companionAgentScope
    @State private var model: VoiceModel
    @State private var isVoiceVisible = false
    @GestureState private var walkieGestureActive = false
    @State private var walkieGestureGeneration: UInt64?
    @State private var isTranscriptExpanded = false
    #if targetEnvironment(macCatalyst)
    @State private var lastSpacePress = Date.distantPast
    #endif
    let agentID: String?
    let agentImageURL: URL?
    let transcriptRows: [VoiceTranscriptRow]?
    let permissionCenter: PermissionCenter?
    let onEnded: () -> Void
    let onWorkspaceTap: () -> Void
    /// The chat's live work (a running tool, thinking), for the avatar's moves.
    var chatActivity: () -> AgentActivityKind = { .idle }
    /// The step the agent is on, in plain words, for the line under the bars.
    var chatStep: () -> String? = { nil }

    init(
        model: VoiceModel,
        agentID: String? = nil,
        agentImageURL: URL? = nil,
        transcriptRows: [VoiceTranscriptRow]? = nil,
        showsTranscript: Bool = false,
        permissionCenter: PermissionCenter? = nil,
        onEnded: @escaping () -> Void = {},
        onWorkspaceTap: @escaping () -> Void = {},
        chatActivity: @escaping () -> AgentActivityKind = { .idle },
        chatStep: @escaping () -> String? = { nil }
    ) {
        _model = State(initialValue: model)
        self.chatActivity = chatActivity
        self.chatStep = chatStep
        self.agentID = agentID
        self.agentImageURL = agentImageURL
        self.transcriptRows = transcriptRows
        _isTranscriptExpanded = State(initialValue: showsTranscript)
        self.permissionCenter = permissionCenter
        self.onEnded = onEnded
        self.onWorkspaceTap = onWorkspaceTap
    }

    var body: some View {
        voiceLayout
        .background { VoiceStageBackground(agentColor: agentPersona.color) }
        // Contain, so the controls keep their own identifiers (and VoiceOver reaches each).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice.screen")
        .onAppear {
            isVoiceVisible = true
            model.setReduceMotion(reduceMotion)
            reconcileMonitoring(for: scenePhase)
        }
        .task { await authorizeVoiceInput() }
        .onDisappear {
            isVoiceVisible = false
            walkieGestureGeneration = nil
            model.setMonitoringAllowed(false)
            model.cancelWalkieTalkieCapture()
            model.stopMonitoring()
        }
        .onChange(of: model.status) { _, _ in
            reconcileMonitoring(for: scenePhase)
        }
        .onChange(of: model.isMicrophoneMuted) { _, _ in
            reconcileMonitoring(for: scenePhase)
        }
        .onChange(of: model.meterState) { _, state in
            guard state == .unavailable, let permissionCenter else { return }
            Task {
                await permissionCenter.refresh(.microphone)
                await permissionCenter.refresh(.speech)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                model.cancelWalkieTalkieCapture()
            }
            reconcileMonitoring(for: phase)
        }
        .onChange(of: permissionCenter?.status(for: .microphone).authorization) { _, _ in
            reconcileMonitoring(for: scenePhase)
        }
        .onChange(of: permissionCenter?.status(for: .speech).authorization) { _, _ in
            reconcileMonitoring(for: scenePhase)
        }
        .onChange(of: reduceMotion) { _, enabled in
            model.setReduceMotion(enabled)
            reconcileMonitoring(for: scenePhase)
        }

    }

    private var voiceLayout: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: BighelpTokens.space8) {
                WorkspaceMenuButton(accessibilityIdentifier: "voice.workspace-menu", action: onWorkspaceTap)
                authoritativeStatus
                    .frame(maxWidth: .infinity)
                // Balances the menu button so the status pill stays centered.
                Color.clear.frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.vertical, BighelpTokens.space8)
            .bighelpShellContentWidth()
            GeometryReader { proxy in
                // The face and its voice together, then the words: what the agent is
                // doing, and what's being said, in full. Only the words scroll.
                VStack(spacing: BighelpTokens.space16) {
                    VStack(spacing: BighelpTokens.space16) {
                        orb(size: stageAvatarSize(height: proxy.size.height))
                        VoiceWaveformBars(level: waveformLevel, color: agentPersona.color)
                    }
                    .padding(.top, BighelpTokens.space16)
                    VoiceStepLine(step: chatStep)
                    words
                    sendNowControl
                    endFailure
                    permissionRecovery
                    transcriptToggle
                }
                .padding(.horizontal, BighelpTokens.space20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .bighelpShellContentWidth()
            }
            controls
                .frame(maxWidth: 620)
                .padding(.horizontal, BighelpTokens.space16)
                .padding(.top, BighelpTokens.space8)
                .padding(.bottom, BighelpTokens.space16)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("voice.controls")
        }
    }

    /// The avatar owns the stage, but leaves the words room to read: a short screen
    /// or large accessibility text gets a smaller face.
    private func stageAvatarSize(height: CGFloat) -> CGFloat {
        let largest: CGFloat = dynamicTypeSize.isAccessibilitySize ? 140 : 200
        // The bars, the step line, the transcript button, spacing, and about five lines of words.
        return min(largest, max(88, height - 360))
    }

    /// What's being said, in full, scrolling when it's long (no scroll bar). A new reply
    /// starts at its top, so you can read along as it's spoken; words still coming in
    /// keep their newest line in view. With Transcript open, the whole conversation.
    private var words: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: BighelpTokens.space8).id(Self.wordsTop)
                    if isTranscriptExpanded { transcriptRowsList } else { caption }
                    Color.clear.frame(height: BighelpTokens.space8).id(Self.wordsBottom)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.05),
                                       .init(color: .black, location: 0.93), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: model.liveAgentTranscript) { _, draft in
                guard draft?.isEmpty == false, !isTranscriptExpanded else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { reader.scrollTo(Self.wordsBottom, anchor: .bottom) }
            }
            .onChange(of: displayedTranscriptRows.last?.id) { _, _ in
                guard !isTranscriptExpanded else { return }
                reader.scrollTo(Self.wordsTop, anchor: .top)
            }
            .onChange(of: isTranscriptExpanded) { _, expanded in
                reader.scrollTo(expanded ? Self.wordsBottom : Self.wordsTop, anchor: expanded ? .bottom : .top)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice.words")
    }

    private static let wordsTop = "voice.words.top"
    private static let wordsBottom = "voice.words.bottom"

    /// A long reply reads better left-aligned at body size, like a message.
    private var captionIsLong: Bool { captionText.count > 160 }

    /// The one line that matters right now: what the agent is saying, else what
    /// you are saying, else the last finished turn, dimmed once it's said.
    private var caption: some View {
        Text(captionText)
            .bighelpFont(captionIsLong ? .sectionTitle : .screenTitle, weight: captionIsLong ? .medium : .semibold)
            .tracking(captionIsLong ? 0 : -0.2)
            .lineSpacing(captionIsLong ? 4 : 0)
            .foregroundStyle(captionIsLive ? theme.primaryText : theme.secondaryText)
            .multilineTextAlignment(captionIsLong ? .leading : .center)
            .frame(maxWidth: 520, alignment: captionIsLong ? .leading : .center)
            .padding(.horizontal, BighelpTokens.space12)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .textSelection(.enabled)
            .accessibilityIdentifier("voice.caption")
    }

    /// Hands-free voice waits for a real pause before sending; Send doesn't wait.
    @ViewBuilder
    private var sendNowControl: some View {
        if model.canSendNow {
            Button {
                model.sendNow()
            } label: {
                Label("Send now", systemImage: "arrow.up.circle.fill")
                    .bighelpFont(.label, weight: .semibold)
                    .padding(.horizontal, BighelpTokens.space16)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .background(Capsule().fill(theme.raisedSurface))
                    .overlay(Capsule().strokeBorder(theme.border, lineWidth: BighelpTokens.hairline))
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.primaryText)
            .accessibilityHint("Sends what you've said so far without waiting for a pause.")
            .accessibilityIdentifier("voice.send-now")
            .transition(.opacity)
        }
    }

    private var captionText: String {
        if let draft = model.liveAgentTranscript, !draft.isEmpty { return draft }
        if model.isTranscribing { return model.partialUserTranscript.map { $0 + " …" } ?? "Transcribing…" }
        if let partial = model.partialUserTranscript, !partial.isEmpty { return partial }
        if let last = displayedTranscriptRows.last { return last.text }
        return readyPrompt
    }

    /// Words being said right now, or the reply being spoken.
    private var captionIsLive: Bool {
        !(model.liveAgentTranscript ?? "").isEmpty
            || !(model.partialUserTranscript ?? "").isEmpty
            || model.isTranscribing
            || (model.status == .speaking && !displayedTranscriptRows.isEmpty)
    }

    /// Hands-free listens for you; walkie-talkie waits for the button.
    private var readyPrompt: String {
        guard model.mode == .walkieTalkie else { return "Start speaking when you’re ready" }
        return BighelpPlatform.isMac ? "Hold the mic or press Space to talk" : "Hold the mic to talk"
    }

    /// Bars follow real audio: playback while the agent speaks, otherwise the
    /// microphone meter. Muted or inactive sessions rest.
    private var waveformLevel: Double {
        guard model.isActive else { return 0 }
        if model.isPlaybackActive { return model.isAgentAudioMuted ? 0 : model.outputLevel }
        guard !model.isMicrophoneMuted, model.meterState == .monitoring else { return 0 }
        return VoiceWaveformBars.displayLevel(microphone: model.inputLevel)
    }

    private var agentPersona: AgentPersona {
        AgentPersona(stableID: agentID ?? model.agentName)
    }

    /// Voice status mapped onto the shared avatar vocabulary.
    private var avatarActivity: AgentActivityKind {
        guard model.isActive else { return .idle }
        return VoiceAvatarActivity.resolve(isSpeaking: model.status == .speaking,
                                           isWorking: model.status == .working, chatActivity: chatActivity())
    }

    private var liveState: AgentLiveState {
        switch model.status {
        case .listening: .listening
        case .working: .thinking
        case .speaking: .speaking
        case .paused, .unavailable: .idle
        }
    }

    private var statusText: String {
        switch model.status {
        case .listening, .working, .speaking: liveState.label
        case .paused, .unavailable: model.status.label
        }
    }

    private var transcriptToggle: some View {
        Button {
            isTranscriptExpanded.toggle()
        } label: {
            HStack(spacing: BighelpTokens.space8) {
                Text("Transcript")
                    .bighelpFont(.label, weight: .semibold)
                Spacer(minLength: BighelpTokens.space8)
                Image(systemName: "chevron.up")
                    .bighelpFont(.metadata, weight: .semibold)
                    .rotationEffect(.degrees(isTranscriptExpanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: 560, minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Transcript")
        .accessibilityValue(isTranscriptExpanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("voice.transcript.toggle")
    }

    /// The whole conversation, in the words area while Transcript is open.
    private var transcriptRowsList: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            if displayedTranscriptRows.isEmpty,
               model.partialUserTranscript == nil, model.liveAgentTranscript == nil {
                Text(readyPrompt)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
            }
            ForEach(displayedTranscriptRows) { row in
                transcriptCard(row)
            }
            if let partial = model.partialUserTranscript, !partial.isEmpty {
                transcriptCard(VoiceTranscriptRow(id: "voice-partial-user", speaker: "You", time: "Now", text: partial), isLive: true)
            }
            if let draft = model.liveAgentTranscript, !draft.isEmpty {
                transcriptCard(VoiceTranscriptRow(id: "voice-partial-agent", speaker: model.agentName, time: "Now", text: draft), isLive: true)
            }
            Label("Choose your speaking mode in Voice settings.", systemImage: "slider.horizontal.3")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice.transcript")
    }

    @ViewBuilder
    private func orb(size: CGFloat) -> some View {
        if let companionStore, companionStore.isEnabled {
            let companionSide = size * CGFloat(min(1, companionStore.sizeScale))
            CompanionAvatar(
                appearance: voiceCompanionAppearance(from: companionStore),
                reaction: voiceCompanionReaction,
                isAnimating: isVoiceVisible && scenePhase == .active && model.isActive,
                audioLevel: model.isPlaybackActive ? model.outputLevel : 0,
                activityMood: avatarActivity == .replying ? nil : avatarActivity.moodID
            )
            .frame(width: companionSide, height: companionSide)
            .allowsHitTesting(false)
            .accessibilityIdentifier("companion-voice")
            // The voice controls own a fixed safe slot; larger preferences stop
            // at that slot instead of covering status text or the End button.
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity)
        } else {
            AgentLiveAvatar(
                agentID: agentID ?? model.agentName,
                displayName: model.agentName,
                imageURL: agentImageURL,
                activity: avatarActivity,
                size: size,
                showsBadge: false,
                restingState: liveState
            )
            .scaleEffect(avatarPulseScale)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: avatarPulseScale)
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity)
        }
    }

    private func voiceCompanionAppearance(from store: CompanionStore) -> CompanionAppearance {
        guard let agentID, !companionAgentScope.isEmpty else { return store.defaultAppearance }
        return store.appearance(
            for: CompanionStore.agentKey(agentScope: companionAgentScope, agentID: agentID)
        )
    }

    private var voiceCompanionReaction: CompanionReaction {
        CompanionVoiceSignal.reaction(
            status: model.status,
            playbackActive: model.isPlaybackActive,
            microphoneMonitoring: voiceInputIsAuthorized && !model.isMicrophoneMuted
                && model.meterState == .monitoring
        )
    }

    private func reconcileMonitoring(for phase: ScenePhase) {
        let allowed = isVoiceVisible && phase == .active && voiceInputIsAuthorized
        model.setMonitoringAllowed(allowed)
        guard allowed,
              model.isActive,
              !model.isMicrophoneMuted,
              model.allowsInputMonitoring,
              voiceInputIsAuthorized
        else {
            model.stopMonitoring()
            return
        }
        Task { await model.startMonitoring() }
    }

    private var voiceInputIsAuthorized: Bool {
        guard let permissionCenter else { return true }
        // Hermes transcribes the recording itself; on-device captions are optional then.
        return permissionCenter.status(for: .microphone).authorization == .authorized
            && (model.transcription == .hermes || permissionCenter.status(for: .speech).authorization == .authorized)
    }

    private func authorizeVoiceInput() async {
        guard let permissionCenter else {
            reconcileMonitoring(for: scenePhase)
            return
        }
        guard await permissionCenter.authorizeContextualAccess(.microphone) else {
            model.stopMonitoring()
            return
        }
        guard await permissionCenter.authorizeContextualAccess(.speech) || model.transcription == .hermes else {
            model.stopMonitoring()
            return
        }
        reconcileMonitoring(for: scenePhase)
    }

    private var authoritativeStatus: some View {
        HStack(spacing: BighelpTokens.space8) {
            Circle()
                .fill(statusIndicatorColor)
                .frame(width: 8, height: 8)
            Text("\(model.agentName) · \(statusText)")
                .bighelpFont(.label, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(theme.primaryText)
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, VoiceViewPresentation.statusVerticalPadding)
        .background(theme.surface.opacity(theme.isDarkPalette ? 0.72 : 0.6), in: .capsule)
        .overlay {
            Capsule()
                .stroke(theme.border, lineWidth: BighelpTokens.hairline)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.status.label)
        .accessibilityValue(model.status == .working ? "In progress" : "")
        .accessibilityIdentifier("voice.status")
    }

    private var statusIndicatorColor: Color {
        switch model.status {
        case .listening, .working, .speaking:
            liveState.dotColor
        case .paused:
            theme.warning
        case .unavailable:
            theme.danger
        }
    }

    /// A subtle, level-driven breath while the microphone hears you.
    private var avatarPulseScale: CGFloat {
        guard !reduceMotion, model.status == .listening, !model.isMicrophoneMuted else { return 1 }
        return 1 + CGFloat(min(max(model.inputLevel, 0), 1)) * 0.04
    }

    private var displayedTranscriptRows: [VoiceTranscriptRow] {
        transcriptRows ?? model.transcriptRows
    }

    private func transcriptCard(
        _ row: VoiceTranscriptRow,
        isLive: Bool = false
    ) -> some View {
        transcriptRowContent(row, isLive: isLive)
            .padding(.vertical, BighelpTokens.space12)
            .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.speaker), \(row.time), \(row.text)\(isLive ? ", live" : "")")
    }

    private func transcriptRowContent(_ row: VoiceTranscriptRow, isLive: Bool) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                Text(row.speaker)
                    .bighelpFont(.label)
                    .foregroundStyle(theme.primaryText)
                if isLive {
                    Text("Live")
                        .bighelpFont(.metadata, weight: .semibold)
                        .foregroundStyle(theme.action)
                }
                Spacer(minLength: BighelpTokens.space8)
                Text(row.time)
                    .bighelpFont(.metadata)
                    .monospacedDigit()
                    .foregroundStyle(theme.tertiaryText)
            }
            Text(row.text)
                .bighelpFont(.body)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var endFailure: some View {
        if let message = model.endErrorMessage ?? model.turnErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .bighelpFont(.body, weight: .semibold)
                .foregroundStyle(theme.danger)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                .padding(.horizontal, BighelpTokens.space4)
                .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var permissionRecovery: some View {
        if let permissionCenter {
            let microphone = permissionCenter.status(for: .microphone).authorization
            let speech = permissionCenter.status(for: .speech).authorization
            if microphone == .denied || microphone == .restricted {
                ContextualPermissionRecoveryView(center: permissionCenter, kind: .microphone)
            } else if speech == .denied || speech == .restricted {
                ContextualPermissionRecoveryView(center: permissionCenter, kind: .speech)
            }
        }
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: BighelpTokens.space20) {
            agentAudioControl
            endControl
            if model.mode == .walkieTalkie {
                walkieTalkieControl
            } else {
                microphoneControl
            }
        }
        .frame(maxWidth: .infinity)
        #if targetEnvironment(macCatalyst)
        .background { spaceToTalk }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// A Mac has the space bar for the Speak button: press it to start talking
    /// and again to send. Holding Space repeats the key, so a press that comes
    /// right after another is the key repeating, not a second press.
    @ViewBuilder private var spaceToTalk: some View {
        if model.mode == .walkieTalkie {
            Button("Speak") {
                let now = Date.now
                defer { lastSpacePress = now }
                guard now.timeIntervalSince(lastSpacePress) > 0.5 else { return }
                toggleAccessibleWalkieTalkieCapture()
            }
            .keyboardShortcut(.space, modifiers: [])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
    #endif

    private var agentAudioControl: some View {
        voiceControl(
            title: "Agent audio",
            actionName: model.isAgentAudioMuted ? "Unmute" : "Mute",
            systemImage: model.isAgentAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            isSelected: model.isAgentAudioMuted,
            accessibilityLabel: model.isAgentAudioMuted ? "Unmute agent audio" : "Mute agent audio",
            accessibilityValue: model.isAgentAudioMuted ? "Muted" : "Unmuted",
            action: model.toggleAgentAudio
        )
        .accessibilityIdentifier("voice.agent-audio")
    }

    private var microphoneControl: some View {
        voiceControl(
            title: "Microphone",
            actionName: model.isMicrophoneMuted ? "Unmute" : "Mute",
            systemImage: model.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill",
            isSelected: model.isMicrophoneMuted,
            accessibilityLabel: model.isMicrophoneMuted ? "Unmute microphone" : "Mute microphone",
            accessibilityValue: model.isMicrophoneMuted ? "Muted" : "Unmuted",
            action: model.toggleMicrophone
        )
        .accessibilityIdentifier("voice.microphone")
    }

    private var walkieTalkieControl: some View {
        voiceControlLabel(
            title: "Speak",
            actionName: model.isWalkieTalkieCapturing ? "Release" : "Hold",
            systemImage: model.isWalkieTalkieCapturing ? "waveform.circle.fill" : "mic.fill",
            isSelected: model.isWalkieTalkieCapturing
        )
        .contentShape(.rect)
        .disabled(
            model.isMicrophoneMuted
                || !model.isActive
                || !(model.status == .listening
                    || (model.status == .working && model.isAgentRunActive))
        )
        .gesture(walkieTalkieGesture)
        .onChange(of: walkieGestureActive) { wasActive, active in
            guard wasActive, !active, let generation = walkieGestureGeneration else { return }
            Task { @MainActor in
                await Task.yield()
                guard walkieGestureGeneration == generation else { return }
                walkieGestureGeneration = nil
                model.cancelWalkieTalkieCapture()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(model.isWalkieTalkieCapturing ? .isSelected : [])
        .accessibilityLabel(model.isWalkieTalkieCapturing ? "Send speech" : "Start speaking")
        .accessibilityValue(model.isWalkieTalkieCapturing ? "Recording" : "Ready")
        .accessibilityHint(
            model.isWalkieTalkieCapturing
                ? "Double tap to send this voice turn."
                : "Hold while speaking and release to send. With VoiceOver, double tap to start."
        )
        .accessibilityAction { toggleAccessibleWalkieTalkieCapture() }
        #if targetEnvironment(macCatalyst)
        .help("Hold while you speak, or press Space to start and Space again to send")
        #endif
        .accessibilityIdentifier("voice.walkie-talkie.speak")
    }

    private var walkieTalkieGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($walkieGestureActive) { _, active, _ in active = true }
            .onChanged { _ in
                guard !model.isWalkieTalkieCapturing else { return }
                guard let generation = model.armWalkieTalkieCapture() else { return }
                walkieGestureGeneration = generation
                Task {
                    _ = await model.startArmedWalkieTalkieCapture(generation: generation)
                }
            }
            .onEnded { value in
                walkieGestureGeneration = nil
                let distance = hypot(value.translation.width, value.translation.height)
                _ = model.endWalkieTalkieCapture(submit: distance <= 50)
            }
    }

    private func toggleAccessibleWalkieTalkieCapture() {
        if model.isWalkieTalkieCapturing {
            _ = model.endWalkieTalkieCapture(submit: true)
            return
        }
        guard let generation = model.armWalkieTalkieCapture() else { return }
        Task {
            _ = await model.startArmedWalkieTalkieCapture(generation: generation)
        }
    }

    private var endControl: some View {
        Button(role: .destructive) {
            Task {
                if await model.end() {
                    onEnded()
                }
            }
        } label: {
            HStack(spacing: BighelpTokens.space8) {
                if model.isEndPending {
                    BighelpThinkingOrb(
                        scenario: .working,
                        scale: .inline,
                        surface: theme.actionThinkingOrbSurface
                    )
                    .accessibilityHidden(true)
                } else {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(model.isEndPending ? "Ending…" : "End")
                    .bighelpFont(.body, weight: .semibold)
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, BighelpTokens.space24)
            .frame(minWidth: 112, minHeight: VoiceViewPresentation.controlMinimumHeight)
            .background(Self.endRed, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .opacity(model.isActive || model.isEndPending ? 1 : 0.5)
        .disabled(model.isEndPending || !model.isActive)
        .accessibilityLabel("End voice chat")
        .accessibilityValue(model.isEndPending ? "Ending" : model.endErrorMessage == nil ? "Ready" : "Failed. Double tap to retry")
        .accessibilityHint("Ends voice chat and returns to the chat canvas.")
        .accessibilityIdentifier("voice.end")
    }

    private static let endRed = Color(hex: "D33F42")

    private func voiceControl(
        title: String,
        actionName: String,
        systemImage: String,
        isSelected: Bool,
        accessibilityLabel: String,
        accessibilityValue: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            voiceControlLabel(
                title: title,
                actionName: actionName,
                systemImage: systemImage,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A 64pt circular control. `title`/`actionName` stay in the signature for
    /// the callers' VoiceOver copy; the circle itself is icon-only like the kit.
    private func voiceControlLabel(
        title: String,
        actionName: String,
        systemImage: String,
        isSelected: Bool
    ) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(isSelected ? theme.actionForeground : theme.primaryText)
            .frame(
                width: VoiceViewPresentation.controlMinimumHeight,
                height: VoiceViewPresentation.controlMinimumHeight
            )
            .background(isSelected ? theme.action : theme.surface, in: .circle)
            .overlay {
                Circle()
                    .stroke(isSelected ? theme.action : theme.border, lineWidth: BighelpTokens.hairline)
            }
            .contentShape(.circle)
    }

    @BighelpThemeReader private var theme

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

#Preview("Voice - Listening") {
    VoiceView(
        model: VoiceModel(
            conversationID: "preview-listening",
            client: VoiceFixtureClient(confirmationDelay: .zero)
        )
    )
}

#Preview("Voice - Unavailable, Landscape", traits: .landscapeLeft) {
    VoiceView(
        model: VoiceModel(
            conversationID: "preview-unavailable",
            status: .unavailable,
            client: VoiceFixtureClient(confirmationDelay: .zero)
        )
    )
    .dynamicTypeSize(.accessibility2)
}
