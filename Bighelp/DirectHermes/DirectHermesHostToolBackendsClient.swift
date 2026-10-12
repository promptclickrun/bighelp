import Foundation

// MARK: - Host tool backend projections

enum HermesTerminalBackendStatus: String, Equatable, Sendable {
    case ready
    case needsSetup = "needs_setup"
    case unavailable
}

struct HermesTerminalBackend: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let summary: String
    let isActive: Bool
    let status: HermesTerminalBackendStatus
    let detail: String
}

struct HermesTerminalBackends: Equatable, Sendable {
    let activeBackendID: String
    let backends: [HermesTerminalBackend]
}

struct HermesComputerUseCheck: Identifiable, Equatable, Sendable {
    let label: String
    let status: String
    let message: String
    var id: String { "\(label)\u{1f}\(status)\u{1f}\(message)" }
}

struct HermesComputerUsePermissionSource: Equatable, Sendable {
    let attribution: String?
    let executable: String?
    let note: String?
    let processID: Int?
    let responsibleParentProcessID: Int?
}

struct HermesComputerUseStatus: Equatable, Sendable {
    let hostPlatform: String
    let isPlatformSupported: Bool
    let isInstalled: Bool
    let version: String?
    let isReady: Bool?
    let canRequestHostPermissionGrant: Bool
    let checks: [HermesComputerUseCheck]
    let hasAccessibilityPermission: Bool?
    let hasScreenRecordingPermission: Bool?
    let canCaptureScreen: Bool?
    let source: HermesComputerUsePermissionSource?
    let errorSummary: String?

    var requiresMacHostInteraction: Bool {
        hostPlatform == "darwin" && canRequestHostPermissionGrant && isReady != true
    }
}

struct HermesComputerUseGrantReceipt: Equatable, Sendable, Identifiable {
    let actionName: String
    let processID: Int
    let actionID: String?
    let wasAlreadyRunning: Bool
    let admittedAt: Date

    var id: String {
        [actionName, actionID ?? "", String(processID)].joined(separator: "\u{1f}")
    }
}

struct HermesComputerUseGrantStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case waitingForHostInteraction
        case finished(exitCode: Int)
        case outcomeUnknown
    }

    let phase: Phase
    let processID: Int?
    let actionID: String?
}

enum HermesHostToolBackendsError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case ownerChanged
    case invalidRequest
    case invalidResponse
    case responseTooLarge
    case reviewChanged
    case outcomeUnknown
    case readbackFailed
    case hostInteractionRequired

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "This Hermes host does not expose typed host tool backend controls."
        case .ownerChanged:
            "The selected host or connection changed. Reopen Tool Backends before continuing."
        case .invalidRequest:
            "The selected host tool backend change is invalid."
        case .invalidResponse:
            "Hermes returned an unsupported Tool Backends response. No change was confirmed."
        case .responseTooLarge:
            "The Tool Backends response exceeded this screen’s safe display limit."
        case .reviewChanged:
            "Host backend status changed after review. Review the current state before continuing."
        case .outcomeUnknown:
            "Hermes did not confirm the operation. Refresh host status before trying again."
        case .readbackFailed:
            "Hermes accepted the request, but the requested backend state was not confirmed by readback."
        case .hostInteractionRequired:
            "Continue on the host Mac. macOS permission dialogs cannot be approved from \(BighelpPlatform.isMac ? "bighelp" : "this iPhone or iPad")."
        }
    }
}

@MainActor
protocol HermesHostToolBackendsManaging: AnyObject {
    var owner: WorkspaceOwner { get }
    func terminalBackends(profileID: String) async throws -> HermesTerminalBackends
    func computerUseStatus(profileID: String) async throws -> HermesComputerUseStatus
    func selectTerminalBackend(
        reviewed: HermesTerminalBackend,
        profileID: String
    ) async throws -> HermesTerminalBackends
    func requestComputerUsePermissionGrant(
        reviewed: HermesComputerUseStatus,
        profileID: String
    ) async throws -> HermesComputerUseGrantReceipt
    func permissionGrantStatus(
        for receipt: HermesComputerUseGrantReceipt
    ) async throws -> HermesComputerUseGrantStatus
}

