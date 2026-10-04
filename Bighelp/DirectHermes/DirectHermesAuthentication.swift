import Foundation
import CryptoKit
import Security

/// An isolated, memory-only session. Redirects are never followed, even to the same
/// origin: POST bodies, authorization headers and ticket subprotocols stay at the
/// caller-approved URL. Certificate handling remains the platform's strict default.
final class DirectHermesSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct BoundedFileUploadFailure: Error, @unchecked Sendable {
        let response: HTTPURLResponse?
        let underlying: any Error
    }

    private struct BoundedFileUpload {
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>
        let successMaximumBytes: Int
        let failureMaximumBytes: Int
        var response: HTTPURLResponse?
        var maximumBytes: Int?
        var received = Data()
        var failure: (any Error)?
    }

    private let uploadLock = NSLock()
    private var fileUploads: [Int: BoundedFileUpload] = [:]

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            completionHandler(.performDefaultHandling, nil)
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault:
            // A password proxy in front of Hermes. Answer with no credential so the
            // 401 reaches the app, which explains it or sends the password the person
            // entered for this address. These sessions have no credential store,
            // so nothing is ever supplied automatically.
            completionHandler(.rejectProtectionSpace, nil)
        default:
            // No client-certificate or other automatic login.
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// `URLSession.bytes(for:)` does not provide the upload-task file contract for
    /// an `httpBodyStream`. This uses Foundation's public file-backed upload task
    /// while collecting only a caller-bounded response through this same session.
    func uploadFile(
        using session: URLSession,
        request: URLRequest,
        fromFile fileURL: URL,
        successMaximumBytes: Int,
        failureMaximumBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let task = session.uploadTask(with: request, fromFile: fileURL)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                uploadLock.withLock {
                    fileUploads[task.taskIdentifier] = BoundedFileUpload(
                        continuation: continuation,
                        successMaximumBytes: successMaximumBytes,
                        failureMaximumBytes: failureMaximumBytes
                    )
                }
                if Task.isCancelled {
                    task.cancel()
                    let upload = uploadLock.withLock {
                        fileUploads.removeValue(forKey: task.taskIdentifier)
                    }
                    upload?.continuation.resume(throwing: BoundedFileUploadFailure(
                        response: nil,
                        underlying: CancellationError()
                    ))
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let disposition = uploadLock.withLock { () -> URLSession.ResponseDisposition in
            guard var upload = fileUploads[dataTask.taskIdentifier] else { return .allow }
            guard let http = response as? HTTPURLResponse else {
                upload.failure = DirectHermesError.invalidResponse
                fileUploads[dataTask.taskIdentifier] = upload
                return .cancel
            }
            let maximumBytes = (200...299).contains(http.statusCode)
                ? upload.successMaximumBytes : upload.failureMaximumBytes
            upload.response = http
            upload.maximumBytes = maximumBytes
            if http.expectedContentLength > Int64(maximumBytes) {
                upload.failure = DirectHermesError.messageTooLarge
                fileUploads[dataTask.taskIdentifier] = upload
                return .cancel
            }
            fileUploads[dataTask.taskIdentifier] = upload
            return .allow
        }
        completionHandler(disposition)
        if disposition == .cancel { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let overflow = uploadLock.withLock { () -> Bool in
            guard var upload = fileUploads[dataTask.taskIdentifier], upload.failure == nil else {
                return false
            }
            guard let maximumBytes = upload.maximumBytes else {
                upload.failure = DirectHermesError.invalidResponse
                fileUploads[dataTask.taskIdentifier] = upload
                return true
            }
            let remaining = maximumBytes - upload.received.count
            let accepted = min(data.count, max(0, remaining))
            if accepted > 0 { upload.received.append(data.prefix(accepted)) }
            guard accepted == data.count else {
                upload.failure = DirectHermesError.messageTooLarge
                fileUploads[dataTask.taskIdentifier] = upload
                return true
            }
            fileUploads[dataTask.taskIdentifier] = upload
            return false
        }
        if overflow { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let result = uploadLock.withLock {
            fileUploads.removeValue(forKey: task.taskIdentifier)
        }
        guard let upload = result else { return }
        if let failure = upload.failure ?? error {
            upload.continuation.resume(throwing: BoundedFileUploadFailure(
                response: upload.response,
                underlying: failure
            ))
        } else if let response = upload.response {
            upload.continuation.resume(returning: (upload.received, response))
        } else {
            upload.continuation.resume(throwing: BoundedFileUploadFailure(
                response: nil,
                underlying: DirectHermesError.invalidResponse
            ))
        }
    }
}

@MainActor
final class DirectHermesHTTP {
    let session: URLSession
    let endpoint: DirectHermesEndpoint
    private let delegate: DirectHermesSessionDelegate
    func sendManagedFileUpload(request: URLRequest, fromFile fileURL: URL,
                               successMaximumBytes: Int, failureMaximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, request.httpMethod == "POST",
              var target = URLComponents(url: url, resolvingAgainstBaseURL: false), target.fragment == nil else {
            throw DirectHermesError.invalidResponse
        }
        target.query = nil
        guard target.url == (try endpoint.url(for: "/api/files/upload-stream")) else {
            throw DirectHermesError.invalidEndpoint
        }
        return try await delegate.uploadFile(using: session, request: request, fromFile: fileURL,
            successMaximumBytes: successMaximumBytes, failureMaximumBytes: failureMaximumBytes)
    }

    private static let maximumBodyBytes = 1_024 * 1_024
    /// The most any one request may take, start to finish.
    static let longestRequestSeconds: TimeInterval = 75
    /// Matches the stock host's incrementally enforced session-import ceiling.
    /// This is route-scoped; ordinary JSON requests retain the 1 MiB body cap.
    static let maximumSessionTransferBytes = 25 * 1_024 * 1_024
    static let maximumManagedFileListingResponseBytes = 4 * 1_024 * 1_024
    static let maximumMediaResponseBytes = ((ChatAttachment.maximumAgentBytes + 2) / 3) * 4 + 8_192
    /// Stock `/api/audio/transcribe` accepts 25 MiB after base64 decoding. Keep
    /// the expansion plus a small fixed JSON/data-URL envelope route-local.
    static let maximumVoiceTranscriptionRequestBytes = ((25 * 1_024 * 1_024 + 2) / 3) * 4 + 8_192
    /// Buffered stock speech is still capped by the existing 8 MiB native
    /// playback boundary; only its base64 JSON reply receives this allowance.
    static let maximumVoiceSpeechResponseBytes =
        ((BighelpLinkVoiceAudioChunk.maximumAudioBytes + 2) / 3) * 4 + 8_192

    /// Plugin routes that return file bytes need more than the 4 MiB message
    /// cap. Without these, every Media download, Feed picture and Artifacts
    /// preview was refused before it was sent.
    static let nativeFileResponseLimits: [String: Int] = [
        "/api/plugins/loopdy/native/attachments/fetch": 4 * 1_024 * 1_024 + 65_536,
        "/api/plugins/loopdy/native/board/media": 12 * 1_024 * 1_024,
        "/api/plugins/loopdy/native/workspace-files/read": maximumMediaResponseBytes,
    ]

    /// A server's whole tool list (test, or a finished sign-in). A cloud
    /// provider's full API server lists thousands of tools with their descriptions.
    nonisolated static let maximumMCPToolListResponseBytes = 16 * 1_024 * 1_024

    static func isMCPToolListRoute(_ route: String, method: String) -> Bool {
        (method == "POST" && route.hasPrefix("/api/mcp/servers/") && route.hasSuffix("/test"))
            || (method == "GET" && route.hasPrefix("/api/mcp/oauth/flows/"))
    }

    static func responseLimit(route: String, method: String, query: [URLQueryItem]) -> Int {
        if isMCPToolListRoute(route, method: method) {
            return maximumMCPToolListResponseBytes
        }
        if method == "POST", route == "/api/audio/speak" {
            return maximumVoiceSpeechResponseBytes
        }
        if method == "POST", query.isEmpty, let limit = nativeFileResponseLimits[route] {
            return limit
        }
        if method == "GET", route == "/api/files" {
            // DirectHermesManagedFilesClient asks for exactly 4 MiB. Keep this
            // explicit so the constructor cannot regress to a smaller base cap.
            return maximumManagedFileListingResponseBytes
        }
        if method == "GET", isSessionExportRoute(route) {
            return maximumSessionTransferBytes
        }
        let paths = query.filter { $0.name == "path" }
        guard method == "GET", paths.count == 1, let path = paths.first?.value else {
            return DirectHermesWire.maximumMessageBytes
        }
        if (route == "/api/media" && DirectHermesGeneratedMediaClient.isImagePath(path))
            || (route == "/api/files/read" && DirectHermesGeneratedMediaClient.isDeliveredFilePath(path)) {
            return maximumMediaResponseBytes
        }
        return DirectHermesWire.maximumMessageBytes
    }

    static func requestBodyLimit(route: String, method: String) -> Int {
        guard method == "POST" else { return maximumBodyBytes }
        switch route {
        case "/api/sessions/import": return maximumSessionTransferBytes
        case "/api/audio/transcribe": return maximumVoiceTranscriptionRequestBytes
        default: return maximumBodyBytes
        }
    }

    private static func isSessionExportRoute(_ route: String) -> Bool {
        let prefix = "/api/sessions/"
        let suffix = "/export"
        guard route.hasPrefix(prefix), route.hasSuffix(suffix) else { return false }
        let session = route.dropFirst(prefix.count).dropLast(suffix.count)
        return !session.isEmpty && !session.contains("/")
    }

    init(endpoint: DirectHermesEndpoint) {
        self.endpoint = endpoint
        delegate = DirectHermesSessionDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        // Requests wait 20 seconds for the host unless they ask for longer; this caps the longest.
        configuration.timeoutIntervalForResource = Self.longestRequestSeconds
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        // A Cloudflare Access token or proxy password, and any custom headers,
        // for this exact address only (redirects are refused, so they never travel).
        accessHeaders = DirectHermesAccessCredentialStore.shared.headers(for: endpoint)
        configuration.httpAdditionalHeaders = accessHeaders
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// Also set on socket upgrades explicitly.
    let accessHeaders: [String: String]

    func applyAccessHeaders(to request: inout URLRequest) {
        for (field, value) in accessHeaders { request.setValue(value, forHTTPHeaderField: field) }
    }

    deinit { session.invalidateAndCancel() }
    func invalidate() { session.invalidateAndCancel() }

    struct Response {
        let http: HTTPURLResponse
        let body: Data
        func value() throws -> BighelpJSONValue {
            try DirectHermesWire.validateNesting(body)
            guard let value = try? JSONDecoder().decode(BighelpJSONValue.self, from: body) else {
                throw DirectHermesError.invalidResponse
            }
            return value
        }
        func object() throws -> [String: BighelpJSONValue] {
            guard let object = try value().object else { throw DirectHermesError.invalidResponse }
            return object
        }
    }

    func send(route: String, method: String = "GET", query: [URLQueryItem] = [],
              body: [String: BighelpJSONValue]? = nil, bearer: String? = nil,
              legacyToken: String? = nil, cookie: String? = nil, accept: String = "application/json",
              allowAuthorizeRedirect: Bool = false,
              maximumResponseBytes: Int = 1_048_576,
              timeout: TimeInterval = 20,
              nativeGuard: DirectHermesNativeRequestGuard? = nil) async throws -> Response {
        try Task.checkCancellation()
        guard (1...Self.responseLimit(route: route, method: method, query: query)).contains(maximumResponseBytes) else {
            throw DirectHermesError.messageTooLarge
        }
        var components = URLComponents(url: try endpoint.url(for: route), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw DirectHermesError.invalidEndpoint }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: min(max(timeout, 1), Self.longestRequestSeconds))
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let nativeGuard {
            guard route.hasPrefix("/api/plugins/loopdy/native/"), method == "POST",
                  (bearer != nil) != (legacyToken != nil), cookie == nil else {
                throw DirectHermesError.invalidResponse
            }
            request.setValue(nativeGuard.etag, forHTTPHeaderField: "If-Match")
            request.setValue(nativeGuard.requestIDHeader, forHTTPHeaderField: "X-Loopdy-Request-ID")
        }
        if let bearer {
            try DirectHermesSecretValidation.validate(bearer)
            request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        if let legacyToken {
            guard bearer == nil else {
                throw DirectHermesError.unsupportedAuthentication
            }
            try DirectHermesSecretValidation.validate(legacyToken)
            request.setValue(legacyToken, forHTTPHeaderField: "X-Hermes-Session-Token")
        }
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let body {
            let maximumBodyBytes = Self.requestBodyLimit(route: route, method: method)
            try DirectHermesWire.validateValueSize(.object(body), limit: maximumBodyBytes)
            request.httpBody = try JSONEncoder().encode(BighelpJSONValue.object(body))
            guard (request.httpBody?.count ?? 0) <= maximumBodyBytes else {
                throw DirectHermesError.messageTooLarge
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url == url else {
                bytes.task.cancel()
                throw DirectHermesError.redirectRefused
            }
            if Self.isCloudflareAccessDenial(http, sentAccessToken: accessHeaders["CF-Access-Client-Id"] != nil) {
                bytes.task.cancel()
                throw DirectHermesError.cloudflareAccessDenied
            }
            if (300...399).contains(http.statusCode), !(allowAuthorizeRedirect && http.statusCode == 302) {
                bytes.task.cancel()
                throw DirectHermesError.redirectRefused
            }
            guard http.expectedContentLength <= Int64(maximumResponseBytes) else {
                bytes.task.cancel()
                throw DirectHermesError.messageTooLarge
            }
            let data = try await Self.collectBody(bytes, maximumBytes: maximumResponseBytes)
            try Task.checkCancellation()
            return Response(http: http, body: data)
        } catch { throw Self.safeError(error) }
    }

    /// AsyncBytes.next runs off the main actor. Consuming each byte on the
    /// main actor otherwise adds an executor hop for every byte of a video.
    /// Preserve the incremental size fence instead of buffering an unlimited
    /// URLSession.data response before checking its size.
    nonisolated static func collectBody(_ bytes: URLSession.AsyncBytes, maximumBytes: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                bytes.task.cancel()
                throw DirectHermesError.messageTooLarge
            }
            if data.count.isMultiple(of: 4_096) { try Task.checkCancellation() }
            data.append(byte)
        }
        return data
    }

    /// Access sends people without a valid token to its login page, and answers a
    /// rejected service token with an HTML block page; Hermes itself answers JSON.
    nonisolated static func isCloudflareAccessDenial(_ response: HTTPURLResponse, sentAccessToken: Bool) -> Bool {
        if (300...399).contains(response.statusCode),
           let location = response.value(forHTTPHeaderField: "Location"),
           let host = URLComponents(string: location)?.host?.lowercased(),
           host == "cloudflareaccess.com" || host.hasSuffix(".cloudflareaccess.com") {
            return true
        }
        guard sentAccessToken, [401, 403].contains(response.statusCode) else { return false }
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        return type.hasPrefix("text/html") && response.value(forHTTPHeaderField: "CF-RAY") != nil
    }

    /// Something other than Hermes' status answered: Hermes' own guard against a
    /// host name it doesn't know (a Cloudflare Tunnel or proxy passes the public
    /// name on), or a web page. Only fixed text reaches the person, never the body.
    static func requireHermesAnswer(_ response: Response) throws {
        let status = response.http.statusCode
        let type = response.http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if status == 400, type.hasPrefix("application/json"),
           (try? response.object())?["detail"]?.string?.hasPrefix("Invalid Host header") == true {
            throw DirectHermesError.hostNameRefused
        }
        // 401, 403 and 5xx pages keep their own meaning (a gate, an outage).
        guard type.hasPrefix("text/html"), (200...299).contains(status) || status == 400 else { return }
        throw DirectHermesError.webPageInsteadOfHermes(
            throughCloudflare: response.http.value(forHTTPHeaderField: "CF-RAY") != nil)
    }

    static func requireSuccess(_ response: Response) throws {
        switch response.http.statusCode {
        case 200...299: return
        case 401, 403: throw DirectHermesError.invalidCredentials
        case 404, 405: throw DirectHermesError.unsupportedAuthentication
        case 429: throw DirectHermesError.rateLimited
        case 500...599: throw DirectHermesError.serverUnavailable
        default: throw DirectHermesError.invalidResponse
        }
    }

    static func safeError(_ error: any Error) -> DirectHermesError {
        if let safe = error as? DirectHermesError { return safe }
        if error is CancellationError { return .cancelled(outcomeUnknown: false) }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled: return .cancelled(outcomeUnknown: false)
            case .timedOut: return .timedOut(outcomeUnknown: false)
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
                return .tlsRequired
            default: break
            }
        }
        return .connectionFailed
    }
}

