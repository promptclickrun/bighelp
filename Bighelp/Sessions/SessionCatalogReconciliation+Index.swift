import Foundation

extension SessionCatalogReconciliation {
    /// A list of chats looked up by id and by the host's durable id. A host with thousands of
    /// scheduled runs lists them all on every change; scanning the list for each row took
    /// seconds on the main actor. Removed rows leave a gap so positions, and so order, hold.
    @MainActor
    struct Index {
        private var slots: [SessionRecord?]
        private var byID: [String: [Int]] = [:]
        private var byStoredID: [String: [Int]] = [:]

        init(_ records: [SessionRecord]) {
            slots = records
            for index in records.indices { register(index) }
        }

        /// The rows still in the list, in their order.
        var records: [SessionRecord] { slots.compactMap { $0 } }

        subscript(index: Int) -> SessionRecord { slots[index]! }

        /// Every row with this id, in list order.
        func indices(id: String) -> [Int] {
            (byID[id] ?? []).filter { slots[$0] != nil }
        }

        func firstIndex(id: String) -> Int? {
            indices(id: id).first
        }

        /// The rows a host row stands for, in list order: the same id, the same durable identity,
        /// or a live-only alias under the host's durable id.
        func matches(for incoming: SessionRecord) -> [Int] {
            var candidates = byID[incoming.id] ?? []
            if let storedID = incoming.remoteStoredID {
                candidates += byStoredID[storedID] ?? []
                candidates += byID[storedID] ?? []
            }
            return Set(candidates).sorted().filter { index in
                guard let local = slots[index] else { return false }
                return local.id == incoming.id
                    || hasSameDurableIdentity(local, incoming)
                    || isTransientActivityAlias(local, of: incoming)
            }
        }

        mutating func append(_ record: SessionRecord) {
            slots.append(record)
            register(slots.count - 1)
        }

        mutating func remove(at index: Int) {
            slots[index] = nil
        }

        mutating func replace(at index: Int, with record: SessionRecord) {
            slots[index] = record
            register(index)
        }

        private mutating func register(_ index: Int) {
            guard let record = slots[index] else { return }
            if byID[record.id]?.contains(index) != true { byID[record.id, default: []].append(index) }
            if let storedID = record.remoteStoredID, byStoredID[storedID]?.contains(index) != true {
                byStoredID[storedID, default: []].append(index)
            }
        }
    }
}
