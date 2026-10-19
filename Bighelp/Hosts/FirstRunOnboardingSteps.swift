import SwiftUI

/// The first-run steps after Connect: the optional plugin, notifications (once the plugin is in), and the
/// mode bighelp opens in. Plain words throughout: these screens are for everyone, not only the technical.
enum FirstRunOnboarding {
    /// Connected, with the steps after Connect still to go. Keeps onboarding on screen past the host
    /// setup's own finish, which clears `onboardingHostID`.
    static let afterConnectKey = "bighelp.onboarding.after-connect"
}

// MARK: Layout

/// One step: a friendly icon, a title, a line under it, the step's content, and its buttons at the bottom.
private struct FirstRunStepLayout<Content: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let primaryTitle: String
    let primaryIdentifier: String
    var isWorking = false
    let primary: () -> Void
    @ViewBuilder let content: Content
    @BighelpThemeReader private var theme

    var body: some View {
        ScrollView {
            VStack(spacing: BighelpTokens.space20) {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(theme.actionForeground)
                    .frame(width: 64, height: 64)
                    .background(theme.action, in: .circle)
                    .accessibilityHidden(true)
                    .padding(.top, BighelpTokens.space16)
                VStack(spacing: BighelpTokens.space8) {
                    Text(title)
                        .bighelpFont(.display)
                        .foregroundStyle(theme.primaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .bighelpFont(.body)
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(.horizontal, BighelpTokens.space24)
            .padding(.bottom, BighelpTokens.space24)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider().overlay(theme.border)
                Button(action: primary) {
                    HStack(spacing: BighelpTokens.space8) {
                        if isWorking { ProgressView().tint(theme.actionForeground) }
                        Text(primaryTitle).bighelpFont(.label, weight: .semibold)
                    }
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.controlHeight)
                    .contentShape(.rect)
                }
                .controlSize(.large)
                .bighelpActionStyle(.primary)
                .disabled(isWorking)
                .accessibilityIdentifier(primaryIdentifier)
                .frame(maxWidth: 620)
                .padding(.horizontal, BighelpTokens.space24)
                .padding(.vertical, BighelpTokens.space12)
            }
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }
}

/// A row of what something does: a small colored icon, a name, and one line.
private struct FirstRunFeatureRow: View {
    let systemImage: String
    let title: String
    let detail: String
    let tint: Color
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(tint, in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bighelpFont(.label, weight: .semibold).foregroundStyle(theme.primaryText)
                Text(detail).bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Plugin

/// "Add the bighelp plugin": what it adds, one tap to install it on the computer, clearly optional.
@MainActor
struct FirstRunPluginStep: View {
    let registry: BighelpHostRegistry
    let onInstalled: () -> Void
    let onSkip: () -> Void
    @State private var setup: HostNotificationSetupModel?
    @State private var outcome: String?
    @State private var needsRestart = false
    @State private var alreadyInstalled = false
    @BighelpThemeReader private var theme

    private var primaryTitle: String {
        if needsRestart { return "Continue" }
        if alreadyInstalled { return "Continue" }
        guard setup?.isWorking == true else { return "Install Plugin" }
        return setup?.state == .checking ? "Checking…" : "Installing…"
    }

    var body: some View {
        FirstRunStepLayout(
            systemImage: "puzzlepiece.extension.fill",
            title: alreadyInstalled ? "The bighelp plugin is on" : "Add the bighelp plugin",
            subtitle: alreadyInstalled
                ? "Your computer already has it. Here's what it adds."
                : "Optional. It adds extras to Hermes on your computer. You can add it later in Settings.",
            primaryTitle: primaryTitle,
            primaryIdentifier: "onboarding.plugin.install",
            isWorking: setup?.isWorking == true && !alreadyInstalled,
            primary: {
                if needsRestart { onSkip() } else if alreadyInstalled { onInstalled() } else { install() }
            }
        ) {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                FirstRunFeatureRow(systemImage: "bell.badge.fill", title: "Alerts",
                                   detail: "Know when your agents reply, finish a task, or need you.", tint: .red)
                FirstRunFeatureRow(systemImage: "person.2.fill", title: "Teamwork",
                                   detail: "Your agents bring each other in to get things done.", tint: .blue)
                FirstRunFeatureRow(systemImage: "waveform", title: "Live voice",
                                   detail: "Talk with your agents and hear them answer right away.", tint: .purple)
                FirstRunFeatureRow(systemImage: "rectangle.stack.fill", title: "Feed, Ideas and Goals",
                                   detail: "Updates and plans your agents make for you.", tint: .orange)
                FirstRunFeatureRow(systemImage: "photo.on.rectangle.angled", title: "Files and cards",
                                   detail: "Pictures, files and handy cards right in your chats.", tint: .teal)
                FirstRunFeatureRow(systemImage: "lock.shield.fill", title: "Chats that stay put",
                                   detail: "Your chats stay open when your phone sleeps.", tint: .green)
            }
            .padding(BighelpTokens.space16)
            .background(theme.surface, in: .rect(cornerRadius: 20))
            if let outcome {
                Label(outcome, systemImage: needsRestart ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .bighelpFont(.metadata)
                    .foregroundStyle(needsRestart ? theme.primaryText : theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding.plugin.outcome")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.plugin")
        .task { await checkInstalled() }
    }

    /// A computer that already has the plugin only needs Continue. Checking reads; it never installs.
    private func checkInstalled() async {
        guard setup == nil, let host = registry.selectedHost else { return }
        let model = HostNotificationSetupModel(host: host, registry: registry, enrollNotifications: false)
        setup = model
        await model.refreshInstalledState()
        if model.state == .installed { alreadyInstalled = true }
    }

    private func install() {
        guard let host = registry.selectedHost else {
            outcome = "Connect to your computer first, then add the plugin in Settings."
            return
        }
        let model = setup ?? HostNotificationSetupModel(host: host, registry: registry, enrollNotifications: false)
        setup = model
        outcome = nil
        Task {
            await model.enable()
            switch model.state {
            case .installed, .enabled:
                onInstalled()
            case .backendRestartRequired:
                needsRestart = true
                outcome = "Installed. Restart Hermes on your computer to finish, then turn on alerts in Settings."
            default:
                outcome = model.message
            }
        }
    }
}

// MARK: Notifications

/// After the plugin is in: alerts for replies, finished tasks and questions, if the person wants them.
@MainActor
struct FirstRunNotificationsStep: View {
    let registry: BighelpHostRegistry
    let onDone: () -> Void
    @State private var setup: HostNotificationSetupModel?
    @State private var outcome: String?

    var body: some View {
        FirstRunStepLayout(
            systemImage: "bell.badge.fill",
            title: "Turn on notifications?",
            subtitle: "Get an alert when your agents reply, finish something, or have a question for you.",
            primaryTitle: setup?.isWorking == true ? "Turning On…" : outcome == nil ? "Turn On Notifications" : "Try Again",
            primaryIdentifier: "onboarding.notifications.enable",
            isWorking: setup?.isWorking == true,
            primary: enable
        ) {
            VStack(spacing: BighelpTokens.space12) {
                FirstRunAlertPreview(name: "Avery Park", message: "Your October budget is ready.", time: "now")
                FirstRunAlertPreview(name: "Mina Shah", message: "I found three flights under $400. Should I book one?",
                                     time: "2m ago")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sample alerts from your agents")
            if let outcome {
                Label(outcome, systemImage: "exclamationmark.circle")
                    .bighelpFont(.metadata)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding.notifications.outcome")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.notifications")
    }

    private func enable() {
        guard let host = registry.selectedHost else { onDone(); return }
        let model = setup ?? HostNotificationSetupModel(host: host, registry: registry)
        setup = model
        outcome = nil
        Task {
            await model.enable()
            if model.state == .enabled { onDone() } else { outcome = model.message }
        }
    }
}

/// A sample alert, drawn like the system's banner, so people can see what they'd get.
private struct FirstRunAlertPreview: View {
    let name: String
    let message: String
    let time: String
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image("BighelpMarkColor")
                .resizable()
                .scaledToFit()
                .padding(6)
                .frame(width: 38, height: 38)
                .background(theme.raisedSurface, in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(name).bighelpFont(.label, weight: .semibold).foregroundStyle(theme.primaryText)
                    Spacer(minLength: BighelpTokens.space8)
                    Text(time).bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
                }
                Text(message).bighelpFont(.metadata).foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(BighelpTokens.space12)
        .background(theme.surface, in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.border, lineWidth: BighelpTokens.hairline))
    }
}

// MARK: Mode

/// The three ways to use bighelp, offered once at the end of setup.
enum FirstRunMode: String, CaseIterable, Identifiable {
    case bots, sessions, code

    var id: Self { self }

    var title: String {
        switch self {
        case .bots: "Bots"
        case .sessions: "Sessions"
        case .code: "Code"
        }
    }

    var detail: String {
        switch self {
        case .bots: "Simple chats with your bots, like texting friends."
        case .sessions: "Every chat, tool and setting in the full bighelp app."
        case .code: "Start coding tasks on your projects and review the changes."
        }
    }

    var systemImage: String {
        switch self {
        case .bots: "bubble.left.and.bubble.right.fill"
        case .sessions: "square.grid.2x2.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The preview: a screenshot of the mode, in light and dark.
    var previewImage: String {
        switch self {
        case .bots: "OnboardingModeBots"
        case .sessions: "OnboardingModeSessions"
        case .code: "OnboardingModeCode"
        }
    }

    /// Bots is Simple Bot mode; Sessions the app as it comes; Code opens in Bighelp IDE.
    @MainActor
    func apply(to settings: SettingsStore) {
        switch self {
        case .bots:
            settings.codeModeEnabled = false
            settings.simpleBotsEnabled = true
        case .sessions:
            settings.simpleBotsEnabled = false
            settings.codeModeEnabled = false
        case .code:
            settings.simpleBotsEnabled = false
            settings.codeModeEnabled = true
            settings.startExperience = .code
            settings.experience = .code
        }
    }
}

/// "Choose your mode": three cards to swipe through, each with a preview of the mode. Tapping one shows
/// its preview large.
@MainActor
struct FirstRunModeStep: View {
    let settings: SettingsStore
    let onChoose: () -> Void
    @State private var selection: FirstRunMode? = .bots
    @State private var previewing: FirstRunMode?
    @BighelpThemeReader private var theme

    private var chosen: FirstRunMode { selection ?? .bots }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: BighelpTokens.space4) {
                Text("Choose your mode")
                    .bighelpFont(.display)
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("You can change this later")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("onboarding.mode.later")
            }
            .padding(.top, BighelpTokens.space24)
            .padding(.horizontal, BighelpTokens.space24)

            GeometryReader { geometry in
                let cardWidth = min(geometry.size.width * 0.72, 300)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: BighelpTokens.space16) {
                        ForEach(FirstRunMode.allCases) { mode in
                            card(mode, width: cardWidth, height: geometry.size.height - BighelpTokens.space32)
                                .id(mode)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $selection, anchor: .center)
                .contentMargins(.horizontal, (geometry.size.width - cardWidth) / 2, for: .scrollContent)
                .padding(.vertical, BighelpTokens.space16)
            }

            HStack(spacing: BighelpTokens.space8) {
                ForEach(FirstRunMode.allCases) { mode in
                    Circle()
                        .fill(mode == chosen ? theme.action : theme.secondaryText.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .accessibilityHidden(true)
            .padding(.bottom, BighelpTokens.space8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider().overlay(theme.border)
                Button { choose(chosen) } label: {
                    Text("Use \(chosen.title)")
                        .bighelpFont(.label, weight: .semibold)
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.controlHeight)
                        .contentShape(.rect)
                }
                .controlSize(.large)
                .bighelpActionStyle(.primary)
                .accessibilityIdentifier("onboarding.mode.continue")
                .frame(maxWidth: 620)
                .padding(.horizontal, BighelpTokens.space24)
                .padding(.vertical, BighelpTokens.space12)
            }
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .bighelpSheet(item: $previewing) { mode in
            FirstRunModePreview(mode: mode) {
                previewing = nil
                choose(mode)
            } onClose: {
                previewing = nil
            }
            .bighelpSheetSize(.large)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.mode")
    }

    private func card(_ mode: FirstRunMode, width: CGFloat, height: CGFloat) -> some View {
        let isChosen = mode == chosen
        return Button {
            withAnimation(.snappy) { selection = mode }
            previewing = mode
        } label: {
            VStack(spacing: BighelpTokens.space12) {
                Image(mode.previewImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.border, lineWidth: BighelpTokens.hairline))
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
                HStack(spacing: BighelpTokens.space8) {
                    Image(systemName: mode.systemImage)
                        .foregroundStyle(theme.action)
                    Text(mode.title)
                        .bighelpFont(.sectionTitle, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                    if isChosen {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.action)
                    }
                }
                Text(mode.detail)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(BighelpTokens.space16)
            .frame(width: width, height: max(height, 200))
            .background(theme.surface, in: .rect(cornerRadius: 28))
            .overlay {
                RoundedRectangle(cornerRadius: 28)
                    .stroke(isChosen ? theme.action : theme.border, lineWidth: isChosen ? 2 : BighelpTokens.hairline)
            }
            .contentShape(.rect(cornerRadius: 28))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.title). \(mode.detail)")
        .accessibilityHint("Shows a preview")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityIdentifier("onboarding.mode.\(mode.rawValue)")
    }

    private func choose(_ mode: FirstRunMode) {
        mode.apply(to: settings)
        onChoose()
    }
}

/// A mode's preview, large, with the button to choose it.
private struct FirstRunModePreview: View {
    let mode: FirstRunMode
    let onUse: () -> Void
    let onClose: () -> Void
    @BighelpThemeReader private var theme

    var body: some View {
        NavigationStack {
            VStack(spacing: BighelpTokens.space16) {
                Image(mode.previewImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 28))
                    .overlay(RoundedRectangle(cornerRadius: 28).stroke(theme.border, lineWidth: BighelpTokens.hairline))
                    .frame(maxHeight: .infinity)
                    .accessibilityLabel("Preview of \(mode.title)")
                Text(mode.detail)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onUse) {
                    Text("Use \(mode.title)")
                        .bighelpFont(.label, weight: .semibold)
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.controlHeight)
                        .contentShape(.rect)
                }
                .controlSize(.large)
                .bighelpActionStyle(.primary)
                .accessibilityIdentifier("onboarding.mode.preview.use")
            }
            .padding(BighelpTokens.space24)
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
    }
}
