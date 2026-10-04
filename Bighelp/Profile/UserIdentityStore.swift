import Foundation
import Observation

struct UserIdentity: Codable, Equatable, Sendable {
    static let stableID = "local-user"
    /// Names reach agents too, so they stay short: 40 visible characters fits
    /// nearly any full name, including two given names or two surnames.
    static let maximumNameLength = 40
    /// Shown on your own messages and avatar before you save a name. Never
    /// sent to a host, so an agent can't mistake it for your name.
    static let placeholderName = "You"

    /// The name you saved, or empty.
    var name: String
    var avatarFileName: String?
}

extension UserIdentity {
    /// What the app shows for you: your name, or "You" before you've saved one.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.placeholderName : trimmed
    }

    /// A name as it's saved: trimmed and at most `maximumNameLength` characters.
    static func savedName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumNameLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case avatarFileName
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try container.decode(String.self, forKey: .name)
        // Before names reached agents, a new install was saved as "You". That was
        // never a name anyone typed, so it reads as no name.
        name = saved == Self.placeholderName ? "" : saved
        avatarFileName = try container.decodeIfPresent(String.self, forKey: .avatarFileName)
    }
}

@MainActor
@Observable
final class UserIdentityStore {
    var identity: UserIdentity {
        didSet {
            mutationGeneration = UUID()
            save(identity)
        }
    }

    // Not observed: changing ownership must not recursively mutate identity.
    @ObservationIgnored private(set) var mutationGeneration = UUID()

    enum ProfileSaveError: Error, LocalizedError {
        case avatarStorageUnavailable

        var errorDescription: String? {
            switch self {
            case .avatarStorageUnavailable: "We couldn’t save that photo. Try again."
            }
        }
    }

    private let defaults: UserDefaults
    let avatarDirectory: URL?

    init(defaults: UserDefaults = .standard, avatarDirectory: URL? = nil) {
        self.defaults = defaults
        self.avatarDirectory = avatarDirectory
        identity = Self.load(from: defaults)
    }

    func avatarURL(for identity: UserIdentity? = nil) -> URL? {
        AvatarFileURL.resolve(fileName: (identity ?? self.identity).avatarFileName, in: avatarDirectory)
    }

    /// Saves your name. An empty name removes it.
    func saveDisplayName(_ name: String) {
        identity.name = UserIdentity.savedName(name)
    }

    func saveAvatar(_ avatar: PreparedAvatar) throws {
        guard let avatarDirectory else { throw ProfileSaveError.avatarStorageUnavailable }
        identity.avatarFileName = try AvatarImageProcessor().store(avatar, in: avatarDirectory)
    }

    /// The name saved on this device, read without a store (for screens that don't hold one).
    static func savedName(in defaults: UserDefaults = .standard) -> String {
        load(from: defaults).name
    }

    private static func load(from defaults: UserDefaults) -> UserIdentity {
        guard
            let data = defaults.data(forKey: Keys.identity),
            let identity = try? JSONDecoder().decode(UserIdentity.self, from: data)
        else {
            return UserIdentity(name: "", avatarFileName: nil)
        }
        return identity
    }

    private func save(_ identity: UserIdentity) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        defaults.set(data, forKey: Keys.identity)
    }
}

private extension UserIdentityStore {
    enum Keys {
        static let identity = "loopdy.demo.userIdentity"
    }
}
