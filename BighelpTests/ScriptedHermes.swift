import Foundation
import Network

/// A loopback stand-in for Hermes that answers each request from a script.
final class ScriptedHermes: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        var body = ""
        func header(_ name: String) -> String? { headers[name] }
    }

    enum Reply: Sendable {
        case status(Int)
        case json(String)
        case html(String)
        /// Any status, type and extra headers, like a proxy or Cloudflare page.
        case raw(Int, type: String, headers: [String: String] = [:], body: String)
        /// Hangs up without answering, like a connection cut off mid-request.
        case drop
        /// Answers after a pause.
        indirect case after(TimeInterval, Reply)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "bighelp.test.scripted-hermes")
    private let lock = NSLock()
    private let script: @Sendable (Request) -> Reply
    private var seen: [String] = []
    private var seenBodies: [String] = []
    private var started = false
    var paths: [String] { lock.withLock { seen } }
    var bodies: [String] { lock.withLock { seenBodies } }

    init(_ script: @escaping @Sendable (Request) -> Reply) throws {
        self.script = script
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    deinit { listener.cancel() }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    guard lock.withLock({ defer { started = true }; return !started }) else { return }
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    guard lock.withLock({ defer { started = true }; return !started }) else { return }
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                receive(connection, prefix: Data())
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, prefix: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
            guard error == nil, let data else { connection.cancel(); return }
            let buffer = prefix + data
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { connection.cancel() } else { receive(connection, prefix: buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let line = head.first?.split(separator: " ") ?? []
            guard line.count >= 2 else { connection.cancel(); return }
            var headers: [String: String] = [:]
            for field in head.dropFirst() {
                guard let colon = field.firstIndex(of: ":") else { continue }
                headers[field[..<colon].lowercased()] = field[field.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            // Wait for the whole body before answering.
            let expected = Int(headers["content-length"] ?? "0") ?? 0
            let received = buffer.count - end.upperBound
            guard received >= expected || complete else { receive(connection, prefix: buffer); return }
            let requestBody = String(decoding: buffer[end.upperBound...], as: UTF8.self)
            let path = String(line[1].split(separator: "?").first ?? "")
            lock.withLock { seen.append(path); seenBodies.append(requestBody) }
            answer(connection, script(Request(method: String(line[0]), path: path, headers: headers, body: requestBody)))
        }
    }

    private func answer(_ connection: NWConnection, _ reply: Reply) {
        let (status, type, body): (Int, String, String)
        var extra: [String: String] = [:]
        switch reply {
        case .drop:
            connection.cancel()
            return
        case .after(let delay, let later):
            queue.asyncAfter(deadline: .now() + delay) { [self] in answer(connection, later) }
            return
        case .status(let code): (status, type, body) = (code, "application/json", "{\"detail\":\"fixture\"}")
        case .json(let text): (status, type, body) = (200, "application/json", text)
        case .html(let text): (status, type, body) = (200, "text/html; charset=utf-8", text)
        case .raw(let code, let kind, let headers, let text): (status, type, body, extra) = (code, kind, text, headers)
        }
        let bytes = Data(body.utf8)
        let response = "HTTP/1.1 \(status) Fixture\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\n"
            + extra.map { "\($0.key): \($0.value)\r\n" }.joined()
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8) + bytes, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
