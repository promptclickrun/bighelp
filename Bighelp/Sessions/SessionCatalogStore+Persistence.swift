import Foundation

extension SessionCatalogStore {
    func schedulePersistenceCheckpoint() {
        hasUnsavedChanges = true
        guard repository != nil, persistenceCheckpointTask == nil else { return }
        let id = UUID()
        persistenceCheckpointID = id
        let delay = persistenceCheckpointDelay
        persistenceCheckpointTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.writePersistenceCheckpoint(id: id)
        }
    }

    /// Saves at once without holding the main thread for the encoding. For the moment a reply
    /// lands: saving every chat there and then (`flushPersistence`) stalled the chat on screen just
    /// as the answer finished, longer the more chats there are. Leaving the app still flushes.
    func checkpointNow() {
        cancelPersistenceCheckpoint()
        guard hasUnsavedChanges, repository != nil else { return }
        let id = UUID()
        persistenceCheckpointID = id
        persistenceCheckpointTask = Task { [weak self] in
            await self?.writePersistenceCheckpoint(id: id)
        }
    }

    private func writePersistenceCheckpoint(id: UUID) async {
        guard persistenceCheckpointID == id, let repository else { return }
        guard repositoryAllowsWrites else { persistenceDidFail(); return }
        let revision = persistenceRevision
        let snapshot = records
        let account = accountGeneration
        do {
            let encoded: Data
            if let encodeSnapshot {
                encoded = try await encodeSnapshot(snapshot)
            } else {
                encoded = try await repository.encodeSnapshot(snapshot)
            }
            // A strict send checkpoint, account reset or host switch retires
            // this task. It must never overwrite the newer durable state.
            guard !Task.isCancelled, persistenceCheckpointID == id,
                  accountGeneration == account else { return }
            try repository.saveEncoded(encoded)
            repositorySaveCount += 1
            cancelPersistenceCheckpoint()
            persistenceErrorMessage = nil
            hasUnsavedChanges = persistenceRevision != revision
            if hasUnsavedChanges { schedulePersistenceCheckpoint() }
        } catch {
            guard persistenceCheckpointID == id, accountGeneration == account else { return }
            persistenceDidFail()
        }
    }

    func cancelPersistenceCheckpoint() {
        persistenceCheckpointID = nil
        persistenceCheckpointTask?.cancel()
        persistenceCheckpointTask = nil
    }

    /// Flush all sessions together at suspension, catch-up completion or exit.
    func flushPersistence() {
        cancelPersistenceCheckpoint()
        guard hasUnsavedChanges else { return }
        persistChangesIfNeeded()
    }

    func persistChangesIfNeeded() {
        cancelPersistenceCheckpoint()
        guard let repository else { return }
        guard repositoryAllowsWrites else {
            persistenceDidFail()
            return
        }
        do {
            try repository.save(records)
            repositorySaveCount += 1
            persistenceDidSucceed()
        } catch {
            persistenceDidFail()
        }
    }

    func loadPinPreferences() {
        guard
            let data = defaults.data(forKey: PreferenceKeys.pinsByHost),
            let allPreferences = try? JSONDecoder().decode(
                [String: [String: Bool]].self,
                from: data
            )
        else {
            pinPreferences = [:]
            return
        }
        pinPreferences = allPreferences[hostBucket] ?? [:]
    }

    func persistPinPreferences() {
        var allPreferences: [String: [String: Bool]] = [:]
        if let data = defaults.data(forKey: PreferenceKeys.pinsByHost),
           let decoded = try? JSONDecoder().decode([String: [String: Bool]].self, from: data) {
            allPreferences = decoded
        }
        if pinPreferences.isEmpty {
            allPreferences.removeValue(forKey: hostBucket)
        } else {
            allPreferences[hostBucket] = pinPreferences
        }
        guard let encoded = try? JSONEncoder().encode(allPreferences) else { return }
        defaults.set(encoded, forKey: PreferenceKeys.pinsByHost)
    }

    func migratePinnedRecordsIfNeeded(_ records: [SessionRecord]) {
        var changed = false
        for record in records where record.isPinned && pinPreferences[record.id] == nil {
            pinPreferences[record.id] = true
            changed = true
        }
        if changed { persistPinPreferences() }
    }

    func applyingPinPreferences(to records: [SessionRecord]) -> [SessionRecord] {
        records.map { record in
            guard let pinned = pinPreferences[record.id] else { return record }
            var preferred = record
            preferred.isPinned = pinned
            return preferred
        }
    }

    private var hostBucket: String {
        currentHostID() ?? ""
    }

    enum PreferenceKeys {
        static let pinsByHost = "loopdy.sessions.pin-preferences.by-host"
    }

    func persistenceDidSucceed() {
        cancelPersistenceCheckpoint()
        persistenceErrorMessage = nil
        hasUnsavedChanges = false
    }

    func persistenceDidFail() {
        cancelPersistenceCheckpoint()
        persistenceErrorMessage = "Chat changes could not be saved. Try again."
        hasUnsavedChanges = true
    }
}
