import SwiftUI
import UIKit

// Same RootShellView owner; no new model, lifecycle or navigation state.
extension RootShellView {
    var currentWorkspaceOwner: WorkspaceOwner? {
        if workspaceConnections?.isDirectSelected == true { return workspaceConnections?.owner }
        if usesWorkspaceFixtures {
            guard let authority = try? WorkspaceAuthority.fixture(id: demoHosts.selectedHostID ?? "demo") else { return nil }
            return WorkspaceOwner(authority: authority, authenticationGeneration: workspaceFixtureGeneration,
                                  connectionGeneration: workspaceFixtureGeneration)
        }
        return nil
    }

    /// A screen opened for this computer and sign-in stays up through a
    /// reconnect, including while the connection is on its way back.
    func isCurrentSignIn(_ owner: WorkspaceOwner) -> Bool {
        (currentWorkspaceOwner?.signIn ?? workspaceSignIn) == owner.signIn
    }

    var currentWorkspaceCapabilities: WorkspaceCapabilities {
        if workspaceConnections?.isDirectSelected == true {
            return workspaceConnections?.capabilities ?? .disconnected
        }
        guard let owner = currentWorkspaceOwner else { return .disconnected }
        var values: [WorkspaceCapability: WorkspaceAvailability] = [:]
        for capability in WorkspaceCapability.allCases { values[capability] = .available }
        for capability in [WorkspaceCapability.groupsCreate, .groupsSend, .groupsRename,
                           .groupsStop, .groupsRetry, .groupsApprove, .groupsDisband] {
            values[capability] = botModeRooms.nativeExecutionAvailable ? .available : .unavailable(.driverUnavailable)
        }
        values[.groupsRead] = .available
        values[.groupPersonContext] = .unavailable(.identityContextUnavailable)
        return WorkspaceCapabilities(owner: owner, values: values)
    }

    var workspaceHostName: String {
        if let host = workspaceConnections?.selectedDirectHost { return host.name }
        if let id = demoHosts.selectedHostID, let host = demoHosts.host(id: id) { return host.name }
        return usesWorkspaceFixtures ? "Demo host" : "Select a host"
    }

    var workspaceProfileName: String {
        agents.resolvedAgent(explicitID: nil)?.name ?? "Select an agent"
    }

    var sessionOrganizationAccountID: String? {
        usesDemoFixtures ? "fixture-account" : nil
    }

    var sessionOrganizationHostID: String? {
        usesDemoFixtures ? "fixture-host" : nil
    }

    var currentDeviceToolScope: DeviceToolScope? {
        if let owner = currentWorkspaceOwner, owner.authority.kind == .direct {
            // Native grants belong to this install and exact host authority.
            // The local epoch is independent of any optional Link account.
            return DeviceToolScope(deviceID: permissionCenter.nativeDeviceID,
                                   authorizationEpoch: 1, hostID: owner.authority.cacheScopeID)
        }
        return nil
    }

    var nativeDeviceToolTrigger: String {
        let coordinate = appState.activeConversationID.flatMap { nativeRuntime?.bridge.currentCoordinate(for: $0) }
        return "\(nativeWorkspaceStore?.nativeClient?.isConnected == true):\(voiceSettingsScope ?? "none"):\(appState.activeConversationID ?? "none"):\(coordinate?.storedSessionID ?? "none"):\(coordinate?.runtimeSessionID ?? "none"):\(permissionCenter.deviceTools.revision):\(hostRegistry?.deviceToolFeatureReadinessToken ?? 0):\(scenePhase):\(UIApplication.shared.isProtectedDataAvailable)"
    }

    func runNativeDeviceTools() async {
        guard let owner = currentWorkspaceOwner, owner.authority.kind == .direct,
              let scope = currentDeviceToolScope, let direct = nativeWorkspaceStore?.nativeClient,
              direct.isConnected,
              let handler = permissionCenter.nativeDeviceToolHandler,
              scenePhase == .active, UIApplication.shared.isProtectedDataAvailable else { return }
        let permissions = permissionCenter.deviceTools
        await permissions.refresh()
        let enabled = Set(DeviceToolCapability.allCases.filter { permissions.isEnabled($0) })
        guard !enabled.isEmpty else { permissionCenter.nativeDeviceToolStatus = nil; return }
        guard let conversationID = appState.activeConversationID,
              let coordinate = nativeRuntime?.bridge.currentCoordinate(for: conversationID),
              coordinate.owner == owner else {
            permissionCenter.nativeDeviceToolStatus = "Open a chat to use this iPhone’s shared data."
            return
        }
        let revision = permissions.revision
        let session = NativeDeviceToolSession(http: direct, owner: owner, currentOwner: { currentWorkspaceOwner },
            scope: scope, agentID: coordinate.profileID,
            sessionID: coordinate.storedSessionID ?? coordinate.runtimeSessionID ?? coordinate.sessionID,
            enabled: enabled, isAvailable: {
                permissions.scope == scope && permissions.revision == revision
                    && scenePhase == .active && UIApplication.shared.isProtectedDataAvailable
                    && appState.activeConversationID == conversationID
            }, handle: handler)
        permissionCenter.nativeDeviceToolStatus = nil
        do { try await session.run() }
        catch {
            guard !Task.isCancelled, currentWorkspaceOwner == owner,
                  permissions.revision == revision else { return }
            permissionCenter.nativeDeviceToolStatus = "Device access is not connected. Check the bighelp plugin on this host, then reopen the chat."
        }
    }

