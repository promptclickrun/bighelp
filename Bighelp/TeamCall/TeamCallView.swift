import SwiftUI

/// Starts a team call from a group chat's header.
struct TeamCallAction {
    let start: @MainActor () -> Void
}

extension EnvironmentValues {
    @Entry var teamCallAction: TeamCallAction? = nil
}

/// The call button under a group chat's name. It sits in the middle column
/// because the header's corners already hold Back, New chat and ⋯.
struct TeamCallHeaderButton: View {
    let action: TeamCallAction
    @BighelpThemeReader private var theme

    var body: some View {
        Button { action.start() } label: {
            Label("Team call", systemImage: "phone.fill")
                .bighelpFont(.label, weight: .semibold)
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, BighelpTokens.space12)
                .frame(minHeight: 34)
                .contentShape(.capsule)
                .bighelpNavigationGlass(in: Capsule(), isInteractive: true)
                .padding(.vertical, 5)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Team call")
        .accessibilityHint("Starts a voice call with everyone in this group.")
        .help("Team call")
        .accessibilityIdentifier("chat.team-call")
    }
}

/// Offers the call on a group chat whose host can speak for every member, and
/// presents it full screen.
struct TeamCallEntry: ViewModifier {
    let chat: ChatModel
    let rooms: BotModeRoomStore
    let services: (any TeamCallServices)?
    let agents: AgentDirectoryStore
    let userIdentity: UserIdentityStore
    let transcription: VoiceTranscriptionSource
    let permissionCenter: PermissionCenter
    @State private var call: TeamCallModel?

    func body(content: Content) -> some View {
        content
            .environment(\.teamCallAction, action)
            .bighelpFullScreenCover(item: $call) { call in
                TeamCallView(
                    model: call,
                    permissionCenter: services?.usesDeviceMicrophone == false ? nil : permissionCenter
                )
                .interactiveDismissDisabled()
            }
    }

    private var participants: [HermesBotModeParticipant] {
        chat.nativeRoomParticipants.filter { $0.availability == .available }
    }

    private var action: TeamCallAction? {
        guard let services, chat.canInteractWithBotMode, chat.botModeRoomID != nil,
              participants.count >= 2,
              services.supportsVoice(profileIDs: participants.map(\.profileID)) else { return nil }
        return TeamCallAction { start(services) }
    }

    private func start(_ services: any TeamCallServices) {
        guard call == nil, let roomID = chat.botModeRoomID else { return }
        let members = participants.map { participant in
            TeamCallModel.Member(
                id: participant.memberID, profileID: participant.profileID, name: participant.displayName,
                imageURL: participant.profile.flatMap { agents.avatarURL(for: $0) }
            )
        }
        var profileIDs: [String] = []
        for member in members where !profileIDs.contains(member.profileID) { profileIDs.append(member.profileID) }
        let permissionCenter = permissionCenter
        let usesDeviceMicrophone = services.usesDeviceMicrophone
        call = TeamCallModel(
            title: chat.botModeRoomTitle,
            members: members,
            userName: "You",
            userAvatar: (userIdentity.identity.displayName.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "You" : userIdentity.identity.displayName, userIdentity.avatarURL()),
            link: BotModeTeamCallRoomLink(
                store: rooms, roomID: roomID,
                senderSnapshot: { [weak chat] in chat?.currentUserSnapshot },
                activitySink: { [weak chat] activity in chat?.acceptBotModeActivity(activity) }
            ),
            voice: { services.makeVoice(profileID: $0) },
            player: services.makePlayer(),
            input: services.makeInput(),
            transcription: transcription,
            // Hermes turns your words into text with the room's first member's
            // speech-to-text, like a Bot chat uses the active profile's.
            hostTranscriber: profileIDs.first.flatMap { services.makeTranscriber(profileID: $0) },
            deviceRecognizerAvailable: {
                !usesDeviceMicrophone || permissionCenter.status(for: .speech).authorization == .authorized
            },
            loadSettings: { await services.loadSettings(profileIDs: profileIDs) },
            onEnded: { call = nil }
        )
    }
}

