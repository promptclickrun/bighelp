import Foundation
import Observation
import UIKit

/// bighelp's Template Catalog (`services/catalog`): new Feed, Ideas and Goals blueprints and agent
/// templates without an app update. Public, read-only, approved items only.
enum TemplateCatalogPolicy {
    static let host = "catalog.bighelp.app"
    static let blueprintsURL = URL(string: "https://catalog.bighelp.app/v1/board-blueprints.json")!
    static let agentTemplatesURL = URL(string: "https://catalog.bighelp.app/v1/agent-templates.json")!
    /// Where people send their own; there's no in-app form.
    static let submitURL = URL(string: "https://bighelp.app/templates#submit")!
    static let maximumBytes = 1_048_576
    static let refreshInterval: TimeInterval = 6 * 60 * 60

    static func isAllowed(_ url: URL?) -> Bool {
        url?.scheme == "https" && url?.host == host && url?.user == nil && url?.password == nil
    }
}

enum TemplateCatalogFetchResult: Sendable, Equatable {
    case notModified
    case fetched(Data, etag: String?)
}

protocol TemplateCatalogFetching: Sendable {
    func fetch(_ url: URL, etag: String?) async throws -> TemplateCatalogFetchResult
}

/// No cookies, no shared cache, https to the catalog host only, and at most 1 MB a file.
struct TemplateCatalogURLSessionTransport: TemplateCatalogFetching {
    func fetch(_ url: URL, etag: String?) async throws -> TemplateCatalogFetchResult {
        guard TemplateCatalogPolicy.isAllowed(url) else { throw URLError(.badURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Cloudflare weakens the ETag (W/"…") when it compresses the reply, and the catalog
        // matches only the strong form.
        if let etag { request.setValue(etag.hasPrefix("W/") ? String(etag.dropFirst(2)) : etag,
                                       forHTTPHeaderField: "If-None-Match") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, TemplateCatalogPolicy.isAllowed(http.url) else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 304 { return .notModified }
        guard http.statusCode == 200, http.expectedContentLength <= Int64(TemplateCatalogPolicy.maximumBytes) else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > TemplateCatalogPolicy.maximumBytes { throw URLError(.dataLengthExceedsMaximum) }
        }
        return .fetched(data, etag: http.value(forHTTPHeaderField: "ETag"))
    }
}

/// The blueprints and agent templates people see: the catalog's last good copy, or the bundled
/// ones until there is one. Refreshed on foreground at most every six hours; a failed or empty
/// download never replaces a good copy.
@MainActor
@Observable
final class TemplateCatalogStore {
    static let shared = TemplateCatalogStore.makeLive()

    private(set) var blueprints: BoardBlueprintCatalog
    private(set) var agentTemplates: [AgentSoulTemplate]

    @ObservationIgnored private let transport: any TemplateCatalogFetching
    @ObservationIgnored private let cacheDirectory: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isEnabled: Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var refreshing: Task<Void, Never>?

    static let fetchedAtKey = "bighelp.template-catalog.fetched-at"

    enum File: String, CaseIterable {
        case blueprints = "board-blueprints"
        case agentTemplates = "agent-templates"

        var url: URL {
            switch self {
            case .blueprints: TemplateCatalogPolicy.blueprintsURL
            case .agentTemplates: TemplateCatalogPolicy.agentTemplatesURL
            }
        }
    }

    init(transport: any TemplateCatalogFetching, cacheDirectory: URL?, defaults: UserDefaults = .standard,
         isEnabled: Bool = true, now: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.cacheDirectory = cacheDirectory
        self.defaults = defaults
        self.isEnabled = isEnabled
        self.now = now
        let bundled = (try? BoardBlueprintCatalog.bundled()) ?? .empty
        blueprints = bundled
        agentTemplates = AgentSoulTemplate.bundled
        guard isEnabled else { return }
        if let data = Self.read(.blueprints, in: cacheDirectory),
           let cached = try? BoardBlueprintCatalog(data: data), cached.count > 0 {
            blueprints = cached
        }
        if let data = Self.read(.agentTemplates, in: cacheDirectory) {
            let cached = AgentSoulTemplate.remote(data)
            if !cached.isEmpty { agentTemplates = cached }
        }
    }

    /// Demo fixtures and tests keep the bundled data and never touch the network.
    static func makeLive() -> TemplateCatalogStore {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        let isOffline = arguments.contains("-use-demo-fixtures") || environment["XCTestConfigurationFilePath"] != nil
        return TemplateCatalogStore(
            transport: TemplateCatalogURLSessionTransport(),
            cacheDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appending(path: "TemplateCatalog", directoryHint: .isDirectory),
            isEnabled: !isOffline
        )
    }

    /// One refresh at a time; callers during it wait for that one.
    func refreshIfNeeded(force: Bool = false) async {
        guard isEnabled else { return }
        if let refreshing {
            await refreshing.value
            return
        }
        if !force, let last = defaults.object(forKey: Self.fetchedAtKey) as? Date {
            let age = now().timeIntervalSince(last)
            if age >= 0, age < TemplateCatalogPolicy.refreshInterval { return }
        }
        let task = Task { await refresh() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func refresh() async {
        var answered = false
        for file in File.allCases {
            let cached = Self.read(file, in: cacheDirectory)
            let etag = cached == nil ? nil : Self.readETag(file, in: cacheDirectory)
            guard let result = try? await transport.fetch(file.url, etag: etag) else { continue }
            answered = true
            guard case .fetched(let data, let newETag) = result, accept(data, for: file) else { continue }
            Self.write(file, data: data, etag: newETag, in: cacheDirectory)
        }
        if answered { defaults.set(now(), forKey: Self.fetchedAtKey) }
    }

    /// Publishes a download only when it holds at least one good item.
    private func accept(_ data: Data, for file: File) -> Bool {
        switch file {
        case .blueprints:
            guard let catalog = try? BoardBlueprintCatalog(data: data), catalog.count > 0 else { return false }
            blueprints = catalog
        case .agentTemplates:
            let templates = AgentSoulTemplate.remote(data)
            guard !templates.isEmpty else { return false }
            agentTemplates = templates
        }
        return true
    }

    // MARK: Cache

    private static func read(_ file: File, in directory: URL?) -> Data? {
        guard let url = directory?.appending(path: file.rawValue + ".json"),
              let data = try? Data(contentsOf: url), !data.isEmpty,
              data.count <= TemplateCatalogPolicy.maximumBytes else { return nil }
        return data
    }

    private static func readETag(_ file: File, in directory: URL?) -> String? {
        guard let url = directory?.appending(path: file.rawValue + ".etag"),
              let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty, text.utf8.count <= 256 else {
            return nil
        }
        return text
    }

    private static func write(_ file: File, data: Data, etag: String?, in directory: URL?) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: file.rawValue + ".json"), options: .atomic)
        let etagURL = directory.appending(path: file.rawValue + ".etag")
        if let etag, etag.utf8.count <= 256 {
            try? Data(etag.utf8).write(to: etagURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: etagURL)
        }
    }
}

extension AgentSoulTemplate {
    /// `/v1/agent-templates.json`, leniently: an item that doesn't read is dropped, never the file.
    /// Community text is shown as plain text only.
    static func remote(_ data: Data) -> [AgentSoulTemplate] {
        guard data.count <= TemplateCatalogPolicy.maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["templates"] as? [Any] else { return [] }
        var seen = Set<String>()
        return rows.prefix(500).compactMap { value -> AgentSoulTemplate? in
            guard let row = value as? [String: Any] else { return nil }
            func text(_ key: String, max: Int) -> String? {
                guard let value = (row[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty, value.count <= max else { return nil }
                return value
            }
            guard let id = text("id", max: 64),
                  id.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
                  seen.insert(id).inserted,
                  let name = text("name", max: 80), let role = text("role", max: 160),
                  let instructions = (row["instructions"] as? String), !instructions.isEmpty,
                  instructions.count <= 64_000 else { return nil }
            let symbol = text("symbol", max: 80).flatMap { UIImage(systemName: $0) == nil ? nil : $0 }
            let credit = BoardBlueprintCatalog.credit(text("credit", max: 40))
            return AgentSoulTemplate(
                id: id, title: name, profile: role, voice: text("vibe", max: 160) ?? "",
                strength: text("description", max: 400) ?? "", systemImage: symbol ?? "person.crop.square",
                inlineSoul: instructions, credit: credit, isCommunity: (row["source"] as? String) == "community"
            )
        }
    }
}
