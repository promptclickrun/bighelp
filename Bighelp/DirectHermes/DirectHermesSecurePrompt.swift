import CryptoKit
import Foundation
import Observation
import SwiftUI

/// A user-attended, non-transcript prompt raised by the authenticated Hermes
/// socket. Secret values never enter this model; they live only in the mounted
/// view's SecureField state and the one response operation that consumes them.
struct DirectHermesSecurePrompt: Identifiable {
    enum Origin: Equatable, Sendable {
        case serverRequest
        case legacyEvent
    }

    enum Kind: Equatable, Sendable {
        case secret
        case sudo
        case mcpSetup(MCPAction)
        /// Hermes' browser vault: the one-time code a site sent the person.
        case vaultCode
        /// Hermes' browser vault: a site's login, saved straight into the vault.
        case vaultSaveLogin
        /// Hermes' browser vault: the master password of a password manager.
        case vaultUnlock
    }

    enum MCPAction: String, Equatable, Sendable {
        case install
        case enable
        case authorize
    }

    let id: String
    let origin: Origin
    let kind: Kind
    let wireID: String
    let hostIdentity: String
    let profile: String
    let runtimeSessionID: String
    let visibleSessionID: String
    let envVar: String?
    let prompt: String?
    let server: String?
    let reason: String?
    /// The agent asked for this itself (bighelp_request_secure_input), with a short field label.
    var isAgentRequest = false
    var label: String?
    /// The site a vault prompt is for, as Hermes names it (host, or the page origin).
    var site: String?
    let createdAt: Date
    fileprivate let key: DirectHermesSecurePromptKey

    var title: String {
        switch kind {
        case .secret where isAgentRequest: label ?? envVar ?? "Secure input"
        case .secret: envVar ?? "Secret required"
        case .sudo: "Sudo password required"
        case .mcpSetup(let action):
            switch action {
            case .install: "Install MCP server?"
            case .enable: "Enable MCP server?"
            case .authorize: "Authorize MCP server?"
            }
        case .vaultCode: "Verification code"
        case .vaultSaveLogin: "Save a login"
        case .vaultUnlock: "Unlock \(server ?? "password manager")"
        }
    }

    var detail: String {
        switch kind {
        case .secret:
            if let prompt, !prompt.isEmpty { return prompt }
            return "Enter this value only if you want Hermes to store it for the named environment variable."
        case .sudo:
            return "Hermes will pass this password to sudo for the waiting terminal command. bighelp does not save it."
        case .mcpSetup(let action):
            let verb = switch action {
            case .install: "install and enable"
            case .enable: "enable"
            case .authorize: "start authorization for"
            }
            let target = server ?? "this MCP server"
            if let reason, !reason.isEmpty { return "Hermes wants to \(verb) \(target). \(reason)" }
            return "Hermes wants to \(verb) \(target)."
        case .vaultCode:
            let place = site.map { "\($0) is asking" } ?? "The site is asking"
            if let prompt, !prompt.isEmpty { return "\(place) for a one-time code. \(prompt)" }
            return "\(place) for a one-time code. Enter the code it sent to your phone, email or app."
        case .vaultSaveLogin:
            return "Your agent is on the sign-in page of \(site ?? "a site") and needs a login to continue."
        case .vaultUnlock:
            return "Your agent wants to use logins saved in \(server ?? "your password manager")."
        }
    }
}

struct DirectHermesMCPSetupPresentation: Equatable {
    let promptID: String
    let source: String?
    let requirements: [MCPEnvironmentRequirement]
    let authorizationURL: URL?
    let authorizationStatus: String?
}

typealias DirectHermesLegacySecurePromptResponder = @MainActor @Sendable (
    _ method: String,
    _ params: [String: BighelpJSONValue]
) async throws -> BighelpJSONValue

typealias DirectHermesSecureMCPClientProvider = @MainActor @Sendable (
    _ profile: String
) throws -> any MCPManagementClient

typealias DirectHermesMCPReloader = @MainActor @Sendable (
    _ runtimeSessionID: String
) async throws -> Void

struct DirectHermesSecurePromptDependencies {
    let respondToLegacyPrompt: DirectHermesLegacySecurePromptResponder
    let makeMCPClient: DirectHermesSecureMCPClientProvider
    let reloadMCP: DirectHermesMCPReloader
}

fileprivate enum DirectHermesSecurePromptMethod: String, Hashable, Sendable {
    case secret
    case sudo
    case mcpSetup = "mcp.setup"
    case vaultCode = "vault.code"
    case vaultSaveLogin = "vault.save_login"
    case vaultUnlock = "vault.unlock_prompt"
}

fileprivate struct DirectHermesSecurePromptKey: Hashable {
    let transportGeneration: DirectHermesServerRequestGeneration
    let wireID: Data
    let method: DirectHermesSecurePromptMethod
}

private struct DirectHermesSecurePromptBinding: Equatable {
    let runtimeID: Data
    let profile: Data
    let visibleSessionID: Data

    init(runtimeID: String, profile: String, visibleSessionID: String) {
        self.runtimeID = Data(runtimeID.utf8)
        self.profile = Data(profile.utf8)
        self.visibleSessionID = Data(visibleSessionID.utf8)
    }
}

@MainActor
@Observable
final class DirectHermesSecurePromptStore {
    private enum Delivery {
        case serverRequest(CheckedContinuation<DirectHermesServerResponse, Never>)
        case legacyEvent
    }

    private struct Pending {
        let connection: DirectHermesPromptConnection
        let prompt: DirectHermesSecurePrompt
        let delivery: Delivery
    }