/// A voice call with the whole group: everyone's avatar, the one talking lit
/// up, what's being said, and Mute and End.
struct TeamCallView: View {
    let model: TeamCallModel
    /// Nil when the microphone is simulated (demo).
    let permissionCenter: PermissionCenter?
    @State private var isVisible = false
    @ScaledMetric(relativeTo: .title2) private var captionSize: CGFloat = 24
    @BighelpThemeReader private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: BighelpTokens.space24) {
                        grid
                        caption
                        notices
                    }
                    .padding(.horizontal, BighelpTokens.space20)
                    .padding(.vertical, BighelpTokens.space16)
                    .frame(minHeight: proxy.size.height)
                    .bighelpShellContentWidth()
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            controls
                .padding(.horizontal, BighelpTokens.space16)
                .padding(.top, BighelpTokens.space8)
                .padding(.bottom, BighelpTokens.space16)
        }
        .background { VoiceStageBackground(agentColor: stageColor) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("team-call.screen")
        .onAppear {
            isVisible = true
            model.start()
            reconcileMicrophone()
        }
        .task { await authorize() }
        .onDisappear {
            isVisible = false
            model.end()
        }
        .onChange(of: scenePhase) { _, _ in reconcileMicrophone() }
        .onChange(of: permissionCenter?.status(for: .microphone).authorization) { _, _ in
            model.retryMicrophone()
            reconcileMicrophone()
        }
        .onChange(of: permissionCenter?.status(for: .speech).authorization) { _, _ in
            model.retryMicrophone()
            reconcileMicrophone()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: BighelpTokens.space8) {
            Text(model.title)
                .bighelpFont(.label, weight: .semibold)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
            HStack(spacing: BighelpTokens.space8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(model.statusText)
                    .bighelpFont(.label, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.vertical, VoiceViewPresentation.statusVerticalPadding)
            .background(theme.surface.opacity(theme.isDarkPalette ? 0.72 : 0.6), in: .capsule)
            .overlay { Capsule().stroke(theme.border, lineWidth: BighelpTokens.hairline) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.statusText)
            .accessibilityIdentifier("team-call.status")
        }
        .padding(.top, BighelpTokens.space12)
        .padding(.horizontal, BighelpTokens.space16)
    }

    private var statusColor: Color {
        switch model.activity {
        case .speaking: AgentLiveState.speaking.dotColor
        case .thinking, .sending, .transcribing: AgentLiveState.thinking.dotColor
        case .listening, .hearingYou, .connecting: AgentLiveState.listening.dotColor
        case .muted, .ended: AgentLiveState.idle.dotColor
        }
    }

    private var stageColor: Color {
        AgentPersona(stableID: model.speakingMemberID ?? model.members.first?.id ?? "team").color
    }

    // MARK: Grid

    private var tileCount: Int { model.members.count + 1 }

    private var avatarSize: CGFloat {
        let base: CGFloat = tileCount <= 4 ? 104 : 80
        return dynamicTypeSize.isAccessibilitySize ? base * 0.8 : base
    }

    private var grid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: BighelpTokens.space16),
                           count: tileCount <= 4 ? 2 : 3),
            spacing: BighelpTokens.space20
        ) {
            ForEach(model.members) { member in
                memberTile(member)
            }
            youTile
        }
        .frame(maxWidth: 520)
    }

    private func memberTile(_ member: TeamCallModel.Member) -> some View {
        let isSpeaking = model.speakingMemberID == member.id
        // The room's header and messages draw members by member ID; match them.
        return tile(
            stableID: member.id, name: member.name, imageURL: member.imageURL, kind: .agent,
            state: isSpeaking ? .speaking : (model.activity == .thinking ? .thinking : .listening),
            isLit: isSpeaking, level: isSpeaking ? model.outputLevel : 0,
            ringColor: AgentPersona(stableID: member.id).color,
            detail: isSpeaking ? "Talking" : nil
        )
        .accessibilityLabel(isSpeaking ? "\(member.name), talking" : member.name)
        .accessibilityIdentifier("team-call.member.\(member.profileID)")
        .accessibilityAddTraits(isSpeaking ? .isSelected : [])
    }

    private var youTile: some View {
        let isTalking = model.activity == .hearingYou
        return tile(
            stableID: UserIdentity.stableID, name: model.userName, avatarName: model.userAvatar.name,
            imageURL: model.userAvatar.imageURL, kind: .person, state: nil,
            isLit: isTalking, level: isTalking ? Double(model.inputLevel) : 0,
            ringColor: theme.action,
            detail: model.isMicrophoneMuted ? "Muted" : nil
        )
        .accessibilityLabel(model.isMicrophoneMuted ? "You, muted" : isTalking ? "You, talking" : "You")
        .accessibilityIdentifier("team-call.you")
    }

    private func tile(
        stableID: String, name: String, avatarName: String? = nil, imageURL: URL?, kind: AvatarView.Kind,
        state: AgentLiveState?, isLit: Bool, level: Double, ringColor: Color, detail: String?
    ) -> some View {
        let ring = avatarSize + 12 + (reduceMotion ? 0 : CGFloat(min(max(level, 0), 1)) * 16)
        return VStack(spacing: BighelpTokens.space8) {
            ZStack {
                Circle()
                    .stroke(ringColor.opacity(isLit ? 0.9 : 0), lineWidth: 4)
                    .frame(width: ring, height: ring)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: ring)
                AvatarView(stableID: stableID, displayName: avatarName ?? name, imageURL: imageURL,
                           size: avatarSize, kind: kind, state: state)
                    .opacity(isLit || model.speakingMemberID == nil ? 1 : 0.72)
            }
            .frame(width: avatarSize + 30, height: avatarSize + 30)
            Text(name)
                .bighelpFont(.label, weight: isLit ? .semibold : .regular)
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail ?? " ")
                .bighelpFont(.metadata, weight: .semibold)
                .foregroundStyle(isLit ? ringColor : theme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
    }

    // MARK: Caption

    private var caption: some View {
        VStack(spacing: BighelpTokens.space8) {
            if let line = model.caption {
                Text(line.speaker)
                    .bighelpFont(.label, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                Text(line.text)
                    .font(.system(size: captionSize, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Say something to the group")
                    .font(.system(size: captionSize, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                if let stopHint = model.stopHint {
                    Text(stopHint)
                        .bighelpFont(.label)
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, BighelpTokens.space12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("team-call.caption")
    }

    @ViewBuilder
    private var notices: some View {
        if let message = model.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .bighelpFont(.body, weight: .semibold)
                .foregroundStyle(theme.danger)
                .frame(maxWidth: 520, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("team-call.error")
        }
        if let permissionCenter {
            let microphone = permissionCenter.status(for: .microphone).authorization
            let speech = permissionCenter.status(for: .speech).authorization
            if microphone == .denied || microphone == .restricted {
                ContextualPermissionRecoveryView(center: permissionCenter, kind: .microphone)
            } else if model.transcriptionNeedsDeviceSpeech, speech == .denied || speech == .restricted {
                ContextualPermissionRecoveryView(center: permissionCenter, kind: .speech)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: BighelpTokens.space20) {
            Button(action: model.toggleMicrophone) {
                Image(systemName: model.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(model.isMicrophoneMuted ? theme.actionForeground : theme.primaryText)
                    .frame(width: VoiceViewPresentation.controlMinimumHeight,
                           height: VoiceViewPresentation.controlMinimumHeight)
                    .background(model.isMicrophoneMuted ? theme.action : theme.surface, in: .circle)
                    .overlay {
                        Circle().stroke(model.isMicrophoneMuted ? theme.action : theme.border,
                                        lineWidth: BighelpTokens.hairline)
                    }
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isMicrophoneMuted ? "Unmute" : "Mute")
            .accessibilityValue(model.isMicrophoneMuted ? "Muted" : "On")
            .accessibilityIdentifier("team-call.mute")

            Button(role: .destructive, action: model.end) {
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
                .frame(minWidth: 112, minHeight: VoiceViewPresentation.controlMinimumHeight)
                .background(Color(hex: "D33F42"), in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("End team call")
            .accessibilityHint("Hangs up. Messages already sent keep going in the chat.")
            .accessibilityIdentifier("team-call.end")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Microphone

    private func reconcileMicrophone() {
        model.setMicrophoneAllowed(isVisible && scenePhase == .active && inputAuthorized)
    }

    private var inputAuthorized: Bool {
        guard let permissionCenter else { return true }
        return permissionCenter.status(for: .microphone).authorization == .authorized
            && (!model.transcriptionNeedsDeviceSpeech
                || permissionCenter.status(for: .speech).authorization == .authorized)
    }

    private func authorize() async {
        guard let permissionCenter else { return reconcileMicrophone() }
        guard await permissionCenter.authorizeContextualAccess(.microphone) else { return reconcileMicrophone() }
        // Hermes transcribes your turns itself; on this device speech
        // recognition is still what hears you cut in.
        _ = await permissionCenter.authorizeContextualAccess(.speech)
        reconcileMicrophone()
    }
}
