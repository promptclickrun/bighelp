import Foundation

/// A credential returned by Hermes' client-direct voice resolver. This type is
/// intentionally reference-only, non-Codable, and non-printable. Its value is
/// available only to a synchronous request builder and is cleared on retirement.
@MainActor
final class DirectHermesEphemeralVoiceCredential {
    private var storage: String?

    init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 16_384,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceClientError.invalidResponse
        }
        storage = value
    }

    var isAvailable: Bool { storage != nil }

    func withValue<Result>(_ body: (String) throws -> Result) throws -> Result {
        guard let storage else { throw WorkspaceClientError.ownerChanged }
        return try body(storage)
    }

    func invalidate() {
        storage?.removeAll(keepingCapacity: false)
        storage = nil
    }

    deinit {
        storage?.removeAll(keepingCapacity: false)
        storage = nil
    }
}

enum DirectHermesVoiceDirection: String, Sendable {
    case speechToText
    case textToSpeech
}

enum DirectHermesVoiceProviderWire: String, Sendable {
    case openAIMultipart = "openai-multipart"
    case xAIStt = "xai-stt"
    case elevenLabsStt = "elevenlabs-stt"
    case openAISpeech = "openai-speech"
    case elevenLabsTts = "elevenlabs-tts"

    func supports(_ direction: DirectHermesVoiceDirection) -> Bool {
        switch (self, direction) {
        case (.openAIMultipart, .speechToText), (.xAIStt, .speechToText),
             (.elevenLabsStt, .speechToText), (.openAISpeech, .textToSpeech),
             (.elevenLabsTts, .textToSpeech):
            true
        default:
            false
        }
    }
}

@MainActor
final class DirectHermesVoiceDirectConfiguration {
    let direction: DirectHermesVoiceDirection
    let wire: DirectHermesVoiceProviderWire
    let providerID: String
    let baseURL: URL
    let modelID: String?
    let language: String?
    let voiceID: String?
    let speed: Double?
    let credential: DirectHermesEphemeralVoiceCredential

    init(
        direction: DirectHermesVoiceDirection,
        wire: DirectHermesVoiceProviderWire,
        providerID: String,
        baseURL: URL,
        modelID: String?,
        language: String?,
        voiceID: String?,
        speed: Double?,
        credential: DirectHermesEphemeralVoiceCredential
    ) {
        self.direction = direction
        self.wire = wire
        self.providerID = providerID
        self.baseURL = baseURL
        self.modelID = modelID
        self.language = language
        self.voiceID = voiceID
        self.speed = speed
        self.credential = credential
    }

    func invalidate() {
        credential.invalidate()
    }
}

@MainActor
enum DirectHermesVoiceRouteConfiguration {
    case relay(reason: String?)
    case direct(DirectHermesVoiceDirectConfiguration)

    var isClientDirect: Bool {
        if case .direct = self { return true }
        return false
    }

    var providerID: String? {
        guard case .direct(let configuration) = self else { return nil }
        return configuration.providerID
    }

    var wire: DirectHermesVoiceProviderWire? {
        guard case .direct(let configuration) = self else { return nil }
        return configuration.wire
    }

    func invalidate() {
        if case .direct(let configuration) = self { configuration.invalidate() }
    }
}

/// Screen-lifetime snapshot. Call `invalidate()` when its host/profile owner,
/// scene, or presentation retires. No credential-bearing value is Codable,
/// written to defaults, logged, or copied into an observable display string.
@MainActor
final class DirectHermesVoiceConfigurationSnapshot {
    let speechToText: DirectHermesVoiceRouteConfiguration
    let textToSpeech: DirectHermesVoiceRouteConfiguration
    private(set) var isInvalidated = false

    init(
        speechToText: DirectHermesVoiceRouteConfiguration,
        textToSpeech: DirectHermesVoiceRouteConfiguration
    ) {
        self.speechToText = speechToText
        self.textToSpeech = textToSpeech
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        speechToText.invalidate()
        textToSpeech.invalidate()
    }

}

struct DirectHermesVoiceDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let label: String
}

struct DirectHermesVoiceCatalog: Equatable, Sendable {
    let isAvailable: Bool
    let voices: [DirectHermesVoiceDescriptor]
    let unavailableReason: String?
}

enum DirectHermesSelectableVoiceProvider: String, CaseIterable, Identifiable, Sendable {
    case openAI = "openai"
    case elevenLabs = "elevenlabs"

    var id: String { rawValue }
    var title: String { self == .openAI ? "OpenAI TTS" : "ElevenLabs" }
}

struct DirectHermesVoiceSelection: Equatable, Sendable {
    let provider: DirectHermesSelectableVoiceProvider
    let voiceID: String
}

struct DirectHermesTTSLease: Identifiable, Hashable, Sendable {
    enum Purpose: String, Sendable {
        case readAloud = "read-aloud"
        case preview
    }

