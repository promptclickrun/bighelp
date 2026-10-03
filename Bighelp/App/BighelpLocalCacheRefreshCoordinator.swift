import Foundation

@MainActor
struct BighelpLocalCacheRefreshCoordinator {
    let invalidateStaleWork: @MainActor () async -> Void
    let clearCurrentHostCache: @MainActor () async throws -> Void
    let refreshAuthoritativeState: @MainActor () async -> Bool

    func clearAndRefresh() async -> Bool {
        await invalidateStaleWork()
        do {
            try await clearCurrentHostCache()
        } catch {
            return false
        }
        return await refreshAuthoritativeState()
    }
}
