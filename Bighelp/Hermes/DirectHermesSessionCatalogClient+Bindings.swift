import Foundation

/// Which saved rows a host row stands for, by the identities Hermes gives a session: its own
/// id, the row and lineage ids of the chat it continues, and its canonical registry id.
extension DirectHermesSessionCatalogClient {
    /// Every identity a saved row can be matched by. `binding(_:containsStoredIdentity:)` is the
    /// same test one identity at a time.
    func storedIdentities(of binding: Binding) -> [String] {
        var ids = [binding.anchorID]
        ids += [binding.coordinate.storedSessionID, binding.catalog?.rowID, binding.catalog?.lineageRootID,
                binding.catalog?.canonicalRegistryID].compactMap { $0 }
        ids += binding.catalog?.lineageIDs ?? []
        return ids
    }

    func binding(_ binding: Binding, containsStoredIdentity value: String) -> Bool {
        storedIdentities(of: binding).contains { DirectHermesSessionValidation.same($0, value) }
    }

    func identityKeys(_ binding: Binding) -> Set<String> {
        var ids = [binding.anchorID]
        ids += [binding.coordinate.storedSessionID, binding.runtimeSessionKey, binding.canonicalRegistryID,
                binding.catalog?.rowID, binding.catalog?.lineageRootID].compactMap { $0 }
        ids += binding.catalog?.lineageIDs ?? []
        return Set(ids.map(DirectHermesSessionIdentity.key))
    }

    /// Saved rows by the identity each is anchored to. A host row's own identities look up the
    /// saved rows that `binding(_:containsStoredIdentity:)` would match, without a scan per row.
    struct BindingAnchorIndex {
        private var byAnchor: [String: [Binding]] = [:]

        init(_ bindings: some Sequence<Binding>) {
            for binding in bindings {
                byAnchor[DirectHermesSessionIdentity.key(binding.anchorID), default: []].append(binding)
            }
        }

        /// Saved rows whose anchor is one of these identities, each once.
        func bindings(anchoredIn identities: [String]) -> [Binding] {
            var seen = Set<String>()
            return identities.flatMap { byAnchor[DirectHermesSessionIdentity.key($0)] ?? [] }
                .filter { seen.insert($0.record.id).inserted }
        }
    }
}