/// Fixed owner-bound client for host terminal selection and Computer Use
/// readiness. Permission grant means only that Hermes launched CuaDriver on the
/// host Mac. It never means that the phone granted macOS TCC permissions.
@MainActor
final class DirectHermesHostToolBackendsClient: HermesHostToolBackendsManaging {
    let owner: WorkspaceOwner

    private let rpc: any DirectHermesRPC
    private let http: any DirectHermesAuthenticatedHTTP
    private let currentOwner: @MainActor () -> WorkspaceOwner?

    init(
        rpc: any DirectHermesRPC,
        http: any DirectHermesAuthenticatedHTTP,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        self.rpc = rpc
        self.http = http
        self.owner = owner
        self.currentOwner = currentOwner
    }

    func terminalBackends(profileID: String) async throws -> HermesTerminalBackends {
        let profile = try checkedProfile(profileID)
        let value = try await request(
            .init(
                path: "/api/tools/terminal/backends", method: .get,
                query: [.init(name: "profile", value: profile)], maximumResponseBytes: 256 * 1_024
            ),
            capabilityProbe: true
        )
        return try HostToolBackendsPayload.terminalBackends(value)
    }

    func computerUseStatus(profileID: String) async throws -> HermesComputerUseStatus {
        let profile = try checkedProfile(profileID)
        let value = try await request(
            .init(
                path: "/api/tools/computer-use/status", method: .get,
                query: [.init(name: "profile", value: profile)], maximumResponseBytes: 128 * 1_024
            ),
            capabilityProbe: true
        )
        return try HostToolBackendsPayload.computerUseStatus(value)
    }

    func selectTerminalBackend(
        reviewed: HermesTerminalBackend,
        profileID: String
    ) async throws -> HermesTerminalBackends {
        let profile = try checkedProfile(profileID)
        let backendID = try HostToolBackendsPayload.identifier(reviewed.id, maximumBytes: 80)
        let before = try await terminalBackends(profileID: profile)
        guard let current = before.backends.first(where: { $0.id == backendID }),
              current == reviewed, !current.isActive else {
            throw HermesHostToolBackendsError.reviewChanged
        }
        let response = try await mutationObject(.init(
            path: "/api/tools/terminal/backend", method: .put,
            body: ["backend": .string(backendID), "profile": .string(profile)],
            maximumResponseBytes: 32 * 1_024
        ))
        guard response["ok"]?.boolean == true, response["backend"]?.string == backendID else {
            throw HermesHostToolBackendsError.outcomeUnknown
        }
        let readback = try await terminalBackends(profileID: profile)
        guard readback.activeBackendID == backendID,
              readback.backends.first(where: { $0.id == backendID })?.isActive == true else {
            throw HermesHostToolBackendsError.readbackFailed
        }
        return readback
    }

    func requestComputerUsePermissionGrant(
        reviewed: HermesComputerUseStatus,
        profileID: String
    ) async throws -> HermesComputerUseGrantReceipt {
        let profile = try checkedProfile(profileID)
        guard reviewed.hostPlatform == "darwin", reviewed.isPlatformSupported,
              reviewed.isInstalled, reviewed.canRequestHostPermissionGrant,
              reviewed.isReady != true else {
            throw HermesHostToolBackendsError.invalidRequest
        }
        let current = try await computerUseStatus(profileID: profile)
        guard current == reviewed else { throw HermesHostToolBackendsError.reviewChanged }
        let response = try await mutationObject(.init(
            path: "/api/tools/computer-use/permissions/grant", method: .post,
            query: [.init(name: "profile", value: profile)], maximumResponseBytes: 32 * 1_024
        ))
        let name = try HostToolBackendsPayload.text(response["name"], maximumBytes: 80)
        guard response["ok"]?.boolean == true, name == "computer-use-grant" else {
            throw HermesHostToolBackendsError.outcomeUnknown
        }
        return .init(
            actionName: name,
            processID: try HostToolBackendsPayload.integer(response["pid"], range: 1...Int.max),
            actionID: try HostToolBackendsPayload.optionalIdentifier(response["action_id"], maximumBytes: 128),
            wasAlreadyRunning: try HostToolBackendsPayload.optionalBoolean(response["already_running"]) ?? false,
            admittedAt: Date()
        )
    }