/// Uses the stock provider-minted bearer and native PKCE APIs, not HTTP Basic or
/// bighelp enrollment. The password and one-time PKCE cookie are never saved.
@MainActor
final class DirectHermesAuthenticator {
    let http: DirectHermesHTTP
    private(set) var savedConnection: DirectHermesSavedConnection?
    /// Invoked synchronously before a rotated session can be used. The owner must
    /// persist it atomically or throw; stale refresh tokens must never be retried.
    var persistRotation: ((DirectHermesSavedConnection, DirectHermesSavedConnection) throws -> Void)?
    private var refreshOutcomeUncertain = false
    private var refreshTask: Task<Void, any Error>?
    /// A renewal whose answer never arrived (the app left, the network dropped): the
    /// connection it renewed and when it was first sent. Hermes answers the same renewal
    /// token with the same new sign-in for 30 seconds (`refresh_singleflight`), so inside
    /// that window it may be sent again; after it, a resend would look like reuse to a
    /// rotating provider such as the Nous Portal, which then ends the whole sign-in.
    private var unansweredRenewal: (connection: DirectHermesSavedConnection, sentAt: Date)?
    static let renewalResendWindow: TimeInterval = 25
    var now: () -> Date = Date.init
    private var signInID: UUID?
    private var signInTask: Task<DirectHermesSavedConnection, any Error>?
    private var browserAuthentication: DirectHermesBrowserAuthentication?
    private let makeBrowserAuthentication: @MainActor () -> DirectHermesBrowserAuthentication

