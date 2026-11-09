import Foundation

/// Why a computer didn't take app state.
enum AppStateError: Error, Equatable {
    /// Another device saved a newer revision first (`409 app_state_conflict`): read it, change it again, retry.
    case conflict
    /// The computer's plugin doesn't have `native-app-state-v1`: the phone keeps these choices itself.
    case needsPluginUpdate
    /// Refused for what's in it (too big, looks like a password, too many keys): trying again won't help.
    case refused(String)
}

/// One computer's app state routes.
@MainActor
protocol AppStateClient: AnyObject {
    func read(person: String, keys: [String]) async throws -> AppStateWire.Answer
    func write(person: String, device: String, writes: [String: AppStateWire.Write]) async throws -> AppStateWire.Answer
}

/// The plugin's `app-state` routes on one connected computer.
@MainActor
final class DirectHermesAppStateClient: AppStateClient {
    private let workspace: @MainActor () -> (any WorkspaceOperationPerforming)?

    init(workspace: @escaping @MainActor () -> (any WorkspaceOperationPerforming)?) {
        self.workspace = workspace
    }

    func read(person: String, keys: [String]) async throws -> AppStateWire.Answer {
        try AppStateWire.answer(try await perform(.appStateRead, AppStateWire.readPayload(person: person, keys: keys)))
    }

    func write(person: String, device: String, writes: [String: AppStateWire.Write]) async throws -> AppStateWire.Answer {
        try AppStateWire.answer(try await perform(
            .appStateWrite, AppStateWire.writePayload(person: person, device: device, writes: writes)))
    }

    private func perform(_ operation: WorkspaceOperation,
                         _ payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        guard let workspace = workspace(), let owner = workspace.owner else {
            throw WorkspaceClientError.transportUnavailable
        }
        do {
            do {
                return try await workspace.perform(operation, payload: payload, owner: owner)
            } catch WorkspaceClientError.conflict {
                // The plugin's context changed (412): the next call loads it again. Once.
                return try await workspace.perform(operation, payload: payload, owner: owner)
            }
        } catch let error as WorkspaceClientError {
            switch error {
            case .unavailable(.unsupportedOperation), .unavailable(.pluginRequired):
                throw AppStateError.needsPluginUpdate
            case .rejected(let code?, _) where code == "app_state_conflict":
                throw AppStateError.conflict
            case .rejected(let code?, _) where code == "app_state_unavailable":
                throw AppStateError.needsPluginUpdate
            case .rejected(let code?, _) where ["secret_scan_blocked", "store_full", "invalid_request"].contains(code):
                throw AppStateError.refused(code)
            case .capacityExceeded:
                throw AppStateError.refused("app_state_too_large")
            default:
                throw error
            }
        }
    }
}

/// Demo mode's computer: the plugin's rules, kept in memory for this run.
@MainActor
final class DemoAppStateClient: AppStateClient {
    static let shared = DemoAppStateClient()

    let computerID: String
    private var people: [String: [String: AppStateWire.Entry]] = [:]
    /// Writes taken, for tests.
    private(set) var writes = 0

    init(computerID: String = "0d3e5c1a-7b2f-4c6d-9e8a-1f2b3c4d5e6f") {
        self.computerID = computerID
    }

    func read(person: String, keys: [String]) async throws -> AppStateWire.Answer {
        guard AppStateWire.isID(person) else { throw WorkspaceClientError.rejected(code: "invalid_request") }
        let stored = people[person] ?? [:]
        return AppStateWire.Answer(computerID: computerID,
                                   entries: keys.isEmpty ? stored : stored.filter { keys.contains($0.key) })
    }

    func write(person: String, device: String, writes: [String: AppStateWire.Write]) async throws -> AppStateWire.Answer {
        guard AppStateWire.isID(person), AppStateWire.isID(device), !writes.isEmpty else {
            throw WorkspaceClientError.rejected(code: "invalid_request")
        }
        var stored = people[person] ?? [:]
        for (key, write) in writes {
            guard AppStateWire.isKey(key), write.revision > write.baseRevision, write.baseRevision >= 0,
                  write.revision <= AppStateWire.maximumRevision else {
                throw WorkspaceClientError.rejected(code: "invalid_request")
            }
            guard AppStateWire.encodedSize(write.value) <= AppStateWire.maximumValueBytes else {
                throw AppStateError.refused("app_state_too_large")
            }
        }
        // All or nothing: a newer revision anywhere refuses the whole write.
        if writes.contains(where: { (stored[$0.key]?.revision ?? 0) > $0.value.baseRevision }) {
            throw AppStateError.conflict
        }
        for (key, write) in writes { stored[key] = AppStateWire.Entry(value: write.value, revision: write.revision) }
        people[person] = stored
        self.writes += 1
        return AppStateWire.Answer(computerID: computerID, entries: stored.filter { writes[$0.key] != nil })
    }

    /// What's stored for `person`, for tests.
    func stored(_ person: String) -> [String: AppStateWire.Entry] { people[person] ?? [:] }

    /// Another device's write, straight into the store, for tests.
    func save(_ entry: AppStateWire.Entry, key: String, person: String) {
        people[person, default: [:]][key] = entry
    }
}
