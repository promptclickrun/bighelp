import Foundation
import Testing
@testable import Bighelp

/// A resolver with a fixed answer, for install and update flows.
@MainActor
final class FixedPluginReleases: PluginReleaseResolving {
    var result: Result<PluginRelease, PluginReleaseError>
    private(set) var calls = 0
    init(_ result: Result<PluginRelease, PluginReleaseError>) { self.result = result }
    static func release(_ version: String, _ character: Character) throws -> FixedPluginReleases {
        FixedPluginReleases(.success(PluginRelease(
            version: version, pin: try HostPluginPin(revision: String(repeating: character, count: 40)), notes: "")))
    }
    func latest(refresh: Bool) async throws -> PluginRelease {
        calls += 1
        return try result.get()
    }
}

@MainActor
struct PluginLatestReleaseTests {
    static let commit = String(repeating: "c", count: 40)
    static let tagObject = String(repeating: "d", count: 40)

    static func pktLines(_ lines: [String]) -> Data {
        var text = "001e# service=git-upload-pack\n0000"
        for line in lines { text += String(format: "%04x", line.utf8.count + 4) + line }
        return Data((text + "0000").utf8)
    }

    static func releaseJSON(tag: String = "v3.0.0", draft: Bool = false, prerelease: Bool = false,
                            body: String = "## 3.0.0: Bighelp names\n\n- Tools say **Bighelp**.") -> Data {
        try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft, "prerelease": prerelease, "body": body])
    }

    @Test func aPublishedReleaseGivesItsVersionAndNotes() throws {
        let release = try GitHubPluginReleaseSource.release(from: Self.releaseJSON())
        #expect(release.tag == "v3.0.0")
        #expect(release.version == "3.0.0")
        #expect(release.notes.hasPrefix("## 3.0.0"))
    }

    @Test func draftsPrereleasesAndOddTagsNeverCount() {
        for data in [Self.releaseJSON(draft: true), Self.releaseJSON(prerelease: true), Self.releaseJSON(tag: "3.0.0"),
                     Self.releaseJSON(tag: "v3.0.0-beta"), Self.releaseJSON(tag: "latest"), Data("{}".utf8), Data("[]".utf8)] {
            #expect(throws: PluginReleaseError.invalidResponse) { try GitHubPluginReleaseSource.release(from: data) }
        }
    }

    @Test func theCommitComesFromGitAndAnAnnotatedTagIsPeeled() throws {
        let annotated = Self.pktLines([
            "\(Self.commit) HEAD\0multi_ack symref=HEAD:refs/heads/main\n",
            "\(Self.commit) refs/heads/main\n",
            "\(Self.tagObject) refs/tags/v3.0.0\n",
            "\(Self.commit) refs/tags/v3.0.0^{}\n",
        ])
        #expect(try GitHubPluginReleaseSource.commit(forTag: "v3.0.0", advertisement: annotated) == Self.commit)
        let lightweight = Self.pktLines(["\(Self.commit) refs/tags/v3.0.0\n"])
        #expect(try GitHubPluginReleaseSource.commit(forTag: "v3.0.0", advertisement: lightweight) == Self.commit)
    }

    @Test func aMissingOrMalformedTagIsRefused() {
        let other = Self.pktLines(["\(Self.commit) refs/tags/v2.19.0\n"])
        let badSHA = Self.pktLines(["NOTASHA refs/tags/v3.0.0\n"])
        for data in [other, badSHA, Data("zzzz".utf8), Data("00ff".utf8)] {
            #expect(throws: PluginReleaseError.invalidResponse) {
                try GitHubPluginReleaseSource.commit(forTag: "v3.0.0", advertisement: data)
            }
        }
    }

    @Test func theSourceAsksGitHubOnceThenReusesTheAnswer() async throws {
        let counter = Counter()
        var clock = Date(timeIntervalSince1970: 1_000)
        let source = GitHubPluginReleaseSource(fetch: Self.fetch(counter: counter), now: { clock })
        async let first = source.latest(refresh: false)
        async let second = source.latest(refresh: false)
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(a.version == "3.0.0")
        #expect(a.pin.revision == Self.commit)
        #expect(await counter.value == 2) // one release lookup and one tag lookup, shared
        _ = try await source.latest(refresh: false)
        #expect(await counter.value == 2)
        _ = try await source.latest(refresh: true)
        #expect(await counter.value == 4)
        clock = clock.addingTimeInterval(GitHubPluginReleaseSource.freshFor + 1)
        _ = try await source.latest(refresh: false)
        #expect(await counter.value == 6)
    }

    @Test func networkTroubleAndBadAnswersAreExplained() async {
        let offline = GitHubPluginReleaseSource(fetch: { _, _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: PluginReleaseError.unreachable) { try await offline.latest(refresh: true) }
        let missing = GitHubPluginReleaseSource(fetch: Self.fetch(counter: Counter(), releaseStatus: 404))
        await #expect(throws: PluginReleaseError.invalidResponse) { try await missing.latest(refresh: true) }
        let limited = GitHubPluginReleaseSource(fetch: Self.fetch(counter: Counter(), releaseStatus: 403))
        await #expect(throws: PluginReleaseError.unreachable) { try await limited.latest(refresh: true) }
        let htmlRefs = GitHubPluginReleaseSource(fetch: Self.fetch(counter: Counter(), refsType: "text/html"))
        await #expect(throws: PluginReleaseError.invalidResponse) { try await htmlRefs.latest(refresh: true) }
    }

    @Test func whatsNewReadsAsPlainLines() throws {
        let release = PluginRelease(version: "3.0.0", pin: try HostPluginPin(revision: Self.commit),
                                    notes: "## 3.0.0: Bighelp names\n\n- Tools say **Bighelp**.\n* `hermes Bighelp` works.")
        #expect(release.whatsNew == "3.0.0: Bighelp names\n\n• Tools say Bighelp.\n• hermes Bighelp works.")
    }

    // MARK: Helpers

    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    static func fetch(counter: Counter, releaseStatus: Int = 200, refsType: String = "application/x-git-upload-pack-advertisement")
        -> GitHubPluginReleaseSource.Fetch {
        let release = releaseJSON()
        let refs = pktLines(["\(commit) refs/tags/v3.0.0\n"])
        return { request, _ in
            await counter.increment()
            let isRelease = request.url == GitHubPluginReleaseSource.latestReleaseURL
            let response = HTTPURLResponse(url: request.url!, statusCode: isRelease ? releaseStatus : 200,
                                           httpVersion: nil,
                                           headerFields: ["Content-Type": isRelease ? "application/json" : refsType])!
            return (isRelease ? release : refs, response)
        }
    }
}
