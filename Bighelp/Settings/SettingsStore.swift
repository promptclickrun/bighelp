import Foundation
import Observation

private struct SessionSectionPreferenceCatalog: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var preferencesByAccount: [String: [String: SessionSectionPreferences]]

    init(preferencesByAccount: [String: [String: SessionSectionPreferences]] = [:]) {
        schemaVersion = Self.currentSchemaVersion
        self.preferencesByAccount = preferencesByAccount
    }
}

@MainActor
@Observable
final class SettingsStore {
    private(set) var sessionSectionPreferencesRevision = 0

    var appearanceContext: BighelpAppearanceContext {
        BighelpAppearanceContext(
            appearance: appearance,
            lightBackground: lightBackground,
            darkBackground: darkBackground,
            bubbleColor: bubbleColor,
            customBubbleHex: customBubbleHex,
            windowTransparency: windowTransparency
        )
    }

    /// Appearance studio: light and dark page colors and the bubble color.
    var lightBackground: BighelpLightBackground {
        didSet { defaults.set(lightBackground.rawValue, forKey: Keys.lightBackground) }
    }

    var darkBackground: BighelpDarkBackground {
        didSet { defaults.set(darkBackground.rawValue, forKey: Keys.darkBackground) }
    }

    /// Nil is bighelp's own lavender.
    var bubbleColor: BighelpBubbleColor? {
        didSet { defaults.set(bubbleColor?.rawValue, forKey: Keys.bubbleColor) }
    }

    /// A color you picked yourself ("0E7C66"); wins over `bubbleColor`.
    var customBubbleHex: String? {
        didSet {
            let valid = BighelpCustomBubbleColor.validated(customBubbleHex)
            if valid != customBubbleHex { customBubbleHex = valid }
            defaults.set(valid, forKey: Keys.customBubbleColor)
        }
    }

    /// "Custom" or the built-in color's name.
    var bubbleColorName: String {
        customBubbleHex != nil ? "Custom" : (bubbleColor ?? .lavender).name
    }

    /// One of the built-in colors, replacing a custom one.
    func pickBubbleColor(_ color: BighelpBubbleColor) {
        // Lavender is the default, so it's stored as no choice.
        bubbleColor = color == .lavender ? nil : color
        customBubbleHex = nil
    }

    /// Vision Pro: how much of the room shows through the windows (0–1).
    var windowTransparency: Double {
        didSet { defaults.set(windowTransparency, forKey: Keys.windowTransparency) }
    }

    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    var autoSuggestionsEnabled: Bool {
        didSet { defaults.set(autoSuggestionsEnabled, forKey: Keys.autoSuggestions) }
    }

    var messageActionsEnabled: Bool {
        didSet { defaults.set(messageActionsEnabled, forKey: Keys.messageActions) }
    }

    var inlineUIEnabled: Bool {
        didSet { defaults.set(inlineUIEnabled, forKey: Keys.inlineUI) }
    }

    var voiceSpeed: VoiceSpeed {
        didSet { defaults.set(voiceSpeed.rawValue, forKey: Keys.voiceSpeed) }
    }

    var voiceMode: VoiceMode {
        didSet { defaults.set(voiceMode.rawValue, forKey: Keys.voiceMode) }
    }

    var voiceConversationMode: VoiceConversationMode {
        didSet { defaults.set(voiceConversationMode.rawValue, forKey: Keys.voiceConversationMode) }
    }

    /// TTS voice mode: where what you say becomes text.
    var voiceTranscription: VoiceTranscriptionSource {
        didSet { defaults.set(voiceTranscription.rawValue, forKey: Keys.voiceTranscription) }
    }

    /// Vision Pro: a quick pinch on the agent in the room talks or types.
    var spatialAvatarPinchAction: SpatialAvatarPinchAction {
        didSet { defaults.set(spatialAvatarPinchAction.rawValue, forKey: Keys.spatialAvatarPinchAction) }
    }

    var liveVoiceProvider: LiveVoiceProvider {
        didSet { defaults.set(liveVoiceProvider.rawValue, forKey: Keys.liveVoiceProvider) }
    }

    private(set) var codexLiveVoice: String {
        didSet { defaults.set(codexLiveVoice, forKey: Keys.codexLiveVoice) }
    }

