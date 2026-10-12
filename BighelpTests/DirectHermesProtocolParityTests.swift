import Foundation
import Testing
@testable import Bighelp

struct DirectHermesProtocolParityTests {
    @Test func nativeBrowserCapabilityDoesNotRequireProviderPickerMetadata() {
        let advertised = DirectHermesAuthenticationDiscovery(
            authRequired: true, flows: ["cookie", "native_pkce"], providers: []
        )
        #expect(advertised.supportsNativePKCE)
        #expect(advertised.passwordProviders.isEmpty)
        #expect(!DirectHermesAuthenticationDiscovery(
            authRequired: true, flows: ["cookie"], providers: []
        ).supportsNativePKCE)
        #expect(!DirectHermesAuthenticationDiscovery(
            authRequired: false, flows: ["native_pkce"], providers: []
        ).supportsNativePKCE)
    }

    @Test func opaqueRequestIDsRemainByteDistinctThroughCancellation() {
        let composed = "request:\u{00e9}"
        let decomposed = "request:e\u{0301}"
        let a = DirectHermesServerRequest(id: composed, method: "approval", params: [:])
        let b = DirectHermesServerRequest(id: decomposed, method: "approval", params: [:])
        #expect(a != b)
        var state = DirectHermesServerRequestState()
        let first = state.register(a)
        let second = state.register(b)
        #expect(first == .accepted && second == .accepted)
        #expect(state.count == 2)
        let staged = state.stageResponse(id: composed, method: "approval")
        #expect(staged)
        let cancelled = state.cancel(.init(id: decomposed, method: "approval", reason: "expired"))
        #expect(cancelled)
        #expect(state.contains(id: composed, method: "approval"))
        let sending = state.beginSendingResponse(id: composed, method: "approval")
        #expect(sending && state.count == 0)
    }

    @Test func queuedResponseRemainsCancellableAndWrongMethodCannotRetireIt() {
        var state = DirectHermesServerRequestState()
        let request = DirectHermesServerRequest(id: "original", method: "approval", params: [:])
        let admitted = state.register(request)
        let duplicate = state.register(request)
        #expect(admitted == .accepted && duplicate == .duplicate)
        let staged = state.stageResponse(id: request.id, method: request.method)
        let restaged = state.stageResponse(id: request.id, method: request.method)
        #expect(staged && !restaged)
        let wrong = state.cancel(.init(id: request.id, method: "clarify", reason: "expired"))
        #expect(!wrong && state.count == 1)
        let cancelled = state.cancel(.init(id: request.id, method: request.method, reason: "expired"))
        let late = state.beginSendingResponse(id: request.id, method: request.method)
        #expect(cancelled && !late && state.count == 0)
    }

    @Test func serverRequestCapacityAndRetirementRemainBounded() {
        var state = DirectHermesServerRequestState()
        for index in 0..<DirectHermesServerRequestState.maximumOpenRequests {
            let result = state.register(.init(id: "request-\(index)", method: "clarify", params: [:]))
            #expect(result == .accepted)
        }
        let overflow = state.register(.init(id: "overflow", method: "clarify", params: [:]))
        #expect(overflow == .atCapacity)
        state.removeAll()
        let stale = state.stageResponse(id: "request-0", method: "clarify")
        #expect(!stale && state.count == 0)
    }

    @Test(arguments: ["", " leading and trailing ", "request:\u{00e9}", "request:e\u{0301}"])
    func responseFramesReturnExactOriginalIDWithoutBecomingRequests(id: String) throws {
        for response in [DirectHermesServerResponse.result(.object(["accepted": .boolean(false)])),
                         .error(code: -32601, message: "Unsupported")] {
            let text = try DirectHermesWire.encodeServerResponse(id: id, response: response)
            let object = try #require(JSONDecoder().decode(BighelpJSONValue.self, from: Data(text.utf8)).object)
            let returnedID = try #require(object["id"]?.string)
            #expect(returnedID.utf8.elementsEqual(id.utf8))
            #expect(object["jsonrpc"] == .string("2.0"))
            #expect(object["method"] == nil && object["params"] == nil)
            switch response {
            case .result(let value):
                #expect(object["result"] == value && object["error"] == nil)
            case .error(let code, _, _):
                #expect(object["error"]?.object?["code"]?.integer == code && object["result"] == nil)
            }
        }
    }

    @Test func cancellationDecodesTheDocumentedExactPayload() throws {
        let id = "request:e\u{0301}"
        let payload: [String: BighelpJSONValue] = [
            "id": .string(id), "method": .string("clarify"), "reason": .string("expired"),
        ]
        let event = DirectHermesEvent(type: "request.cancel", sessionID: nil, payload: payload, sequence: nil)
        let cancellation = try DirectHermesWire.cancellation(in: event)
        #expect(cancellation.id.utf8.elementsEqual(id.utf8))
        #expect(cancellation.method == "clarify" && cancellation.reason == "expired")
        for key in payload.keys {
            var incomplete = payload
            incomplete.removeValue(forKey: key)
            let invalid = DirectHermesEvent(type: "request.cancel", sessionID: nil, payload: incomplete, sequence: nil)
            #expect(throws: DirectHermesError.invalidResponse) { try DirectHermesWire.cancellation(in: invalid) }
        }
    }

    @Test func ambiguousAndMalformedServerRequestEnvelopesAreRejected() throws {
        let invalid: [[String: BighelpJSONValue]] = [
            ["method": .string("approval"), "id": .string("id"), "result": .null],
            ["method": .string("event"), "id": .string("id"), "params": .object(["type": .string("gateway.ready")])],
            ["method": .string("approval"), "id": .integer(1)],
            ["method": .string("approval"), "id": .string("id"), "params": .array([])],
            ["method": .integer(1), "id": .string("id")],
            ["method": .string("approval"), "id": .string(String(repeating: "x", count: DirectHermesWire.maximumRequestIDBytes + 1))],
        ]
        for var object in invalid {
            object["jsonrpc"] = .string("2.0")
            let data = try JSONEncoder().encode(BighelpJSONValue.object(object))
            #expect(throws: DirectHermesError.invalidResponse) { try DirectHermesWire.decode(data) }
        }
    }

    // Frame-level coverage for every server-request method in the supplied
    // v2026.9.14 catalog. Business payload validation is a separate boundary.
    @Test(arguments: [
        "approval", "clarify", "mcp.setup", "preview.act", "preview.read",
        "secret", "sudo", "terminal.read", "tour", "vault.code",
        "vault.save_login", "vault.unlock_prompt", "window.read",
    ])
    func documentedServerRequestFramesDoNotDisconnectTheClient(method: String) throws {
        let frame = BighelpJSONValue.object([
            "jsonrpc": .string("2.0"), "id": .string("server-request:original-id"),
            "method": .string(method), "params": .object([:]),
        ])
        let messages = try DirectHermesWire.decode(JSONEncoder().encode(frame))
        #expect(messages.count == 1)
        guard case .request(let request) = try #require(messages.first) else {
            Issue.record("Server request was decoded as a reply or notification")
            return
        }
        #expect(request.id == "server-request:original-id")
        #expect(request.method == method)
    }

    /// Hermes says why it refused in `error.data.reason`: 4090 is a chat another Hermes
    /// process holds (`SESSION_NOT_OWNED`) or its cap on open chats (`MAX_CONCURRENT_SESSIONS`).
    @Test func refusalsKeepHermesReason() throws {
        let frame = BighelpJSONValue.object([
            "jsonrpc": .string("2.0"), "id": .string("request-1"),
            "error": .object(["code": .integer(4090), "message": .string("Active session limit reached"),
                              "data": .object(["reason": .string("MAX_CONCURRENT_SESSIONS")])]),
        ])
        guard case .failure(let id, let code, let reason, let message) = try #require(try DirectHermesWire.decode(JSONEncoder().encode(frame)).first) else {
            Issue.record("Refusal was not decoded as a failure")
            return
        }
        #expect(id == "request-1" && code == 4090 && reason == "MAX_CONCURRENT_SESSIONS")
        #expect(message.text == "Active session limit reached")
    }
}
