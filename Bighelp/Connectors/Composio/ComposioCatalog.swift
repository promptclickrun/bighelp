import Foundation

/// Composio's apps by category, from bighelp's catalog service (`services/catalog`,
/// `GET /v1/composio/catalog.json`). The person's own Composio sign-in can't read
/// Composio's catalog, so the service reads it with bighelp's key: app names,
/// categories and logos only, never anyone's connections.
struct ComposioCatalog: Equatable, Sendable {
    struct Category: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
    }

    struct Toolkit: Identifiable, Equatable, Sendable {
        let slug: String
        let name: String
        let summary: String
        let logoURL: URL?
        let categories: [String]
        /// Works without an account, so there's nothing to connect.
        let noAuth: Bool

        var id: String { slug }
    }

    static let url = URL(string: "https://catalog.bighelp.app/v1/composio/catalog.json")!
    static let maximumBytes = 4_194_304

    let revision: String
    let categories: [Category]
    let toolkits: [Toolkit]

    func toolkits(in category: String) -> [Toolkit] { toolkits.filter { $0.categories.contains(category) } }

    func toolkit(_ slug: String) -> Toolkit? { toolkits.first { $0.slug == slug } }

    /// Names and descriptions that match, in the catalog's order (most used first).
    func search(_ text: String) -> [Toolkit] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return toolkits.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.slug.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
        }
    }

    /// The service's document. One bad app drops that app, not the catalog.
    static func decode(_ data: Data) throws -> ComposioCatalog {
        guard data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["schemaVersion"] as? NSNumber)?.intValue == 1,
              let revision = object["revision"] as? String, revision.utf8.count <= 128,
              let rawCategories = object["categories"] as? [[String: Any]],
              let rawToolkits = object["toolkits"] as? [[String: Any]] else { throw ComposioError.invalidResponse }
        let categories = rawCategories.prefix(200).compactMap { row -> Category? in
            guard let id = row["id"] as? String, isCategoryID(id),
                  let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  (1...60).contains(name.count) else { return nil }
            return Category(id: id, name: name)
        }
        let known = Set(categories.map(\.id))
        var seen = Set<String>()
        let toolkits = rawToolkits.prefix(4_000).compactMap { row -> Toolkit? in
            guard let slug = row["slug"] as? String, ComposioConnectClient.isSlug(slug), seen.insert(slug).inserted,
                  let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  (1...80).contains(name.count) else { return nil }
            let logo = (row["logo"] as? String).flatMap { text -> URL? in
                guard text.utf8.count <= 512, let url = URL(string: text), url.scheme == "https",
                      url.host != nil, url.user == nil, url.password == nil else { return nil }
                return url
            }
            let summary = (row["description"] as? String).map { String($0.prefix(280)) } ?? ""
            let tags = (row["categories"] as? [String] ?? []).filter(known.contains).prefix(8)
            return Toolkit(slug: slug, name: name, summary: summary, logoURL: logo, categories: Array(tags),
                           noAuth: row["noAuth"] as? Bool ?? false)
        }
        guard !toolkits.isEmpty else { throw ComposioError.invalidResponse }
        let used = Set(toolkits.flatMap(\.categories))
        return ComposioCatalog(revision: revision, categories: categories.filter { used.contains($0.id) }, toolkits: toolkits)
    }

    private static func isCategoryID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 48
            && value.utf8.allSatisfy { (0x61...0x7a).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2d }
    }
}

/// Reads the catalog. The last good copy stays on the device, so the list shows at once and
/// survives a service that's down.
@MainActor
protocol ComposioCatalogLoading: AnyObject {
    func cached() -> ComposioCatalog?
    func refresh() async throws -> ComposioCatalog
}

@MainActor
final class ComposioCatalogStore: ComposioCatalogLoading {
    private let transport: any TemplateCatalogFetching
    private let directory: URL

    init(transport: any TemplateCatalogFetching = ComposioCatalogTransport(),
         directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
             .appendingPathComponent("ComposioCatalog", isDirectory: true)) {
        self.transport = transport
        self.directory = directory
    }

    private var file: URL { directory.appendingPathComponent("catalog.json") }
    private var etagFile: URL { directory.appendingPathComponent("catalog.etag") }

    func cached() -> ComposioCatalog? {
        (try? Data(contentsOf: file)).flatMap { try? ComposioCatalog.decode($0) }
    }

    func refresh() async throws -> ComposioCatalog {
        let current = cached()
        let etag = current == nil ? nil : (try? String(contentsOf: etagFile, encoding: .utf8))
        switch try await transport.fetch(ComposioCatalog.url, etag: etag) {
        case .notModified:
            guard let current else { throw ComposioError.unavailable }
            return current
        case .fetched(let data, let newETag):
            let catalog = try ComposioCatalog.decode(data)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            if let newETag, newETag.utf8.count <= 256 { try? newETag.write(to: etagFile, atomically: true, encoding: .utf8) }
            return catalog
        }
    }
}

/// The catalog service only, no cookies, at most 4 MB.
struct ComposioCatalogTransport: TemplateCatalogFetching {
    func fetch(_ url: URL, etag: String?) async throws -> TemplateCatalogFetchResult {
        guard TemplateCatalogPolicy.isAllowed(url) else { throw URLError(.badURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag.hasPrefix("W/") ? String(etag.dropFirst(2)) : etag, forHTTPHeaderField: "If-None-Match") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, TemplateCatalogPolicy.isAllowed(http.url) else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 304 { return .notModified }
        guard http.statusCode == 200, http.expectedContentLength <= Int64(ComposioCatalog.maximumBytes) else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > ComposioCatalog.maximumBytes { throw URLError(.dataLengthExceedsMaximum) }
        }
        return .fetched(data, etag: http.value(forHTTPHeaderField: "ETag"))
    }
}
