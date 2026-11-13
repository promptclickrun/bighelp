import Observation
import SwiftUI

/// A bot's config.yaml on its computer, as bighelp reads and saves it: the time zone (Settings ›
/// Your computers › Time zone) and Advanced Options (approvals and the rest).
@MainActor
protocol SimpleBotHostConfiguring: AnyObject {
    func read(profile: String) async throws -> [String: BighelpJSONValue]
    /// Saves only these keys; Hermes merges them into the rest of the config.
    func write(_ config: [String: BighelpJSONValue], profile: String) async throws
}

/// The live host: Hermes' dashboard config routes, the same ones voice settings use.
@MainActor
final class SimpleBotWorkspaceConfiguration: SimpleBotHostConfiguring {
    private let workspace: @MainActor () -> (any WorkspaceOperationPerforming)?

    init(workspace: @escaping @MainActor () -> (any WorkspaceOperationPerforming)?) {
        self.workspace = workspace
    }

    func read(profile: String) async throws -> [String: BighelpJSONValue] {
        guard let workspace = workspace(), let owner = workspace.owner else {
            throw WorkspaceClientError.transportUnavailable
        }
        return try await workspace.perform(.workspaceConfigGet, payload: ["profile": .string(profile)], owner: owner)
    }

    func write(_ config: [String: BighelpJSONValue], profile: String) async throws {
        guard let workspace = workspace(), let owner = workspace.owner else {
            throw WorkspaceClientError.transportUnavailable
        }
        let result = try await workspace.perform(.workspaceConfigSet, payload: [
            "profile": .string(profile), "config": .object(config),
        ], owner: owner)
        guard result["ok"]?.boolean != false else { throw WorkspaceClientError.invalidResponse }
    }
}

/// Demo mode's config, in memory, merged like Hermes merges a save.
@MainActor
final class SimpleBotDemoConfiguration: SimpleBotHostConfiguring {
    static let shared = SimpleBotDemoConfiguration()
    private var configs: [String: [String: BighelpJSONValue]] = [:]

    func read(profile: String) async throws -> [String: BighelpJSONValue] {
        configs[profile] ?? ["approvals": .object(["mode": .string("smart")]), "timezone": .string("")]
    }

    func write(_ config: [String: BighelpJSONValue], profile: String) async throws {
        configs[profile] = Self.merge(try await read(profile: profile), config)
    }

    static func merge(_ base: [String: BighelpJSONValue], _ incoming: [String: BighelpJSONValue])
        -> [String: BighelpJSONValue] {
        var result = base
        for (key, value) in incoming {
            if case .object(let inner) = value, case .object(let existing)? = result[key] {
                result[key] = .object(merge(existing, inner))
            } else {
                result[key] = value
            }
        }
        return result
    }
}

/// The time zone the bots on a computer work in (Settings › Your computers › Time zone).
/// Approvals live in each bot's Advanced Options, so only one place writes them.
@MainActor
@Observable
final class SimpleBotHostSettings {
    enum Load: Equatable { case idle, loading, loaded, unavailable }

    private(set) var load: Load = .idle
    /// Hermes' time zone; empty means the computer's own.
    private(set) var timeZone = ""
    private(set) var isSaving = false
    var errorMessage: String?

    @ObservationIgnored private let client: any SimpleBotHostConfiguring
    @ObservationIgnored private let profile: String
    @ObservationIgnored private let allProfiles: () -> [String]

    init(client: any SimpleBotHostConfiguring, profile: String, allProfiles: @escaping () -> [String]) {
        self.client = client
        self.profile = profile
        self.allProfiles = allProfiles
    }

    func refresh() async {
        if load == .idle { load = .loading }
        do {
            apply(try await client.read(profile: profile))
            load = .loaded
        } catch {
            load = .unavailable
        }
    }

    /// The time zone every bot on this computer works in (schedules, "today").
    func setTimeZone(_ identifier: String) async {
        guard identifier != timeZone else { return }
        await save(["timezone": .string(identifier)], profiles: allProfiles())
    }

    private func save(_ config: [String: BighelpJSONValue], profiles: [String]) async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            for profile in Set(profiles + [self.profile]).sorted() {
                try await client.write(config, profile: profile)
            }
            apply(try await client.read(profile: profile))
        } catch {
            errorMessage = String(localized: "The computer didn't save that. Try again in a moment.")
        }
    }

    private func apply(_ config: [String: BighelpJSONValue]) {
        timeZone = config["timezone"]?.string ?? ""
    }
}
