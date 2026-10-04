import Foundation
import Observation

enum AvatarCatalogFetchResult: Sendable, Equatable {
    case notModified(maxAge: TimeInterval?)
    case fetched(Data, etag: String?, maxAge: TimeInterval?)
}

protocol AvatarCatalogFetching: Sendable {
    func fetch(_ url: URL, etag: String?) async throws -> AvatarCatalogFetchResult
}

/// No cookies, no shared cache, https to the avatar host only (redirects too), and at most 2 MB a file.
struct AvatarCatalogURLSessionTransport: AvatarCatalogFetching {
    func fetch(_ url: URL, etag: String?) async throws -> AvatarCatalogFetchResult {
        guard AvatarCatalogPolicy.isAllowed(url) else { throw URLError(.badURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Sent back exactly as received, weak (W/) or not.
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, AvatarCatalogPolicy.isAllowed(http.url) else {
            throw URLError(.badServerResponse)
        }
        let maxAge = Self.maxAge(http.value(forHTTPHeaderField: "Cache-Control"))
        if http.statusCode == 304 { return .notModified(maxAge: maxAge) }
        guard http.statusCode == 200, http.expectedContentLength <= Int64(AvatarCatalogPolicy.maximumBytes) else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > AvatarCatalogPolicy.maximumBytes { throw URLError(.dataLengthExceedsMaximum) }
        }
        return .fetched(data, etag: http.value(forHTTPHeaderField: "ETag"), maxAge: maxAge)
    }

    static func maxAge(_ header: String?) -> TimeInterval? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "max-age", let value = TimeInterval(pair[1]), value >= 0 { return value }
        }
        return nil
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            AvatarCatalogPolicy.isAllowed(request.url) ? request : nil
        }
    }
}

/// The avatar catalog the picker shows: the last good copy, refreshed when it's due (at most every
/// five minutes, sooner at the next start or expiry). Starts and expiries are applied on the phone,
/// offline too. A failed download never replaces a good copy, and expiry only hides choices: a
/// character someone picked keeps its pack and keeps drawing.
@MainActor
@Observable
final class AvatarCatalogStore {
    static let shared = AvatarCatalogStore.makeLive()

    private(set) var catalog: AvatarCatalog
    /// Moves on at each start or expiry so views re-filter.
    private(set) var now: Date
    private(set) var isRefreshing = false

    @ObservationIgnored private let transport: any AvatarCatalogFetching
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let isEnabled: Bool
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var dueAt: Date?
    @ObservationIgnored private var packLoads: [String: Task<AvatarKit?, Never>] = [:]

    init(transport: any AvatarCatalogFetching, directory: URL?, isEnabled: Bool = true,
         clock: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.directory = directory
        self.isEnabled = isEnabled
        self.clock = clock
        now = clock()
        // The copy that shipped with the app until a download lands; demo mode and tests keep it.
        catalog = (isEnabled ? Self.readCatalog(in: directory) : nil) ?? AvatarCatalog.bundled
        AvatarKitLibrary.shared.directory = directory?.appending(path: "packs", directoryHint: .isDirectory)
    }

    /// Demo fixtures and tests never touch the network.
    static func makeLive() -> AvatarCatalogStore {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        let isOffline = arguments.contains("-use-demo-fixtures") || environment["XCTestConfigurationFilePath"] != nil
        // Application Support, not Caches: a picked character's pack must outlive cache purges.
        return AvatarCatalogStore(
            transport: AvatarCatalogURLSessionTransport(),
            directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appending(path: "AvatarCatalog", directoryHint: .isDirectory),
            isEnabled: !isOffline
        )
    }

    /// Re-reads the clock, so a start or expiry that passed shows without a download.
    func tick() {
        now = clock()
    }

    /// One refresh at a time; callers during it wait for that one.
    func refreshIfNeeded(force: Bool = false) async {
        tick()
        guard isEnabled else { return }
        if let refreshing {
            await refreshing.value
            return
        }
        // `dueAt` already comes before the next start or expiry.
        if !force, let dueAt, now < dueAt { return }
        let task = Task { await refresh() }
        refreshing = task
        isRefreshing = true
        await task.value
        refreshing = nil
        isRefreshing = false
        tick()
    }

