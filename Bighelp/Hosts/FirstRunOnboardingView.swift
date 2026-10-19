import SwiftUI

/// Production first-run flow for a device with no restored Hermes instances.
/// Theme choices write through SettingsStore immediately; host setup keeps its
/// existing authenticated, transactional Keychain-backed implementation.
@MainActor
struct FirstRunOnboardingView: View {
    let registry: BighelpHostRegistry
    @Bindable var settings: SettingsStore
    let onCompleted: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("loopdy.onboarding.first-run-v1.step")
    private var savedStepRawValue = 0
    @AppStorage(AIDataConsent.key) private var agreedToAIData = false
    @State private var isAskingAIConsent = false
    @State private var step: Step = .welcome
    @State private var connectionBackStep: Step = .welcome
    @State private var hostConnectionCommitted = false
    @State private var hostDraft = HostSetupDraft()

    @AppStorage(FirstRunOnboarding.afterConnectKey) private var isAfterConnect = false

    private enum Step: Int, CaseIterable {
        case welcome
        case appearance
        case host
        case plugin
        case notifications
        case mode

        var progressLabel: String {
            switch self {
            case .welcome: "Step 1 of 4 · Welcome"
            case .appearance: "Appearance · Optional"
            case .host: "Step 2 of 4 · Connect"
            case .plugin: "Step 3 of 4 · Plugin · Optional"
            case .notifications: "Step 3 of 4 · Notifications · Optional"
            case .mode: "Step 4 of 4 · Your mode"
            }
        }

        /// Where the progress bar is, out of four.
        var progress: Double {
            switch self {
            case .welcome, .appearance: 1
            case .host: 2
            case .plugin, .notifications: 3
            case .mode: 4
            }
        }

        var accessibilityValue: String {
            switch self {
            case .welcome: "welcome"
            case .appearance: "appearance"
            case .host: "connection"
            case .plugin: "plugin"
            case .notifications: "notifications"
            case .mode: "mode"
            }
        }

        var accessibilityTitle: String {
            switch self {
            case .welcome: "Welcome"
            case .appearance: "Appearance"
            case .host: "Connect"
            case .plugin: "Plugin"
            case .notifications: "Notifications"
            case .mode: "Mode"
            }
        }

        /// After Connect, the computer is set up; Back can't undo that.
        var allowsBack: Bool { [.appearance, .host, .mode].contains(self) }
        /// Steps a person can pass by: everything but connecting and choosing a mode.
        var allowsSkip: Bool { [.appearance, .plugin, .notifications].contains(self) }
    }

