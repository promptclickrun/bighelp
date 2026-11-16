import CryptoKit
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Bighelp

@MainActor
struct ProviderLogoStoreTests {
    @Test func downloadedArtworkSurvivesOfflineRelaunch() async throws {
        let cache = FileManager.default.temporaryDirectory.appending(path: "provider-logo-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cache) }
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData())
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let base = URL(string: "https://logos.loopdy.app/provider-logos/v1/")!
        let manifest = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "revision": "first",
            "logos": ["ProviderLogoOpenAI": [
                "light": ["path": "images/\(digest).png", "sha256": digest],
                "dark": ["path": "images/\(digest).png", "sha256": digest]
            ]]
        ])
        let network = ProviderLogoFixtureTransport(responses: [
            base.appending(path: "manifest.json"): manifest,
            base.appending(path: "images/\(digest).png"): png
        ])
        let store = ProviderLogoStore(manifestURL: base.appending(path: "manifest.json"), cacheURL: cache, transport: network)
        await store.refreshIfNeeded()
        #expect(store.revision == "first")
        #expect(store.image(for: "ProviderLogoOpenAI", colorScheme: .light) != nil)
        let offline = ProviderLogoStore(manifestURL: base.appending(path: "manifest.json"), cacheURL: cache, transport: ProviderLogoFixtureTransport(responses: [:]))
        await offline.refreshIfNeeded()
        #expect(offline.revision == "first")
        #expect(offline.image(for: "ProviderLogoOpenAI", colorScheme: .dark) != nil)
    }

    @Test func aNewCatalogChangesTheRenderedImageWithoutRecreatingTheStore() async throws {
        let first = try fixture(revision: "one", light: .red, dark: .blue)
        let network = ProviderLogoFixtureTransport(responses: first.responses)
        let store = ProviderLogoStore(manifestURL: first.url, cacheURL: nil, transport: network)
        await store.refreshIfNeeded()
        let before = try renderedMark(store: store, colorScheme: .light)
        let dark = try renderedMark(store: store, colorScheme: .dark)
        #expect(before != dark)
        let next = try fixture(revision: "two", light: .green, dark: .yellow)
        await network.replace(with: next.responses)
        await store.refreshIfNeeded(force: true)
        #expect(store.revision == "two")
        #expect(try renderedMark(store: store, colorScheme: .light) != before)
        #expect(try renderedMark(store: nil, colorScheme: .light) != before)
    }

    @Test func invalidUpdatePreservesTheLastGoodCatalog() async throws {
        let first = try fixture(revision: "good")
        let network = ProviderLogoFixtureTransport(responses: first.responses)
        let store = ProviderLogoStore(manifestURL: first.url, cacheURL: nil, transport: network)
        await store.refreshIfNeeded()
        let before = store.image(for: "ProviderLogoAnthropic", colorScheme: .light)?.pngData()
        var broken = try fixture(revision: "broken", light: .green)
        for url in broken.responses.keys where url.pathExtension == "png" {
            broken.responses[url] = Data("not a PNG".utf8)
        }
        await network.replace(with: broken.responses)
        await store.refreshIfNeeded(force: true)
        #expect(store.revision == "good")
        #expect(store.image(for: "ProviderLogoAnthropic", colorScheme: .light)?.pngData() == before)
    }

    @Test func removedOverridesReturnToBundledArtwork() async throws {
        let first = try fixture(revision: "present")
        let network = ProviderLogoFixtureTransport(responses: first.responses)
        let store = ProviderLogoStore(manifestURL: first.url, cacheURL: nil, transport: network)
        await store.refreshIfNeeded()
        await network.replace(with: [first.url: try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "revision": "withdrawn", "logos": [:] as [String: String]
        ])])
        await store.refreshIfNeeded(force: true)
        #expect(store.revision == "withdrawn")
        #expect(store.image(for: "ProviderLogoAnthropic", colorScheme: .light) == nil)
        #expect(try renderedMark(store: store, colorScheme: .light) == renderedMark(store: nil, colorScheme: .light))
    }

    @Test func coalescesConcurrentRefreshesAndDeduplicatesImageHashes() async throws {
        let value = try fixture(revision: "shared", light: .red, dark: .red)
        let network = ProviderLogoFixtureTransport(responses: value.responses)
        await network.setDelay(.milliseconds(25))
        let store = ProviderLogoStore(manifestURL: value.url, cacheURL: nil, transport: network)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { await store.refreshIfNeeded() } }
        }
        #expect(store.revision == "shared")
        #expect(await network.requests.filter { $0 == value.url }.count == 1)
        #expect(await network.requests.filter { $0.pathExtension == "png" }.count == 1)
    }

    @Test func dailyRefreshAndFailedRetryAreThrottled() async throws {
        let value = try fixture(revision: "daily")
        let clock = ProviderLogoTestClock()
        let network = ProviderLogoFixtureTransport(responses: value.responses)
        let store = ProviderLogoStore(manifestURL: value.url, cacheURL: nil, transport: network, now: { clock.now })
        await store.refreshIfNeeded()
        await store.refreshIfNeeded()
        #expect(await network.requests.filter { $0 == value.url }.count == 1)
        clock.advance(86_401)
        await network.replace(with: [:])
        await store.refreshIfNeeded()
        await store.refreshIfNeeded()
        #expect(await network.requests.filter { $0 == value.url }.count == 2)
        #expect(store.revision == "daily")
        clock.advance(901)
        await store.refreshIfNeeded()
        #expect(await network.requests.filter { $0 == value.url }.count == 3)
    }

    @Test func rejectsUnsafePathsAndUnsupportedProviderArtworkBeforeImageRequests() async throws {
        let url = URL(string: "https://logos.loopdy.app/provider-logos/v1/manifest.json")!
        for path in ["https://example.org/logo.png", "../logo.png", "images/../logo.png", "images/logo.png?key=secret"] {
            let entry = ["path": path, "sha256": String(repeating: "a", count: 64)]
            let data = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "revision": "invalid", "logos": ["ProviderLogoAnthropic": ["light": entry, "dark": entry]]
            ])
            let network = ProviderLogoFixtureTransport(responses: [url: data])
            let store = ProviderLogoStore(manifestURL: url, cacheURL: nil, transport: network)
            await store.refreshIfNeeded()
            #expect(store.revision == nil)
            #expect(await network.requests.count == 1)
        }
        let value = try fixture(revision: "unsupported", asset: "ProviderLogoNoSuchProvider")
        let network = ProviderLogoFixtureTransport(responses: value.responses)
        let store = ProviderLogoStore(manifestURL: value.url, cacheURL: nil, transport: network)
        await store.refreshIfNeeded()
        #expect(store.revision == nil)
        #expect(await network.requests.count == 1)
    }

    @Test func rejectsOversizedDecodedImagesEvenWhenCompressedBytesAreSmall() async throws {
        let value = try fixture(revision: "too-wide", dimensions: CGSize(width: 1025, height: 2))
        let store = ProviderLogoStore(manifestURL: value.url, cacheURL: nil, transport: ProviderLogoFixtureTransport(responses: value.responses))
        await store.refreshIfNeeded()
        #expect(store.revision == nil)
        #expect(store.image(for: "ProviderLogoAnthropic", colorScheme: .light) == nil)
    }

    @Test func corruptDiskCacheFallsBackWithoutCrashing() async throws {
        let cache = FileManager.default.temporaryDirectory.appending(path: "provider-logo-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cache) }
        try Data("corrupt snapshot".utf8).write(to: cache)
        let store = ProviderLogoStore(manifestURL: URL(string: "https://logos.loopdy.app/provider-logos/v1/manifest.json")!, cacheURL: cache, transport: ProviderLogoFixtureTransport(responses: [:]))
        await store.refreshIfNeeded()
        #expect(store.revision == nil)
        #expect(store.image(for: "ProviderLogoAnthropic", colorScheme: .light) == nil)
    }

    @Test func remoteArtworkUpdatesSharedCopilotAssetWithoutChangingProviderIdentity() async throws {
        let value = try fixture(revision: "copilot", asset: "ProviderLogoGitHubCopilot")
        let store = ProviderLogoStore(manifestURL: value.url, cacheURL: nil, transport: ProviderLogoFixtureTransport(responses: value.responses))
        await store.refreshIfNeeded()
        func image(_ value: ProviderLogoStore?) throws -> Data {
            let renderer = ImageRenderer(content: AIProviderMarkView(providerID: "copilot-acp", providerName: "GitHub Copilot ACP", context: .agentRuntimeSelection, size: 44).environment(\.providerLogoStore, value))
            return try #require(renderer.uiImage?.pngData())
        }
        #expect(store.revision == "copilot")
        #expect(try image(store) != image(nil))
        let identity = AIProviderVisibleIdentity.resolve(providerID: "copilot-acp", providerName: "GitHub Copilot ACP")
        #expect(identity.rawProviderID == "copilot-acp")
        #expect(identity.visibleProviderName == "GitHub Copilot ACP")
    }

    @Test func fixedOriginPolicyRejectsAlternateURLs() {
        #expect(ProviderLogoPolicy.isAllowedURL(ProviderLogoPolicy.manifestURL))
        for value in [
            "http://logos.loopdy.app/provider-logos/v1/manifest.json",
            "https://example.org/provider-logos/v1/manifest.json",
            "https://logos.loopdy.app:443/provider-logos/v1/manifest.json",
            "https://user:password@logos.loopdy.app/provider-logos/v1/manifest.json",
            "https://logos.loopdy.app/provider-logos/v1/manifest.json?token=sentinel",
            "https://logos.loopdy.app/provider-logos/v1/manifest.json#fragment",
            "https://logos.loopdy.app/provider-logos/v1/images/../manifest.json"
        ] {
            #expect(!ProviderLogoPolicy.isAllowedURL(URL(string: value)!))
        }
    }

    @Test func ambiguousAndUnsupportedCatalogsAreRejected() {
        for json in [
            "{\"schemaVersion\":1,\"revision\":\"one\",\"revision\":\"two\",\"logos\":{}}",
            "{\"schemaVersion\":true,\"revision\":\"one\",\"logos\":{}}",
            "{\"schemaVersion\":2,\"revision\":\"one\",\"logos\":{}}",
            "{\"schemaVersion\":1,\"revision\":\"one\",\"logos\":[],\"extra\":0}"
        ] {
            #expect(throws: (any Error).self) {
                try ProviderLogoManifest.parse(Data(json.utf8), allowedAssetNames: ["ProviderLogoOpenAI"])
            }
        }
    }

    @Test func cancellingTheFinalWaiterDoesNotPublishPartialArtwork() async throws {
        let value = try fixture(revision: "cancelled")
        let network = ProviderLogoFixtureTransport(responses: value.responses)
        await network.setDelay(.milliseconds(100))
        let store = ProviderLogoStore(manifestURL: value.url, cacheURL: nil, transport: network)
        let refresh = Task { await store.refreshIfNeeded() }
        for _ in 0..<1_000 {
            if !(await network.requests.isEmpty) { break }
            await Task.yield()
        }
        #expect(!(await network.requests.isEmpty))
        refresh.cancel()
        await refresh.value
        #expect(store.revision == nil)
        await network.setDelay(.zero)
        await store.refreshIfNeeded()
        #expect(store.revision == "cancelled")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BIGHELP_PROVIDER_LOGO_LIVE_PROOF"] == "1"))
    func liveHostedCatalogRendersBothAppearances() async throws {
        let store = ProviderLogoStore.makeLive()
        await store.refreshIfNeeded(force: true)
        #expect(store.revision != nil)
        let providers = [
            ("openai", "OpenAI", "ProviderLogoOpenAI"),
            ("anthropic", "Anthropic", "ProviderLogoAnthropic"),
            ("google", "Google", "ProviderLogoGoogle"),
            ("openrouter", "OpenRouter", "ProviderLogoOpenRouter"),
            ("mistral", "Mistral AI", "ProviderLogoMistral"),
            ("lm-studio", "LM Studio", "ProviderLogoLMStudio"),
            ("huggingface", "Hugging Face", "ProviderLogoHuggingFace"),
            ("venice", "Venice", "ProviderLogoVenice"),
            ("github-copilot", "GitHub Copilot", "ProviderLogoGitHubCopilot")
        ]
        for (_, _, asset) in providers {
            #expect(store.image(for: asset, colorScheme: .light) != nil)
            #expect(store.image(for: asset, colorScheme: .dark) != nil)
        }
        let view = VStack(spacing: 12) {
            Text("Hosted provider logos").font(.headline)
            Text("Remote light / dark · Bundled light / dark").font(.caption)
            ForEach(providers, id: \.0) { provider in
                HStack(spacing: 12) {
                    Text(provider.1).font(.caption).frame(width: 100, alignment: .leading)
                    ForEach([false, true], id: \.self) { bundled in
                        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                            AIProviderMarkView(providerID: provider.0, providerName: provider.1, context: .modelPickerProviderHeader, size: 48)
                                .environment(\.providerLogoStore, bundled ? nil : store)
                                .environment(\.colorScheme, scheme)
                                .padding(12)
                                .background(scheme == .dark ? Color.black : Color.white)
                        }
                    }
                }
            }
        }.padding(16).background(Color.gray.opacity(0.15))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let data = try #require(renderer.uiImage?.pngData())
        let path = FileManager.default.temporaryDirectory.appending(path: "loopdy-provider-logos-live.png")
        try data.write(to: path, options: .atomic)
        print("PROVIDER_LOGO_LIVE_EVIDENCE \(path.path(percentEncoded: false)) revision=\(store.revision ?? "none")")
    }

    private func renderedMark(store: ProviderLogoStore?, colorScheme: ColorScheme) throws -> Data {
        let renderer = ImageRenderer(content: AIProviderMarkView(providerID: "anthropic", providerName: "Anthropic", context: .modelPickerProviderHeader, size: 64)
            .environment(\.providerLogoStore, store).environment(\.colorScheme, colorScheme))
        renderer.scale = 1
        return try #require(renderer.uiImage?.pngData())
    }

    private func fixture(revision: String, asset: String = "ProviderLogoAnthropic", light: UIColor = .red, dark: UIColor = .blue, dimensions: CGSize = CGSize(width: 8, height: 8)) throws -> (url: URL, responses: [URL: Data]) {
        let base = URL(string: "https://logos.loopdy.app/provider-logos/v1/")!
        var responses: [URL: Data] = [:]
        var entries: [String: [String: String]] = [:]
        for (appearance, color) in [("light", light), ("dark", dark)] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let png = try #require(UIGraphicsImageRenderer(size: dimensions, format: format).image { context in
                color.setFill()
                context.fill(CGRect(origin: .zero, size: dimensions))
            }.pngData())
            let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            entries[appearance] = ["path": "images/\(digest).png", "sha256": digest]
            responses[base.appending(path: "images/\(digest).png")] = png
        }
        let url = base.appending(path: "manifest.json")
        responses[url] = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "revision": revision, "logos": [asset: entries]])
        return (url, responses)
    }
}

private final class ProviderLogoTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

actor ProviderLogoFixtureTransport: ProviderLogoFetching {
    var responses: [URL: Data]
    var requests: [URL] = []
    private var delay = Duration.zero
    init(responses: [URL: Data]) { self.responses = responses }
    func replace(with responses: [URL: Data]) { self.responses = responses }
    func setDelay(_ delay: Duration) { self.delay = delay }
    func data(from url: URL, maximumBytes: Int) async throws -> Data {
        requests.append(url)
        if delay > .zero { try await Task.sleep(for: delay) }
        guard let data = responses[url] else { throw URLError(.notConnectedToInternet) }
        guard data.count <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }
}
