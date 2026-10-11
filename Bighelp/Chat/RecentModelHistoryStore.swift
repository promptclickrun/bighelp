import Foundation
import Observation

@MainActor
@Observable
final class RecentModelHistoryStore {
    private struct Entry: Codable, Equatable, Hashable {
        let providerID: String
        let modelID: String
    }

    private static let maximumEntries = 12
    private static let maximumPinnedEntries = 12
    private static let storageKey = "loopdy.models.recent"
    private static let pinnedStorageKey = "loopdy.models.pinned"

    private let defaults: UserDefaults
    private let scopeID: () -> String?
    private var entriesByScope: [String: [Entry]]
    private var pinnedEntriesByScope: [String: [Entry]]

    init(
        defaults: UserDefaults = .standard,
        scopeID: @escaping () -> String? = { "default" }
    ) {
        self.defaults = defaults
        self.scopeID = scopeID
        entriesByScope = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: [Entry]].self, from: $0) }
            ?? [:]
        pinnedEntriesByScope = defaults.data(forKey: Self.pinnedStorageKey)
            .flatMap { try? JSONDecoder().decode([String: [Entry]].self, from: $0) }
            ?? [:]
    }

    func record(providerID: String, modelID: String) {
        guard let scope = currentScopeID else { return }
        let entry = Entry(providerID: providerID, modelID: modelID)
        var entries = entriesByScope[scope] ?? []
        entries.removeAll { $0 == entry }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(Self.maximumEntries))
        entriesByScope[scope] = entries
        if let data = try? JSONEncoder().encode(entriesByScope) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    func isPinned(providerID: String, modelID: String) -> Bool {
        guard let scope = currentScopeID else { return false }
        let entry = Entry(providerID: providerID, modelID: modelID)
        return (pinnedEntriesByScope[scope] ?? []).contains(entry)
    }

    var hasReachedPinCapacity: Bool {
        guard let scope = currentScopeID else { return false }
        return (pinnedEntriesByScope[scope] ?? []).count >= Self.maximumPinnedEntries
    }

    /// Toggles an exact provider/model favorite in the current account/host
    /// partition. Newly pinned models sort first, so a successful pin is
    /// immediately visible in the bounded quick-choice catalog. A `false`
    /// result means the model is not pinned, including when the twelve-item
    /// capacity has been reached; callers can surface that limit to the user.
    @discardableResult
    func togglePin(providerID: String, modelID: String) -> Bool {
        guard
            let scope = currentScopeID,
            !providerID.isEmpty,
            !modelID.isEmpty
        else { return false }

        let entry = Entry(providerID: providerID, modelID: modelID)
        var entries = pinnedEntriesByScope[scope] ?? []
        if let index = entries.firstIndex(of: entry) {
            entries.remove(at: index)
            pinnedEntriesByScope[scope] = entries
            persistPinnedEntries()
            return false
        }

        guard entries.count < Self.maximumPinnedEntries else { return false }
        entries.insert(entry, at: 0)
        pinnedEntriesByScope[scope] = entries
        persistPinnedEntries()
        return true
    }

    /// Only the models picked before on this computer, newest first; nothing fills the gaps.
    func recentChoices(
        providers: [BighelpLinkModelProvider],
        currentProviderID: String?,
        currentModelID: String?,
        limit: Int = 12
    ) -> [RecentModelChoice] {
        guard limit > 0, let scope = currentScopeID else { return [] }
        return resolvedChoices(
            for: entriesByScope[scope] ?? [],
            providers: providers,
            currentProviderID: currentProviderID,
            currentModelID: currentModelID,
            limit: limit
        )
    }

    func pinnedChoices(
        providers: [BighelpLinkModelProvider],
        currentProviderID: String?,
        currentModelID: String?,
        limit: Int = 12
    ) -> [RecentModelChoice] {
        guard limit > 0, let scope = currentScopeID else { return [] }
        return resolvedChoices(
            for: pinnedEntriesByScope[scope] ?? [],
            providers: providers,
            currentProviderID: currentProviderID,
            currentModelID: currentModelID,
            limit: limit
        )
    }

    func choices(
        providers: [BighelpLinkModelProvider],
        currentProviderID: String?,
        currentModelID: String?,
        limit: Int = 4
    ) -> [RecentModelChoice] {
        guard limit > 0 else { return [] }
        var result: [RecentModelChoice] = []
        var seen = Set<Entry>()
        let scope = currentScopeID

        func append(providerID: String, modelID: String) {
            guard
                result.count < limit,
                let provider = providers.first(where: { $0.id == providerID }),
                provider.models.contains(modelID)
            else { return }
            let entry = Entry(providerID: providerID, modelID: modelID)
            guard seen.insert(entry).inserted else { return }
            result.append(
                RecentModelChoice(
                    providerID: provider.id,
                    providerName: provider.name,
                    modelID: modelID,
                    isCurrent: providerID == currentProviderID && modelID == currentModelID
                )
            )
        }

        if let scope {
            for entry in pinnedEntriesByScope[scope] ?? [] {
                append(providerID: entry.providerID, modelID: entry.modelID)
            }
        }
        if let currentProviderID, let currentModelID {
            append(providerID: currentProviderID, modelID: currentModelID)
        }
        if let scope {
            for entry in entriesByScope[scope] ?? [] {
                append(providerID: entry.providerID, modelID: entry.modelID)
            }
        }
        for provider in providers {
            guard let modelID = provider.models.first else { continue }
            append(providerID: provider.id, modelID: modelID)
        }
        return result
    }

    private var currentScopeID: String? {
        guard let scope = scopeID() else { return nil }
        let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed == scope,
            !scope.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return scope
    }

    private func resolvedChoices(
        for entries: [Entry],
        providers: [BighelpLinkModelProvider],
        currentProviderID: String?,
        currentModelID: String?,
        limit: Int
    ) -> [RecentModelChoice] {
        var result: [RecentModelChoice] = []
        var seen = Set<Entry>()
        for entry in entries {
            guard
                result.count < limit,
                seen.insert(entry).inserted,
                let provider = providers.first(where: { $0.id == entry.providerID }),
                provider.models.contains(entry.modelID)
            else { continue }
            result.append(RecentModelChoice(
                providerID: provider.id,
                providerName: provider.name,
                modelID: entry.modelID,
                isCurrent: entry.providerID == currentProviderID
                    && entry.modelID == currentModelID
            ))
        }
        return result
    }

    private func persistPinnedEntries() {
        if let data = try? JSONEncoder().encode(pinnedEntriesByScope) {
            defaults.set(data, forKey: Self.pinnedStorageKey)
        }
    }
}
