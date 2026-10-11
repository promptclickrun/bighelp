import Foundation
import Observation

struct VoiceProviderConfiguration: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let voiceID: String
    let apiKeyConfigured: Bool
    var model = ""
    var serverURL = ""
    var kind: VoiceProviderSpec.Kind = .cloud
    var hasVoice = true
    var hasModel = false
    var needsAPIKey = true
    var supportsServerURL = false
}

struct VoiceSettingsConfiguration: Equatable, Sendable {
    let revision: String
    let providerID: String
    let providers: [VoiceProviderConfiguration]
}

struct VoiceSettingsUpdate: Equatable, Sendable {
    let expectedRevision: String
    let providerID: String
    let voiceID: String
    let apiKey: String?
    /// nil leaves the host's value alone.
    var model: String? = nil
    /// nil leaves the host's value alone; "" goes back to the provider's own server.
    var serverURL: String? = nil
}

@MainActor
protocol VoiceSettingsClient: AnyObject {
    func load(agentID: String) async throws -> VoiceSettingsConfiguration
    func update(agentID: String, settings: VoiceSettingsUpdate) async throws -> VoiceSettingsConfiguration
    /// Speaks a short line with the agent's saved voice, through the host.
    func playSample(agentID: String) async throws
}

extension VoiceSettingsClient {
    func playSample(agentID: String) async throws { throw VoiceSettingsError.unsupported }
}

enum VoiceSettingsError: Error {
    case unavailable, unsupported, conflict, invalidResponse
}

@MainActor @Observable
final class VoiceSettingsStore {
    let agentID: String
    private(set) var providerID = ""
    var voiceID = "" { didSet { if voiceID != oldValue { edited() } } }
    var apiKey = "" { didSet { if apiKey != oldValue { edited() } } }
    var model = "" { didSet { if model != oldValue { edited() } } }
    var serverURL = "" { didSet { if serverURL != oldValue { edited() } } }
    private(set) var isPlayingSample = false
    private(set) var sampleError: String?
    private(set) var configuration: VoiceSettingsConfiguration?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var confirmation: String?
    @ObservationIgnored private let client: any VoiceSettingsClient
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool

    init(agentID: String, client: any VoiceSettingsClient,
         isCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.agentID = agentID
        self.client = client
        self.isCurrent = isCurrent
    }

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var editRevision = 0

    var selectedProvider: VoiceProviderConfiguration? {
        configuration?.providers.first { $0.id == providerID }
    }

    var canSave: Bool {
        guard isCurrent(), !isLoading, !isSaving, let configuration, let selectedProvider,
              !selectedProvider.hasVoice || (!normalizedVoice.isEmpty && Self.validText(normalizedVoice, 160)),
              Self.validText(normalizedModel, 160),
              normalizedServerURL.isEmpty || Self.validServerURL(normalizedServerURL),
              Self.validText(normalizedKey, 4096),
              !selectedProvider.needsAPIKey || selectedProvider.apiKeyConfigured || !normalizedKey.isEmpty
        else { return false }
        return providerID != configuration.providerID || changedVoice || changedModel != nil
            || changedServerURL != nil || !normalizedKey.isEmpty
    }

    /// Unsaved edits: a sample plays what the host has saved.
    var hasUnsavedChanges: Bool {
        guard let configuration, let selectedProvider else { return false }
        return providerID != configuration.providerID || changedVoice
            || (selectedProvider.hasModel && normalizedModel != selectedProvider.model)
            || (selectedProvider.supportsServerURL && normalizedServerURL != selectedProvider.serverURL)
            || !normalizedKey.isEmpty
    }

    var canPlaySample: Bool {
        isCurrent() && configuration != nil && !isLoading && !isSaving && !isPlayingSample && !hasUnsavedChanges
    }

    private var changedVoice: Bool {
        selectedProvider?.hasVoice == true && normalizedVoice != selectedProvider?.voiceID
    }

    private var changedModel: String? {
        guard let selectedProvider, selectedProvider.hasModel, normalizedModel != selectedProvider.model else { return nil }
        return normalizedModel
    }

    private var changedServerURL: String? {
        guard let selectedProvider, selectedProvider.supportsServerURL,
              normalizedServerURL != selectedProvider.serverURL else { return nil }
        return normalizedServerURL
    }

    func load() async {
        guard isCurrent(), !isSaving, !isLoading else { return }
        generation += 1
        let request = generation
        let edits = editRevision
        isLoading = true
        errorMessage = nil
        confirmation = nil
        defer { if generation == request { isLoading = false } }
        do {
            let value = try await client.load(agentID: agentID)
            guard generation == request, isCurrent(), !Task.isCancelled else { return }
            configuration = value
            if editRevision == edits {
                providerID = value.providerID
                fillFromSelectedProvider()
            }
        } catch {
            guard generation == request, isCurrent(), !Task.isCancelled else { return }
            errorMessage = message(for: error, saving: false)
        }
    }

