import Foundation
import Observation

/// Signing in to accounts that only sign in from a terminal on the host
/// (the Copilot CLI, Claude Code, Hermes' own GitHub login for Copilot). The
/// bighelp plugin runs the provider's own tool there; the phone shows its link
/// and code, and sends back a code the provider's page shows. The plugin's
/// `native-provider-sign-in-v1` route is the source of which accounts can.
struct HostSignInProvider: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case ready(signedIn: Bool?)
        case notInstalled(installCommand: String?)
        case retired(message: String, replacementKey: String?)
    }

    let providerID: String
    let name: String
    let client: String
    let flow: HostSignInFlow
    let state: State
    let documentationURL: URL?
}

enum HostSignInFlow: String, Sendable {
    /// The provider's page confirms by itself after the code is entered there.
    case device
    /// The provider's page shows a code to paste back into bighelp.
    case paste
}

struct HostSignInSession: Equatable, Sendable {
    enum Status: String, Sendable {
        case starting, waiting, needsCode, finishing, signedIn, failed, expired, cancelled
    }

    let id: String
    let providerID: String
    let flow: HostSignInFlow
    let status: Status
    let link: URL?
    let code: String?
    let message: String?

    var isRunning: Bool { [.starting, .waiting, .needsCode, .finishing].contains(status) }
}

enum HostSignInCodec {
    static func isIdentifier(_ value: String) -> Bool {
        value.wholeMatch(of: /[a-z0-9][a-z0-9._-]{0,63}/) != nil
    }

    static func providers(_ value: [String: BighelpJSONValue]) -> [HostSignInProvider] {
        (value["providers"]?.array ?? []).prefix(64).compactMap { item -> HostSignInProvider? in
            guard let row = item.object, let id = row["providerId"]?.string, isIdentifier(id) else { return nil }
            let name = text(row["name"], limit: 120) ?? id
            let client = text(row["client"], limit: 80) ?? name
            let state: HostSignInProvider.State
            switch row["state"]?.string {
            case "ready":
                state = .ready(signedIn: row["signedIn"]?.boolean)
            case "notInstalled":
                state = .notInstalled(installCommand: text(row["installCommand"], limit: 300).flatMap(
                    DirectHermesProviderClient.terminalCommand))
            case "retired":
                let key = text(row["replacementKey"], limit: 128).flatMap { $0.wholeMatch(of: /[A-Z][A-Z0-9_]{0,127}/) != nil ? $0 : nil }
                state = .retired(message: text(row["message"], limit: 400) ?? "This sign-in is no longer offered.",
                                 replacementKey: key)
            default:
                return nil
            }
            return HostSignInProvider(providerID: id, name: name, client: client,
                                      flow: HostSignInFlow(rawValue: row["flow"]?.string ?? "") ?? .device,
                                      state: state, documentationURL: webURL(row["docsURL"]))
        }
    }

    static func session(_ value: [String: BighelpJSONValue]) throws -> HostSignInSession {
        guard let id = value["sessionId"]?.string, UUID(uuidString: id) != nil,
              let provider = value["providerId"]?.string, isIdentifier(provider) else {
            throw WorkspaceClientError.invalidResponse
        }
        // A status this build doesn't know yet is treated as the end, never as waiting forever.
        let status = HostSignInSession.Status(rawValue: value["status"]?.string ?? "") ?? .failed
        let code = text(value["code"], limit: 32).flatMap { code in
            code.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7f } ? code : nil
        }
        return HostSignInSession(id: id.lowercased(), providerID: provider,
                                 flow: HostSignInFlow(rawValue: value["flow"]?.string ?? "") ?? .device,
                                 status: status, link: webURL(value["link"]), code: code,
                                 message: text(value["message"], limit: 400))
    }

    private static func text(_ value: BighelpJSONValue?, limit: Int) -> String? {
        guard let raw = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              raw.utf8.count <= limit * 4,
              raw.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return nil }
        return String(raw.prefix(limit))
    }

    /// Only https links reach the sign-in sheet.
    private static func webURL(_ value: BighelpJSONValue?) -> URL? {
        guard let raw = value?.string, raw.utf8.count <= 4_096, let url = URL(string: raw),
              url.scheme?.lowercased() == "https", url.host() != nil, url.user() == nil else { return nil }
        return url
    }
}

