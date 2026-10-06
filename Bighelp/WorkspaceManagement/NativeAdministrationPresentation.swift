import Foundation
import SwiftUI

/// Owns the one typed global-invalidation subscription for a retained native
/// administration presentation. Session and cron notices stay with the runtime;
/// this observer only routes management topics to their retained stores.
@MainActor
private final class NativeAdministrationInvalidationObserver {
    private weak var connections: WorkspaceConnectionStore?
    private let expectedSource: NativeWorkspaceEventSource
    private let presentationOwner: WorkspaceOwner
    private let presentationServingProfileID: String?
    private let isCurrent: @MainActor () -> Bool
    private let messaging: MessagingOnboardingStore
    private let pairing: PairingManagementStore
    private let providerAccounts: ProviderAccountsStore
    private let observesProviderSetup: Bool
    private let observerID = UUID()
    private var isInstalled = false

    init(
        connections: WorkspaceConnectionStore,
        expectedSource: NativeWorkspaceEventSource,
        presentationOwner: WorkspaceOwner,
        presentationServingProfileID: String?,
        isCurrent: @escaping @MainActor () -> Bool,
        messaging: MessagingOnboardingStore,
        pairing: PairingManagementStore,
        providerAccounts: ProviderAccountsStore,
        observesProviderSetup: Bool
    ) {
        self.connections = connections
        self.expectedSource = expectedSource
        self.presentationOwner = presentationOwner
        self.presentationServingProfileID = presentationServingProfileID
        self.isCurrent = isCurrent
        self.messaging = messaging
        self.pairing = pairing
        self.providerAccounts = providerAccounts
        self.observesProviderSetup = observesProviderSetup
    }

    func install() {
        guard !isInstalled, let connections,
              expectedSource.owner == presentationOwner,
              expectedSource.servingProfileID.map({ Data($0.utf8) })
                == presentationServingProfileID.map({ Data($0.utf8) }),
              connections.nativeInvalidationSource(authority: presentationOwner.authority) == expectedSource
        else { return }
        isInstalled = true
        connections.addInvalidationObserver(id: observerID) { [weak self] update in
            self?.receive(update)
        }
    }

    func retire() {
        guard isInstalled else { return }
        isInstalled = false
        connections?.removeInvalidationObserver(id: observerID)
    }

    private func receive(_ update: NativeWorkspaceInvalidationUpdate) {
        guard isInstalled, isCurrent(), let connections,
              update.source == expectedSource,
              update.revision.source == expectedSource,
              update.source.owner == presentationOwner,
              update.source.servingProfileID.map({ Data($0.utf8) })
                == presentationServingProfileID.map({ Data($0.utf8) }),
              connections.nativeInvalidationSource(authority: expectedSource.owner.authority) == expectedSource
        else { return }

        switch update.notice {
        case .platformsChanged:
            messaging.receivePlatformsInvalidation(
                revision: update.revision.value(for: .platforms)
            )
        case .pairingChanged:
            pairing.receivePairingInvalidation(
                revision: update.revision.value(for: .pairing)
            )
        case .setupReady:
            guard observesProviderSetup else { return }
            providerAccounts.receiveSetupInvalidation(
                revision: update.revision.value(for: .setup)
            )
        case .sessionsChanged, .scheduledTasksChanged, .resumeProgress:
            break
        }
    }
}

/// Retains one management scope across SwiftUI updates. A new host/profile or
/// explicit navigation creates a new owner; no second connection is opened.
@MainActor
final class NativeAdministrationPresentation: Identifiable {
    private final class Lifetime { var isActive = true }
    private let lifetime: Lifetime
    let id = UUID()
    let destination: WorkspaceDestination
    let owner: WorkspaceOwner
    let profileID: String
    let hostName: String
    let servingProfileID: String?
    let memory: MemoryGraphStore
    let messaging: MessagingOnboardingStore
    let pairing: PairingManagementStore
    let webhooks: WebhookEditorStore
    let providerAccounts: ProviderAccountsStore
    let models: DirectHermesModelAdministrationClient
    let hostOperations: HostOperationsStore
    let files: WorkspaceFileTransferStore
    let projects: ProjectLifecycleStore
    let stockGitCoordinator: NativeStockGitCoordinator?
    private let ownsProjectStore: Bool
    let localModels: LocalModelsStore
    let toolBackends: HostToolBackendsStore
    let kanban: HermesKanbanStore
    let achievements: HermesAchievementsStore
    let voice: VoiceConfigurationStore?
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private var invalidationObserver: NativeAdministrationInvalidationObserver?
    private(set) var retired = false