    private func fillFromSelectedProvider() {
        voiceID = selectedProvider?.voiceID ?? ""
        model = selectedProvider?.model ?? ""
        serverURL = selectedProvider?.serverURL ?? ""
        apiKey = ""
    }

    func selectProvider(_ id: String) {
        guard id != providerID, !isSaving, configuration?.providers.contains(where: { $0.id == id }) == true else { return }
        providerID = id
        fillFromSelectedProvider()
        sampleError = nil
        edited()
    }

    func save() async {
        guard canSave, let configuration else { return }
        let update = VoiceSettingsUpdate(expectedRevision: configuration.revision,
            providerID: providerID, voiceID: selectedProvider?.hasVoice == true ? normalizedVoice : "",
            apiKey: normalizedKey.isEmpty ? nil : normalizedKey,
            model: changedModel, serverURL: changedServerURL)
        let request = generation
        let edits = editRevision
        isSaving = true
        errorMessage = nil
        confirmation = nil
        defer { if generation == request { isSaving = false } }
        do {
            let value = try await client.update(agentID: agentID, settings: update)
            guard generation == request, isCurrent(), !Task.isCancelled else { return }
            guard value.providerID == update.providerID,
                  let saved = value.providers.first(where: { $0.id == update.providerID }),
                  !saved.hasVoice || saved.voiceID == update.voiceID,
                  !saved.needsAPIKey || saved.apiKeyConfigured else {
                throw VoiceSettingsError.invalidResponse
            }
            self.configuration = value
            if editRevision == edits {
                providerID = value.providerID
                fillFromSelectedProvider()
                confirmation = "Voice settings saved."
            }
        } catch {
            guard generation == request, isCurrent(), !Task.isCancelled else { return }
            errorMessage = message(for: error, saving: true)
        }
    }

    /// Speaks a short line with the saved voice, so a person hears the provider
    /// actually works on their computer before relying on it.
    func playSample() async {
        guard canPlaySample else { return }
        let request = generation
        isPlayingSample = true
        sampleError = nil
        confirmation = nil
        defer { if generation == request { isPlayingSample = false } }
        do {
            try await client.playSample(agentID: agentID)
        } catch {
            guard generation == request, isCurrent(), !Task.isCancelled else { return }
            sampleError = sampleMessage(for: error)
        }
    }

    func invalidate() {
        generation += 1
        configuration = nil
        providerID = ""
        voiceID = ""
        model = ""
        serverURL = ""
        isPlayingSample = false
        sampleError = nil
        apiKey = ""
        isLoading = false
        isSaving = false
        errorMessage = nil
        confirmation = nil
    }

    func clearAPIKey() {
        // Privacy cleanup is not a new user edit. A save already in flight may
        // still confirm its accepted provider/voice after the secret is erased.
        let revision = editRevision
        apiKey = ""
        editRevision = revision
    }
    private var normalizedVoice: String { voiceID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var normalizedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var normalizedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var normalizedServerURL: String { serverURL.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func validText(_ value: String, _ maximum: Int) -> Bool {
        value.utf8.count <= maximum && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func validServerURL(_ value: String) -> Bool {
        guard validText(value, 512), let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { return false }
        return true
    }

    private func sampleMessage(for error: any Error) -> String {
        if case VoiceSettingsError.unsupported = error {
            return "Update the bighelp plugin on this host to play samples."
        }
        let title = selectedProvider?.title ?? "This provider"
        switch error {
        case DirectHermesVoiceError.hostRestartRequired:
            return "\(title) is installed on your computer now. Restart Hermes there, then play the sample again."
        case DirectHermesVoiceError.voicePackageMissing(let extra?):
            return "Hermes couldn't install \(title) on your computer. Run hermes pm install --extra \(extra) there, then restart Hermes."
        case DirectHermesVoiceError.voicePackageMissing:
            return "Hermes couldn't install \(title) on your computer. Run hermes setup tts there."
        default: break
        }
        switch selectedProvider?.kind {
        case .onYourComputer:
            return "Couldn't play a sample. Make sure \(title) is installed on your computer: run hermes setup tts there."
        case .cloud:
            return "Couldn't play a sample. Check the API key and voice for \(title), then try again."
        default:
            return "Couldn't play a sample. Check \(title) on your computer, then try again."
        }
    }
    private func edited() {
        editRevision += 1
        confirmation = nil
    }
    private func message(for error: any Error, saving: Bool) -> String {
        switch error {
        case VoiceSettingsError.unsupported:
            "Update the bighelp plugin on this host to edit voice settings."
        case VoiceSettingsError.conflict:
            "Voice settings changed on the host. Reload them before saving again."
        default:
            saving ? "Voice settings could not be saved. Your edits are still here."
                : "Voice settings could not be loaded. Try again when the host is connected."
        }
    }
}
