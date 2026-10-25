import Foundation

/// The computer in use: its cache scope (`WorkspaceOwner.cacheScopeID`) and its routes.
typealias PhotoActionsConnection = (scope: String, api: ImageDraftsAPI)

/// Why a Photo actions change didn't save, in words for the page.
enum PhotoActionsSaveError: Error, Equatable {
    case needsPluginUpdate
    /// Someone changed this agent's settings elsewhere; the page now shows theirs.
    case changedElsewhere
    case invalid
    case noConnection
    case failed

    var message: String {
        switch self {
        case .needsPluginUpdate: String(localized: "Update the bighelp plugin to change Photo actions.")
        case .changedElsewhere: String(localized: "These settings changed on another device. This is the latest; make your change again.")
        case .invalid: String(localized: "Some of this text can't be saved. Check the messages marked in red.")
        case .noConnection: String(localized: "Can't reach the computer. Try again when it's connected.")
        case .failed: String(localized: "The computer didn't save that. Try again.")
        }
    }
}

/// Each agent's Photo actions settings on the computer in use, kept for the launch so the page
/// opens at once on what it showed last and refreshes behind it.
@MainActor
@Observable
final class PhotoActionsSettingsStore {
    /// Set up by the app with the computer in use (`BighelpApp`).
    static let shared = PhotoActionsSettingsStore()

    enum Load: Equatable { case idle, loading, loaded, needsPluginUpdate, unavailable }

    struct Entry: Equatable {
        var page = ImageActionsSettingsPage(settings: ImageActionsSettings(), defaults: .standard)
        var load: Load = .idle
    }

    private(set) var entries: [String: Entry] = [:]
    private(set) var saving: Set<String> = []

    @ObservationIgnored var connection: @MainActor () -> PhotoActionsConnection?
    @ObservationIgnored private var scope: String?
    @ObservationIgnored private var refreshing: [String: Task<Void, Never>] = [:]

    init(connection: @escaping @MainActor () -> PhotoActionsConnection? = { nil }) {
        self.connection = connection
    }

    func entry(_ agentID: String) -> Entry { entries[agentID] ?? Entry() }

    /// One read per agent at a time; callers during it wait for that one.
    func refresh(_ agentID: String) async {
        if let running = refreshing[agentID] {
            await running.value
            return
        }
        let task = Task { await reload(agentID) }
        refreshing[agentID] = task
        await task.value
        refreshing[agentID] = nil
    }

    private func reload(_ agentID: String) async {
        // No connection is the gap of a reconnect, not another computer: what's here stays.
        guard let connection = connection() else {
            if entries[agentID]?.load != .loaded { entries[agentID, default: Entry()].load = .unavailable }
            return
        }
        adopt(connection.scope)
        if entries[agentID]?.load != .loaded { entries[agentID, default: Entry()].load = .loading }
        do {
            let page = try await connection.api.settings(agentID: agentID)
            guard scope == connection.scope else { return }
            entries[agentID] = Entry(page: page, load: .loaded)
        } catch .needsPluginUpdate {
            guard scope == connection.scope else { return }
            entries[agentID] = Entry(load: .needsPluginUpdate)
        } catch {
            // A failed read keeps what the page shows.
            guard scope == connection.scope, entries[agentID]?.load != .loaded else { return }
            entries[agentID, default: Entry()].load = .unavailable
        }
    }

    /// Applies one change to what the computer has and saves it with the revision it was read at.
    /// A revision that moved reloads the page and says so, rather than overwriting someone else's edit.
    func update(_ agentID: String, _ change: (inout ImageActionsSettings, ImageActionsDefaults) -> Void)
        async throws(PhotoActionsSaveError) {
        guard let connection = connection() else { throw .noConnection }
        adopt(connection.scope)
        guard entries[agentID]?.load == .loaded, var settings = entries[agentID]?.page.settings,
              let defaults = entries[agentID]?.page.defaults else { throw .noConnection }
        change(&settings, defaults)
        do { try settings.validate() } catch { throw .invalid }
        saving.insert(agentID)
        defer { saving.remove(agentID) }
        do {
            let saved = try await connection.api.save(settings, agentID: agentID)
            guard scope == connection.scope else { return }
            entries[agentID]?.page.settings = saved
        } catch {
            switch error {
            case .revisionConflict:
                await reload(agentID)
                throw .changedElsewhere
            case .needsPluginUpdate:
                if scope == connection.scope { entries[agentID] = Entry(load: .needsPluginUpdate) }
                throw .needsPluginUpdate
            case .refused: throw .invalid
            case .noConnection: throw .noConnection
            default: throw .failed
            }
        }
    }

    private func adopt(_ next: String) {
        guard scope != next else { return }
        scope = next
        entries = [:]
        refreshing = [:]
    }
}
