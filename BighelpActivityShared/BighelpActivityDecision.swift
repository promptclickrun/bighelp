// Live Activities are iPhone and iPad only, and so are their buttons.
#if os(iOS) && !targetEnvironment(macCatalyst)
import AppIntents
import Foundation

/// What the island's Approve and Deny do. The app sets it as it starts; the Live Activity extension
/// never does, because iOS runs a Live Activity's intent in the app.
@MainActor
enum BighelpActivityActions {
    static var decide: (@MainActor (_ rowID: String, _ approves: Bool) async -> Void)?

    static func run(rowID: String, approves: Bool) async {
        await decide?(rowID, approves)
    }
}

/// Approve or Deny beside a command the island shows in full. It runs in the app, which answers the
/// computer over its own connection. `isDiscoverable` keeps it out of the Shortcuts app, and the
/// phone must be unlocked: a yes to a command is the person's own.
struct BighelpActivityDecisionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer a request"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Chat")
    var rowID: String

    @Parameter(title: "Approve")
    var approves: Bool

    init() {}

    init(rowID: String, approves: Bool) {
        self.rowID = rowID
        self.approves = approves
    }

    func perform() async throws -> some IntentResult {
        await BighelpActivityActions.run(rowID: rowID, approves: approves)
        return .result()
    }
}
#endif