    static func supports(_ destination: WorkspaceDestination) -> Bool {
        [.memory, .messaging, .webhooks, .keys, .models, .system, .files, .projects].contains(destination)
    }

    init(destination: WorkspaceDestination, hostName: String, profileID: String,
         servingProfileID: String?, rpc: any DirectHermesRPC, http: any DirectHermesAuthenticatedHTTP,
         owner: WorkspaceOwner, currentOwner sourceOwner: @escaping @MainActor () -> WorkspaceOwner?,
         connections: WorkspaceConnectionStore?, invalidationSource: NativeWorkspaceEventSource?,
         stockGit: NativeStockGitProjectPresentation? = nil) {
        let lifetime = Lifetime()
        self.lifetime = lifetime
        let currentOwner: @MainActor () -> WorkspaceOwner? = {
            guard lifetime.isActive else { return nil }
            return sourceOwner()
        }
        self.destination = destination
        self.hostName = hostName
        self.profileID = profileID
        self.servingProfileID = servingProfileID
        self.owner = owner
        self.currentOwner = currentOwner
        stockGitCoordinator = stockGit?.coordinator
        ownsProjectStore = stockGit == nil
        let actionStatusClient = DirectHermesHostOperationsClient(rpc: rpc, http: http, owner: owner, currentOwner: currentOwner)
        memory = MemoryGraphStore(hostName: hostName, profileName: profileID,
            client: DirectHermesMemoryClient(rpc: rpc, http: http, owner: owner, currentOwner: currentOwner,
                actionStatusClient: actionStatusClient), actionStatusClient: actionStatusClient)
        messaging = MessagingOnboardingStore(hostName: hostName, profileID: profileID,
            client: DirectHermesMessagingClient(rpc: rpc, http: http, owner: owner, currentOwner: currentOwner),
            isCurrent: { currentOwner() == owner })
        pairing = PairingManagementStore(hostName: hostName, profileID: profileID,
            client: DirectHermesPairingClient(rpc: rpc, http: http, owner: owner, currentOwner: currentOwner),
            isCurrent: { currentOwner() == owner })
        webhooks = WebhookEditorStore(hostName: hostName,
            client: DirectHermesWebhooksClient(rpc: rpc, http: http, owner: owner, currentOwner: currentOwner),
            isCurrent: { currentOwner() == owner })
        let providerClient = DirectHermesProviderClient(
            rpc: rpc, http: http, owner: owner, currentOwner: currentOwner
        )
        providerAccounts = ProviderAccountsStore(
            hostName: hostName, profileID: profileID,
            servingProfileID: servingProfileID, client: providerClient,
            hostSignIn: ProviderHostSignInStore(
                profileID: profileID, hostName: hostName,
                client: DirectHermesHostSignInClient(owner: owner, currentWorkspace: { [weak connections] in
                    currentOwner() == owner ? connections?.workspace : nil
                })
            )
        )
        models = DirectHermesModelAdministrationClient(rpc: rpc, http: http, owner: owner, currentOwner: currentOwner)
        hostOperations = HostOperationsStore(hostName: hostName, profileID: profileID,
            operationTargetProfileID: servingProfileID,
            client: actionStatusClient,
            isCurrent: { currentOwner() == owner })
        files = WorkspaceFileTransferStore(hostName: hostName,
            client: DirectHermesManagedFilesClient(http: http, binaryHTTP: http as? any DirectHermesManagedFileBinaryHTTP,
                owner: owner, currentOwner: currentOwner), isCurrent: { currentOwner() == owner })
        projects = stockGit?.projects ?? ProjectLifecycleStore(hostName: hostName, profileID: profileID,
            client: DirectHermesProjectLifecycleClient(rpc: rpc, http: http, owner: owner, currentOwner: currentOwner),
            isCurrent: { currentOwner() == owner })
        localModels = LocalModelsStore(hostName: hostName, profileID: profileID,
            client: DirectHermesLocalModelsClient(rpc: rpc, http: http, owner: owner, currentOwner: currentOwner),
            isCurrent: { currentOwner() == owner })
        toolBackends = HostToolBackendsStore(hostName: hostName, profileID: profileID,
            client: DirectHermesHostToolBackendsClient(rpc: rpc, http: http, owner: owner, currentOwner: currentOwner),
            isCurrent: { currentOwner() == owner })
        achievements = HermesAchievementsStore(hostName: hostName,
            client: DirectHermesAchievementsClient(rpc: rpc, http: http, owner: owner, currentOwner: currentOwner))
        if let direct = rpc as? DirectHermesClient {
            kanban = HermesKanbanStore(hostName: hostName,
                client: direct.makeKanbanClient(owner: owner, currentOwner: currentOwner))
            voice = VoiceConfigurationStore(hostName: hostName, profileID: profileID,
                client: direct.makeVoiceConfigurationClient(owner: owner, currentOwner: currentOwner),
                isCurrent: { currentOwner() == owner })
        } else {
            kanban = HermesKanbanStore(hostName: hostName,
                client: DirectHermesKanbanClient(rpc: rpc, http: http, owner: owner, currentOwner: currentOwner))
            voice = nil
        }
        invalidationObserver = nil
        // Demo runs have no host to send updates.
        guard let connections, let invalidationSource else { return }
        let observer = NativeAdministrationInvalidationObserver(
            connections: connections, expectedSource: invalidationSource,
            presentationOwner: owner,
            presentationServingProfileID: servingProfileID,
            isCurrent: { currentOwner() == owner }, messaging: messaging,
            pairing: pairing, providerAccounts: providerAccounts,
            observesProviderSetup: destination == .keys
        )
        invalidationObserver = observer
        observer.install()
    }

