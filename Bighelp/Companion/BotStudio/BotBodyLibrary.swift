import Foundation
import Observation

/// Bot Studio's bodies: avatars.bighelp.app's catalog v2 (`/v2/bodies.json`), with the copy the app
/// ships (`BotBodies.json`) until the first download lands and whenever the host can't be reached.
struct BotBodyCatalog: Equatable, Sendable {
    struct BodySet: Codable, Equatable, Hashable, Sendable, Identifiable {
        let id: String
        let name: String
        let category: String
        let startsAt: Date?
        let expiresAt: Date?

        func isAvailable(at now: Date) -> Bool {
            (startsAt.map { now >= $0 } ?? true) && (expiresAt.map { now < $0 } ?? true)
        }

        init(id: String, name: String, category: String, startsAt: Date? = nil, expiresAt: Date? = nil) {
            self.id = id
            self.name = name
            self.category = category
            self.startsAt = startsAt
            self.expiresAt = expiresAt
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            category = (try? container.decodeIfPresent(String.self, forKey: .category)).flatMap { $0 } ?? "bighelp"
            startsAt = BotBodyCatalog.date((try? container.decodeIfPresent(String.self, forKey: .startsAt)).flatMap { $0 })
            expiresAt = BotBodyCatalog.date((try? container.decodeIfPresent(String.self, forKey: .expiresAt)).flatMap { $0 })
        }
    }

    var sets: [BodySet] = []
    var bodies: [BotBody] = []

    static let empty = BotBodyCatalog()

    static let bundled: BotBodyCatalog = {
        guard let url = Bundle.main.url(forResource: "BotBodies", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return .empty }
        return decode(data) ?? .empty
    }()

    /// The catalog, or nil when it doesn't read. A body that doesn't read is left out, never the catalog.
    static func decode(_ data: Data) -> BotBodyCatalog? {
        guard data.count <= AvatarCatalogPolicy.maximumBytes,
              let root = try? JSONDecoder().decode(Root.self, from: data), root.schemaVersion == 2 else { return nil }
        let bodies = root.bodies.compactMap(\.body)
        guard !bodies.isEmpty else { return nil }
        return BotBodyCatalog(sets: root.sets.compactMap(\.set), bodies: bodies)
    }

    /// The sets on offer now, each with its bodies, in the catalog's order.
    func available(at now: Date) -> [(set: BodySet, bodies: [BotBody])] {
        let grouped = Dictionary(grouping: bodies, by: { $0.set ?? "" })
        return sets.filter { $0.isAvailable(at: now) }.compactMap { set in
            grouped[set.id].map { (set, $0) }
        }
    }

    func body(id: String) -> BotBody? { bodies.first { $0.id == id } }

    private struct Root: Decodable {
        let schemaVersion: Int
        let sets: [Failable<BodySet>]
        let bodies: [Failable<BotBody>]
    }

    private struct Failable<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
        var set: Value? { value }
        var body: Value? { value }
    }

    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return try? Date(text, strategy: .iso8601)
    }
}

/// Keeps the catalog current: the downloaded copy when there is one, else the bundled one.
/// Demo fixtures and tests never download.
@MainActor
@Observable
final class BotBodyLibrary {
    static let shared = BotBodyLibrary.makeLive()
    static let url = URL(string: "https://avatars.bighelp.app/v2/bodies.json")!

    private(set) var catalog: BotBodyCatalog
    private let transport: any AvatarCatalogFetching
    private let directory: URL?
    private let isEnabled: Bool
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var checkedAt: Date?
    @ObservationIgnored private var refreshing: Task<Void, Never>?

    init(transport: any AvatarCatalogFetching, directory: URL?, isEnabled: Bool) {
        self.transport = transport
        self.directory = directory
        self.isEnabled = isEnabled
        let saved = isEnabled ? directory.flatMap { try? Data(contentsOf: $0.appending(path: "bodies.json")) } : nil
        catalog = saved.flatMap(BotBodyCatalog.decode) ?? .bundled
    }

    static func makeLive() -> BotBodyLibrary {
        let arguments = ProcessInfo.processInfo.arguments
        let isOffline = arguments.contains("-use-demo-fixtures")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return BotBodyLibrary(
            transport: AvatarCatalogURLSessionTransport(),
            directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appending(path: "AvatarCatalog", directoryHint: .isDirectory),
            isEnabled: !isOffline)
    }

    /// At most one download every few minutes; callers during one wait for it.
    func refreshIfNeeded() async {
        guard isEnabled else { return }
        if let refreshing { return await refreshing.value }
        if let checkedAt, Date.now.timeIntervalSince(checkedAt) < AvatarCatalogPolicy.maximumAge { return }
        let task = Task { await refresh() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func refresh() async {
        checkedAt = .now
        guard case .fetched(let data, let tag, _) = try? await transport.fetch(Self.url, etag: etag),
              let fresh = BotBodyCatalog.decode(data) else { return }
        etag = tag
        if fresh != catalog { catalog = fresh }
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: "bodies.json"), options: .atomic)
    }
}
