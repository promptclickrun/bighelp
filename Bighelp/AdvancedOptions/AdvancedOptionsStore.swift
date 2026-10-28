import Foundation
import Observation

/// Reads and saves one bot's Advanced Options. Hermes owns the values; this keeps a bounded
/// copy for display, writes only the key that changed, and checks the computer kept it.
@MainActor
@Observable
final class AdvancedOptionsStore {
    enum Load: Equatable { case idle, loading, loaded, unavailable }

    /// What the page says when a read or a save didn't go as planned.
    enum Message: Equatable {
        /// The save never reached the computer.
        case notSaved
        /// The computer answered the save but kept something else.
        case notKept
        /// The save went out, but reading it back failed.
        case sentUnchecked
        /// A fresh read failed; the page shows what it read last.
        case outOfDate

        var text: String {
            switch self {
            case .notSaved: String(localized: "The computer didn't save that. Try again in a moment.")
            case .notKept: String(localized: "The computer didn't keep that setting. Try again.")
            case .sentUnchecked: String(localized: "Sent to your computer, but bighelp couldn't check it was kept.")
            case .outOfDate: String(localized: "Couldn't reach your computer. These may be out of date.")
            }
        }

        /// Red for a change that didn't happen; plain for one that may have.
        var isProblem: Bool { self == .notSaved || self == .notKept }
    }

    /// A pick that waits for a yes before it's saved (turning approvals off).
    struct PendingChoice: Equatable, Identifiable {
        let option: AdvancedOption
        let choice: AdvancedChoice
        var id: String { option.id }
    }

    private(set) var load: Load = .idle
    private(set) var isSaving = false
    private(set) var message: Message?
    private(set) var pendingChoice: PendingChoice?

    @ObservationIgnored private let client: any SimpleBotHostConfiguring
    @ObservationIgnored let profile: String
    @ObservationIgnored let groups: [AdvancedGroup]

