import Foundation
import os

/// A computer the app can reach now: the phone's own name for it (its host ID) and its routes.
struct AppStateComputer {
    let hostKey: String
    let client: any AppStateClient
}

/// Keeps app state the same on every computer the person uses, and on this phone. Each key's newest
/// revision wins wherever it is; a change made here is a list of patches, written as one revision
/// past the newest seen anywhere, to every computer, on top of what each one has. A computer that
/// another device wrote to first refuses (409): the patches go on top of its value and the write
/// goes again. A computer that is behind gets the newest. The values and this phone's unsent
/// changes are kept in a file, so launch and time away from the computers never wait.
///
/// Each value lists the computers it covers (`computers`). The first time a computer is reached,
/// what this phone has for it is added (`join`); a computer already listed keeps what it has, so a
/// fresh install takes the computer's choices instead of sending empty ones.
@MainActor
final class AppStateSync {
    struct Saved: Codable, Equatable {
        var entries: [String: AppStateWire.Entry] = [:]
        /// Changes made here and not yet taken by any computer, by key.
        var pending: [String: [AppStatePatch]] = [:]
        /// Each host's computer ID, by the phone's own host ID.
        var computers: [String: String] = [:]
    }

    struct Outcome: Equatable {
        /// Hosts that answered.
        var reached: [String] = []
        /// Hosts whose plugin doesn't have the feature.
        var lacking: [String] = []
    }

    /// What `join` adds for computers a value doesn't list yet: the key, its value (nil when no
    /// computer has it), and those computers' IDs.
    typealias Join = @MainActor (_ key: String, _ value: BighelpJSONValue?, _ computers: [String]) -> [AppStatePatch]

    nonisolated static let computersField = "computers"
    /// A conflict means another device wrote between the read and the write; a few tries settle it.
    static let maximumRounds = 3

    let keys: [String]
    let device: String
    private(set) var saved: Saved
    private let file: URL?
    private let person: @MainActor () -> String?
    /// Keys a computer refused for what's in them, until they change here again.
    private var refused: Set<String> = []
    private static let log = Logger(subsystem: "app.loopdy.mobile", category: "AppState")

    init(keys: [String], device: String, file: URL?, person: @escaping @MainActor () -> String?) {
        self.keys = keys
        self.device = device
        self.file = file
        self.person = person
        saved = file.flatMap(Self.load) ?? Saved()
    }

    /// The newest value this phone knows, with its own unsent changes on top.
    func value(_ key: String) -> BighelpJSONValue? {
        let base = saved.entries[key]?.value
        guard let patches = saved.pending[key], !patches.isEmpty else { return base }
        return patches.reduce(base) { $1.applied(to: $0) }
    }

    func computerID(forHost hostKey: String) -> String? { saved.computers[hostKey] }

    /// A change made here: shown at once, sent with the next `sync`.
    func change(_ key: String, _ patches: [AppStatePatch]) {
        guard keys.contains(key), !patches.isEmpty else { return }
        refused.remove(key)
        var pending = saved.pending[key] ?? []
        pending.append(contentsOf: patches)
        // Far more than months away from every computer makes; past it the oldest go.
        saved.pending[key] = Array(pending.suffix(Self.maximumPending))
        save()
    }

