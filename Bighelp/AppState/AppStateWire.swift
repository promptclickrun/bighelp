import Foundation

/// The app's own choices kept for each person on their computers by the bighelp plugin
/// (`native-app-state-v1`, bighelp-plugin docs/APP_STATE.md), so a reinstall or another device gets
/// them back. The plugin keeps each key with a revision and doesn't read the values: the app owns
/// them and their shapes. Answers are read leniently: an entry that doesn't read is left out.
enum AppStateWire {
    static let feature = "native-app-state-v1"
    /// The plugin's limits.
    static let maximumValueBytes = 65_536
    static let maximumRevision = 9_007_199_254_740_991
    static let maximumKeys = 24

    /// One stored key. A nil `value` was deleted (JSON null) and keeps its revision.
    struct Entry: Codable, Equatable, Sendable {
        var value: BighelpJSONValue?
        var revision: Int
    }

    /// What a computer answered: its own ID, made once and never changed, and the person's keys.
    struct Answer: Equatable, Sendable {
        let computerID: String
        let entries: [String: Entry]
    }

    /// One key's new revision, built on the revision that computer had (`baseRevision`, 0 for none).
    struct Write: Equatable, Sendable {
        let value: BighelpJSONValue?
        let revision: Int
        let baseRevision: Int
    }

    /// A `read` or `write` answer. Without a computer ID nothing can be named on it, so that's an error.
    static func answer(_ json: [String: BighelpJSONValue]) throws -> Answer {
        guard let computer = json["computerId"]?.string, isID(computer) else { throw WorkspaceClientError.invalidResponse }
        var entries: [String: Entry] = [:]
        for (key, row) in (json["keys"]?.object ?? [:]).prefix(maximumKeys * 2) {
            guard isKey(key), let fields = row.object, let revision = revision(fields["revision"]) else { continue }
            let value = fields["value"]
            entries[key] = Entry(value: value == .null ? nil : value, revision: revision)
        }
        return Answer(computerID: computer, entries: entries)
    }

    static func readPayload(person: String, keys: [String]) -> [String: BighelpJSONValue] {
        ["person": .string(person), "keys": .array(keys.map(BighelpJSONValue.string))]
    }

    static func writePayload(person: String, device: String, writes: [String: Write]) -> [String: BighelpJSONValue] {
        ["person": .string(person), "device": .string(device),
         "keys": .object(writes.mapValues { write in
             .object(["value": write.value ?? .null, "revision": .integer(write.revision),
                      "baseRevision": .integer(write.baseRevision)])
         })]
    }

    /// People, devices and computers are lowercase UUIDs.
    static func isID(_ value: String) -> Bool {
        value.utf8.count == 36 && value == value.lowercased() && UUID(uuidString: value) != nil
    }

    /// The plugin's key names: `^[a-z][a-z0-9]*([.-][a-z0-9]+){0,5}$`, at most 64 characters.
    static func isKey(_ value: String) -> Bool {
        value.utf8.count <= 64
            && value.range(of: "^[a-z][a-z0-9]*([.-][a-z0-9]+){0,5}$", options: .regularExpression) != nil
    }

    /// The compact JSON size the plugin counts against `maximumValueBytes`.
    static func encodedSize(_ value: BighelpJSONValue?) -> Int {
        (try? JSONEncoder().encode(value ?? .null).count) ?? .max
    }

    private static func revision(_ value: BighelpJSONValue?) -> Int? {
        let number: Int? = switch value {
        case .integer(let integer)?: integer
        case .number(let double)? where double.rounded() == double && abs(double) <= Double(maximumRevision): Int(double)
        default: nil
        }
        guard let number, (1...maximumRevision).contains(number) else { return nil }
        return number
    }
}

/// One change to a part of a key's value: `value` set at `path` (nil removes it). Changes are kept as
/// these, not as whole values, so a change made on this device goes on top of whatever another device
/// saved meanwhile.
struct AppStatePatch: Codable, Equatable, Sendable {
    var path: [String]
    var value: BighelpJSONValue?
    /// The fields this app writes in an object `value`, or in each object of a list (matched by its
    /// `id`). Any other field already there stays: a newer app may have added it.
    var fields: [String]? = nil

    func applied(to root: BighelpJSONValue?) -> BighelpJSONValue {
        var object = root?.object ?? [:]
        Self.set(&object, path[...], self)
        return .object(object)
    }

    private static func set(_ object: inout [String: BighelpJSONValue], _ path: ArraySlice<String>,
                            _ patch: AppStatePatch) {
        guard let first = path.first else { return }
        if path.count == 1 {
            object[first] = merged(object[first], patch.value, fields: patch.fields)
            return
        }
        var child = object[first]?.object ?? [:]
        set(&child, path.dropFirst(), patch)
        object[first] = child.isEmpty ? nil : .object(child)
    }

    private static func merged(_ old: BighelpJSONValue?, _ new: BighelpJSONValue?,
                               fields: [String]?) -> BighelpJSONValue? {
        guard let fields else { return new }
        let known = Set(fields)
        func keep(_ old: [String: BighelpJSONValue]?, _ new: [String: BighelpJSONValue]?) -> [String: BighelpJSONValue] {
            (old ?? [:]).filter { !known.contains($0.key) }.merging(new ?? [:]) { _, new in new }
        }
        switch (old, new) {
        case (.object(let old)?, .object(let new)?):
            return .object(keep(old, new))
        case (.object(let old)?, nil):
            let rest = keep(old, nil)
            return rest.isEmpty ? nil : .object(rest)
        case (.array(let old)?, .array(let new)?):
            var earlier: [String: [String: BighelpJSONValue]] = [:]
            for item in old {
                if let row = item.object, let id = row["id"]?.string, earlier[id] == nil { earlier[id] = row }
            }
            return .array(new.map { item in
                guard let row = item.object, let id = row["id"]?.string else { return item }
                return .object(keep(earlier[id], row))
            })
        default:
            return new
        }
    }
}

/// Where a value can change on its own, so a local change becomes the smallest patches: a whole
/// leaf, each entry of a map, or each named field of an object.
indirect enum AppStateShape: Sendable {
    case leaf(fields: [String]? = nil)
    case map(AppStateShape)
    case object([String: AppStateShape])

    func patches(from old: BighelpJSONValue?, to new: BighelpJSONValue?, path: [String] = []) -> [AppStatePatch] {
        switch self {
        case .leaf(let fields):
            return Self.present(old) == Self.present(new) ? [] : [AppStatePatch(path: path, value: Self.present(new), fields: fields)]
        case .map(let child):
            let keys = Set((old?.object ?? [:]).keys).union((new?.object ?? [:]).keys).sorted()
            return keys.flatMap { child.patches(from: old?.object?[$0], to: new?.object?[$0], path: path + [$0]) }
        case .object(let children):
            return children.keys.sorted().flatMap { key in
                children[key]!.patches(from: old?.object?[key], to: new?.object?[key], path: path + [key])
            }
        }
    }

    /// Absent, null and empty mean the same: nothing chosen.
    private static func present(_ value: BighelpJSONValue?) -> BighelpJSONValue? {
        switch value {
        case nil, .null?: nil
        case .object(let object)? where object.isEmpty: nil
        case .array(let array)? where array.isEmpty: nil
        default: value
        }
    }
}
