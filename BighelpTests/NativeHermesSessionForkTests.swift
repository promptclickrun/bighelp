import Foundation
import Testing
@testable import Bighelp

@MainActor
@Suite(.serialized)
struct NativeHermesSessionForkTests {
    /// Chat IDs saved on phones hold these keys, so their spelling must never change.
    @Test func sessionKeysAreURLSafeBase64WithoutPadding() {
        #expect(DirectHermesSessionIdentity.key("a") == "YQ")
        #expect(DirectHermesSessionIdentity.key("ab") == "YWI")
        #expect(DirectHermesSessionIdentity.key("??>") == "Pz8-")
        #expect(DirectHermesSessionIdentity.key("???") == "Pz8_")
        #expect(DirectHermesSessionIdentity.key("") == "")
    }

    @Test func branchPagesCompleteHistoryAndUsesServerAssignedIdentity() async throws {
        let fixture = try NativeForkWorkspaceFixture(rowCount: 205, usesOfficialHistoryEnvelope: true)
        let appID = try DirectHermesSessionIdentity.appID(
            owner: fixture.expectedOwner, profileID: "alpha", anchorID: fixture.sourceStoredID
        )
        let recentItems = (198...205).map { row in
            TimelineItem(
                id: "\(appID):row:\(row)",
                role: row.isMultiple(of: 2) ? .assistant : .human,
                sender: row.isMultiple(of: 2)
                    ? .agent(id: "alpha", snapshot: .init(name: "alpha"))
                    : .user(snapshot: .init(name: "You")),
                content: .message("message-\(row)"),
                metadata: .init(delivery: "Saved", sourceOrder: row)
            )
        }
        let source = SessionRecord(
            id: appID, kind: .direct, agentIDs: ["alpha"], title: "Source",
            remoteStoredID: fixture.sourceStoredID, remoteSource: "tui", items: recentItems,
            hasAcceptedMessage: true
        )
        let client = fixture.client()

        let fork = try await client.fork(record: source, throughItemID: "\(appID):row:201")

        let expectedChildID = try DirectHermesSessionIdentity.appID(
            owner: fixture.expectedOwner, profileID: "alpha", anchorID: fixture.childStoredID
        )
        #expect(fork.id == expectedChildID)
        #expect(fork.id != source.id)
        #expect(fork.remoteStoredID == fixture.childStoredID)
        #expect(fork.parentSessionID == source.id)
        #expect(fork.title == "Source · Fork")
        #expect(fork.items.count == 201)
        #expect(fork.items.last?.id == "\(appID):row:201")
        #expect(fork.items.last?.content == .message("message-201"))

        let branch = try #require(fixture.calls.last(where: { $0.operation == .sessionBranch }))
        #expect(branch.payload == [
            "session_id": .string(fixture.parentRuntimeID),
            "count": .integer(201),
            "name": .string("Source · Fork")
        ])
        #expect(fixture.calls.filter { $0.operation == .sessionHistory }.count == 2)
        #expect(fixture.calls.filter { $0.operation == .sessionBranch }.count == 1)
    }

    @Test func branchRejectsReturnedCountProfileParentOrMessageDigest() async throws {
        for corruption in NativeForkWorkspaceFixture.Corruption.allCases {
            let fixture = try NativeForkWorkspaceFixture(rowCount: 12, corruption: corruption)
            let appID = try DirectHermesSessionIdentity.appID(
                owner: fixture.expectedOwner, profileID: "alpha", anchorID: fixture.sourceStoredID
            )
            let source = SessionRecord(
                id: appID, kind: .direct, agentIDs: ["alpha"], title: "Source",
                remoteStoredID: fixture.sourceStoredID,
                items: [TimelineItem(
                    id: "\(appID):row:12", role: .assistant,
                    sender: .agent(id: "alpha", snapshot: .init(name: "alpha")),
                    content: .message("message-12"), metadata: .init()
                )], hasAcceptedMessage: true
            )

            await #expect(throws: WorkspaceClientError.invalidResponse) {
                try await fixture.client().fork(record: source, throughItemID: "\(appID):row:12")
            }
            #expect(fixture.calls.filter { $0.operation == .sessionBranch }.count == 1)
        }
    }

    @Test func branchDoesNotRetryWhenTheMutationOutcomeIsUncertain() async throws {
        let fixture = try NativeForkWorkspaceFixture(rowCount: 12, branchError: .outcomeUnknown)
        let appID = try DirectHermesSessionIdentity.appID(
            owner: fixture.expectedOwner, profileID: "alpha", anchorID: fixture.sourceStoredID
        )
        let source = SessionRecord(
            id: appID, kind: .direct, agentIDs: ["alpha"], title: "Source",
            remoteStoredID: fixture.sourceStoredID,
            items: [TimelineItem(
                id: "\(appID):row:12", role: .assistant,
                sender: .agent(id: "alpha", snapshot: .init(name: "alpha")),
                content: .message("message-12"), metadata: .init()
            )], hasAcceptedMessage: true
        )

        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await fixture.client().fork(record: source, throughItemID: "\(appID):row:12")
        }
        #expect(fixture.calls.filter { $0.operation == .sessionBranch }.count == 1)
    }

    @Test func branchStopsAtOwnerBoundaryAfterHostReceipt() async throws {
        let fixture = try NativeForkWorkspaceFixture(rowCount: 12, retireOwnerOnBranch: true)
        let appID = try DirectHermesSessionIdentity.appID(
            owner: fixture.expectedOwner, profileID: "alpha", anchorID: fixture.sourceStoredID
        )
        let source = SessionRecord(
            id: appID, kind: .direct, agentIDs: ["alpha"], title: "Source",
            remoteStoredID: fixture.sourceStoredID,
            items: [TimelineItem(
                id: "\(appID):row:12", role: .assistant,
                sender: .agent(id: "alpha", snapshot: .init(name: "alpha")),
                content: .message("message-12"), metadata: .init()
            )], hasAcceptedMessage: true
        )

        await #expect(throws: WorkspaceClientError.ownerChanged) {
            try await fixture.client().fork(record: source, throughItemID: "\(appID):row:12")
        }
        #expect(fixture.calls.filter { $0.operation == .sessionBranch }.count == 1)
    }
}

