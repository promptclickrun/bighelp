import Foundation

/// Agent entries resolve the same Bot Chat as Desktop, never the newest scratch
/// conversation. The view cancels ownership when navigation or the host changes.
@MainActor
final class CanonicalChatCoordinator {
    private var task: Task<Void, Never>?
    private var requestID: UUID?
    private var canPresent: (@MainActor () -> Bool)?

    @discardableResult
    func open(
        profileID: String,
        owner: WorkspaceOwner,
        resolve: @escaping @MainActor (String, WorkspaceOwner) async throws -> String,
        canPresent: @escaping @MainActor () -> Bool,
        present: @escaping @MainActor (String) -> Void,
        failed: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        cancel()
        let id = UUID()
        requestID = id
        self.canPresent = canPresent
        let task = Task { @MainActor [weak self] in
            defer {
                if self?.requestID == id {
                    self?.requestID = nil
                    self?.task = nil
                    self?.canPresent = nil
                }
            }
            do {
                let sessionID = try await resolve(profileID, owner)
                guard !Task.isCancelled, self?.requestID == id, canPresent() else { return }
                present(sessionID)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, self?.requestID == id, canPresent() else { return }
                failed()
            }
        }
        self.task = task
        return task
    }

    func cancelIfSuperseded() {
        if canPresent?() == false { cancel() }
    }

    func cancel() {
        canPresent = nil
        requestID = nil
        task?.cancel()
        task = nil
    }
}
