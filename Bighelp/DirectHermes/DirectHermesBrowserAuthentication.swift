import Foundation
import AuthenticationServices
import Network
import UIKit

/// Test construction seam for a credential-free synthetic broker. Production
/// leaves this nil and always creates a real ASWebAuthenticationSession.
typealias DirectHermesBrowserAuthorizeOpener = @MainActor (URL) throws -> Void

/// Incremental single-request framing, shared by the real listener and unit tests.
/// The listener imposes an independent wall-clock/connection limit. No HTTP body,
/// second request, obs-fold or malformed line endings are accepted by validation.
struct DirectHermesBrowserRequestParser: Sendable {
    static let maximumBytes = 16_384
    private var buffer = Data()
    private var completed = false

    mutating func append(_ fragment: Data) throws -> Data? {
        guard !completed else { throw DirectHermesError.invalidResponse }
        guard fragment.count <= Self.maximumBytes - buffer.count else {
            buffer.removeAll()
            completed = true
            throw DirectHermesError.messageTooLarge
        }
        buffer.append(fragment)
        guard let end = buffer.range(of: Data([13, 10, 13, 10])) else { return nil }
        completed = true
        guard end.upperBound == buffer.endIndex else {
            buffer.removeAll()
            throw DirectHermesError.invalidResponse
        }
        let request = buffer
        buffer.removeAll()
        return request
    }
}

/// Exact callback authority and pure, strict HTTP validation. Contains transient
/// correlation material: never encode, log, or attach this value to diagnostics.
struct DirectHermesBrowserCallback: Sendable {
    let port: UInt16
    let path: String
    private let state: String
    let url: URL

    init(port: UInt16, path: String, state: String) throws {
        guard port != 0, path.hasPrefix("/"), !path.hasPrefix("//"),
              path.utf8.count <= 1_024, !path.contains("//"),
              path.utf8.allSatisfy({ Self.isURLToken($0) || $0 == 47 || $0 == 46 }),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !state.isEmpty, state.utf8.count <= 4_096,
              state.utf8.allSatisfy(Self.isURLToken),
              let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw DirectHermesError.invalidResponse
        }
        self.port = port
        self.path = path
        self.state = state
        self.url = url
    }

    func validate(_ request: Data) throws -> String {
        guard request.count <= DirectHermesBrowserRequestParser.maximumBytes else {
            throw DirectHermesError.messageTooLarge
        }
        // ASCII HTTP headers only; CR/LF/HTAB are checked structurally below.
        guard request.allSatisfy({ (32...126).contains($0) || [9, 10, 13].contains($0) }),
              let text = String(data: request, encoding: .ascii), text.hasSuffix("\r\n\r\n") else {
            throw DirectHermesError.invalidResponse
        }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.count >= 4, lines.count <= 68, lines.suffix(2).allSatisfy(\.isEmpty),
              lines.dropLast(2).allSatisfy({ !$0.isEmpty && !$0.contains("\r") && !$0.contains("\n") }) else {
            throw DirectHermesError.invalidResponse
        }
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[0] == "GET", requestLine[2] == "HTTP/1.1" else {
            throw DirectHermesError.invalidResponse
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst().dropLast(2) {
            guard let colon = line.firstIndex(of: ":") else { throw DirectHermesError.invalidResponse }
            let name = String(line[..<colon])
            guard !name.isEmpty, name.utf8.allSatisfy(Self.isHeaderToken) else {
                throw DirectHermesError.invalidResponse
            }
            let key = name.lowercased()
            guard headers[key] == nil else { throw DirectHermesError.invalidResponse }
            headers[key] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        }
        guard headers["host"] == "127.0.0.1:\(port)",
              headers["transfer-encoding"] == nil, headers["expect"] == nil,
              headers["upgrade"] == nil, headers["trailer"] == nil,
              headers["content-length"].map({ $0 == "0" }) ?? true else {
            throw DirectHermesError.invalidResponse
        }
        let target = requestLine[1].split(separator: "?", omittingEmptySubsequences: false)
        guard target.count == 2, target[0] == path else { throw DirectHermesError.invalidResponse }
        let fields = target[1].split(separator: "&", omittingEmptySubsequences: false)
        guard fields.count == 2 else { throw DirectHermesError.invalidResponse }
        var query: [String: String] = [:]
        for field in fields {
            let pair = field.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw DirectHermesError.invalidResponse }
            let key = try Self.decodeToken(pair[0])
            let value = try Self.decodeToken(pair[1])
            guard ["state", "code"].contains(key), query[key] == nil else {
                throw DirectHermesError.invalidResponse
            }
            query[key] = value
        }
        guard query["state"] == state, let code = query["code"] else { throw DirectHermesError.invalidResponse }
        return code
    }

    private static func isURLToken(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
    }

    private static func isHeaderToken(_ byte: UInt8) -> Bool {
        isURLToken(byte) || "!#$%&'*+.^`|~".utf8.contains(byte)
    }

    private static func decodeToken(_ encoded: Substring) throws -> String {
        let bytes = Array(encoded.utf8)
        var result: [UInt8] = []
        var index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 65 + 10
            case 97...102: return byte - 97 + 10
            default: return nil
            }
        }
        while index < bytes.count {
            let byte: UInt8
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) else {
                    throw DirectHermesError.invalidResponse
                }
                byte = high * 16 + low
                index += 3
            } else {
                byte = bytes[index]
                index += 1
            }
            guard isURLToken(byte), result.count < 4_096 else { throw DirectHermesError.invalidResponse }
            result.append(byte)
        }
        guard !result.isEmpty else { throw DirectHermesError.invalidResponse }
        return String(decoding: result, as: UTF8.self)
    }
}

