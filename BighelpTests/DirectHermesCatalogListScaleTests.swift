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

    @Test func anchorIndexMatchesTheByteExactScan() throws {
        let workspace = try SessionWorkspaceStub()
        let owner = try #require(workspace.owner)
        let client = DirectHermesSessionCatalogClientTests.client(workspace)
        let identities = ["anchor", "stored", "row", "root", "registry", "é", "e\u{0301}",
                          "a:b", "a/b", "ROW", "runtime-only", "binding-registry-only"]
        func binding(_ anchor: String, profile: String) throws -> DirectHermesSessionCatalogClient.Binding {
            let id = try DirectHermesSessionIdentity.appID(owner: owner, profileID: profile, anchorID: anchor)
            return try .init(coordinate: .init(owner: owner, profileID: profile, sessionID: id,
                                               storedSessionID: anchor, runtimeSessionID: nil),
                             anchorID: anchor,
                             record: .init(id: id, kind: .direct, agentIDs: [profile], title: "Fixture"),
                             durability: .persisted, cwd: nil, canonicalRegistryID: nil)
        }
        let saved = try ["alpha", "é", "e\u{0301}"].flatMap { profile in
            try identities.map { try binding($0, profile: profile) }
        }
        let index = DirectHermesSessionCatalogClient.BindingAnchorIndex(saved)
        for profile in ["alpha", "é", "e\u{0301}"] {
            var incoming = try binding("anchor", profile: profile)
            incoming.coordinate = try .init(owner: owner, profileID: profile, sessionID: incoming.record.id,
                                             storedSessionID: "stored", runtimeSessionID: nil)
            incoming.catalog = .init(owner: owner, profileID: profile, rowID: "row", lineageRootID: "root",
                                     lineageIDs: ["row", "é", "a:b"], canonicalRegistryID: "registry")
            incoming.runtimeSessionKey = "runtime-only"
            incoming.canonicalRegistryID = "binding-registry-only"
            let expected = saved.filter { current in
                current.record.id != incoming.record.id
                    && DirectHermesSessionValidation.same(current.coordinate.profileID, profile)
                    && ["anchor", "stored", "row", "root", "registry", "é", "a:b"].contains {
                        $0.utf8.elementsEqual(current.anchorID.utf8)
                    }
            }
            let actual = index.bindings(anchoredIn: client.storedIdentities(of: incoming)).filter {
                $0.record.id != incoming.record.id
                    && DirectHermesSessionValidation.same($0.coordinate.profileID, profile)
            }
            #expect(Set(actual.map(\.record.id)) == Set(expected.map(\.record.id)))
            #expect(actual.count == expected.count, "Repeated row/lineage identities return each saved row once.")
        }
    }

    @Test(arguments: [false, true])
    func replacingOrRemovingBindingsInvalidatesTheAnchorIndex(remove: Bool) async throws {
        let workspace = try SessionWorkspaceStub()
        var rows = [DirectHermesSessionCatalogClientTests.session(id: "old")]
        workspace.handler = { operation, _ in
            switch operation {
            case .profilesList: return DirectHermesSessionCatalogClientTests.profiles()
            case .sessionsList:
                return ["sessions": .array(rows), "total": .integer(rows.count),
                        "limit": .integer(100), "offset": .integer(0)]
            case .sessionDelete: return ["ok": .boolean(true)]
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        let client = DirectHermesSessionCatalogClientTests.client(workspace)
        _ = try await client.list()
        let old = try #require(try await client.list().first)
        let retained: SessionRecord
        if remove {
            try await client.deleteNativeRow(old)
            retained = old
        } else {
            rows = [DirectHermesSessionCatalogClientTests.session(id: "replacement")]
            retained = try #require(try await client.list().first)
        }
        var next = try #require(DirectHermesSessionCatalogClientTests.session(id: "next").object)
        next["_lineage_ids"] = .array([.string("next"), .string(remove ? "old" : "replacement")])
        rows = [.object(next)]
        let result = try #require(try await client.list().first)
        if remove {
            #expect(result.id != old.id, "A removed binding cannot be resurrected from the cached index.")
        } else {
            #expect(result.id == retained.id, "The index uses the latest complete binding snapshot.")
        }
    }

}
