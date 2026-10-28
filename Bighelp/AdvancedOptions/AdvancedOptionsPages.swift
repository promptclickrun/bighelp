import SwiftUI

// Advanced Options (a bot's profile › Info, and Bots mode's Settings › Approvals): the bot's
// settings, and every Nerd Mode page made for that bot. Hermes tools opens the same pages for
// the agent the app has selected (`workspaceAgentID`); these name the bot themselves, so they
// work for any bot and without Nerd Mode.
extension RootShellView {
    /// Nil without a computer to read the bot's settings from.
    func makeAdvancedOptions(for agentID: String) -> AdvancedOptionsContext? {
        guard let configuration = makeSimpleBotHostConfiguration() else { return nil }
        return AdvancedOptionsContext(
            store: AdvancedOptionsStore(client: configuration, profile: agentID),
            settings: settings,
            offers: { advancedOptionsOffers($0) },
            page: { AnyView(advancedOptionsPage($0, agentID: agentID)) })
    }

    /// Demo mode's made-up computer, while no real one is picked.
    private var advancedOptionsOnDemo: Bool {
        usesWorkspaceFixtures && workspaceConnections?.isDirectSelected != true
    }

    /// Read as Advanced Options draws, so its rows show up once the computer is connected.
    private func advancedOptionsOffers(_ page: AdvancedPage) -> Bool {
        if advancedOptionsOnDemo {
            switch page {
            // The made-up computer has no Skills Hub.
            case .skillsHub: return false
            case .rawConfiguration: return advancedDemoHasConfigFile
            default: return true
            }
        }
        return currentWorkspaceOwner != nil && workspaceConnections?.hosts.selectedWorkspace?.nativeClient != nil
    }

    /// Demo mode's config.yaml is a debug-only fixture (`AdvancedDemoRawConfiguration`).
    private var advancedDemoHasConfigFile: Bool {
        #if DEBUG
        return administrationOwner != nil
        #else
        return false
        #endif
    }

    @ViewBuilder
    private func advancedOptionsPage(_ page: AdvancedPage, agentID: String) -> some View {
        let name = agents.profiles.first { $0.id == agentID }?.name ?? agentID
        switch page {
        case .skillsAndTools:
            SkillsAndToolsCatalogView(store: skillsAndTools, agentID: agentID)
        case .rawConfiguration:
            AdvancedKeptPage(title: page.title) { makeAdvancedRawConfiguration(agentID: agentID) } content: {
                RawConfigurationView(store: $0)
            }
        default:
            if let destination = page.destination {
                if advancedOptionsOnDemo {
                    AdvancedKeptPage(title: page.title) {
                        WorkspaceManagementStore(hostName: workspaceHostName, profileName: name,
                                                 client: FixtureWorkspaceManagementClient(), isCurrent: { true })
                    } content: { WorkspaceManagementView(store: $0, destination: destination) }
                } else {
                    advancedHostPage(destination, agentID: agentID, name: name)
                }
            }
        }
    }

    /// The computer's own pages, as Hermes tools opens them, for this bot.
    @ViewBuilder
    private func advancedHostPage(_ destination: WorkspaceDestination, agentID: String, name: String) -> some View {
        if let owner = currentWorkspaceOwner, let connections = workspaceConnections,
           let direct = connections.hosts.selectedWorkspace?.nativeClient {
            let current: @MainActor () -> WorkspaceOwner? = { currentWorkspaceOwner }
            if let kind = CapabilitiesManagementKind(destination: destination) {
                let status = DirectHermesHostOperationsClient(rpc: direct, http: direct, owner: owner, currentOwner: current)
                CapabilitiesManagementView(kind: kind, hostName: workspaceHostName, profileName: name, dependencies: .init(
                    skills: DirectHermesSkillsHubClient(http: direct, owner: owner, profileID: agentID,
                                                        currentOwner: current, actionStatusClient: status),
                    mcp: DirectHermesMCPClient(http: direct, rpc: direct, owner: owner, profileID: agentID,
                                               currentOwner: current, actionStatusClient: status),
                    plugins: DirectHermesPluginLifecycleClient(http: direct, owner: owner, currentOwner: current),
                    toolsets: DirectHermesToolsetClient(http: direct, owner: owner, profileID: agentID,
                                                        currentOwner: current, actionStatusClient: status)))
            } else if destination == .logs, let workspace = connections.workspace {
                HermesLogsDestinationView(hostName: workspaceHostName, owner: owner, http: direct,
                                          workspace: workspace, currentOwner: current)
            } else {
                AdvancedKeptPage(title: destination.title) {
                    AdvancedAdministration(NativeAdministrationPresentation(
                        destination: destination, hostName: workspaceHostName, profileID: agentID,
                        servingProfileID: connections.workspace?.nativeContext?.servingProfileID,
                        rpc: direct, http: direct, owner: owner, currentOwner: current,
                        connections: connections,
                        invalidationSource: connections.nativeInvalidationSource(authority: owner.authority)))
                } content: { kept in
                    NativeAdministrationDestination(
                        presentation: kept.presentation, permissionCenter: permissionCenter,
                        agents: modelAdministrationAgents, reasoningDefaults: agentRuntimeDefaults,
                        onOpenProviderAccounts: {}, onOpenAgentDefaults: {})
                }
            }
        } else {
            WorkspaceUnavailableView(destination: destination, hostName: workspaceHostName,
                                     reason: String(localized: "Connect to your computer, then open this again."))
        }
    }