    private var config: [String: BighelpJSONValue] = [:]
    /// The value being saved, shown at once.
    private var saving: [String: BighelpJSONValue] = [:]
    /// Bumped by every read and save: only the newest one's read may change what's shown.
    @ObservationIgnored private var readGeneration = 0

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
        // A save reads back what the computer kept; a read started during it could be older.
        guard !isSaving else { return }
        if load != .loaded { load = .loading }
        readGeneration += 1
        let generation = readGeneration
        do {
            let saved = try await client.read(profile: profile)
            guard generation == readGeneration else { return }
            config = saved
            load = .loaded
            // What it read is the truth now; a save that didn't happen still says so.
            if message?.isProblem == false { message = nil }
        } catch {
            guard generation == readGeneration else { return }
            if load == .loaded { message = .outOfDate } else { load = .unavailable }
        }
    }

    // MARK: Reading

    /// The value the computer has saved, or nil when it never stored one.
    func currentValue(for option: AdvancedOption) -> BighelpJSONValue? {
        Self.value(at: option.path, in: config)
    }

    func displayedValue(for option: AdvancedOption) -> BighelpJSONValue {
        saving[option.id] ?? currentValue(for: option) ?? option.defaultValue
    }

    /// The answer shown as picked: the one naming the value, else the one Hermes falls back to.
    func selectedChoice(for option: AdvancedOption) -> AdvancedChoice? {
        guard case .choice(let choices, let unknownMeans) = option.kind else { return nil }
        let value = displayedValue(for: option)
        if let named = choices.first(where: { $0.matches(value) }) { return named }
        return unknownMeans.flatMap { fallback in choices.first { $0.matches(fallback) } }
    }

    func isOn(_ option: AdvancedOption) -> Bool {
        guard case .toggle(let toggle) = option.kind else { return false }
        return toggle.isOn(displayedValue(for: option)) ?? toggle.isOn(option.defaultValue) ?? false
    }

    /// A wait in seconds, however the computer wrote the number.
    func seconds(for option: AdvancedOption) -> Int? {
        let value = displayedValue(for: option)
        // Bounded: `Int(_:)` traps on a number past its range.
        if let number = value.number { return abs(number) < 1e9 ? Int(number) : nil }
        return value.string.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    func text(for option: AdvancedOption) -> String {
        displayedValue(for: option).string ?? ""
    }

    /// The value at a row's end: a choice's name, a wait in minutes, or a saved value no choice
    /// names, shown as it is rather than guessed.
    func valueText(for option: AdvancedOption) -> String {
        switch option.kind {
        case .choice:
            return selectedChoice(for: option)?.title ?? displayedValue(for: option).displayText ?? ""
        case .duration:
            return seconds(for: option).map(AdvancedValue.duration) ?? displayedValue(for: option).displayText ?? ""
        case .text:
            return text(for: option).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(localized: "None") : String(localized: "Set")
        case .toggle:
            return isOn(option) ? String(localized: "On") : String(localized: "Off")
        }
    }

    func isShown(_ option: AdvancedOption) -> Bool {
        switch option.visibility {
        case .always:
            return true
        case .whileOn:
            // What the computer has, not the pick being saved: the row stays until it's off for good.
            guard case .toggle(let toggle) = option.kind, let stored = currentValue(for: option) else { return false }
            return toggle.isOn(stored) == true
        case .when(let path, let value):
            guard let other = groups.flatMap(\.options).first(where: { $0.path == path }) else { return false }
            if let choice = selectedChoice(for: other) { return choice.matches(value) }
            return AdvancedValue.same(displayedValue(for: other), value)
        }
    }

    // MARK: Saving

    /// A pick from a menu: saved at once, or held for a yes when it takes a safety net away.
    func choose(_ choice: AdvancedChoice, for option: AdvancedOption) async {
        guard selectedChoice(for: option)?.id != choice.id else { return }
        if choice.confirmation != nil {
            pendingChoice = PendingChoice(option: option, choice: choice)
            return
        }
        await set(option, to: choice.value)
    }

    /// The yes. It takes the pick itself: closing the question may clear `pendingChoice` first.
    func confirm(_ pending: PendingChoice) async {
        pendingChoice = nil
        await set(pending.option, to: pending.choice.value)
    }

    func cancelPendingChoice() {
        pendingChoice = nil
    }

    func setOn(_ option: AdvancedOption, _ on: Bool) async {
        guard case .toggle(let toggle) = option.kind else { return }
        await set(option, to: on ? toggle.on : toggle.off)
    }

    func setSeconds(_ option: AdvancedOption, _ seconds: Int) async {
        guard seconds != self.seconds(for: option) else { return }
        await set(option, to: .integer(seconds))
    }

    func setText(_ option: AdvancedOption, _ text: String) async {
        await set(option, to: .string(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func set(_ option: AdvancedOption, to value: BighelpJSONValue) async {
        guard load == .loaded, !isSaving else { return }
        isSaving = true
        message = nil
        saving[option.id] = value
        // A read already on its way started before this save; its answer could be older.
        readGeneration += 1
        let generation = readGeneration
        defer {
            saving[option.id] = nil
            isSaving = false
        }
        let partial = Self.partial(at: option.path, value: value)
        do {
            try await client.write(partial, profile: profile)
        } catch {
            message = .notSaved
            return
        }
        do {
            let saved = try await client.read(profile: profile)
            guard generation == readGeneration else { return }
            config = saved
            if !Self.kept(value, for: option, in: saved) { message = .notKept }
        } catch {
            // It went out: show it as Hermes would have merged it, and say it wasn't checked.
            config = SimpleBotDemoConfiguration.merge(config, partial)
            message = .sentUnchecked
        }
    }

    private static func kept(
        _ value: BighelpJSONValue,
        for option: AdvancedOption,
        in config: [String: BighelpJSONValue]
    ) -> Bool {
        let stored = Self.value(at: option.path, in: config)
        switch option.kind {
        case .toggle(let toggle):
            guard let stored else { return false }
            return toggle.isOn(stored) == toggle.isOn(value)
        case .choice(let choices, _):
            guard let stored else { return false }
            if let choice = choices.first(where: { $0.matches(value) }) { return choice.matches(stored) }
            return AdvancedValue.same(stored, value)
        case .duration:
            return stored.map { AdvancedValue.same($0, value) } ?? false
        case .text:
            let trimmed = { (text: String?) in (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            return trimmed(stored?.string) == trimmed(value.string)
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