    init(endpoint: DirectHermesEndpoint,
         makeBrowserAuthentication: @escaping @MainActor () -> DirectHermesBrowserAuthentication = {
             DirectHermesBrowserAuthentication()
         }) {
        http = DirectHermesHTTP(endpoint: endpoint)
        self.makeBrowserAuthentication = makeBrowserAuthentication
    }

    func discoverGatedMode() async throws -> Bool {
        try await discoverAuthentication(enrichProviders: false).authRequired
    }

    /// Public status is the initial authority for release compatibility, auth mode,
    /// and native capability. Provider details are optional picker enrichment.
    /// Discovery never captures browser cookies or sends credentials.
    func discoverAuthentication() async throws -> DirectHermesAuthenticationDiscovery {
        try await discoverAuthentication(enrichProviders: true)
    }

    private func discoverAuthentication(enrichProviders: Bool) async throws -> DirectHermesAuthenticationDiscovery {
        let response = try await http.send(route: "/api/status")
        try DirectHermesHTTP.requireHermesAnswer(response)
        try DirectHermesHTTP.requireSuccess(response)
        let status = try response.object()
        guard let authRequired = status["auth_required"]?.boolean else {
            throw DirectHermesError.invalidResponse
        }

        // Reuse the parent-owned exact release matrix without requiring /api/status
        // to expose the health-only `ok` field.
        var releaseProjection = status
        releaseProjection["ok"] = .boolean(true)
        releaseProjection["auth_required"] = .boolean(authRequired)
        do {
            try DirectHermesReleaseContract.validateHealth(releaseProjection)
        } catch WorkspaceClientError.unavailable(.unsupportedHermesVersion) {
            // A version outside the verified matrix is not a sign-in problem; say so.
            throw DirectHermesError.unsupportedHermesVersion
        } catch {
            throw DirectHermesError.invalidResponse
        }

        let flows: [String]
        if let advertisedFlows = status["auth_flows"], advertisedFlows != .null {
            guard let rawFlows = advertisedFlows.array, rawFlows.count <= 32 else {
                throw DirectHermesError.invalidResponse
            }
            flows = try rawFlows.map { value -> String in
                guard let flow = value.string, !flow.isEmpty, flow.utf8.count <= 128 else {
                    throw DirectHermesError.invalidResponse
                }
                return flow
            }
        } else {
            flows = []
        }
        guard Set(flows).count == flows.count else { throw DirectHermesError.invalidResponse }
        guard authRequired, flows.contains("native_pkce"), enrichProviders else {
            return .init(authRequired: authRequired, flows: flows, providers: [])
        }

        let providers: [DirectHermesAuthenticationProvider]
        do {
            providers = try await discoverProviders()
        } catch {
            // Provider presentation metadata cannot disable a status-advertised
            // browser flow. Only cancellation of this owning task propagates.
            try Task.checkCancellation()
            providers = []
        }
        return .init(authRequired: authRequired, flows: flows, providers: providers)
    }

