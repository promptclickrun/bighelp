import Foundation

/// Chats once had backgrounds of their own (a color or a photo, from ⋯ › Chat appearance).
/// That's gone. Launch deletes what it saved: a choice per chat in UserDefaults and the
/// photos in the data folder.
enum RetiredChatAppearance {
    static let keyPrefix = "loopdy.session-appearance.v1."
    static let removedKey = "bighelp.chat-appearance.removed"

    static func removeSavedData(defaults: UserDefaults = .standard, dataDirectory: URL) {
        guard !defaults.bool(forKey: removedKey) else { return }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
        let photos = dataDirectory.appending(path: "session-appearance", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: photos.path) {
            guard (try? FileManager.default.removeItem(at: photos)) != nil else { return }
        }
        defaults.set(true, forKey: removedKey)
    }
}
