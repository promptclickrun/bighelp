import Foundation
import PDFKit
import Testing
import UIKit
@testable import Bighelp

/// Feed posts carry the agent's files (plugin `native-agent-board-files-v1`): names and
/// sizes in the post, bytes through the attachment routes.
@MainActor
struct AgentBoardFileTests {
    @Test func postsListTheirFilesByNameAndNeverByPath() throws {
        func file(_ index: Int, _ name: String, _ mime: String = "application/pdf", size: Int = 2_048) -> BighelpJSONValue {
            .object(["index": .integer(index), "fileName": .string(name), "mimeType": .string(mime),
                     "byteCount": .integer(size), "addedAt": .integer(1_790_000_000)])
        }
        let json: BighelpJSONValue = .object([
            "id": .string("feed-1"), "kind": .string("feed"), "title": .string("Lisbon"),
            "files": .array([
                file(0, "harbor.png", "image/png"), file(1, "Trip plan.pdf"),
                file(1, "duplicate.pdf"), file(10, "past-the-end.pdf"), file(2, "../secret.pdf"),
                file(3, "/Users/someone/plan.pdf"), file(4, String(repeating: "a", count: 181) + ".pdf"),
                file(5, "empty.pdf", size: 0), file(6, "huge.pdf", size: ChatAttachment.maximumAgentBytes + 1),
                file(7, "odd.bin", "not a type"), .string("MEDIA:/tmp/x.pdf"),
            ]),
        ])
        let item = try AgentBoardItem(json: json)
        #expect(item.files.map(\.fileName) == ["harbor.png", "Trip plan.pdf"])
        #expect(item.files.map(\.index) == [0, 1])
        #expect(item.files[0].isImage && !item.files[1].isImage)
        #expect(item.files[1].byteCount == 2_048 && item.files[1].mimeType == "application/pdf")
        #expect(item.files[1].addedAt == Date(timeIntervalSince1970: 1_790_000_000))

        let many = BighelpJSONValue.object(["id": .string("f"), "kind": .string("feed"), "title": .string("t"),
                                            "files": .array((0..<12).map { file($0, "page-\($0).pdf") })])
        #expect(try AgentBoardItem(json: many).files.count == 10, "At most ten files")
        // Plugins before files, and ideas or goals, have none.
        #expect(try AgentBoardItem(json: .object(["id": .string("x"), "kind": .string("feed"),
                                                  "title": .string("t")])).files.isEmpty)
    }

    @Test func withoutThePluginFeatureFeedWorksAsBefore() async throws {
        let item = AgentBoardItem(id: "a", kind: .feed, title: "One",
                                  files: [.init(index: 0, fileName: "plan.pdf", mimeType: "application/pdf", byteCount: 9)])
        let client = FileBoardClient(items: [item], supportsFiles: false)
        let store = AgentBoardStore()
        store.configure(client: client)
        await store.load(agentID: "default")
        #expect(!store.supportsFiles)
        #expect(store.visibleFiles(of: store.feed[0]).isEmpty, "An older plugin's post shows no files")
        #expect(await store.attachment(for: store.feed[0], file: item.files[0]) == nil)
        #expect(client.fileRequests.isEmpty, "Nothing asks the host for a file it can't serve")
    }

    @Test func picturesBecomeThumbnailsAndMissingFilesSayUnavailableUntilRetried() async throws {
        let picture = BoardFileFixture.png()
        let item = AgentBoardItem(id: "a", kind: .feed, title: "One", files: [
            .init(index: 0, fileName: "harbor.png", mimeType: "image/png", byteCount: picture.count),
            .init(index: 1, fileName: "moved.pdf", mimeType: "application/pdf", byteCount: 9),
        ])
        let client = FileBoardClient(items: [item], supportsFiles: true)
        client.data[0] = picture
        let store = AgentBoardStore()
        store.configure(client: client)
        await store.load(agentID: "default")
        let post = store.feed[0]
        #expect(store.visibleFiles(of: post).count == 2)
        #expect(store.fileState(post, post.files[0]) == .loading)
        await store.loadThumbnail(for: post, file: post.files[0])
        #expect(store.thumbnail(post, post.files[0]) != nil)
        #expect(store.fileState(post, post.files[0]) == .ready)

        #expect(await store.attachment(for: post, file: post.files[1]) == nil)
        #expect(store.fileState(post, post.files[1]) == .unavailable)
        client.data[1] = Data("%PDF-1.4\n".utf8)
        let opened = await store.attachment(for: post, file: post.files[1])
        #expect(opened?.fileName == "moved.pdf", "Opening it again tries again")
        #expect(store.fileState(post, post.files[1]) == .ready)

        // A new connection forgets what this one loaded.
        store.configure(client: FileBoardClient(items: [], supportsFiles: true))
        #expect(store.thumbnail(post, post.files[0]) == nil)
    }

    @Test func theCompactRowShowsPicturesThenAFileChipWithACount() {
        func file(_ index: Int, _ name: String, _ mime: String) -> AgentBoardItem.File {
            .init(index: index, fileName: name, mimeType: mime, byteCount: 10)
        }
        let one = BoardFileSummary(files: [file(0, "plan.pdf", "application/pdf")])
        #expect(one.pictures.isEmpty && one.morePictures == 0)
        #expect(one.chipTitle == "plan.pdf" && one.chipSymbol == "doc.richtext")
        let mixed = BoardFileSummary(files: (0..<5).map { file($0, "p\($0).png", "image/png") }
            + [file(5, "plan.pdf", "application/pdf"), file(6, "sheet.xlsx", "application/vnd.ms-excel")])
        #expect(mixed.pictures.map(\.index) == [0, 1, 2])
        #expect(mixed.morePictures == 2)
        #expect(mixed.chipTitle == "2 files" && mixed.chipSymbol == "doc.on.doc")
        #expect(mixed.accessibilityLabel == "7 attachments: 5 pictures, 2 files")
        #expect(BoardFileSummary(files: [file(0, "a.png", "image/png")]).chipTitle == nil)
    }

    @Test func theDemoPostCarriesAPictureAndAPDF() async throws {
        let demo = DemoAgentBoardClient()
        #expect(demo.supportsFiles)
        let post = try #require(try await demo.items(agentID: "default").first { !$0.files.isEmpty })
        #expect(post.kind == .feed)
        #expect(post.files.map(\.mimeType) == ["image/png", "application/pdf"])
        for file in post.files {
            let attachment = try await demo.file(agentID: "default", itemID: post.id, file: file)
            #expect(attachment.fileName == file.fileName && attachment.data.count == file.byteCount)
            if file.isImage {
                #expect(UIImage(data: attachment.data) != nil)
            } else {
                #expect((PDFDocument(data: attachment.data)?.pageCount ?? 0) > 0)
            }
        }
    }
}

