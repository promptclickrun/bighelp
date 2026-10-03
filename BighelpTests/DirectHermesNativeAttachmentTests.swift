import Foundation
import Testing
import UIKit
@testable import Bighelp

/// Agent `MEDIA:` deliveries resolve through the plugin's provenance-bound route.
@MainActor
struct DirectHermesNativeAttachmentTests {
    @Test func assistantMediaResolvesThroughPluginInBoundedChunksAndStripsTheDirective() async throws {
        let owner = try makeOwner()
        let http = AttachmentHTTP(features: ["native-agent-attachments-v1"])
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 10, height: 10)).pdfData { $0.beginPage() }
        http.file = pdf
        http.chunk = 40
        let workspace = DirectHermesWorkspaceClient(rpc: NoRPC(), http: http, owner: owner,
                                                    capabilities: .init(owner: owner), currentOwner: { owner })
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        let text = "Here is the report. MEDIA://Users/me/Downloads/Report.pdf"
        let result = try #require(try await resolver.resolve(agentID: "default", storedID: "stored",
                                                             items: [.init(id: "m1", text: text)]).first)
        #expect(result.text == "Here is the report.")
        #expect(result.attachments.map(\.fileName) == ["Report.pdf"])
        #expect(result.attachments.first?.data == pdf)
        #expect(result.attachments.first?.mimeType == "application/pdf")
        let paths = http.requests.map(\.path).filter { !$0.hasSuffix("/context") }
        #expect(paths.first == "/api/plugins/loopdy/native/attachments/resolve")
        #expect(paths.dropFirst().allSatisfy { $0 == "/api/plugins/loopdy/native/attachments/fetch" })
        #expect(paths.count == 1 + (pdf.count + 39) / 40)
        #expect(!http.requests.contains { $0.path == "/api/media" || $0.path == "/api/files/read" })
    }

    /// A piece lost to a timeout is asked for again from where it was,
    /// instead of failing the file and starting it all over.
    @Test func aDroppedPieceIsAskedForAgainWhereItStopped() async throws {
        let owner = try makeOwner()
        let http = AttachmentHTTP(features: ["native-agent-attachments-v1"])
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 10, height: 10)).pdfData { $0.beginPage() }
        http.file = pdf
        http.chunk = 40
        http.failOnce = [80]
        let workspace = DirectHermesWorkspaceClient(rpc: NoRPC(), http: http, owner: owner,
                                                    capabilities: .init(owner: owner), currentOwner: { owner })
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        let result = try #require(try await resolver.resolve(agentID: "default", storedID: "stored",
            items: [.init(id: "m1", text: "MEDIA:/Users/me/Downloads/Report.pdf")]).first)
        #expect(result.attachments.first?.data == pdf)
        #expect(http.fetchedOffsets.filter { $0 == 80 }.count == 2)
        #expect(http.fetchedOffsets.filter { $0 == 40 }.count == 1)
        #expect(http.requests.filter { $0.path.hasSuffix("/resolve") }.count == 1)
    }

    /// After the first piece, the rest download a few at a time.
    @Test func piecesDownloadSideBySide() async throws {
        let owner = try makeOwner()
        let http = AttachmentHTTP(features: ["native-agent-attachments-v1"])
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 10, height: 10)).pdfData { $0.beginPage() }
        http.file = pdf
        http.chunk = 40
        http.fetchDelay = .milliseconds(15)
        let workspace = DirectHermesWorkspaceClient(rpc: NoRPC(), http: http, owner: owner,
                                                    capabilities: .init(owner: owner), currentOwner: { owner })
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        let result = try #require(try await resolver.resolve(agentID: "default", storedID: "stored",
            items: [.init(id: "m1", text: "MEDIA:/Users/me/Downloads/Report.pdf")]).first)
        #expect(result.attachments.first?.data == pdf)
        #expect(http.mostAtOnce > 1)
        #expect(http.mostAtOnce <= DirectHermesGeneratedMediaClient.parallelChunks)
    }

    /// A chat opened again shows its files from this phone, without asking the host.
    @Test func aFileOpenedAgainComesFromThisPhone() async throws {
        let owner = try makeOwner()
        let http = AttachmentHTTP(features: ["native-agent-attachments-v1"])
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 10, height: 10)).pdfData { $0.beginPage() }
        http.file = pdf
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AgentAttachmentCache(directory: directory)
        let workspace = DirectHermesWorkspaceClient(rpc: NoRPC(), http: http, owner: owner,
                                                    capabilities: .init(owner: owner), currentOwner: { owner })
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner },
                                                        cache: cache)
        let text = "Here is the report. MEDIA://Users/me/Downloads/Report.pdf"
        let first = try #require(try await resolver.resolve(agentID: "default", storedID: "stored",
                                                            items: [.init(id: "m1", text: text)]).first)
        let asked = http.requests.count
        let again = try #require(try await resolver.resolve(agentID: "default", storedID: "stored",
                                                            items: [.init(id: "m1", text: text)]).first)
        #expect(again.attachments == first.attachments)
        #expect(again.text == "Here is the report.")
        #expect(http.requests.count == asked)
        // Another chat with the same words isn't the same file.
        _ = try await resolver.resolve(agentID: "default", storedID: "other", items: [.init(id: "m1", text: text)])
        #expect(http.requests.count > asked)
    }

    @Test func theCacheDropsTheLeastRecentlyOpenedFilesFirst() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AgentAttachmentCache(directory: directory, maximumBytes: 30_000)
        func entry(_ byte: UInt8) throws -> AgentAttachmentCache.Entry {
            .init(text: "", attachments: [try .agentArtifact(id: "native_media_" + String(repeating: "a", count: 16),
                fileName: "a.bin", mimeType: "application/octet-stream", data: Data(repeating: byte, count: 7_000))])
        }
        for (index, name) in ["one", "two", "three"].enumerated() {
            await cache.store(try entry(UInt8(index)), for: name)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await cache.entry(for: "one") != nil)
        try await Task.sleep(for: .milliseconds(20))
        await cache.store(try entry(4), for: "four")
        try await Task.sleep(for: .milliseconds(20))
        await cache.store(try entry(5), for: "five")
        #expect(await cache.entry(for: "two") == nil)
        #expect(await cache.entry(for: "three") == nil)
        #expect(await cache.entry(for: "one") != nil)
        #expect(await cache.entry(for: "five") != nil)
    }

    @Test func refusedResolutionKeepsTheOriginalTextReadable() async throws {
        let owner = try makeOwner()
        let http = AttachmentHTTP(features: ["native-agent-attachments-v1"])
        http.file = nil
        let workspace = DirectHermesWorkspaceClient(rpc: NoRPC(), http: http, owner: owner,
                                                    capabilities: .init(owner: owner), currentOwner: { owner })
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        let text = "MEDIA:/etc/passwd.txt"
        let result = try #require(try await resolver.resolve(agentID: "default", storedID: "stored",
                                                             items: [.init(id: "m1", text: text)]).first)
        #expect(result.text == text)
        #expect(result.attachments.isEmpty)
    }

    @Test func hostsWithoutThePluginRouteFallBackToStockMediaReads() async throws {
        let owner = try makeOwner()
        let http = AttachmentHTTP(features: [])
        let workspace = DirectHermesWorkspaceClient(rpc: NoRPC(), http: http, owner: owner,
                                                    capabilities: .init(owner: owner), currentOwner: { owner })
        let resolver = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        _ = try? await resolver.resolve(agentID: "default", storedID: "stored",
                                        items: [.init(id: "m1", text: "MEDIA:/host/.hermes/cache/images/a.png")])
        #expect(http.requests.contains { $0.path == "/api/media" })
        #expect(!http.requests.contains { $0.path.contains("/attachments/") })
    }

    /// A Feed post's file: the phone names the post and the file's place in it, never a
    /// path; the host answers with an opaque ID that downloads like a chat file, and the
    /// copy is kept on the phone.
    @Test func aFeedPostsFileResolvesByPostAndPlaceThenDownloadsInChunks() async throws {
        let owner = try makeOwner()
        let http = AttachmentHTTP(features: ["native-agent-attachments-v1", "native-agent-board-v1",
                                             "native-agent-board-files-v1"])
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 10, height: 10)).pdfData { $0.beginPage() }
        http.file = pdf
        http.chunk = 40
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = DirectHermesWorkspaceClient(rpc: NoRPC(), http: http, owner: owner,
                                                    capabilities: .init(owner: owner), currentOwner: { owner })
        let files = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner },
                                                     cache: AgentAttachmentCache(directory: directory))
        let board = DirectHermesAgentBoardClient(workspace: workspace, owner: owner, supportsFeedback: true, files: files)
        #expect(board.supportsFiles)
        let file = AgentBoardItem.File(index: 1, fileName: "Report.pdf", mimeType: "application/pdf",
                                       byteCount: pdf.count, addedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let attachment = try await board.file(agentID: "default", itemID: "lisbon", file: file)
        #expect(attachment.data == pdf && attachment.fileName == "Report.pdf")
        let asked = http.requests.filter { !$0.path.hasSuffix("/context") }
        #expect(asked.first?.path == "/api/plugins/loopdy/native/attachments/board")
        #expect(asked.first?.body == ["agentId": .string("default"), "itemId": .string("lisbon"), "index": .integer(1)])
        #expect(asked.dropFirst().allSatisfy { $0.path.hasSuffix("/attachments/fetch") })
        #expect(asked.count == 1 + (pdf.count + 39) / 40)

        let count = http.requests.count
        #expect(try await board.file(agentID: "default", itemID: "lisbon", file: file).data == pdf)
        #expect(http.requests.count == count, "Opened again, it comes from this phone")
        // Attached again later: a new copy.
        let newer = AgentBoardItem.File(index: 1, fileName: "Report.pdf", mimeType: "application/pdf",
                                        byteCount: pdf.count, addedAt: Date(timeIntervalSince1970: 1_790_000_600))
        _ = try await board.file(agentID: "default", itemID: "lisbon", file: newer)
        #expect(http.requests.count > count)
    }

    @Test func aFileTheHostNoLongerServesIsUnavailable() async throws {
        let owner = try makeOwner()
        let http = AttachmentHTTP(features: ["native-agent-attachments-v1", "native-agent-board-v1",
                                             "native-agent-board-files-v1"])
        http.file = nil
        let workspace = DirectHermesWorkspaceClient(rpc: NoRPC(), http: http, owner: owner,
                                                    capabilities: .init(owner: owner), currentOwner: { owner })
        let files = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        let board = DirectHermesAgentBoardClient(workspace: workspace, owner: owner, supportsFeedback: true, files: files)
        let file = AgentBoardItem.File(index: 0, fileName: "moved.pdf", mimeType: "application/pdf", byteCount: 9)
        await #expect(throws: (any Error).self) {
            _ = try await board.file(agentID: "default", itemID: "lisbon", file: file)
        }
        #expect(!http.requests.contains { $0.path.hasSuffix("/attachments/fetch") })
    }

    @Test func olderPluginsAreNeverAskedForAPostsFiles() async throws {
        let owner = try makeOwner()
        let http = AttachmentHTTP(features: ["native-agent-attachments-v1", "native-agent-board-v1"])
        let workspace = DirectHermesWorkspaceClient(rpc: NoRPC(), http: http, owner: owner,
                                                    capabilities: .init(owner: owner), currentOwner: { owner })
        let files = DirectHermesGeneratedMediaClient(workspace: workspace, owner: owner, currentOwner: { owner })
        let file = AgentBoardItem.File(index: 0, fileName: "plan.pdf", mimeType: "application/pdf", byteCount: 9)
        // Without the feature the board client gets no file loader at all…
        let old = DirectHermesAgentBoardClient(workspace: workspace, owner: owner, supportsFeedback: true)
        #expect(!old.supportsFiles)
        await #expect(throws: WorkspaceClientError.self) {
            _ = try await old.file(agentID: "default", itemID: "a", file: file)
        }
        // …and the route itself refuses before asking the host.
        await #expect(throws: WorkspaceClientError.self) {
            _ = try await files.boardFile(agentID: "default", itemID: "a", file: file)
        }
        #expect(!http.requests.contains { $0.path.contains("/attachments/") })
    }

    @Test func inlineAndGluedDirectivesScheduleResolution() {
        #expect(DirectHermesGeneratedMediaClient.hasAttachmentDirectives("See MEDIA:/a/b.pdf now", role: .assistant))
        #expect(DirectHermesGeneratedMediaClient.hasAttachmentDirectives("MEDIA://a/b.mov", role: .assistant))
        #expect(!DirectHermesGeneratedMediaClient.hasAttachmentDirectives("No files here", role: .assistant))
        #expect(!DirectHermesGeneratedMediaClient.hasAttachmentDirectives("MEDIA:/a/b.pdf", role: .human))
    }

    private func makeOwner() throws -> WorkspaceOwner {
        WorkspaceOwner(authority: try .direct(endpointIdentity: "https://fixture.example.test", providerID: "test", userID: "files"),
                       authenticationGeneration: UUID(), connectionGeneration: UUID())
    }
}

