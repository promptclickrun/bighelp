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
    /// Hermes' Kanban boards, for a computer page's Advanced · Setup › Kanban boards.
    let kanban: HermesKanbanStore
    let achievements: HermesAchievementsStore
    let voice: VoiceConfigurationStore?
    private let rpc: any DirectHermesRPC
    private let http: any DirectHermesAuthenticatedHTTP
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
        self.rpc = rpc
        self.http = http
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
            observesProviderSetup: destination == .keys || destination == .models
        )
        invalidationObserver = observer
        observer.install()
    }

    var isCurrent: Bool { !retired && currentOwner() == owner }

    /// A computer's page › Advanced · Upkeep › Logs, read over this presentation's connection.
    func makeLogs() -> HermesLogsDestinationView {
        HermesLogsDestinationView(
            hostName: hostName, owner: owner, http: http,
            workspace: DirectHermesWorkspaceClient(rpc: rpc, http: http, owner: owner,
                                                   capabilities: .init(owner: owner), currentOwner: currentOwner),
            currentOwner: currentOwner)
    }

    /// The computer page for the computer `hostID`, made from the registry's own connection to it
    /// (Settings › a computer). Nil unless it's connected now.
    static func computer(_ hostID: UUID, registry: BighelpHostRegistry) -> NativeAdministrationPresentation? {
        guard registry.isWorkspaceReady, let host = registry.hosts.first(where: { $0.id == hostID }) else { return nil }
        let workspace = registry.workspace(for: host)
        let generation = registry.generation
        guard let verified = try? workspace.verifiedConnection(for: host, generation: generation) else { return nil }
        let direct = verified.client, owner = verified.owner
        let connectionGeneration = owner.connectionGeneration
        let current: @MainActor () -> WorkspaceOwner? = { [weak registry, weak workspace] in
            guard let registry, let workspace, registry.generation == generation,
                  workspace.connectionGeneration == connectionGeneration, workspace.isConnected else { return nil }
            return owner
        }
        let profile = workspace.selectedProfile.isEmpty ? "default" : workspace.selectedProfile
        let presentation = NativeAdministrationPresentation(
            destination: .system, hostName: host.name, profileID: profile, servingProfileID: nil,
            rpc: direct, http: direct, owner: owner, currentOwner: current,
            connections: nil, invalidationSource: nil)
        presentation.hostOperations.onServicesChanged = { [weak registry] in
            registry?.noteServicesChanged(hostID: hostID)
        }
        return presentation
    }

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
    /// The computer's bots, for Models' Default model rows.
    var agents: [ModelAdministrationAgent] = []
    /// Reads and saves each bot's default model (Models › Default model).
    var reasoningDefaults: (any AgentRuntimeDefaultsClient)?
    /// Demo runs: the made-up providers Models lists, in place of the stand-in computer's own (none).
    var demoProviderAccounts: ProviderAccountsStore?
    /// Models' Default model rows, made once the page shows and kept while it's on the stack. A
    /// reattach hands this page a new presentation, so they're made again for its clients.
    @State private var botDefaults: ModelsBotDefaults?
    @State private var botDefaultsPresentation: UUID?

    var body: some View {
        Group {
            if presentation.isCurrent {
                switch presentation.destination {
                case .memory:
                    MemoryManagementView(store: presentation.memory)
                case .system:
                    HostOperationsView(store: presentation.hostOperations, administration: presentation,
                                       permissionCenter: permissionCenter)
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
                case .keys, .models:
                    // Default model and AI providers are one page: Models.
                    ProviderAccountsView(store: demoProviderAccounts ?? presentation.providerAccounts, botDefaults: botDefaults,
                                         models: presentation.models, localModels: presentation.localModels)
                        .onAppear { makeBotDefaults() }
                        .onChange(of: presentation.id) { _, _ in makeBotDefaults() }
                        .onChange(of: agents) { _, agents in botDefaults?.show(agents) }
                default:
                    unavailable
                }
            } else {
                unavailable
            }
        }
        .id(presentation.id)
    }

    private func makeBotDefaults() {
        guard botDefaultsPresentation != presentation.id, let reasoningDefaults else { return }
        botDefaultsPresentation = presentation.id
        let models = presentation.models
        botDefaults = ModelsBotDefaults(agents: agents, client: reasoningDefaults) { id in
            AgentHelperModelsModel(agentID: id, client: models)
        }
    }

    private var unavailable: some View {
        WorkspaceUnavailableView(destination: presentation.destination, hostName: presentation.hostName,
            reason: "Open this page again for the computer in use.")
    }
}

/// Holds a page's own administration connection and lets it go once the page leaves the stack:
/// `.onDisappear` can't, because a page pushed over it makes it disappear too.
@MainActor
final class RetainedAdministration {
    let presentation: NativeAdministrationPresentation

    init(_ presentation: NativeAdministrationPresentation) {
        self.presentation = presentation
    }

    deinit {
        let presentation = presentation
        Task { @MainActor in presentation.retire() }
    }
}