    func permissionGrantStatus(
        for receipt: HermesComputerUseGrantReceipt
    ) async throws -> HermesComputerUseGrantStatus {
        try requireOwner()
        guard receipt.actionName == "computer-use-grant" else {
            throw HermesHostToolBackendsError.invalidRequest
        }
        let object = try HostToolBackendsPayload.object(try await request(.init(
            path: "/api/actions/computer-use-grant/status", method: .get,
            query: [.init(name: "lines", value: "1")], maximumResponseBytes: 64 * 1_024
        )))
        guard object["name"]?.string == receipt.actionName,
              let running = object["running"]?.boolean else {
            throw HermesHostToolBackendsError.invalidResponse
        }
        let processID = try HostToolBackendsPayload.optionalInteger(object["pid"], range: 1...Int.max)
        let actionID = try HostToolBackendsPayload.optionalIdentifier(object["action_id"], maximumBytes: 128)
        if let processID, processID != receipt.processID {
            throw HermesHostToolBackendsError.reviewChanged
        }
        if let expected = receipt.actionID, let actionID,
           !expected.utf8.elementsEqual(actionID.utf8) {
            throw HermesHostToolBackendsError.reviewChanged
        }
        let exitCode = try HostToolBackendsPayload.optionalInteger(object["exit_code"], range: Int.min...Int.max)
        let phase: HermesComputerUseGrantStatus.Phase
        if running {
            guard exitCode == nil else { throw HermesHostToolBackendsError.invalidResponse }
            phase = .waitingForHostInteraction
        } else if let exitCode {
            phase = .finished(exitCode: exitCode)
        } else {
            phase = .outcomeUnknown
        }
        return .init(phase: phase, processID: processID, actionID: actionID)
    }

    private func mutationObject(_ requestValue: DirectHermesHTTPRequest) async throws -> [String: BighelpJSONValue] {
        do {
            return try HostToolBackendsPayload.object(try await request(requestValue))
        } catch WorkspaceClientError.outcomeUnknown {
            throw HermesHostToolBackendsError.outcomeUnknown
        } catch let error as DirectHermesError where error.outcomeIsUnknown {
            throw HermesHostToolBackendsError.outcomeUnknown
        }
    }

    private func request(
        _ requestValue: DirectHermesHTTPRequest,
        capabilityProbe: Bool = false
    ) async throws -> BighelpJSONValue {
        try await DirectHermesCoreRequestScope.checkedRequest(check: requireOwner, mapError: { error in
            switch error {
            case DirectHermesError.unsupportedAuthentication:
                return capabilityProbe ? HermesHostToolBackendsError.unavailable : HermesHostToolBackendsError.invalidRequest
            case DirectHermesError.rpcRejected(let code, _) where capabilityProbe && (code == -32601 || code == 404):
                return HermesHostToolBackendsError.unavailable
            case DirectHermesError.messageTooLarge:
                return HermesHostToolBackendsError.responseTooLarge
            default:
                return error
            }
        }) {
            try await http.request(requestValue)
        }
    }

    private func checkedProfile(_ profileID: String) throws -> String {
        try requireOwner()
        return try DirectHermesAgentProfileService.profileIdentifier(profileID)
    }

    private func requireOwner() throws {
        try Task.checkCancellation()
        guard owner.authority.kind == .direct, currentOwner() == owner else {
            throw HermesHostToolBackendsError.ownerChanged
        }
    }
}

