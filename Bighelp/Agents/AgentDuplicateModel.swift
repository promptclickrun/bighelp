import Foundation
import Observation

@MainActor
@Observable
final class AgentDuplicateModel: Identifiable {
    enum Result: Equatable {
        case committed
        case partial
        case unconfirmed
    }

    let id = UUID()
    let source: AgentProfile
    let owner: WorkspaceOwner
    var destinationProfileID = ""
    var acknowledgesSensitiveCopy = false
    private(set) var plan: AgentProfileClonePlan?
    private(set) var isPreparing = false
    private(set) var isSubmitting = false
    private(set) var errorMessage: String?
    private(set) var result: Result?

    private let client: any AgentProfileCloneClient
    private let isCurrent: @MainActor () -> Bool
    private var generation = 0

    init(
        source: AgentProfile, owner: WorkspaceOwner, client: any AgentProfileCloneClient,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.source = source
        self.owner = owner
        self.client = client
        self.isCurrent = isCurrent
    }

    var requiresSensitiveConsent: Bool {
        plan.map { $0.includesCredentials || $0.includesMemory } == true
    }

    var canConfirm: Bool {
        plan != nil && result == nil && !isPreparing && !isSubmitting
            && (!requiresSensitiveConsent || acknowledgesSensitiveCopy)
            && isCurrent()
    }

    func prepare() async {
        guard !isPreparing, !isSubmitting, result == nil, isCurrent() else { return }
        let destination = destinationProfileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty, destination != source.id else {
            errorMessage = "Enter a different profile identifier for the new bot."
            return
        }
        generation += 1
        let request = generation
        isPreparing = true
        errorMessage = nil
        plan = nil
        acknowledgesSensitiveCopy = false
        defer { if generation == request { isPreparing = false } }
        do {
            let reviewed = try await client.prepareClone(
                sourceProfileID: source.id, destinationProfileID: destination, owner: owner
            )
            guard generation == request, isCurrent(), !Task.isCancelled else { return }
            guard reviewed.owner == owner, reviewed.sourceProfileID == source.id,
                  reviewed.destinationProfileID == destination else {
                errorMessage = "Hermes returned a different duplication plan. Nothing has been submitted."
                return
            }
            destinationProfileID = destination
            plan = reviewed
        } catch is CancellationError {
            return
        } catch {
            guard generation == request, isCurrent() else { return }
            errorMessage = (error as? WorkspaceClientError)?.localizedDescription
                ?? "The duplication plan could not be verified. Check the connection and profile identifier, then try again."
        }
    }

    func revise() {
        guard !isSubmitting, result == nil else { return }
        generation += 1
        plan = nil
        acknowledgesSensitiveCopy = false
        errorMessage = nil
        isPreparing = false
    }

    func confirm() async {
        guard canConfirm, let plan else { return }
        let request = generation
        isSubmitting = true
        errorMessage = nil
        defer { if generation == request { isSubmitting = false } }
        do {
            let outcome = try await client.clone(plan)
            guard generation == request, isCurrent(), !Task.isCancelled else { return }
            switch outcome {
            case .committed(let receipt):
                result = receipt.profileID == plan.destinationProfileID ? .committed : .unconfirmed
            case .partial(let receipt, _):
                result = receipt.profileID == plan.destinationProfileID ? .partial : .unconfirmed
            case .unconfirmed:
                result = .unconfirmed
            }
        } catch {
            guard generation == request, isCurrent() else { return }
            if let error = error as? WorkspaceClientError {
                switch error {
                case .conflict, .invalidRequest, .unavailable, .authenticationRequired, .capacityExceeded:
                    self.plan = nil
                    acknowledgesSensitiveCopy = false
                    errorMessage = error.localizedDescription
                    return
                default: break
                }
            }
            // A thrown transport error does not prove a profile create was rejected.
            result = .unconfirmed
        }
    }

    func cancel() {
        generation += 1
        isPreparing = false
        isSubmitting = false
        plan = nil
    }
}
