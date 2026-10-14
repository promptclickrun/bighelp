import CryptoKit
import Foundation
import Observation

struct DirectHermesPrompt: Identifiable, Equatable {
    enum Origin: Equatable, Sendable {
        case serverRequest
        case legacyEvent
    }

    enum Kind: Equatable, Sendable {
        case approval
        case clarification
    }

    let id: String
    let origin: Origin
    let kind: Kind
    let payload: [String: BighelpJSONValue]
    let wireID: String
    let domainRequestID: String?
    let method: String
    let hostIdentity: String
    let profile: String
    let runtimeSessionID: String
    let visibleSessionID: String
    let approval: Approval?
    let clarification: Clarification?
    let createdAt: Date
    fileprivate let key: DirectHermesPromptKey?

    struct Approval: Equatable {
        let command: String?
        let description: String?
        let choices: [ApprovalDecision]
        let toolName: String?
    }

    struct Clarification: Equatable {
        let questions: [Question]
        let isBatch: Bool
    }

    /// Legacy approval cards start their timeout only after the renderer says
    /// the exact card is on screen. This metadata is inert until a mounted view
    /// calls DirectHermesWorkspaceStore.acknowledgePresentation(of:).
    struct PresentationAcknowledgement: Equatable, Sendable {
        let requestID: String
        let runtimeSessionID: String
        let profile: String
    }

    var presentationAcknowledgement: PresentationAcknowledgement? {
        guard origin == .legacyEvent, kind == .approval,
              let domainRequestID, !domainRequestID.isEmpty else { return nil }
        return PresentationAcknowledgement(
            requestID: domainRequestID,
            runtimeSessionID: runtimeSessionID,
            profile: profile
        )
    }

    struct Question: Identifiable, Equatable {
        let id: String
        let question: String
        let choices: [String]
        let isMultiSelect: Bool
        let lockedAnswer: String?
    }

    var title: String { kind == .approval ? "Approval requested" : "Hermes has a question" }
    var detail: String {
        switch kind {
        case .approval:
            return approval?.description ?? approval?.command ?? "Review this request before responding."
        case .clarification:
            guard let clarification else { return "Review this request before responding." }
            return clarification.isBatch
                ? "Hermes has \(clarification.questions.count) questions."
                : clarification.questions.first?.question ?? "Hermes has a question."
        }
    }
    var isBatch: Bool { clarification?.isBatch == true }
    var choices: [String] { clarification?.questions.first?.choices ?? [] }

    @MainActor
    static func legacy(
        eventType: String,
        payload: [String: BighelpJSONValue],
        hostIdentity: String,
        profile: String,
        runtimeSessionID: String,
        visibleSessionID: String,
        createdAt: Date = .now
    ) throws -> Self {
        let method: DirectHermesPromptMethod
        switch eventType {
        case "approval.request": method = .approval
        case "clarify.request": method = .clarify
        default: throw DirectHermesError.invalidResponse
        }
        guard let wireID = payload["request_id"]?.string,
              !wireID.isEmpty, wireID.utf8.count <= 4_096 else {
            throw DirectHermesError.invalidResponse
        }
        var parameters = payload
        parameters["session_id"] = .string(runtimeSessionID)
        if method == .clarify { parameters.removeValue(forKey: "request_id") }
        let decoded = try DirectHermesPromptStore.decode(
            DirectHermesServerRequest(id: wireID, method: method.rawValue, params: parameters),
            method: method
        )
        let approval: Approval?
        let clarification: Clarification?
        let domainRequestID: String?
        let kind: Kind
        switch decoded.content {
        case .approval(let value, let requestID):
            kind = .approval
            approval = value
            clarification = nil
            domainRequestID = requestID
        case .clarification(let value):
            kind = .clarification
            approval = nil
            clarification = value
            domainRequestID = nil
        }
        return Self(
            id: DirectHermesPromptStore.legacyPresentationID(
                hostIdentity: hostIdentity, profile: profile,
                runtimeID: runtimeSessionID, visibleSessionID: visibleSessionID,
                wireID: wireID, method: method
            ),
            origin: .legacyEvent,
            kind: kind,
            payload: decoded.payload,
            wireID: wireID,
            domainRequestID: domainRequestID,
            method: method.rawValue,
            hostIdentity: hostIdentity,
            profile: profile,
            runtimeSessionID: runtimeSessionID,
            visibleSessionID: visibleSessionID,
            approval: approval,
            clarification: clarification,
            createdAt: createdAt,
            key: nil
        )
    }
}

