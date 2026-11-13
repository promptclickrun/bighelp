import SwiftUI
import UIKit

extension SettingsView {
    /// Settings › Appearance: colors, light and dark, and the rest of the look on one page, with
    /// Chat layout, App layout, Thinking and the companion pet a row each.
    var appearancePage: some View {
        AppearanceStudioView(settings: settings) {
            settingsLink(to: .chatLayout) {
                AppearanceStudioRow(title: String(localized: "Chat layout"),
                                    detail: String(localized: "Avatar, name, text size and spacing"),
                                    systemImage: "text.bubble")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.appearance.chat-layout")
            .driveTarget("settings.appearance.chat-layout")
            settingsLink(to: .appLayout) {
                AppearanceStudioRow(title: String(localized: "App layout"),
                                    detail: String(localized: "Bottom bar and menu order"),
                                    systemImage: "rectangle.bottomthird.inset.filled")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.appearance.app-layout")
            .driveTarget("settings.appearance.app-layout")
            settingsLink(to: .thinking) {
                AppearanceStudioRow(title: String(localized: "Thinking"),
                                    detail: String(localized: "The look of the Thinking control"),
                                    systemImage: "brain.head.profile")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.appearance.thinking")
            .driveTarget("settings.appearance.thinking")
            if companionStore != nil {
                settingsLink(to: .section(.companion)) {
                    AppearanceStudioRow(title: SettingsMenuSection.companion.title,
                                        detail: SettingsMenuSection.companion.detail,
                                        systemImage: SettingsMenuSection.companion.systemImage)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(SettingsMenuSection.companion.accessibilityIdentifier)
                .driveTarget(SettingsMenuSection.companion.accessibilityIdentifier)
            }
            #if os(visionOS)
            transparency
                .padding(BighelpTokens.space16)
                .background(theme.surface, in: .rect(cornerRadius: 16))
            #endif
            if settings.nerdModeEnabled {
                reflectiveVisionCard
            }
        }
    }

    #if os(visionOS)
    /// How much of the room shows through bighelp's windows.
    private var transparency: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            settingLabel(String(localized: "Transparency"),
                         detail: String(localized: "How much of your space shows through bighelp"))
            HStack(spacing: BighelpTokens.space12) {
                Image(systemName: "square.fill")
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityHidden(true)
                Slider(value: $settings.windowTransparency, in: 0...1)
                    .accessibilityLabel("Window transparency")
                    .accessibilityValue("\(Int((settings.windowTransparency * 100).rounded())) percent")
                    .accessibilityIdentifier("appearance.transparency")
                Image(systemName: "square.dashed")
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: BighelpTokens.hitTarget)
        }
    }
    #endif

    private var reflectiveVisionCard: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Toggle(isOn: Binding(
                get: { settings.reflectiveVisionEnabled },
                set: { enabled in
                    settings.reflectiveVisionEnabled = enabled
                    Task {
                        if enabled {
                            _ = await permissionCenter.authorizeContextualAccess(.camera)
                        }
                        await reflectiveVisionCamera?.update(
                            enabled: enabled
                        )
                        await permissionCenter.refresh(.camera)
                    }
                }
            )) {
                settingLabel(String(localized: "Reflective Vision"),
                             detail: String(localized: "Your blurred surroundings in a few accents. Uses the camera only while on."))
            }
            .accessibilityIdentifier("settings.reflective-vision")

            if settings.reflectiveVisionEnabled {
                HStack(alignment: .top, spacing: BighelpTokens.space8) {
                    Image(systemName: reflectiveVisionCamera?.state.isActive == true
                        ? "camera.aperture"
                        : "camera.fill")
                        .reflectiveVisionIcon()
                        .foregroundStyle(theme.action)
                        .accessibilityHidden(true)
                    Text(reflectiveVisionStatus)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                }
                .accessibilityElement(children: .combine)

                if reflectiveVisionCamera?.state.canOpenSettings == true {
                    Button("Open Camera Settings") {
                        permissionCenter.performRecoveryAction(for: .camera)
                    }
                    .bighelpFont(.label)
                }
            }
        }
        .padding(BighelpTokens.space16)
        .background(theme.surface, in: .rect(cornerRadius: 16))
    }

