import Foundation

enum ApprovalDecision: String, Codable, CaseIterable, Equatable, Sendable {
    case once
    case session
    case always
    case deny

    // Source-compatible names for older fixture call sites. New product UI
    // presents the exact Hermes scope instead of flattening every approval to
    // a boolean.
    static var approve: ApprovalDecision { .once }
    static var decline: ApprovalDecision { .deny }

    var authorizesRequest: Bool {
        self != .deny
    }

    var buttonTitle: String {
        switch self {
        case .once: "Approve this time"
        case .session: "Approve this chat"
        case .always: "Always Approve"
        case .deny: "Deny"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .once: "Allows only this exact Hermes request."
        case .session: "Allows matching requests for this Hermes chat."
        case .always: "Allows matching requests in future Hermes chats."
        case .deny: "Denies this exact Hermes request."
        }
    }
}

enum ApprovalActionControlStyle: Equatable, Sendable {
    case neutralGlass
}

struct ApprovalActionPresentation: Equatable, Sendable {
    let controlStyle: ApprovalActionControlStyle
    let usesColoredBackground: Bool
    let drawsExplicitBorder: Bool
    let isDestructive: Bool

    static func resolve(for decision: ApprovalDecision) -> Self {
        ApprovalActionPresentation(
            controlStyle: .neutralGlass,
            usesColoredBackground: false,
            drawsExplicitBorder: false,
            isDestructive: decision == .deny
        )
    }
}

struct ApprovalReceipt: Equatable, Sendable {
    let requestID: String
    let decision: ApprovalDecision
}

enum ApprovalStatus: Equatable, Sendable {
    case idle
    case pending
    case resolved(ApprovalDecision)
    case failed(String)
}

@MainActor
protocol ApprovalClient {
    func submit(request: ApprovalRequest, decision: ApprovalDecision) async throws -> ApprovalReceipt
}

struct LoadedApprovalRequest: Equatable, Sendable {
    let request: ApprovalRequest
    let allowedDecisions: Set<ApprovalDecision>
}

@MainActor
protocol ApprovalRequestLoading {
    func loadApproval(id: String) async throws -> LoadedApprovalRequest
}
