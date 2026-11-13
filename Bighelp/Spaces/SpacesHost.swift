import Foundation

/// A bot on a computer, as Today names it.
struct SpacesBot: Equatable, Sendable {
    /// Its `agentId` (Hermes' profile id).
    let id: String
    let name: String
}

/// One of the person's computers, as Today reads it: its cache scope (the key its spaces are kept
/// by), its routes while it's connected, and its bots.
struct SpacesComputer: Sendable {
    /// The host registry's id, or "demo".
    let hostKey: String
    /// `WorkspaceAuthority.cacheScopeID`: the same across reconnects, never the owner.
    let scope: String
    let name: String
    /// Nil while it isn't connected: Today shows its last panels.
    let api: SpacesAPI?
    /// The bots whose spaces to read. Empty while they aren't known yet: nothing is read.
    let bots: [SpacesBot]
    /// The computer in use, where chats (and their draft cards) are.
    let isCurrent: Bool
}

/// Where Spaces find the person's computers. Set up by the app (`BighelpApp`); empty until then.
@MainActor
enum SpacesHost {
    /// The computer in use: a chat's draft card adds its space here.
    static var current: @MainActor () -> SpacesComputer? = { nil }
    /// Every computer Today shows, the one in use first: connected ones with their routes and bots,
    /// the others with their saved scope only.
    static var computers: @MainActor () -> [SpacesComputer] = { [] }
    /// The `hostKey` of every computer the app has, whether or not it can be read now. Nil when the
    /// app can't say: only the computers listed above then count.
    static var hostKeys: @MainActor () -> Set<String>? = { nil }
    /// The HTML app routes of the computer with this cache scope, where a space's page is; nil
    /// while it isn't connected.
    static var pages: @MainActor (_ scope: String) -> HTMLAppsAPI? = { _ in nil }
}
