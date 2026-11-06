import CryptoKit
import Foundation
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The moves a petdex pet's sheet holds, named as Hermes names them
/// (`agent/pet/constants.py`).
enum PetdexMove: String, CaseIterable, Sendable {
    case idle, wave, run, failed, review, jump, waiting

    /// Same priority as Hermes's `derive_pet_state`: a failure, a finished turn,
    /// waiting on you, reasoning, then any other work runs.
    init(activity: AgentActivityKind) {
        switch activity {
        case .idle: self = .idle
        case .failed: self = .failed
        case .done: self = .wave
        case .waiting: self = .waiting
        case .thinking: self = .review
        default: self = .run
        }
    }

    /// Row names this move answers to, newest sheets first.
    var rowNames: [String] {
        switch self {
        case .wave: ["wave", "waving"]
        case .run: ["run", "running"]
        case .jump: ["jump", "jumping"]
        default: [rawValue]
        }
    }

    /// Today's 9-row sheets (1536×1872) and the older 8-row ones.
    static let currentRows = ["idle", "running-right", "running-left", "waving", "jumping",
                              "failed", "waiting", "running", "review"]
    static let legacyRows = ["idle", "wave", "run", "failed", "review", "jump", "extra1", "extra2"]
}

extension PetdexSprite {
    /// Frames each move steps through (petdex's `steps(6)`) and one loop's length.
    static let framesPerMove = 6
    static let loopDuration: Double = 1.1

    /// A petdex sheet cut into one strip per move (up to six frames side by
    /// side, as PNG). Like Hermes, a move stops at its first empty frame; a
    /// move the sheet doesn't have is left out.
    static func strips(fromSheet data: Data) throws -> [PetdexMove: Data] {
        guard data.count <= PetdexPolicy.maximumSheetBytes else { throw PetdexError.tooLarge }
        let sheet = try image(data, allowed: [UTType.webP.identifier, UTType.png.identifier],
                              maximumDimension: PetdexPolicy.maximumSheetDimension)
        let width = PetdexPolicy.frameWidth, height = PetdexPolicy.frameHeight
        let columns = sheet.width / width, rows = sheet.height / height
        guard columns >= 1, rows >= 1 else { throw PetdexError.invalidImage }
        let layout = rows >= PetdexMove.currentRows.count ? PetdexMove.currentRows : PetdexMove.legacyRows
        var strips: [PetdexMove: Data] = [:]
        for move in PetdexMove.allCases {
            guard let row = move.rowNames.lazy.compactMap({ layout.firstIndex(of: $0) }).first, row < rows else { continue }
            let drawn = (0..<min(framesPerMove, columns)).prefix { column in
                guard let frame = sheet.cropping(to: CGRect(x: column * width, y: row * height, width: width, height: height))
                else { return false }
                return !isBlank(frame)
            }.count
            guard drawn > 0, let strip = sheet.cropping(to: CGRect(x: 0, y: row * height, width: drawn * width, height: height))
            else { continue }
            strips[move] = try png(strip)
        }
        guard strips[.idle] != nil else { throw PetdexError.invalidImage }
        return strips
    }

    private static func isBlank(_ frame: CGImage) -> Bool {
        var bytes = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: frame.width, height: frame.height,
                                          bitsPerComponent: 8, bytesPerRow: frame.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
            return true
        }
        guard drawn else { return false }
        return !stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] != 0 }
    }

    /// A strip's frames, left to right.
    static func frames(fromStrip data: Data) -> [CGImage] {
        guard let strip = try? image(data, allowed: [UTType.png.identifier],
                                     maximumDimension: PetdexPolicy.maximumSheetDimension) else { return [] }
        let width = PetdexPolicy.frameWidth
        let count = min(framesPerMove, strip.width / width)
        return (0..<count).compactMap {
            strip.cropping(to: CGRect(x: $0 * width, y: 0, width: width, height: min(PetdexPolicy.frameHeight, strip.height)))
        }
    }
}

/// Which agents wear a petdex pet, and each pet's moves, kept on this device
/// (Hermes Desktop keeps a bot's pet locally too). The agent's saved picture
/// stays its first frame, so other devices and Hermes Desktop still show it.
@MainActor
@Observable
final class PetAvatarStore {
    static let shared = PetAvatarStore(
        defaults: .standard,
        directory: URL.applicationSupportDirectory.appending(path: "PetAvatars", directoryHint: .isDirectory))

    static let maximumAgents = 256
    private static let storageKey = "bighelp.pet-avatars"

    /// Agent key (`CompanionStore.agentKey`) → pet slug, once its moves are on disk.
    private(set) var assignments: [String: String]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var loads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var frameCache: [String: [CGImage]] = [:]
    @ObservationIgnored private var frameOrder: [String] = []

    init(defaults: UserDefaults, directory: URL) {
        self.defaults = defaults
        self.directory = directory
        let stored = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
        assignments = stored.filter { $0.key.utf8.count <= CompanionStore.maximumKeyUTF8Count && $0.value.utf8.count <= 128 }
    }

    func slug(for agentKey: String) -> String? { assignments[agentKey] }

