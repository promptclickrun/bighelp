import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Bighelp

@MainActor
struct SettingsStoreTests {
    @Test func everyStoredLegacyInterfaceUsesV3WithoutChangingAppearanceBytes() throws {
        for version in ["v1", "v2", "v3", "future-version"] {
            let name = "ui-release-migration-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(version, forKey: "loopdy.appearance.interface-version")
            defaults.set(false, forKey: "loopdy.appearance.ui-v2-enabled")
            let previous = SettingsStore(defaults: defaults)
            previous.bubbleColor = .ocean
            previous.lightBackground = .paper
            previous.appearance = .dark
            defaults.set(version, forKey: "loopdy.appearance.interface-version")
            let before = defaults.dictionaryRepresentation().filter { $0.key.contains("appearance") && !$0.key.contains("interface") && !$0.key.contains("ui-v2") }
            let settings = SettingsStore(defaults: defaults)
            #expect(settings.interfaceVersion == .v3)
            #expect(settings.uiV2Enabled)
            #expect(settings.bubbleColor == .ocean)
            #expect(settings.lightBackground == .paper)
            #expect(settings.appearance == .dark)
            let after = defaults.dictionaryRepresentation().filter { $0.key.contains("appearance") && !$0.key.contains("interface") && !$0.key.contains("ui-v2") }
            #expect(NSDictionary(dictionary: before).isEqual(to: after))
        }
    }

    @Test func windowTransparencyPersistsAndStaysInRange() {
        let name = "window-transparency-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.windowTransparency == BighelpVisionGlass.defaultTransparency)
        settings.windowTransparency = 0.9
        #expect(SettingsStore(defaults: defaults).appearanceContext.windowTransparency == 0.9)
        // A launch argument arrives as text.
        defaults.set("0.25", forKey: "loopdy.appearance.windowTransparency")
        #expect(SettingsStore(defaults: defaults).windowTransparency == 0.25)

        // More transparent means less of the page color over the glass, never none or all of it.
        let solid = BighelpVisionGlass.canvasOpacity(forTransparency: 0)
        let clear = BighelpVisionGlass.canvasOpacity(forTransparency: 1)
        #expect(solid > BighelpVisionGlass.canvasOpacity(forTransparency: 0.5))
        #expect(BighelpVisionGlass.canvasOpacity(forTransparency: 0.5) > clear)
        #expect(clear > 0 && solid < 1)
        #expect(BighelpVisionGlass.canvasOpacity(forTransparency: 7) == clear)
        #expect(BighelpVisionGlass.canvasOpacity(forTransparency: -3) == solid)
        #expect(BighelpVisionGlass.canvasOpacity(forTransparency: .nan)
            == BighelpVisionGlass.canvasOpacity(forTransparency: BighelpVisionGlass.defaultTransparency))