@MainActor
protocol HostSignInClient: AnyObject {
    func providers(agentID: String) async throws -> [HostSignInProvider]
    func start(agentID: String, providerID: String) async throws -> HostSignInSession
    func status(agentID: String, sessionID: String) async throws -> HostSignInSession
    func submit(agentID: String, sessionID: String, code: String) async throws -> HostSignInSession
    func cancel(agentID: String, sessionID: String) async throws -> HostSignInSession
}

/// The plugin's sign-in route over the current connection to the same host and sign-in.
@MainActor
final class DirectHermesHostSignInClient: HostSignInClient {
    private let owner: WorkspaceOwner
    private let currentWorkspace: @MainActor () -> (any WorkspaceOperationPerforming)?

    init(owner: WorkspaceOwner, currentWorkspace: @escaping @MainActor () -> (any WorkspaceOperationPerforming)?) {
        self.owner = owner
        self.currentWorkspace = currentWorkspace
    }

    private func perform(_ operation: WorkspaceOperation, _ payload: [String: BighelpJSONValue]) async throws
        -> [String: BighelpJSONValue] {
        guard let workspace = currentWorkspace() else { throw WorkspaceClientError.transportUnavailable }
        guard workspace.owner == owner else { throw WorkspaceClientError.ownerChanged }
        do {
            return try await workspace.perform(operation, payload: payload, owner: owner)
        } catch WorkspaceClientError.conflict where [.providerSignInList, .providerSignInStatus].contains(operation) {
            // The plugin's context changed (412): reads load it again, once.
            return try await workspace.perform(operation, payload: payload, owner: owner)
        }
    }

    func providers(agentID: String) async throws -> [HostSignInProvider] {
        HostSignInCodec.providers(try await perform(.providerSignInList, ["agentId": .string(agentID)]))
    }

    func start(agentID: String, providerID: String) async throws -> HostSignInSession {
        try HostSignInCodec.session(try await perform(.providerSignInStart, [
            "agentId": .string(agentID), "providerId": .string(providerID)]))
    }

    func status(agentID: String, sessionID: String) async throws -> HostSignInSession {
        try HostSignInCodec.session(try await perform(.providerSignInStatus, [
            "agentId": .string(agentID), "sessionId": .string(sessionID)]))
    }

    func submit(agentID: String, sessionID: String, code: String) async throws -> HostSignInSession {
        try HostSignInCodec.session(try await perform(.providerSignInSubmit, [
            "agentId": .string(agentID), "sessionId": .string(sessionID), "code": .string(code)]))
    }

    func cancel(agentID: String, sessionID: String) async throws -> HostSignInSession {
        try HostSignInCodec.session(try await perform(.providerSignInCancel, [
            "agentId": .string(agentID), "sessionId": .string(sessionID)]))
    }
}

/// Which terminal-only accounts this host can sign in to from the phone, and the
/// one sign-in running now. `onSignedIn` reloads Provider Keys once Hermes has it.
@MainActor @Observable
final class ProviderHostSignInStore {
    let profileID: String
    let hostName: String
    /// False when the host's plugin has no sign-in route (older, or no plugin).
    private(set) var isSupported = false
    private(set) var providers: [HostSignInProvider] = []
    private(set) var session: HostSignInSession?
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let client: any HostSignInClient
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored var onSignedIn: (@MainActor () async -> Void)?

    init(profileID: String, hostName: String, client: any HostSignInClient, pollInterval: Duration = .seconds(2)) {
        self.profileID = profileID
        self.hostName = hostName
        self.client = client
        self.pollInterval = pollInterval
    }