    var body: some View {
        VStack(spacing: 0) {
            progressHeader
            Divider().overlay(theme.border)
            content
        }
        .background(theme.canvas.ignoresSafeArea())
        .animation(reduceMotion ? nil : .easeInOut(duration: BighelpTokens.transitionDuration), value: step)
        .onAppear {
            restoreSavedProgress()
            hostConnectionCommitted = registry.onboardingHostID != nil
        }
        .onChange(of: step) { _, step in
            savedStepRawValue = step.rawValue
        }
        .onChange(of: registry.onboardingHostID) { _, hostID in
            hostConnectionCommitted = hostID != nil
            if hostID != nil, step != .host {
                move(to: .host)
            }
        }
        .bighelpSheet(isPresented: $isAskingAIConsent) {
            AIDataConsentSheet {
                agreedToAIData = true
                isAskingAIConsent = false
                move(to: .host)
            }
            .presentationDetents([.medium])
            .bighelpSheetSize(.compact)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.screen")
    }

    private var progressHeader: some View {
        HStack(spacing: BighelpTokens.space16) {
            Group {
                if step.allowsBack && !(step == .host && hostConnectionCommitted) {
                    Button {
                        moveBack()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                            .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("onboarding.back")
                } else {
                    Color.clear
                        .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        .accessibilityHidden(true)
                }
            }

            VStack(spacing: BighelpTokens.space8) {
                if step != .appearance {
                    ProgressView(value: step.progress, total: 4)
                        .tint(theme.action)
                        .frame(maxWidth: 180)
                        .accessibilityHidden(true)
                }

                Text(step.progressLabel)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(step == .appearance ? "Optional appearance settings" : "Onboarding step")
            .accessibilityValue(step.accessibilityValue)
            .accessibilityIdentifier("onboarding.step")

            Group {
                if step.allowsSkip {
                    Button("Skip", action: skip)
                        .bighelpFont(.label)
                        .foregroundStyle(theme.secondaryText)
                        .buttonStyle(.plain)
                        .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                        .accessibilityIdentifier("onboarding.skip")
                } else {
                    Color.clear
                        .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space8)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            welcomeStep
                .transition(stepTransition)
        case .appearance:
            appearanceStep
                .transition(stepTransition)
        case .host:
            HostSetupView(
                registry: registry,
                allowsDismiss: false,
                firstRunPresentation: true,
                completionActionTitle: "Continue",
                showsNotificationSetup: false,
                retainedDraft: $hostDraft,
                onConnectionCommitted: { _ in
                    hostConnectionCommitted = true
                },
                onFinished: {
                    isAfterConnect = true
                    move(to: .plugin)
                }
            )
            .transition(stepTransition)
            .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.connection")
        case .plugin:
            // An install still running after Skip must not pull the person back.
            FirstRunPluginStep(registry: registry,
                               onInstalled: { if step == .plugin { move(to: .notifications) } },
                               onSkip: { if step == .plugin { move(to: .mode) } })
                .transition(stepTransition)
        case .notifications:
            FirstRunNotificationsStep(registry: registry, onDone: { if step == .notifications { move(to: .mode) } })
                .transition(stepTransition)
        case .mode:
            FirstRunModeStep(settings: settings, onChoose: completeOnboarding)
                .transition(stepTransition)
        }
    }

    private var welcomeStep: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(spacing: BighelpTokens.space32) {
                Spacer(minLength: BighelpTokens.space16)
                FirstRunCompanionConstellation()
                    .frame(maxWidth: 520)

                VStack(spacing: BighelpTokens.space16) {
                    Text("Your agents, right at home.")
                        .bighelpFont(.display)
                        .foregroundStyle(theme.primaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    Text("Chat with the Hermes agents running on your computer. No separate bighelp account required.")
                        .bighelpFont(.body)
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Label("Private by design · Connected directly", systemImage: "lock.shield.fill")
                        .bighelpFont(.label)
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, BighelpTokens.space16)
                        .padding(.vertical, BighelpTokens.space8)
                        .background(theme.surface, in: .capsule)
                        .overlay {
                            Capsule().stroke(theme.border, lineWidth: BighelpTokens.hairline)
                        }
                }
                .frame(maxWidth: 620)
                Spacer(minLength: BighelpTokens.space24)
            }
            .padding(.horizontal, BighelpTokens.space24)
            .padding(.bottom, BighelpTokens.space24)
            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
        }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                actionFooter(title: "Get Started", identifier: "onboarding.get-started") {
                    continueToConnect()
                }
                Button {
                    move(to: .appearance)
                } label: {
                    Text("Appearance options")
                        .font(.bighelp(.subheadline))
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryText)
                .accessibilityIdentifier("onboarding.customize-appearance")
                .padding(.bottom, BighelpTokens.space8)
            }
            .background(.bar)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.welcome")
    }

    private var appearanceStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space24) {
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    Text("Make bighelp feel like yours")
                        .bighelpFont(.display)
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Choose an accent and appearance. You can change both anytime in Settings.")
                        .bighelpFont(.body)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                    Text("Appearance")
                        .bighelpFont(.sectionTitle)
                        .foregroundStyle(theme.primaryText)
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Label(appearance.firstRunTitle, systemImage: appearance.firstRunSystemImage)
                                .tag(appearance)
                        }
                    }
                    .bighelpSegmentedPicker()
                    .accessibilityIdentifier("settings.appearance")
                }
                .padding(BighelpTokens.space16)
                .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius20))
                .overlay {
                    RoundedRectangle(cornerRadius: BighelpTokens.radius20, style: .continuous)
                        .stroke(theme.border, lineWidth: BighelpTokens.hairline)
                }

                VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Bubble color")
                            .bighelpFont(.sectionTitle)
                            .foregroundStyle(theme.primaryText)
                        Spacer()
                        Text("Change it anytime in Settings")
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                    }
                    AppearanceBubbleGrid(settings: settings)
                }
                .padding(BighelpTokens.space16)
                .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius20))
                .overlay {
                    RoundedRectangle(cornerRadius: BighelpTokens.radius20, style: .continuous)
                        .stroke(theme.border, lineWidth: BighelpTokens.hairline)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.themes")
            }
            .padding(.horizontal, BighelpTokens.space24)
            .padding(.top, BighelpTokens.space24)
            .padding(.bottom, BighelpTokens.space32)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionFooter(title: "Continue", identifier: "onboarding.appearance.continue") {
                continueToConnect()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.appearance")
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private func actionFooter(
        title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            Divider().overlay(theme.border)
            Button(action: action) {
                Text(title)
                    .bighelpFont(.label, weight: .semibold)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.controlHeight)
                    .contentShape(.rect)
            }
            .controlSize(.large)
            .bighelpActionStyle(.primary)
            .accessibilityIdentifier(identifier)
            .frame(maxWidth: 620)
            .padding(.horizontal, BighelpTokens.space24)
            .padding(.vertical, BighelpTokens.space12)
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// Connecting comes after the one-time agreement to share data with AI providers.
    private func continueToConnect() {
        if agreedToAIData { move(to: .host) } else { isAskingAIConsent = true }
    }

    private func skip() {
        switch step {
        case .appearance: continueToConnect()
        case .plugin, .notifications: move(to: .mode)
        default: break
        }
    }

    private func moveBack() {
        switch step {
        case .host: move(to: connectionBackStep)
        case .mode: move(to: .plugin)
        default: move(to: .welcome)
        }
    }

    private func move(to destination: Step) {
        if destination == .host, step != .host { connectionBackStep = step }
        savedStepRawValue = destination.rawValue
        if reduceMotion {
            step = destination
        } else {
            withAnimation(.easeInOut(duration: BighelpTokens.transitionDuration)) {
                step = destination
            }
        }
    }

    private func restoreSavedProgress() {
        let destination: Step
        if registry.onboardingHostID != nil {
            destination = .host
        } else if isAfterConnect {
            // Connected already: pick up at the plugin, notifications or mode step.
            destination = Step(rawValue: savedStepRawValue).flatMap { $0.rawValue > Step.host.rawValue ? $0 : nil }
                ?? .plugin
        } else {
            destination = Step(rawValue: savedStepRawValue) ?? .welcome
        }
        step = destination
        savedStepRawValue = destination.rawValue
    }

    private func completeOnboarding() {
        savedStepRawValue = Step.welcome.rawValue
        isAfterConnect = false
        onCompleted()
    }

    @BighelpThemeReader private var theme
}