    /// Pets chosen on another device whose moves are still on their way (or couldn't come): they
    /// count as the agent's pet for app state, so a slow download never takes them off elsewhere.
    @ObservationIgnored private(set) var wanted: [String: String] = [:]

    /// The frames for this agent's move, or nil when it wears no pet (or the
    /// pet's moves are gone): then its still picture shows.
    func frames(for agentKey: String, move: PetdexMove) -> [CGImage]? {
        guard let slug = assignments[agentKey] else { return nil }
        if let frames = frames(slug: slug, move: move), !frames.isEmpty { return frames }
        return move == .idle ? nil : frames(slug: slug, move: .idle)
    }

    /// Fetches the pet's sheet (unless its moves are already here), cuts it into
    /// moves and then puts it on the agent. Until then the still picture shows.
    func assign(_ pet: PetdexPet, to agentKey: String, loadSheet: @escaping @MainActor () async throws -> Data) {
        wanted[agentKey] = nil
        loads[agentKey]?.cancel()
        let folder = folder(for: pet.slug)
        loads[agentKey] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.loads[agentKey] = nil }
            if !FileManager.default.fileExists(atPath: folder.appending(path: "idle.png").path()) {
                guard let sheet = try? await loadSheet(), !Task.isCancelled,
                      let strips = try? await Task.detached(priority: .utility, operation: {
                          try PetdexSprite.strips(fromSheet: sheet)
                      }).value,
                      !Task.isCancelled else { return }
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    for (move, data) in strips {
                        try data.write(to: folder.appending(path: move.rawValue + ".png"), options: .atomic)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    return
                }
            }
            guard !Task.isCancelled else { return }
            if self.assignments[agentKey] == nil, self.assignments.count >= Self.maximumAgents { return }
            self.assignments[agentKey] = pet.slug
            if self.wanted[agentKey] == pet.slug { self.wanted[agentKey] = nil }
            self.persist()
        }
    }

    /// A pet chosen on another device (`BotsAppState`): found by its slug, then put on the agent the
    /// way `assign` does. Nothing when it's on already or on its way.
    func restore(_ slug: String, to agentKey: String, find: @escaping @MainActor (String) async -> PetdexPet?,
                 loadSheet: @escaping @MainActor (PetdexPet) async throws -> Data) {
        guard assignments[agentKey] != slug, wanted[agentKey] != slug else { return }
        guard assignments[agentKey] != nil || assignments.count < Self.maximumAgents else { return }
        loads[agentKey]?.cancel()
        wanted[agentKey] = slug
        loads[agentKey] = Task { @MainActor [weak self] in
            guard let pet = await find(slug), !Task.isCancelled, let self, self.wanted[agentKey] == slug else { return }
            self.assign(pet, to: agentKey) { try await loadSheet(pet) }
            self.wanted[agentKey] = slug
        }
    }

    /// The agent wears something else now.
    func remove(_ agentKey: String) {
        wanted[agentKey] = nil
        loads[agentKey]?.cancel()
        loads[agentKey] = nil
        guard let slug = assignments.removeValue(forKey: agentKey) else { return }
        persist()
        if !assignments.values.contains(slug) {
            try? FileManager.default.removeItem(at: folder(for: slug))
            for move in PetdexMove.allCases { forgetFrames(slug + "|" + move.rawValue) }
        }
    }

    private func frames(slug: String, move: PetdexMove) -> [CGImage]? {
        let key = slug + "|" + move.rawValue
        if let cached = frameCache[key] { return cached }
        guard let data = try? Data(contentsOf: folder(for: slug).appending(path: move.rawValue + ".png")) else { return nil }
        let frames = PetdexSprite.frames(fromStrip: data)
        frameCache[key] = frames
        frameOrder.append(key)
        // A few pets' current moves; each strip is about 1 MB once drawn.
        while frameOrder.count > 24 { frameCache[frameOrder.removeFirst()] = nil }
        return frames
    }

    private func forgetFrames(_ key: String) {
        frameCache[key] = nil
        frameOrder.removeAll { $0 == key }
    }

    /// One folder per pet, named by a hash so any slug is a safe file name.
    private func folder(for slug: String) -> URL {
        let name = SHA256.hash(data: Data(slug.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name, directoryHint: .isDirectory)
    }

    private func persist() {
        defaults.set(assignments, forKey: Self.storageKey)
    }
}

/// A petdex pet playing one move, pixel-sharp. Reduce Motion holds the first frame.
struct PetdexAnimatedAvatar: View {
    let frames: [CGImage]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion || frames.count < 2 {
            frame(0)
        } else {
            let step = PetdexSprite.loopDuration / Double(PetdexSprite.framesPerMove)
            TimelineView(.animation(minimumInterval: step)) { context in
                frame(Int(context.date.timeIntervalSinceReferenceDate / step) % frames.count)
            }
        }
    }

    private func frame(_ index: Int) -> some View {
        Image(decorative: frames[min(index, frames.count - 1)], scale: 1)
            .resizable()
            .interpolation(.none)
            .aspectRatio(contentMode: .fit)
    }
}