    func provider(_ id: String) -> HostSignInProvider? { providers.first { $0.providerID == id } }

    func load() async {
        do {
            providers = try await client.providers(agentID: profileID)
            isSupported = true
        } catch is CancellationError {
        } catch let error as WorkspaceClientError {
            if case .unavailable = error {
                isSupported = false
                providers = []
            }
        } catch {}
    }

    @discardableResult
    func start(providerID: String) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        pollTask?.cancel()
        do {
            let started = try await client.start(agentID: profileID, providerID: providerID)
            session = started
            follow(started)
            return true
        } catch is CancellationError {
            return false
        } catch {
            session = nil
            errorMessage = message(error, providerID: providerID)
            return false
        }
    }

    func submit(code: String) async {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = session, current.status == .needsCode, !code.isEmpty, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let next = try await client.submit(agentID: profileID, sessionID: current.id, code: code)
            guard session?.id == current.id else { return }
            session = next
            follow(next)
        } catch is CancellationError {
        } catch {
            errorMessage = message(error, providerID: current.providerID)
        }
    }

    /// The sheet closed: a sign-in still running is stopped on the host.
    func close() async {
        pollTask?.cancel()
        pollTask = nil
        guard let current = session else { return }
        session = nil
        errorMessage = nil
        if current.isRunning {
            _ = try? await client.cancel(agentID: profileID, sessionID: current.id)
        }
    }

    func retire() {
        pollTask?.cancel()
        pollTask = nil
        session = nil
    }

    private func follow(_ current: HostSignInSession) {
        pollTask?.cancel()
        pollTask = nil
        guard current.isRunning else {
            if current.status == .signedIn { Task { await finishSignIn() } }
            return
        }
        pollTask = Task { @MainActor [weak self] in
            var latest = current
            while !Task.isCancelled, latest.isRunning {
                guard let interval = self?.pollInterval else { return }
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, self.session?.id == latest.id else { return }
                do {
                    latest = try await self.client.status(agentID: self.profileID, sessionID: latest.id)
                } catch is CancellationError {
                    return
                } catch {
                    // A dropped connection gets another try on the next tick.
                    continue
                }
                guard !Task.isCancelled, self.session?.id == latest.id else { return }
                self.session = latest
            }
            guard let self, !Task.isCancelled, latest.status == .signedIn else { return }
            self.pollTask = nil
            await self.finishSignIn()
        }
    }

    private func finishSignIn() async {
        await load()
        await onSignedIn?()
    }

    private func message(_ error: any Error, providerID: String) -> String {
        let client = provider(providerID)?.client ?? "The sign-in tool"
        switch error as? WorkspaceClientError {
        case .rejected(let code, _)?:
            switch code {
            case "sign_in_tool_missing": return "\(client) isn't installed on \(hostName)."
            case "sign_in_retired": return "This sign-in is no longer offered."
            case "sign_in_not_found": return "That sign-in stopped. Try again."
            case "sign_in_not_waiting": return "\(client) isn't waiting for a code right now."
            case "sign_in_code_invalid": return "That doesn't look like the code from the page. Copy it again."
            case "sign_in_busy": return "Too many sign-ins are running on \(hostName). Try again in a minute."
            case "sign_in_unavailable": return "This account can't sign in from \(BighelpPlatform.isMac ? "this Mac" : "the phone")."
            default: return "\(hostName) couldn't start the sign-in. Try again."
            }
        case .unavailable?:
            return "Update the bighelp plugin on \(hostName) to sign in from your \(BighelpPlatform.isMac ? "Mac" : "phone")."
        case .outcomeUnknown?, .transportUnavailable?:
            return "\(client) couldn't start on \(hostName). Check that the computer is online and try again."
        default:
            return (error as? LocalizedError)?.errorDescription ?? "\(hostName) couldn't start the sign-in. Try again."
        }
    }
}