private struct FirstRunCompanionConstellation: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The b writes itself in, waves hello, then rests.
    @State private var logoMotion: BighelpNoodleMotion? = .reveal

    var body: some View {
        GeometryReader { proxy in
            let avatarSize = min(106, max(74, proxy.size.width * 0.28))
            let horizontalOffset = min(132, max(88, proxy.size.width * 0.34))

            ZStack {
                RoundedRectangle(cornerRadius: BighelpTokens.radius28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: gradientColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: BighelpTokens.radius28, style: .continuous)
                            .stroke(theme.border, lineWidth: BighelpTokens.hairline)
                    }

                BighelpLogo(height: 52, motion: logoMotion) {
                    logoMotion = logoMotion == .reveal ? .hello : nil
                }
                    .padding(.horizontal, BighelpTokens.space32)
                    .padding(.vertical, BighelpTokens.space20)
                    .background(.thinMaterial, in: .capsule)
                    .overlay { Capsule().stroke(theme.border, lineWidth: BighelpTokens.hairline) }

                companion(.lobster, motion: .bounce)
                    .frame(width: avatarSize, height: avatarSize)
                    .offset(x: -horizontalOffset, y: -69)
                    .rotationEffect(.degrees(-7))
                companion(.messenger, motion: .dance)
                    .frame(width: avatarSize * 0.96, height: avatarSize * 0.96)
                    .offset(x: horizontalOffset, y: -66)
                    .rotationEffect(.degrees(6))
                companion(.robot, motion: .bounce)
                    .frame(width: avatarSize * 0.9, height: avatarSize * 0.9)
                    .offset(x: horizontalOffset * 0.72, y: 83)
                companion(.dragon, motion: .none)
                    .frame(width: avatarSize * 0.77, height: avatarSize * 0.77)
                    .offset(x: -horizontalOffset * 0.88, y: 86)
            }
        }
        .frame(height: 286)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("bighelp and its colorful agent companions")
    }

    private var gradientColors: [Color] {
        let accents = theme.backgroundAccents.map { $0.opacity(0.22) }
        return accents.isEmpty ? [theme.action.opacity(0.16), theme.canvas] : accents
    }

    private func companion(
        _ character: CompanionCharacter,
        motion: CompanionAmbientMotion
    ) -> some View {
        CompanionAvatar(
            appearance: CompanionAppearance(character: character, usesCharacterColors: true),
            reaction: .idle,
            isAnimating: !reduceMotion,
            ambientMotion: motion
        )
    }

    @BighelpThemeReader private var theme
}

private extension AppAppearance {
    var firstRunTitle: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var firstRunSystemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }
}