enum BoardFileFixture {
    static func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
}

@MainActor
private final class FileBoardClient: AgentBoardClient {
    var items: [AgentBoardItem]
    let supportsFeedback = true
    let supportsFiles: Bool
    var data: [Int: Data] = [:]
    private(set) var fileRequests: [Int] = []

    init(items: [AgentBoardItem], supportsFiles: Bool) {
        self.items = items
        self.supportsFiles = supportsFiles
    }

    func items(agentID: String) async throws -> [AgentBoardItem] { items }
    func update(agentID: String, itemID: String, change: AgentBoardChange) async throws -> AgentBoardItem { items[0] }
    func markRead(agentID: String, itemIDs: [String]) async throws {}
    func promote(agentID: String, itemID: String) async throws -> AgentBoardItem { items[0] }
    func picture(agentID: String, itemID: String, index: Int) async throws -> Data { Data() }
    func activity(agentID: String) async throws -> [AgentActivityEntry] { [] }
    func approvals(agentID: String) async throws -> [AgentApprovalEntry] { [] }
    func identity(agentID: String) async throws -> AgentIdentityDocuments {
        AgentIdentityDocuments(soul: .init(), memory: .init(), user: .init())
    }

    func file(agentID: String, itemID: String, file: AgentBoardItem.File) async throws -> ChatAttachment {
        fileRequests.append(file.index)
        guard let bytes = data[file.index] else { throw WorkspaceClientError.rejected(code: "attachment_unavailable") }
        return try .agentArtifact(id: "native_att_" + String(repeating: "f", count: 16) + "\(file.index)",
                                  fileName: file.fileName, mimeType: file.mimeType, data: bytes)
    }
}