    private(set) var revision: UInt64 = 0
    private(set) var mcpPresentation: DirectHermesMCPSetupPresentation?
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var connection: DirectHermesPromptConnection?
    @ObservationIgnored private var dependencies: DirectHermesSecurePromptDependencies?
    @ObservationIgnored private var bindings: [Data: DirectHermesSecurePromptBinding] = [:]
    @ObservationIgnored private var pending: [DirectHermesSecurePromptKey: Pending] = [:]
    @ObservationIgnored private var mcpClients: [DirectHermesSecurePromptKey: any MCPManagementClient] = [:]
    @ObservationIgnored private var mcpFlows: [DirectHermesSecurePromptKey: MCPOAuthFlow] = [:]
    @ObservationIgnored private var activePresentationID: Data?

    var activePrompt: DirectHermesSecurePrompt? {
        _ = revision
        return pending.values
            .filter { $0.connection == connection }
            .map(\.prompt)
            .sorted(by: Self.sortPrompts)
            .first
    }

    func beginConnection(
        _ value: DirectHermesPromptConnection,
        dependencies: DirectHermesSecurePromptDependencies
    ) {
        retireAll(with: Self.retiredResponse)
        connection = value
        self.dependencies = dependencies
        bindings.removeAll(keepingCapacity: false)
        activePresentationID = nil
        resetMCPPresentation()
        changed()
    }

    func retireConnection(_ value: DirectHermesPromptConnection) {
        guard connection == value else { return }
        connection = nil
        dependencies = nil
        bindings.removeAll(keepingCapacity: false)
        retireAll(with: Self.retiredResponse)
        activePresentationID = nil
        resetMCPPresentation()
        changed()
    }

    func bind(
        profile: String,
        runtimeID: String,
        visibleSessionID: String,
        connection expected: DirectHermesPromptConnection
    ) throws {
        guard isCurrent(expected),
              Self.validIdentifier(profile, maximumBytes: 4_096),
              Self.validIdentifier(runtimeID, maximumBytes: 4_096),
              Self.validIdentifier(visibleSessionID, maximumBytes: 8_192) else {
            throw WorkspaceClientError.ownerChanged
        }
        let key = Data(runtimeID.utf8)
        let value = DirectHermesSecurePromptBinding(
            runtimeID: runtimeID,
            profile: profile,
            visibleSessionID: visibleSessionID
        )
        guard bindings[key] != value else { return }
        retirePending(runtimeKey: key, response: Self.retiredResponse)
        bindings[key] = value
        changed()
    }

    func unbind(
        runtimeID: String,
        profile: String,
        visibleSessionID: String,
        connection expected: DirectHermesPromptConnection
    ) {
        guard isCurrent(expected) else { return }
        let key = Data(runtimeID.utf8)
        guard bindings[key] == DirectHermesSecurePromptBinding(
            runtimeID: runtimeID,
            profile: profile,
            visibleSessionID: visibleSessionID
        ) else { return }
        bindings.removeValue(forKey: key)
        retirePending(runtimeKey: key, response: Self.retiredResponse)
        changed()
    }

