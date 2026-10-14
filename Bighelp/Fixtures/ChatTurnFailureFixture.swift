#if DEBUG
import Foundation
import SwiftUI

/// Demo of a turn that fails the way a Hermes host reports it, driven through
/// the real native chat: the first message gets a failed final with the
/// `error_surface` named by `-test-turn-failure <code>` (rate_limit by default;
/// also auth, billing, overloaded, model_not_found, context_overflow,
/// agent_init_failed), and every later send succeeds. Made-up content only.
@MainActor
struct ChatTurnFailureFixtureView: View {
    static let launchArgument = "-test-turn-failure"

    @State private var fixture: ChatTurnFailureFixture?
    @State private var opened: String?

    var body: some View {
        Group {
            if let fixture {
                ChatView(model: fixture.model, agentName: "Kai", agentRole: "Travel agent",
                         directHermesClient: fixture.client,
                         onNewChatTap: { opened = "New chat" },
                         onOpenProviderAccounts: { opened = "AI providers" })
                    .environment(\.chatSurfaceCapabilities, .standaloneDirect)
            } else {
                ProgressView("Preparing the failed-turn demo")
            }
        }
        .bighelpSheet(item: Binding(get: { opened.map(FixturePage.init) }, set: { opened = $0?.id })) { page in
            NavigationStack {
                Text("This demo stands in for \(page.id).")
                    .padding()
                    .navigationTitle(page.id)
                    .accessibilityIdentifier("turn-failure-fixture.opened")
            }
            .bighelpSheetSize(.compact)
        }
        .task {
            guard fixture == nil else { return }
            fixture = try? ChatTurnFailureFixture(code: Self.code)
        }
        .onDisappear { fixture?.close() }
    }

    private static var code: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: launchArgument), arguments.indices.contains(index + 1),
              !arguments[index + 1].hasPrefix("-") else { return "rate_limit" }
        return arguments[index + 1]
    }

    private struct FixturePage: Identifiable {
        let id: String
    }
}

@MainActor
private final class ChatTurnFailureFixture {
    let root: URL
    let rpc: ChatTurnFailureFixtureRPC
    let client: DirectHermesConversationClient
    let model: ChatModel

    init(code: String) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "turn-failure-ui-" + UUID().uuidString)
        rpc = ChatTurnFailureFixtureRPC(code: code)
        let drafts = DirectHermesDraftStore(root: root)
        client = try DirectHermesConversationClient(
            rpc: rpc, hostIdentity: "offline-turn-failure", profile: "kai",
            runtimeID: "fixture-runtime", storedID: "fixture-stored", title: "Weekend plans",
            epoch: "fixture-epoch", drafts: drafts
        )
        // The demo picker takes a Link-style session ID; the native chat's own ID has a colon.
        let controls = SessionRuntimeControlModel(sessionID: "demo-turn-failure", agentID: "kai",
                                                  messaging: DemoSessionControlMessaging())
        model = ChatModel(conversationID: client.conversationID, client: client, agentID: "kai",
                          initialItems: [], runtimeControls: controls)
        client.model = model
        rpc.client = client
    }

    func close() {
        client.suspend()
        try? FileManager.default.removeItem(at: root)
    }
}

/// Answers like a Hermes host: `prompt.submit` says `streaming`, then the
/// turn's events follow on the socket.
@MainActor
private final class ChatTurnFailureFixtureRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    weak var client: DirectHermesConversationClient?
    private let code: String
    private var submits = 0
    private var sequence = 0

    init(code: String) {
        self.code = code
    }

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        switch method {
        case "prompt.submit":
            submits += 1
            let fails = submits == 1
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.play(fails: fails)
            }
            return .object(["status": .string("streaming"), "user_row_id": .integer(10 + submits)])
        case "session.control.read":
            return .object(["control": .object(["goal": .null, "loop": .null, "heartbeat": .null,
                                                "revision": .string("fixture"), "updated_at": .integer(0)])])
        case "subagent.list":
            return .object(["subagents": .array([])])
        default:
            throw DirectHermesError.invalidResponse
        }
    }

    func disconnect() async {}

    private func play(fails: Bool) {
        if fails, code == "agent_init_failed" {
            // Hermes refuses before the turn starts: no message.start.
            emit("error", ["message": .string("Hermes could not start the assistant for this session.")])
        } else {
            emit("message.start", [:])
        }
        if fails {
            emit("message.complete", [
                "text": .string("The request failed. Your message was not answered."),
                "status": .string("error"), "error": .string("Demo provider refused the request"),
                "recoverable": .boolean(true), "error_surface": .object(surface),
                "billing": code == "billing"
                    ? .object(["provider_label": .string("Demo Cloud"),
                               "billing_url": .string("https://billing.example.com/credit")])
                    : .null,
            ])
        } else {
            emit("message.delta", ["text": .string("Here's a plan: a quiet ryokan near the station, then Arashiyama.")])
            emit("message.complete", ["text": .string("Here's a plan: a quiet ryokan near the station, then Arashiyama."),
                                      "status": .string("complete")])
        }
        emit("session.info", ["running": .boolean(false)])
    }

    private var surface: [String: BighelpJSONValue] {
        let layer: String = switch code {
        case "auth": "auth"
        case "billing": "billing"
        case "agent_init_failed": "runtime"
        default: "provider"
        }
        var value: [String: BighelpJSONValue] = [
            "layer": .string(layer), "code": .string(code),
            "retryable": .boolean(!["auth", "billing", "model_not_found", "context_overflow"].contains(code)),
        ]
        if code != "agent_init_failed" {
            value["provider"] = .string("demo-cloud")
            value["provider_label"] = .string("Demo Cloud")
            value["model"] = .string("demo-model")
        }
        if code == "rate_limit" {
            value["resets_at"] = .number(Date().addingTimeInterval(90 * 60).timeIntervalSince1970)
        }
        return value
    }

    private func emit(_ type: String, _ payload: [String: BighelpJSONValue]) {
        sequence += 1
        client?.receive(.init(type: type, sessionID: "fixture-runtime", payload: payload, sequence: sequence))
    }
}
#endif
