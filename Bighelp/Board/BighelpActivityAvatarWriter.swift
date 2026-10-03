import CryptoKit
import UIKit

/// Writes a small copy of an agent's picture to the shared app group for the
/// Live Activity. Rewrites only when the picture changed.
enum BighelpActivityAvatarWriter {
    static func write(agentID: String, from source: URL) {
        guard let destination = BighelpActivityAvatarStore.fileURL(agentID: agentID) else { return }
        write(source, to: destination)
    }

    /// A square copy at `BighelpActivityAvatarStore.pixelSize`, filled to the edges.
    /// False when the source isn't a picture or the copy would be too big.
    @discardableResult
    static func write(_ source: URL, to destination: URL) -> Bool {
        guard let data = try? Data(contentsOf: source), data.count <= 16_777_216,
              let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return false }
        let side = CGFloat(BighelpActivityAvatarStore.pixelSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let scale = max(side / image.size.width, side / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                  width: size.width, height: size.height))
        }
        guard let png = resized.pngData(), png.count <= 262_144 else { return false }
        if let existing = try? Data(contentsOf: destination), existing == png { return true }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try png.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }
}

/// Pinned agents' pictures for the Pinned Agents widget: one per agent and
/// computer, so two computers' "default" agents keep their own faces. Only
/// the pictures of agents still pinned stay.
enum BighelpPinnedAvatarWriter {
    /// A file name that says nothing about the agent or computer.
    static func key(hostID: UUID?, agentID: String) -> String {
        let digest = SHA256.hash(data: Data(((hostID?.uuidString ?? "this-computer") + "/" + agentID).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes `pictures` (key → the agent's picture on this device) and removes
    /// every other file in the folder. At most `BighelpPinnedAvatarStore.maximumFiles`.
    static func sync(_ pictures: [String: URL], in directory: URL? = BighelpPinnedAvatarStore.directory) {
        guard let directory else { return }
        var kept: Set<String> = []
        for key in pictures.keys.sorted().prefix(BighelpPinnedAvatarStore.maximumFiles) {
            guard let source = pictures[key],
                  let destination = BighelpPinnedAvatarStore.fileURL(key: key, in: directory) else { continue }
            if BighelpActivityAvatarWriter.write(source, to: destination) {
                kept.insert(destination.lastPathComponent)
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where !kept.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file, isDirectory: false))
        }
    }
}
