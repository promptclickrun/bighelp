import Foundation

/// The smallest slice of the app's gateway protocol a share needs: mint a single-use
/// ticket over HTTPS, open `/api/ws` with it, then send JSON-RPC frames — the same two
/// steps `DirectHermes/DirectHermesAuthentication.swift` takes (`mintTicket`,
/// `websocketRequest`), without the app's socket, event projection and queues.
@MainActor
final class ShareRPC {
    enum Failure: LocalizedError {
        case signInExpired
        case unreachable
        case refused
        case invalidResponse
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .signInExpired:
                return "bighelp needs you to sign in again. Open the app once, then share this again."
            case .unreachable:
                return "Couldn't reach your computer. Check the VPN or Tailscale, then try again."
            case .refused:
                return "Your computer refused this share."
            case .invalidResponse:
                return "Your computer answered in a way bighelp didn't understand."
            case .tooLarge:
                return "That's too big to send from the share sheet."
            }
        }
    }

    private let credential: ShareCredential
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var sequence = 0

    init(credential: ShareCredential) {
        self.credential = credential
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// Where the reply carries more than the caller needs, `[String: Any]` keeps the
    /// reading honest without a decoder for every shape on the host.
    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let socket = try await openSocketIfNeeded()
        sequence += 1
        let id = "share-\(sequence)"
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: frame) }
        catch { throw Failure.invalidResponse }
        guard data.count <= 24 * 1_024 * 1_024 else { throw Failure.tooLarge }
        do { try await socket.send(.data(data)) } catch { throw Failure.unreachable }
        while true {
            let message: URLSessionWebSocketTask.Message
            do { message = try await socket.receive() } catch { throw Failure.unreachable }
            let payload: Data
            switch message {
            case .data(let bytes): payload = bytes
            case .string(let text): payload = Data(text.utf8)
            @unknown default: throw Failure.invalidResponse
            }
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
            // The host pushes events and server requests down this same socket; only the
            // frame answering this call is ours.
            guard object["id"] as? String == id else { continue }
            if let error = object["error"] as? [String: Any] {
                throw ShareRefusal(message: error["message"] as? String,
                                   code: (error["code"] as? NSNumber)?.intValue)
            }
            return object["result"] as? [String: Any] ?? [:]
        }
    }

    /// Leaves the socket to die with the extension. A share never calls `session.close`:
    /// the turn it started has to finish on the host after this sheet goes away.
    func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func openSocketIfNeeded() async throws -> URLSessionWebSocketTask {
        if let socket, socket.state == .running { return socket }
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil

        var query: [URLQueryItem] = []
        var protocols: String?
        var legacyToken: String?
        switch credential.kind {
        case .bearer:
            // Every socket consumes its own ticket; none is reused.
            let ticket = try await mintTicket()
            protocols = "hermes-gateway-v1, hermes-gateway-ticket." + ticket
        case .dashboard:
            guard let token = credential.accessToken, !token.isEmpty else { throw Failure.signInExpired }
            query = [URLQueryItem(name: "token", value: token)]
            legacyToken = token
        }

        guard var components = URLComponents(url: try url(for: "/api/ws"), resolvingAgainstBaseURL: false) else {
            throw Failure.invalidResponse
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw Failure.invalidResponse }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        if let protocols { request.setValue(protocols, forHTTPHeaderField: "Sec-WebSocket-Protocol") }
        if let legacyToken { request.setValue(legacyToken, forHTTPHeaderField: "X-Hermes-Session-Token") }

        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 24 * 1_024 * 1_024
        task.resume()
        socket = task
        return task
    }

    private func mintTicket() async throws -> String {
        guard let token = credential.accessToken, !token.isEmpty else { throw Failure.signInExpired }
        var request = URLRequest(url: try url(for: "/api/auth/ws-ticket"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data("{}".utf8)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw Failure.unreachable }
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw Failure.signInExpired }
        guard http.statusCode == 200, data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ticket = object["ticket"] as? String, !ticket.isEmpty else { throw Failure.invalidResponse }
        return ticket
    }

    private func url(for route: String) throws -> URL {
        var base = credential.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + route) else { throw Failure.invalidResponse }
        return url
    }
}

/// A rejection the host named, so the sheet can show the host's own words.
struct ShareRefusal: LocalizedError {
    let message: String?
    let code: Int?

    var errorDescription: String? {
        if let message, !message.isEmpty, message.utf8.count <= 400 { return message }
        return "Your computer refused this share."
    }
}