    private func discoverProviders() async throws -> [DirectHermesAuthenticationProvider] {
        let response = try await http.send(route: "/api/auth/providers")
        try DirectHermesHTTP.requireSuccess(response)
        guard let rawProviders = try response.object()["providers"]?.array,
              rawProviders.count <= 64 else { throw DirectHermesError.invalidResponse }
        var names = Set<String>()
        return try rawProviders.map { value -> DirectHermesAuthenticationProvider in
            guard let object = value.object, let name = object["name"]?.string,
                  !name.isEmpty, name.utf8.count <= 256,
                  name.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }),
                  names.insert(name).inserted,
                  let supportsPassword = object["supports_password"]?.boolean else {
                throw DirectHermesError.invalidResponse
            }
            let displayName = object["display_name"]?.string ?? name
            guard !displayName.isEmpty, displayName.utf8.count <= 512,
                  !displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw DirectHermesError.invalidResponse
            }
            return .init(name: name, displayName: displayName, supportsPassword: supportsPassword)
        }
    }

    /// Cancels the exact in-flight sign-in, not the saved host session. Call on
    /// endpoint/account/view retirement. Task cancellation of signIn/
    /// DirectHermesClient.connect follows this path too.
    func cancelAuthentication() {
        signInID = nil
        signInTask?.cancel()
        signInTask = nil
        browserAuthentication?.cancel()
        browserAuthentication = nil
    }

    func signIn(_ input: DirectHermesAuthInput) async throws {
        cancelAuthentication()
        try Task.checkCancellation()
        let id = UUID()
        signInID = id
        let task = Task { @MainActor in try await self.performSignIn(input) }
        signInTask = task
        defer {
            if signInID == id {
                signInID = nil
                signInTask = nil
            }
        }
        try await withTaskCancellationHandler {
            do {
                let candidate = try await task.value
                try Task.checkCancellation()
                guard signInID == id else { throw DirectHermesError.cancelled(outcomeUnknown: false) }
                try candidate.validate()
                savedConnection = candidate
                refreshOutcomeUncertain = false
            } catch { throw DirectHermesHTTP.safeError(error) }
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in
                guard let self, self.signInID == id else { return }
                self.cancelAuthentication()
            }
        }
    }

    private func performSignIn(_ input: DirectHermesAuthInput) async throws -> DirectHermesSavedConnection {
        // This preflight precedes browser launch, credential verification, and any
        // candidate that the workspace could persist. Provider detail is fetched
        // only for methods that can use it.
        let enrichProviders: Bool
        switch input {
        case .password, .passwordProvider, .browser: enrichProviders = true
        case .dashboard, .token: enrichProviders = false
        }
        let discovery = try await discoverAuthentication(enrichProviders: enrichProviders)
        let gated = discovery.authRequired
        switch input {
        case .token(let token):
            try DirectHermesSecretValidation.validate(token)
            if gated {
                let identity = try await verifiedIdentity(accessToken: token)
                return DirectHermesSavedConnection(endpoint: http.endpoint,
                    authentication: .bearer(accessToken: token, refreshToken: nil, expiresAt: identity.expiresAt),
                    provider: identity.provider, userID: identity.userID)
            } else {
                return DirectHermesSavedConnection(endpoint: http.endpoint,
                    authentication: .dashboardSession(token: token, automatic: false))
            }
        case .dashboard:
            guard !gated else { throw DirectHermesError.authModeChanged }
            return DirectHermesSavedConnection(endpoint: http.endpoint,
                authentication: .dashboardSession(token: try await dashboardToken(), automatic: true))

        case .password(let username, let password):
            guard gated else { throw DirectHermesError.unsupportedAuthentication }
            return try await passwordSignIn(username: username, password: password,
                                            selectedProvider: nil, discovery: discovery)
        case .passwordProvider(let provider, let username, let password):
            guard gated else { throw DirectHermesError.unsupportedAuthentication }
            return try await passwordSignIn(username: username, password: password,
                                            selectedProvider: provider, discovery: discovery)
        case .browser(let provider):
            guard gated else { throw DirectHermesError.unsupportedAuthentication }
            return try await browserSignIn(provider: provider, discovery: discovery)
        }
    }

    func restore(_ saved: DirectHermesSavedConnection) async throws {
        try saved.validate()
        guard saved.endpoint == http.endpoint else { throw DirectHermesError.savedConnectionInvalid }
        savedConnection = saved
        try await verifyModeAndSession()
    }

    /// Renews a saved rotating sign-in without connecting, when a wake from the host's
    /// plugin arrives while bighelp is closed.
    func renew(_ saved: DirectHermesSavedConnection) async throws {
        try saved.validate()
        guard saved.endpoint == http.endpoint, case .bearer(_, _?, _) = saved.authentication else {
            throw DirectHermesError.savedConnectionInvalid
        }
        savedConnection = saved
        try await refresh()
    }

    #if DEBUG
    func adoptForTesting(_ saved: DirectHermesSavedConnection) { savedConnection = saved }
    #endif

    func verifyModeAndSession() async throws {
        guard let saved = savedConnection else { throw DirectHermesError.notConnected }
        let gated = try await discoverGatedMode()
        switch saved.authentication {
        case .dashboardSession(let oldToken, let automatic):
            guard !gated else { throw DirectHermesError.authModeChanged }
            if automatic {
                let token = try await dashboardToken()
                guard savedConnection == saved else { throw DirectHermesError.secureStorageChanged }
                if token != oldToken {
                    var replacement = saved
                    replacement.authentication = .dashboardSession(token: token, automatic: true)
                    try persistRotation?(saved, replacement)
                    savedConnection = replacement
                }
            }
        case .legacyLoopbackToken:
            guard !gated else { throw DirectHermesError.authModeChanged }
            // Authentication is completed by the new socket's gateway.ready.
        case .bearer(let token, _, let expiry):
            guard gated else { throw DirectHermesError.authModeChanged }
            if let expiry, expiry <= Date().addingTimeInterval(30) {
                try await refresh()
            } else {
                do {
                    let identity = try await verifiedIdentity(accessToken: token)
                    try requireIdentity(identity.provider, identity.userID, matches: saved)
                } catch DirectHermesError.invalidCredentials {
                    try await refresh()
                }
            }
        }
    }

    func websocketRequest() async throws -> URLRequest {
        guard let saved = savedConnection else { throw DirectHermesError.notConnected }
        var components = URLComponents(url: try http.endpoint.url(for: "/api/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = http.endpoint.baseURL.scheme == "https" ? "wss" : "ws"
        var protocols: String?
        var legacyHeader: String?
        switch saved.authentication {
        case .dashboardSession(let token, _):
            components.queryItems = [URLQueryItem(name: "token", value: token)]
            legacyHeader = token
        case .legacyLoopbackToken(let token):
            guard saved.endpoint.isLiteralLoopback, saved.endpoint.allowPrivateHTTP else {
                throw DirectHermesError.unsupportedAuthentication
            }
            components.queryItems = [URLQueryItem(name: "token", value: token)]
            legacyHeader = token
        case .bearer:
            // Every socket, including reconnects, consumes a new single-use ticket.
            let ticket = try await mintTicket()
            protocols = "hermes-gateway-v1, hermes-gateway-ticket." + ticket
        }
        guard let url = components.url else { throw DirectHermesError.invalidEndpoint }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        if let protocols { request.setValue(protocols, forHTTPHeaderField: "Sec-WebSocket-Protocol") }
        if let legacyHeader { request.setValue(legacyHeader, forHTTPHeaderField: "X-Hermes-Session-Token") }
        http.applyAccessHeaders(to: &request)
        return request
    }

    /// A speech socket is a separate authenticated WebSocket and therefore
    /// consumes its own freshly minted ticket. The main gateway socket's
    /// credential is neither retained nor reusable here.
    func voiceStreamingRequest(profileID: String) async throws -> URLRequest {
        let profile = try DirectHermesProviderClient.profile(profileID)
        let tokens = try await authenticatedTokens()
        var query = [URLQueryItem(name: "profile", value: profile)]
        if tokens.bearer != nil {
            query.append(URLQueryItem(name: "ticket", value: try await mintTicket()))
        } else if let dashboard = tokens.dashboard {
            query.append(URLQueryItem(name: "token", value: dashboard))
        } else {
            throw DirectHermesError.authenticationRequired
        }

        var components = URLComponents(
            url: try http.endpoint.url(for: "/api/audio/speak-stream"),
            resolvingAgainstBaseURL: false
        )!
        components.scheme = http.endpoint.baseURL.scheme == "https" ? "wss" : "ws"
        components.queryItems = query
        guard let url = components.url else { throw DirectHermesError.invalidEndpoint }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.httpShouldHandleCookies = false
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        http.applyAccessHeaders(to: &request)
        return request
    }

    /// The Kanban event feed is a separate, read-only WebSocket. Every bearer
    /// connection and reconnect consumes a new ticket; ungated loopback/dashboard
    /// mode retains the stock token query contract.
    func kanbanEventRequest(board: String, since cursor: Int) async throws -> URLRequest {
        var query = try DirectHermesKanbanTransportBoundary.eventQuery(
            board: board,
            since: cursor
        )
        let tokens = try await authenticatedTokens()
        if tokens.bearer != nil {
            query.append(.init(name: "ticket", value: try await mintTicket()))
        } else if let dashboard = tokens.dashboard {
            query.append(.init(name: "token", value: dashboard))
        } else {
            throw DirectHermesError.authenticationRequired
        }

        var components = URLComponents(
            url: try http.endpoint.url(for: "/api/plugins/kanban/events"),
            resolvingAgainstBaseURL: false
        )!
        components.scheme = http.endpoint.baseURL.scheme == "https" ? "wss" : "ws"
        components.queryItems = query
        guard let url = components.url else { throw DirectHermesError.invalidEndpoint }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.httpShouldHandleCookies = false
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        http.applyAccessHeaders(to: &request)
        return request
    }

    private func mintTicket() async throws -> String {
        guard let saved = savedConnection, case .bearer(let token, _, _) = saved.authentication else {
            throw DirectHermesError.notConnected
        }
        var response = try await http.send(route: "/api/auth/ws-ticket", method: "POST", body: [:], bearer: token)
        if response.http.statusCode == 401 {
            try await refresh()
            guard let refreshed = savedConnection, case .bearer(let newToken, _, _) = refreshed.authentication else {
                throw DirectHermesError.authenticationRequired
            }
            response = try await http.send(route: "/api/auth/ws-ticket", method: "POST", body: [:], bearer: newToken)
        }
        try DirectHermesHTTP.requireSuccess(response)
        let object = try response.object()
        guard let ticket = object["ticket"]?.string, !ticket.isEmpty, ticket.utf8.count <= 4_096,
              ticket.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let ttl = object["ttl_seconds"]?.number, ttl > 0, ttl <= 300 else {
            throw DirectHermesError.invalidResponse
        }
        return ticket
    }

    private struct Identity {
        let provider: String
        let userID: String
        let expiresAt: Date?
    }

    private func verifiedIdentity(accessToken: String) async throws -> Identity {
        let response = try await http.send(route: "/api/auth/me", bearer: accessToken)
        try DirectHermesHTTP.requireSuccess(response)
        let json = try response.object()
        guard let provider = json["provider"]?.string, !provider.isEmpty,
              let userID = json["user_id"]?.string, !userID.isEmpty else { throw DirectHermesError.invalidResponse }
        return Identity(provider: provider, userID: userID,
                        expiresAt: json["expires_at"]?.number.map { Date(timeIntervalSince1970: $0) })
    }

    private func requireIdentity(_ provider: String, _ userID: String, matches saved: DirectHermesSavedConnection) throws {
        guard DirectHermesIdentity.matches(provider, saved.provider),
              DirectHermesIdentity.matches(userID, saved.userID) else { throw DirectHermesError.identityChanged }
    }

    private func browserSignIn(provider: String?,
                               discovery: DirectHermesAuthenticationDiscovery) async throws -> DirectHermesSavedConnection {
        guard discovery.supportsNativePKCE else { throw DirectHermesError.unsupportedAuthentication }
        if let provider {
            guard !provider.isEmpty, provider.utf8.count <= 128,
                  provider.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else {
                throw DirectHermesError.unsupportedAuthentication
            }
        }
        let verifier = try randomURLSafeSecret()
        let state = try randomURLSafeSecret()
        let callbackPath = "/loopdy-native-callback/" + (try randomURLSafeSecret())
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        try Task.checkCancellation()
        let browser = makeBrowserAuthentication()
        browserAuthentication = browser
        defer {
            browser.cancel()
            if browserAuthentication === browser { browserAuthentication = nil }
        }
        let code = try await browser.authorizationCode(endpoint: http.endpoint, callbackPath: callbackPath,
                                                       state: state, challenge: challenge, provider: provider)
        try Task.checkCancellation()
        // One-use mutation: never retry or replay this code after an uncertain
        // response. Browser storage/cookies are never read by the native client.
        let response: DirectHermesHTTP.Response
        do {
            response = try await http.send(route: "/auth/native/token", method: "POST", body: [
                "code": .string(code), "code_verifier": .string(verifier)
            ])
        } catch {
            let safe = DirectHermesHTTP.safeError(error)
            switch safe {
            case .connectionFailed, .timedOut, .disconnected, .cancelled, .invalidResponse, .messageTooLarge:
                throw DirectHermesError.nativeTokenExchangeUncertain
            default: throw safe
            }
        }
        try DirectHermesHTTP.requireSuccess(response)
        let saved = try session(from: response)
        guard provider.map({ DirectHermesIdentity.matches($0, saved.provider) }) ?? true,
              case .bearer(let token, _, _) = saved.authentication else {
            throw DirectHermesError.identityChanged
        }
        let identity = try await verifiedIdentity(accessToken: token)
        try Task.checkCancellation()
        try requireIdentity(identity.provider, identity.userID, matches: saved)
        return saved
    }

    private func passwordSignIn(username: String, password: String,
                                selectedProvider: String?,
                                discovery: DirectHermesAuthenticationDiscovery) async throws -> DirectHermesSavedConnection {
        guard !username.isEmpty, username.utf8.count <= 1_024,
              !password.isEmpty, password.utf8.count <= 16_384 else {
            throw DirectHermesError.invalidCredentials
        }
        let passwordProviders = discovery.passwordProviders.map(\.name)
        let provider: String
        if let selectedProvider {
            guard passwordProviders.contains(selectedProvider) else { throw DirectHermesError.unsupportedAuthentication }
            provider = selectedProvider
        } else {
            guard passwordProviders.count == 1, let only = passwordProviders.first else {
                throw passwordProviders.isEmpty ? DirectHermesError.unsupportedAuthentication : .ambiguousPasswordProvider
            }
            provider = only
        }
        let verifier = try randomURLSafeSecret()
        let state = try randomURLSafeSecret()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        // No listener is created. Password login returns the callback in JSON; we
        // validate it locally and redeem its code directly at the approved host.
        let callback = "http://127.0.0.1:49152/loopdy-native-callback"
        let authorization = try await http.send(route: "/auth/native/authorize", query: [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: callback),
            URLQueryItem(name: "state", value: state)
        ], allowAuthorizeRedirect: true)
        guard authorization.http.statusCode == 302,
              let location = authorization.http.value(forHTTPHeaderField: "Location"),
              let login = URL(string: location, relativeTo: try http.endpoint.url(for: "/auth/native/authorize"))?.absoluteURL,
              login == (try http.endpoint.url(for: "/login")) else {
            throw DirectHermesError.unsupportedAuthentication
        }
        let cookie = try pkceCookie(from: authorization.http)
        let loginResponse = try await http.send(route: "/auth/password-login", method: "POST", body: [
            "provider": .string(provider), "username": .string(username), "password": .string(password), "next": .string("")
        ], cookie: cookie)
        try DirectHermesHTTP.requireSuccess(loginResponse)
        let loginObject = try loginResponse.object()
        guard loginObject["ok"]?.boolean == true, let next = loginObject["next"]?.string,
              var result = URLComponents(string: next), let items = result.queryItems,
              items.count == 2, items.filter({ $0.name == "state" }).count == 1,
              items.filter({ $0.name == "code" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw DirectHermesError.invalidResponse
        }
        result.query = nil
        guard result.string == callback else { throw DirectHermesError.redirectRefused }
        let tokenResponse = try await http.send(route: "/auth/native/token", method: "POST", body: [
            "code": .string(code), "code_verifier": .string(verifier)
        ])
        try DirectHermesHTTP.requireSuccess(tokenResponse)
        let saved = try session(from: tokenResponse)
        guard DirectHermesIdentity.matches(saved.provider, provider), case .bearer(let token, _, _) = saved.authentication else {
            throw DirectHermesError.identityChanged
        }
        let identity = try await verifiedIdentity(accessToken: token)
        try requireIdentity(identity.provider, identity.userID, matches: saved)
        return saved
    }

    private func pkceCookie(from response: HTTPURLResponse) throws -> String {
        guard let url = response.url else { throw DirectHermesError.invalidResponse }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        let expectedPath = http.endpoint.baseURL.path.isEmpty ? "/" : http.endpoint.baseURL.path
        let secure = http.endpoint.baseURL.scheme == "https"
        let prefix = secure ? (expectedPath == "/" ? "__Host-" : "__Secure-") : ""
        let expectedName = prefix + "hermes_session_pkce"
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).filter { $0.name == expectedName }
        guard cookies.count == 1, let cookie = cookies.first,
              cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == http.endpoint.host,
              cookie.path == expectedPath, (!secure || cookie.isSecure),
              cookie.expiresDate.map({ $0 > Date() }) ?? false,
              cookie.value.utf8.count <= 8_192,
              !cookie.value.isEmpty,
              cookie.value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 95, 61].contains($0) }) else {
            throw DirectHermesError.invalidResponse
        }
        return expectedName + "=" + cookie.value
    }

    private func refresh() async throws {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { @MainActor in try await self.performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func authenticatedTokens() async throws -> (bearer: String?, dashboard: String?) {
        guard let saved = savedConnection else { throw DirectHermesError.authenticationRequired }
        try saved.validate()
        if case .bearer(_, _, let expiry) = saved.authentication,
           let expiry, expiry <= Date().addingTimeInterval(30) { try await refresh() }
        try Task.checkCancellation()
        guard let current = savedConnection else { throw DirectHermesError.authenticationRequired }
        switch current.authentication {
        case .bearer(let token, _, _): return (token, nil)
        case .dashboardSession(let token, _), .legacyLoopbackToken(let token): return (nil, token)
        }
    }

    func authenticatedResponse(_ request: DirectHermesHTTPRequest,
                               nativeGuard: DirectHermesNativeRequestGuard? = nil) async throws -> DirectHermesHTTP.Response {
        func send(_ tokens: (bearer: String?, dashboard: String?)) async throws -> DirectHermesHTTP.Response {
            try await http.send(route: request.path, method: request.method.rawValue,
                                query: request.query, body: request.body, bearer: tokens.bearer,
                                legacyToken: tokens.dashboard,
                                maximumResponseBytes: request.maximumResponseBytes, timeout: request.timeout,
                                nativeGuard: nativeGuard)
        }
        let tokens = try await authenticatedTokens()
        let response = try await send(tokens)
        guard response.http.statusCode == 401,
              response.http.value(forHTTPHeaderField: "WWW-Authenticate") == nil,
              await renewSignIn(turnedAway: tokens) else { return response }
        // Hermes checks the sign-in before any route runs, so the request never
        // started and sending it once more is safe.
        return try await send(try await authenticatedTokens())
    }

    /// The socket stays signed in from when it connected, but Hermes checks every
    /// web request again. A token revoked early, renewed by another request, or
    /// replaced when the dashboard restarted fails here first, while chat still
    /// works. Renew once and say whether the request is worth sending again.
    private func renewSignIn(turnedAway tokens: (bearer: String?, dashboard: String?)) async -> Bool {
        guard let saved = savedConnection else { return false }
        switch saved.authentication {
        case .bearer(let token, let refreshToken, _):
            guard token == tokens.bearer else { return true }
            guard refreshTask != nil || (refreshToken != nil && !refreshOutcomeUncertain) else { return false }
            return (try? await refresh()) != nil
        case .dashboardSession(let token, let automatic):
            guard token == tokens.dashboard else { return true }
            guard automatic, let fresh = try? await dashboardToken(), fresh != token,
                  savedConnection == saved else { return false }
            var replacement = saved
            replacement.authentication = .dashboardSession(token: fresh, automatic: true)
            do { try persistRotation?(saved, replacement) } catch { return false }
            savedConnection = replacement
            return true
        case .legacyLoopbackToken:
            return false
        }
    }

    func authenticatedManagedFileResponse(
        _ request: DirectHermesManagedFileTransportRequest,
        willDispatch: @MainActor () throws -> Void,
        didReceiveStatus: @MainActor (Int) -> Void
    ) async throws -> DirectHermesHTTP.Response {
        let tokens = try await authenticatedTokens()
        return try await http.sendManagedFile(
            request,
            bearer: tokens.bearer,
            legacyToken: tokens.dashboard,
            willDispatch: willDispatch,
            didReceiveStatus: didReceiveStatus
        )
    }

    func authenticatedHostImportUploadResponse(
        _ request: DirectHermesHostImportUploadRequest,
        willDispatch: @MainActor () throws -> Void,
        didReceiveStatus: @MainActor (Int) -> Void
    ) async throws -> DirectHermesHTTP.Response {
        let tokens = try await authenticatedTokens()
        return try await http.sendHostImportUpload(
            request,
            bearer: tokens.bearer,
            legacyToken: tokens.dashboard,
            willDispatch: willDispatch,
            didReceiveStatus: didReceiveStatus
        )
    }

    func authenticatedKanbanAttachmentResponse(
        _ request: DirectHermesKanbanAttachmentRequest
    ) async throws -> DirectHermesHTTP.Response {
        let tokens = try await authenticatedTokens()
        return try await http.sendKanbanAttachment(
            request,
            bearer: tokens.bearer,
            legacyToken: tokens.dashboard
        )
    }

    private func dashboardToken() async throws -> String {
        let response = try await http.send(route: "/", accept: "text/html")
        try DirectHermesHTTP.requireSuccess(response)
        guard response.http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/html") == true else {
            throw DirectHermesError.unsupportedAuthentication
        }
        return try DirectHermesDashboardBootstrap.token(from: response.body)
    }

    private func performRefresh() async throws {
        guard let current = savedConnection else { throw DirectHermesError.authenticationRequired }
        let old: DirectHermesSavedConnection
        let refreshToken: String
        let sentAt: Date
        if !refreshOutcomeUncertain, case .bearer(_, let token?, _) = current.authentication {
            (old, refreshToken, sentAt) = (current, token, now())
        } else if let unanswered = unansweredRenewal,
                  now().timeIntervalSince(unanswered.sentAt) < Self.renewalResendWindow,
                  case .bearer(_, let token?, _) = unanswered.connection.authentication {
            // Still inside Hermes' window: the same token gets the same answer.
            (old, refreshToken, sentAt) = (unanswered.connection, token, unanswered.sentAt)
        } else {
            unansweredRenewal = nil
            throw DirectHermesError.authenticationRequired
        }
        // Rotation is a mutation: loss/cancellation of its reply is not permission
        // to replay the old refresh token (providers may enforce reuse detection).
        refreshOutcomeUncertain = true
        var consumed = old
        if case .bearer(let accessToken, _, let expiry) = old.authentication {
            consumed.authentication = .bearer(accessToken: accessToken, refreshToken: nil, expiresAt: expiry)
        }
        // Durably retire the old rotating token BEFORE dispatch, so process death or
        // a lost response cannot replay it on the next app launch.
        if current != consumed {
            if let persistRotation { try persistRotation(current, consumed) }
            savedConnection = consumed
        }
        unansweredRenewal = (old, sentAt)
        let response = try await http.send(route: "/auth/native/refresh", method: "POST", body: [
            "refresh_token": .string(refreshToken), "provider": .string(old.provider ?? "")
        ])
        if response.http.statusCode == 401 {
            unansweredRenewal = nil
            throw DirectHermesError.authenticationRequired
        }
        if response.http.statusCode == 503 {
            // The sign-in provider couldn't be reached, so nothing was renewed and the
            // token still works: keep it for the next try instead of signing out.
            if let persistRotation { try persistRotation(consumed, old) }
            savedConnection = old
            refreshOutcomeUncertain = false
            unansweredRenewal = nil
            throw DirectHermesError.serverUnavailable
        }
        try DirectHermesHTTP.requireSuccess(response)
        let refreshed = try session(from: response)
        try requireIdentity(refreshed.provider ?? "", refreshed.userID ?? "", matches: old)
        if let persistRotation { try persistRotation(consumed, refreshed) }
        savedConnection = refreshed
        refreshOutcomeUncertain = false
        unansweredRenewal = nil
    }

    /// Leaving the app closes the connection and cancels its requests. A renewal already on
    /// its way gets a moment to finish first, so its answer (the new sign-in) isn't lost.
    func settlePendingRenewal(within limit: Duration) async {
        guard let refreshTask else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await refreshTask.value }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
    }

    private func session(from response: DirectHermesHTTP.Response) throws -> DirectHermesSavedConnection {
        let json = try response.object()
        guard json["token_type"]?.string == "Bearer", let token = json["access_token"]?.string,
              let provider = json["provider"]?.string, !provider.isEmpty,
              let userID = json["user_id"]?.string, !userID.isEmpty,
              let expires = json["expires_at"]?.number, expires > Date().timeIntervalSince1970 else {
            throw DirectHermesError.invalidResponse
        }
        let refresh = json["refresh_token"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let saved = DirectHermesSavedConnection(endpoint: http.endpoint,
            authentication: .bearer(accessToken: token, refreshToken: refresh, expiresAt: Date(timeIntervalSince1970: expires)),
            provider: provider, userID: userID)
        try saved.validate()
        return saved
    }

    private func randomURLSafeSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DirectHermesError.secureStorageUnavailable
        }
        return Self.base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Parse only Hermes' inert bootstrap assignments. Never execute dashboard HTML
