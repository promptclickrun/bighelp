import Foundation

/// Opens Bot Screen's RFB socket (`/api/display/ws`) on this connection's URLSession,
/// so it carries the same proxy and Cloudflare Access headers and the same TLS trust
/// and redirect rules as `/api/ws`. The single-use, 30-second display ticket from
/// `display.observe` is its only credential: the gateway's own login is never sent.
@MainActor
final class DirectHermesBotScreenStreams {
    /// Hermes' bridge sends at most 64 KB per message.
    static let maximumMessageBytes = 1_024 * 1_024

    private let authenticator: DirectHermesAuthenticator
    private let isCurrent: @MainActor () -> Bool

    init(authenticator: DirectHermesAuthenticator, isCurrent: @escaping @MainActor () -> Bool) {
        self.authenticator = authenticator
        self.isCurrent = isCurrent
    }

    func open(_ observation: BotScreenObservation) throws -> any RFBTransport {
        guard isCurrent() else { throw WorkspaceClientError.ownerChanged }
        let request = try authenticator.botScreenStreamRequest(path: observation.path, ticket: observation.ticket)
        let task = authenticator.http.session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageBytes
        let socket = DirectHermesBotScreenSocket(task: task)
        task.resume()
        // Signing out or picking another computer ends the screen at once.
        let isCurrent = isCurrent
        Task { @MainActor [weak socket] in
            while let live = socket, !live.isFinished {
                guard isCurrent() else { live.close(handBack: false); return }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
        return socket
    }
}

/// One RFB socket. `URLSessionWebSocketTask` is thread-safe and every property here
/// is a constant, so the wrapper can cross actors.
final class DirectHermesBotScreenSocket: RFBTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) { self.task = task }

    func send(_ data: Data) async throws { try await task.send(.data(data)) }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        // RFB is binary; Hermes closes a socket that sends text, and never sends any.
        case .string: throw RFBError.protocolViolation("text message")
        @unknown default: throw RFBError.protocolViolation("unknown message")
        }
    }

    func close(handBack: Bool) {
        // 1000 is Hermes' "the viewer closed the window"; a plain cancel is a dropped link.
        if handBack { task.cancel(with: .normalClosure, reason: nil) } else { task.cancel() }
    }

    var closeCode: Int? {
        let code = task.closeCode.rawValue
        return code == URLSessionWebSocketTask.CloseCode.invalid.rawValue ? nil : code
    }

    var isFinished: Bool { task.state == .completed || task.state == .canceling }
}

extension DirectHermesAuthenticator {
    /// `wss://host/api/display/ws?display_ticket=…`: Hermes takes the ticket in the query on
    /// purpose (it's spent on first use and expires in 30 seconds).
    func botScreenStreamRequest(path: String, ticket: String) throws -> URLRequest {
        guard path == BotScreenObservation.streamPath, !ticket.isEmpty, ticket.utf8.count <= 1_024 else {
            throw WorkspaceClientError.invalidRequest
        }
        guard var components = URLComponents(url: try http.endpoint.url(for: path), resolvingAgainstBaseURL: false) else {
            throw DirectHermesError.invalidEndpoint
        }
        components.scheme = http.endpoint.baseURL.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "display_ticket", value: ticket)]
        guard let url = components.url else { throw DirectHermesError.invalidEndpoint }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        http.applyAccessHeaders(to: &request)
        return request
    }
}