    let id: String
    let purpose: Purpose

    init(purpose: Purpose) {
        self.purpose = purpose
        id = "loopdy-ios:\(purpose.rawValue):\(UUID().uuidString.lowercased())"
    }
}

struct DirectHermesTTSLeaseReceipt: Equatable, Sendable {
    let leaseID: String
    let isActive: Bool
    let action: String
    let activeLeaseCount: Int?
    let providerID: String?
    let warmed: Bool?
    let failedToWarm: Bool
}

struct DirectHermesVoiceRecording: Sendable {
    static let maximumHostBytes = 25 * 1_024 * 1_024

    let bytes: Data
    let mimeType: String

    init(bytes: Data, mimeType: String) throws {
        let normalized = mimeType.split(separator: ";", maxSplits: 1)
            .first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let supported = [
            "audio/aac", "audio/flac", "audio/m4a", "audio/mp3", "audio/mp4",
            "audio/mpeg", "audio/ogg", "audio/wav", "audio/wave", "audio/webm",
            "audio/x-m4a", "audio/x-wav", "video/webm",
        ]
        guard !bytes.isEmpty, bytes.count <= Self.maximumHostBytes,
              supported.contains(normalized) else {
            throw WorkspaceClientError.invalidRequest
        }
        self.bytes = bytes
        self.mimeType = normalized
    }
}

struct DirectHermesTranscription: Equatable, Sendable {
    let text: String
    let providerID: String?
    let usedClientDirectTransport: Bool
}

struct DirectHermesSynthesizedSpeech: Sendable {
    let audio: Data
    let mimeType: String
    let providerID: String?
    let usedClientDirectTransport: Bool
}

enum DirectHermesVoiceChatMode: String, Sendable {
    case chained
    case gptLive = "gpt-live"
}

struct DirectHermesStockLiveVoiceStatus: Equatable, Sendable {
    let mode: DirectHermesVoiceChatMode
    let isAvailable: Bool
    let reason: String?
    let modelID: String
    let voiceID: String
}

struct DirectHermesVoiceLiveHistoryMessage: Equatable, Sendable {
    enum Role: String, Sendable {
        case user, assistant, developer
    }

    let role: Role
    let text: String
}

struct DirectHermesStockLiveVoiceSession: Equatable, Sendable {
    let sessionID: String?
    let answerSDP: String
}

enum DirectHermesVoiceStreamResult: Equatable, Sendable {
    case played
    case fallbackRequired
}

enum DirectHermesVoiceConfigurationError: Error, LocalizedError, Equatable, Sendable {
    case inlineTranscriptionLimit(Int)
    case streamingTransportUnavailable
    case invalidProviderResponse

    var errorDescription: String? {
        switch self {
        case .inlineTranscriptionLimit(let bytes):
            "This recording is larger than the current authenticated inline limit of \(bytes) bytes. The full 25 MiB relay needs the fixed voice-media transport extension."
        case .streamingTransportUnavailable:
            "Streaming playback needs a fresh authenticated audio WebSocket. Buffered computer playback is still available."
        case .invalidProviderResponse:
            "The configured voice provider returned an unsupported response."
        }
    }
}

/// Parent integration seam for the stock host's full 25 MiB transcription route.
/// It is deliberately fixed to transcription bytes: no arbitrary URL, method,
/// header, or bearer can cross this protocol.
@MainActor
protocol DirectHermesVoiceRelayMediaHTTP: AnyObject {
    func transcribeVoice(
        profileID: String,
        recording: DirectHermesVoiceRecording
    ) async throws -> BighelpJSONValue
}

/// Parent integration seam for `/api/audio/speak-stream`. Its implementation
/// must mint a fresh ticket for this socket, enforce the existing Host/Origin
/// guards, accept only start/fallback/end JSON frames plus bounded Int16 PCM,
/// and own immediate stop. The main gateway WebSocket ticket cannot be reused.
@MainActor
protocol DirectHermesVoiceStreamingPlaybackTransport: AnyObject {
    func play(
        profileID: String,
        text: String,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws -> DirectHermesVoiceStreamResult
    func stop()
}

@MainActor
protocol DirectHermesClientVoiceProviderTransport: AnyObject {
    func transcribe(
        _ recording: DirectHermesVoiceRecording,
        using configuration: DirectHermesVoiceDirectConfiguration
    ) async throws -> DirectHermesTranscription

    func synthesize(
        _ text: String,
        using configuration: DirectHermesVoiceDirectConfiguration
    ) async throws -> DirectHermesSynthesizedSpeech
}

/// Executes only the five wire shapes returned by stock `voice-config`. The
/// session is ephemeral, redirects and shared credentials are disabled, all
/// base URLs must be HTTPS, and provider bodies are bounded before decoding.
@MainActor
final class DirectHermesURLSessionVoiceProviderTransport: DirectHermesClientVoiceProviderTransport {
    private static let maximumTranscriptBytes = 1 * 1_024 * 1_024
    private static let maximumSpeechBytes = BighelpLinkVoiceAudioChunk.maximumAudioBytes
    private static let maximumMultipartOverheadBytes = 16 * 1_024

