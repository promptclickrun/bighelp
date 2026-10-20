import Foundation
import Testing
@testable import Bighelp

/// A host with thousands of scheduled runs lists them all, 100 a page, on every
/// `sessions.changed`. The second list, with every row already bound, must stay cheap.
@MainActor
struct DirectHermesCatalogListScaleTests {
    private static let rowCount = 4_350

    @Test func relistingThousandsOfBoundChatsStaysCheap() async throws {
        let workspace = try SessionWorkspaceStub()
        let rows: [BighelpJSONValue] = (0..<Self.rowCount).map { index in
            var row = DirectHermesSessionCatalogClientTests.session(id: "run-\(index)").object!
            row["source"] = .string(index % 5 == 0 ? "telegram" : "cron")
            row["last_active"] = .number(Double(1_700_000_000 + index * 900))
            return .object(row)
        }
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return DirectHermesSessionCatalogClientTests.profiles()
            case .sessionsList:
                let offset = payload["offset"]?.integer ?? 0
                let page = Array(rows.dropFirst(offset).prefix(100))
                return ["sessions": .array(page), "total": .integer(rows.count), "offset": .integer(offset),
                        "limit": .integer(100), "has_more": .boolean(offset + 100 < rows.count)]
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = DirectHermesSessionCatalogClientTests.client(workspace)
        let first = try await client.list()
        #expect(first.count == Self.rowCount)
        let pagesBefore = workspace.calls.filter { $0.operation == .sessionsList }.count

        let start = ContinuousClock.now
        let second = try await client.list()
        let elapsed = ContinuousClock.now - start
        let pages = workspace.calls.filter { $0.operation == .sessionsList }.count - pagesBefore
        print("CATALOG_RELIST rows=\(second.count) pages=\(pages) elapsed=\(elapsed)")
        #expect(second.count == Self.rowCount)
        #expect(elapsed < .milliseconds(500), "Binding the host's rows must be linear in the number of chats.")
    }
}
