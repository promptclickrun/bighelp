import Foundation
import UIKit

/// A speech model that runs on this iPhone or iPad instead of the computer. Voice settings list
/// each one under "Runs on this iPhone"; an agent that uses one speaks with no account, key or
/// internet. Phonon is the first; another model is one more entry in `all`.
struct OnDeviceVoiceModel: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    /// The model's full name, shown beside its provider row.
    let detail: String
    /// A pinned release archive, checked against `archiveSHA256` before it's opened.
    let archiveURL: URL
    let archiveSHA256: String
    let archiveBytes: Int64
    /// The folder in the archive that holds the model (and its `bundle.json`).
    let archiveFolder: String
    let defaultVoice: String
    /// Voices listed under Characters rather than Voices.
    let characterVoices: Set<String>

    /// The provider ID in Voice settings. Never sent to the computer, and unlike any Hermes
    /// provider name, so a computer's own `phonon` command stays its own row.
    var providerID: String { "device-" + id }

    /// Phonon 31m English (Gradium), Apache 2.0. The 40m models are CC BY-NC: never list them.
    static let phonon = OnDeviceVoiceModel(
        id: "phonon-31m-en",
        title: "Phonon",
        detail: "Phonon 31m English",
        archiveURL: URL(string: "https://github.com/gradium-ai/xn-ptts/releases/download/v0.5.0/phonon-31m-en-coreml.zip")!,
        archiveSHA256: "10f3a99fd39256db44f826267ef21d78cca959b16c0554926344c09fde27b436",
        archiveBytes: 137_096_081,
        archiveFolder: "phonon-31m-en-coreml",
        defaultVoice: "default",
        characterVoices: [
            "Azgorath", "Captain Silas Blackwater", "Fairy Godmother", "Fennick the Young Elf",
            "Grub the Ogre", "Master Aldric", "Morwenna of the Deep", "Old Mortlake", "Sir Bramwell",
            "The Snow Queen", "The Thing Under the Stairs", "Vyrmathrax the Ancient",
        ]
    )

    static let all = [phonon]

    static func model(providerID: String) -> OnDeviceVoiceModel? {
        all.first { $0.providerID == providerID }
    }

    static func model(id: String) -> OnDeviceVoiceModel? {
        all.first { $0.id == id }
    }

    /// "Default" for the model's own voice; other names as the model has them.
    func voiceTitle(_ voice: String) -> String {
        voice == defaultVoice ? String(localized: "Default") : voice
    }

    /// The download's size as people read it: "137 MB".
    var downloadSize: String {
        ByteCountFormatter.string(fromByteCount: archiveBytes, countStyle: .file)
    }

    /// "iPhone" or "iPad", for "Runs on this iPhone".
    @MainActor static var deviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }
}

/// Which agents speak on this device, and in which voice: per computer and agent, kept on the
/// device and never sent to the computer, whose own speech provider stays as it was.
@MainActor
final class OnDeviceVoiceChoices {
    struct Choice: Codable, Equatable, Sendable {
        let modelID: String
        let voice: String
    }

    static let shared = OnDeviceVoiceChoices()
    static let key = "bighelp.voice.on-device-choices"
    /// A bound, far above real use: past it, one saved entry makes room for the new one.
    static let limit = 256

    private let defaults: UserDefaults
    private var saved: [String: Choice]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        saved = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: Choice].self, from: $0) } ?? [:]
    }

    /// `computer` is the connection's `cacheScopeID`.
    func choice(computer: String, agentID: String) -> Choice? {
        saved[Self.entry(computer, agentID)]
    }

    func set(_ choice: Choice?, computer: String, agentID: String) {
        let entry = Self.entry(computer, agentID)
        guard saved[entry] != choice else { return }
        saved[entry] = nil
        if let choice {
            if saved.count >= Self.limit, let oldest = saved.keys.sorted().first { saved[oldest] = nil }
            saved[entry] = choice
        }
        defaults.set(try? JSONEncoder().encode(saved), forKey: Self.key)
    }

    private static func entry(_ computer: String, _ agentID: String) -> String {
        "\(computer.utf8.count):\(computer)\(agentID)"
    }
}
