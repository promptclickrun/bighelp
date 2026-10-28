import Foundation
import Observation

/// Reads and saves one bot's friendly settings. Hermes owns the values; this keeps a bounded
/// copy for display, writes only the key that changed, and checks the computer kept it.
@MainActor
@Observable
final class AdvancedOptionsStore {
    enum Load: Equatable { case idle, loading, loaded, unavailable }

    private(set) var load: Load = .idle
    private(set) var isSaving = false
    var errorMessage: String?

    @ObservationIgnored private let client: any SimpleBotHostConfiguring
    @ObservationIgnored let profile: String
    @ObservationIgnored let groups: [AdvancedGroup]

    private var config: [String: BighelpJSONValue] = [:]
    private var pending: [String: BighelpJSONValue] = [:]

    init(
        client: any SimpleBotHostConfiguring,
        profile: String,
        groups: [AdvancedGroup] = AdvancedOptionsCatalog.groups
    ) {
        self.client = client
        self.profile = profile
        self.groups = groups
    }

    func refresh() async {
        if load == .idle { load = .loading }
        do {
            config = try await client.read(profile: profile)
            load = .loaded
        } catch {
            if load != .loaded { load = .unavailable }
        }
    }

    /// The value the computer has saved, or nil when it never stored one.
    func currentValue(for option: AdvancedOption) -> BighelpJSONValue? {
        Self.value(at: option.path, in: config)
    }

    func displayedValue(for option: AdvancedOption) -> BighelpJSONValue {
        pending[option.id] ?? currentValue(for: option) ?? option.defaultValue
    }

    func selectedChoice(for option: AdvancedOption) -> AdvancedChoice? {
        guard case .choice(let choices) = option.kind else { return nil }
        let value = displayedValue(for: option)
        return choices.first { $0.matches(value) }
    }

    func isOn(_ option: AdvancedOption) -> Bool {
        AdvancedValue.switchState(displayedValue(for: option))
            ?? AdvancedValue.switchState(option.defaultValue)
            ?? false
    }

    /// Text for a saved value none of the choices describe, so it is shown as it is, not guessed.
    func customDescription(for option: AdvancedOption) -> String? {
        guard case .choice = option.kind,
              selectedChoice(for: option) == nil,
              let value = currentValue(for: option)
        else { return nil }
        return value.displayText
    }

    func set(_ option: AdvancedOption, to value: BighelpJSONValue) async {
        guard load == .loaded, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        pending[option.id] = value
        defer {
            pending[option.id] = nil
            isSaving = false
        }
        do {
            try await client.write(Self.partial(at: option.path, value: value), profile: profile)
            let saved = try await client.read(profile: profile)
            config = saved
            if !Self.kept(value, for: option, in: saved) {
                errorMessage = String(localized: "The computer didn't keep that setting. Try again.")
            }
        } catch {
            errorMessage = String(localized: "The computer didn't save that. Try again in a moment.")
        }
    }

    private static func kept(
        _ value: BighelpJSONValue,
        for option: AdvancedOption,
        in config: [String: BighelpJSONValue]
    ) -> Bool {
        guard let stored = Self.value(at: option.path, in: config) else { return false }
        switch option.kind {
        case .toggle:
            guard let wanted = AdvancedValue.switchState(value),
                  let actual = AdvancedValue.switchState(stored)
            else { return AdvancedValue.same(stored, value) }
            return wanted == actual
        case .choice(let choices):
            if let choice = choices.first(where: { $0.matches(value) }) {
                return choice.matches(stored)
            }
            return AdvancedValue.same(stored, value)
        }
    }

    private static func value(at path: [String], in config: [String: BighelpJSONValue]) -> BighelpJSONValue? {
        var current: BighelpJSONValue = .object(config)
        for key in path {
            guard let next = current.object?[key] else { return nil }
            current = next
        }
        return current
    }

    private static func partial(at path: [String], value: BighelpJSONValue) -> [String: BighelpJSONValue] {
        var node = value
        for key in path.dropFirst().reversed() {
            node = .object([key: node])
        }
        return [path[0]: node]
    }
}
