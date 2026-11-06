import Foundation
import Network
@testable import Bighelp

/// A loopback stand-in for Hermes' WebSocket: says `gateway.ready` when the app connects,
/// answers every request at once, and can hold its `gateway.ping` answers or send an event,
/// for checks of what the real connection does.
final class LoopbackHermesSocket: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "bighelp.test.loopback-socket")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var holdsPings = false
    private var heldPings: [String] = []
    private var pingCount = 0
    private var started = false

    /// `gateway.ping` requests seen so far.
    var pings: Int { lock.withLock { pingCount } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    deinit {
        connection?.cancel()
        listener.cancel()
    }

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
                lock.withLock { self.connection = connection }
                connection.stateUpdateHandler = { [self] state in
                    if case .ready = state { send(event: "gateway.ready") }
                }
                connection.start(queue: queue)
                receive(on: connection)
            }
            listener.start(queue: queue)
        }
    }

    /// A client on this socket, with the saved sign-in a loopback host uses.
    @MainActor
    func connect() async throws -> DirectHermesClient {
        let port = try await start()
        let endpoint = try DirectHermesEndpoint(address: "http://127.0.0.1:\(port)", allowPrivateHTTP: true)
        let saved = DirectHermesSavedConnection(endpoint: endpoint, authentication: .legacyLoopbackToken("loopback-test"))
        return try await DirectHermesClient.openedForTesting(saved, vault: MemoryVault(saved))
    }

    /// Pings wait for `releasePings()`, the way a connection that went quiet doesn't answer.
    func holdPings() { lock.withLock { holdsPings = true } }

    func releasePings() {
        let held = lock.withLock {
            holdsPings = false
            defer { heldPings = [] }
            return heldPings
        }
        held.forEach(answer)
    }

    func send(event type: String) {
        send(#"{"jsonrpc":"2.0","method":"event","params":{"type":"\#(type)","payload":{}}}"#)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [self] content, _, _, error in
            guard error == nil else { return }
            if let content, let object = try? JSONSerialization.jsonObject(with: content) as? [String: Any],
               let id = object["id"] as? String {
                let held = lock.withLock { () -> Bool in
                    guard object["method"] as? String == "gateway.ping" else { return false }
                    pingCount += 1
                    if holdsPings { heldPings.append(id) }
                    return holdsPings
                }
                if !held { answer(id) }
            }
            receive(on: connection)
        }
    }

    private func answer(_ id: String) {
        send(#"{"jsonrpc":"2.0","id":"\#(id)","result":{}}"#)
    }

    private func send(_ text: String) {
        guard let connection = lock.withLock({ connection }) else { return }
        let context = NWConnection.ContentContext(identifier: "frame",
                                                  metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }
}