    private(set) var apiLiveVoice: String {
        didSet { defaults.set(apiLiveVoice, forKey: Keys.apiLiveVoice) }
    }

    var offlineModeEnabled: Bool {
        didSet { defaults.set(offlineModeEnabled, forKey: Keys.offlineMode) }
    }

    /// Legacy app preference retained for migration compatibility. It is not
    /// presented as, or used as, writable iOS notification authorization.
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) }
    }

    var showReasoningByDefault: Bool {
        didSet { defaults.set(showReasoningByDefault, forKey: Keys.showReasoningByDefault) }
    }

    var showToolCallsByDefault: Bool {
        didSet { defaults.set(showToolCallsByDefault, forKey: Keys.showToolCallsByDefault) }
    }

    var chatActivityVisibility: ChatActivityVisibility {
        ChatActivityVisibility(
            showReasoning: showReasoningByDefault,
            showToolCalls: showToolCallsByDefault
        )
    }

    /// V3 is the only shipping interface. Legacy cases remain decodable so
    /// older preferences can be migrated without touching appearance data.
    var interfaceVersion: BighelpInterfaceVersion {
        get { .v3 }
        set {
            defaults.set(BighelpInterfaceVersion.v3.rawValue, forKey: Keys.interfaceVersion)
            defaults.set(true, forKey: Keys.uiV2Enabled)
        }
    }

    /// Compatibility projection for modern controls retained by V3.
    var uiV2Enabled: Bool {
        get { true }
        set {
            defaults.set(BighelpInterfaceVersion.v3.rawValue, forKey: Keys.interfaceVersion)
            defaults.set(true, forKey: Keys.uiV2Enabled)
        }
    }

    var reflectiveVisionEnabled: Bool {
        didSet { defaults.set(reflectiveVisionEnabled, forKey: Keys.reflectiveVision) }
    }

    var leftEdgeSwipeAction: WorkspaceSwipeAction {
        didSet { defaults.set(leftEdgeSwipeAction.rawValue, forKey: Keys.leftEdgeSwipeAction) }
    }

    var rightEdgeSwipeAction: WorkspaceSwipeAction {
        didSet { defaults.set(rightEdgeSwipeAction.rawValue, forKey: Keys.rightEdgeSwipeAction) }
    }

    var preferredBrowser: ChatBrowserPreference {
        didSet { defaults.set(preferredBrowser.rawValue, forKey: Keys.preferredBrowser) }
    }

    var midSessionChatBehavior: MidSessionChatBehavior {
        didSet { defaults.set(midSessionChatBehavior.rawValue, forKey: Keys.midSessionChatBehavior) }
    }

    var foldCompletedTurns: Bool {
        didSet { defaults.set(foldCompletedTurns, forKey: Keys.foldCompletedTurns) }
    }

    /// Reacting to an agent's message tells the agent, which may reply.
    var reactionsReachAgent: Bool {
        didSet { defaults.set(reactionsReachAgent, forKey: Keys.reactionsReachAgent) }
    }

    /// While an agent works, the Dynamic Island grows into its little stage.
    var agentIslandEnabled: Bool {
        didSet { defaults.set(agentIslandEnabled, forKey: Keys.agentIsland) }
    }

    var responseHapticsEnabled: Bool {
        didSet { defaults.set(responseHapticsEnabled, forKey: Keys.responseHaptics) }
    }

    var showProjectChanges: Bool {
        didSet { defaults.set(showProjectChanges, forKey: Keys.showProjectChanges) }
    }

    var organizeChatsByProjects: Bool {
        didSet { defaults.set(organizeChatsByProjects, forKey: Keys.organizeChatsByProjects) }
    }

    var showCronSessions: Bool {
        didSet { defaults.set(showCronSessions, forKey: Keys.showCronSessions) }
    }

    /// Reveals host administration (files, gateways, plugins, logs, ...) in Settings.
    /// Off by default so everyday use stays a simple messaging app.
    var nerdModeEnabled: Bool {
        didSet { defaults.set(nerdModeEnabled, forKey: Keys.nerdMode) }
    }

    /// The all-hosts view: every agent on every host in one list.
    var allHostsMode: Bool {
        didSet { defaults.set(allHostsMode, forKey: Keys.allHostsMode) }
    }

    /// Settings › Chat › Open on; nil until picked (the agent's latest chat).
    var landingScreen: BighelpLandingScreen? {
        didSet { defaults.set(landingScreen?.rawValue, forKey: BighelpLanding.screenKey) }
    }

    /// What this launch opens on, read once: a new pick applies next time.
    let launchLanding: BighelpLandingChoice

    /// Settings › Chat › Start with, per computer (`cacheScopeID` → agent ID).
    private(set) var startAgentIDs: [String: String]

    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        legacyThemeLogoDirectory: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.now = now
        Self.removeRetiredThemes(defaults: defaults,
                                 logoDirectory: legacyThemeLogoDirectory ?? Self.defaultLegacyThemeLogoDirectory)
        let recoveredReflectiveVisionActivation = ReflectiveVisionRecoveryMarker(
            defaults: defaults
        ).consumePendingActivation()
        appearance = AppAppearance(
            rawValue: defaults.string(forKey: Keys.appearance) ?? ""
        ) ?? .system
        autoSuggestionsEnabled = defaults.bool(
            forKey: Keys.autoSuggestions,
            default: true
        )
        messageActionsEnabled = defaults.bool(
            forKey: Keys.messageActions,
            default: true
        )
        inlineUIEnabled = defaults.bool(
            forKey: Keys.inlineUI,
            default: true
        )
        voiceSpeed = VoiceSpeed(
            rawValue: defaults.string(forKey: Keys.voiceSpeed) ?? ""
        ) ?? .normal
        voiceMode = VoiceMode(
            rawValue: defaults.string(forKey: Keys.voiceMode) ?? ""
        ) ?? .pressToTalk
        voiceConversationMode = VoiceConversationMode(
            rawValue: defaults.string(forKey: Keys.voiceConversationMode) ?? ""
        ) ?? .codexLive
        voiceTranscription = VoiceTranscriptionSource(
            rawValue: defaults.string(forKey: Keys.voiceTranscription) ?? ""
        ) ?? .onDevice
        spatialAvatarPinchAction = SpatialAvatarPinchAction(
            rawValue: defaults.string(forKey: Keys.spatialAvatarPinchAction) ?? ""
        ) ?? .talk
        liveVoiceProvider = LiveVoiceProvider(
            rawValue: defaults.string(forKey: Keys.liveVoiceProvider) ?? ""
        ) ?? .codexSubscription
        let savedCodexVoice = defaults.string(forKey: Keys.codexLiveVoice) ?? ""
        codexLiveVoice = LiveVoiceProvider.codexSubscription.voices.contains(savedCodexVoice)
            ? savedCodexVoice : LiveVoiceProvider.codexSubscription.defaultVoice
        let savedAPIVoice = defaults.string(forKey: Keys.apiLiveVoice) ?? ""
        apiLiveVoice = LiveVoiceProvider.apiKey.voices.contains(savedAPIVoice)
            ? savedAPIVoice : LiveVoiceProvider.apiKey.defaultVoice
        offlineModeEnabled = defaults.bool(
            forKey: Keys.offlineMode,
            default: false
        )
        notificationsEnabled = defaults.bool(
            forKey: Keys.notifications,
            default: true
        )
        showReasoningByDefault = defaults.bool(
            forKey: Keys.showReasoningByDefault,
            default: ChatActivityVisibility.default.showReasoning
        )
        showToolCallsByDefault = defaults.bool(
            forKey: Keys.showToolCallsByDefault,
            default: ChatActivityVisibility.default.showToolCalls
        )
        if defaults.object(forKey: Keys.interfaceVersion) != nil
            || defaults.object(forKey: Keys.uiV2Enabled) != nil {
            defaults.set(BighelpInterfaceVersion.v3.rawValue, forKey: Keys.interfaceVersion)
            defaults.set(true, forKey: Keys.uiV2Enabled)
        }
        reflectiveVisionEnabled = defaults.bool(
            forKey: Keys.reflectiveVision,
            default: false
        )
        if recoveredReflectiveVisionActivation {
            reflectiveVisionEnabled = false
            defaults.set(false, forKey: Keys.reflectiveVision)
        }
        let storedLeftEdgeSwipeAction = WorkspaceSwipeAction(
            rawValue: defaults.string(forKey: Keys.leftEdgeSwipeAction) ?? ""
        ) ?? .sessions
        let storedRightEdgeSwipeAction = WorkspaceSwipeAction(
            rawValue: defaults.string(forKey: Keys.rightEdgeSwipeAction) ?? ""
        ) ?? .newChat
        leftEdgeSwipeAction = storedLeftEdgeSwipeAction == .inbox
            ? .home
            : storedLeftEdgeSwipeAction
        rightEdgeSwipeAction = storedRightEdgeSwipeAction == .inbox
            ? .home
            : storedRightEdgeSwipeAction
        if storedLeftEdgeSwipeAction == .inbox {
            defaults.set(WorkspaceSwipeAction.home.rawValue, forKey: Keys.leftEdgeSwipeAction)
        }
        if storedRightEdgeSwipeAction == .inbox {
            defaults.set(WorkspaceSwipeAction.home.rawValue, forKey: Keys.rightEdgeSwipeAction)
        }
        preferredBrowser = ChatBrowserPreference(
            rawValue: defaults.string(forKey: Keys.preferredBrowser) ?? ""
        ) ?? .systemDefault
        midSessionChatBehavior = MidSessionChatBehavior(
            rawValue: defaults.string(forKey: Keys.midSessionChatBehavior) ?? ""
        ) ?? .steer
        foldCompletedTurns = defaults.bool(forKey: Keys.foldCompletedTurns, default: true)
        reactionsReachAgent = defaults.bool(forKey: Keys.reactionsReachAgent, default: true)
        lightBackground = defaults.string(forKey: Keys.lightBackground).flatMap(BighelpLightBackground.init(rawValue:)) ?? .cream
        darkBackground = defaults.string(forKey: Keys.darkBackground).flatMap(BighelpDarkBackground.init(rawValue:)) ?? .graphite
        bubbleColor = defaults.string(forKey: Keys.bubbleColor).flatMap(BighelpBubbleColor.init(rawValue:))
        customBubbleHex = BighelpCustomBubbleColor.validated(defaults.string(forKey: Keys.customBubbleColor))
        windowTransparency = defaults.object(forKey: Keys.windowTransparency) == nil
            ? BighelpVisionGlass.defaultTransparency
            : defaults.double(forKey: Keys.windowTransparency)
        agentIslandEnabled = defaults.bool(forKey: Keys.agentIsland, default: true)
        responseHapticsEnabled = defaults.bool(forKey: Keys.responseHaptics, default: true)
        showProjectChanges = defaults.bool(
            forKey: Keys.showProjectChanges,
            default: true
        )
        organizeChatsByProjects = defaults.bool(
            forKey: Keys.organizeChatsByProjects,
            default: true
        )
        showCronSessions = defaults.bool(
            forKey: Keys.showCronSessions,
            default: false
        )
        nerdModeEnabled = defaults.bool(forKey: Keys.nerdMode, default: false)
        allHostsMode = defaults.bool(forKey: Keys.allHostsMode, default: false)
        let landing = defaults.string(forKey: BighelpLanding.screenKey).flatMap(BighelpLandingScreen.init(rawValue:))
        landingScreen = landing
        let legacyOpensChat = defaults.object(forKey: BighelpLanding.legacyOpensChatKey) == nil
            ? nil : defaults.bool(forKey: BighelpLanding.legacyOpensChatKey)
        launchLanding = BighelpLanding.choice(screen: landing, legacyOpensChat: legacyOpensChat)
        startAgentIDs = (defaults.dictionary(forKey: BighelpLanding.startAgentKey) as? [String: String] ?? [:])
            .filter { $0.key.utf8.count <= Self.maximumStartAgentKeyLength && $0.value.utf8.count <= Self.maximumStartAgentKeyLength }
    }

    private static let maximumStartAgentKeyLength = 256

    /// The agent this computer opens with; nil is Automatic.
    func startAgentID(scope: String?) -> String? {
        scope.flatMap { startAgentIDs[$0] }
    }

    func setStartAgentID(_ id: String?, scope: String) {
        guard scope.utf8.count <= Self.maximumStartAgentKeyLength,
              (id?.utf8.count ?? 0) <= Self.maximumStartAgentKeyLength else { return }
        startAgentIDs[scope] = id
        defaults.set(startAgentIDs, forKey: BighelpLanding.startAgentKey)
    }

    /// A picked Open on decides, at launch, whether every computer's agents show.
    func applyLaunchLandingToAllHostsMode() {
        guard let on = BighelpLanding.allHostsMode(for: launchLanding), allHostsMode != on else { return }
        modeBeforeLaunchLanding = (allHostsMode, now())
        allHostsMode = on
    }

    /// A notification, widget or link that opened the app goes where it points, in the mode you
    /// were in: Open on decides only for a launch you started yourself. Only right after launch.
    func restoreAllHostsModeForOutsideOpen() {
        guard let before = modeBeforeLaunchLanding else { return }
        modeBeforeLaunchLanding = nil
        guard now().timeIntervalSince(before.at) < Self.outsideOpenWindow, allHostsMode != before.on else { return }
        allHostsMode = before.on
    }

    /// The switch as it was before Open on changed it at this launch.
    @ObservationIgnored private var modeBeforeLaunchLanding: (on: Bool, at: Date)?
    @ObservationIgnored private let now: () -> Date
    private static let outsideOpenWindow: TimeInterval = 30

    /// Themes (Nous, Superpilot and your own, with their logos) were replaced by
    /// bubble colors and light and dark backgrounds. Picking a bubble color
    /// quietly replaced a chosen theme anyway. Their saved data and logo files
    /// are removed once, so nothing is left taking up space.
    static func removeRetiredThemes(defaults: UserDefaults, logoDirectory: URL) {
        guard defaults.object(forKey: Keys.customThemes) != nil || defaults.object(forKey: Keys.themeID) != nil
                || FileManager.default.fileExists(atPath: logoDirectory.path) else { return }
        defaults.removeObject(forKey: Keys.customThemes)
        defaults.removeObject(forKey: Keys.themeID)
        try? FileManager.default.removeItem(at: logoDirectory)
    }

    static func eraseSessionSectionPreferences(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Keys.sessionSectionPreferences)
    }

    func sessionSectionPreferences(
        accountID: String?,
        hostID: String?
    ) -> SessionSectionPreferences {
        _ = sessionSectionPreferencesRevision
        guard let scope = sessionSectionScope(accountID: accountID, hostID: hostID) else {
            return SessionSectionPreferences()
        }
        return loadSessionSectionPreferenceCatalog()
            .preferencesByAccount[scope.accountID]?[scope.hostID]
            .map(Self.sanitized) ?? SessionSectionPreferences()
    }

    func sessionSectionLayout(
        accountID: String?,
        hostID: String?,
        availableProjectKeys: [SessionSectionKey]
    ) -> SessionSectionLayout {
        let preferences = sessionSectionPreferences(accountID: accountID, hostID: hostID)
        return SessionSectionLayout(
            projectOrder: SessionSectionLayout.orderedProjectKeys(
                savedOrder: preferences.projectOrder,
                availableKeys: availableProjectKeys
            ),
            collapsedSectionKeys: preferences.collapsedSectionKeys
        )
    }

    func setSessionSectionCollapsed(
        _ collapsed: Bool,
        sectionKey: SessionSectionKey,
        accountID: String?,
        hostID: String?
    ) {
        guard sectionKey.isReorderable else { return }
        updateSessionSectionPreferences(accountID: accountID, hostID: hostID) { preferences in
            if collapsed {
                preferences.collapsedSectionKeys.insert(sectionKey)
            } else {
                preferences.collapsedSectionKeys.remove(sectionKey)
            }
        }
    }

    func setSessionSectionOrder(
        _ reorderedKeys: [SessionSectionKey],
        accountID: String?,
        hostID: String?
    ) {
        updateSessionSectionPreferences(accountID: accountID, hostID: hostID) { preferences in
            preferences.projectOrder = SessionSectionLayout.preservingSavedKeys(
                reorderedKeys: reorderedKeys,
                savedOrder: preferences.projectOrder
            )
        }
    }

    func moveSessionSection(
        _ sectionKey: SessionSectionKey,
        direction: SessionSectionMoveDirection,
        availableProjectKeys: [SessionSectionKey],
        accountID: String?,
        hostID: String?
    ) {
        let layout = sessionSectionLayout(
            accountID: accountID,
            hostID: hostID,
            availableProjectKeys: availableProjectKeys
        )
        guard let index = layout.projectOrder.firstIndex(of: sectionKey) else { return }
        let destination = direction == .up ? index - 1 : index + 1
        guard layout.projectOrder.indices.contains(destination) else { return }
        moveSessionSection(
            sectionKey,
            to: layout.projectOrder[destination],
            availableProjectKeys: layout.projectOrder,
            accountID: accountID,
            hostID: hostID
        )
    }

    func moveSessionSection(
        _ sectionKey: SessionSectionKey,
        to targetKey: SessionSectionKey,
        availableProjectKeys: [SessionSectionKey],
        accountID: String?,
        hostID: String?
    ) {
        let layout = sessionSectionLayout(
            accountID: accountID,
            hostID: hostID,
            availableProjectKeys: availableProjectKeys
        )
        let reordered = SessionSectionLayout.moving(
            sectionKey,
            to: targetKey,
            in: layout.projectOrder
        )
        guard reordered != layout.projectOrder else { return }
        setSessionSectionOrder(
            reordered,
            accountID: accountID,
            hostID: hostID
        )
    }

    func liveVoice(for provider: LiveVoiceProvider) -> String {
        switch provider {
        case .codexSubscription: codexLiveVoice
        case .apiKey: apiLiveVoice
        }
    }

    func setLiveVoice(_ voice: String, for provider: LiveVoiceProvider) {
        guard provider.voices.contains(voice) else { return }
        switch provider {
        case .codexSubscription: codexLiveVoice = voice
        case .apiKey: apiLiveVoice = voice
        }
    }

}

