import Foundation
import Observation

@MainActor
@Observable
final class RawConfigurationStore {
    let hostName: String
    let profileID: String

    private(set) var snapshot: HermesRawConfigurationSnapshot?
    var draft = ""
    private(set) var review: HermesRawConfigurationReview?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var isRetired = false
    private(set) var saveOutcomeNeedsReview = false
    private(set) var errorMessage: String?
    private(set) var successMessage: String?

    @ObservationIgnored private let client: DirectHermesHostOperationsClient
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private var generation = UUID()

    init(
        hostName: String,
        profileID: String,
        client: DirectHermesHostOperationsClient,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.hostName = hostName
        self.profileID = profileID
        self.client = client
        self.isCurrent = isCurrent
    }

    var ownsScope: Bool { !isRetired && isCurrent() }
    var canEdit: Bool { ownsScope && snapshot != nil && !isLoading && !isSaving && !saveOutcomeNeedsReview }
    var hasChanges: Bool {
        guard let snapshot else { return false }
        return Data(snapshot.yaml.utf8) != Data(draft.utf8)
    }
    var remainingBytes: Int {
        DirectHermesHostOperationsClient.maximumRawConfigurationBytes - draft.utf8.count
    }
    var canSave: Bool { canEdit && hasChanges && remainingBytes >= 0 }

    func load() async {
        guard ownsScope, !isSaving else { return }
        let token = UUID()
        generation = token
        isLoading = true
        errorMessage = nil
        successMessage = nil
        review = nil
        defer { if accepts(token) { isLoading = false } }
        do {
            let value = try await client.rawConfiguration(profileID: profileID)
            guard accepts(token) else { return }
            snapshot = value
            draft = value.yaml
            saveOutcomeNeedsReview = false
        } catch {
            guard accepts(token) else { return }
            snapshot = nil
            draft = ""
            errorMessage = Self.message(error)
        }
    }

    func prepareReview() {
        guard canEdit, let snapshot else { return }
        errorMessage = nil
        successMessage = nil
        do {
            review = try client.reviewRawConfiguration(original: snapshot, proposedYAML: draft)
        } catch {
            review = nil
            errorMessage = Self.message(error)
        }
    }

    func cancelReview() {
        review = nil
    }

    func saveReviewed(_ reviewed: HermesRawConfigurationReview) async {
        guard canEdit, review == reviewed else { return }
        let token = UUID()
        generation = token
        isSaving = true
        errorMessage = nil
        successMessage = nil
        defer { if accepts(token) { isSaving = false } }
        do {
            let commit = try await client.saveRawConfiguration(reviewed: reviewed)
            guard accepts(token) else { return }
            snapshot = commit.readback
            draft = commit.readback.yaml
            review = nil
            successMessage = commit.serverPreservedExactText
                ? "Hermes acknowledged the replacement and exact readback matched the reviewed document."
                : "Hermes acknowledged the replacement. Its authoritative readback normalized the document; review the returned text before another edit."
        } catch {
            guard accepts(token) else { return }
            if error as? HostOperationsError == .outcomeUnknown {
                saveOutcomeNeedsReview = true
                review = nil
                errorMessage = "Hermes did not provide complete acknowledgement and readback. Reload the selected profile before deciding whether to edit again; Bighelp will not resend the replacement."
            } else {
                errorMessage = Self.message(error)
            }
        }
    }

    func discardDraft() {
        guard canEdit, let snapshot else { return }
        draft = snapshot.yaml
        review = nil
        errorMessage = nil
        successMessage = nil
    }

    /// Raw configuration can contain credentials. It is never persisted by this
    /// store and is dropped as soon as the private editor leaves presentation.
    func closePrivateEditor() {
        generation = UUID()
        snapshot = nil
        draft = ""
        review = nil
        isLoading = false
        isSaving = false
        saveOutcomeNeedsReview = false
        errorMessage = nil
        successMessage = nil
    }

    func clearMessages() {
        errorMessage = nil
        successMessage = nil
    }

    func retire() {
        isRetired = true
        closePrivateEditor()
    }

    private func accepts(_ token: UUID) -> Bool {
        ownsScope && generation == token && !Task.isCancelled
    }

    private static func message(_ error: any Error) -> String {
        if let error = error as? HostOperationsError { return error.localizedDescription }
        return "Hermes could not complete this private configuration request. No configuration content was included in the error."
    }
}
