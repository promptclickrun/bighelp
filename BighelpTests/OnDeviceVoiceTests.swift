import Foundation
import Testing
@testable import Bighelp

/// Archives made by a script with Python's zipfile: `model.zip` holds `tiny-model/` (stored and
/// deflated files, a `bundle.json` listing them) and an unrelated `other/` folder.
private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "Fixtures/OnDeviceVoice", directoryHint: .isDirectory)

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "on-device-voice-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct ZipArchiveExtractorTests {
    @Test func unpacksOneFolderOfStoredAndDeflatedFiles() throws {
        let out = try temporaryDirectory()
        try ZipArchiveExtractor.extract(fixtures.appending(path: "model.zip"), folder: "tiny-model", to: out)

        let weights = try Data(contentsOf: out.appending(path: "weights.bin"))
        #expect(weights == Data(String(repeating: "phonon-fixture-weights ", count: 400).utf8))
        #expect(try String(contentsOf: out.appending(path: "voices/Grub the Ogre.safetensors"), encoding: .utf8)
            == "grub voice fixture")
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "other").path))
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "tiny-model").path))
    }

    @Test func refusesAPathThatLeavesTheFolder() throws {
        let parent = try temporaryDirectory()
        let out = parent.appending(path: "model")
        #expect(throws: ZipArchiveExtractor.Failure.unsafePath("tiny-model/../escape.txt")) {
            try ZipArchiveExtractor.extract(fixtures.appending(path: "traversal.zip"), folder: "tiny-model", to: out)
        }
        #expect(!FileManager.default.fileExists(atPath: parent.appending(path: "escape.txt").path))
    }

    @Test func refusesWhatIsntAZip() throws {
        let folder = try temporaryDirectory()
        let file = folder.appending(path: "not.zip")
        try Data("plain text, not an archive".utf8).write(to: file)
        #expect(throws: ZipArchiveExtractor.Failure.notAZip) {
            try ZipArchiveExtractor.extract(file, folder: "tiny-model", to: folder.appending(path: "out"))
        }
    }
}

@MainActor
struct OnDeviceVoiceInstallerTests {
    @Test func installsAnArchiveThatMatchesItsChecksumAndFileList() throws {
        let root = try temporaryDirectory()
        let archive = fixtures.appending(path: "model.zip")
        let model = try tinyModel(archive)
        let installer = OnDeviceVoiceInstaller(root: root)
        #expect(installer.state(of: model) == .notInstalled)

        try OnDeviceVoiceInstaller.unpack(archive, model: model, into: installer.directory(for: model))

        #expect(OnDeviceVoiceInstaller.isComplete(installer.directory(for: model)))
        #expect(try installer.directory(for: model).resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup == true)
        let fresh = OnDeviceVoiceInstaller(root: root)
        #expect(fresh.state(of: model) == .installed)
        #expect(fresh.voices(for: model) == ["default", "Grub the Ogre", "Zoey"])
    }

    @Test func aDownloadThatDoesntMatchItsChecksumInstallsNothing() throws {
        let root = try temporaryDirectory()
        let archive = fixtures.appending(path: "model.zip")
        let model = try tinyModel(archive, sha256: String(repeating: "0", count: 64))
        let destination = root.appending(path: model.id)
        #expect(throws: OnDeviceVoiceInstaller.InstallError.checksum) {
            try OnDeviceVoiceInstaller.unpack(archive, model: model, into: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func aModelMissingFilesInstallsNothing() throws {
        let root = try temporaryDirectory()
        let archive = fixtures.appending(path: "incomplete.zip")
        let model = try tinyModel(archive)
        let destination = root.appending(path: model.id)
        #expect(throws: (any Error).self) {
            try OnDeviceVoiceInstaller.unpack(archive, model: model, into: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: model.id + ".partial").path))
    }

    private func tinyModel(_ archive: URL, sha256: String? = nil) throws -> OnDeviceVoiceModel {
        OnDeviceVoiceModel(
            id: "tiny", title: "Tiny", detail: "Tiny test model", archiveURL: archive,
            archiveSHA256: try sha256 ?? OnDeviceVoiceInstaller.sha256(of: archive),
            archiveBytes: 1_381, archiveFolder: "tiny-model", defaultVoice: "default",
            characterVoices: ["Grub the Ogre"])
    }
}

@MainActor
struct OnDeviceVoiceSettingsTests {
    private let phonon = OnDeviceVoiceModel.phonon.providerID

