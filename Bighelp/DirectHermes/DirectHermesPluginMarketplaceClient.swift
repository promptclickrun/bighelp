import Foundation

/// The plugin's `marketplace/plugins` route (`native-marketplace-v1`): what Hermes' marketplace page
/// knows about each catalog plugin and the host's catalog route leaves out (GitHub stars, the curated
/// featured rank, when it was added and changed), and Hermes' own refusal for each plugin this computer
/// won't install. The plugin reads the marketplace's feed for the app, so the app talks only to the host.
@MainActor
final class DirectHermesPluginMarketplaceClient: PluginMarketplaceReading {
    static let feature = "native-marketplace-v1"
    nonisolated static let maximumPlugins = 5_000

    private let currentWorkspace: @MainActor () -> (any WorkspaceOperationPerforming)?

    init(currentWorkspace: @escaping @MainActor () -> (any WorkspaceOperationPerforming)?) {
        self.currentWorkspace = currentWorkspace
    }

    func plugins() async -> [String: PluginMarketplaceFacts]? {
        // A plugin without the feature fails the call as unsupported: the storefront then goes by the catalog.
        guard let workspace = currentWorkspace(), let owner = workspace.owner else { return nil }
        let response: [String: BighelpJSONValue]
        do {
            response = try await workspace.perform(.marketplacePlugins, payload: [:], owner: owner)
        } catch WorkspaceClientError.conflict {
            // The plugin's context changed (412): the next call loads it again. Once.
            guard let retried = try? await workspace.perform(.marketplacePlugins, payload: [:], owner: owner) else {
                return nil
            }
            response = retried
        } catch {
            return nil
        }
        return Self.facts(from: response)
    }

    /// Leniently: a field this build can't read is left out, a row without a name is skipped.
    nonisolated static func facts(from response: [String: BighelpJSONValue]) -> [String: PluginMarketplaceFacts]? {
        guard let rows = response["plugins"]?.array else { return nil }
        var facts: [String: PluginMarketplaceFacts] = [:]
        for value in rows.prefix(maximumPlugins) {
            guard let row = value.object, let name = row["name"]?.string, !name.isEmpty, name.utf8.count <= 64,
                  facts[name] == nil else { continue }
            let refusal = HermesRefusalMessage(row["installRefusal"]?.string)
            facts[name] = PluginMarketplaceFacts(
                stars: row["stars"]?.integer.flatMap { $0 >= 0 ? $0 : nil },
                featuredRank: row["featured"]?.integer.flatMap { $0 > 0 ? $0 : nil },
                addedAt: date(row["addedAt"]),
                updatedAt: date(row["updatedAt"]),
                installRefusal: refusal.text)
        }
        return facts
    }

    private nonisolated static func date(_ value: BighelpJSONValue?) -> Date? {
        guard let text = value?.string, text.utf8.count <= 40 else { return nil }
        return try? Date(text, strategy: .iso8601)
    }
}
