import SwiftUI
import UIKit

// Same RootShellView owner; no new model, lifecycle or navigation state.
extension RootShellView {
    var currentWorkspaceOwner: WorkspaceOwner? {
        if workspaceConnections?.isDirectSelected == true { return workspaceConnections?.owner }
        if usesWorkspaceFixtures {
            guard let authority = try? WorkspaceAuthority.fixture(id: demoHosts.selectedHostID ?? "demo") else { return nil }
            return WorkspaceOwner(authority: authority, authenticationGeneration: workspaceFixtureGeneration,
                                  connectionGeneration: workspaceFixtureConnection)
        }
        return nil
    }

    /// A screen opened for this computer and sign-in stays up through a
    /// reconnect, including while the connection is on its way back.
    func isCurrentSignIn(_ owner: WorkspaceOwner) -> Bool {
        (currentWorkspaceOwner?.signIn ?? workspaceSignIn) == owner.signIn
    }

    /// The owner host pages (Default model, Provider Keys, the Nerd Mode tools)
    /// are opened for. Demo runs stand a direct sign-in in for their fixture one,
    /// so the demo's Default model page is the real one.
    var administrationOwner: WorkspaceOwner? {
        #if DEBUG
        if usesWorkspaceFixtures { return currentWorkspaceOwner.flatMap(DemoModels.owner(standingInFor:)) }
        #endif
        return currentWorkspaceOwner
    }

    /// The sign-in host pages belong to, kept while the connection is away.
    var administrationSignIn: WorkspaceSignIn? {
        if let owner = administrationOwner { return owner.signIn }
        #if DEBUG
        if usesWorkspaceFixtures { return workspaceSignIn.flatMap(DemoModels.signIn(standingInFor:)) }
        #endif
        return workspaceSignIn
    }

    /// Host pages with a connection of their own (`NativeAdministrationPresentation`).
    func opensHostAdministration(_ destination: WorkspaceDestination) -> Bool {
        guard NativeAdministrationPresentation.supports(destination) else { return false }
        #if DEBUG
        // Provider Keys shows `DemoProviderKeys`, but opens like a host's so the
        // pages under it see what they would with one.
        if usesWorkspaceFixtures { return destination == .models || destination == .keys }
        #endif
        return !usesWorkspaceFixtures
    }

    /// Default model's agent picker: every agent on this computer.
    var modelAdministrationAgents: [ModelAdministrationAgent] {
        agents.profiles.map { ModelAdministrationAgent(id: $0.id, name: $0.name, imageURL: agents.avatarURL(for: $0)) }
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
        // Demo mode's made-up host, so its switches (Location's demo place) can be tried.
        if usesDemoFixtures {
            return DeviceToolScope(deviceID: permissionCenter.nativeDeviceID, authorizationEpoch: 1, hostID: "demo-host")
        }
        return nil
    }

    var nativeDeviceToolTrigger: String {
        let coordinate = appState.activeConversationID.flatMap { nativeRuntime?.bridge.currentCoordinate(for: $0) }
        return "\(nativeWorkspaceStore?.nativeClient?.isConnected == true):\(voiceSettingsScope ?? "none"):\(appState.activeConversationID ?? "none"):\(coordinate?.storedSessionID ?? "none"):\(coordinate?.runtimeSessionID ?? "none"):\(permissionCenter.deviceTools.revision):\(hostRegistry?.deviceToolFeatureReadinessToken ?? 0):\(deviceToolsOpen):\(UIApplication.shared.isProtectedDataAvailable)"
    }

    /// Whether the phone's channel runs: while bighelp is active or inactive (a notification pulled
    /// down, Control Center, a system question), for the background grace after leaving, and while a
    /// tool call has the app out in another app (`DeviceToolHandoff`).
    var deviceToolsOpen: Bool { DeviceToolHandoff.shared.isOpen(scenePhase) }

    /// The same, read live by the channel's closures, which outlive this view's copy of the scene phase.
    static var deviceToolsOpenNow: Bool { DeviceToolHandoff.shared.isAppOpen(UIApplication.shared.applicationState) }