    /// The bot's own config.yaml, in the editor Settings › System uses; demo mode's is made up.
    private func makeAdvancedRawConfiguration(agentID: String) -> RawConfigurationStore? {
        #if DEBUG
        if advancedOptionsOnDemo {
            guard let owner = administrationOwner else { return nil }
            let demo = AdvancedDemoRawConfiguration.shared
            return RawConfigurationStore(
                hostName: workspaceHostName, profileID: agentID,
                client: DirectHermesHostOperationsClient(rpc: demo, http: demo, owner: owner, currentOwner: { owner }),
                isCurrent: { true })
        }
        #endif
        guard let owner = currentWorkspaceOwner,
              let direct = workspaceConnections?.hosts.selectedWorkspace?.nativeClient else { return nil }
        return RawConfigurationStore(
            hostName: workspaceHostName, profileID: agentID,
            client: DirectHermesHostOperationsClient(rpc: direct, http: direct, owner: owner,
                                                     currentOwner: { currentWorkspaceOwner }),
            isCurrent: { currentWorkspaceOwner == owner })
    }
}

/// Makes a page's model once, when the page first shows, and keeps it while the page is on the
/// stack: `navigationDestination` builds its view again on every update.
private struct AdvancedKeptPage<Model: AnyObject, Content: View>: View {
    let title: String
    let make: @MainActor () -> Model?
    @ViewBuilder let content: (Model) -> Content

    @State private var model: Model?
    @State private var isMade = false

    var body: some View {
        Group {
            if let model {
                content(model)
            } else if isMade {
                ContentUnavailableView(String(localized: "Your computer isn't connected"), systemImage: "wifi.slash",
                                       description: Text("Connect to it, then open this again."))
                    .navigationTitle(title)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            guard !isMade else { return }
            model = make()
            isMade = true
        }
    }
}

/// A host page's own connection, let go once its page leaves the stack.
@MainActor
private final class AdvancedAdministration {
    let presentation: NativeAdministrationPresentation

    init(_ presentation: NativeAdministrationPresentation) {
        self.presentation = presentation
    }

    deinit {
        let presentation = presentation
        Task { @MainActor in presentation.retire() }
    }
}

#if DEBUG
/// Demo mode's config.yaml for each bot: written out from the demo settings until it's saved
/// here, then kept in memory.
@MainActor
final class AdvancedDemoRawConfiguration: DirectHermesRPC, DirectHermesAuthenticatedHTTP {
    static let shared = AdvancedDemoRawConfiguration()

    var onEvent: ((DirectHermesEvent) -> Void)?
    private var saved: [String: String] = [:]

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }

    func disconnect() async {}

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        guard request.path == "/api/config/raw" else { throw DirectHermesError.unsupportedAuthentication }
        let profile = request.query.first { $0.name == "profile" }?.value ?? "default"
        if request.method == .put, let yaml = request.body?["yaml_text"]?.string {
            saved[profile] = yaml
            return .object(["ok": .boolean(true)])
        }
        var yaml = saved[profile]
        if yaml == nil { yaml = Self.yaml(try await SimpleBotDemoConfiguration.shared.read(profile: profile)) }
        return .object(["yaml": .string(yaml ?? ""), "path": .string("~/.hermes/profiles/\(profile)/config.yaml")])
    }

    static func yaml(_ config: [String: BighelpJSONValue]) -> String {
        lines(config, indent: "").joined(separator: "\n") + "\n"
    }

    private static func lines(_ object: [String: BighelpJSONValue], indent: String) -> [String] {
        object.keys.sorted().flatMap { key -> [String] in
            if case .object(let inner)? = object[key], !inner.isEmpty {
                return ["\(indent)\(key):"] + lines(inner, indent: indent + "  ")
            }
            return ["\(indent)\(key): \(scalar(object[key] ?? .null))"]
        }
    }

    private static func scalar(_ value: BighelpJSONValue) -> String {
        switch value {
        case .string(let text):
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        case .integer(let number): String(number)
        case .number(let number): String(number)
        case .boolean(let flag): flag ? "true" : "false"
        case .null: "null"
        case .object: "{}"
        case .array(let items): "[" + items.map(scalar).joined(separator: ", ") + "]"
        }
    }
}
#endif
