import Foundation
import Observation

@MainActor @Observable
final class HermesAchievementsStore {
    let hostName: String
    private(set) var mount: HermesAchievementsMount = .unknown
    private(set) var catalog: HermesAchievementsCatalog?
    private(set) var recentUnlocks: [HermesAchievement] = []
    private(set) var status: HermesAchievementScanStatus?
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    private(set) var statusMessage: String?
    private(set) var isRetired = false
    var review: HermesAchievementsReview?

    @ObservationIgnored private let client: DirectHermesAchievementsClient
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    init(hostName: String, client: DirectHermesAchievementsClient) {
        self.hostName = hostName
        self.client = client
    }

    var ownsScope: Bool { !isRetired && client.ownsScope }
    var canAct: Bool {
        ownsScope && mount == .available && !isLoading && !isMutating && status?.state != .running
    }

    func load() async {
        guard ownsScope, !isMutating else { return }
        stopStatusPolling()
        let token = UUID()
        generation = token
        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer { if generation == token { isLoading = false } }
        do {
            mount = try await client.discoverMount()
            guard accepts(token) else { return }
            guard mount == .available else {
                catalog = nil
                recentUnlocks = []
                status = nil
                return
            }
            async let catalogValue = client.catalog()
            async let recentValue = client.recentUnlocks()
            let loadedCatalog = try await catalogValue
            let loadedRecent = try await recentValue
            guard accepts(token) else { return }
            catalog = loadedCatalog
            recentUnlocks = loadedRecent
            status = loadedCatalog.status
            describe(loadedCatalog.status)
            if loadedCatalog.status.state == .running { startStatusPolling() }
        } catch is CancellationError {
        } catch {
            guard accepts(token) else { return }
            errorMessage = Self.message(error)
        }
    }

    func refresh() async { await load() }

    func prepare(_ action: HermesAchievementsReview.Action) async {
        guard canAct else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let prepared = try await client.prepare(action)
            guard ownsScope else { return }
            review = prepared
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func confirm(_ approved: HermesAchievementsReview) async {
        guard canAct, review == approved else {
            review = nil
            return
        }
        review = nil
        stopStatusPolling()
        let token = UUID()
        generation = token
        isMutating = true
        errorMessage = nil
        successMessage = nil
        defer { if generation == token { isMutating = false } }
        do {
            switch approved.action {
            case .rescan:
                let result = try await client.rescan(approved: approved)
                guard accepts(token) else { return }
                switch result {
                case .completed(let catalog, let status):
                    self.catalog = catalog
                    self.status = status
                    recentUnlocks = catalog.achievements
                        .filter(\.isUnlocked)
                        .sorted { ($0.unlockedAt ?? .distantPast) > ($1.unlockedAt ?? .distantPast) }
                        .prefix(20).map { $0 }
                    successMessage = "Hermes finished the scan. Bighelp verified run \(status.runCount) and loaded its resulting catalog."
                    describe(status)
                case .running(let status):
                    self.status = status
                    statusMessage = "Hermes still reports this scan as running. Completion has not been claimed."
                    startStatusPolling()
                case .failed(let status):
                    self.status = status
                    errorMessage = status.lastError ?? "Hermes reported that the achievements scan failed."
                    describe(status)
                }
            case .reset:
                let status = try await client.reset(approved: approved)
                guard accepts(token) else { return }
                self.status = status
                catalog = nil
                recentUnlocks = []
                successMessage = "Hermes reset achievement unlock state and Bighelp verified the snapshot and checkpoint are no longer reported."
                statusMessage = "A new scan has not been claimed. Choose Rescan after reviewing that separate action."
            }
        } catch is CancellationError {
            guard accepts(token) else { return }
            errorMessage = "The request was interrupted. Refresh scan status before taking another action."
        } catch {
            guard accepts(token) else { return }
            errorMessage = Self.message(error)
        }
    }

    func retire() {
        isRetired = true
        generation = UUID()
        stopStatusPolling()
        catalog = nil
        recentUnlocks = []
        status = nil
        review = nil
        errorMessage = nil
        successMessage = nil
        statusMessage = nil
        isLoading = false
        isMutating = false
    }

    private func startStatusPolling() {
        stopStatusPolling()
        statusTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<90 {
                do { try await Task.sleep(nanoseconds: DirectHermesAchievementsClient.pollingIntervalNanoseconds) }
                catch { return }
                guard self.ownsScope else { return }
                do {
                    let value = try await self.client.scanStatus()
                    guard self.ownsScope else { return }
                    self.status = value
                    self.describe(value)
                    if value.state != .running {
                        if value.state == .idle {
                            let catalog = try await self.client.catalog()
                            guard self.ownsScope else { return }
                            self.catalog = catalog
                            self.recentUnlocks = try await self.client.recentUnlocks()
                        }
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard self.ownsScope else { return }
                    self.statusMessage = Self.message(error)
                    return
                }
            }
            guard self.ownsScope, self.status?.state == .running else { return }
            self.statusMessage = "Hermes still reports this scan as running after the bounded polling window. Pull to refresh its status."
        }
    }

    private func stopStatusPolling() {
        statusTask?.cancel()
        statusTask = nil
    }

    private func describe(_ status: HermesAchievementScanStatus) {
        switch status.state {
        case .idle:
            if let duration = status.lastDurationMilliseconds {
                statusMessage = "Last scan finished in \(duration) ms. Run count: \(status.runCount)."
            } else {
                statusMessage = "Hermes reports the achievements scanner is idle."
            }
        case .running:
            statusMessage = "Hermes reports the achievements scanner is running."
        case .failed:
            statusMessage = status.lastError ?? "Hermes reports that the achievements scan failed."
        }
    }

    private func accepts(_ token: UUID) -> Bool {
        ownsScope && generation == token && !Task.isCancelled
    }

    private static func message(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError, let message = localized.errorDescription {
            return message
        }
        return "Hermes could not complete the Achievements request. Refresh its mounted status before trying again."
    }
}