        // A light window never goes bare: dark text needs a light backing in a dim room.
        let lightClear = BighelpVisionGlass.canvasOpacity(forTransparency: 1, dark: false)
        #expect(lightClear >= 0.4)
        #expect(BighelpVisionGlass.canvasOpacity(forTransparency: 0, dark: false) > lightClear)
    }

    @Test func invalidInterfaceVersionWithoutLegacyChoiceUsesV3() {
        let name = "ui-invalid-default-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("future-version", forKey: "loopdy.appearance.interface-version")
        #expect(SettingsStore(defaults: defaults).interfaceVersion == .v3)
    }

    @Test func explicitLegacyV1ChoiceMigratesToV3() {
        let name = "ui-legacy-v1-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "loopdy.appearance.ui-v2-enabled")
        #expect(SettingsStore(defaults: defaults).interfaceVersion == .v3)
    }

    @Test func appCompositionUsesV3WithoutAnInterfaceOverride() {
        let name = "ui-composition-default-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let composition = BighelpAppComposition(arguments: ["bighelp", "-use-demo-fixtures"], defaults: defaults)
        #expect(composition.settings.interfaceVersion == .v3)
        #expect(composition.settings.uiV2Enabled)
        #expect(defaults.object(forKey: "loopdy.appearance.interface-version") == nil)
        #expect(defaults.object(forKey: "loopdy.appearance.ui-v2-enabled") == nil)
    }

    @Test func storedV3SelectionEnablesModernPresentation() {
        let name = "ui-v3-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("v3", forKey: "loopdy.appearance.interface-version")
        #expect(SettingsStore(defaults: defaults).uiV2Enabled)
    }

    @Test func interfaceVersionsPersistAndMigrateWithoutChangingTheme() {
        let name = "ui-versions-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(SettingsStore(defaults: defaults).interfaceVersion == .v3)
        defaults.set(true, forKey: "loopdy.appearance.ui-v2-enabled")
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.interfaceVersion == .v3)
        let appearance = settings.appearanceContext
        for version in BighelpInterfaceVersion.allCases {
            settings.interfaceVersion = version
            let restored = SettingsStore(defaults: defaults)
            #expect(restored.interfaceVersion == .v3)
            #expect(restored.uiV2Enabled)
            #expect(restored.appearanceContext == appearance)
        }
        settings.uiV2Enabled = false
        #expect(settings.interfaceVersion == .v3)
        settings.uiV2Enabled = true
        #expect(settings.interfaceVersion == .v3)
    }

    @Test func invalidInterfaceVersionWithLegacyPreferenceUsesV3() {
        let name = "ui-invalid-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("future-version", forKey: "loopdy.appearance.interface-version")
        defaults.set(true, forKey: "loopdy.appearance.ui-v2-enabled")
        #expect(SettingsStore(defaults: defaults).interfaceVersion == .v3)
    }

    @Test func modernUIStaysEnabledAfterLegacySetters() {
        let name = "ui-v2-opt-in-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let original = SettingsStore(defaults: defaults)
        #expect(original.interfaceVersion == .v3)
        #expect(original.uiV2Enabled)
        original.uiV2Enabled = true
        #expect(SettingsStore(defaults: defaults).uiV2Enabled)
        original.uiV2Enabled = false
        #expect(SettingsStore(defaults: defaults).uiV2Enabled)
    }

    @Test func changingUIVersionPreservesThemeAndPreparedChatIdentity() {
        let name = "ui-v2-route-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let composition = BighelpAppComposition(arguments: ["bighelp", "-disable-demo-delays"], defaults: defaults)
        let route = AppRoute.chat(conversationID: "demo-finance")
        #expect(composition.featureStore.prepare(route))
        guard case .chat(let original) = composition.featureStore.preparedModel(for: route) else {
            Issue.record("Expected prepared chat"); return
        }
        let appearance = composition.settings.appearanceContext
        original.draft = "Keep this draft across interface changes."
        for version in BighelpInterfaceVersion.allCases {
            composition.settings.interfaceVersion = version
            guard case .chat(let current) = composition.featureStore.preparedModel(for: route) else {
                Issue.record("Interface switch discarded the active chat"); return
            }
            #expect(original === current)
            #expect(current.draft == "Keep this draft across interface changes.")
            #expect(composition.settings.appearanceContext == appearance)
        }
    }
    @Test func appCompositionDeclaresDirectFirstConnectivity() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let composition = BighelpAppComposition(
            arguments: ["bighelp", "-disable-demo-delays"],
            defaults: defaults
        )

        #expect(composition.workspaceConnectivity == .nativeOnly)
    }

    @Test func appCompositionAppearanceChangePreservesPreparedRouteIdentity() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let composition = BighelpAppComposition(
            arguments: ["bighelp", "-disable-demo-delays"],
            defaults: defaults
        )
        let route = AppRoute.chat(conversationID: "demo-finance")
        #expect(composition.featureStore.prepare(route))
        composition.appState.activateConversation(id: "demo-finance", source: .quickSwitch)
        guard case .chat(let chat) = composition.featureStore.preparedModel(for: route) else {
            Issue.record("Composition did not prepare its Chat route")
            return
        }
        let featureStore = composition.featureStore
        let path = composition.appState.path
        let itemIDs = chat.items.map(\.id)

        composition.settings.appearance = .dark

        #expect(composition.featureStore === featureStore)
        guard case .chat(let retainedChat) = composition.featureStore.preparedModel(for: route) else {
            Issue.record("Appearance change discarded the prepared Chat route")
            return
        }
        #expect(retainedChat === chat)
        #expect(retainedChat.items.map(\.id) == itemIDs)
        #expect(composition.appState.path == path)
    }

    @Test func appCompositionThemeChangeDoesNotRestartAccountOrWorkspaceState() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let composition = BighelpAppComposition(
            arguments: ["bighelp", "-use-demo-fixtures"],
            defaults: defaults
        )
        let route = AppRoute.chat(conversationID: "demo-finance")
        #expect(composition.featureStore.prepare(route))
        composition.appState.activateConversation(id: "demo-finance", source: .quickSwitch)
        let demoHosts = composition.demoHosts
        let featureStore = composition.featureStore
        let path = composition.appState.path

        composition.settings.bubbleColor = .rose

        #expect(composition.demoHosts === demoHosts)
        #expect(composition.featureStore === featureStore)
        #expect(composition.appState.path == path)
    }

    @Test func voiceModeDefaultsToPressToTalkAndPersistsWalkieTalkie() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = SettingsStore(defaults: defaults)
        #expect(initial.voiceMode == .pressToTalk)
        initial.voiceMode = .walkieTalkie

        let restored = SettingsStore(defaults: defaults)
        #expect(restored.voiceMode == .walkieTalkie)
    }

    @Test func appearancePersistsWithoutResettingRouteOrChatItemIdentities() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        let app = AppState()
        app.activateConversation(id: "demo-finance", source: .quickSwitch)
        let chat = ChatModel(
            conversationID: "demo-finance",
            client: ConversationFixtureClient()
        )
        let path = app.path
        let itemIDs = chat.items.map(\.id)

        settings.appearance = .dark

        let restored = SettingsStore(defaults: defaults)
        #expect(restored.appearance == .dark)
        #expect(app.path == path)
        #expect(chat.items.map(\.id) == itemIDs)
    }

    @Test func representativePreferencesPersistThroughInjectedDefaults() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        settings.autoSuggestionsEnabled = false
        settings.messageActionsEnabled = false
        settings.inlineUIEnabled = false
        settings.voiceSpeed = .fast
        settings.offlineModeEnabled = true
        settings.notificationsEnabled = false
        settings.showReasoningByDefault = true
        settings.showToolCallsByDefault = false
        settings.reflectiveVisionEnabled = true
        settings.bubbleColor = .teal
        settings.leftEdgeSwipeAction = .sessions
        settings.rightEdgeSwipeAction = .newChat
        settings.preferredBrowser = .firefox
        settings.midSessionChatBehavior = .queued
        settings.showProjectChanges = false

        let restored = SettingsStore(defaults: defaults)
        #expect(!restored.autoSuggestionsEnabled)
        #expect(!restored.messageActionsEnabled)
        #expect(!restored.inlineUIEnabled)
        #expect(restored.voiceSpeed == .fast)
        #expect(restored.offlineModeEnabled)
        #expect(!restored.notificationsEnabled)
        #expect(restored.showReasoningByDefault)
        #expect(!restored.showToolCallsByDefault)
        #expect(restored.reflectiveVisionEnabled)
        #expect(restored.bubbleColor == .teal)
        #expect(restored.leftEdgeSwipeAction == .sessions)
        #expect(restored.rightEdgeSwipeAction == .newChat)
        #expect(restored.preferredBrowser == .firefox)
        #expect(restored.midSessionChatBehavior == .queued)
        #expect(!restored.showProjectChanges)
    }

    @Test func projectChangesRailIsEnabledByDefault() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SettingsStore(defaults: defaults).showProjectChanges)
    }

    @Test func organizeChatsByProjectsIsOnByDefaultAndPersistsWhenTurnedOff() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        #expect(settings.organizeChatsByProjects)

        settings.organizeChatsByProjects = false

        #expect(!SettingsStore(defaults: defaults).organizeChatsByProjects)
    }

    @Test func midSessionChatBehaviorDefaultsToSteerAndOffersEveryHermesMode() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)

        // A tap on Send during a turn steers it; stopping the agent is a deliberate choice.
        #expect(settings.midSessionChatBehavior == .steer)
        #expect(MidSessionChatBehavior.allCases == [
            .steer,
            .queued,
            .interruptAndSend,
        ])
        #expect(MidSessionChatBehavior.allCases.map(\.title) == [
            "Steer",
            "Queued",
            "Interrupt and Send",
        ])
    }

    @Test func chatLinksUseTheSystemDefaultBrowserUntilTheUserSavesAChoice() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.preferredBrowser == .systemDefault)
    }

    @Test func browserListContainsOnlySystemDefaultAndSupportedInstalledBrowsers() {
        let available = ChatBrowserPreference.available { probeURL in
            ["googlechrome", "brave"].contains(probeURL.scheme)
        }

        #expect(available == [.systemDefault, .chrome, .brave])
    }

    @Test func browserRoutesPreserveTheOriginalWebDestination() throws {
        let original = try #require(URL(
            string: "https://loopdy.app/docs?q=link%20routing#settings"
        ))

        let chrome = try #require(ChatBrowserPreference.chrome.targetURL(for: original))
        #expect(chrome.scheme == "googlechromes")
        #expect(chrome.host == "loopdy.app")
        #expect(chrome.path == "/docs")
        #expect(chrome.query == "q=link%20routing")
        #expect(chrome.fragment == "settings")

        for browser in [ChatBrowserPreference.firefox, .brave] {
            let target = try #require(browser.targetURL(for: original))
            let components = try #require(URLComponents(
                url: target,
                resolvingAgainstBaseURL: false
            ))
            #expect(components.host == "open-url")
            #expect(components.queryItems == [
                URLQueryItem(name: "url", value: original.absoluteString)
            ])
        }

        #expect(ChatBrowserPreference.systemDefault.targetURL(for: original) == original)
        #expect(ChatBrowserPreference.chrome.targetURL(
            for: try #require(URL(string: "mailto:hello@loopdy.app"))
        ) == nil)
    }

    @Test func chatActivityVisibilityDefaultsPersistAndNewSessionsInheritThem() async throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        settings.showReasoningByDefault = true
        settings.showToolCallsByDefault = false
        let client = DemoSessionCatalogClient(records: [])
        let catalog = SessionCatalogStore(
            client: client,
            defaultActivityVisibility: { settings.chatActivityVisibility }
        )

        let created = try await catalog.createDirect(agentID: "default")

        #expect(created.activityVisibility == .init(
            showReasoning: true,
            showToolCalls: false
        ))
        #expect(catalog.session(id: created.id)?.activityVisibility == created.activityVisibility)
    }

    @Test func settingsMenuUsesFocusedSubsectionsInsteadOfOneLongForm() {
        #expect(SettingsMenuSection.allCases == [
            .appearance,
            .workspace,
            .agentsAndPersonalities,
            .chat,
            .voice,
            .notifications,
            .permissions,
            .connectivityAndNotifications,
            .companion,
            .help,
            .watch,
        ])
        #expect(Set(SettingsMenuSection.allCases.map(\.title)).count == 11)
        #expect(Set(SettingsMenuSection.allCases.map(\.accessibilityIdentifier)).count == 11)
    }

    @Test func currentEdgeGestureChoicesExcludeTheLegacyInboxDestination() {
        #expect(!WorkspaceSwipeAction.allCases.contains(.inbox))
    }

    @Test func persistedLegacyInboxEdgeGesturesMigrateToVisibleHomeRouting() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("inbox", forKey: "loopdy.workspace.leftEdgeSwipeAction")
        defaults.set("inbox", forKey: "loopdy.workspace.rightEdgeSwipeAction")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.leftEdgeSwipeAction.title == "Home")
        #expect(settings.rightEdgeSwipeAction.title == "Home")
        #expect(defaults.string(forKey: "loopdy.workspace.leftEdgeSwipeAction") == "home")
        #expect(defaults.string(forKey: "loopdy.workspace.rightEdgeSwipeAction") == "home")
    }

    @Test func reflectiveVisionIsOptInAndDoesNotChangeThemePreferences() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        settings.bubbleColor = .grape
        settings.appearance = .dark

        #expect(!settings.reflectiveVisionEnabled)

        settings.reflectiveVisionEnabled = true
        let restored = SettingsStore(defaults: defaults)

        #expect(restored.reflectiveVisionEnabled)
        #expect(restored.bubbleColor == .grape)
        #expect(restored.appearance == .dark)
    }

    @Test func reflectiveVisionMaterialRequiresOptInAnActiveCameraAndTransparency() {
        #expect(!ReflectiveVisionPresentationResolver.shouldRenderCamera(
            enabled: false,
            cameraIsActive: true,
            reduceTransparency: false
        ))
        #expect(!ReflectiveVisionPresentationResolver.shouldRenderCamera(
            enabled: true,
            cameraIsActive: false,
            reduceTransparency: false
        ))
        #expect(!ReflectiveVisionPresentationResolver.shouldRenderCamera(
            enabled: true,
            cameraIsActive: true,
            reduceTransparency: true
        ))
        #expect(ReflectiveVisionPresentationResolver.shouldRenderCamera(
            enabled: true,
            cameraIsActive: true,
            reduceTransparency: false
        ))
    }

    @Test func reflectiveVisionCoalescesRepeatedActivationRequestsAndAllowsFreshRelaunch() {
        var policy = ReflectiveVisionActivationPolicy()

        let firstActivation = policy.shouldReconcile(enabled: true, state: .off)
        #expect(firstActivation)
        let duplicateWhilePreparing = policy.shouldReconcile(enabled: true, state: .preparing)
        #expect(!duplicateWhilePreparing)
        let duplicateWhileActive = policy.shouldReconcile(enabled: true, state: .active)
        #expect(!duplicateWhileActive)
        let duplicateAfterFailure = policy.shouldReconcile(
            enabled: true,
            state: .unavailable(.permissionDenied)
        )
        #expect(!duplicateAfterFailure)
        let deactivation = policy.shouldReconcile(enabled: false, state: .active)
        #expect(deactivation)

        var relaunchedPolicy = ReflectiveVisionActivationPolicy()
        let relaunchedActivation = relaunchedPolicy.shouldReconcile(enabled: true, state: .off)
        #expect(relaunchedActivation)
    }

    @Test func reflectiveVisionRequestsCameraOnlyFromAnExplicitSettingAction() {
        #expect(!ReflectiveVisionPermissionPolicy.shouldRequest(
            enabled: true,
            authorization: .notDetermined,
            trigger: .lifecycle
        ))
        #expect(ReflectiveVisionPermissionPolicy.shouldRequest(
            enabled: true,
            authorization: .notDetermined,
            trigger: .explicitUserAction
        ))
        #expect(!ReflectiveVisionPermissionPolicy.shouldRequest(
            enabled: true,
            authorization: .authorized,
            trigger: .explicitUserAction
        ))
    }

    @Test func reflectiveVisionUnfinishedActivationDisablesOptInOnNextLaunch() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let marker = ReflectiveVisionRecoveryMarker(defaults: defaults)
        marker.markActivationStarted()
        defaults.set(true, forKey: "loopdy.appearance.reflectiveVision")

        let relaunchedSettings = SettingsStore(defaults: defaults)

        #expect(!relaunchedSettings.reflectiveVisionEnabled)
        #expect(!defaults.bool(forKey: "loopdy.appearance.reflectiveVision"))
        #expect(!marker.hasPendingActivation)
    }

    @Test func reflectiveVisionStableActivationClearsRecoveryMarker() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let marker = ReflectiveVisionRecoveryMarker(defaults: defaults)
        marker.markActivationStarted()
        #expect(marker.hasPendingActivation)

        marker.markActivationStabilized()

        #expect(!marker.hasPendingActivation)
    }

    @Test func reflectiveVisionUsesOneLowRateSharedFrameOutput() {
        #expect(ReflectiveVisionCaptureArchitecture.usesSingleOutput)
        #expect(ReflectiveVisionCaptureArchitecture.maximumFramesPerSecond == 6)
        #expect(ReflectiveVisionCaptureArchitecture.maximumFrameDimension <= 720)

        let store = ReflectiveVisionFrameStore()
        store.publish(Data([1]))
        let first = store.latest(after: 0)
        #expect(first?.data == Data([1]))

        store.publish(Data([2]))
        let latest = store.latest(after: first?.sequence ?? 0)
        #expect(latest?.data == Data([2]))
    }

    @Test func reflectiveVisionRecoveryWaitsForStableActiveRenderingBeforeClearing() {
        let activation = ReflectiveVisionActivationStability(generation: 7, startedAt: 10)

        #expect(!activation.canClearRecoveryMarker(
            at: 11.99,
            currentGeneration: 7,
            state: .active
        ))
        #expect(!activation.canClearRecoveryMarker(
            at: 12,
            currentGeneration: 8,
            state: .active
        ))
        #expect(!activation.canClearRecoveryMarker(
            at: 12,
            currentGeneration: 7,
            state: .preparing
        ))
        #expect(activation.canClearRecoveryMarker(
            at: 12,
            currentGeneration: 7,
            state: .active
        ))
    }

    @Test func edgeSwipeDefaultsAreUsefulWithoutSurprisingTheUser() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.leftEdgeSwipeAction == .sessions)
        #expect(settings.rightEdgeSwipeAction == .newChat)
    }

    @Test func explicitlySavedEdgeSwipeChoicesAreNeverReplacedByNewDefaults() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(WorkspaceSwipeAction.none.rawValue, forKey: "loopdy.workspace.leftEdgeSwipeAction")
        defaults.set(WorkspaceSwipeAction.quickWorkspace.rawValue, forKey: "loopdy.workspace.rightEdgeSwipeAction")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.leftEdgeSwipeAction == .none)
        #expect(settings.rightEdgeSwipeAction == .quickWorkspace)
        #expect(defaults.string(forKey: "loopdy.workspace.leftEdgeSwipeAction") == "none")
        #expect(defaults.string(forKey: "loopdy.workspace.rightEdgeSwipeAction") == "quickWorkspace")
    }

    @Test func invalidStoredEnumValuesFallBackSafely() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("infrared", forKey: "loopdy.demo.appearance")
        defaults.set("warp", forKey: "loopdy.demo.voiceSpeed")
        defaults.set("teleport", forKey: "loopdy.workspace.leftEdgeSwipeAction")
        defaults.set("obliterate", forKey: "loopdy.workspace.rightEdgeSwipeAction")
        defaults.set("missing-color", forKey: "loopdy.appearance.bubbleColor")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.appearance == .system)
        #expect(settings.voiceSpeed == .normal)
        #expect(settings.leftEdgeSwipeAction == .sessions)
        #expect(settings.rightEdgeSwipeAction == .newChat)
        #expect(settings.bubbleColor == nil)
    }

    @Test func aCustomBubbleColorIsSavedAndAPresetReplacesIt() {
        let suiteName = "custom-bubble-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.customBubbleHex == nil)
        settings.customBubbleHex = "#12ab34"
        #expect(settings.customBubbleHex == "12AB34")
        let restored = SettingsStore(defaults: defaults)
        #expect(restored.customBubbleHex == "12AB34")
        #expect(restored.appearanceContext.customBubbleHex == "12AB34")

        restored.pickBubbleColor(.ocean)
        #expect(restored.customBubbleHex == nil && restored.bubbleColor == .ocean)
        restored.pickBubbleColor(.lavender)
        #expect(restored.bubbleColor == nil)
        #expect(SettingsStore(defaults: defaults).customBubbleHex == nil)

        defaults.set("not-a-color", forKey: "loopdy.appearance.customBubbleColor")
        #expect(SettingsStore(defaults: defaults).customBubbleHex == nil)
    }

    /// Themes were replaced by bubble colors. A saved theme, its catalog and its
    /// logo files are removed at launch, and other appearance picks stay.
    @Test func retiredThemesAndTheirLogoFilesAreRemoved() throws {
        let suiteName = "retired-themes-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let logos = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: logos) }
        try FileManager.default.createDirectory(at: logos, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: logos.appending(path: "custom-theme-logo-1.png"))
        defaults.set("custom-6F64BA03", forKey: "loopdy.appearance.theme")
        defaults.set(Data("{\"schemaVersion\":2,\"themes\":[]}".utf8), forKey: "loopdy.appearance.customThemes")
        defaults.set("ocean", forKey: "loopdy.appearance.bubbleColor")

        let settings = SettingsStore(defaults: defaults, legacyThemeLogoDirectory: logos)

        #expect(defaults.object(forKey: "loopdy.appearance.theme") == nil)
        #expect(defaults.object(forKey: "loopdy.appearance.customThemes") == nil)
        #expect(!FileManager.default.fileExists(atPath: logos.path))
        #expect(settings.bubbleColor == .ocean)
    }

}