enum DirectHermesPromptContract: Equatable, Sendable {
    case unknown
    case legacyEvents
    case serverRequests
}

/// Re-delivers what a resumed chat still waits on: its open server requests and, on Hermes 0.21.4
/// and later, the connect card it missed (`pending_connection`).
typealias DirectHermesOpenRequestRecovery = @MainActor (
    _ openRequests: BighelpJSONValue,
    _ runtimeID: String,
    _ pendingConnection: BighelpJSONValue?
) throws -> Void

struct DirectHermesPromptConnection: Equatable, @unchecked Sendable {
    let owner: UUID
    let principalIdentity: Data
    let clientIdentity: ObjectIdentifier
    let transportGeneration: DirectHermesServerRequestGeneration

    init(owner: UUID, principalIdentity: String, client: DirectHermesClient,
         transportGeneration: DirectHermesServerRequestGeneration) {
        self.init(owner: owner, principalIdentity: principalIdentity,
                  clientIdentity: ObjectIdentifier(client), transportGeneration: transportGeneration)
    }

    init(owner: UUID, principalIdentity: String, clientIdentity: ObjectIdentifier,
         transportGeneration: DirectHermesServerRequestGeneration) {
        self.owner = owner
        self.principalIdentity = Data(principalIdentity.utf8)
        self.clientIdentity = clientIdentity
        self.transportGeneration = transportGeneration
    }
}

fileprivate struct DirectHermesPromptKey: Hashable {
    let transportGeneration: DirectHermesServerRequestGeneration
    let wireID: Data
    let method: DirectHermesPromptMethod
}

fileprivate enum DirectHermesPromptMethod: String, Hashable, Sendable {
    case approval
    case clarify
}

struct DirectHermesLegacyPromptKey: Hashable, Sendable {
    let wireID: Data
    let method: String

    init(wireID: String, method: String) {
        self.wireID = Data(wireID.utf8)
        self.method = method
    }
}

private struct DirectHermesPromptBinding: Equatable {
    let runtimeID: Data
    let profile: Data
    let visibleSessionID: Data

    init(runtimeID: String, profile: String, visibleSessionID: String) {
        self.runtimeID = Data(runtimeID.utf8)
        self.profile = Data(profile.utf8)
        self.visibleSessionID = Data(visibleSessionID.utf8)
    }
}

fileprivate struct DirectHermesDecodedPrompt {
    enum Content {
        case approval(DirectHermesPrompt.Approval, domainRequestID: String)
        case clarification(DirectHermesPrompt.Clarification)
    }

    let runtimeID: String
    let payload: [String: BighelpJSONValue]
    let content: Content
}

@MainActor
@Observable
final class DirectHermesPromptStore {
    private struct Pending {
        let connection: DirectHermesPromptConnection
        let key: DirectHermesPromptKey
        let wireID: String
        let decoded: DirectHermesDecodedPrompt
        let createdAt: Date
        let continuation: CheckedContinuation<DirectHermesServerResponse, Never>
    }