    func handle(
        _ request: DirectHermesServerRequest,
        connection expected: DirectHermesPromptConnection
    ) async -> DirectHermesServerResponse {
        guard isCurrent(expected),
              let method = DirectHermesSecurePromptMethod(rawValue: request.method) else {
            return Self.retiredResponse
        }
        let prompt: DirectHermesSecurePrompt
        do {
            prompt = try decode(
                id: request.id,
                method: method,
                params: request.params,
                origin: .serverRequest,
                connection: expected
            )
        } catch {
            return Self.invalidParamsResponse
        }
        let key = prompt.key
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, isCurrent(expected), pending[key] == nil,
                      pending.count < 64 else {
                    continuation.resume(returning: Self.retiredResponse)
                    return
                }
                pending[key] = Pending(
                    connection: expected,
                    prompt: prompt,
                    delivery: .serverRequest(continuation)
                )
                activePromptDidChange()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelHandler(key: key, connection: expected)
            }
        }
    }

    /// Accepts only the stock event bridge retained for older Hermes hosts:
    /// `*.request` plus its exact `*.expire`. Browser-vault prompt families stay
    /// unsupported because this client does not own their browser authority.
    func acceptLegacyEvent(
        _ event: DirectHermesEvent,
        connection expected: DirectHermesPromptConnection
    ) {
        guard isCurrent(expected), let runtimeID = event.sessionID,
              bindings[Data(runtimeID.utf8)] != nil else { return }
        let method: DirectHermesSecurePromptMethod
        let isExpiry: Bool
        switch event.type {
        case "secret.request": (method, isExpiry) = (.secret, false)
        case "sudo.request": (method, isExpiry) = (.sudo, false)
        case "mcp.setup.request": (method, isExpiry) = (.mcpSetup, false)
        case "secret.expire": (method, isExpiry) = (.secret, true)
        case "sudo.expire": (method, isExpiry) = (.sudo, true)
        case "mcp.setup.expire": (method, isExpiry) = (.mcpSetup, true)
        default: return
        }
        guard let wireID = event.payload["request_id"]?.string,
              Self.validIdentifier(wireID, maximumBytes: 4_096) else { return }
        let key = DirectHermesSecurePromptKey(
            transportGeneration: expected.transportGeneration,
            wireID: Data(wireID.utf8),
            method: method
        )
        if isExpiry {
            guard let entry = pending[key], case .legacyEvent = entry.delivery else { return }
            remove(entry)
            return
        }
        var params = event.payload
        params.removeValue(forKey: "request_id")
        params["session_id"] = .string(runtimeID)
        guard let prompt = try? decode(
            id: wireID,
            method: method,
            params: params,
            origin: .legacyEvent,
            connection: expected
        ) else { return }
        if let previous = pending[key] {
            guard case .legacyEvent = previous.delivery,
                  previous.prompt.kind == prompt.kind,
                  Self.same(previous.prompt.envVar, prompt.envVar),
                  Self.same(previous.prompt.prompt, prompt.prompt),
                  Self.same(previous.prompt.server, prompt.server),
                  Self.same(previous.prompt.reason, prompt.reason),
                  Data(previous.prompt.profile.utf8) == Data(prompt.profile.utf8),
                  Data(previous.prompt.runtimeSessionID.utf8) == Data(prompt.runtimeSessionID.utf8),
                  Data(previous.prompt.visibleSessionID.utf8) == Data(prompt.visibleSessionID.utf8) else {
                return
            }
            return
        } else {
            guard pending.count < 64 else { return }
            pending[key] = Pending(connection: expected, prompt: prompt, delivery: .legacyEvent)
        }
        activePromptDidChange()
    }

    func acceptCancellation(
        _ cancellation: DirectHermesServerRequestCancellation,
        connection expected: DirectHermesPromptConnection
    ) {
        guard isCurrent(expected),
              let method = DirectHermesSecurePromptMethod(rawValue: cancellation.method) else { return }
        let key = DirectHermesSecurePromptKey(
            transportGeneration: expected.transportGeneration,
            wireID: Data(cancellation.id.utf8),
            method: method
        )
        guard let entry = pending[key] else { return }
        remove(entry, serverResponse: Self.retiredResponse)
    }

    func presentationBinding() -> Binding<DirectHermesSecurePrompt?> {
        let presented = activePrompt
        return Binding(
            get: { [weak self] in self?.activePrompt },
            set: { [weak self] value in
                guard value == nil, let presented else { return }
                Task { @MainActor [weak self] in await self?.cancel(presented) }
            }
        )
    }

    func prepareMCP(_ candidate: DirectHermesSecurePrompt) async {
        guard let entry = current(candidate), case .mcpSetup(let action) = entry.prompt.kind,
              mcpPresentation?.promptID != entry.prompt.id, !isWorking,
              let dependencies else { return }
        isWorking = true
        errorMessage = nil
        let key = entry.prompt.key
        do {
            let client = try dependencies.makeMCPClient(entry.prompt.profile)
            let snapshot = try await client.load()
            guard current(candidate)?.prompt.key == key else { return }
            mcpClients[key] = client
            switch action {
            case .install:
                guard let server = entry.prompt.server,
                      let catalog = snapshot.catalog.first(where: {
                          Data($0.name.utf8) == Data(server.utf8)
                      }) else {
                    throw CapabilitiesManagementError.invalidRequest
                }
                mcpPresentation = DirectHermesMCPSetupPresentation(
                    promptID: entry.prompt.id,
                    source: catalog.source.isEmpty ? catalog.url : catalog.source,
                    requirements: catalog.requiredEnvironment,
                    authorizationURL: nil,
                    authorizationStatus: nil
                )
            case .enable, .authorize:
                guard let server = entry.prompt.server,
                      let configured = snapshot.servers.first(where: {
                          Data($0.name.utf8) == Data(server.utf8)
                      }) else {
                    throw CapabilitiesManagementError.invalidRequest
                }
                mcpPresentation = DirectHermesMCPSetupPresentation(
                    promptID: entry.prompt.id,
                    source: configured.url ?? configured.command,
                    requirements: [],
                    authorizationURL: nil,
                    authorizationStatus: action == .authorize ? "Not started" : nil
                )
            }
        } catch is CancellationError {
        } catch {
            guard current(candidate)?.prompt.key == key else { return }
            errorMessage = "Hermes could not verify this MCP setup request. No change was sent."
        }
        if current(candidate)?.prompt.key == key { isWorking = false }
    }

    /// Returns an authorization URL only for the exact authorize action. Install
    /// and enable complete here after authoritative readback. No action is taken
    /// until this method is called by the user's explicit button press.
    func approveMCP(
        _ candidate: DirectHermesSecurePrompt,
        environment: [String: String]
    ) async -> URL? {
        guard let entry = current(candidate), case .mcpSetup(let action) = entry.prompt.kind,
              !isWorking, let dependencies, let client = mcpClients[entry.prompt.key],
              let server = entry.prompt.server else { return nil }
        let key = entry.prompt.key
        if action == .install {
            guard validateEnvironment(environment, for: candidate) else { return nil }
        } else if !environment.isEmpty {
            errorMessage = "This MCP action does not accept credential fields."
            return nil
        }
        isWorking = true
        errorMessage = nil
        var mutationStarted = false
        do {
            switch action {
            case .install:
                mutationStarted = true
                let result = try await client.installCatalog(name: server, environment: environment, enable: true)
                guard current(candidate)?.prompt.key == key else { return nil }
                if case .pending(let receipt, _) = result {
                    guard let statusClient = client.actionStatusClient else {
                        throw WorkspaceClientError.outcomeUnknown
                    }
                    let hostReceipt = try receipt.hostReceipt(using: statusClient)
                    let status = try await statusClient.poll(hostReceipt)
                    guard status.phase == .succeeded else { throw WorkspaceClientError.outcomeUnknown }
                    let snapshot = try await client.load()
                    guard snapshot.servers.contains(where: {
                        Data($0.name.utf8) == Data(server.utf8) && $0.isEnabled
                    }) else { throw WorkspaceClientError.outcomeUnknown }
                }
                await completeMCP(
                    entry,
                    status: "installed",
                    tools: [],
                    reload: dependencies.reloadMCP
                )
            case .enable:
                let snapshot = try await client.load()
                guard let configured = snapshot.servers.first(where: {
                    Data($0.name.utf8) == Data(server.utf8)
                }) else { throw CapabilitiesManagementError.invalidRequest }
                if !configured.isEnabled {
                    mutationStarted = true
                    _ = try await client.setEnabled(true, serverName: server)
                }
                guard current(candidate)?.prompt.key == key else { return nil }
                await completeMCP(
                    entry,
                    status: "enabled",
                    tools: [],
                    reload: dependencies.reloadMCP
                )
            case .authorize:
                mutationStarted = true
                let flow = try await client.startOAuth(serverName: server)
                guard current(candidate)?.prompt.key == key else { return nil }
                if flow.status == .approved {
                    await completeMCP(
                        entry,
                        status: "authorized",
                        tools: flow.tools.map(\.name),
                        reload: dependencies.reloadMCP
                    )
                    return nil
                }
                guard flow.status == .authorizationRequired || flow.status == .starting,
                      let url = flow.authorizationURL else {
                    throw WorkspaceClientError.outcomeUnknown
                }
                mcpFlows[key] = flow
                mcpPresentation = DirectHermesMCPSetupPresentation(
                    promptID: entry.prompt.id,
                    source: mcpPresentation?.source,
                    requirements: [],
                    authorizationURL: url,
                    authorizationStatus: "Waiting for authorization"
                )
                isWorking = false
                return url
            }
        } catch is CancellationError {
            if current(candidate)?.prompt.key == key { isWorking = false }
        } catch {
            guard current(candidate)?.prompt.key == key else { return nil }
            if mutationStarted {
                await completeMCPFailure(entry)
            } else {
                errorMessage = "Hermes rejected this MCP setup request before any change was confirmed."
                isWorking = false
            }
        }
        return nil
    }

    func checkMCPAuthorization(_ candidate: DirectHermesSecurePrompt) async {
        guard let entry = current(candidate), case .mcpSetup(.authorize) = entry.prompt.kind,
              !isWorking, let flow = mcpFlows[entry.prompt.key],
              let client = mcpClients[entry.prompt.key], let dependencies else { return }
        let key = entry.prompt.key
        isWorking = true
        errorMessage = nil
        do {
            let updated = try await client.pollOAuth(flowID: flow.id)
            guard current(candidate)?.prompt.key == key else { return }
            switch updated.status {
            case .approved:
                await completeMCP(
                    entry,
                    status: "authorized",
                    tools: updated.tools.map(\.name),
                    reload: dependencies.reloadMCP
                )
            case .starting, .authorizationRequired:
                mcpFlows[key] = updated
                mcpPresentation = DirectHermesMCPSetupPresentation(
                    promptID: entry.prompt.id,
                    source: mcpPresentation?.source,
                    requirements: [],
                    authorizationURL: updated.authorizationURL ?? flow.authorizationURL,
                    authorizationStatus: "Authorization is still pending"
                )
                isWorking = false
            case .error, .expired, .unknown:
                await completeMCPFailure(entry)
            }
        } catch is CancellationError {
            if current(candidate)?.prompt.key == key { isWorking = false }
        } catch {
            // Polling can persist the newly approved token. An unknown outcome is
            // never replayed; close this setup request with an honest error.
            guard current(candidate)?.prompt.key == key else { return }
            await completeMCPFailure(entry)
        }
    }

    func submitSecret(_ candidate: DirectHermesSecurePrompt, value: String) async {
        guard !isWorking, let entry = current(candidate),
              [.secret, .sudo, .vaultUnlock].contains(entry.prompt.kind),
              Self.validSecret(value) else {
            errorMessage = "Enter a nonempty value before sending."
            return
        }
        errorMessage = nil
        await respond(entry, value: value)
    }

    func submitCode(_ candidate: DirectHermesSecurePrompt, code: String) async {
        let value = code.filter { !$0.isWhitespace && $0 != "-" }
        guard !isWorking, let entry = current(candidate), entry.prompt.kind == .vaultCode,
              (1...64).contains(value.count), value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            errorMessage = "Enter the code the site sent you."
            return
        }
        errorMessage = nil
        await respond(entry, value: value)
    }

    /// Hermes parses the answer as `{identifier, password}` and stores it in its
    /// vault for the page's origin.
    func submitLogin(_ candidate: DirectHermesSecurePrompt, identifier: String, password: String) async {
        let name = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isWorking, let entry = current(candidate), entry.prompt.kind == .vaultSaveLogin,
              Self.validIdentifier(name, maximumBytes: 512), Self.validLoginPassword(password) else {
            errorMessage = "Enter the email or username and the password."
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(["identifier": name, "password": password]),
              let value = String(data: data, encoding: .utf8) else { return }
        errorMessage = nil
        await respond(entry, value: value)
    }

    func cancel(_ candidate: DirectHermesSecurePrompt) async {
        guard let entry = current(candidate), !isWorking else { return }
        isWorking = true
        if case .mcpSetup = entry.prompt.kind,
           let flow = mcpFlows[entry.prompt.key],
           let client = mcpClients[entry.prompt.key] {
            // One cancellation attempt only. A transport-unknown result is not
            // retried and never broadens the original authorization scope.
            _ = try? await client.cancelOAuth(flowID: flow.id)
        }
        guard current(candidate)?.prompt.key == entry.prompt.key else { return }
        switch entry.prompt.kind {
        case .secret, .sudo, .vaultCode, .vaultSaveLogin, .vaultUnlock:
            await respond(entry, value: "")
        case .mcpSetup:
            let value = Self.mcpOutcome(status: "declined", server: entry.prompt.server ?? "")
            await respond(entry, value: value)
        }
    }

    private func completeMCP(
        _ entry: Pending,
        status: String,
        tools: [String],
        reload: DirectHermesMCPReloader
    ) async {
        var detail: String?
        do { try await reload(entry.prompt.runtimeSessionID) }
        catch { detail = "Hermes confirmed the setup change. The server will be available in a new session if live reload did not finish." }
        guard current(entry.prompt)?.prompt.key == entry.prompt.key else { return }
        let value = Self.mcpOutcome(
            status: status,
            server: entry.prompt.server ?? "",
            detail: detail,
            tools: tools
        )
        await respond(entry, value: value)
    }

    private func completeMCPFailure(_ entry: Pending) async {
        let value = Self.mcpOutcome(
            status: "error",
            server: entry.prompt.server ?? "",
            detail: "The setup outcome could not be confirmed. Review MCP Servers before trying again."
        )
        await respond(entry, value: value)
    }

    private func respond(_ entry: Pending, value: String) async {
        guard pending[entry.prompt.key]?.prompt.id == entry.prompt.id else { return }
        switch entry.delivery {
        case .serverRequest:
            remove(
                entry,
                serverResponse: .result(.object(["value": .string(value)]))
            )
        case .legacyEvent:
            guard let dependencies else { remove(entry); return }
            let method: String
            let valueKey: String
            switch entry.prompt.key.method {
            case .secret: (method, valueKey) = ("secret.respond", "value")
            case .sudo: (method, valueKey) = ("sudo.respond", "password")
            case .mcpSetup: (method, valueKey) = ("mcp.setup.respond", "result")
            // Vault prompts arrive only as server requests, never legacy events.
            case .vaultCode, .vaultSaveLogin, .vaultUnlock: remove(entry); return
            }
            // One dispatch only. The input has already been cleared by the view,
            // and this entry is locked while the RPC is in flight. Success,
            // expiry, and transport-unknown outcomes all retire it without replay.
            isWorking = true
            _ = try? await dependencies.respondToLegacyPrompt(method, [
                "request_id": .string(entry.prompt.wireID),
                valueKey: .string(value),
            ])
            guard pending[entry.prompt.key]?.prompt.id == entry.prompt.id else { return }
            remove(entry)
        }
    }

    private func decode(
        id: String,
        method: DirectHermesSecurePromptMethod,
        params: [String: BighelpJSONValue],
        origin: DirectHermesSecurePrompt.Origin,
        connection expected: DirectHermesPromptConnection
    ) throws -> DirectHermesSecurePrompt {
        guard Self.validIdentifier(id, maximumBytes: 4_096),
              let runtimeID = params["session_id"]?.string,
              Self.validIdentifier(runtimeID, maximumBytes: 4_096),
              let binding = bindings[Data(runtimeID.utf8)] else {
            throw DirectHermesError.invalidResponse
        }
        let kind: DirectHermesSecurePrompt.Kind
        let envVar: String?
        let promptText: String?
        let server: String?
        let reason: String?
        var isAgentRequest = false
        var label: String?
        var site: String?
        switch method {
        case .secret:
            guard Set(params.keys).isSubset(of: ["session_id", "env_var", "prompt", "metadata"]),
                  let variable = params["env_var"]?.string,
                  Self.validIdentifier(variable, maximumBytes: 4_096),
                  let message = params["prompt"]?.string,
                  Self.validText(message, maximumBytes: 65_536),
                  params["metadata"].map({ $0 == .null || $0.object != nil }) ?? true else {
                throw DirectHermesError.invalidResponse
            }
            kind = .secret
            envVar = variable
            promptText = message
            server = nil
            reason = nil
            let metadata = params["metadata"]?.object
            isAgentRequest = metadata?["source"]?.string == "agent"
            label = metadata?["label"]?.string.flatMap { value -> String? in
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty || text.utf8.count > 120 ? nil : text
            }
        case .sudo:
            guard Set(params.keys) == Set(["session_id"]) else {
                throw DirectHermesError.invalidResponse
            }
            kind = .sudo
            envVar = nil
            promptText = nil
            server = nil
            reason = nil
        case .mcpSetup:
            guard Set(params.keys).isSubset(of: ["session_id", "server", "action", "reason"]),
                  let serverName = params["server"]?.string,
                  Self.validIdentifier(serverName, maximumBytes: 160) else {
                throw DirectHermesError.invalidResponse
            }
            let rawAction: String
            if params["action"] == nil || params["action"] == .null { rawAction = "install" }
            else if let value = params["action"]?.string { rawAction = value }
            else { throw DirectHermesError.invalidResponse }
            guard let action = DirectHermesSecurePrompt.MCPAction(rawValue: rawAction),
                  params["reason"].map({
                      $0 == .null || ($0.string.map { Self.validText($0, maximumBytes: 65_536) } ?? false)
                  }) ?? true else {
                throw DirectHermesError.invalidResponse
            }
            kind = .mcpSetup(action)
            envVar = nil
            promptText = nil
            server = serverName
            reason = params["reason"]?.string
        case .vaultCode:
            guard Set(params.keys).isSubset(of: ["session_id", "site", "hint"]),
                  let named = Self.optionalLabel(params["site"], maximumBytes: 255),
                  let hint = Self.optionalLabel(params["hint"], maximumBytes: 500) else {
                throw DirectHermesError.invalidResponse
            }
            kind = .vaultCode
            site = named.isEmpty ? nil : named
            promptText = hint.isEmpty ? nil : hint
            envVar = nil
            server = nil
            reason = nil
        case .vaultSaveLogin:
            guard Set(params.keys) == ["session_id", "origin", "site"],
                  let origin = params["origin"]?.string, Self.validOrigin(origin),
                  Self.optionalLabel(params["site"], maximumBytes: 255) != nil else {
                throw DirectHermesError.invalidResponse
            }
            kind = .vaultSaveLogin
            // The origin, not the agent's label: people recognise addresses.
            site = origin
            envVar = nil
            promptText = nil
            server = nil
            reason = nil
        case .vaultUnlock:
            guard Set(params.keys) == ["session_id", "backend", "display_name"],
                  let backend = params["backend"]?.string, Self.validIdentifier(backend, maximumBytes: 64),
                  let name = Self.optionalLabel(params["display_name"], maximumBytes: 120) else {
                throw DirectHermesError.invalidResponse
            }
            kind = .vaultUnlock
            server = name.isEmpty ? backend : name
            envVar = nil
            promptText = nil
            reason = nil
        }
        let key = DirectHermesSecurePromptKey(
            transportGeneration: expected.transportGeneration,
            wireID: Data(id.utf8),
            method: method
        )
        return DirectHermesSecurePrompt(
            id: Self.presentationID(for: key),
            origin: origin,
            kind: kind,
            wireID: id,
            hostIdentity: String(decoding: expected.principalIdentity, as: UTF8.self),
            profile: String(decoding: binding.profile, as: UTF8.self),
            runtimeSessionID: runtimeID,
            visibleSessionID: String(decoding: binding.visibleSessionID, as: UTF8.self),
            envVar: envVar,
            prompt: promptText,
            server: server,
            reason: reason,
            isAgentRequest: isAgentRequest,
            label: label,
            site: site,
            createdAt: .now,
            key: key
        )
    }

    private func validateEnvironment(
        _ environment: [String: String],
        for prompt: DirectHermesSecurePrompt
    ) -> Bool {
        guard let presentation = mcpPresentation,
              presentation.promptID == prompt.id else { return false }
        let allowed = Set(presentation.requirements.map(\.name))
        guard environment.count <= 32, Set(environment.keys).isSubset(of: allowed),
              presentation.requirements.filter(\.isRequired).allSatisfy({
                  Self.validMCPSecret(environment[$0.name] ?? "")
              }), environment.allSatisfy({
                  Self.validIdentifier($0.key, maximumBytes: 128)
                      && ($0.value.isEmpty || Self.validMCPSecret($0.value))
              }) else {
            errorMessage = "Complete every required credential field before installing this server."
            return false
        }
        return true
    }

    private func current(_ candidate: DirectHermesSecurePrompt) -> Pending? {
        guard let entry = pending[candidate.key], entry.connection == connection,
              let binding = bindings[Data(entry.prompt.runtimeSessionID.utf8)],
              entry.prompt.id == candidate.id,
              Data(entry.prompt.hostIdentity.utf8) == entry.connection.principalIdentity,
              Data(entry.prompt.profile.utf8) == binding.profile,
              Data(entry.prompt.visibleSessionID.utf8) == binding.visibleSessionID else {
            return nil
        }
        return entry
    }

    private func cancelHandler(
        key: DirectHermesSecurePromptKey,
        connection expected: DirectHermesPromptConnection
    ) {
        guard let entry = pending[key], entry.connection == expected else { return }
        remove(entry, serverResponse: Self.retiredResponse)
    }

    private func remove(
        _ entry: Pending,
        serverResponse: DirectHermesServerResponse? = nil
    ) {
        guard pending.removeValue(forKey: entry.prompt.key) != nil else { return }
        mcpClients[entry.prompt.key] = nil
        mcpFlows[entry.prompt.key] = nil
        if case .serverRequest(let continuation) = entry.delivery {
            continuation.resume(returning: serverResponse ?? Self.retiredResponse)
        }
        activePromptDidChange()
    }

    private func retirePending(runtimeKey: Data, response: DirectHermesServerResponse) {
        let entries = pending.values.filter {
            Data($0.prompt.runtimeSessionID.utf8) == runtimeKey
        }
        for entry in entries { remove(entry, serverResponse: response) }
    }

    private func retireAll(with response: DirectHermesServerResponse) {
        let entries = Array(pending.values)
        pending.removeAll(keepingCapacity: false)
        for entry in entries {
            if case .serverRequest(let continuation) = entry.delivery {
                continuation.resume(returning: response)
            }
        }
        mcpClients.removeAll(keepingCapacity: false)
        mcpFlows.removeAll(keepingCapacity: false)
    }

    private func isCurrent(_ expected: DirectHermesPromptConnection) -> Bool {
        connection == expected
    }

    private func activePromptDidChange() {
        let nextID = activePrompt.map { Data($0.id.utf8) }
        if nextID != activePresentationID {
            activePresentationID = nextID
            resetMCPPresentation()
        }
        changed()
    }

    private func resetMCPPresentation() {
        mcpPresentation = nil
        isWorking = false
        errorMessage = nil
    }

    private func changed() {
        revision &+= 1
    }

    private static func sortPrompts(
        _ lhs: DirectHermesSecurePrompt,
        _ rhs: DirectHermesSecurePrompt
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
    }

    private static func presentationID(for key: DirectHermesSecurePromptKey) -> String {
        var bytes = Data(key.transportGeneration.rawValue.uuidString.utf8)
        bytes.append(0)
        bytes.append(key.wireID)
        bytes.append(0)
        bytes.append(contentsOf: key.method.rawValue.utf8)
        let digest = Data(SHA256.hash(data: bytes))
        return "dhs_" + digest.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func mcpOutcome(
        status: String,
        server: String,
        detail: String? = nil,
        tools: [String] = []
    ) -> String {
        var value: [String: BighelpJSONValue] = [
            "server": .string(server),
            "status": .string(status),
        ]
        if let detail { value["detail"] = .string(detail) }
        if !tools.isEmpty { value["tools"] = .array(tools.map(BighelpJSONValue.string)) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(BighelpJSONValue.object(value)),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"server\":\"\",\"status\":\"error\"}"
        }
        return text
    }

    private static func same(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (let lhs?, let rhs?): Data(lhs.utf8) == Data(rhs.utf8)
        default: false
        }
    }

    private static func validIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    }

    private static func validText(_ value: String, maximumBytes: Int) -> Bool {
        value.utf8.count <= maximumBytes && !value.contains("\0")
    }

    private static func validMCPSecret(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384
            && !value.contains("\n") && !value.contains("\r") && !value.contains("\0")
    }

    /// A missing or null label is empty; a present one is bounded single-line text.
    private static func optionalLabel(_ value: BighelpJSONValue?, maximumBytes: Int) -> String? {
        guard let value, value != .null else { return "" }
        guard let text = value.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.utf8.count <= maximumBytes,
              !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        return text
    }

    private static func validOrigin(_ value: String) -> Bool {
        guard value.utf8.count <= 2_048, let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return !value.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7f })
    }

    private static func validLoginPassword(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4_096 && !value.contains("\0")
    }

    private static func validSecret(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 65_536 && !value.contains("\0")
    }

    private static let invalidParamsResponse = DirectHermesServerResponse.error(
        code: -32602,
        message: "Invalid secure prompt parameters"
    )
    private static let retiredResponse = DirectHermesServerResponse.error(
        code: -32000,
        message: "Secure prompt is no longer active"
    )
}