    private let session: URLSession
    private let delegate: DirectHermesSessionDelegate

    init() {
        delegate = DirectHermesSessionDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func transcribe(
        _ recording: DirectHermesVoiceRecording,
        using configuration: DirectHermesVoiceDirectConfiguration
    ) async throws -> DirectHermesTranscription {
        guard configuration.direction == .speechToText,
              configuration.wire.supports(.speechToText),
              configuration.credential.isAvailable else {
            throw WorkspaceClientError.invalidRequest
        }
        let multipart = try Self.multipart(recording: recording, configuration: configuration)
        let path: [String]
        switch configuration.wire {
        case .openAIMultipart: path = ["audio", "transcriptions"]
        case .xAIStt: path = ["stt"]
        case .elevenLabsStt: path = ["speech-to-text"]
        default: throw WorkspaceClientError.invalidRequest
        }
        let url = try Self.endpoint(configuration.baseURL, appending: path)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = multipart.body
        request.httpShouldHandleCookies = false
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
        try configuration.credential.withValue { credential in
            switch configuration.wire {
            case .elevenLabsStt:
                request.setValue(credential, forHTTPHeaderField: "xi-api-key")
            default:
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            }
        }

        let response = try await send(request, maximumBytes: Self.maximumTranscriptBytes)
        let text: String
        switch configuration.wire {
        case .openAIMultipart:
            text = try Self.openAITranscript(response.body)
        case .xAIStt, .elevenLabsStt:
            let object = try Self.object(response.body)
            text = try Self.text(object["text"], maximum: Self.maximumTranscriptBytes)
        default:
            throw WorkspaceClientError.invalidRequest
        }
        return .init(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            providerID: configuration.providerID,
            usedClientDirectTransport: true
        )
    }

    func synthesize(
        _ text: String,
        using configuration: DirectHermesVoiceDirectConfiguration
    ) async throws -> DirectHermesSynthesizedSpeech {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.direction == .textToSpeech,
              configuration.wire.supports(.textToSpeech),
              configuration.credential.isAvailable,
              !normalized.isEmpty, normalized.utf8.count <= 20_000 else {
            throw WorkspaceClientError.invalidRequest
        }

        let url: URL
        let body: BighelpJSONValue
        switch configuration.wire {
        case .openAISpeech:
            url = try Self.endpoint(configuration.baseURL, appending: ["audio", "speech"])
            var fields: [String: BighelpJSONValue] = [
                "model": configuration.modelID.map(BighelpJSONValue.string) ?? .null,
                "voice": configuration.voiceID.map(BighelpJSONValue.string) ?? .null,
                "input": .string(normalized),
                "response_format": .string("mp3"),
            ]
            if let speed = configuration.speed, speed != 1 { fields["speed"] = .number(speed) }
            body = .object(fields)
        case .elevenLabsTts:
            guard let voice = configuration.voiceID, !voice.isEmpty else {
                throw WorkspaceClientError.invalidResponse
            }
            url = try Self.endpoint(configuration.baseURL, appending: ["text-to-speech", voice])
            body = .object([
                "text": .string(normalized),
                "model_id": configuration.modelID.map(BighelpJSONValue.string) ?? .null,
            ])
        default:
            throw WorkspaceClientError.invalidRequest
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        try configuration.credential.withValue { credential in
            if configuration.wire == .elevenLabsTts {
                request.setValue(credential, forHTTPHeaderField: "xi-api-key")
            } else {
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            }
        }
        let response = try await send(request, maximumBytes: Self.maximumSpeechBytes)
        guard !response.body.isEmpty else { throw DirectHermesVoiceConfigurationError.invalidProviderResponse }
        let mime = try Self.audioMIME(response.http.value(forHTTPHeaderField: "Content-Type"))
        return .init(
            audio: response.body,
            mimeType: mime,
            providerID: configuration.providerID,
            usedClientDirectTransport: true
        )
    }

    private func send(_ request: URLRequest, maximumBytes: Int) async throws -> (http: HTTPURLResponse, body: Data) {
        let expectedURL = request.url
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url == expectedURL else {
                bytes.task.cancel()
                throw DirectHermesError.redirectRefused
            }
            guard (200...299).contains(http.statusCode) else {
                bytes.task.cancel()
                throw WorkspaceClientError.rejected(code: String(http.statusCode))
            }
            guard http.expectedContentLength <= Int64(maximumBytes) else {
                bytes.task.cancel()
                throw WorkspaceClientError.capacityExceeded
            }
            var body = Data()
            body.reserveCapacity(max(0, min(maximumBytes, Int(http.expectedContentLength))))
            for try await byte in bytes {
                guard body.count < maximumBytes else {
                    bytes.task.cancel()
                    throw WorkspaceClientError.capacityExceeded
                }
                if body.count.isMultiple(of: 4_096) { try Task.checkCancellation() }
                body.append(byte)
            }
            return (http, body)
        } catch {
            if error is WorkspaceClientError || error is CancellationError { throw error }
            throw WorkspaceClientError.transportUnavailable
        }
    }

    private static func multipart(
        recording: DirectHermesVoiceRecording,
        configuration: DirectHermesVoiceDirectConfiguration
    ) throws -> (boundary: String, body: Data) {
        let boundary = try multipartBoundary(excluding: recording.bytes)
        var fields: [(String, String)] = []
        switch configuration.wire {
        case .openAIMultipart:
            if let model = configuration.modelID { fields.append(("model", model)) }
            fields.append(("response_format", "text"))
            if let language = configuration.language { fields.append(("language", language)) }
        case .xAIStt:
            fields.append(("format", "true"))
            if let language = configuration.language { fields.append(("language", language)) }
        case .elevenLabsStt:
            if let model = configuration.modelID { fields.append(("model_id", model)) }
            if let language = configuration.language { fields.append(("language_code", language)) }
        default:
            throw WorkspaceClientError.invalidRequest
        }
        for (_, value) in fields {
            guard value.utf8.count <= 1_024,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw WorkspaceClientError.invalidResponse
            }
        }

        var body = Data()
        body.reserveCapacity(recording.bytes.count + maximumMultipartOverheadBytes)
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"recording.\(fileExtension(recording.mimeType))\"\r\n".utf8))
        body.append(Data("Content-Type: \(recording.mimeType)\r\n\r\n".utf8))
        body.append(recording.bytes)
        for (name, value) in fields {
            body.append(Data("\r\n--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
        }
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        guard body.count <= DirectHermesVoiceRecording.maximumHostBytes + maximumMultipartOverheadBytes else {
            throw WorkspaceClientError.capacityExceeded
        }
        return (boundary, body)
    }

    private static func multipartBoundary(excluding bytes: Data) throws -> String {
        for _ in 0..<8 {
            let candidate = "BighelpVoice-\(UUID().uuidString)"
            if bytes.range(of: Data(candidate.utf8)) == nil { return candidate }
        }
        throw WorkspaceClientError.invalidRequest
    }

    private static func endpoint(_ baseURL: URL, appending path: [String]) throws -> URL {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host?.isEmpty == false,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw WorkspaceClientError.invalidResponse
        }
        var result = baseURL
        for component in path {
            guard !component.isEmpty, component.utf8.count <= 512,
                  !component.contains("/"), !component.contains("\\"),
                  !component.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw WorkspaceClientError.invalidRequest
            }
            result.append(path: component)
        }
        return result
    }

    private static func openAITranscript(_ data: Data) throws -> String {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw DirectHermesVoiceConfigurationError.invalidProviderResponse
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let object = try? object(data), let value = object["text"] {
            return try text(value, maximum: maximumTranscriptBytes)
        }
        guard trimmed.utf8.count <= maximumTranscriptBytes,
              !trimmed.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw DirectHermesVoiceConfigurationError.invalidProviderResponse
        }
        return trimmed
    }

    private static func object(_ data: Data) throws -> [String: BighelpJSONValue] {
        try DirectHermesWire.validateNesting(data)
        guard let value = try? JSONDecoder().decode(BighelpJSONValue.self, from: data),
              let object = value.object else {
            throw DirectHermesVoiceConfigurationError.invalidProviderResponse
        }
        return object
    }

    private static func text(_ value: BighelpJSONValue?, maximum: Int) throws -> String {
        guard let text = value?.string, text.utf8.count <= maximum,
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw DirectHermesVoiceConfigurationError.invalidProviderResponse
        }
        return text
    }

    private static func audioMIME(_ value: String?) throws -> String {
        let declared = value?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "audio/mpeg"
        let mime = declared == "application/octet-stream" ? "audio/mpeg" : declared
        guard mime.hasPrefix("audio/"), mime.utf8.count <= 128,
              !mime.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DirectHermesVoiceConfigurationError.invalidProviderResponse
        }
        return mime
    }

    private static func fileExtension(_ mimeType: String) -> String {
        switch mimeType {
        case "audio/mpeg", "audio/mp3": "mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": "m4a"
        case "audio/wav", "audio/wave", "audio/x-wav": "wav"
        case "video/webm": "webm"
        default: mimeType.split(separator: "/").last.map(String.init) ?? "audio"
        }
    }
}

