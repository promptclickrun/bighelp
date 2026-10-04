#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif
import SwiftUI
import UIKit
import WatchConnectivity

struct BighelpNotificationRuntimeSnapshot: Equatable, Sendable {
    let state: BighelpBuzzKitRuntime.State
    let providerReadiness: BighelpBuzzKitProviderReadiness?

    @MainActor
    static var current: Self {
        let runtime = BighelpBuzzKitRuntime.shared
        return Self(state: runtime.state, providerReadiness: runtime.providerReadiness)
    }

    var mayLoadPreferences: Bool {
        switch state {
        case .notConfigured, .failed:
            false
        case .configured, .identitySubmitted, .registered, .ready:
            true
        }
    }

}

@MainActor
struct BighelpNotificationSettingsView: View {
    let permissionCenter: PermissionCenter
    let hostRegistry: BighelpHostRegistry?
    let scope: String?
    let preferencesClient: BighelpBuzzKitPreferencesClient
    let runtimeSource: @MainActor () -> BighelpNotificationRuntimeSnapshot
    let refreshRuntime: (@MainActor () async throws -> BighelpNotificationRuntimeSnapshot)?
    let sendTest: (@MainActor () async throws -> BighelpNotificationTestReceipt)?
    let turnOff: BighelpNotificationTurnOff?
    let isCurrent: @MainActor () -> Bool

    @State private var preferences: [BighelpBuzzKitPreference] = []
    @State private var runtime: BighelpNotificationRuntimeSnapshot
    @State private var liveActivitiesEnabled = false
    @State private var notificationSetup: HostNotificationSetupModel?
    @State private var isLoading = false
    @State private var isRefreshingRuntime = false
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var savingTopicID: String?
    @State private var preferenceError: String?
    @State private var runtimeError: String?
    @State private var hasLoadedPreferences = false
    @State private var preferencesAreStale = false
    @State private var operationToken = UUID()
    @State private var isConfirmingTurnOff = false
    @AppStorage(BighelpPeerChatAlerts.key) private var peerChatAlerts = false
    @State private var turnOffStep: BighelpNotificationTurnOffStep?
    @State private var turnOffMessage: String?
    @State private var turnOffFailed = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    init(
        permissionCenter: PermissionCenter,
        hostRegistry: BighelpHostRegistry? = nil,
        scope: String? = nil,
        preferencesClient: BighelpBuzzKitPreferencesClient = BighelpBuzzKitPreferencesClient(),
        runtimeSource: @escaping @MainActor () -> BighelpNotificationRuntimeSnapshot = {
            .current
        },
        refreshRuntime: (@MainActor () async throws -> BighelpNotificationRuntimeSnapshot)? = nil,
        sendTest: (@MainActor () async throws -> BighelpNotificationTestReceipt)? = nil,
        turnOff: BighelpNotificationTurnOff? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) {
        self.permissionCenter = permissionCenter
        self.hostRegistry = hostRegistry
        self.scope = scope
        self.preferencesClient = preferencesClient
        self.runtimeSource = runtimeSource
        self.refreshRuntime = refreshRuntime
        self.sendTest = sendTest
        self.turnOff = turnOff
        self.isCurrent = isCurrent
        _runtime = State(initialValue: runtimeSource())
        if let hostRegistry, let host = hostRegistry.selectedHost {
            _notificationSetup = State(initialValue: HostNotificationSetupModel(host: host, registry: hostRegistry))
        } else {
            _notificationSetup = State(initialValue: nil)
        }
    }