    var quickWorkspaceContent: QuickWorkspaceContent {
        let summaries = sessionCatalog.recentSummaries(includeCronSessions: settings.showCronSessions)
        let availableKeys = SessionSectionOrganizer.reorderableKeys(
            in: summaries,
            organizeByProjects: settings.organizeChatsByProjects
        )
        let layout = settings.sessionSectionLayout(
            accountID: sessionOrganizationAccountID,
            hostID: sessionOrganizationHostID,
            availableProjectKeys: availableKeys
        )
        return QuickWorkspaceContent(
            recentSessions: summaries,
            organizeByProjects: settings.organizeChatsByProjects,
            projectOrder: layout.projectOrder,
            includeCronSessions: settings.showCronSessions
        )
    }

    var voiceSettingsScope: String? {
        if let owner = currentWorkspaceOwner, owner.authority.kind == .direct {
            return owner.authority.cacheScopeID + ":" + owner.authenticationGeneration.uuidString + ":" + owner.connectionGeneration.uuidString
        }
        #if DEBUG
        if usesDemoFixtures, ProcessInfo.processInfo.arguments.contains("-voice-settings-fixture") {
            return "fixture-voice-settings"
        }
        #endif
        return nil
    }

    var voiceSettingsIsCurrent: @MainActor () -> Bool {
        if let owner = currentWorkspaceOwner, owner.authority.kind == .direct {
            return { currentWorkspaceOwner == owner }
        }
        #if DEBUG
        if usesDemoFixtures, ProcessInfo.processInfo.arguments.contains("-voice-settings-fixture") { return { true } }
        #endif
        return { false }
    }

    var voiceSettingsClient: (any VoiceSettingsClient)? {
        if let owner = currentWorkspaceOwner, owner.authority.kind == .direct,
           let workspace = workspaceConnections?.workspace {
            return DirectHermesVoiceSettingsClient(workspace: workspace, owner: owner, currentOwner: { currentWorkspaceOwner })
        }
        #if DEBUG
        if usesDemoFixtures, ProcessInfo.processInfo.arguments.contains("-voice-settings-fixture") {
            return voiceSettingsPreview
        }
        #endif
        return nil
    }

    var pluginUpdateScope: String? {
        guard nativeWorkspaceStore == nil else { return nil }
        #if DEBUG
        if usesDemoFixtures, ProcessInfo.processInfo.arguments.contains("-plugin-update-fixture") {
            return "fixture-plugin-update"
        }
        #endif
        return nil
    }

    var pluginUpdateIsCurrent: @MainActor () -> Bool {
        #if DEBUG
        if usesDemoFixtures, ProcessInfo.processInfo.arguments.contains("-plugin-update-fixture") { return { true } }
        #endif
        return { false }
    }

    var pluginUpdateClient: (any PluginUpdateClient)? {
        #if DEBUG
        if usesDemoFixtures, ProcessInfo.processInfo.arguments.contains("-plugin-update-fixture") {
            return PluginUpdatePreviewClient()
        }
        #endif
        return nil
    }

    var hostRuntimeScope: String? {
        guard nativeWorkspaceStore == nil else { return nil }
        #if DEBUG
        if usesDemoFixtures,
           HostRuntimePreviewClient.scenario(arguments: ProcessInfo.processInfo.arguments) != nil {
            return "fixture-host-runtime"
        }
        #endif
        return nil
    }

    var currentHostRuntime: HostRuntimeStore? {
        guard hostRuntime?.scope == hostRuntimeScope, hostRuntime?.ownsScope == true else { return nil }
        return hostRuntime
    }

    func prepareHostRuntime() async {
        hostRuntime?.invalidate()
        hostRuntime = nil
        guard let scope = hostRuntimeScope else { return }
        let isCurrent: @MainActor () -> Bool = { hostRuntimeScope == scope }
        #if DEBUG
        guard usesDemoFixtures,
              let scenario = HostRuntimePreviewClient.scenario(arguments: ProcessInfo.processInfo.arguments) else { return }
        let store = HostRuntimeStore(scope: scope, client: HostRuntimePreviewClient(scenario: scenario), isCurrent: isCurrent)
        hostRuntime = store
        await store.refresh()
        #endif
    }

}
