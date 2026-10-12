import Foundation

struct HermesDiagnosticsShareReceipt: Equatable, Sendable {
    let viewURL: URL?
    let uploadID: String?
    let expiresAt: Date?
}

enum HermesDiagnosticAction: String, CaseIterable, Identifiable, Sendable {
    case doctor
    case securityAudit = "security-audit"
    case promptSize = "prompt-size"
    case dump
    case configMigrate = "config-migrate"

    var id: Self { self }
    var title: String {
        switch self {
        case .doctor: "Doctor"
        case .securityAudit: "Security audit"
        case .promptSize: "Prompt size"
        case .dump: "Diagnostic dump"
        case .configMigrate: "Configuration migration"
        }
    }

    fileprivate var action: HermesHostAction {
        switch self {
        case .doctor: .doctor
        case .securityAudit: .securityAudit
        case .promptSize: .promptSize
        case .dump: .dump
        case .configMigrate: .configMigrate
        }
    }

    fileprivate var route: String { "/api/ops/\(rawValue)" }
}

extension DirectHermesHostOperationsClient {
    func launchDiagnostic(_ action: HermesDiagnosticAction) async throws -> HermesHostActionReceipt {
        try await launch(
            .init(path: action.route, method: .post, body: [:]),
            expectedAction: action.action,
            feature: "\(action.title) diagnostics"
        )
    }

    /// The host force-redacts this RPC. Callers still must obtain fresh user
    /// confirmation for every invocation; consent is intentionally not stored.
    func shareDiagnosticsWithNous(logLines: Int = 200) async throws -> HermesDiagnosticsShareReceipt {
        guard (10...2_000).contains(logLines) else { throw HostOperationsError.invalidRequest }
        try requireOwner()
        let value: BighelpJSONValue
        do {
            value = try await rpc.request("diagnostics.share_nous", params: ["log_lines": .integer(logLines)])
            try requireOwner()
        } catch DirectHermesError.rpcRejected(let code, _) where code == -32601 || code == 4010 {
            try requireOwner()
            throw HostOperationsError.unavailable("force-redacted Nous diagnostics sharing")
        } catch {
            try requireOwner()
            throw HostOperationsError.shareFailed
        }
        let object = try DirectHermesHostPayload.object(value)
        guard object["ok"]?.boolean == true else { throw HostOperationsError.shareFailed }
        let viewURL = try DirectHermesHostPayload.optionalHTTPSURL(object["view_url"])
        let uploadID = try DirectHermesHostPayload.optionalText(object["upload_id"], maximumBytes: 512)
        guard viewURL != nil || uploadID != nil else { throw HostOperationsError.shareFailed }
        return .init(
            viewURL: viewURL, uploadID: uploadID,
            expiresAt: DirectHermesHostPayload.date(try DirectHermesHostPayload.optionalText(object["expires_at"], maximumBytes: 128))
        )
    }
}