    var body: some View {
        Form {
            notificationEnrollmentSection
            notificationAuthorizationSection
            #if !os(visionOS) && !targetEnvironment(macCatalyst)
            liveActivitiesSection // Vision Pro and the Mac have no Live Activities.
            #endif
            if let sendTest {
                Section("Test") {
                    Button(isTesting ? "Sending Test…" : "Send Test Notification") {
                        Task {
                            guard isCurrent(), !isTesting else { return }
                            let token = operationToken
                            isTesting = true
                            defer { if token == operationToken { isTesting = false } }
                            do {
                                let receipt = try await sendTest()
                                guard isCurrent(), token == operationToken else { return }
                                testMessage = receipt.state == .accepted
                                    ? "Test sent. Check your notifications."
                                    : "Test failed. Try again."
                            } catch {
                                guard isCurrent(), token == operationToken else { return }
                                testMessage = "Couldn't confirm the test. Check your notifications before retrying."
                            }
                        }
                    }
                    .disabled(isTesting || !isCurrent())
                    .accessibilityIdentifier("settings.notifications.send-test")
                    if let testMessage { Text(testMessage).font(.bighelp(.footnote)) }
                }
            }
            topicsSection
            turnOffSection
            Section("Advanced") {
                DisclosureGroup("Provider details") {
                    providerSection
                }
                .accessibilityIdentifier("settings.notifications.details")
            }
        }
        .bighelpFormSurface()
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.notifications")
        .confirmationDialog("Turn off notifications?", isPresented: $isConfirmingTurnOff, titleVisibility: .visible) {
            Button("Turn Off Notifications", role: .destructive) {
                Task { await runTurnOff() }
            }
            .accessibilityIdentifier("settings.notifications.turn-off.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This device stops getting notifications from bighelp. Its notification data is deleted from bighelp's notification service and from every computer that sends it notifications. You can turn them on again later.")
        }
        .task(id: presentationScope) {
            configureNotificationSetup()
            await reloadAll()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                notificationSetup?.cancel()
                operationToken = UUID()
                return
            }
            Task {
                await permissionCenter.refresh(.notification)
                liveActivitiesEnabled = Self.liveActivitiesAllowed
            }
        }
        .onDisappear {
            notificationSetup?.cancel()
            operationToken = UUID()
        }
    }

    @ViewBuilder
    private var notificationEnrollmentSection: some View {
        if let hostRegistry,
           let host = hostRegistry.selectedHost,
           let notificationSetup,
           notificationSetup.hostID == host.id {
            HostNotificationSetupSection(
                model: notificationSetup,
                hostName: host.name,
                hostEndpoint: host.endpoint.identity,
                onCompletion: {
                    guard scenePhase == .active else { return }
                    runtime = runtimeSource()
                    await permissionCenter.refresh(.notification)
                    if runtime.mayLoadPreferences { await reloadPreferences() }
                }
            )
        } else {
            Section {
                Text("Connect a computer to enable notifications.")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.notifications.no-selected-host")
            }
            .listRowBackground(theme.surface)
        }
    }

    @ViewBuilder
    private var turnOffSection: some View {
        if let turnOff, turnOffStep != nil || turnOffMessage != nil || turnOff.isAvailable()
            || !turnOff.hostsAwaitingCleanup().isEmpty {
            Section {
                if let turnOffStep {
                    HStack(spacing: BighelpTokens.space12) {
                        ProgressView()
                        Text(Self.progressText(turnOffStep))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.notifications.turn-off.progress")
                } else if turnOff.isAvailable() {
                    Button(role: .destructive) {
                        isConfirmingTurnOff = true
                    } label: {
                        Text("Turn Off Notifications")
                            .frame(minHeight: BighelpTokens.hitTarget)
                    }
                    // Every host and this device, so it doesn't wait on the
                    // current connection; an offline host is finished later.
                    .accessibilityIdentifier("settings.notifications.turn-off")
                }
                if let message = turnOffMessage ?? awaitingCleanupMessage(turnOff) {
                    Text(message)
                        .bighelpFont(.metadata)
                        .foregroundStyle(turnOffFailed ? theme.warning : theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.notifications.turn-off.result")
                }
            } footer: {
                if turnOffStep == nil, turnOffMessage == nil || turnOffFailed {
                    Text("Deletes this device's notification data everywhere, as if you never turned notifications on.")
                }
            }
            .listRowBackground(theme.surface)
        }
    }

    private static func progressText(_ step: BighelpNotificationTurnOffStep) -> String {
        switch step {
        case .hosts: "Removing this device from your computers…"
        case .service: "Deleting it from the notification service…"
        case .device: "Deleting notification data on this device…"
        }
    }

    private func awaitingCleanupMessage(_ turnOff: BighelpNotificationTurnOff) -> String? {
        let hosts = turnOff.hostsAwaitingCleanup()
        guard !hosts.isEmpty else { return nil }
        return "Notifications are off. \(Self.list(hosts)) still \(hosts.count == 1 ? "has" : "have") a copy of this device's notification data. It can't send you anything, and bighelp removes it the next time it can reach \(hosts.count == 1 ? "it" : "them")."
    }

    private static func list(_ names: [String]) -> String {
        names.count < 3 ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    private func runTurnOff() async {
        guard let turnOff, turnOffStep == nil else { return }
        notificationSetup?.cancel()
        operationToken = UUID()
        turnOffMessage = nil
        turnOffFailed = false
        turnOffStep = .hosts
        do {
            let result = try await turnOff.run { step in turnOffStep = step }
            turnOffStep = nil
            if result.unreachableHosts.isEmpty {
                turnOffMessage = "Notifications are off, and this device's notification data was deleted. To stop bighelp asking iOS for alerts too, turn them off in iOS Settings."
            } else {
                turnOffMessage = awaitingCleanupMessage(turnOff)
                    ?? "Notifications are off. Some computers couldn't be reached yet; bighelp will finish there later."
            }
        } catch {
            turnOffStep = nil
            turnOffFailed = true
            turnOffMessage = "Couldn't reach the notification service, so notifications aren't fully off yet. Check your connection and try again."
        }
        configureNotificationSetup()
        await reloadAll()
    }

    private var notificationAuthorizationSection: some View {
        Section(Self.systemNotificationsTitle) {
            PermissionRow(center: permissionCenter, kind: .notification)
            if permissionCenter.status(for: .notification).authorization != .notDetermined {
                Button("Open Notification Settings") {
                    openAppSettings()
                }
                .accessibilityIdentifier("settings.notifications.open-system-settings")
            }
        }
        .listRowBackground(theme.surface)
    }

    private static var systemNotificationsTitle: String {
        #if targetEnvironment(macCatalyst)
        "Mac notifications"
        #else
        "iOS notifications"
        #endif
    }

    private static var liveActivitiesAllowed: Bool {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        false
        #endif
    }

    private var liveActivitiesSection: some View {
        Section("Live Activities") {
            HStack(alignment: .top, spacing: BighelpTokens.space12) {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(liveActivitiesEnabled ? theme.success : theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text("Live Activities")
                        .bighelpFont(.body, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                    Text(liveActivitiesEnabled ? "Allowed by iOS" : "Off in iOS Settings")
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: BighelpTokens.space8)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Live Activities")
            .accessibilityValue(liveActivitiesEnabled ? "Allowed by iOS" : "Off in iOS Settings")
            .accessibilityIdentifier("settings.notifications.live-activities-status")

            Button("Open Live Activities Settings") {
                openAppSettings()
            }
            .accessibilityIdentifier("settings.notifications.live-activities-settings")
        }
        .listRowBackground(theme.surface)
    }

    private var providerSection: some View {
        Group {
            LabeledContent("Device registration", value: runtimeStateTitle)
            Text(runtimeStateDetail)
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Optional diagnostics", value: providerStatusTitle)
            Text(providerStatusDetail)
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let refreshRuntime {
                Button {
                    Task { await refreshProvider(using: refreshRuntime) }
                } label: {
                    Label(
                        isRefreshingRuntime ? "Checking…" : "Check Provider Diagnostics",
                        systemImage: "arrow.clockwise"
                    )
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
                .disabled(isRefreshingRuntime || !isCurrent())
                .accessibilityIdentifier("settings.notifications.refresh-provider")
            }
            if let runtimeError {
                Text(runtimeError)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.notifications.runtime-error")
            }
        }
        .listRowBackground(theme.surface)
    }

    private var topicsSection: some View {
        Section {
            ForEach(BighelpBuzzKitTopic.allCases, id: \.rawValue) { topic in
                if let preference = preference(for: topic) {
                    Toggle(isOn: Binding(
                        get: { self.preference(for: topic)?.enabled ?? false },
                        set: { enabled in set(topic, enabled: enabled) }
                    )) {
                        topicLabel(preference: preference, topic: topic)
                    }
                    .disabled(isLoading || savingTopicID != nil || !isCurrent())
                    .accessibilityValue(preference.enabled ? "On" : "Off")
                    .accessibilityIdentifier("settings.notifications.topic.\(topic.rawValue)")
                } else {
                    HStack(alignment: .top, spacing: BighelpTokens.space12) {
                        topicLabel(preference: nil, topic: topic)
                        Spacer(minLength: BighelpTokens.space8)
                        Text(hasLoadedPreferences ? "Unavailable" : "Not loaded")
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.notifications.topic.\(topic.rawValue)")
                }
            }

            Toggle(isOn: $peerChatAlerts) {
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text("Peer chats")
                        .bighelpFont(.body)
                        .foregroundStyle(theme.primaryText)
                    Text("When your agents message each other with hermes peer. Questions and approvals still notify you.")
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, BighelpTokens.space4)
            }
            .onChange(of: peerChatAlerts) { _, _ in
                Task { await hostRegistry?.notificationSetup?.applyPeerChatPreference() }
            }
            .accessibilityValue(peerChatAlerts ? "On" : "Off")
            .accessibilityIdentifier("settings.notifications.peer-chats")

            if isLoading {
                ProgressView("Loading notification topics…")
                    .accessibilityIdentifier("settings.notifications.topics-loading")
            }

            if preferencesAreStale {
                Text("Refresh before making another change.")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let preferenceError {
                Text(preferenceError)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.notifications.topics-error")
            }

            Button {
                Task { await reloadPreferences() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .frame(minHeight: BighelpTokens.hitTarget)
            }
            .disabled(isLoading || savingTopicID != nil || !runtime.mayLoadPreferences || !isCurrent())
            .accessibilityIdentifier("settings.notifications.reload-topics")
        } header: {
            Text("Notify Me About")
        }
        .listRowBackground(theme.surface)
    }

    private func topicLabel(
        preference: BighelpBuzzKitPreference?,
        topic: BighelpBuzzKitTopic
    ) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            Text(preference?.name ?? topic.fallbackName)
                .bighelpFont(.body)
                .foregroundStyle(theme.primaryText)

            if savingTopicID == topic.rawValue {
                Text("Saving…")
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.action)
            }
        }
        .padding(.vertical, BighelpTokens.space4)
    }

    private func statusRow(
        title: String,
        value: String,
        systemImage: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: systemImage)
                .foregroundStyle(theme.secondaryText)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(title)
                    .bighelpFont(.body, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                Text(value)
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                Text(detail)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private func reloadAll() async {
        let token = UUID()
        operationToken = token
        preferences = []
        hasLoadedPreferences = false
        preferencesAreStale = false
        preferenceError = nil
        isLoading = false
        isRefreshingRuntime = false
        savingTopicID = nil
        runtimeError = nil
        await permissionCenter.refresh(.notification)
        guard operationToken == token, !Task.isCancelled else { return }
        liveActivitiesEnabled = Self.liveActivitiesAllowed
        runtime = runtimeSource()
        guard operationToken == token, !Task.isCancelled else { return }
        guard isCurrent() else {
            hasLoadedPreferences = false
            preferenceError = nil
            return
        }
        guard runtime.mayLoadPreferences else {
            hasLoadedPreferences = false
            preferenceError = nil
            return
        }
        await loadPreferences(token: token)
    }

    private func reloadPreferences() async {
        let token = operationToken
        guard owns(token), runtime.mayLoadPreferences else { return }
        await loadPreferences(token: token)
    }

    private func loadPreferences(token: UUID) async {
        guard !isLoading, savingTopicID == nil else { return }
        isLoading = true
        preferenceError = nil
        defer {
            if operationToken == token { isLoading = false }
        }
        do {
            let loaded = try await preferencesClient.load()
            guard owns(token) else { return }
            preferences = try validatedPreferences(loaded)
            hasLoadedPreferences = true
            preferencesAreStale = false
        } catch is CancellationError {
            return
        } catch {
            guard owns(token) else { return }
            preferencesAreStale = !preferences.isEmpty
            preferenceError = preferences.isEmpty
                ? "Couldn't load your notification preferences. Try again."
                : "Couldn't refresh your preferences."
        }
    }

    private func set(_ topic: BighelpBuzzKitTopic, enabled: Bool) {
        guard savingTopicID == nil, !isLoading, isCurrent(),
              let index = preferences.firstIndex(where: { $0.id == topic.rawValue }) else { return }
        let token = operationToken
        let original = preferences
        let value = preferences[index]
        preferences[index] = BighelpBuzzKitPreference(
            id: value.id,
            name: value.name,
            detail: value.detail,
            category: value.category,
            enabled: enabled,
            isDefault: value.isDefault
        )
        savingTopicID = topic.rawValue
        preferenceError = nil
        preferencesAreStale = false
        Task {
            defer {
                if operationToken == token { savingTopicID = nil }
            }
            do {
                let updated = try await preferencesClient.set(topic, enabled: enabled)
                guard owns(token) else { return }
                let validated = try validatedPreferences(updated)
                guard validated.first(where: { $0.id == topic.rawValue })?.enabled == enabled else {
                    throw BighelpNotificationSettingsError.inconsistentPreferenceResponse
                }
                preferences = validated
                hasLoadedPreferences = true
            } catch is CancellationError {
                return
            } catch {
                guard owns(token) else { return }
                preferences = original
                preferencesAreStale = true
                preferenceError = "Couldn't confirm the change. Refresh before trying again."
            }
        }
    }

    private func refreshProvider(
        using refresh: @MainActor () async throws -> BighelpNotificationRuntimeSnapshot
    ) async {
        guard !isRefreshingRuntime, isCurrent() else { return }
        let token = operationToken
        isRefreshingRuntime = true
        runtimeError = nil
        defer {
            if operationToken == token { isRefreshingRuntime = false }
        }
        do {
            let refreshed = try await refresh()
            guard owns(token) else { return }
            runtime = refreshed
        } catch is CancellationError {
            return
        } catch {
            guard owns(token) else { return }
            runtime = runtimeSource()
            runtimeError = "Couldn't check optional provider diagnostics."
        }
    }


    private func validatedPreferences(
        _ values: [BighelpBuzzKitPreference]
    ) throws -> [BighelpBuzzKitPreference] {
        let known = Set(BighelpBuzzKitTopic.allCases.map(\.rawValue))
        guard values.count == known.count,
              Set(values.map(\.id)) == known else {
            throw BighelpNotificationSettingsError.inconsistentPreferenceResponse
        }
        let byID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        return BighelpBuzzKitTopic.allCases.compactMap { byID[$0.rawValue] }
    }

    private func preference(for topic: BighelpBuzzKitTopic) -> BighelpBuzzKitPreference? {
        preferences.first { $0.id == topic.rawValue }
    }

    private func owns(_ token: UUID) -> Bool {
        operationToken == token && isCurrent() && !Task.isCancelled
    }

    private func configureNotificationSetup() {
        notificationSetup?.cancel()
        guard let hostRegistry, let host = hostRegistry.selectedHost else {
            notificationSetup = nil
            return
        }
        notificationSetup = HostNotificationSetupModel(host: host, registry: hostRegistry)
    }

    private var presentationScope: String {
        [
            scope ?? "notification-settings-unscoped",
            hostRegistry?.generation.uuidString ?? "no-registry",
            hostRegistry?.selectedHostID?.uuidString ?? "no-host",
        ].joined(separator: ":")
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private var runtimeStateTitle: String {
        switch runtime.state {
        case .notConfigured: "Not configured"
        case .configured: "Not confirmed"
        case .identitySubmitted: "Identity active"
        case .registered: "Registered"
        case .ready: "Registered"
        case .failed: "Needs attention"
        }
    }

    private var runtimeStateDetail: String {
        switch runtime.state {
        case .notConfigured(let reason):
            "BuzzKit has not started (\(reason))."
        case .configured:
            "BuzzKit is configured. This screen has not observed an exact registration receipt in this process."
        case .identitySubmitted:
            "The restricted notification identity is active. An exact device registration receipt has not been observed in this process."
        case .registered:
            "BuzzKit returned a receipt matching this iPhone's exact APNs token, notification identity, and push environment."
        case .ready(_, let activePushRegistrations):
            "Optional provider diagnostics also matched this iPhone token and environment (\(activePushRegistrations) current registration)."
        case .failed(let code):
            "BuzzKit reported a local runtime failure (\(code))."
        }
    }

    private var providerStatusTitle: String {
        guard let readiness = runtime.providerReadiness else { return "Not run" }
        if case .ready = runtime.state { return "Passed" }
        if !readiness.subscriber.identified { return "Subscriber not found" }
        if !readiness.subscriber.verified { return "Subscriber identity unverified" }
        guard let current = readiness.subscriber.currentDevice, current.matched,
              current.enabled, current.active else { return "Current device registration not found" }
        if readiness.pushCredentials.contains(where: { $0.status == "invalid" }) {
            return "Credentials need attention"
        }
        if !readiness.pushCredentials.contains(where: { $0.status == "active" }) {
            return "Credentials not validated"
        }
        return "Provider setup mismatch"
    }

    private var providerStatusDetail: String {
        guard let readiness = runtime.providerReadiness else {
            return "Not required to enable notifications. Run this only when diagnosing provider delivery setup."
        }
        let active = readiness.pushCredentials.filter { $0.status == "active" }.count
        let invalid = readiness.pushCredentials.filter { $0.status == "invalid" }.count
        let current = readiness.subscriber.currentDevice
        let currentStatus = current.map { "exact device \($0.matched && $0.enabled && $0.active ? "active" : "not active") in \($0.environment)" }
            ?? "exact device not checked"
        return "Provider response: \(active) active, \(invalid) invalid, \(readiness.pushCredentials.count - active - invalid) unvalidated; \(currentStatus); \(readiness.topicSlugs.count) required topics. This optional read is neither enrollment authority nor a delivery receipt."
    }

    @BighelpThemeReader private var theme

}

private enum BighelpNotificationSettingsError: Error {
    case inconsistentPreferenceResponse
}

private extension BighelpBuzzKitTopic {
    var fallbackName: String {
        switch self {
        case .chatRepliesAndCompletions: "Chat replies and completions"
        case .scheduledTasksAndDeliveries: "Scheduled tasks and deliveries"
        case .questionsAndApprovals: "Questions and Approvals"
        case .subagentCompletions: "Subagent Completions"
        }
    }

    var fallbackDetail: String {
        switch self {
        case .chatRepliesAndCompletions:
            "Final chat replies and reported chat failures."
        case .scheduledTasksAndDeliveries:
            "Completed or failed scheduled Hermes work and its delivery result."
        case .questionsAndApprovals:
            "Questions that need an answer and operations that need approval."
        case .subagentCompletions:
            "Completed or failed delegated subagent work."
        }
    }
}

@MainActor
struct BighelpPluginCapabilitiesSection: View {
    let connections: WorkspaceConnectionStore?
    let permissionCenter: PermissionCenter
    /// Off when the plugin's version section is already on the page.
    var showsPluginSummary = true

    var body: some View {
        Section {
            if showsPluginSummary {
                capabilityRow(
                    title: "bighelp plugin",
                    systemImage: "puzzlepiece.extension",
                    status: pluginStatus,
                    detail: pluginDetail
                )
            }
            DisclosureGroup("Plugin features") {
                capabilityRow(
                    title: "Rich cards",
                    systemImage: "rectangle.stack",
                    capability: .cards
                )
                capabilityRow(
                    title: "Notification channel",
                    systemImage: "bell.and.waves.left.and.right",
                    capability: .cloudNotifications
                )
                deviceCapabilityRow(.health, title: "Apple Health", systemImage: "heart")
                deviceCapabilityRow(.calendar, title: "Calendar", systemImage: "calendar")
                deviceCapabilityRow(.reminders, title: "Reminders", systemImage: "checklist")
                deviceCapabilityRow(.location, title: "Location", systemImage: "location")
                watchCapabilityRow
            }
            .accessibilityIdentifier("settings.plugin-capability.details")
        }
        .listRowBackground(theme.surface)
    }

    private var pluginStatus: String {
        guard let connections, let owner = connections.owner else { return "Not connected" }
        guard connections.capabilities.owner == owner else { return "Not verified" }
        guard connections.workspace?.nativeContext != nil else { return "Not verified" }
        return "Connected"
    }

    private var pluginDetail: String {
        guard let connections, let owner = connections.owner else {
            return "Connect a computer to check its plugin."
        }
        guard connections.capabilities.owner == owner else {
            return "Waiting for this computer."
        }
        guard let context = connections.workspace?.nativeContext else {
            return "Plugin status not checked."
        }
        return "Version \(context.pluginVersion)"
    }

    private func capabilityRow(
        title: String,
        systemImage: String,
        capability: WorkspaceCapability
    ) -> some View {
        let presentation = presentation(for: capability)
        return capabilityRow(
            title: title,
            systemImage: systemImage,
            status: presentation.status,
            detail: presentation.detail
        )
    }

    private func deviceCapabilityRow(
        _ deviceCapability: DeviceToolCapability,
        title: String,
        systemImage: String
    ) -> some View {
        let host = presentation(for: .phoneTools)
        let status: String
        let detail: String
        if host.isAvailable {
            if permissionCenter.deviceTools.scope == nil {
                status = "Available · iPhone not bound"
                detail = "The host reports phone tools, but this iPhone has no current host-scoped device grant."
            } else if permissionCenter.deviceTools.isEnabled(deviceCapability) {
                status = "Enabled on this iPhone"
                detail = deviceAccessDetail(deviceCapability)
            } else {
                status = "Available · Off"
                detail = "The host reports phone tools. Access remains off for this iPhone and selected host."
            }
        } else {
            status = "\(host.status) · \(iosAccessStatus(deviceCapability))"
            detail = "\(host.detail) \(iosAccessDetail(deviceCapability)) Install or activate the host feature first, then grant this protected iOS access separately. Notification opt-in never requests it."
        }
        return capabilityRow(title: title, systemImage: systemImage, status: status, detail: detail)
    }

    private var watchCapabilityRow: some View {
        let host = presentation(for: .watchCompanion)
        let status: String
        let detail: String
        if !host.isAvailable {
            status = "\(host.status) · \(watchDeviceStatus)"
            detail = "\(host.detail) Watch pairing and app installation are separate iPhone states; notification opt-in does not change either one."
        } else if !WCSession.isSupported() {
            status = "Unavailable on this iPhone"
            detail = "The host reports Watch support, but Watch connectivity is unavailable on this device."
        } else if !WCSession.default.isPaired {
            status = "Available · No paired Watch"
            detail = "The host reports Watch support. No Apple Watch is paired with this iPhone."
        } else if !WCSession.default.isWatchAppInstalled {
            status = "Available · App not installed"
            detail = "An Apple Watch is paired, but the bighelp Watch app is not installed."
        } else {
            status = WCSession.default.isReachable ? "Installed · Reachable" : "Installed · Not currently reachable"
            detail = "The host reports Watch support and the bighelp Watch app is installed. Reachability can change when the app is not active."
        }
        return capabilityRow(title: "Apple Watch", systemImage: "applewatch", status: status, detail: detail)
    }

    private func presentation(for capability: WorkspaceCapability) -> CapabilityPresentation {
        guard let connections, let owner = connections.owner else {
            return CapabilityPresentation(
                status: "Not connected",
                detail: "Connect the selected Hermes host to read this capability.",
                isAvailable: false
            )
        }
        switch connections.capabilities.availability(for: capability, owner: owner) {
        case .unknown:
            return CapabilityPresentation(
                status: "Not verified",
                detail: "The selected host has not reported this capability.",
                isAvailable: false
            )
        case .available:
            return CapabilityPresentation(
                status: "Available",
                detail: "The selected host reports this capability as available.",
                isAvailable: true
            )
        case .unavailable(let reason):
            return CapabilityPresentation(
                status: "Unavailable",
                detail: reason.message,
                isAvailable: false
            )
        }
    }

    private func deviceAccessDetail(_ capability: DeviceToolCapability) -> String {
        switch permissionCenter.deviceTools.status(for: capability) {
        case .notRequested:
            "bighelp’s host grant is on; iOS access has not been requested in this session."
        case .available:
            "The host grant and iOS access are available on this iPhone."
        case .managedByHealth:
            "The host grant is on. Apple Health controls which data is shared and does not reveal read authorization status."
        case .denied:
            "The host grant is on, but iOS access is denied."
        case .unavailable:
            "The host grant is on, but this device reports the system capability as unavailable."
        }
    }

    private func iosAccessStatus(_ capability: DeviceToolCapability) -> String {
        switch permissionCenter.deviceTools.status(for: capability) {
        case .notRequested: "iOS not requested"
        case .available: "iOS available"
        case .managedByHealth: "managed by Health"
        case .denied: "iOS denied"
        case .unavailable: "iOS unavailable"
        }
    }

    private func iosAccessDetail(_ capability: DeviceToolCapability) -> String {
        switch permissionCenter.deviceTools.status(for: capability) {
        case .notRequested: "This iPhone has not requested that protected-data permission."
        case .available: "This iPhone reports the protected-data capability as available."
        case .managedByHealth: "Apple Health manages per-data-type authorization and does not expose read authorization status."
        case .denied: "iOS denies this protected-data access; change it in the relevant system settings if desired."
        case .unavailable: "This iPhone reports the protected-data capability as unavailable."
        }
    }

    private var watchDeviceStatus: String {
        guard WCSession.isSupported() else { return "Watch unsupported" }
        guard WCSession.default.isPaired else { return "No paired Watch" }
        guard WCSession.default.isWatchAppInstalled else { return "Watch app not installed" }
        return WCSession.default.isReachable ? "Watch reachable" : "Watch not reachable"
    }

    private func capabilityRow(
        title: String,
        systemImage: String,
        status: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: systemImage)
                .foregroundStyle(theme.secondaryText)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(title)
                    .bighelpFont(.body, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                Text(status)
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                Text(detail)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, BighelpTokens.space4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(status)
        .accessibilityIdentifier("settings.plugin-capability.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }

    @BighelpThemeReader private var theme


    private struct CapabilityPresentation {
        let status: String
        let detail: String
        let isAvailable: Bool
    }
}
