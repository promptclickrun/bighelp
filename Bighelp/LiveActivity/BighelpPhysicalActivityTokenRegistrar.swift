import Foundation

/// Share one instance across row registrars that publish to the same physical activities.
@MainActor
final class BighelpPhysicalActivityTokenRegistrar {
    enum RegistrationError: Error { case ownerChanged, tokenUnavailable }

    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Call after the row's account registration, using the physical provider ID.
    /// The token must come from the live driver, never the row's captured request.
    func register(
        physicalID: String,
        currentToken: @MainActor () -> Data?,
        isCurrent: @MainActor () -> Bool,
        send: @MainActor (String, Data) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw RegistrationError.ownerChanged }
        await acquire(physicalID)
        defer { release(physicalID) }

        func readToken() throws -> Data {
            try Task.checkCancellation()
            guard isCurrent() else { throw RegistrationError.ownerChanged }
            guard let token = currentToken(), !token.isEmpty else { throw RegistrationError.tokenUnavailable }
            return token
        }

        var token = try readToken()
        while true {
            try await send(physicalID, token)
            // Keep this physical ID until rotations during the write have converged.
            let latest = try readToken()
            guard latest != token else { return }
            token = latest
        }
    }

    private func acquire(_ physicalID: String) async {
        if waiters[physicalID] == nil {
            waiters[physicalID] = []
            return
        }
        await withCheckedContinuation { waiters[physicalID, default: []].append($0) }
    }

    private func release(_ physicalID: String) {
        guard var pending = waiters[physicalID], !pending.isEmpty else {
            // Idle IDs retain neither tokens nor owner closures nor completed tasks.
            waiters.removeValue(forKey: physicalID)
            return
        }
        let next = pending.removeFirst()
        waiters[physicalID] = pending
        next.resume()
    }
}