@MainActor
final class DirectHermesVoiceConfigurationClient {
    /// The existing JSON constructor has a 1 MiB body ceiling. This conservative
    /// decoded cap leaves room for base64, the data-URL prefix, JSON escaping,
    /// and the MIME field. Larger relay recordings require the fixed media seam.
    static let maximumInlineTranscriptionBytes = 700 * 1_024

    private let http: any DirectHermesAuthenticatedHTTP
    private let relayMediaHTTP: (any DirectHermesVoiceRelayMediaHTTP)?
    private let streamingPlayback: (any DirectHermesVoiceStreamingPlaybackTransport)?
    private let providerTransport: any DirectHermesClientVoiceProviderTransport
    private let playback: any VoiceAudioPlayback
    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?

    init(
        http: any DirectHermesAuthenticatedHTTP,
        relayMediaHTTP: (any DirectHermesVoiceRelayMediaHTTP)? = nil,
        streamingPlayback: (any DirectHermesVoiceStreamingPlaybackTransport)? = nil,
        providerTransport: any DirectHermesClientVoiceProviderTransport = DirectHermesURLSessionVoiceProviderTransport(),
        playback: any VoiceAudioPlayback = AVAudioPlayerVoicePlayback(use: .playback),
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        self.http = http
        self.relayMediaHTTP = relayMediaHTTP
        self.streamingPlayback = streamingPlayback
        self.providerTransport = providerTransport
        self.playback = playback
        self.owner = owner
        self.currentOwner = currentOwner
    }