    func runNativeDeviceTools() async {
        #if DEBUG
        if usesDemoFixtures, let call = permissionCenter.demoAppearanceCall, let scope = currentDeviceToolScope,
           let conversationID = appState.activeConversationID, scenePhase == .active {
            await call.send(scope: scope, isCurrent: {
                appState.activeConversationID == conversationID && scenePhase == .active
            })
            return
        }
        #endif
        guard let owner = currentWorkspaceOwner, owner.authority.kind == .direct,
              let scope = currentDeviceToolScope, let direct = nativeWorkspaceStore?.nativeClient,
              direct.isConnected,
              let handler = permissionCenter.nativeDeviceToolHandler,
              deviceToolsOpen, UIApplication.shared.isProtectedDataAvailable else { return }
        let permissions = permissionCenter.deviceTools
        await permissions.refresh()
        // On, and allowed by iOS now: a switch whose iOS access is off stays on but isn't offered.
        let enabled = Set(DeviceToolCapability.allCases.filter { permissions.isUsable($0) })
        guard !enabled.isEmpty else { permissionCenter.nativeDeviceToolStatus = nil; return }
        guard let conversationID = appState.activeConversationID,
              let coordinate = nativeRuntime?.bridge.currentCoordinate(for: conversationID),
              coordinate.owner == owner else {
            permissionCenter.nativeDeviceToolStatus = DeviceToolChannelNote.noChat(enabled: enabled)
            return
        }
        let revision = permissions.revision
        // An agent's own contacts.create and calendar.create wait for a reviewed draft in a chat with
        // the person's picture (docs/IMAGE_DRAFTS.md › Image fence); the chat is read per such call.
        let features = featureStore
        let guarded = ImageDraftWriteFence.guarding(handler, holdsPicture: {
            features.preparedChatModel(id: conversationID).map { ImageDraftWriteFence.holdsPersonPicture($0.items) } ?? false
        })
        var session: NativeDeviceToolSession?
        permissionCenter.nativeDeviceToolStatus = nil
        do {
            try await NativeDeviceToolSession.runReopeningWhileHeld(makeSession: {
                let next = NativeDeviceToolSession(http: direct, owner: owner, currentOwner: { currentWorkspaceOwner },
                    scope: scope, agentID: coordinate.profileID,
                    sessionID: coordinate.storedSessionID ?? coordinate.runtimeSessionID ?? coordinate.sessionID,
                    enabled: enabled, isAvailable: {
                        permissions.scope == scope && permissions.revision == revision
                            && Self.deviceToolsOpenNow && UIApplication.shared.isProtectedDataAvailable
                            && appState.activeConversationID == conversationID
                    }, isPaused: { !Self.deviceToolsOpenNow }, handle: guarded)
                session = next
                return next
            }, onConnected: { connected in
                permissionCenter.nativeDeviceToolStatus = DeviceToolChannelNote.connected(
                    needsNewerPlugin: connected.needsNewerPlugin)
            }, onWaiting: {
                permissionCenter.nativeDeviceToolStatus = DeviceToolChannelNote.reconnecting(enabled: enabled)
            })
        } catch {
            guard !Task.isCancelled, currentWorkspaceOwner == owner,
                  permissions.revision == revision else { return }
            if let served = session?.servingAgentID {
                let name = agents.resolvedAgent(explicitID: served)?.name ?? ""
                permissionCenter.nativeDeviceToolStatus = DeviceToolChannelNote.otherAgent(
                    enabled: enabled, servingAgentName: name.isEmpty ? "your default agent" : name)
                return
            }
            if NativeDeviceToolSession.isChatHeld(error) {
                permissionCenter.nativeDeviceToolStatus = DeviceToolChannelNote.heldElsewhere(enabled: enabled)
                return
            }
            permissionCenter.nativeDeviceToolStatus = DeviceToolChannelNote.failed(
                enabled: enabled, needsNewerPlugin: session?.needsNewerPlugin ?? [])
        }
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
            return Self.withOnDeviceVoices(
                DirectHermesVoiceSettingsClient(workspace: workspace, owner: owner, currentOwner: { currentWorkspaceOwner }),
                computer: owner.authority.cacheScopeID)
        }
        #if DEBUG
        if usesDemoFixtures, ProcessInfo.processInfo.arguments.contains("-voice-settings-fixture") {
            return Self.withOnDeviceVoices(voiceSettingsPreview, computer: "fixture-voice-settings")
        }
        #endif
        return nil
    }

    /// This iPhone's or iPad's own voices, where it can run them.
    private static func withOnDeviceVoices(_ client: any VoiceSettingsClient, computer: String) -> any VoiceSettingsClient {
        OnDeviceSpeechEngine.isSupported ? OnDeviceVoiceSettingsClient(host: client, computer: computer) : client
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