private enum HostToolBackendsPayload: DirectHermesPayloadDecoding {
    static var invalidResponse: any Error { HermesHostToolBackendsError.invalidResponse }
    static var arrayOverflow: any Error { HermesHostToolBackendsError.responseTooLarge }
    static let requiresNonemptyText = true

    static func identifier(_ value: String, maximumBytes: Int) throws -> String {
        guard !value.isEmpty, value.utf8.count <= maximumBytes, value != ".", value != "..",
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                      || $0 == 45 || $0 == 46 || $0 == 95
              }) else { throw HermesHostToolBackendsError.invalidRequest }
        return value
    }

    static func optionalIdentifier(_ value: BighelpJSONValue?, maximumBytes: Int) throws -> String? {
        guard let value = try optionalText(value, maximumBytes: maximumBytes) else { return nil }
        return try identifier(value, maximumBytes: maximumBytes)
    }

    static func terminalBackends(_ value: BighelpJSONValue) throws -> HermesTerminalBackends {
        let row = try object(value)
        let active = try identifier(text(row["active"], maximumBytes: 80), maximumBytes: 80)
        var seen = Set<Data>()
        let backends = try array(row["backends"], maximum: 128).map { value in
            let item = try object(value)
            let id = try identifier(text(item["name"], maximumBytes: 80), maximumBytes: 80)
            guard seen.insert(Data(id.utf8)).inserted,
                  let status = HermesTerminalBackendStatus(rawValue: try text(item["status"], maximumBytes: 32)) else {
                throw HermesHostToolBackendsError.invalidResponse
            }
            return HermesTerminalBackend(
                id: id,
                label: try text(item["label"], maximumBytes: 256),
                summary: try text(item["description"], maximumBytes: 4_096, required: false),
                isActive: try boolean(item["active"]),
                status: status,
                detail: try text(item["detail"], maximumBytes: 4_096, required: false)
            )
        }
        guard backends.contains(where: { $0.id == active && $0.isActive }),
              backends.filter(\.isActive).count == 1 else {
            throw HermesHostToolBackendsError.invalidResponse
        }
        return .init(activeBackendID: active, backends: backends)
    }

    static func computerUseStatus(_ value: BighelpJSONValue) throws -> HermesComputerUseStatus {
        let row = try object(value)
        let source: HermesComputerUsePermissionSource?
        if row["source"] == nil || row["source"] == .null {
            source = nil
        } else {
            let item = try object(row["source"])
            source = .init(
                attribution: try optionalText(item["attribution"], maximumBytes: 512),
                executable: try optionalText(item["executable"], maximumBytes: 4_096),
                note: try optionalText(item["note"], maximumBytes: 2_048),
                processID: try optionalInteger(item["pid"], range: 1...Int.max),
                responsibleParentProcessID: try optionalInteger(item["responsible_ppid"], range: 1...Int.max)
            )
        }
        let checks = try array(row["checks"], maximum: 128).map { value in
            let item = try object(value)
            return HermesComputerUseCheck(
                label: try text(item["label"], maximumBytes: 512),
                status: try text(item["status"], maximumBytes: 128),
                message: try text(item["message"], maximumBytes: 2_048, required: false)
            )
        }
        guard let supported = row["platform_supported"]?.boolean,
              let installed = row["installed"]?.boolean,
              let canGrant = row["can_grant"]?.boolean else {
            throw HermesHostToolBackendsError.invalidResponse
        }
        return .init(
            hostPlatform: try text(row["platform"], maximumBytes: 80),
            isPlatformSupported: supported,
            isInstalled: installed,
            version: try optionalText(row["version"], maximumBytes: 256),
            isReady: try optionalBoolean(row["ready"]),
            canRequestHostPermissionGrant: canGrant,
            checks: checks,
            hasAccessibilityPermission: try optionalBoolean(row["accessibility"]),
            hasScreenRecordingPermission: try optionalBoolean(row["screen_recording"]),
            canCaptureScreen: try optionalBoolean(row["screen_recording_capturable"]),
            source: source,
            errorSummary: try optionalText(row["error"], maximumBytes: 2_048)
        )
    }
}