    var ownsScope: Bool { currentOwner() == owner && owner.authority.kind == .direct }
    var supportsFullRelayTranscription: Bool { relayMediaHTTP != nil }
    var supportsStreamingPlayback: Bool { streamingPlayback != nil }

    func loadConfiguration(profileID: String) async throws -> DirectHermesVoiceConfigurationSnapshot {
        let profile = try Self.profile(profileID)
        let response = try await request(.init(
            path: "/api/audio/voice-config", method: .get,
            query: [.init(name: "profile", value: profile)], maximumResponseBytes: 128 * 1_024
        ))
        let object = try DirectHermesAdministrationCodec.object(response)
        guard try DirectHermesAdministrationCodec.bool(object["ok"]) else { throw WorkspaceClientError.invalidResponse }
        let speechToText = try Self.route(object["stt"], direction: .speechToText)
        do {
            let textToSpeech = try Self.route(object["tts"], direction: .textToSpeech)
            return DirectHermesVoiceConfigurationSnapshot(
                speechToText: speechToText,
                textToSpeech: textToSpeech
            )
        } catch {
            speechToText.invalidate()
            throw error
        }
    }

    func loadVoiceSelection(profileID: String) async throws -> DirectHermesVoiceSelection? {
        let profile = try Self.profile(profileID)
        let value = try await request(.init(
            path: "/api/config", method: .get,
            query: [
                .init(name: "profile", value: profile),
                .init(name: "include_defaults", value: "true"),
            ], maximumResponseBytes: 1 * 1_024 * 1_024
        ))
        let config = try DirectHermesAdministrationCodec.object(value)
        let tts = try Self.optionalObject(config["tts"]) ?? [:]
        guard let rawProvider = try DirectHermesAdministrationCodec.optionalString(tts["provider"], maximum: 64),
              let provider = DirectHermesSelectableVoiceProvider(rawValue: rawProvider) else {
            return nil
        }
        let section = try Self.optionalObject(tts[provider.rawValue]) ?? [:]
        let field = provider == .openAI ? "voice" : "voice_id"
        guard let voice = try DirectHermesAdministrationCodec.optionalString(section[field], maximum: 160), !voice.isEmpty else {
            return nil
        }
        return .init(provider: provider, voiceID: voice)
    }

    func listElevenLabsVoices(profileID: String) async throws -> DirectHermesVoiceCatalog {
        let profile = try Self.profile(profileID)
        let response = try await request(.init(
            path: "/api/audio/elevenlabs/voices", method: .get,
            query: [.init(name: "profile", value: profile)], maximumResponseBytes: 1 * 1_024 * 1_024
        ))
        let object = try DirectHermesAdministrationCodec.object(response)
        let available = try DirectHermesAdministrationCodec.bool(object["available"])
        let rows = try DirectHermesAdministrationCodec.array(object["voices"], maximum: 2_000)
        var seen = Set<String>()
        let voices = try rows.map { value -> DirectHermesVoiceDescriptor in
            let row = try DirectHermesAdministrationCodec.object(value)
            let id = try Self.identifier(DirectHermesAdministrationCodec.string(row["voice_id"], maximum: 256), maximum: 256)
            guard seen.insert(id).inserted else { throw WorkspaceClientError.invalidResponse }
            return .init(
                id: id,
                name: try DirectHermesAdministrationCodec.string(row["name"], maximum: 800),
                label: try DirectHermesAdministrationCodec.string(row["label"], maximum: 1_024)
            )
        }
        let error = try DirectHermesAdministrationCodec.optionalString(object["error"], maximum: 256)
        guard available || voices.isEmpty else { throw WorkspaceClientError.invalidResponse }
        return .init(isAvailable: available, voices: voices, unavailableReason: error)
    }

