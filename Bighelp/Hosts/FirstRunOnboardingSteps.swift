import SwiftUI

/// The first-run steps after Connect: the optional plugin, notifications (once the plugin is in), and how
/// the home opens. Plain words throughout: these screens are for everyone, not only the technical.
enum FirstRunOnboarding {
    /// Connected, with the steps after Connect still to go. Keeps onboarding on screen past the host
    /// setup's own finish, which clears `onboardingHostID`.
    static let afterConnectKey = "bighelp.onboarding.after-connect"
}

// MARK: Layout

/// One step: a friendly icon, a title, a line under it, the step's content, and its buttons at the bottom.
private struct FirstRunStepLayout<Content: View>: View {
    let systemImage: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var subtitleIdentifier: String?
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
                        .accessibilityIdentifier(subtitleIdentifier ?? "")
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
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
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
    /// After an install: the plugin takes effect once the dashboard and the gateway restart.
    @State private var restarts: HostPluginUpdateModel?
    @State private var restartPrompt: HostPluginUpdateModel?
    @BighelpThemeReader private var theme

    private var primaryTitle: String {
        if needsRestart { return String(localized: "Continue") }
        if alreadyInstalled { return String(localized: "Continue") }
        if restarts?.isWorking == true { return String(localized: "Restarting…") }
        guard setup?.isWorking == true else { return String(localized: "Install Plugin") }
        return setup?.state == .checking ? String(localized: "Checking…") : String(localized: "Installing…")
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
            isWorking: (setup?.isWorking == true || restarts?.isWorking == true) && !alreadyInstalled,
            primary: {
                if needsRestart { onSkip() } else if alreadyInstalled { onInstalled() } else { install() }
            }
        ) {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                FirstRunFeatureRow(systemImage: "bell.badge.fill", title: "Alerts",
                                   detail: "Know when your bots reply, finish a task, or need you.", tint: .red)
                FirstRunFeatureRow(systemImage: "person.2.fill", title: "Teamwork",
                                   detail: "Your bots bring each other in to get things done.", tint: .blue)
                FirstRunFeatureRow(systemImage: "waveform", title: "Live voice",
                                   detail: "Talk with your bots and hear them answer right away.", tint: .purple)
                FirstRunFeatureRow(systemImage: "rectangle.stack.fill", title: "Feed, Ideas and Goals",
                                   detail: "Updates and plans your bots make for you.", tint: .orange)
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
                if !needsRestart, let failure = setup?.failure {
                    BighelpNotificationFailureCodeRow(failure: failure, identifier: "onboarding.plugin.failure")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.plugin")
        .task { await checkInstalled() }
        .pluginRestartPrompt($restartPrompt) { _ in onInstalled() }
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
            outcome = String(localized: "Connect to your computer first, then add the plugin in Settings.")
            return
        }
        let model = setup ?? HostNotificationSetupModel(host: host, registry: registry, enrollNotifications: false)
        setup = model
        outcome = nil
        Task {
            await model.enable()
            switch model.state {
            case .installed where model.pluginChanged, .enabled where model.pluginChanged:
                let restarts = await HostPluginUpdateModel.afterPluginChange(hostID: host.id, registry: registry)
                self.restarts = restarts
                restartPrompt = restarts
            case .installed, .enabled:
                onInstalled()
            case .backendRestartRequired:
                needsRestart = true
                outcome = String(localized: "Installed. Restart Hermes on your computer to finish, then turn on alerts in Settings.")
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

    /// Trying again can't fix this one: its message says what to do, and setup moves on.
    private var retryCannotHelp: Bool { outcome != nil && setup?.offersRetry == false }

    private var primaryTitle: String {
        if setup?.isWorking == true { return String(localized: "Turning On…") }
        if retryCannotHelp { return String(localized: "Continue") }
        return outcome == nil ? String(localized: "Turn On Notifications") : String(localized: "Try Again")
    }

    var body: some View {
        FirstRunStepLayout(
            systemImage: "bell.badge.fill",
            title: "Turn on notifications?",
            subtitle: "Get an alert when your bots reply, finish something, or have a question for you.",
            primaryTitle: primaryTitle,
            primaryIdentifier: "onboarding.notifications.enable",
            isWorking: setup?.isWorking == true,
            primary: { if retryCannotHelp { onDone() } else { enable() } }
        ) {
            VStack(spacing: BighelpTokens.space12) {
                FirstRunAlertPreview(name: "Avery Park", message: "Your October budget is ready.", time: "now")
                FirstRunAlertPreview(name: "Mina Shah", message: "I found three flights under $400. Should I book one?",
                                     time: "2m ago")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sample alerts from your bots")
            if let outcome {
                Label(outcome, systemImage: "exclamationmark.circle")
                    .bighelpFont(.metadata)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding.notifications.outcome")
                if let failure = setup?.failure {
                    BighelpNotificationFailureCodeRow(failure: failure, identifier: "onboarding.notifications.failure")
                }
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
    let message: LocalizedStringKey
    let time: LocalizedStringKey
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

// MARK: How to start

/// How the home opens, asked once at the end of setup: one ongoing chat with each bot, or many chats.
/// Either way it's the same home; the answer picks Opens on, which Settings › Chat changes later.
enum FirstRunHome: String, CaseIterable, Identifiable {
    case bots, chats

    var id: Self { self }

    var title: String {
        switch self {
        case .bots: String(localized: "With a bot")
        case .chats: String(localized: "Across chats")
        }
    }

    var detail: String {
        switch self {
        case .bots: String(localized: "One ongoing chat with each bot.")
        case .chats: String(localized: "Many chats, newest first.")
        }
    }

    var landing: HomeLanding {
        switch self {
        case .bots: .bots
        case .chats: .chats
        }
    }

    /// Opens on, which also sets the first tab's view.
    @MainActor
    func apply(to settings: SettingsStore) {
        settings.homeLanding = landing
    }
}

/// "How do you want to start?": two choices and Continue. No Skip: the home needs an answer.
@MainActor
struct FirstRunHomeStep: View {
    let settings: SettingsStore
    let onChoose: () -> Void
    @State private var choice = FirstRunHome.bots

    var body: some View {
        FirstRunStepLayout(
            systemImage: "house.fill",
            title: "How do you want to start?",
            subtitle: "You can change this in Settings › Chat.",
            subtitleIdentifier: "onboarding.mode.later",
            primaryTitle: String(localized: "Continue"),
            primaryIdentifier: "onboarding.mode.continue",
            primary: {
                choice.apply(to: settings)
                onChoose()
            }
        ) {
            VStack(spacing: BighelpTokens.space12) {
                ForEach(FirstRunHome.allCases) { home in
                    FirstRunHomeCard(home: home, isChosen: home == choice) { choice = home }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.mode")
    }
}

/// One choice: a small drawing of where it opens, its name and one line.
private struct FirstRunHomeCard: View {
    let home: FirstRunHome
    let isChosen: Bool
    let onSelect: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @BighelpThemeReader private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius20, style: .continuous)
        // At the largest text sizes the words get the card's whole width, under the drawing.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: BighelpTokens.space12))
            : AnyLayout(HStackLayout(spacing: BighelpTokens.space16))
        Button(action: onSelect) {
            layout {
                FirstRunHomeSketch(home: home)
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text(home.title)
                        .bighelpFont(.label, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                    Text(home.detail)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .font(.bighelp(.title3))
                    .foregroundStyle(isChosen ? theme.action : theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .padding(BighelpTokens.space16)
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            .background(shape.fill(isChosen ? theme.action.opacity(theme.isDarkPalette ? 0.16 : 0.08) : theme.surface))
            .overlay {
                shape.strokeBorder(isChosen ? theme.action : theme.border,
                                   lineWidth: isChosen ? 2 : BighelpTokens.hairline)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(home.title)
        .accessibilityValue(home.detail)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityIdentifier("onboarding.mode.\(home.rawValue)")
    }
}

/// A still drawing of the home each choice opens on, in the theme's colors: a face for each bot, or a
/// list of chats with their times. Drawn, not a screenshot, so it can't show a home that's gone.
private struct FirstRunHomeSketch: View {
    let home: FirstRunHome
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 6) {
                    switch home {
                    case .bots:
                        Circle().fill(faceTint(row)).frame(width: 14, height: 14)
                        bar(width: [30, 24, 34][row])
                    case .chats:
                        VStack(alignment: .leading, spacing: 3) {
                            bar(width: [36, 28, 38][row])
                            bar(width: [24, 32, 20][row]).opacity(0.6)
                        }
                        Spacer(minLength: 0)
                        bar(width: 8)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 76, height: 76, alignment: .topLeading)
        .background(theme.canvas, in: .rect(cornerRadius: BighelpTokens.radius12))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius12).stroke(theme.border, lineWidth: BighelpTokens.hairline)
        }
        .accessibilityHidden(true)
    }

    private func bar(width: CGFloat) -> some View {
        Capsule().fill(theme.secondaryText.opacity(0.35)).frame(width: width, height: 5)
    }

    private func faceTint(_ row: Int) -> Color {
        [theme.action, theme.action.opacity(0.55), theme.secondaryText.opacity(0.45)][row]
    }
}