    @Test func listsThisDevicesVoiceFirstWithoutChangingTheComputersChoice() async throws {
        let (client, _, _) = try make()
        let loaded = try await client.load(agentID: "finance")
        #expect(loaded.providers.first?.id == phonon)
        #expect(loaded.providers.first?.kind == .onThisDevice)
        #expect(loaded.providers.first?.needsAPIKey == false)
        #expect(loaded.providerID == "openai")
    }

    @Test func choosingThisDevicesVoiceIsSavedOnTheDeviceForThatAgentOnly() async throws {
        let (client, host, choices) = try make()
        let loaded = try await client.load(agentID: "finance")
        let saved = try await client.update(agentID: "finance", settings: VoiceSettingsUpdate(
            expectedRevision: loaded.revision, providerID: phonon, voiceID: "Zoey", apiKey: nil))

        #expect(saved.providerID == phonon)
        #expect(saved.providers.first?.voiceID == "Zoey")
        #expect(choices.choice(computer: "computer-a", agentID: "finance") == .init(modelID: "phonon-31m-en", voice: "Zoey"))
        #expect(choices.choice(computer: "computer-a", agentID: "travel") == nil)
        #expect(choices.choice(computer: "computer-b", agentID: "finance") == nil)
        #expect(try await host.load(agentID: "finance").providerID == "openai",
                "The computer's own provider changed")
    }

    @Test func choosingAComputerProviderAgainClearsThisDevicesVoice() async throws {
        let (client, host, choices) = try make()
        choices.set(.init(modelID: "phonon-31m-en", voice: "Zoey"), computer: "computer-a", agentID: "finance")
        let loaded = try await client.load(agentID: "finance")
        #expect(loaded.providerID == phonon)

        let saved = try await client.update(agentID: "finance", settings: VoiceSettingsUpdate(
            expectedRevision: loaded.revision, providerID: "edge", voiceID: "en-US-AriaNeural", apiKey: nil))

        #expect(saved.providerID == "edge")
        #expect(choices.choice(computer: "computer-a", agentID: "finance") == nil)
        #expect(try await host.load(agentID: "finance").providerID == "edge")
    }

    @Test func aChoiceMadeElsewhereSinceLoadingIsAConflict() async throws {
        let (client, _, choices) = try make()
        let loaded = try await client.load(agentID: "finance")
        choices.set(.init(modelID: "phonon-31m-en", voice: "Hugh"), computer: "computer-a", agentID: "finance")
        await #expect(throws: VoiceSettingsError.conflict) {
            try await client.update(agentID: "finance", settings: VoiceSettingsUpdate(
                expectedRevision: loaded.revision, providerID: phonon, voiceID: "Zoey", apiKey: nil))
        }
    }

    @Test func choicesStayOnTheDevice() throws {
        let defaults = try freshDefaults()
        OnDeviceVoiceChoices(defaults: defaults)
            .set(.init(modelID: "phonon-31m-en", voice: "Sir Bramwell"), computer: "computer-a", agentID: "finance")
        #expect(OnDeviceVoiceChoices(defaults: defaults).choice(computer: "computer-a", agentID: "finance")?.voice
            == "Sir Bramwell")
    }

    /// Save stays off until the voice is downloaded: it would have nothing to speak with.
    @Test func savingThisDevicesVoiceWaitsForItsDownload() async throws {
        let (client, _, _) = try make()
        let ready = ReadyFlag()
        let store = VoiceSettingsStore(agentID: "finance", client: client, isOnDeviceReady: { _ in ready.value })
        await store.load()
        store.selectProvider(phonon)
        #expect(!store.canSave)
        ready.value = true
        #expect(store.canSave)
    }

    @Test func speaksWithTheComputerWhileThisDevicesVoiceIsntDownloaded() async throws {
        let host = ReplySpeechSpy()
        let engine = OnDeviceSpeechEngine(installer: OnDeviceVoiceInstaller(root: try temporaryDirectory()))
        let output = OnDeviceRoutedSpeechOutput(host: host, engine: engine) {
            .init(modelID: "phonon-31m-en", voice: "Zoey")
        }
        try await output.speak("Hello there.", rate: 1)
        #expect(host.spoken == ["Hello there."])
        output.stop()
        #expect(host.stops == 1)
    }

    private func make() throws -> (OnDeviceVoiceSettingsClient, VoiceSettingsPreviewClient, OnDeviceVoiceChoices) {
        let host = VoiceSettingsPreviewClient()
        let choices = OnDeviceVoiceChoices(defaults: try freshDefaults())
        return (OnDeviceVoiceSettingsClient(host: host, computer: "computer-a", choices: choices), host, choices)
    }

    private func freshDefaults() throws -> UserDefaults {
        let suite = "on-device-voice-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

@MainActor
private final class ReadyFlag {
    var value = false
}