    @discardableResult
    func selectVoice(
        profileID: String,
        selection: DirectHermesVoiceSelection
    ) async throws -> DirectHermesVoiceSelection {
        let profile = try Self.profile(profileID)
        let voice = try Self.identifier(selection.voiceID, maximum: 160)
        let field = selection.provider == .openAI ? "voice" : "voice_id"
        let response = try await request(.init(
            path: "/api/config", method: .put,
            body: [
                "profile": .string(profile),
                "config": .object([
                    "tts": .object([
                        "provider": .string(selection.provider.rawValue),
                        selection.provider.rawValue: .object([field: .string(voice)]),
                    ])
                ]),
            ], maximumResponseBytes: 16 * 1_024
        ), mutation: true)
        let receipt = try DirectHermesAdministrationCodec.object(response)
        guard try DirectHermesAdministrationCodec.bool(receipt["ok"]) else { throw WorkspaceClientError.outcomeUnknown }
        guard let verified = try await loadVoiceSelection(profileID: profile),
              verified == DirectHermesVoiceSelection(provider: selection.provider, voiceID: voice) else {
            throw WorkspaceClientError.outcomeUnknown
        }
        return verified
    }

    func setTTSLease(
        profileID: String,
        lease: DirectHermesTTSLease,
        active: Bool
    ) async throws -> DirectHermesTTSLeaseReceipt {
        let profile = try Self.profile(profileID)
        let leaseID = try Self.identifier(lease.id, maximum: 256)
        let response = try await request(.init(
            path: "/api/audio/tts-lease", method: .post,
            query: [.init(name: "profile", value: profile)],
            body: ["lease": .string(leaseID), "active": .boolean(active)],
            maximumResponseBytes: 32 * 1_024
        ), mutation: true)
        let row = try DirectHermesAdministrationCodec.object(response)
        guard try DirectHermesAdministrationCodec.bool(row["ok"]),
              try DirectHermesAdministrationCodec.string(row["lease"], maximum: 256) == leaseID,
              try DirectHermesAdministrationCodec.bool(row["active"]) == active else {
            throw WorkspaceClientError.outcomeUnknown
        }
        let action = try DirectHermesAdministrationCodec.optionalString(row["action"], maximum: 128) ?? "unknown"
        return .init(
            leaseID: leaseID,
            isActive: active,
            action: action,
            activeLeaseCount: try DirectHermesAdministrationCodec.optionalInt(row["leases"], minimum: 0),
            providerID: try DirectHermesAdministrationCodec.optionalString(row["provider"], maximum: 128),
            warmed: try DirectHermesAdministrationCodec.optionalBool(row["warmed"]),
            failedToWarm: action == "error" || row["error"] != nil
        )
    }

    func transcribe(
        profileID: String,
        recording: DirectHermesVoiceRecording,
        configuration: DirectHermesVoiceConfigurationSnapshot
    ) async throws -> DirectHermesTranscription {
        let profile = try Self.profile(profileID)
        try checkOwner()
        guard !configuration.isInvalidated else { throw WorkspaceClientError.ownerChanged }
        if case .direct(let direct) = configuration.speechToText {
            let result = try await providerTransport.transcribe(recording, using: direct)
            try checkOwner()
            return result
        }

        let response: BighelpJSONValue
        if let relayMediaHTTP {
            response = try await relayMediaHTTP.transcribeVoice(profileID: profile, recording: recording)
            try checkOwner()
        } else {
            guard recording.bytes.count <= Self.maximumInlineTranscriptionBytes else {
                throw DirectHermesVoiceConfigurationError.inlineTranscriptionLimit(
                    Self.maximumInlineTranscriptionBytes
                )
            }
            let dataURL = "data:\(recording.mimeType);base64,\(recording.bytes.base64EncodedString())"
            response = try await request(.init(
                path: "/api/audio/transcribe", method: .post,
                query: [.init(name: "profile", value: profile)],
                body: [
                    "data_url": .string(dataURL),
                    "mime_type": .string(recording.mimeType),
                ], maximumResponseBytes: 1 * 1_024 * 1_024
            ))
        }
        return try Self.transcription(response, clientDirect: false)
    }

    func synthesize(
        profileID: String,
        text: String,
        configuration: DirectHermesVoiceConfigurationSnapshot
    ) async throws -> DirectHermesSynthesizedSpeech {
        let profile = try Self.profile(profileID)
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 20_000,
              !configuration.isInvalidated else {
            throw WorkspaceClientError.invalidRequest
        }
        if case .direct(let direct) = configuration.textToSpeech {
            let result = try await providerTransport.synthesize(normalized, using: direct)
            try checkOwner()
            return result
        }
        return try Self.speech(try await request(.init(
            path: "/api/audio/speak", method: .post,
            query: [.init(name: "profile", value: profile)],
            body: ["text": .string(normalized)],
            maximumResponseBytes: DirectHermesHTTP.maximumVoiceSpeechResponseBytes
        )))
    }