    private var reflectiveVisionStatus: String {
        reflectiveVisionCamera?.state.statusText
            ?? String(localized: "The live reflection is available when bighelp is running on a device with camera access.")
    }

    var workspace: some View {
        Section("Advanced · Chat list") {
            Toggle(isOn: $settings.organizeChatsByProjects) {
                settingTitle(String(localized: "Group by project"))
            }
            .accessibilityIdentifier("settings.organize-chats-by-projects")

            Toggle(isOn: $settings.showCronSessions) {
                settingTitle(String(localized: "Scheduled runs"))
            }
            .accessibilityIdentifier("settings.show-cron-sessions")
        }
        .listRowBackground(theme.surface)
    }

    var agentBehavior: some View {
        Section("Agent Behavior") {
            Button {
                isPersonalitiesPresented = true
            } label: {
                HStack(spacing: BighelpTokens.space12) {
                    Label("Personalities", systemImage: "theatermasks")
                    Spacer(minLength: BighelpTokens.space8)
                    if let active = personalities.catalog?.activeName, !active.isEmpty {
                        Text(active.capitalized)
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Image(systemName: "chevron.right")
                        .font(.bighelp(.caption).weight(.semibold))
                        .foregroundStyle(theme.tertiaryText)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            }
            .accessibilityIdentifier("profile.personalities")
        }
        .listRowBackground(theme.surface)
    }

    /// Code mode's swipe only while Code mode is on (or already picked, so the picker still shows it).
    func swipeChoices(keeping current: WorkspaceSwipeAction) -> [WorkspaceSwipeAction] {
        WorkspaceSwipeAction.allCases.filter { $0 != .codeMode || settings.codeModeEnabled || current == .codeMode }
    }

    /// A Mac has no screen edges to swipe from.
    @ViewBuilder
    var edgeGestures: some View {
        #if !targetEnvironment(macCatalyst)
        Section {
            Picker("Swipe from left edge", selection: $settings.leftEdgeSwipeAction) {
                ForEach(swipeChoices(keeping: settings.leftEdgeSwipeAction)) { action in
                    Label(action.title, systemImage: action.systemImage).tag(action)
                }
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .accessibilityIdentifier("settings.left-edge-swipe")

            Picker("Swipe from right edge", selection: $settings.rightEdgeSwipeAction) {
                ForEach(swipeChoices(keeping: settings.rightEdgeSwipeAction)) { action in
                    Label(action.title, systemImage: action.systemImage).tag(action)
                }
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .accessibilityIdentifier("settings.right-edge-swipe")
        } header: {
            Text("Advanced · Edge swipes")
        } footer: {
            Text("Start right at the edge of the screen.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
        #endif
    }

    /// Where bighelp opens when it starts and with which bot (`BighelpLanding`), and what a tap
    /// on a bot opens. Each row's second line is its value: the choices' own names say what they do.
    private var opening: some View {
        let screen = settings.landingScreen ?? .lastChat
        let startAgentID = settings.startAgentID(scope: landingScope).flatMap { id in
            agents.contains { $0.id == id } ? id : nil
        }
        return Section {
            Picker(selection: Binding(get: { screen }, set: { settings.landingScreen = $0 })) {
                ForEach(BighelpLandingScreen.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            } label: {
                settingTitle(String(localized: "Opens on"))
            }
            .accessibilityIdentifier("settings.landing.screen")

            if screen.offersStartAgent, let scope = landingScope, !agents.isEmpty {
                Picker(selection: Binding(get: { startAgentID },
                                          set: { settings.setStartAgentID($0, scope: scope) })) {
                    Text("Last bot used").tag(String?.none)
                    ForEach(agents) { agent in
                        Text(agent.name).tag(Optional(agent.id))
                    }
                } label: {
                    settingTitle(String(localized: "Start with"))
                }
                .accessibilityIdentifier("settings.landing.agent")
            }

            Picker(selection: $settings.botChatExperience) {
                ForEach(BotChatExperience.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            } label: {
                settingTitle(String(localized: "A bot opens"))
            }
            .accessibilityIdentifier("settings.chat.bot-chat-experience")
        } header: {
            Text("Opening")
        } footer: {
            Text("Links, widgets and notifications still open what they point to.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
    }

    /// How a one-to-one chat shows what its bot does while it works.
    private var botWork: some View {
        Section("A bot's work") {
            Picker(selection: $settings.chatWorkStyle) {
                ForEach(ChatWorkStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            } label: {
                settingTitle(String(localized: "Shows as"))
            }
            .accessibilityIdentifier("settings.chat.work-style")

            ChatReasoningSettingRows {
                settingTitle(String(localized: "Thinking"))
            } staysOpenLabel: {
                settingTitle(String(localized: "Keep thinking open"))
            }

            #if !targetEnvironment(macCatalyst) // The island is an iPhone's.
            Toggle(isOn: $settings.agentIslandEnabled) {
                settingTitle(String(localized: "Dynamic Island"))
            }
            .accessibilityIdentifier("settings.chat.agent-island")
            #endif
        }
        .listRowBackground(theme.surface)
    }

    private var inChat: some View {
        Section("In a chat") {
            SessionTitleToggle {
                settingTitle(String(localized: "Chat title"))
            }
            .accessibilityIdentifier("settings.chat.session-title")

            Toggle(isOn: $settings.reactionsReachAgent) {
                settingTitle(String(localized: "Bots see reactions"))
            }
            .accessibilityIdentifier("settings.chat.reactions-reach-agent")

            #if !targetEnvironment(macCatalyst) // A Mac has no haptics.
            Toggle(isOn: $settings.responseHapticsEnabled) {
                settingTitle(String(localized: "Haptics"))
            }
            .accessibilityIdentifier("settings.chat.response-haptics")
            #endif

            ReturnSendsToggle {
                settingLabel(String(localized: "Return sends"), detail: Self.returnSendsHint)
            }
            .accessibilityIdentifier("settings.chat.return-sends")
            .driveTarget("settings.chat.return-sends")
        }
        .listRowBackground(theme.surface)
    }

    /// The on-screen keyboard's Return always adds a line, so an iPhone or iPad says which
    /// keyboard the switch is for. A Mac always has one.
    private static var returnSendsHint: String {
        #if targetEnvironment(macCatalyst)
        String(localized: "Shift-Return adds a line")
        #else
        String(localized: "With a keyboard attached")
        #endif
    }

    private var chatList: some View {
        Section("Chat list") {
            ChatProjectToggle {
                settingTitle(String(localized: "Project names"))
            }
            .accessibilityIdentifier("settings.chat.chat-projects")
        }
        .listRowBackground(theme.surface)
    }

    /// Settings › Chat: four named groups, then Nerd Mode's Advanced groups (what chats show,
    /// sending, edge swipes and the chat list). Everyday controls are never only in those.
    var chatPage: some View {
        Form {
            BighelpDeferredSection { opening }
            BighelpDeferredSection { botWork }
            BighelpDeferredSection { inChat }
            BighelpDeferredSection { chatList }
            if settings.nerdModeEnabled {
                BighelpDeferredSection { chatDetailDefaults }
                BighelpDeferredSection { advancedChat }
                BighelpDeferredSection { sendingAndLinks }
                BighelpDeferredSection { edgeGestures }
                BighelpDeferredSection { workspace }
            }
        }
        .bighelpFormSurface()
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .driveScrolls()
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// How much of a bot's work chats show. Technical, so it appears with Nerd Mode's
    /// Advanced groups rather than the basics. A chat's own ••• menu overrides these for itself,
    /// which is why they have a group of their own: the footer is true for all three.
    var chatDetailDefaults: some View {
        Section {
            Toggle(isOn: $settings.foldCompletedTurns) {
                settingLabel(
                    String(localized: "Fold finished turns"),
                    detail: String(localized: "Answers stay open")
                )
            }
            .accessibilityIdentifier("settings.chat.fold-completed-turns")

            Toggle(isOn: $settings.showReasoningByDefault) {
                settingTitle(String(localized: "Show thinking"))
            }
            .accessibilityIdentifier("settings.chat.show-reasoning")

            Toggle(isOn: $settings.showToolCallsByDefault) {
                settingTitle(String(localized: "Show tool calls"))
            }
            .accessibilityIdentifier("settings.chat.show-tool-calls")
        } header: {
            Text("Advanced · A bot's work")
        } footer: {
            Text("A chat can change these in its ••• menu.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
    }

    var advancedChat: some View {
        Section("Advanced · In a chat") {
            Toggle(isOn: $settings.autoSuggestionsEnabled) {
                settingLabel(
                    String(localized: "Suggestions"),
                    detail: String(localized: "Prompts to start a chat")
                )
            }

            Toggle(isOn: $settings.messageActionsEnabled) {
                settingLabel(
                    String(localized: "Message actions"),
                    detail: String(localized: "Actions beside each message")
                )
            }

            Toggle(isOn: $settings.inlineUIEnabled) {
                settingLabel(
                    String(localized: "Cards"),
                    detail: String(localized: "Weather, tasks, budgets and approvals")
                )
            }

            Toggle(isOn: $settings.showProjectChanges) {
                settingLabel(
                    String(localized: "Project changes"),
                    detail: String(localized: "Lines added and removed")
                )
            }
            .accessibilityIdentifier("settings.chat.show-project-changes")
        }
        .listRowBackground(theme.surface)
    }

    /// What Send does while a bot works, and where a web link opens.
    var sendingAndLinks: some View {
        Section {
            Picker(selection: $settings.midSessionChatBehavior) {
                ForEach(MidSessionChatBehavior.allCases) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            } label: {
                settingTitle(String(localized: "While a bot works"))
            }
            .accessibilityIdentifier("settings.chat.mid-session-behavior")

            let availableBrowsers = ChatBrowserPreference.available(canOpenURL: UIApplication.shared.canOpenURL)
            Picker(selection: Binding(
                get: { availableBrowsers.contains(settings.preferredBrowser) ? settings.preferredBrowser : .systemDefault },
                set: { settings.preferredBrowser = $0 }
            )) {
                ForEach(availableBrowsers) { browser in
                    Label(browser.title, systemImage: browser.systemImage).tag(browser)
                }
            } label: {
                settingTitle(String(localized: "Open links in"))
            }
            .accessibilityIdentifier("settings.chat.browser")
        } header: {
            Text("Advanced · Sending and links")
        } footer: {
            Text("Hold Send while a bot works to choose for one message.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
    }
}

/// Saved with the chat look (`@AppStorage`), which the chat headers read directly.
private struct SessionTitleToggle<Label: View>: View {
    @AppStorage(ChatLayoutPreferences.showsSessionTitleKey)
    private var showsSessionTitle = ChatLayoutPreferences.showsSessionTitleByDefault
    @ViewBuilder let label: Label

    var body: some View {
        Toggle(isOn: $showsSessionTitle) { label }
    }
}

/// Settings › Chat: where a chat shows its bot's thinking, and whether its words stay in
/// view (#943). Saved on this device only (`@AppStorage`); chats read both directly.
private struct ChatReasoningSettingRows<PlacementLabel: View, StaysOpenLabel: View>: View {
    @AppStorage(ChatReasoningPlacement.storageKey) private var placement = ChatReasoningPlacement.defaultPlacement
    @AppStorage(ChatReasoningPlacement.staysOpenKey) private var staysOpen = ChatReasoningPlacement.staysOpenByDefault
    @ViewBuilder let placementLabel: PlacementLabel
    @ViewBuilder let staysOpenLabel: StaysOpenLabel

    var body: some View {
        Picker(selection: $placement) {
            ForEach(ChatReasoningPlacement.allCases) { choice in
                Text(choice.title).tag(choice)
            }
        } label: {
            placementLabel
        }
        .accessibilityIdentifier("settings.chat.reasoning-placement")

        Toggle(isOn: $staysOpen) { staysOpenLabel }
        .accessibilityIdentifier("settings.chat.reasoning-stays-open")
    }
}

/// Saved on this device only (`@AppStorage`), like the chat look; Chats reads it directly.
private struct ChatProjectToggle<Label: View>: View {
    @AppStorage(ChatLayoutPreferences.showsChatProjectKey)
    private var showsChatProject = ChatLayoutPreferences.showsChatProjectByDefault
    @ViewBuilder let label: Label

    var body: some View {
        Toggle(isOn: $showsChatProject) { label }
    }
}

/// Saved with the chat look (`@AppStorage`), which the message boxes read
/// directly. The on-screen keyboard's Return always adds a line.
private struct ReturnSendsToggle<Label: View>: View {
    @AppStorage(ChatLayoutPreferences.returnSendsKey) private var returnSends = true
    @ViewBuilder let label: Label

    var body: some View {
        Toggle(isOn: $returnSends) { label }
    }
}