    /// Reads every computer, keeps each key's newest revision, writes it to the computers behind,
    /// and adds this phone's part for computers a value doesn't list yet.
    @discardableResult
    func sync(_ computers: [AppStateComputer], join: Join) async -> Outcome {
        guard let person = person(), AppStateWire.isID(person) else { return Outcome() }
        var outcome = Outcome()
        // What this phone last wrote for each key: on a tie with another device's write, theirs is
        // read and this phone's changes go on top of it.
        var written: [String: AppStateWire.Entry] = [:]
        for _ in 0..<Self.maximumRounds {
            outcome = Outcome()
            var answers: [(computer: AppStateComputer, answer: AppStateWire.Answer)] = []
            for computer in computers {
                do {
                    let answer = try await computer.client.read(person: person, keys: keys)
                    outcome.reached.append(computer.hostKey)
                    saved.computers[computer.hostKey] = answer.computerID
                    // A computer set up twice on this phone is written once.
                    if !answers.contains(where: { $0.answer.computerID == answer.computerID }) {
                        answers.append((computer, answer))
                    }
                } catch AppStateError.needsPluginUpdate {
                    outcome.lacking.append(computer.hostKey)
                } catch {
                    Self.log.info("A computer's app state couldn't be read: \(String(describing: error), privacy: .public)")
                }
            }
            guard !answers.isEmpty else {
                save()
                return outcome
            }
            let reached = answers.map(\.answer.computerID)

            var targets: [String: AppStateWire.Entry] = [:]
            var newest: [String: AppStateWire.Entry] = [:]
            var sending: [String: Int] = [:]
            for key in keys {
                var best = saved.entries[key]
                var fromComputer = false
                for (_, answer) in answers {
                    guard let entry = answer.entries[key] else { continue }
                    let tie = entry.revision == best?.revision
                    if entry.revision > best?.revision ?? 0 || (tie && (!fromComputer || best == written[key])) {
                        best = entry
                        fromComputer = true
                    }
                }
                if let best { newest[key] = best }
                let pending = refused.contains(key) ? [] : saved.pending[key] ?? []
                var value = pending.reduce(best?.value) { $1.applied(to: $0) }
                let listed = Self.listed(value)
                let newcomers = reached.filter { !listed.contains($0) }
                if !newcomers.isEmpty, !refused.contains(key) {
                    value = join(key, value, newcomers).reduce(value) { $1.applied(to: $0) }
                    value = AppStatePatch(path: [Self.computersField],
                                          value: .array((listed + newcomers).prefix(64).map(BighelpJSONValue.string)))
                        .applied(to: value)
                }
                guard let value else { continue }
                var revision = best?.revision ?? 0
                if value != best?.value { revision += 1 }
                let target = AppStateWire.Entry(value: value, revision: revision)
                // Every computer behind takes it; one that holds something else at this revision needs a higher one.
                let highest = answers.compactMap { pair -> Int? in
                    guard let entry = pair.answer.entries[key], entry != target else { return nil }
                    return entry.revision
                }.max() ?? 0
                if highest >= revision { revision = highest + 1 }
                guard revision <= AppStateWire.maximumRevision else { continue }
                targets[key] = AppStateWire.Entry(value: value, revision: revision)
                sending[key] = pending.count
            }

            var took: [String: Int] = [:]
            var conflicts: Set<String> = []
            for (computer, answer) in answers {
                var writes: [String: AppStateWire.Write] = [:]
                for (key, target) in targets {
                    if answer.entries[key] == target {
                        took[key, default: 0] += 1
                        continue
                    }
                    guard AppStateWire.encodedSize(target.value) <= AppStateWire.maximumValueBytes else {
                        refused.insert(key)
                        Self.log.error("App state \(key, privacy: .public) is over the computer's limit; it stays on this phone")
                        continue
                    }
                    writes[key] = AppStateWire.Write(value: target.value, revision: target.revision,
                                                     baseRevision: answer.entries[key]?.revision ?? 0)
                }
                guard !writes.isEmpty else { continue }
                do {
                    _ = try await computer.client.write(person: person, device: device, writes: writes)
                    for key in writes.keys { took[key, default: 0] += 1 }
                } catch AppStateError.conflict {
                    conflicts.formUnion(writes.keys)
                } catch AppStateError.refused(let code) {
                    refused.formUnion(writes.keys)
                    Self.log.error("A computer refused app state (\(code, privacy: .public)); it stays on this phone")
                } catch {
                    Self.log.info("A computer's app state couldn't be written: \(String(describing: error), privacy: .public)")
                }
            }

            for (key, target) in targets {
                guard took[key] != nil else {
                    // Nobody took it: the newest seen, with this phone's changes kept for the next try.
                    if let seen = newest[key] { saved.entries[key] = seen }
                    continue
                }
                saved.entries[key] = target
                written[key] = target
                // Changes another device's write got in the way of go again on top of its value.
                guard !conflicts.contains(key), let count = sending[key], count > 0 else { continue }
                let rest = Array((saved.pending[key] ?? []).dropFirst(count))
                saved.pending[key] = rest.isEmpty ? nil : rest
            }
            save()
            if conflicts.isEmpty { return outcome }
        }
        return outcome
    }

    static let maximumPending = 1_000

    /// The computers a value covers.
    static func listed(_ value: BighelpJSONValue?) -> [String] {
        var seen = Set<String>()
        return (value?.object?[computersField]?.array ?? []).compactMap(\.string).filter { seen.insert($0).inserted }
    }

    private static func load(_ file: URL) -> Saved? {
        guard let data = try? Data(contentsOf: file), data.count <= 4 * 1_048_576 else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    /// Readable after the first unlock, like the settings it mirrors: wakes in the background sync too.
    private func save() {
        guard let file else { return }
        let protector = BighelpLocalFileProtector()
        try? protector.prepareDirectory(file.deletingLastPathComponent(), protection: .backgroundCompatible,
                                        fileManager: .default)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: file, options: [.atomic, BighelpLocalFileProtector.writingOptions(for: .backgroundCompatible)])
    }
}