/// Mount exactly once above the selected native workspace. The sheet binding
/// maps every dismiss path to an explicit refusal; host/scene retirement clears
/// the store synchronously through DirectHermesWorkspaceStore.
@MainActor
struct DirectHermesSecurePromptOverlay: View {
    @Bindable private var store: DirectHermesSecurePromptStore

    init(workspace: DirectHermesWorkspaceStore) {
        _store = Bindable(wrappedValue: workspace.securePromptStore)
    }

    var body: some View {
        let _ = store.revision
        // A sheet needs a real view to hang from; EmptyView never presents one.
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .bighelpSheet(item: store.presentationBinding()) { prompt in
                DirectHermesSecurePromptView(
                    store: store,
                    prompt: prompt
                )
                .bighelpSheetSize(Self.sheetSize(prompt))
            }
    }

    /// One secret or password is a short panel; MCP setup lists its settings.
    private static func sheetSize(_ prompt: DirectHermesSecurePrompt) -> BighelpSheetSize {
        if case .mcpSetup = prompt.kind { return .standard }
        return .compact
    }
}

@MainActor
private struct DirectHermesSecurePromptView: View {
    let store: DirectHermesSecurePromptStore
    let prompt: DirectHermesSecurePrompt

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var value = ""
    @State private var identifier = ""
    @State private var environment: [String: String] = [:]
    @FocusState private var focusedField: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(prompt.detail)
                        .textSelection(.enabled)
                    if let site = prompt.site {
                        LabeledContent("Site", value: site)
                            .accessibilityIdentifier("direct-hermes.vault-site")
                    }
                    LabeledContent(prompt.isAgentRequest || isVault ? "Agent" : "Profile", value: prompt.profile)
                    if let server = prompt.server {
                        LabeledContent("Server", value: server)
                    }
                    if let source = store.mcpPresentation?.source, !source.isEmpty {
                        LabeledContent("Source", value: source)
                    }
                } header: {
                    Text(prompt.title)
                }

                switch prompt.kind {
                case .secret:
                    secureValueSection(label: prompt.isAgentRequest ? (prompt.label ?? "Secret") : (prompt.envVar ?? "Secret"))
                case .sudo:
                    secureValueSection(label: "Password")
                case .mcpSetup:
                    mcpSection
                case .vaultCode:
                    codeSection
                case .vaultSaveLogin:
                    loginSection
                case .vaultUnlock:
                    secureValueSection(label: "Master password", submitTitle: "Unlock",
                        footer: "Unlocks it on your computer for this session only. bighelp doesn't keep your master password or add it to chat.")
                }

                if let errorMessage = store.errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.secondary)
                    }
                }
            }
            .bighelpFormSurface()
            .navigationTitle(prompt.isAgentRequest || isVault ? "Secure input" : "Hermes request")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(store.isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { cancel() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(store.isWorking)
                        .bighelpToolbarText()
                }
            }
            .task(id: prompt.id) {
                clearSensitiveState()
                if case .mcpSetup = prompt.kind { await store.prepareMCP(prompt) }
                switch prompt.kind {
                case .secret, .sudo, .vaultCode, .vaultUnlock: focusedField = "primary"
                case .vaultSaveLogin: focusedField = "identifier"
                case .mcpSetup: break
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase != .active else { return }
                clearSensitiveState()
            }
            .onDisappear { clearSensitiveState() }
        }
        .accessibilityIdentifier("direct-hermes.secure-prompt.\(prompt.id)")
    }

    private var isVault: Bool {
        [.vaultCode, .vaultSaveLogin, .vaultUnlock].contains(prompt.kind)
    }

    @ViewBuilder
    private func secureValueSection(label: String, submitTitle: String = "Send securely",
                                    footer: String? = nil) -> some View {
        Section {
            SecureField(label, text: $value)
                .focused($focusedField, equals: "primary")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .accessibilityIdentifier("direct-hermes.secure-input")
            Button(submitTitle) { submitSecret() }
                .disabled(value.isEmpty || store.isWorking)
                .accessibilityIdentifier("direct-hermes.secure-submit")
        } header: {
            Text("Secure response")
        } footer: {
            if let footer {
                Text(footer)
            } else if prompt.isAgentRequest, let name = prompt.envVar {
                Text("Saved privately on your computer as \(name). Your agent can use it in commands but never sees what you type, and bighelp doesn't keep it or add it to chat.")
            } else {
                Text("This value is sent only to the waiting request. bighelp does not save it, add it to chat, or copy it to the clipboard.")
            }
        }
    }

    /// Not masked: a one-time code is short-lived, and iOS can fill it from Messages.
    private var codeSection: some View {
        Section {
            TextField("Code", text: $value)
                .focused($focusedField, equals: "primary")
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .submitLabel(.send)
                .onSubmit { submitCode() }
                .accessibilityIdentifier("direct-hermes.vault-code")
            Button("Enter code") { submitCode() }
                .disabled(value.isEmpty || store.isWorking)
                .accessibilityIdentifier("direct-hermes.secure-submit")
        } header: {
            Text("One-time code")
        } footer: {
            Text("Hermes types the code into the waiting page on your computer. Your agent never sees it, and bighelp doesn't keep it or add it to chat.")
        }
    }

    private var loginSection: some View {
        Section {
            TextField("Email or username", text: $identifier)
                .focused($focusedField, equals: "identifier")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .submitLabel(.next)
                .onSubmit { focusedField = "primary" }
                .accessibilityIdentifier("direct-hermes.vault-identifier")
            SecureField("Password", text: $value)
                .focused($focusedField, equals: "primary")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .accessibilityIdentifier("direct-hermes.secure-input")
            Button("Save and sign in") { submitLogin() }
                .disabled(identifier.isEmpty || value.isEmpty || store.isWorking)
                .accessibilityIdentifier("direct-hermes.secure-submit")
        } header: {
            Text("Login")
        } footer: {
            Text("Saved in Hermes' vault on your computer for this site only, then filled into the page. Your agent never sees the password, and bighelp doesn't keep it or add it to chat.")
        }
    }

    @ViewBuilder
    private var mcpSection: some View {
        if let presentation = store.mcpPresentation,
           presentation.promptID == prompt.id {
            if !presentation.requirements.isEmpty {
                Section {
                    ForEach(presentation.requirements) { requirement in
                        SecureField(
                            requirement.isRequired ? requirement.prompt : "\(requirement.prompt) (optional)",
                            text: environmentBinding(requirement.name)
                        )
                        .focused($focusedField, equals: requirement.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .accessibilityLabel(requirement.prompt)
                        .accessibilityIdentifier("direct-hermes.mcp-secret.\(requirement.name)")
                    }
                } header: {
                    Text("Required credentials")
                } footer: {
                    Text("Credential values are submitted only with this approved install and are never read back into bighelp.")
                }
            }
            Section {
                if let status = presentation.authorizationStatus {
                    Text(status).foregroundStyle(.secondary)
                }
                if let url = presentation.authorizationURL {
                    Button("Open authorization page", systemImage: "arrow.up.right.square") {
                        openURL(url)
                    }
                    Button("Check authorization") {
                        Task { await store.checkMCPAuthorization(prompt) }
                    }
                    .disabled(store.isWorking)
                } else {
                    Button(mcpActionTitle) { approveMCP() }
                        .disabled(!mcpRequirementsSatisfied(presentation) || store.isWorking)
                        .accessibilityIdentifier("direct-hermes.mcp-approve")
                }
                if store.isWorking { ProgressView("Working with Hermes") }
            } header: {
                Text("Action")
            } footer: {
                Text(mcpFooter)
            }
        } else {
            Section("Verification") {
                if store.isWorking {
                    ProgressView("Verifying MCP request")
                } else {
                    Button("Try verification again") {
                        Task { await store.prepareMCP(prompt) }
                    }
                }
            }
        }
    }

    private var mcpActionTitle: String {
        switch prompt.kind {
        case .mcpSetup(.install): "Install and enable"
        case .mcpSetup(.enable): "Enable server"
        case .mcpSetup(.authorize): "Start authorization"
        case .secret, .sudo, .vaultCode, .vaultSaveLogin, .vaultUnlock: "Continue"
        }
    }

    private var mcpFooter: String {
        switch prompt.kind {
        case .mcpSetup(.install):
            "Only the displayed catalog server and credential fields will be installed."
        case .mcpSetup(.enable):
            "This enables only the named configured server for the requesting profile."
        case .mcpSetup(.authorize):
            "Authorization starts only after you choose Start authorization. bighelp does not expand the server's requested scope."
        case .secret, .sudo, .vaultCode, .vaultSaveLogin, .vaultUnlock:
            ""
        }
    }

    private func environmentBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { environment[name] ?? "" },
            set: { environment[name] = $0 }
        )
    }

    private func mcpRequirementsSatisfied(_ presentation: DirectHermesMCPSetupPresentation) -> Bool {
        presentation.requirements.filter(\.isRequired).allSatisfy {
            !(environment[$0.name] ?? "").isEmpty
        }
    }

    private func submitSecret() {
        let submitted = value
        value = ""
        focusedField = nil
        Task { await store.submitSecret(prompt, value: submitted) }
    }

    private func submitCode() {
        let submitted = value
        guard !submitted.isEmpty else { return }
        value = ""
        focusedField = nil
        Task { await store.submitCode(prompt, code: submitted) }
    }

    private func submitLogin() {
        let name = identifier
        let password = value
        identifier = ""
        value = ""
        focusedField = nil
        Task { await store.submitLogin(prompt, identifier: name, password: password) }
    }

    private func approveMCP() {
        let submitted = environment
        environment.removeAll(keepingCapacity: false)
        focusedField = nil
        Task {
            if let url = await store.approveMCP(prompt, environment: submitted) {
                openURL(url)
            }
        }
    }

    private func cancel() {
        clearSensitiveState()
        Task { await store.cancel(prompt) }
    }

    private func clearSensitiveState() {
        value = ""
        identifier = ""
        environment.removeAll(keepingCapacity: false)
        focusedField = nil
    }
}

