import Foundation

/// `navigation.places` and `navigation.open`, the agent's `iphone_navigation` tool (#662): it finds a
/// place in bighelp by the person's words and shows the person the way there, under the driving
/// overlay (`DriveNavigator`). It only moves between pages and points at controls, so it's never
/// journaled: opening a place twice is the same as once.
@MainActor
final class DeviceNavigationTool {
    enum Failure: String, DeviceToolFailure, Equatable {
        case invalidArguments = "invalid_arguments"
        /// No place has that id; `places` lists them.
        case unknownPlace = "unknown_place"
        /// The place isn't in the mode the app is in (Bots, Chat or Code).
        case notInThisMode = "not_in_this_mode"
        /// Only with Settings › Nerd Mode on. A drive never turns it on.
        case needsNerdMode = "needs_nerd_mode"
        /// A place inside one bot, and no bot on this computer has that id.
        case needsBot = "needs_bot"
        /// The app can't drive right now (it's still starting).
        case busy
        case unsupportedOperation = "unsupported_operation"

        var code: String { rawValue }
    }

    static let operations: Set<String> = ["navigation.places", "navigation.open"]
    /// The plugin's bounds too.
    static let maximumQueryLength = 120
    static let maximumNoteLength = 160
    static let maximumIDLength = 96

    /// What the tool needs from the app.
    struct Environment {
        var mode: @MainActor () -> BighelpMode
        var nerdMode: @MainActor () -> Bool
        /// The bot's name, when this computer has a bot with that id.
        var botName: @MainActor (String) -> String?
        /// Starts the drive and returns the trail; nil when the app can't drive yet.
        var open: @MainActor (DrivePlace, [DriveStep], (id: String, name: String)?, String?, DeviceToolCallContext) -> [String]?
    }

    private let environment: Environment

    init(_ environment: Environment) { self.environment = environment }

    func execute(
        operation: String,
        arguments: [String: BighelpJSONValue],
        context: DeviceToolCallContext,
        authorize: @MainActor () throws -> Void
    ) throws -> [String: BighelpJSONValue] {
        switch operation {
        case "navigation.places":
            let (query, limit) = try Self.placesArguments(arguments)
            try authorize()
            let mode = environment.mode()
            let found = DriveCatalog.search(query ?? "", mode: mode, nerdMode: environment.nerdMode(), limit: limit)
            return [
                "places": .array(found.map { place in
                    .object([
                        "id": .string(place.id),
                        "title": .string(place.title),
                        "what": .string(place.what),
                        "steps": .array((place.playbooks[mode] ?? []).map { .string($0.label(bot: nil)) }),
                        "needs": place.needs.contains(.bot) ? .string("bot") : .null,
                    ])
                }),
                "total": .integer(found.count),
            ]
        case "navigation.open":
            let request = try Self.openArguments(arguments)
            guard let place = DriveCatalog.place(request.place) else { throw Failure.unknownPlace }
            let mode = environment.mode()
            guard let steps = place.playbooks[mode] else { throw Failure.notInThisMode }
            if place.needs.contains(.nerdMode), !environment.nerdMode() { throw Failure.needsNerdMode }
            var bot: (id: String, name: String)?
            if place.needs.contains(.bot) {
                // The bot the agent names, else the agent itself: "show me your profile".
                let id = request.bot ?? context.agentID
                guard let name = environment.botName(id) else { throw Failure.needsBot }
                bot = (id, name)
            }
            try authorize()
            guard let trail = environment.open(place, steps, bot, request.note, context) else { throw Failure.busy }
            return ["opened": .string(place.id), "steps": .array(trail.map { .string($0) }), "mode": .string(mode.rawValue)]
        default:
            throw Failure.unsupportedOperation
        }
    }

    private static func placesArguments(_ arguments: [String: BighelpJSONValue]) throws -> (String?, Int) {
        guard Set(arguments.keys).isSubset(of: ["query", "limit"]) else { throw Failure.invalidArguments }
        var query: String?
        if let value = arguments["query"] {
            guard let text = value.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  text.count <= maximumQueryLength else { throw Failure.invalidArguments }
            query = text
        }
        var limit = 8
        if let value = arguments["limit"] {
            guard case .integer(let number) = value, (1...20).contains(number) else { throw Failure.invalidArguments }
            limit = number
        }
        return (query, limit)
    }

    private struct OpenRequest {
        let place: String
        let bot: String?
        let note: String?
    }

    private static func openArguments(_ arguments: [String: BighelpJSONValue]) throws -> OpenRequest {
        guard Set(arguments.keys).isSubset(of: ["place", "bot", "note"]),
              let place = arguments["place"]?.string, isPlaceID(place) else { throw Failure.invalidArguments }
        var bot: String?
        if let value = arguments["bot"] {
            guard let id = value.string, !id.isEmpty, id.utf8.count <= maximumIDLength else { throw Failure.invalidArguments }
            bot = id
        }
        var note: String?
        if let value = arguments["note"] {
            guard let text = value.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  text.count <= maximumNoteLength else { throw Failure.invalidArguments }
            note = text
        }
        return OpenRequest(place: place, bot: bot, note: note)
    }

    /// Lowercase letters, digits, "." and "-". Byte checks, not CharacterSet (see `BighelpIncomingURLRoute`).
    private static func isPlaceID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumIDLength && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2E || byte == 0x2D
        }
    }
}