private extension SettingsStore {
    static var defaultLegacyThemeLogoDirectory: URL {
        let arguments = ProcessInfo.processInfo.arguments
        let usesFixtures = arguments.contains("-disable-demo-delays")
            || arguments.contains("-use-demo-fixtures")
        return BighelpApplicationDataDirectories.active(fixtures: usesFixtures)
            .appending(path: "custom-theme-logos", directoryHint: .isDirectory)
    }

    private func sessionSectionScope(
        accountID: String?,
        hostID: String?
    ) -> (accountID: String, hostID: String)? {
        guard
            let accountID,
            let hostID,
            !accountID.isEmpty,
            !hostID.isEmpty,
            accountID.count <= 256,
            hostID.count <= 256
        else { return nil }
        return (accountID, hostID)
    }

    private func loadSessionSectionPreferenceCatalog() -> SessionSectionPreferenceCatalog {
        guard
            let data = defaults.data(forKey: Keys.sessionSectionPreferences),
            let catalog = try? JSONDecoder().decode(SessionSectionPreferenceCatalog.self, from: data),
            catalog.schemaVersion == SessionSectionPreferenceCatalog.currentSchemaVersion
        else { return SessionSectionPreferenceCatalog() }
        return catalog
    }

    private func updateSessionSectionPreferences(
        accountID: String?,
        hostID: String?,
        update: (inout SessionSectionPreferences) -> Void
    ) {
        guard let scope = sessionSectionScope(accountID: accountID, hostID: hostID) else { return }
        // An older app must not replace a newer or unreadable preference format.
        if let existing = defaults.data(forKey: Keys.sessionSectionPreferences) {
            guard let decoded = try? JSONDecoder().decode(SessionSectionPreferenceCatalog.self, from: existing),
                  decoded.schemaVersion == SessionSectionPreferenceCatalog.currentSchemaVersion else { return }
        }
        var catalog = loadSessionSectionPreferenceCatalog()
        var preferences = catalog.preferencesByAccount[scope.accountID]?[scope.hostID]
            .map(Self.sanitized) ?? SessionSectionPreferences()
        update(&preferences)
        preferences = Self.sanitized(preferences)
        var accountPreferences = catalog.preferencesByAccount[scope.accountID] ?? [:]
        accountPreferences[scope.hostID] = preferences
        catalog.preferencesByAccount[scope.accountID] = accountPreferences
        guard let encoded = try? JSONEncoder().encode(catalog) else { return }
        defaults.set(encoded, forKey: Keys.sessionSectionPreferences)
        sessionSectionPreferencesRevision &+= 1
    }