@MainActor
private final class NativeForkWorkspaceFixture: WorkspaceOperationPerforming {
    enum Corruption: CaseIterable {
        case count
        case profile
        case parent
        case message
    }

    struct Call {
        let operation: WorkspaceOperation
        let payload: [String: BighelpJSONValue]
    }

    let expectedOwner: WorkspaceOwner
    let sourceStoredID = "source-stored"
    let parentRuntimeID = "parent-runtime"
    let childStoredID = "child-stored-server"
    let childRuntimeID = "child-runtime-server"
    let rowCount: Int
    let corruption: Corruption?
    let branchError: WorkspaceClientError?
    let retireOwnerOnBranch: Bool
    let usesOfficialHistoryEnvelope: Bool
    var calls: [Call] = []
    var currentOwner: WorkspaceOwner?
    var owner: WorkspaceOwner? { currentOwner }

    var capabilities: WorkspaceCapabilities { .init(owner: owner) }

    init(rowCount: Int, corruption: Corruption? = nil, branchError: WorkspaceClientError? = nil,
         retireOwnerOnBranch: Bool = false, usesOfficialHistoryEnvelope: Bool = false) throws {
        self.expectedOwner = WorkspaceOwner(
            authority: try .fixture(id: "native-fork-tests"),
            authenticationGeneration: UUID(), connectionGeneration: UUID()
        )
        self.rowCount = rowCount
        self.corruption = corruption
        self.branchError = branchError
        self.retireOwnerOnBranch = retireOwnerOnBranch
        self.usesOfficialHistoryEnvelope = usesOfficialHistoryEnvelope
        self.currentOwner = expectedOwner
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                 owner expectedOwner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        guard expectedOwner == self.expectedOwner, currentOwner == self.expectedOwner else {
            throw WorkspaceClientError.ownerChanged
        }
        calls.append(.init(operation: operation, payload: payload))
        switch operation {
        case .profilesList:
            return ["profiles": .array([.object([
                "name": .string("alpha"), "display_name": .string("Alpha"),
                "canonical_session": .null
            ])])]
        case .sessionResume:
            return ["session_id": .string(parentRuntimeID), "session_key": .string(sourceStoredID),
                    "resumed": .string(sourceStoredID), "running": .boolean(false),
                    "info": .object(["profile_name": .string("alpha"), "model": .string("model")])]
        case .sessionHistory:
            let offset = try #require(payload["offset"]?.integer)
            let limit = try #require(payload["limit"]?.integer)
            let values: [BighelpJSONValue]
            if offset == 0 {
                values = (1...min(rowCount, 200)).map(row)
            } else {
                values = (offset + 1...rowCount).map(row)
            }
            var result: [String: BighelpJSONValue] = ["session_id": .string(sourceStoredID),
                    "pagination": .object([
                        "offset": .integer(offset), "limit": .integer(limit),
                        "order": .string(payload["order"]?.string ?? ""),
                        "returned": .integer(values.count)
                    ])]
            if usesOfficialHistoryEnvelope {
                result["data"] = .array(values)
            } else {
                result["profile"] = .string("alpha")
                result["messages"] = .array(values)
            }
            return result
        case .sessionBranch:
            if let branchError { throw branchError }
            if retireOwnerOnBranch { currentOwner = nil }
            let requestedCount = payload["count"]?.integer ?? rowCount
            let returnedCount = corruption == .count ? requestedCount - 1 : requestedCount
            let returnedProfile = corruption == .profile ? "foreign" : "alpha"
            let returnedParent = corruption == .parent ? "foreign-parent" : sourceStoredID
            var messages = (1...max(0, requestedCount)).map(wireMessage)
            if corruption == .message, !messages.isEmpty {
                messages[messages.count - 1] = .object(["role": .string("assistant"), "text": .string("tampered")])
            }
            return ["session_id": .string(childRuntimeID), "stored_session_id": .string(childStoredID),
                    "title": .string("Source · Fork"), "parent": .string(returnedParent),
                    "message_count": .integer(returnedCount), "messages": .array(messages),
                    "info": .object(["profile_name": .string(returnedProfile), "model": .string("model"),
                                     "provider": .string("provider"), "running": .boolean(false)])]
        default:
            throw WorkspaceClientError.invalidRequest
        }
    }

    func client() -> DirectHermesSessionCatalogClient {
        DirectHermesSessionCatalogClient(
            workspace: self, owner: expectedOwner, currentOwner: { [weak self] in self?.currentOwner },
            now: { Date(timeIntervalSince1970: 100) }
        )
    }

    private func row(_ id: Int) -> BighelpJSONValue {
        .object([
            "id": .integer(id), "session_id": .string(sourceStoredID),
            "role": .string(id.isMultiple(of: 2) ? "assistant" : "user"),
            "content": .string("message-\(id)"), "timestamp": .number(Double(id))
        ])
    }

    private func wireMessage(_ id: Int) -> BighelpJSONValue {
        .object([
            "role": .string(id.isMultiple(of: 2) ? "assistant" : "user"), "row_id": .integer(id),
            "text": .string("message-\(id)")
        ])
    }
}
