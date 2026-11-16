import Foundation
import Observation

/// Read-only evidence, deliberately separate from transport and updater state.
struct HostRuntimeStatus: Decodable, Equatable, Sendable {
    enum RestartState: String, Decodable, Sendable {
        case unknown, required
        case notRequired = "not_required"
        var title: String {
            switch self {
            case .unknown: "Unknown"
            case .required: "Restart required"
            case .notRequired: "No restart required"
            }
        }
    }
    enum UpdateState: String, Decodable, Sendable {
        case unknown, current, available
        var title: String {
            switch self {
            case .unknown: "Unknown"
            case .current: "Current at last check"
            case .available: "Update available"
            }
        }
    }
    struct Hermes: Decodable, Equatable, Sendable {
        let runningVersion: String?
        let cliVersion: String?
        let updateState: UpdateState
        let updateCheckedAt: Int?
        let restartState: RestartState
    }
    struct Plugin: Decodable, Equatable, Sendable {
        let runningVersion: String
        let installedRevision: String?
        let activeRevision: String?
        let restartState: RestartState
    }
    struct Compatibility: Decodable, Equatable, Sendable {
        enum State: String, Decodable, Sendable { case unknown, compatible, incompatible }
        struct Issue: Decodable, Equatable, Sendable {
            let code: String
            let operation: String
            let message: String
            let suggestedAction: String
        }
        let state: State
        let checkedOperations: [String]
        let unavailableOperations: [String]
        let issues: [Issue]
    }
    let schemaVersion: Int
    let runtimeId: String
    let observedAt: Int
    let hermes: Hermes
    let plugin: Plugin
    let compatibility: Compatibility

    var hasMissingAgentCapability: Bool {
        compatibility.state == .incompatible
            && compatibility.checkedOperations.contains("agents.list")
            && compatibility.unavailableOperations.contains("agents.list")
            && compatibility.issues.contains { $0.code == "hermes_capability_missing" && $0.operation == "agents.list" }
    }

    static func decode(_ payload: [String: BighelpJSONValue]) throws -> Self {
        // Missing nullable fields and malformed metadata must not become healthy defaults.
        guard Set(payload.keys) == Set(["schemaVersion", "runtimeId", "observedAt", "hermes", "plugin", "compatibility"]),
              let hermes = payload["hermes"]?.object,
              Set(hermes.keys) == Set(["runningVersion", "cliVersion", "updateState", "updateCheckedAt", "restartState"]),
              let plugin = payload["plugin"]?.object,
              Set(plugin.keys) == Set(["runningVersion", "installedRevision", "activeRevision", "restartState"]),
              let compatibility = payload["compatibility"]?.object,
              Set(compatibility.keys) == Set(["state", "checkedOperations", "unavailableOperations", "issues"])
        else { throw HostRuntimeClientError.invalidResponse }
        let data = try JSONEncoder().encode(payload)
        guard data.count <= 16_384 else { throw HostRuntimeClientError.invalidResponse }
        let value = try JSONDecoder().decode(Self.self, from: data)
        func token(_ text: String, maximum: Int = 128) -> Bool {
            !text.isEmpty && text.utf8.count <= maximum && text.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0))
            }
        }
        func version(_ text: String?) -> Bool { text.map { token($0) } ?? true }
        // A git commit: 40 lowercase hex characters.
        func revision(_ text: String?) -> Bool {
            guard let text else { return true }
            return text.count == 40 && text.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }
        }
        guard value.schemaVersion == 1, value.observedAt > 0,
              token(value.runtimeId), version(value.hermes.runningVersion), version(value.hermes.cliVersion),
              token(value.plugin.runningVersion), revision(value.plugin.installedRevision), revision(value.plugin.activeRevision),
              value.hermes.updateCheckedAt == nil || value.hermes.updateCheckedAt! > 0,
              value.hermes.updateState == .unknown || value.hermes.updateCheckedAt != nil,
              value.compatibility.checkedOperations.count <= 64,
              value.compatibility.unavailableOperations.count <= 64,
              value.compatibility.issues.count <= 16,
              value.compatibility.checkedOperations.allSatisfy({ token($0) }),
              value.compatibility.unavailableOperations.allSatisfy({ token($0) }),
              value.compatibility.issues.allSatisfy({ token($0.code) && token($0.operation) && token($0.suggestedAction) && $0.message.utf8.count <= 512 })
        else { throw HostRuntimeClientError.invalidResponse }
        // A contradictory compatibility report is not evidence of working discovery.
        if value.compatibility.state == .compatible,
           (!value.compatibility.unavailableOperations.isEmpty || !value.compatibility.issues.isEmpty) {
            throw HostRuntimeClientError.invalidResponse
        }
        return value
    }
}