    func play(
        profileID: String,
        text: String,
        configuration: DirectHermesVoiceConfigurationSnapshot,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void = { _ in }
    ) async throws {
        let profile = try Self.profile(profileID)
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 20_000,
              !configuration.isInvalidated else {
            throw WorkspaceClientError.invalidRequest
        }

        if case .relay = configuration.textToSpeech, let streamingPlayback {
            switch try await streamingPlayback.play(
                profileID: profile,
                text: normalized,
                onPlayback: onPlayback
            ) {
            case .played:
                try checkOwner()
                return
            case .fallbackRequired:
                break
            }
        }

        let result = try await synthesize(
            profileID: profile,
            text: normalized,
            configuration: configuration
        )
        try checkOwner()
        try await playback.play(result.audio, mimeType: result.mimeType, onPlayback: onPlayback)
    }

    func stopPlayback() {
        streamingPlayback?.stop()
        playback.stop()
    }

    func loadStockLiveVoiceStatus(profileID: String) async throws -> DirectHermesStockLiveVoiceStatus {
        let profile = try Self.profile(profileID)
        let response = try await request(.init(
            path: "/api/audio/voice-live/status", method: .get,
            query: [.init(name: "profile", value: profile)], maximumResponseBytes: 32 * 1_024
        ))
        let row = try DirectHermesAdministrationCodec.object(response)
        guard try DirectHermesAdministrationCodec.bool(row["ok"]),
              let mode = DirectHermesVoiceChatMode(rawValue: try DirectHermesAdministrationCodec.string(row["mode"], maximum: 64)) else {
            throw WorkspaceClientError.invalidResponse
        }
        return .init(
            mode: mode,
            isAvailable: try DirectHermesAdministrationCodec.bool(row["available"]),
            reason: try DirectHermesAdministrationCodec.optionalString(row["reason"], maximum: 1_024),
            modelID: try DirectHermesAdministrationCodec.string(row["model"], maximum: 256),
            voiceID: try DirectHermesAdministrationCodec.string(row["voice"], maximum: 256)
        )
    }