    private static func sanitized(
        _ preferences: SessionSectionPreferences
    ) -> SessionSectionPreferences {
        let maximumSectionCount = SessionCatalogStore.summaryRetentionLimit + 1
        var orderSeen = Set<SessionSectionKey>()
        let projectOrder = preferences.projectOrder.filter {
            $0.isReorderable && orderSeen.insert($0).inserted
        }.prefix(maximumSectionCount)
        let collapsed = preferences.collapsedSectionKeys
            .filter(\.isReorderable)
            .prefix(maximumSectionCount)
        return SessionSectionPreferences(
            projectOrder: Array(projectOrder),
            collapsedSectionKeys: Set(collapsed)
        )
    }

    enum Keys {
        static let appearance = "loopdy.demo.appearance"
        /// Retired with themes; removed at launch.
        static let themeID = "loopdy.appearance.theme"
        static let uiV2Enabled = "loopdy.appearance.ui-v2-enabled"
        static let interfaceVersion = "loopdy.appearance.interface-version"
        /// Retired with themes; removed at launch.
        static let customThemes = "loopdy.appearance.customThemes"
        static let autoSuggestions = "loopdy.demo.autoSuggestions"
        static let messageActions = "loopdy.demo.messageActions"
        static let inlineUI = "loopdy.demo.inlineUI"
        static let voiceSpeed = "loopdy.demo.voiceSpeed"
        static let voiceMode = "loopdy.voice.mode"
        static let voiceConversationMode = "loopdy.voice.conversation-mode"
        static let voiceTranscription = "bighelp.voice.transcription"
        static let spatialAvatarPinchAction = "bighelp.spatial-avatar.pinch-action"
        static let liveVoiceProvider = "loopdy.voice.live.provider"
        static let codexLiveVoice = "loopdy.voice.live.codex-voice"
        static let apiLiveVoice = "loopdy.voice.live.api-voice"
        static let offlineMode = "loopdy.demo.offlineMode"
        static let notifications = "loopdy.demo.notifications"
        static let showReasoningByDefault = "loopdy.chat.showReasoningByDefault"
        static let showToolCallsByDefault = "loopdy.chat.showToolCallsByDefault"
        static let reflectiveVision = "loopdy.appearance.reflectiveVision"
        static let leftEdgeSwipeAction = "loopdy.workspace.leftEdgeSwipeAction"
        static let rightEdgeSwipeAction = "loopdy.workspace.rightEdgeSwipeAction"
        static let preferredBrowser = "loopdy.chat.preferredBrowser"
        static let midSessionChatBehavior = "loopdy.chat.midSessionBehavior"
        static let foldCompletedTurns = "loopdy.chat.foldCompletedTurns"
        static let reactionsReachAgent = "loopdy.chat.reactionsReachAgent"
        static let agentIsland = "loopdy.chat.agentIsland"
        static let lightBackground = "loopdy.appearance.lightBackground"
        static let darkBackground = "loopdy.appearance.darkBackground"
        static let bubbleColor = "loopdy.appearance.bubbleColor"
        static let customBubbleColor = "loopdy.appearance.customBubbleColor"
        static let windowTransparency = "loopdy.appearance.windowTransparency"
        static let responseHaptics = "loopdy.chat.responseHaptics"
        static let showProjectChanges = "loopdy.chat.showProjectChanges"
        static let organizeChatsByProjects = "loopdy.sessions.organizeByProjects"
        static let showCronSessions = "loopdy.sessions.showCronSessions"
        static let nerdMode = "loopdy.settings.nerd-mode"
        static let allHostsMode = "bighelp.hosts.all-hosts"
        static let sessionSectionPreferences = "loopdy.sessions.section-preferences.v1"
    }
}

private extension UserDefaults {
    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        object(forKey: key) == nil ? defaultValue : bool(forKey: key)
    }
}
