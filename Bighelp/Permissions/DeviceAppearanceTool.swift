import Foundation

/// `appearance.get` and `appearance.set`, the agent's `iphone_appearance` tool: light or dark mode and
/// the chat color (bubbles and buttons), changed through `SettingsStore` like Appearance does, so the
/// person's next pick there wins. It changes the look only while `authorize` passes: the chat that
/// asked is still open, bighelp is in front and the switch is on.
@MainActor
final class DeviceAppearanceTool {
    enum Failure: String, DeviceToolFailure, Equatable {
        case invalidArguments = "invalid_arguments"
        /// Not one of the app's color names; `get` lists them.
        case unknownColor = "unknown_color"
        case unsupportedOperation = "unsupported_operation"

        var code: String { rawValue }
    }

    static let operations: Set<String> = ["appearance.get", "appearance.set"]

    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func execute(
        operation: String,
        arguments: [String: BighelpJSONValue],
        authorize: @MainActor () throws -> Void
    ) throws -> [String: BighelpJSONValue] {
        switch operation {
        case "appearance.get":
            guard arguments.isEmpty else { throw Failure.invalidArguments }
            try authorize()
            return look.merging([
                "modes": .array(AppAppearance.allCases.map { .string($0.rawValue) }),
                "colors": .array(BighelpBubbleColor.allCases.map { .string($0.agentName) }),
            ]) { current, _ in current }
        case "appearance.set":
            // Check everything first, so a refused request changes nothing.
            let change = try Change(arguments)
            try authorize()
            if let mode = change.mode { settings.appearance = mode }
            switch change.color {
            case .named(let color): settings.pickBubbleColor(color)
            case .custom(let hex): settings.customBubbleHex = hex
            case nil: break
            }
            return look
        default:
            throw Failure.unsupportedOperation
        }
    }

    /// What the app shows now, as the agent names it.
    private var look: [String: BighelpJSONValue] {
        [
            "mode": .string(settings.appearance.rawValue),
            "color": .string(settings.customBubbleHex.map { "#" + $0 } ?? (settings.bubbleColor ?? .lavender).agentName),
        ]
    }

    private struct Change {
        enum Color { case named(BighelpBubbleColor), custom(String) }
        /// The plugin's bound too: a name or "#rrggbb".
        static let maximumColorLength = 24
        var mode: AppAppearance?
        var color: Color?

        init(_ arguments: [String: BighelpJSONValue]) throws {
            guard !arguments.isEmpty, Set(arguments.keys).isSubset(of: ["mode", "color"]) else {
                throw Failure.invalidArguments
            }
            if let value = arguments["mode"] {
                guard let mode = value.string.flatMap(AppAppearance.init(rawValue:)) else { throw Failure.invalidArguments }
                self.mode = mode
            }
            if let value = arguments["color"] {
                guard let raw = value.string, !raw.isEmpty, raw.count <= Self.maximumColorLength else {
                    throw Failure.invalidArguments
                }
                if raw.hasPrefix("#") {
                    guard let hex = BighelpCustomBubbleColor.validated(raw) else { throw Failure.invalidArguments }
                    color = .custom(hex)
                } else {
                    guard let named = BighelpBubbleColor.allCases.first(where: { $0.agentName == raw.lowercased() }) else {
                        throw Failure.unknownColor
                    }
                    color = .named(named)
                }
            }
        }
    }
}

private extension BighelpBubbleColor {
    /// The name Appearance shows, lowercased ("ink" for the dark gray).
    var agentName: String { name.lowercased() }
}