    var isCurrent: Bool { !retired && currentOwner() == owner }

    func retire() {
        invalidationObserver?.retire()
        invalidationObserver = nil
        lifetime.isActive = false
        retired = true
        memory.retire()
        messaging.retire()
        pairing.retire()
        webhooks.retire()
        providerAccounts.retire()
        hostOperations.retire()
        files.retire()
        if ownsProjectStore { projects.retire() }
        localModels.retire()
        toolBackends.retire()
        kanban.retire()
        achievements.retire()
        voice?.retire()
    }
}

@MainActor
struct NativeAdministrationDestination: View {
    let presentation: NativeAdministrationPresentation
    let permissionCenter: PermissionCenter
    /// The host's agents, for Default model's agent picker.
    var agents: [ModelAdministrationAgent] = []
    /// Reads and saves each agent's reasoning default (Default model › Reasoning).
    var reasoningDefaults: (any AgentRuntimeDefaultsClient)?
    let onOpenProviderAccounts: () -> Void
    let onOpenAgentDefaults: () -> Void

    var body: some View {
        Group {
            if presentation.isCurrent {
                switch presentation.destination {
                case .memory:
                    MemoryManagementView(store: presentation.memory)
                case .system:
                    HostOperationsView(store: presentation.hostOperations) {
                        NavigationLink {
                            HostToolBackendsView(store: presentation.toolBackends)
                        } label: {
                            Label("Tool Backends", systemImage: "wrench.and.screwdriver")
                        }
                        NavigationLink {
                            HostExtensionsView(kanban: presentation.kanban, achievements: presentation.achievements)
                        } label: {
                            Label("Extensions", systemImage: "puzzlepiece.extension")
                        }
                        if let voice = presentation.voice {
                            NavigationLink {
                                VoiceConfigurationView(store: voice, permissionCenter: permissionCenter)
                            } label: {
                                Label("Host Voice", systemImage: "waveform")
                            }
                        }
                    }
                case .files:
                    WorkspaceFileTransferView(store: presentation.files)
                case .projects:
                    ProjectsLifecycleView(store: presentation.projects, stockGitCoordinator: presentation.stockGitCoordinator)
                case .messaging:
                    MessagingOnboardingView(store: presentation.messaging)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                NavigationLink("Pairing") {
                                    PairingManagementView(store: presentation.pairing)
                                }
                            }
                        }
                case .webhooks:
                    WebhookEditorView(store: presentation.webhooks)
                case .keys:
                    ProviderAccountsView(store: presentation.providerAccounts)
                case .models:
                    ModelAdministrationView(hostName: presentation.hostName, profileID: presentation.profileID,
                        client: presentation.models, agents: agents, reasoningDefaults: reasoningDefaults,
                        onOpenProviderAccounts: onOpenProviderAccounts,
                        onOpenAgentDefaults: onOpenAgentDefaults)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                NavigationLink("Local Models") {
                                    LocalModelsView(store: presentation.localModels)
                                }
                            }
                        }
                default:
                    unavailable
                }
            } else {
                unavailable
            }
        }
        .id(presentation.id)
    }

    private var unavailable: some View {
        WorkspaceUnavailableView(destination: presentation.destination, hostName: presentation.hostName,
            reason: "Reopen this feature for the current host and profile.")
    }
}
