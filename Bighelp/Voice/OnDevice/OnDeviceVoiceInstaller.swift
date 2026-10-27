import CryptoKit
import Foundation
import Observation

/// Downloads on-device voice models when someone picks one, never with the app: a model is over
/// 100 MB. Each lives in Application Support (left out of backups) and is checked file by file
/// against its own `bundle.json` before it's used.
@MainActor @Observable
final class OnDeviceVoiceInstaller {
    enum State: Equatable, Sendable {
        case notInstalled
        /// 0...1 of the download.
        case downloading(Double)
        /// Checking and unpacking the download.
        case installing
        case installed
        case failed(String)
    }

    static let shared = OnDeviceVoiceInstaller()

    /// What changed while the app ran: downloads, installs, removals.
    private var states: [String: State] = [:]
    /// What was on disk when first asked, so a view never reads the disk on each draw.
    @ObservationIgnored private var found: [String: State] = [:]
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var jobs: [String: Task<Void, Never>] = [:]

    init(root: URL = URL.applicationSupportDirectory.appending(path: "BighelpVoices", directoryHint: .isDirectory),
         session: URLSession = .shared) {
        self.root = root
        self.session = session
    }

    func state(of model: OnDeviceVoiceModel) -> State {
        if let state = states[model.id] ?? found[model.id] { return state }
        let state: State = Self.isComplete(directory(for: model)) ? .installed : .notInstalled
        found[model.id] = state
        return state
    }

    func isInstalled(_ model: OnDeviceVoiceModel) -> Bool {
        state(of: model) == .installed
    }

    func directory(for model: OnDeviceVoiceModel) -> URL {
        root.appending(path: model.id, directoryHint: .isDirectory)
    }

    /// The model's voices, its own default first, then by name.
    func voices(for model: OnDeviceVoiceModel) -> [String] {
        guard isInstalled(model) else { return [] }
        let folder = directory(for: model).appending(path: "voices", directoryHint: .isDirectory)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".safetensors") }
            .map { String($0.dropLast(".safetensors".count)) }
        return names.sorted { lhs, rhs in
            if (lhs == model.defaultVoice) != (rhs == model.defaultVoice) { return lhs == model.defaultVoice }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    func install(_ model: OnDeviceVoiceModel) {
        guard jobs[model.id] == nil, state(of: model) != .installed else { return }
        states[model.id] = .downloading(0)
        jobs[model.id] = Task { [weak self] in
            await self?.run(model)
        }
    }

    func cancel(_ model: OnDeviceVoiceModel) {
        jobs[model.id]?.cancel()
    }

    /// Frees the space. Agents that used it speak with their computer's voice again. Not while a
    /// download unpacks: it would put the files back.
    func remove(_ model: OnDeviceVoiceModel) {
        guard jobs[model.id] == nil else { return }
        try? FileManager.default.removeItem(at: directory(for: model))
        states[model.id] = .notInstalled
    }

    private func run(_ model: OnDeviceVoiceModel) async {
        defer { jobs[model.id] = nil }
        let destination = directory(for: model)
        do {
            let archive = try await download(model)
            states[model.id] = .installing
            try await Task.detached(priority: .userInitiated) {
                defer { try? FileManager.default.removeItem(at: archive) }
                try Self.unpack(archive, model: model, into: destination)
            }.value
            states[model.id] = .installed
        } catch is CancellationError {
            states[model.id] = .notInstalled
        } catch let error as URLError where error.code == .cancelled {
            states[model.id] = .notInstalled
        } catch {
            states[model.id] = .failed(Self.message(for: error))
        }
    }

    private func download(_ model: OnDeviceVoiceModel) async throws -> URL {
        let progress = DownloadProgress(total: model.archiveBytes) { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard case .downloading = self?.states[model.id] else { return }
                self?.states[model.id] = .downloading(fraction)
            }
        }
        let (temporary, response) = try await session.download(from: model.archiveURL, delegate: progress)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            try? FileManager.default.removeItem(at: temporary)
            throw URLError(.badServerResponse)
        }
        // Out of URLSession's temporary spot, until it's unpacked.
        let kept = FileManager.default.temporaryDirectory.appending(path: "\(model.id)-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: temporary, to: kept)
        return kept
    }

    /// Checks the archive, unpacks it beside `destination` and swaps it in only once every file
    /// is there and matches, so a failure leaves nothing half-installed.
    nonisolated static func unpack(_ archive: URL, model: OnDeviceVoiceModel, into destination: URL) throws {
        guard try sha256(of: archive) == model.archiveSHA256 else { throw InstallError.checksum }
        let fileManager = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appending(path: destination.lastPathComponent + ".partial", directoryHint: .isDirectory)
        try? fileManager.removeItem(at: staging)
        defer { try? fileManager.removeItem(at: staging) }
        try ZipArchiveExtractor.extract(archive, folder: model.archiveFolder, to: staging)
        try verify(staging)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staging, to: destination)
        // Installed by now: a failure here only means a backup could include it.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = destination
        try? excluded.setResourceValues(values)
    }

    private struct Manifest: Decodable {
        struct File: Decodable {
            let path: String
            let size: Int
            let sha256: String
        }
        let files: [File]
    }

    /// Every file the model lists is there, at its size and SHA-256.
    nonisolated static func verify(_ directory: URL) throws {
        let data = try Data(contentsOf: directory.appending(path: "bundle.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard !manifest.files.isEmpty, manifest.files.count <= 512 else { throw InstallError.incomplete }
        for file in manifest.files {
            guard !file.path.split(separator: "/").contains(".."), !file.path.hasPrefix("/") else {
                throw InstallError.incomplete
            }
            let url = directory.appending(path: file.path)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size == file.size, try sha256(of: url) == file.sha256.lowercased() else {
                throw InstallError.incomplete
            }
        }
    }

    /// Whether `directory` holds a model that finished installing (files there, sizes right).
    /// Hashes were checked when it was installed.
    nonisolated static func isComplete(_ directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appending(path: "bundle.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              !manifest.files.isEmpty else { return false }
        return manifest.files.allSatisfy { file in
            (try? directory.appending(path: file.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) == file.size
        }
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum InstallError: Error {
        case checksum, incomplete
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost:
            String(localized: "The download stopped because the internet connection was lost. Try again when you're online.")
        case let error as CocoaError where error.code == .fileWriteOutOfSpace:
            String(localized: "There isn't enough free space for this voice. Free some space, then try again.")
        case InstallError.checksum, InstallError.incomplete, is ZipArchiveExtractor.Failure:
            String(localized: "The download was damaged. Try again.")
        default:
            String(localized: "The voice couldn't be downloaded. Try again.")
        }
    }
}

/// Byte progress of one download, on whatever queue URLSession calls it.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    private let total: Int64
    private let report: @Sendable (Double) -> Void

    init(total: Int64, report: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.report = report
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : total
        report(min(1, Double(totalBytesWritten) / Double(max(expected, 1))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