    /// Typed control-plane exchange only. This does not mount a WebRTC engine,
    /// capture a microphone, alter bighelp's Codex subscription voice, or make
    /// stock GPT-Live a fallback. A separately selected engine owns those steps.
    func createStockLiveVoiceSession(
        profileID: String,
        offerSDP: String,
        history: [DirectHermesVoiceLiveHistoryMessage]
    ) async throws -> DirectHermesStockLiveVoiceSession {
        let profile = try Self.profile(profileID)
        guard !offerSDP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              offerSDP.utf8.count <= 512 * 1_024,
              history.count <= 24 else {
            throw WorkspaceClientError.invalidRequest
        }
        var totalHistoryBytes = 0
        let encodedHistory = try history.map { message -> BighelpJSONValue in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.utf8.count <= 1_200 else {
                throw WorkspaceClientError.invalidRequest
            }
            totalHistoryBytes += text.utf8.count
            guard totalHistoryBytes <= 6_000 else { throw WorkspaceClientError.capacityExceeded }
            let contentType = message.role == .assistant ? "output_text" : "input_text"
            return .object([
                "type": .string("message"),
                "role": .string(message.role.rawValue),
                "content": .array([.object([
                    "type": .string(contentType),
                    "text": .string(text),
                ])]),
            ])
        }
        let response = try await request(.init(
            path: "/api/audio/voice-live/session", method: .post,
            query: [.init(name: "profile", value: profile)],
            body: ["sdp": .string(offerSDP), "history": .array(encodedHistory)],
            maximumResponseBytes: 1 * 1_024 * 1_024
        ), mutation: true)
        let row = try DirectHermesAdministrationCodec.object(response)
        guard try DirectHermesAdministrationCodec.bool(row["ok"]) else { throw WorkspaceClientError.outcomeUnknown }
        let transport = try DirectHermesAdministrationCodec.object(row["transport"])
        guard try DirectHermesAdministrationCodec.string(transport["type"], maximum: 64) == "webrtc" else {
            throw WorkspaceClientError.invalidResponse
        }
        let answer = try DirectHermesAdministrationCodec.string(transport["sdp"], maximum: 1 * 1_024 * 1_024)
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceClientError.invalidResponse
        }
        let session = try Self.optionalObject(row["session"])
        return .init(
            sessionID: try DirectHermesAdministrationCodec.optionalString(session?["id"], maximum: 512),
            answerSDP: answer
        )
    }

    private func request(
        _ request: DirectHermesHTTPRequest,
        mutation: Bool = false
    ) async throws -> BighelpJSONValue {
        try await DirectHermesCoreRequestScope.checkedRequest(check: checkOwner,
            mapError: { DirectHermesAdministrationCodec.safeError($0, mutation: mutation) }) {
            try await http.request(request)
        }
    }

    private func checkOwner() throws {
        try Task.checkCancellation()
        guard ownsScope else { throw WorkspaceClientError.ownerChanged }
    }

    private static func route(
        _ value: BighelpJSONValue?,
        direction: DirectHermesVoiceDirection
    ) throws -> DirectHermesVoiceRouteConfiguration {
        let row = try DirectHermesAdministrationCodec.object(value)
        let mode = try DirectHermesAdministrationCodec.string(row["mode"], maximum: 32)
        if mode == "relay" {
            return .relay(reason: try DirectHermesAdministrationCodec.optionalString(row["reason"], maximum: 1_024))
        }
        guard mode == "direct",
              let wire = DirectHermesVoiceProviderWire(
                rawValue: try DirectHermesAdministrationCodec.string(row["wire"], maximum: 64)
              ), wire.supports(direction) else {
            throw WorkspaceClientError.invalidResponse
        }
        let provider = try identifier(DirectHermesAdministrationCodec.string(row["provider"], maximum: 128), maximum: 128)
        let baseURL = try secureBaseURL(DirectHermesAdministrationCodec.string(row["base_url"], maximum: 2_048))
        let model = try DirectHermesAdministrationCodec.optionalString(row["model"], maximum: 512)
        let language = try DirectHermesAdministrationCodec.optionalString(row["language"], maximum: 128)
        let voice = try DirectHermesAdministrationCodec.optionalString(row["voice"], maximum: 256)
        let speed = try DirectHermesAdministrationCodec.optionalNumber(row["speed"])
        if let speed, !(0.25...4).contains(speed) { throw WorkspaceClientError.invalidResponse }
        let credential = try DirectHermesEphemeralVoiceCredential(DirectHermesAdministrationCodec.string(row["api_key"], maximum: 16_384))
        return .direct(.init(
            direction: direction,
            wire: wire,
            providerID: provider,
            baseURL: baseURL,
            modelID: model,
            language: language,
            voiceID: voice,
            speed: speed,
            credential: credential
        ))
    }

    static func transcription(
        _ value: BighelpJSONValue,
        clientDirect: Bool
    ) throws -> DirectHermesTranscription {
        let row = try DirectHermesAdministrationCodec.object(value)
        guard try DirectHermesAdministrationCodec.bool(row["ok"]) else { throw WorkspaceClientError.invalidResponse }
        return .init(
            text: try DirectHermesAdministrationCodec.string(row["transcript"], maximum: 1 * 1_024 * 1_024),
            providerID: try DirectHermesAdministrationCodec.optionalString(row["provider"], maximum: 128),
            usedClientDirectTransport: clientDirect
        )
    }

    private static func speech(_ value: BighelpJSONValue) throws -> DirectHermesSynthesizedSpeech {
        let row = try DirectHermesAdministrationCodec.object(value)
        guard try DirectHermesAdministrationCodec.bool(row["ok"]),
              let dataURL = row["data_url"]?.string,
              dataURL.utf8.count <= ((BighelpLinkVoiceAudioChunk.maximumAudioBytes + 2) / 3) * 4 + 512,
              let comma = dataURL.firstIndex(of: ",") else {
            throw WorkspaceClientError.invalidResponse
        }
        let header = String(dataURL[..<comma])
        let encoded = String(dataURL[dataURL.index(after: comma)...])
        guard header.hasPrefix("data:"), header.contains(";base64"),
              let declared = try DirectHermesAdministrationCodec.optionalString(row["mime_type"], maximum: 128) else {
            throw WorkspaceClientError.invalidResponse
        }
        let mime = String(header.dropFirst(5).split(separator: ";", maxSplits: 1).first ?? "").lowercased()
        guard mime == declared.lowercased(), mime.hasPrefix("audio/"),
              let audio = Data(base64Encoded: encoded), !audio.isEmpty,
              audio.count <= BighelpLinkVoiceAudioChunk.maximumAudioBytes else {
            throw WorkspaceClientError.invalidResponse
        }
        return .init(
            audio: audio,
            mimeType: mime,
            providerID: try DirectHermesAdministrationCodec.optionalString(row["provider"], maximum: 128),
            usedClientDirectTransport: false
        )
    }


    private static func profile(_ value: String) throws -> String {
        try DirectHermesProviderClient.profile(value)
    }

    private static func secureBaseURL(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else {
            throw WorkspaceClientError.invalidResponse
        }
        return url
    }

    private static func identifier(_ value: String, maximum: Int) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= maximum,
              !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceClientError.invalidResponse
        }
        return normalized
    }

    private static func optionalObject(_ value: BighelpJSONValue?) throws -> [String: BighelpJSONValue]? {
        if value == nil || value == .null { return nil }
        return try DirectHermesAdministrationCodec.object(value)
    }

}
