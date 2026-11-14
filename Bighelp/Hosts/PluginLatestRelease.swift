import Foundation

/// The newest bighelp plugin: the latest published GitHub Release of the plugin
/// repository. A plugin merge that bumps its version publishes one, so hosts get
/// plugin updates without a new app build.
struct PluginRelease: Equatable, Sendable {
    let version: String
    /// The release's exact commit, which the host installs and reads back.
    let pin: HostPluginPin
    /// The release description (the merged pull request's), for "What's new".
    let notes: String

    /// The notes as plain lines: Markdown headings and bullets without their marks.
    var whatsNew: String {
        notes.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var text = line.trimmingCharacters(in: .whitespaces)
            while text.hasPrefix("#") { text.removeFirst() }
            if text.hasPrefix("- ") || text.hasPrefix("* ") { text = "• " + text.dropFirst(2) }
            return text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        .joined(separator: "\n")
        .replacingOccurrences(of: "\n\n\n", with: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .prefix(1_500)
        .description
    }
}

enum PluginReleaseError: Error, LocalizedError, Equatable {
    case unreachable, invalidResponse

    var errorDescription: String? {
        switch self {
        case .unreachable:
            "Bighelp couldn't reach GitHub to find the newest plugin. Check the internet connection and try again."
        case .invalidResponse:
            "GitHub's answer about the newest plugin didn't look right. Try again later."
        }
    }
}

@MainActor
protocol PluginReleaseResolving: AnyObject {
    /// A recent answer is reused unless `refresh` asks GitHub again.
    func latest(refresh: Bool) async throws -> PluginRelease
}

@MainActor
final class GitHubPluginReleaseSource: PluginReleaseResolving {
    typealias Fetch = @Sendable (_ request: URLRequest, _ maximumBytes: Int) async throws -> (Data, HTTPURLResponse)

    static let shared = GitHubPluginReleaseSource()
    nonisolated static let latestReleaseURL = URL(string: "https://api.github.com/repos/promptclickrun/bighelp-plugin/releases/latest")!
    /// What `git ls-remote` reads: it maps the release tag to its commit and has no API rate limit.
    nonisolated static let referencesURL = URL(string: "https://github.com/promptclickrun/bighelp-plugin.git/info/refs?service=git-upload-pack")!
    nonisolated static let freshFor: TimeInterval = 600

    private let fetch: Fetch
    private let now: () -> Date
    private var cached: (release: PluginRelease, at: Date)?
    private var inFlight: Task<PluginRelease, Error>?

    init(fetch: @escaping Fetch = BoundedGitHubFetch.fetch, now: @escaping () -> Date = Date.init) {
        self.fetch = fetch
        self.now = now
    }

    func latest(refresh: Bool = false) async throws -> PluginRelease {
        if !refresh, let cached, now().timeIntervalSince(cached.at) < Self.freshFor { return cached.release }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await resolve() }
        inFlight = task
        defer { inFlight = nil }
        let release = try await task.value
        cached = (release, now())
        return release
    }

    private func resolve() async throws -> PluginRelease {
        var releaseRequest = URLRequest(url: Self.latestReleaseURL, timeoutInterval: 20)
        releaseRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        releaseRequest.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (releaseBody, _) = try await load(releaseRequest, maximumBytes: 256 * 1_024)
        let release = try Self.release(from: releaseBody)

        var referencesRequest = URLRequest(url: Self.referencesURL, timeoutInterval: 20)
        referencesRequest.setValue("application/x-git-upload-pack-advertisement", forHTTPHeaderField: "Accept")
        let (references, response) = try await load(referencesRequest, maximumBytes: 1_024 * 1_024)
        guard response.value(forHTTPHeaderField: "Content-Type") == "application/x-git-upload-pack-advertisement" else {
            throw PluginReleaseError.invalidResponse
        }
        let revision = try Self.commit(forTag: release.tag, advertisement: references)
        guard let pin = try? HostPluginPin(revision: revision) else { throw PluginReleaseError.invalidResponse }
        return PluginRelease(version: release.version, pin: pin, notes: release.notes)
    }

    private func load(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let result: (Data, HTTPURLResponse)
        do {
            result = try await fetch(request, maximumBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PluginReleaseError {
            throw error
        } catch {
            throw PluginReleaseError.unreachable
        }
        guard result.1.statusCode == 200 else {
            throw result.1.statusCode >= 500 || result.1.statusCode == 403 || result.1.statusCode == 429
                ? PluginReleaseError.unreachable : PluginReleaseError.invalidResponse
        }
        return result
    }

    /// The tag, version and notes of a published release. Drafts and pre-releases never count.
    nonisolated static func release(from data: Data) throws -> (tag: String, version: String, notes: String) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              object["draft"] as? Bool == false, object["prerelease"] as? Bool == false,
              tag.hasPrefix("v"), HostPluginPin.validVersion(String(tag.dropFirst())),
              tag.split(separator: ".").count <= 4 else {
            throw PluginReleaseError.invalidResponse
        }
        let notes = (object["body"] as? String).map { String($0.prefix(4_000)) } ?? ""
        return (tag, String(tag.dropFirst()), notes)
    }

    /// Finds `refs/tags/<tag>` in Git's ref advertisement (pkt-lines). An annotated tag's
    /// commit is its peeled `^{}` entry; a lightweight tag points straight at the commit.
    nonisolated static func commit(forTag tag: String, advertisement data: Data) throws -> String {
        let bytes = [UInt8](data)
        var index = 0
        var direct: String?
        var peeled: String?
        while index + 4 <= bytes.count {
            guard let header = String(bytes: bytes[index..<index + 4], encoding: .ascii),
                  let length = Int(header, radix: 16) else { throw PluginReleaseError.invalidResponse }
            if length == 0 { index += 4; continue }
            guard length >= 4, index + length <= bytes.count else { throw PluginReleaseError.invalidResponse }
            let payload = bytes[index + 4..<index + length]
            index += length
            // "<40 hex> <ref>[\0capabilities]\n"
            let line = payload.prefix { $0 != 0 && $0 != 10 }
            guard let text = String(bytes: line, encoding: .utf8) else { continue }
            let parts = text.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let revision = String(parts[0]), reference = String(parts[1])
            if reference == "refs/tags/\(tag)" { direct = revision }
            if reference == "refs/tags/\(tag)^{}" { peeled = revision }
        }
        guard index == bytes.count, let revision = peeled ?? direct,
              (try? HostPluginPin(revision: revision)) != nil else {
            throw PluginReleaseError.invalidResponse
        }
        return revision
    }
}

/// Unauthenticated, cookie-free GETs to GitHub with a size cap. Redirects may only
/// stay on GitHub (a renamed repository redirects to its new name).
enum BoundedGitHubFetch {
    @Sendable static func fetch(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: GitHubOnlyRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = request
        request.httpMethod = "GET"
        request.setValue("bighelp-ios", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.expectedContentLength <= Int64(maximumBytes) else { throw PluginReleaseError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw PluginReleaseError.invalidResponse }
            data.append(byte)
        }
        return (data, http)
    }
}

private final class GitHubOnlyRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host?.lowercased()
        completionHandler(request.url?.scheme == "https" && (host == "api.github.com" || host == "github.com") ? request : nil)
    }
}
