import Foundation
import Observation

struct PluginUpdateStatus: Equatable, Sendable {
    enum Phase: String, Sendable {
        case idle, accepted, resolving, validating, installing, blocked, restarting, complete, failed
        case installedRestartRequired = "installed_restart_required"
        case waitingForActivation = "waiting_for_activation"
        case upToDate = "up_to_date"
        case timedOut = "timed_out"

        var isTerminal: Bool {
            switch self {
            case .idle, .blocked, .installedRestartRequired, .complete, .failed, .upToDate: true
            default: false
            }
        }
        var title: String {
            switch self {
            case .idle: "Ready to update"
            case .accepted, .resolving, .validating, .installing: "Updating"
            case .restarting: "Restarting"
            case .waitingForActivation: "Reconnecting"
            case .complete: "Complete"
            case .upToDate: "Up to date"
            case .installedRestartRequired: "Restart required"
            case .blocked: "Update needs attention"
            case .failed: "Update failed"
            case .timedOut: "Still waiting for the computer"
            }
        }
    }
    let operationID: String?
    let phase: Phase
    let targetRevision: String?
    let activeRevision: String?
    let runtimeID: String?
    let message: String

    static func validRevision(_ value: String?) -> Bool {
        guard let value, value.count == 40 else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }
    }
    var provesCompletion: Bool {
        Self.validRevision(targetRevision) && targetRevision == activeRevision && runtimeID?.isEmpty == false
    }
}

enum PluginUpdateClientError: Error, LocalizedError {
    case unsupported, invalidResponse
    var errorDescription: String? {
        switch self {
        case .unsupported: "This computer needs the initial updater-capable bighelp plugin installed before it can update from the app."
        case .invalidResponse: "The computer has not provided matching update confirmation. No completion was recorded."
        }
    }
}

@MainActor
protocol PluginUpdateClient: AnyObject {
    func start(operationID: String) async throws -> PluginUpdateStatus
    func status(operationID: String?) async throws -> PluginUpdateStatus
}

/// Owns only one account/device/host's update. A disconnect never submits twice.
@MainActor @Observable
final class PluginUpdateStore {
    private struct Pending: Codable {
        let id: String
        var targetRevision: String?
        let initialRuntimeID: String?
    }

    let scope: String
    private(set) var status: PluginUpdateStatus?
    private(set) var message: String?
    private(set) var isWorking = false
    private(set) var isUnsupported = false
    private(set) var pendingOperationID: String?
    @ObservationIgnored private var pending: Pending?
    @ObservationIgnored private let client: any PluginUpdateClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let operationID: () -> String
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private var valid = true
    private var key: String { "loopdy.plugin-update.pending.\(scope)" }

    init(scope: String, client: any PluginUpdateClient, defaults: UserDefaults = .standard,
         operationID: @escaping () -> String = { "update_\(UUID().uuidString)" },
         isCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.scope = scope
        self.client = client
        self.defaults = defaults
        self.operationID = operationID
        self.isCurrent = isCurrent
        if let data = defaults.data(forKey: "loopdy.plugin-update.pending.\(scope)"),
           let value = try? JSONDecoder().decode(Pending.self, from: data) {
            pending = value
            pendingOperationID = value.id
        }
    }

    var isPending: Bool { pendingOperationID != nil }
    var canStart: Bool { valid && isCurrent() && !isWorking && !isPending && !isUnsupported }
    /// Hermes restarted for the update and the app is waiting to reach it again.
    var isReconnecting: Bool { (isPending && message != nil) || status?.phase == .waitingForActivation }
    var title: String {
        if isPending, message != nil { return "Reconnecting" }
        return status?.phase.title ?? (isWorking ? "Checking computer" : "bighelp Plugin")
    }

    func invalidate() { valid = false }
    private var ownsScope: Bool { valid && isCurrent() && !Task.isCancelled }

    func start() async {
        guard ownsScope, !isWorking, !isUnsupported else { return }
        guard pending == nil else { await refreshStatus(); return }
        isWorking = true
        defer { isWorking = false }
        let value = Pending(id: operationID(), targetRevision: nil, initialRuntimeID: status?.runtimeID)
        // Persist before sending: a lost acknowledgement must not create a new job.
        pending = value
        persistPending()
        message = nil
        do {
            let result = try await client.start(operationID: value.id)
            guard ownsScope else { return }
            try accept(result)
        } catch {
            guard ownsScope else { return }
            record(error)
        }
    }

    func refreshStatus() async {
        guard ownsScope, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await client.status(operationID: pending?.id)
            guard ownsScope else { return }
            try accept(result)
        } catch {
            guard ownsScope else { return }
            record(error)
        }
    }

    /// The view may stop observation; host execution and durable ID continue.
    func observe() async {
        await refreshStatus()
        for _ in 0..<180 {
            guard ownsScope, isPending else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard ownsScope else { return }
            if isPending { await refreshStatus() }
        }
        if ownsScope, isPending {
            message = "The update is still unconfirmed. Use Check Update Status to reconnect; another update will not be started."
        }
    }

    private func accept(_ result: PluginUpdateStatus) throws {
        if let expected = pending {
            guard result.operationID == expected.id else { throw PluginUpdateClientError.invalidResponse }
            if let target = expected.targetRevision, let received = result.targetRevision, target != received {
                throw PluginUpdateClientError.invalidResponse
            }
        }
        if result.phase == .complete || result.phase == .upToDate {
            guard result.provesCompletion else { throw PluginUpdateClientError.invalidResponse }
            if result.phase == .complete, let previousRuntime = pending?.initialRuntimeID,
               previousRuntime == result.runtimeID { throw PluginUpdateClientError.invalidResponse }
        }
        status = result
        message = nil
        isUnsupported = false
        if result.phase.isTerminal {
            pending = nil
        } else if let id = result.operationID {
            if pending == nil { pending = Pending(id: id, targetRevision: result.targetRevision, initialRuntimeID: nil) }
            else if pending?.targetRevision == nil { pending?.targetRevision = result.targetRevision }
        }
        persistPending()
    }

    private func persistPending() {
        pendingOperationID = pending?.id
        if let pending, let data = try? JSONEncoder().encode(pending) { defaults.set(data, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    private func record(_ error: any Error) {
        if case PluginUpdateClientError.unsupported = error {
            isUnsupported = true
            message = error.localizedDescription
        } else if error is PluginUpdateClientError {
            message = error.localizedDescription
        } else {
            message = isPending
                ? "Waiting for the same computer to reconnect and confirm this update."
                : "The computer could not be reached. Try checking its status again."
        }
    }
}