#if DEBUG && targetEnvironment(simulator)
/// `-test-secure-input`: an agent's secure input request, for screenshots.
enum DirectHermesSecurePromptFixture {
    static let launchArgument = "-test-secure-input"

    @MainActor
    static func rootView() -> some View { FixtureHost() }

    @MainActor
    private struct FixtureHost: View {
        @State private var store = DirectHermesSecurePromptStore()
        @State private var identity = NSObject()

        var body: some View {
            let _ = store.revision
            NavigationStack {
                Text("Chat").navigationTitle("Juniper")
            }
            .bighelpSheet(item: store.presentationBinding()) { prompt in
                DirectHermesSecurePromptView(store: store, prompt: prompt)
            }
            .task { await request() }
        }

        private func request() async {
            let connection = DirectHermesPromptConnection(owner: UUID(), principalIdentity: "host",
                clientIdentity: ObjectIdentifier(identity), transportGeneration: .init(UUID()))
            let unsupported: @MainActor @Sendable (String) async throws -> Void = { _ in
                throw WorkspaceClientError.unavailable(.unsupportedOperation)
            }
            store.beginConnection(connection, dependencies: .init(
                respondToLegacyPrompt: { _, _ in throw WorkspaceClientError.unavailable(.unsupportedOperation) },
                makeMCPClient: { _ in throw WorkspaceClientError.unavailable(.unsupportedOperation) },
                reloadMCP: unsupported))
            try? store.bind(profile: "juniper", runtimeID: "runtime", visibleSessionID: "chat", connection: connection)
            _ = await store.handle(.init(id: "fixture", method: "secret", params: [
                "session_id": .string("runtime"), "env_var": .string("GITHUB_TOKEN"),
                "prompt": .string("Paste a GitHub token with repo access so I can open the pull request for you."),
                "metadata": .object(["source": .string("agent"), "label": .string("GitHub token")]),
            ]), connection: connection)
        }
    }
}
#endif
