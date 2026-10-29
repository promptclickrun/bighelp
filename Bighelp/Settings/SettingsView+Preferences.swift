import SwiftUI
import UIKit

extension SettingsView {
    /// Settings › Appearance: colors, light and dark, and the rest of the look on one page.
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
        Section("Chat list") {
            Toggle(isOn: $settings.organizeChatsByProjects) {
                settingLabel(
                    String(localized: "Organize chats by project"),
                    detail: String(localized: "Group chats by their Hermes project.")
                )
            }
            .accessibilityIdentifier("settings.organize-chats-by-projects")

            Toggle(isOn: $settings.showCronSessions) {
                settingLabel(
                    String(localized: "Show scheduled runs"),
                    detail: String(localized: "Include scheduled task runs in Chats.")
                )
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
            Text("Edge Gestures")
        } footer: {
            Text("Start right at the edge of the screen.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
        #endif
    }

    /// Where bighelp opens when it starts, and with which agent (`BighelpLanding`).
    private var landing: some View {
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
                settingLabel(String(localized: "Open on"), detail: screen.detail)
            }
            .accessibilityIdentifier("settings.landing.screen")

            if screen.offersStartAgent, let scope = landingScope, !agents.isEmpty {
                Picker(selection: Binding(get: { startAgentID },
                                          set: { settings.setStartAgentID($0, scope: scope) })) {
                    Text("Automatic").tag(String?.none)
                    ForEach(agents) { agent in
                        Text(agent.name).tag(Optional(agent.id))
                    }
                } label: {
                    settingLabel(String(localized: "Start with"), detail: startAgentID == nil
                                 ? String(localized: "The agent you used last.")
                                 : String(localized: "On this computer."))
                }
                .accessibilityIdentifier("settings.landing.agent")
            }
        } header: {
            Text("When bighelp opens")
        } footer: {
            Text("Links, widgets and notifications still open what they point to.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
    }

    private var chatBasics: some View {
        Section {
            Picker(selection: $settings.botChatExperience) {
                ForEach(BotChatExperience.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            } label: {
                settingLabel(String(localized: "Bot chat experience"), detail: settings.botChatExperience.detail)
            }
            .accessibilityIdentifier("settings.chat.bot-chat-experience")

            Picker(selection: $settings.chatWorkStyle) {
                ForEach(ChatWorkStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            } label: {
                settingLabel(String(localized: "Agent's work"), detail: settings.chatWorkStyle.detail)
            }
            .accessibilityIdentifier("settings.chat.work-style")

            #if !targetEnvironment(macCatalyst) // A Mac has no haptics.
            Toggle(isOn: $settings.responseHapticsEnabled) {
                settingLabel(
                    String(localized: "Response haptics"),
                    detail: String(localized: "A light tap as replies arrive.")
                )
            }
            .accessibilityIdentifier("settings.chat.response-haptics")
            #endif

            Toggle(isOn: $settings.reactionsReachAgent) {
                settingLabel(
                    String(localized: "Agents see your reactions"),
                    detail: String(localized: "Your agent sees them the next time you message it.")
                )
            }
            .accessibilityIdentifier("settings.chat.reactions-reach-agent")

            #if !targetEnvironment(macCatalyst) // The island is an iPhone's.
            Toggle(isOn: $settings.agentIslandEnabled) {
                settingLabel(
                    String(localized: "Agent in the Dynamic Island"),
                    detail: String(localized: "Watch your agent work at the top of the screen.")
                )
            }
            .accessibilityIdentifier("settings.chat.agent-island")
            #endif

            SessionTitleToggle {
                settingLabel(String(localized: "Session title"),
                             detail: String(localized: "Show the chat's title under the agent's name."))
            }
            .accessibilityIdentifier("settings.chat.session-title")

            ReturnSendsToggle {
                settingLabel(String(localized: "Return sends"), detail: Self.returnSendsDetail)
            }
            .accessibilityIdentifier("settings.chat.return-sends")
            .driveTarget("settings.chat.return-sends")
        }
        .listRowBackground(theme.surface)
    }

    private static var returnSendsDetail: String {
        #if targetEnvironment(macCatalyst)
        String(localized: "Shift-Return adds a line; Command-Return lets you pick how to send while your agent works.")
        #else
        String(localized: "With a keyboard attached. Shift-Return adds a line; Command-Return lets you pick how to send while your agent works.")
        #endif
    }

    /// Settings › Chat. Nerd Mode adds what chats show and how the chat list and
    /// edge swipes behave; everyday toggles stay first.
    var chatPage: some View {
        Form {
            BighelpDeferredSection { landing }
            BighelpDeferredSection { chatBasics }
            if settings.nerdModeEnabled {
                BighelpDeferredSection { chatDetailDefaults }
                BighelpDeferredSection { advancedChat }
                BighelpDeferredSection { workspace }
                BighelpDeferredSection { edgeGestures }
            }
        }
        .bighelpFormSurface()
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// How much of an agent's work chats show. Technical, so it appears
    /// with Nerd Mode's Advanced section rather than the basics.
    var chatDetailDefaults: some View {
        Section {
            Toggle(isOn: $settings.foldCompletedTurns) {
                settingLabel(
                    String(localized: "Fold finished turns"),
                    detail: String(localized: "Tuck finished work away; answers stay.")
                )
            }
            .accessibilityIdentifier("settings.chat.fold-completed-turns")

            Toggle(isOn: $settings.showReasoningByDefault) {
                settingLabel(
                    String(localized: "Show reasoning"),
                    detail: String(localized: "Thinking and notes between steps.")
                )
            }
            .accessibilityIdentifier("settings.chat.show-reasoning")

            Toggle(isOn: $settings.showToolCallsByDefault) {
                settingLabel(
                    String(localized: "Show tool calls"),
                    detail: String(localized: "Show the work trail.")
                )
            }
            .accessibilityIdentifier("settings.chat.show-tool-calls")
        } header: {
            Text("Chat details")
        } footer: {
            Text("Every chat shows these unless you change it in that chat's ••• menu.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
    }

    var advancedChat: some View {
        Group {
            Section {

                Toggle(isOn: $settings.autoSuggestionsEnabled) {
                    settingLabel(
                        String(localized: "Auto suggestions"),
                        detail: String(localized: "Show prompts that help begin a conversation.")
                    )
                }

                Toggle(isOn: $settings.messageActionsEnabled) {
                    settingLabel(
                        String(localized: "Message actions"),
                        detail: String(localized: "Keep actions available alongside messages.")
                    )
                }

                Toggle(isOn: $settings.inlineUIEnabled) {
                    settingLabel(
                        String(localized: "Inline UI"),
                        detail: String(localized: "Show supported weather, task, budget, and approval cards.")
                    )
                }

                Toggle(isOn: $settings.showProjectChanges) {
                    settingLabel(
                        String(localized: "Project changes"),
                        detail: String(localized: "Show file additions and deletions for a chat’s Hermes Project.")
                    )
                }
                .accessibilityIdentifier("settings.chat.show-project-changes")

                let availableBrowsers = ChatBrowserPreference.available(canOpenURL: UIApplication.shared.canOpenURL)
                Picker("Open links in", selection: Binding(
                    get: { availableBrowsers.contains(settings.preferredBrowser) ? settings.preferredBrowser : .systemDefault },
                    set: { settings.preferredBrowser = $0 }
                )) {
                    ForEach(availableBrowsers) { browser in
                        Label(browser.title, systemImage: browser.systemImage).tag(browser)
                    }
                }
                .accessibilityIdentifier("settings.chat.browser")

                Picker("While an agent is working", selection: $settings.midSessionChatBehavior) {
                    ForEach(MidSessionChatBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .accessibilityIdentifier("settings.chat.mid-session-behavior")
            } header: {
                Text("More chat options")
            } footer: {
                Text("Hold Send while an agent works to choose for just that message.")
                    .bighelpFont(.metadata)
            }
            .listRowBackground(theme.surface)
        }
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

/// Saved with the chat look (`@AppStorage`), which the message boxes read
/// directly. The on-screen keyboard's Return always adds a line.
private struct ReturnSendsToggle<Label: View>: View {
    @AppStorage(ChatLayoutPreferences.returnSendsKey) private var returnSends = true
    @ViewBuilder let label: Label

    var body: some View {
        Toggle(isOn: $returnSends) { label }
    }
}