/// or JavaScript, follow its resources, or accept a token from a gated page.
enum DirectHermesDashboardBootstrap {
    static func token(from data: Data) throws -> String {
        guard data.count <= 1_048_576, let html = String(data: data, encoding: .utf8) else {
            throw DirectHermesError.invalidResponse
        }
        let scripts = try NSRegularExpression(pattern: #"<script\b[^>]*>([\s\S]*?)</script\s*>"#, options: [.caseInsensitive])
        let assignment = try NSRegularExpression(pattern: #"(?:^|;)\s*window\.__HERMES_SESSION_TOKEN__\s*=\s*("(?:[^"\\]|\\.)*")\s*;"#)
        let mode = try NSRegularExpression(pattern: #"(?:^|;)\s*window\.__HERMES_AUTH_REQUIRED__\s*=\s*(true|false)\s*;"#)
        var tokens: [String] = []
        var modes: [String] = []
        for match in scripts.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let script = String(html[range])
            let full = NSRange(script.startIndex..., in: script)
            for value in assignment.matches(in: script, range: full) {
                guard let tokenRange = Range(value.range(at: 1), in: script),
                      let token = try? JSONDecoder().decode(String.self, from: Data(script[tokenRange].utf8)) else {
                    throw DirectHermesError.invalidResponse
                }
                tokens.append(token)
            }
            for value in mode.matches(in: script, range: full) {
                if let range = Range(value.range(at: 1), in: script) { modes.append(String(script[range])) }
            }
        }
        guard tokens.count == 1, modes == ["false"], let token = tokens.first else {
            throw DirectHermesError.unsupportedAuthentication
        }
        try DirectHermesSecretValidation.validate(token)
        return token
    }
}