@MainActor
private final class NoRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        throw WorkspaceClientError.invalidRequest
    }
    func disconnect() async {}
}

@MainActor
private final class AttachmentHTTP: DirectHermesAuthenticatedHTTP, DirectHermesNativeHTTP {
    let features: [String]
    var file: Data?
    var chunk = 1_024
    var requests: [DirectHermesHTTPRequest] = []
    /// Offsets whose first request times out.
    var failOnce: Set<Int> = []
    var fetchDelay: Duration?
    private(set) var fetchedOffsets: [Int] = []
    private(set) var mostAtOnce = 0
    private var inFlight = 0
    init(features: [String]) { self.features = features }

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        requests.append(request)
        throw WorkspaceClientError.transportUnavailable
    }

    func nativeResponse(_ request: DirectHermesHTTPRequest,
                        requestGuard: DirectHermesNativeRequestGuard?) async throws -> DirectHermesHTTP.Response {
        requests.append(request)
        let etag = "\"sha256:" + String(repeating: "b", count: 64) + "\""
        var headers = ["ETag": etag, "Cache-Control": "no-store"]
        let object: [String: BighelpJSONValue]
        if request.path.hasSuffix("/context") {
            object = ["schemaVersion": .integer(1), "pluginVersion": .string("test"), "runtimeId": .string("rt"),
                      "servingProfileId": .string("default"),
                      "principal": .object(["provider": .string("test"), "userId": .string("files"), "displayName": .null]),
                      "features": .array((["native-context-v1", "serving-profile-v1"] + features).map(BighelpJSONValue.string))]
        } else {
            headers["X-Loopdy-Request-ID"] = try #require(requestGuard).requestIDHeader
            let body = try #require(request.body)
            if request.path.hasSuffix("/attachments/board") {
                guard let data = file else {
                    let url = try #require(URL(string: "https://fixture.example.test" + request.path))
                    let missing = try #require(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1",
                                                               headerFields: headers))
                    return .init(http: missing, body: Data(#"{"error":{"code":"attachment_unavailable"}}"#.utf8))
                }
                object = ["attachment": .object(["id": .string(String(repeating: "d", count: 32)),
                                                 "fileName": .string("Report.pdf"), "mimeType": .string("application/pdf"),
                                                 "byteCount": .integer(data.count)])]
            } else if request.path.hasSuffix("/resolve") {
                let item = try #require(body["items"]?.array?.first?.object)
                let attachments: [BighelpJSONValue] = file.map { data in
                    [.object(["id": .string(String(repeating: "c", count: 32)), "fileName": .string("Report.pdf"),
                              "mimeType": .string("application/pdf"), "byteCount": .integer(data.count)])]
                } ?? []
                object = ["items": .array([.object(["itemId": item["itemId"]!,
                    "text": .string(file == nil ? item["text"]!.string! : "Here is the report."),
                    "attachments": .array(attachments)])])]
            } else {
                let data = try #require(file)
                let offset = try #require(body["offset"]?.integer)
                fetchedOffsets.append(offset)
                if failOnce.remove(offset) != nil { throw WorkspaceClientError.transportUnavailable }
                inFlight += 1
                mostAtOnce = max(mostAtOnce, inFlight)
                if let fetchDelay { try await Task.sleep(for: fetchDelay) }
                inFlight -= 1
                let end = min(data.count, offset + chunk)
                object = ["attachmentId": body["attachmentId"]!, "offset": .integer(offset), "byteCount": .integer(data.count),
                          "mimeType": .string("application/pdf"),
                          "data": .string(data[offset..<end].base64EncodedString()),
                          "nextOffset": end < data.count ? .integer(end) : .null]
            }
        }
        let url = try #require(URL(string: "https://fixture.example.test" + request.path))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers))
        return .init(http: response, body: try JSONEncoder().encode(BighelpJSONValue.object(object)))
    }
}