/// Serialized by the browser owner, with no UIKit/Network dependency in the state
/// transitions. Browser cancellation cannot erase a captured code. Explicit owner
/// retirement CAN invalidate it, and finishResponse transfers the code only once.
struct DirectHermesBrowserAttemptState: Sendable {
    enum Phase: Equatable, Sendable { case pending, captured, finished, cancelled }
    private(set) var phase: Phase = .pending
    private var code: String?

    mutating func capture(code: String) -> Bool {
        guard phase == .pending, !code.isEmpty else { return false }
        self.code = code
        phase = .captured
        return true
    }

    mutating func finishResponse() -> String? {
        guard phase == .captured else { return nil }
        let result = code
        code = nil
        phase = .finished
        return result
    }

    @discardableResult
    mutating func cancel() -> Bool {
        guard phase == .pending else { return false }
        phase = .cancelled
        return true
    }

    mutating func invalidate() {
        code = nil
        phase = .cancelled
    }
}

/// Public-API iOS candidate, NOT a claim of runtime qualification. ASWebAuthenticationSession
/// drives the auth sheet (on the Mac, your default browser does); the HTTP callback is
/// received only by NWListener, never by a made-up custom scheme or an intercepted
/// browser/cookie API.
@MainActor
final class DirectHermesBrowserAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var state = DirectHermesBrowserAttemptState()
    private var listener: NWListener?
    private var callback: DirectHermesBrowserCallback?
    private var webSession: ASWebAuthenticationSession?
    // Retain through this attempt's lifetime, including a late system context
    // query after cancel(). Never substitute a scene-less UIWindow.
    private var anchor: ASPresentationAnchor?
    private var continuation: CheckedContinuation<String, any Error>?
    private var deadline: Task<Void, Never>?
    private var started = false
    private var didOpenAuthorize = false
    private var connections: [UUID: Incoming] = [:]
    private let queue = DispatchQueue(label: "app.loopdy.native-auth.loopback")
    private let authorizeOpener: DirectHermesBrowserAuthorizeOpener?
    private static let maximumConnections = 4

    private final class Incoming {
        let connection: NWConnection
        var parser = DirectHermesBrowserRequestParser()
        var deadline: Task<Void, Never>?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(authorizeOpener: DirectHermesBrowserAuthorizeOpener? = nil) {
        self.authorizeOpener = authorizeOpener
        super.init()
    }

    func authorizationCode(endpoint: DirectHermesEndpoint, callbackPath: String,
                           state correlation: String, challenge: String, provider: String?) async throws -> String {
        guard !started else { throw DirectHermesError.invalidResponse }
        started = true
        try Task.checkCancellation()
        defer { dispose() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, state.phase == .pending else {
                    continuation.resume(throwing: DirectHermesError.cancelled(outcomeUnknown: false))
                    return
                }
                self.continuation = continuation
                if authorizeOpener == nil {
                    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                        .first(where: { $0.activationState == .foregroundActive && $0.windows.contains(where: \.isKeyWindow) }),
                          let anchor = scene.windows.first(where: \.isKeyWindow) else {
                        fail(.browserAuthenticationUnavailable)
                        return
                    }
                    self.anchor = anchor
                }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                    // No wildcard binding, port reservation race, Bonjour, or local-network browsing.
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.newConnectionHandler = { [weak self] connection in
                        Task { @MainActor [weak self] in
                            guard let self else { connection.cancel(); return }
                            self.accept(connection)
                        }
                    }
                    listener.stateUpdateHandler = { [weak self] update in
                        Task { @MainActor [weak self] in
                            guard let self, self.state.phase == .pending, self.continuation != nil else { return }
                            switch update {
                            case .ready:
                                guard !self.didOpenAuthorize else { return }
                                guard let port = self.listener?.port, port.rawValue != 0 else {
                                    self.fail(.browserAuthenticationUnavailable)
                                    return
                                }
                                self.didOpenAuthorize = true
                                self.present(endpoint: endpoint, port: port.rawValue, path: callbackPath,
                                             correlation: correlation, challenge: challenge, provider: provider)
                            case .failed, .cancelled: self.fail(.browserAuthenticationUnavailable)
                            default: break
                            }
                        }
                    }
                    deadline = timeout(seconds: 10) { [weak self] in self?.fail(.browserAuthenticationUnavailable) }
                    listener.start(queue: queue)
                } catch { fail(.browserAuthenticationUnavailable) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    /// Explicit account/host/lifecycle retirement, including after code capture.
    func cancel() {
        guard continuation != nil else {
            state.invalidate()
            dispose()
            return
        }
        state.invalidate()
        complete(.failure(.cancelled(outcomeUnknown: false)))
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Assigned before start(), strongly retained until the system session is
        // cancelled/disposed. Never substitute a scene-less UIWindow.
        precondition(anchor != nil)
        return anchor!
    }

    private func present(endpoint: DirectHermesEndpoint, port: UInt16, path: String,
                         correlation: String, challenge: String, provider: String?) {
        guard authorizeOpener != nil || anchor?.windowScene?.activationState == .foregroundActive else {
            fail(.browserAuthenticationUnavailable)
            return
        }
        do {
            let callback = try DirectHermesBrowserCallback(port: port, path: path, state: correlation)
            self.callback = callback
            var url = URLComponents(url: try endpoint.url(for: "/auth/native/authorize"), resolvingAgainstBaseURL: false)!
            var query = [
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "redirect_uri", value: callback.url.absoluteString),
                URLQueryItem(name: "state", value: correlation)
            ]
            if let provider { query.append(URLQueryItem(name: "provider", value: provider)) }
            url.queryItems = query
            guard let authorize = url.url else { throw DirectHermesError.invalidEndpoint }
            deadline?.cancel()
            deadline = timeout(seconds: 600) { [weak self] in self?.fail(.timedOut(outcomeUnknown: false)) }
            if let authorizeOpener {
                try authorizeOpener(authorize)
                return
            }
            #if targetEnvironment(macCatalyst)
            // The Mac signs in in your own browser, with its saved logins and
            // passkeys; the 127.0.0.1 listener receives the code just the same.
            UIApplication.shared.open(authorize) { [weak self] opened in
                guard !opened else { return }
                self?.fail(.browserAuthenticationUnavailable)
            }
            return
            #else
            // HTTP is deliberately NOT registered as a custom scheme. Ignore any
            // completion URL: only our validated listener supplies code.
            let session = ASWebAuthenticationSession(url: authorize, callbackURLScheme: nil,
                                                     completionHandler: Self.sessionCompletion { [weak self] cancelled in
                Task { @MainActor [weak self] in
                    guard let self, self.state.phase == .pending else { return }
                    self.fail(cancelled ? .cancelled(outcomeUnknown: false) : .browserAuthenticationUnavailable)
                }
            })
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            guard session.start() else { fail(.browserAuthenticationUnavailable); return }
            #endif
        } catch { fail(DirectHermesHTTP.safeError(error)) }
    }

    #if targetEnvironment(macCatalyst)
    /// bighelp's own link scheme; opening it brings the app back from the browser.
    private static let returnURL = URL(string: "app.loopdy.mobile://signed-in")!
    private static let receivedMessage = "<p>Signed in. <a href=\"app.loopdy.mobile://signed-in\">Return to Bighelp</a>"
        + " and close this tab.</p>"
    #else
    private static let receivedMessage = "<p>Sign-in received. Return to Bighelp.</p>"
    #endif

    /// The sheet's completion, which AuthenticationServices may call on its own
    /// queue (on the Mac, an XPC queue). It must not be main-actor isolated: an
    /// isolated closure traps there. It only reports whether the person cancelled.
    nonisolated static func sessionCompletion(
        _ deliver: @escaping @Sendable (_ cancelled: Bool) -> Void
    ) -> @Sendable (URL?, (any Error)?) -> Void {
        { _, error in deliver((error as? ASWebAuthenticationSessionError)?.code == .canceledLogin) }
    }

    private func accept(_ connection: NWConnection) {
        guard state.phase == .pending, callback != nil, continuation != nil,
              connections.count < Self.maximumConnections else { connection.cancel(); return }
        let id = UUID()
        let incoming = Incoming(connection)
        connections[id] = incoming
        incoming.deadline = timeout(seconds: 5) { [weak self] in self?.close(id) }
        connection.start(queue: queue)
        receive(id)
    }

    private func receive(_ id: UUID) {
        guard let incoming = connections[id], state.phase == .pending else { return }
        incoming.connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, ended, error in
            let failed = error != nil
            Task { @MainActor [weak self] in self?.received(data, id: id, ended: ended, failed: failed) }
        }
    }

    private func received(_ data: Data?, id: UUID, ended: Bool, failed: Bool) {
        guard let incoming = connections[id], state.phase == .pending else { return }
        guard !failed, let data, !data.isEmpty else { close(id); return }
        do {
            if let request = try incoming.parser.append(data) {
                guard let callback else { close(id); return }
                let code = try callback.validate(request)
                guard state.capture(code: code) else { close(id); return }
                // The accepted code is now owned independently of sheet callbacks.
                // Stop other readers, then flush a static response before teardown.
                for other in Array(connections.keys) where other != id { close(other) }
                incoming.deadline?.cancel()
                incoming.deadline = timeout(seconds: 2) { [weak self] in self?.responseFinished() }
                let body = "<!doctype html><meta name=\"viewport\" content=\"width=device-width\"><title>Bighelp</title>"
                    + Self.receivedMessage
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nPragma: no-cache\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n" + body
                incoming.connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
                    Task { @MainActor [weak self] in self?.responseFinished() }
                })
            } else if ended { close(id) }
            else { receive(id) }
        } catch {
            // Favicon, malicious/invalid requests and slow clients cannot consume
            // the pending login. No server-supplied text or code is reflected.
            close(id)
        }
    }

    private func responseFinished() {
        guard let code = state.finishResponse() else { return }
        complete(.success(code))
        #if targetEnvironment(macCatalyst)
        // Signing in happened in the browser; open bighelp's own link to come
        // back to the front (no route handles it, so nothing else happens).
        if authorizeOpener == nil { UIApplication.shared.open(Self.returnURL) }
        #endif
    }

    private func fail(_ error: DirectHermesError) {
        guard state.cancel() else { return }
        complete(.failure(error))
    }

    private func complete(_ result: Result<String, DirectHermesError>) {
        let waiter = continuation
        continuation = nil
        // State was settled first. cancel() may synchronously trigger the sheet's
        // cancelled completion; it cannot replace success or resume the waiter twice.
        dispose()
        switch result {
        case .success(let code): waiter?.resume(returning: code)
        case .failure(let error): waiter?.resume(throwing: error)
        }
    }

    private func close(_ id: UUID) {
        guard let incoming = connections.removeValue(forKey: id) else { return }
        incoming.deadline?.cancel()
        incoming.connection.cancel()
    }

    private func dispose() {
        deadline?.cancel()
        deadline = nil
        for id in Array(connections.keys) { close(id) }
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        callback = nil
        webSession?.cancel()
        webSession = nil
    }

    private func timeout(seconds: UInt64, action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
            catch { return }
            action()
        }
    }
}
