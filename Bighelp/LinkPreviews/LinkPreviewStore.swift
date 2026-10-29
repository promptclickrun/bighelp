import CryptoKit
import Foundation
import UIKit

/// Keeps link previews, so a card loads once and keeps its size: in memory
/// while the app runs, and on disk for a week. A few load at a time.
@MainActor
final class LinkPreviewStore {
    enum Result: Equatable, Sendable {
        case preview(LinkPreview)
        /// Not a public web page, or it has nothing to show: the card shows the site.
        case unavailable

        var preview: LinkPreview? {
            if case .preview(let preview) = self { preview } else { nil }
        }
    }

    static var shared = LinkPreviewStore(loader: .live, directory: defaultDirectory)

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "LinkPreviews", directoryHint: .isDirectory)
    }

    nonisolated static let keepFor: TimeInterval = 7 * 24 * 60 * 60
    static let retryFailuresAfter: TimeInterval = 15 * 60
    static let maximumRemembered = 300
    static let maximumConcurrentLoads = 3

    private let loader: LinkPreviewLoader
    private let directory: URL?
    private let now: () -> Date
    private var remembered: [String: (result: Result, at: Date)] = [:]
    private var rememberedOrder: [String] = []
    /// Pictures when there's no directory (demo runs and tests).
    private var pictures: [String: Data] = [:]
    private let decoded = NSCache<NSString, UIImage>()
    private var loading: [String: Task<Result, Never>] = [:]
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(loader: LinkPreviewLoader, directory: URL?, now: @escaping () -> Date = Date.init) {
        self.loader = loader
        self.directory = directory
        self.now = now
        decoded.countLimit = 60
        if let directory {
            Task.detached(priority: .utility) { Self.prune(directory) }
        }
    }

    /// What's already known about `url`, without loading anything.
    func cached(_ url: URL) -> Result? {
        guard let target = LinkPreviewPolicy.loadableURL(url) else { return .unavailable }
        let key = Self.key(target)
        if let entry = remembered[key] {
            if entry.result == .unavailable, now().timeIntervalSince(entry.at) > Self.retryFailuresAfter { return nil }
            return entry.result
        }
        guard let directory, let preview = Self.read(key, in: directory, now: now()) else { return nil }
        remember(.preview(preview), for: key)
        return .preview(preview)
    }

    func load(_ url: URL) async -> Result {
        if let known = cached(url) { return known }
        guard let target = LinkPreviewPolicy.loadableURL(url) else { return .unavailable }
        let key = Self.key(target)
        if let task = loading[key] { return await task.value }
        let task = Task { [loader, directory] () -> Result in
            await self.startLoading()
            defer { self.finishLoading() }
            guard let loaded = try? await loader.load(target) else { return .unavailable }
            if let directory {
                await Self.write(loaded, key: key, in: directory)
            } else if let data = loaded.imageData {
                self.pictures[key] = data
            }
            return .preview(loaded.preview)
        }
        loading[key] = task
        let result = await task.value
        loading[key] = nil
        remember(result, for: key)
        return result
    }

    /// The picture for `url`'s preview if it's already decoded in memory, without loading anything.
    func cachedPicture(for url: URL) -> UIImage? {
        guard let target = LinkPreviewPolicy.loadableURL(url) else { return nil }
        return decoded.object(forKey: Self.key(target) as NSString)
    }

    /// The kept picture for `url`'s preview, if it has one.
    func picture(for url: URL) async -> UIImage? {
        guard let target = LinkPreviewPolicy.loadableURL(url) else { return nil }
        let key = Self.key(target)
        if let image = decoded.object(forKey: key as NSString) { return image }
        var data = pictures[key]
        if let directory { data = await Self.readPicture(key, in: directory) }
        guard let data, let image = UIImage(data: data) else { return nil }
        decoded.setObject(image, forKey: key as NSString)
        return image
    }

    private func remember(_ result: Result, for key: String) {
        if remembered[key] == nil { rememberedOrder.append(key) }
        remembered[key] = (result, now())
        while rememberedOrder.count > Self.maximumRemembered {
            let oldest = rememberedOrder.removeFirst()
            remembered[oldest] = nil
            pictures[oldest] = nil
        }
    }

    private func startLoading() async {
        if running < Self.maximumConcurrentLoads {
            running += 1
            return
        }
        // The slot is handed over by `finishLoading`.
        await withCheckedContinuation { waiting.append($0) }
    }

    private func finishLoading() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    // MARK: Disk

    private static func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func read(_ key: String, in directory: URL, now: Date) -> LinkPreview? {
        let file = directory.appending(path: "\(key).json", directoryHint: .notDirectory)
        guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              now.timeIntervalSince(modified) < keepFor,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(LinkPreview.self, from: data)
    }

    private nonisolated static func write(_ loaded: LinkPreviewLoader.Loaded, key: String, in directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = loaded.imageData {
            try? data.write(to: directory.appending(path: "\(key).picture", directoryHint: .notDirectory),
                            options: .atomic)
        }
        if let data = try? JSONEncoder().encode(loaded.preview) {
            try? data.write(to: directory.appending(path: "\(key).json", directoryHint: .notDirectory), options: .atomic)
        }
    }

    private nonisolated static func readPicture(_ key: String, in directory: URL) async -> Data? {
        try? Data(contentsOf: directory.appending(path: "\(key).picture", directoryHint: .notDirectory))
    }

    /// Drops previews older than a week, and the oldest past 600 files.
    private nonisolated static func prune(_ directory: URL) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys:
            [.contentModificationDateKey]) else { return }
        let dated = files.map { file in
            (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (index, (file, modified)) in dated.enumerated()
        where index >= 600 || Date().timeIntervalSince(modified) > keepFor {
            try? manager.removeItem(at: file)
        }
    }
}