    private(set) var revision: UInt64 = 0
    /// Hermes' connect cards, kept beside the prompts so every chat that holds this store can
    /// show its own inline.
    let connectorCards = ConnectorCardStore()
    @ObservationIgnored private var connection: DirectHermesPromptConnection?
    @ObservationIgnored private var bindings: [Data: DirectHermesPromptBinding] = [:]
    @ObservationIgnored private var contracts: [Data: DirectHermesPromptContract] = [:]
    @ObservationIgnored private var legacyPrompts: [Data: [DirectHermesLegacyPromptKey: DirectHermesPrompt]] = [:]
    @ObservationIgnored private var pending: [DirectHermesPromptKey: Pending] = [:]
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]

    func beginConnection(_ value: DirectHermesPromptConnection) {
        retireAll(with: Self.retiredResponse)
        connection = value
        bindings.removeAll(keepingCapacity: false)
        contracts.removeAll(keepingCapacity: false)
        legacyPrompts.removeAll(keepingCapacity: false)
        changed()
    }

    func retireConnection(_ value: DirectHermesPromptConnection) {
        guard connection == value else { return }
        connection = nil
        bindings.removeAll(keepingCapacity: false)
        contracts.removeAll(keepingCapacity: false)
        legacyPrompts.removeAll(keepingCapacity: false)
        retireAll(with: Self.retiredResponse)
        changed()
    }

    func bind(profile: String, runtimeID: String, visibleSessionID: String,
              connection expected: DirectHermesPromptConnection) throws {
        guard isCurrent(expected), !profile.isEmpty, !runtimeID.isEmpty, !visibleSessionID.isEmpty,
              profile.utf8.count <= 4_096, runtimeID.utf8.count <= 4_096,
              visibleSessionID.utf8.count <= 8_192 else {
            throw WorkspaceClientError.ownerChanged
        }
        let key = Data(runtimeID.utf8)
        let value = DirectHermesPromptBinding(
            runtimeID: runtimeID, profile: profile, visibleSessionID: visibleSessionID
        )
        guard bindings[key] != value else { return }
        bindings[key] = value
        contracts[key] = .unknown
        legacyPrompts[key] = nil
        changed()
    }

    func unbind(runtimeID: String, profile: String, visibleSessionID: String,
                connection expected: DirectHermesPromptConnection) {
        guard isCurrent(expected) else { return }
        let key = Data(runtimeID.utf8)
        guard bindings[key] == DirectHermesPromptBinding(
            runtimeID: runtimeID, profile: profile, visibleSessionID: visibleSessionID
        ) else { return }
        bindings.removeValue(forKey: key)
        contracts.removeValue(forKey: key)
        legacyPrompts.removeValue(forKey: key)
        changed()
    }

    func setContract(
        _ contract: DirectHermesPromptContract,
        legacy prompts: [DirectHermesPrompt],
        hostIdentity: String,
        profile: String,
        runtimeID: String,
        visibleSessionID: String
    ) throws {
        let runtimeKey = Data(runtimeID.utf8)
        let binding = DirectHermesPromptBinding(
            runtimeID: runtimeID, profile: profile, visibleSessionID: visibleSessionID
        )
        guard let connection,
              connection.principalIdentity == Data(hostIdentity.utf8),
              bindings[runtimeKey] == binding else {
            throw WorkspaceClientError.ownerChanged
        }
        guard prompts.count <= 64 else { throw DirectHermesError.invalidResponse }
        var indexed: [DirectHermesLegacyPromptKey: DirectHermesPrompt] = [:]
        if case .legacyEvents = contract {
            for prompt in prompts {
                guard prompt.origin == .legacyEvent,
                      Data(prompt.hostIdentity.utf8) == connection.principalIdentity,
                      Data(prompt.profile.utf8) == binding.profile,
                      Data(prompt.runtimeSessionID.utf8) == binding.runtimeID,
                      Data(prompt.visibleSessionID.utf8) == binding.visibleSessionID else {
                    throw WorkspaceClientError.ownerChanged
                }
                let key = DirectHermesLegacyPromptKey(wireID: prompt.wireID, method: prompt.method)
                guard indexed.updateValue(prompt, forKey: key) == nil else {
                    throw DirectHermesError.invalidResponse
                }
            }
        } else if !prompts.isEmpty {
            throw DirectHermesError.invalidResponse
        }
        contracts[runtimeKey] = contract
        legacyPrompts[runtimeKey] = indexed.isEmpty ? nil : indexed
        changed()
    }

    func prompts(hostIdentity: String, profile: String, runtimeID: String,
                 visibleSessionID: String) -> [DirectHermesPrompt] {
        _ = revision
        let runtimeKey = Data(runtimeID.utf8)
        let binding = DirectHermesPromptBinding(
            runtimeID: runtimeID, profile: profile, visibleSessionID: visibleSessionID
        )
        guard let connection,
              connection.principalIdentity == Data(hostIdentity.utf8),
              bindings[runtimeKey] == binding else { return [] }
        let values: [DirectHermesPrompt]
        switch contracts[runtimeKey] ?? .unknown {
        case .unknown:
            values = []
        case .legacyEvents:
            values = legacyPrompts[runtimeKey].map { Array($0.values) } ?? []
        case .serverRequests:
            values = pending.values.compactMap { entry in
                guard entry.connection == connection,
                      Data(entry.decoded.runtimeID.utf8) == runtimeKey else { return nil }
                return makePrompt(entry, binding: binding)
            }
        }
        return values.sorted(by: Self.sortPrompts)
    }

    /// Every question and approval waiting on this connection, across chats.
    func waitingPrompts() -> [DirectHermesPrompt] {
        _ = revision
        return visiblePrompts()
    }

    func dashboardApprovals() -> [DirectHermesDashboardApproval] {
        _ = revision
        return visiblePrompts().compactMap { prompt in
            guard let approval = prompt.approval else { return nil }
            return DirectHermesDashboardApproval(
                id: prompt.id,
                title: approval.command ?? "Approval requested",
                detail: approval.description ?? "Review this Hermes action before allowing it.",
                sessionID: prompt.visibleSessionID,
                agentID: prompt.profile,
                allowedDecisions: Set(approval.choices),
                createdAt: prompt.createdAt
            )
        }
    }

    func dashboardClarifications() -> [DirectHermesDashboardClarification] {
        _ = revision
        return visiblePrompts().compactMap { prompt in
            guard let clarification = prompt.clarification else { return nil }
            guard !clarification.questions.isEmpty else { return nil }
            return DirectHermesDashboardClarification(
                id: prompt.id,
                sessionID: prompt.visibleSessionID,
                questions: clarification.questions.map { question in
                    DashboardClarificationQuestion(
                        id: question.id,
                        question: question.question,
                        choices: question.choices,
                        allowsCustomResponse: question.lockedAnswer == nil,
                        isMultiSelect: question.isMultiSelect,
                        lockedAnswer: question.lockedAnswer
                    )
                },
                agentID: prompt.profile,
                createdAt: prompt.createdAt
            )
        }
    }

    func containsApproval(presentationID: String) -> Bool {
        let identity = Data(presentationID.utf8)
        let matches = visiblePrompts().filter {
            Data($0.id.utf8) == identity && $0.kind == .approval
        }
        return matches.count == 1
    }

    func answerApproval(presentationID: String, decision: ApprovalDecision) throws {
        guard let entry = pendingForPresentationID(presentationID),
              case .approval(let approval, _) = entry.decoded.content,
              approval.choices.contains(decision) else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        resolve(entry, with: .result(.object([
            "choice": .string(decision.rawValue),
            "all": .boolean(false),
        ])))
    }

    func answerClarification(presentationID: String, answer: String) throws {
        guard let entry = pendingForPresentationID(presentationID),
              case .clarification(let clarification) = entry.decoded.content,
              !clarification.isBatch, let question = clarification.questions.first,
              Self.validAnswer(answer) else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        let validated = try Self.validatedAnswer(answer, for: question)
        resolve(entry, with: .result(.object(["answer": .string(validated)])))
    }

    func answerApproval(_ prompt: DirectHermesPrompt, decision: ApprovalDecision) throws {
        guard prompt.origin == .serverRequest, let key = prompt.key,
              let entry = pending[key], entry.connection == connection,
              presentationID(for: entry.key) == prompt.id,
              case .approval(let approval, _) = entry.decoded.content,
              approval.choices.contains(decision) else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        resolve(entry, with: .result(.object([
            "choice": .string(decision.rawValue),
            "all": .boolean(false),
        ])))
    }

    func answerClarification(_ prompt: DirectHermesPrompt, answer: String) throws {
        guard prompt.origin == .serverRequest, let key = prompt.key,
              let entry = pending[key], entry.connection == connection,
              presentationID(for: entry.key) == prompt.id,
              case .clarification(let clarification) = entry.decoded.content,
              !clarification.isBatch, let question = clarification.questions.first,
              Self.validAnswer(answer) else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        let validated = try Self.validatedAnswer(answer, for: question)
        resolve(entry, with: .result(.object(["answer": .string(validated)])))
    }

    func answerClarification(_ prompt: DirectHermesPrompt, answers: [String: String]) throws {
        guard prompt.origin == .serverRequest, let key = prompt.key,
              let entry = pending[key], entry.connection == connection,
              presentationID(for: entry.key) == prompt.id,
              case .clarification(let clarification) = entry.decoded.content,
              clarification.isBatch,
              answers.count == clarification.questions.count else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        var validated: [String: BighelpJSONValue] = [:]
        for question in clarification.questions {
            guard let answer = answers[question.id] else {
                throw DirectHermesWorkspaceError.expiredPrompt
            }
            if let locked = question.lockedAnswer {
                guard answer.utf8.elementsEqual(locked.utf8) else {
                    throw DirectHermesWorkspaceError.expiredPrompt
                }
                validated[question.id] = .string(locked)
            } else {
                validated[question.id] = .string(try Self.validatedAnswer(answer, for: question))
            }
        }
        resolve(entry, with: .result(.object(["answers": .object(validated)])))
    }

    func cancel(_ prompt: DirectHermesPrompt) throws {
        guard prompt.origin == .serverRequest, let key = prompt.key,
              let entry = pending[key], entry.connection == connection,
              presentationID(for: entry.key) == prompt.id else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        switch entry.decoded.content {
        case .approval:
            resolve(entry, with: .result(.object(["choice": .string("deny"), "all": .boolean(false)])))
        case .clarification:
            resolve(entry, with: .result(.object([:])))
        }
    }

    func acceptCancellation(_ cancellation: DirectHermesServerRequestCancellation,
                            connection expected: DirectHermesPromptConnection) {
        guard isCurrent(expected), let method = DirectHermesPromptMethod(rawValue: cancellation.method) else { return }
        let key = DirectHermesPromptKey(
            transportGeneration: expected.transportGeneration,
            wireID: Data(cancellation.id.utf8),
            method: method
        )
        guard let entry = pending.removeValue(forKey: key) else { return }
        changed()
        entry.continuation.resume(returning: Self.retiredResponse)
    }

    func handle(_ request: DirectHermesServerRequest,
                connection expected: DirectHermesPromptConnection) async -> DirectHermesServerResponse {
        guard isCurrent(expected), let method = DirectHermesPromptMethod(rawValue: request.method) else {
            return Self.retiredResponse
        }
        let decoded: DirectHermesDecodedPrompt
        do {
            decoded = try Self.decode(request, method: method)
        } catch {
            return Self.invalidParamsResponse
        }
        let key = DirectHermesPromptKey(
            transportGeneration: expected.transportGeneration,
            wireID: Data(request.id.utf8),
            method: method
        )
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, isCurrent(expected), pending[key] == nil else {
                    continuation.resume(returning: Self.retiredResponse)
                    return
                }
                pending[key] = Pending(
                    connection: expected, key: key, wireID: request.id,
                    decoded: decoded, createdAt: .now, continuation: continuation
                )
                changed()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelHandler(key: key, connection: expected)
            }
        }
        guard isCurrent(expected), !Task.isCancelled else { return Self.retiredResponse }
        return response
    }

    func addObserver(id: UUID, _ observer: @escaping @MainActor () -> Void) {
        observers[id] = observer
    }

    func removeObserver(id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func cancelHandler(key: DirectHermesPromptKey,
                               connection expected: DirectHermesPromptConnection) {
        guard let entry = pending[key], entry.connection == expected else { return }
        pending.removeValue(forKey: key)
        changed()
        entry.continuation.resume(returning: Self.retiredResponse)
    }

    private func visiblePrompts() -> [DirectHermesPrompt] {
        guard let connection else { return [] }
        var values: [DirectHermesPrompt] = []
        for (runtimeKey, binding) in bindings {
            switch contracts[runtimeKey] ?? .unknown {
            case .unknown:
                continue
            case .legacyEvents:
                values += legacyPrompts[runtimeKey].map { Array($0.values) } ?? []
            case .serverRequests:
                values += pending.values.compactMap { entry in
                    guard entry.connection == connection,
                          Data(entry.decoded.runtimeID.utf8) == runtimeKey else { return nil }
                    return makePrompt(entry, binding: binding)
                }
            }
        }
        return values.sorted(by: Self.sortPrompts)
    }

    private func makePrompt(_ entry: Pending, binding: DirectHermesPromptBinding) -> DirectHermesPrompt {
        let approval: DirectHermesPrompt.Approval?
        let clarification: DirectHermesPrompt.Clarification?
        let domainRequestID: String?
        let kind: DirectHermesPrompt.Kind
        switch entry.decoded.content {
        case .approval(let value, let requestID):
            kind = .approval
            approval = value
            clarification = nil
            domainRequestID = requestID
        case .clarification(let value):
            kind = .clarification
            approval = nil
            clarification = value
            domainRequestID = nil
        }
        return DirectHermesPrompt(
            id: presentationID(for: entry.key),
            origin: .serverRequest,
            kind: kind,
            payload: entry.decoded.payload,
            wireID: entry.wireID,
            domainRequestID: domainRequestID,
            method: entry.key.method.rawValue,
            hostIdentity: String(decoding: entry.connection.principalIdentity, as: UTF8.self),
            profile: String(decoding: binding.profile, as: UTF8.self),
            runtimeSessionID: entry.decoded.runtimeID,
            visibleSessionID: String(decoding: binding.visibleSessionID, as: UTF8.self),
            approval: approval,
            clarification: clarification,
            createdAt: entry.createdAt,
            key: entry.key
        )
    }

    private func pendingForPresentationID(_ id: String) -> Pending? {
        guard let connection else { return nil }
        let matches = pending.values.filter { entry in
            entry.connection == connection
                && bindings[Data(entry.decoded.runtimeID.utf8)] != nil
                && presentationID(for: entry.key) == id
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func resolve(_ entry: Pending, with response: DirectHermesServerResponse) {
        guard pending.removeValue(forKey: entry.key) != nil else { return }
        changed()
        entry.continuation.resume(returning: response)
    }

    private func retireAll(with response: DirectHermesServerResponse) {
        let entries = Array(pending.values)
        pending.removeAll(keepingCapacity: false)
        for entry in entries { entry.continuation.resume(returning: response) }
    }

    private func isCurrent(_ expected: DirectHermesPromptConnection) -> Bool {
        connection == expected
    }

    private func changed() {
        revision &+= 1
        for observer in observers.values { observer() }
    }

    private func presentationID(for key: DirectHermesPromptKey) -> String {
        var bytes = Data(key.transportGeneration.rawValue.uuidString.utf8)
        bytes.append(0)
        bytes.append(key.wireID)
        bytes.append(0)
        bytes.append(contentsOf: key.method.rawValue.utf8)
        return Self.presentationID(prefix: "dhp_", bytes: bytes)
    }

    fileprivate static func legacyPresentationID(
        hostIdentity: String,
        profile: String,
        runtimeID: String,
        visibleSessionID: String,
        wireID: String,
        method: DirectHermesPromptMethod
    ) -> String {
        var bytes = Data("legacy-prompt-v1".utf8)
        for value in [hostIdentity, profile, runtimeID, visibleSessionID, wireID, method.rawValue] {
            let field = Data(value.utf8)
            bytes.append(0)
            bytes.append(contentsOf: String(field.count).utf8)
            bytes.append(58)
            bytes.append(field)
        }
        return presentationID(prefix: "dhl_", bytes: bytes)
    }

    private static func presentationID(prefix: String, bytes: Data) -> String {
        let digest = Data(SHA256.hash(data: bytes))
        return prefix + digest.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sortPrompts(_ lhs: DirectHermesPrompt, _ rhs: DirectHermesPrompt) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
    }

    private static let invalidParamsResponse = DirectHermesServerResponse.error(
        code: -32602, message: "Invalid prompt parameters"
    )
    private static let retiredResponse = DirectHermesServerResponse.error(
        code: -32000, message: "Prompt is no longer active"
    )

    fileprivate static func decode(_ request: DirectHermesServerRequest,
                                   method: DirectHermesPromptMethod) throws -> DirectHermesDecodedPrompt {
        guard let runtimeID = request.params["session_id"]?.string,
              !runtimeID.isEmpty, runtimeID.utf8.count <= 4_096 else {
            throw DirectHermesError.invalidResponse
        }
        switch method {
        case .approval:
            guard let requestID = request.params["request_id"]?.string,
                  !requestID.isEmpty, requestID.utf8.count <= 4_096,
                  let choicesValue = request.params["choices"]?.array,
                  !choicesValue.isEmpty, choicesValue.count <= 16 else {
                throw DirectHermesError.invalidResponse
            }
            // An unknown or repeated choice from a newer Hermes is skipped, not fatal:
            // failing the request makes Hermes treat the approval as unanswered.
            var choices: [ApprovalDecision] = []
            var seen = Set<ApprovalDecision>()
            for value in choicesValue {
                guard let raw = value.string, let choice = ApprovalDecision(rawValue: raw),
                      seen.insert(choice).inserted else { continue }
                choices.append(choice)
            }
            guard !choices.isEmpty else { throw DirectHermesError.invalidResponse }
            try validateOptionalString(request.params["command"], maximumBytes: 65_536)
            try validateOptionalString(request.params["description"], maximumBytes: 65_536)
            try validateOptionalString(request.params["tool_name"], maximumBytes: 4_096)
            try validateOptionalString(request.params["gateway_session_id"], maximumBytes: 4_096)
            for key in ["allow_permanent", "allow_session", "smart_denied"] {
                if let value = request.params[key], value.boolean == nil {
                    throw DirectHermesError.invalidResponse
                }
            }
            let approval = DirectHermesPrompt.Approval(
                command: request.params["command"]?.string,
                description: request.params["description"]?.string,
                choices: choices,
                toolName: request.params["tool_name"]?.string
            )
            return DirectHermesDecodedPrompt(
                runtimeID: runtimeID,
                payload: request.params,
                content: .approval(approval, domainRequestID: requestID)
            )
        case .clarify:
            // Keys this app doesn't know are ignored and null means absent: rejecting the
            // request makes Hermes give the agent a blank answer instead of waiting for you.
            func present(_ key: String) -> Bool { request.params[key].map { $0 != .null } ?? false }
            let hasSingle = present("question")
            let hasBatch = present("questions")
            guard hasSingle != hasBatch else { throw DirectHermesError.invalidResponse }
            if hasSingle {
                guard !present("answers"),
                      let question = request.params["question"]?.string else {
                    throw DirectHermesError.invalidResponse
                }
                let choices = try decodeChoices(request.params["choices"])
                let multi = try decodeMultiSelect(request.params["multi_select"])
                guard validQuestion(question), !multi || !choices.isEmpty else {
                    throw DirectHermesError.invalidResponse
                }
                return DirectHermesDecodedPrompt(
                    runtimeID: runtimeID,
                    payload: request.params,
                    content: .clarification(.init(
                        questions: [.init(
                            id: "$single", question: question, choices: choices,
                            isMultiSelect: multi, lockedAnswer: nil
                        )],
                        isBatch: false
                    ))
                )
            }
            guard let rows = request.params["questions"]?.array,
                  !rows.isEmpty, rows.count <= 10 else {
                throw DirectHermesError.invalidResponse
            }
            let locked = try decodeLockedAnswers(request.params["answers"])
            var questions: [DirectHermesPrompt.Question] = []
            var qids = Set<Data>()
            var swiftQIDs = Set<String>()
            for row in rows {
                guard let object = row.object,
                      let qid = object["qid"]?.string, !qid.isEmpty, qid.utf8.count <= 4_096,
                      qids.insert(Data(qid.utf8)).inserted,
                      swiftQIDs.insert(qid).inserted,
                      let question = object["question"]?.string, validQuestion(question) else {
                    throw DirectHermesError.invalidResponse
                }
                let choices = try decodeChoices(object["choices"])
                let multi = try decodeMultiSelect(object["multi_select"])
                guard !multi || !choices.isEmpty else { throw DirectHermesError.invalidResponse }
                questions.append(.init(
                    id: qid,
                    question: question,
                    choices: choices,
                    isMultiSelect: multi,
                    lockedAnswer: locked[Data(qid.utf8)]
                ))
            }
            guard locked.keys.allSatisfy(qids.contains) else { throw DirectHermesError.invalidResponse }
            return DirectHermesDecodedPrompt(
                runtimeID: runtimeID,
                payload: request.params,
                content: .clarification(.init(questions: questions, isBatch: true))
            )
        }
    }

    private static func decodeChoices(_ value: BighelpJSONValue?) throws -> [String] {
        guard let value, value != .null else { return [] }
        guard let rows = value.array, rows.count <= 12 else { throw DirectHermesError.invalidResponse }
        var choices: [String] = []
        var seen = Set<Data>()
        for row in rows {
            guard let choice = row.string, !choice.isEmpty, choice.utf8.count <= 10_000,
                  !choice.contains("\0"), seen.insert(Data(choice.utf8)).inserted else {
                throw DirectHermesError.invalidResponse
            }
            choices.append(choice)
        }
        return choices
    }

    private static func decodeMultiSelect(_ value: BighelpJSONValue?) throws -> Bool {
        guard let value, value != .null else { return false }
        guard let result = value.boolean else { throw DirectHermesError.invalidResponse }
        return result
    }

    private static func decodeLockedAnswers(_ value: BighelpJSONValue?) throws -> [Data: String] {
        guard let value else { return [:] }
        guard let object = value.object, object.count <= 5 else { throw DirectHermesError.invalidResponse }
        var result: [Data: String] = [:]
        for (key, value) in object {
            guard !key.isEmpty, key.utf8.count <= 4_096,
                  let answer = value.string, validAnswer(answer),
                  result.updateValue(answer, forKey: Data(key.utf8)) == nil else {
                throw DirectHermesError.invalidResponse
            }
        }
        return result
    }

    private static func validateOptionalString(_ value: BighelpJSONValue?, maximumBytes: Int) throws {
        guard let value else { return }
        guard let text = value.string, text.utf8.count <= maximumBytes,
              !text.contains("\0") else { throw DirectHermesError.invalidResponse }
    }

    private static func validQuestion(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 65_536 && !value.contains("\0")
    }

    private static func validAnswer(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 10_000 && !value.contains("\0")
    }

    static func validatedAnswer(_ answer: String,
                                for question: DirectHermesPrompt.Question) throws -> String {
        guard validAnswer(answer) else { throw DirectHermesWorkspaceError.expiredPrompt }
        guard question.isMultiSelect else { return answer }
        guard let data = answer.data(using: .utf8) else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        guard let selected = try? JSONDecoder().decode([String].self, from: data) else {
            // The stock Clarify UI treats typed “Other” text as the whole
            // multi-select answer. The tool turns it into a one-item response.
            return answer
        }
        guard
              !selected.isEmpty, selected.count <= question.choices.count + 1,
              selected.allSatisfy(validAnswer) else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        var usedChoices = Set<Int>()
        var customCount = 0
        var seen = Set<Data>()
        for value in selected {
            let bytes = Data(value.utf8)
            guard seen.insert(bytes).inserted else {
                throw DirectHermesWorkspaceError.expiredPrompt
            }
            if let index = question.choices.indices.first(where: {
                !usedChoices.contains($0)
                    && question.choices[$0].utf8.elementsEqual(value.utf8)
            }) {
                usedChoices.insert(index)
            } else {
                customCount += 1
            }
        }
        guard customCount <= 1,
              let encoded = try? JSONEncoder().encode(selected),
              let value = String(data: encoded, encoding: .utf8) else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        return value
    }
}

enum DirectHermesWorkspaceError: Error, LocalizedError {
    case attachmentsUnavailable, reviewRequired, interruptAndSendUnavailable, expiredPrompt, modelConfirmationRequired, liveReplayUnavailable, nativeTurnActive, midSessionRejected
    var errorDescription: String? {
        switch self {
        case .nativeTurnActive: "The native session is already working. Reopen it to recover its live controls, or wait for it to finish."
        case .liveReplayUnavailable: "Live event replay is no longer available. Keep the retained content and reopen saved history after Hermes becomes idle; nothing was resent."
        case .attachmentsUnavailable: "Direct attachments are not enabled yet. Your text and attachments have not been sent."
        case .reviewRequired: "Reopen this chat to reconnect before sending. Your previous text is saved locally and will not be resent automatically."
        case .interruptAndSendUnavailable: "This send mode does not support attachments. Choose Queue or send them after this turn."
        case .midSessionRejected: "Hermes did not accept this correction. Your draft is still available."
        case .expiredPrompt: "This request is no longer pending. Your response has not been sent as a new chat message."
        case .modelConfirmationRequired: "Hermes requires additional confirmation for this model. Choose another model or confirm through Hermes Desktop."
        }
    }
}