enum HostRuntimeClientError: Error { case unknownSupport, unsupported, invalidResponse }

@MainActor
protocol HostRuntimeClient: AnyObject {
    func status() async throws -> HostRuntimeStatus
}

@MainActor
final class BighelpHostRuntimeClient: HostRuntimeClient {
    private let workspace: BighelpLinkWorkspaceClient
    private let isCurrent: @MainActor () -> Bool

    init(workspace: BighelpLinkWorkspaceClient, isCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.workspace = workspace
        self.isCurrent = isCurrent
    }

    func status() async throws -> HostRuntimeStatus {
        guard isCurrent() else { throw CancellationError() }
        let payload = try await workspace.perform(.hostRuntimeStatus, payload: [:])
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        return try HostRuntimeStatus.decode(payload)
    }
}

@MainActor @Observable
final class HostRuntimeStore {
    enum Availability: Equatable { case unknown, supported, unsupported, unavailable }
    let scope: String
    private(set) var status: HostRuntimeStatus?
    private(set) var availability: Availability = .unknown
    private(set) var isChecking = false
    private(set) var checkedAt: Date?
    @ObservationIgnored private let client: any HostRuntimeClient
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private var valid = true

    init(scope: String, client: any HostRuntimeClient, isCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.scope = scope
        self.client = client
        self.isCurrent = isCurrent
    }

    var ownsScope: Bool { valid && isCurrent() }
    func invalidate() { valid = false }

    func refresh() async {
        guard ownsScope, !Task.isCancelled, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let result = try await client.status()
            guard ownsScope, !Task.isCancelled else { return }
            status = result
            checkedAt = Date()
            availability = .supported
        } catch is CancellationError {
            // Scope replacement and cancelled presentation do not publish a failure.
        } catch {
            guard ownsScope, !Task.isCancelled else { return }
            // Keep last evidence, but label it unverified until a fresh successful read.
            if case HostRuntimeClientError.unsupported = error { availability = .unsupported }
            else if case HostRuntimeClientError.unknownSupport = error { availability = .unknown }
            else { availability = .unavailable }
        }
    }
}

#if DEBUG
/// No credentials, repository writes, or live requests in diagnostic UI scenarios.
@MainActor
final class HostRuntimeAgentPreviewClient: AgentDirectoryClient {
    let isCapabilityMissing: Bool
    init(isCapabilityMissing: Bool) { self.isCapabilityMissing = isCapabilityMissing }
    func list() async throws -> [AgentProfile] {
        throw BighelpLinkWorkspaceClientError.remote(status: .failed,
            code: isCapabilityMissing ? "hermes_capability_missing" : "internal_error", message: nil)
    }
    func create(_ draft: AgentDraft) async throws -> AgentProfile { throw HostRuntimeClientError.unsupported }
    func update(id: String, draft: AgentDraft) async throws -> AgentProfile { throw HostRuntimeClientError.unsupported }
}

@MainActor
final class HostRuntimePreviewClient: HostRuntimeClient {
    enum Scenario: String { case gatewayOutdated = "gateway-outdated", restart, unsupported }
    let scenario: Scenario
    init(scenario: Scenario) { self.scenario = scenario }

    static func scenario(arguments: [String]) -> Scenario? {
        guard let index = arguments.firstIndex(of: "-host-diagnostics-fixture"),
              arguments.indices.contains(index + 1) else { return nil }
        return Scenario(rawValue: arguments[index + 1])
    }

    func status() async throws -> HostRuntimeStatus {
        if scenario == .unsupported { throw HostRuntimeClientError.unsupported }
        return HostRuntimeStatus(
            schemaVersion: 1, runtimeId: "fixture-runtime", observedAt: 1_783_000_000,
            hermes: .init(runningVersion: nil, cliVersion: "0.0.0-fixture", updateState: .unknown,
                          updateCheckedAt: nil, restartState: .unknown),
            plugin: .init(runningVersion: "0.0.0-fixture", installedRevision: String(repeating: "b", count: 40),
                          activeRevision: String(repeating: scenario == .restart ? "a" : "b", count: 40),
                          restartState: scenario == .restart ? .required : .notRequired),
            compatibility: .init(state: scenario == .gatewayOutdated ? .incompatible : .unknown,
                checkedOperations: scenario == .gatewayOutdated ? ["agents.list"] : [],
                unavailableOperations: scenario == .gatewayOutdated ? ["agents.list"] : [],
                issues: scenario == .gatewayOutdated ? [.init(code: "hermes_capability_missing", operation: "agents.list",
                    message: "Fixture only", suggestedAction: "update_hermes")] : [])
        )
    }
}
#endif