    /// While a picker is open: refresh when due and at each start or expiry.
    func keepCurrent() async {
        while !Task.isCancelled {
            await refreshIfNeeded()
            let wake = [dueAt, catalog.nextChange(after: clock())].compactMap { $0 }.min()
                ?? clock().addingTimeInterval(AvatarCatalogPolicy.maximumAge)
            let seconds = min(max(wake.timeIntervalSince(clock()), 1), AvatarCatalogPolicy.maximumAge)
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    private func refresh() async {
        let cached = Self.readCatalog(in: directory) != nil
        let etag = cached ? Self.readETag(in: directory) : nil
        let result = try? await transport.fetch(AvatarCatalogPolicy.discoveryURL, etag: etag)
        let maxAge: TimeInterval?
        switch result {
        case .notModified(let age)?:
            maxAge = age
        case .fetched(let data, let newETag, let age)?:
            maxAge = age
            if let fresh = AvatarCatalog(discovery: data) {
                catalog = fresh
                Self.write(fresh, etag: newETag, in: directory)
            }
        case nil:
            // Try again within a minute, not five.
            dueAt = clock().addingTimeInterval(60)
            return
        }
        var due = clock().addingTimeInterval(min(maxAge ?? AvatarCatalogPolicy.maximumAge, AvatarCatalogPolicy.maximumAge))
        if let next = catalog.nextChange(after: clock()), next < due { due = next }
        dueAt = due
    }

    // MARK: Packs

    /// A character's pack: on the phone already, or downloaded once, size- and hash-checked.
    func pack(for reference: AvatarCatalogReference) async -> AvatarKit? {
        let library = AvatarKitLibrary.shared
        if let kit = library.kit(sha256: reference.kitSHA256) { return kit }
        // Keep a downloaded copy even when the app has one, so the saved look survives app updates.
        guard isEnabled else { return nil }
        if let loading = packLoads[reference.kitSHA256] { return await loading.value }
        let transport = transport
        let task = Task<AvatarKit?, Never> {
            guard case .fetched(let data, _, _)? = try? await transport.fetch(reference.kitURL, etag: nil),
                  AvatarKitPackValidator.sha256(data) == reference.kitSHA256,
                  let kit = AvatarKitPackValidator.decode(data),
                  kit.character(reference.id) != nil else { return nil }
            library.store(kit, data: data, sha256: reference.kitSHA256)
            return kit
        }
        packLoads[reference.kitSHA256] = task
        let kit = await task.value
        packLoads[reference.kitSHA256] = nil
        return kit
    }

    func pack(for entry: AvatarCatalogEntry) async -> AvatarKit? {
        guard entry.kitBytes <= AvatarCatalogPolicy.maximumBytes else { return nil }
        return await pack(for: AvatarCatalogReference(entry))
    }

    // MARK: Cache

    private struct Saved: Codable {
        let catalog: AvatarCatalog
    }

    private static func readCatalog(in directory: URL?) -> AvatarCatalog? {
        guard let url = directory?.appending(path: "catalog.json"),
              let data = try? Data(contentsOf: url), data.count <= AvatarCatalogPolicy.maximumBytes,
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        return saved.catalog
    }

    private static func readETag(in directory: URL?) -> String? {
        guard let url = directory?.appending(path: "catalog.etag"),
              let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty, text.utf8.count <= 256 else { return nil }
        return text
    }

    private static func write(_ catalog: AvatarCatalog, etag: String?, in directory: URL?) {
        guard let directory, let data = try? JSONEncoder().encode(Saved(catalog: catalog)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: "catalog.json"), options: .atomic)
        let etagURL = directory.appending(path: "catalog.etag")
        if let etag, etag.utf8.count <= 256 {
            try? Data(etag.utf8).write(to: etagURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: etagURL)
        }
    }
}

/// Packs on the phone, by hash, decoded once. Read while drawing, so it answers synchronously.
final class AvatarKitLibrary: @unchecked Sendable {
    static let shared = AvatarKitLibrary()

    private let lock = NSLock()
    private var kits: [String: AvatarKit] = [:]
    private var missing: Set<String> = []
    private var _directory: URL?

    var directory: URL? {
        get { lock.withLock { _directory } }
        set { lock.withLock { _directory = newValue; missing = [] } }
    }

    /// Catalog characters shipped with the app: what draws until a pack downloads, and offline.
    static let bundledKit: AvatarKit? = {
        guard let url = Bundle.main.url(forResource: "AvatarCatalogKit", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return AvatarKitPackValidator.decode(data)
    }()

    /// The pack for a picked character: its own downloaded pack, else the shipped copy of it.
    func kit(for reference: AvatarCatalogReference) -> AvatarKit? {
        if let kit = kit(sha256: reference.kitSHA256), kit.character(reference.id) != nil { return kit }
        if let kit = Self.bundledKit, kit.character(reference.id) != nil { return kit }
        return nil
    }

    func kit(sha256: String) -> AvatarKit? {
        let sha = sha256.lowercased()
        let (cached, directory, isMissing) = lock.withLock { (kits[sha], _directory, missing.contains(sha)) }
        if let cached { return cached }
        guard !isMissing, AvatarCatalog.isSHA256(sha), let directory else { return nil }
        guard let data = try? Data(contentsOf: directory.appending(path: sha + ".json")),
              AvatarKitPackValidator.sha256(data) == sha, let kit = AvatarKitPackValidator.decode(data) else {
            lock.withLock { _ = missing.insert(sha) }
            return nil
        }
        lock.withLock { kits[sha] = kit }
        return kit
    }

    func store(_ kit: AvatarKit, data: Data, sha256: String) {
        let sha = sha256.lowercased()
        let directory = lock.withLock { () -> URL? in
            kits[sha] = kit
            missing.remove(sha)
            return _directory
        }
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: sha + ".json"), options: .atomic)
    }

    /// Tests and previews: a pack known only in memory.
    func insert(_ kit: AvatarKit, sha256: String) {
        lock.withLock { kits[sha256.lowercased()] = kit }
    }
}
