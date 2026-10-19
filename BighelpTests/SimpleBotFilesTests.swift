import Foundation
import Testing
@testable import Bighelp

@MainActor
struct SimpleBotFilesTests {
    @Test func filesAndMediaComeAfterComputer() {
        #expect(SimpleBotProfileTab.available(showsComputer: true) == [.info, .computer, .files, .media])
        #expect(SimpleBotProfileTab.available(showsComputer: false) == [.info, .files, .media])
        #expect(SimpleBotProfileTab.available(showsComputer: true).map(\.title) == ["Info", "Computer", "Files", "Media"])
    }

    @Test func aRowOpensByWhatItIs() {
        let folder = Self.file("/w/Reports", directory: true)
        let video = Self.file("/w/clip.mp4", size: 40_000_000, mime: "video/mp4")
        #expect(SimpleBotFileOpening.decide(folder, downloadLimit: 1_000, canStream: false) == .folder)
        #expect(SimpleBotFileOpening.decide(video, downloadLimit: 1_000, canStream: true) == .stream)
        #expect(SimpleBotFileOpening.decide(video, downloadLimit: 1_000, canStream: false) == .tooBig)
        #expect(SimpleBotFileOpening.decide(Self.file("/w/a.txt", size: 0), downloadLimit: 1_000, canStream: false) == .empty)
        #expect(SimpleBotFileOpening.decide(Self.file("/w/a.txt", size: 900), downloadLimit: 1_000, canStream: false) == .preview)
    }

    @Test func foldersComeFirstAndHiddenFilesWaitForNerdMode() {
        let files = [Self.file("/w/b.txt"), Self.file("/w/.env"), Self.file("/w/Zed", directory: true),
                     Self.file("/w/a10.txt"), Self.file("/w/a9.txt"), Self.file("/w/Alpha", directory: true)]
        #expect(SimpleBotFilesModel.visible(files, showsHidden: false).map(\.name)
                == ["Alpha", "Zed", "a9.txt", "a10.txt", "b.txt"])
        #expect(SimpleBotFilesModel.visible(files, showsHidden: true).map(\.name).contains(".env"))
    }

    @Test func anOldPluginAsksForAnUpdateAndTheHostsReasonIsKept() {
        #expect(SimpleBotFilesModel.phase(for: WorkspaceClientError.unavailable(.unsupportedOperation)) == .needsPluginUpdate)
        #expect(SimpleBotFilesModel.phase(for: WorkspaceClientError.rejected(code: WorkspaceClientError.workspacePluginOutdated))
                == .needsPluginUpdate)
        let reason = WorkspaceClientError.workspaceFilesMessage("workspace_in_container") ?? ""
        #expect(SimpleBotFilesModel.phase(for: WorkspaceClientError.rejected(code: "workspace_in_container")) == .failed(reason))
        if case .failed(let message) = SimpleBotFilesModel.phase(for: WorkspaceClientError.transportUnavailable) {
            #expect(message.contains("computer is on"))
        } else {
            Issue.record("A dropped connection says to check the computer")
        }
    }

    @Test func locationIsSaidFromTheTopFolder() {
        #expect(SimpleBotFilesModel.location(of: "/w/Reports/2026", root: "/w") == ["Reports", "2026"])
        #expect(SimpleBotFilesModel.location(of: "/w", root: "/w").isEmpty)
        #expect(SimpleBotFilesModel.location(of: "/elsewhere/Notes", root: "/w") == ["Notes"])
    }

    @Test func foldersOpenInPlaceAndBackGoesUp() async throws {
        let source = FakeFilesSource()
        let model = SimpleBotFilesModel(agentID: "finance", source: source)
        await model.refresh()
        #expect(model.phase == .loaded)
        #expect(model.isAtTop)
        #expect(model.locationTitle == "All files")
        #expect(model.entries.map(\.name) == ["Reports", "notes.md"])

        let reports = try #require(model.entries.first)
        await model.open(reports)
        #expect(model.locationTitle == "Reports")
        #expect(model.parentTitle == "All files")
        #expect(!model.isAtTop)
        #expect(model.entries.map(\.name) == ["chart.png"])

        await model.goUp()
        #expect(model.isAtTop)
        #expect(source.listed == [nil, "/w/Reports", "/w"])
    }

    @Test func aFileOpensInTheChatPreview() async throws {
        let source = FakeFilesSource()
        let model = SimpleBotFilesModel(agentID: "finance", source: source)
        await model.refresh()
        let notes = try #require(model.entries.last)
        await model.open(notes)
        let preview = try #require(model.preview)
        #expect(preview.fileName == "notes.md")
        #expect(preview.mimeType == "text/markdown")
        #expect(ChatAttachmentMarkdown.text(of: preview) == "# Notes")
        #expect(model.openingPath == nil)
    }

    @Test func aFolderThatFailsKeepsTheListAndSaysSo() async throws {
        let source = FakeFilesSource()
        let model = SimpleBotFilesModel(agentID: "finance", source: source)
        await model.refresh()
        source.failure = WorkspaceClientError.transportUnavailable
        await model.open(try #require(model.entries.first))
        #expect(model.phase == .loaded)
        #expect(model.isAtTop)
        #expect(model.notice != nil)
    }

    @Test func everyBotOpensItsOwnFolder() async {
        let source = FakeFilesSource()
        let model = SimpleBotFilesModel(agentID: "travel", source: source)
        await model.refresh()
        #expect(model.phase == .loaded)
        #expect(source.agents == ["travel"])
    }

    @Test func theDemoGivesEachBotItsOwnFolder() async throws {
        let demo = SimpleBotDemoFiles()
        let top = try await demo.list(agentID: "finance", path: nil)
        #expect(top.parent == nil)
        #expect(top.files.contains { $0.isDirectory && $0.name == "Reports" })
        let reports = try await demo.list(agentID: "finance", path: SimpleBotDemoFiles.root + "/Reports")
        #expect(reports.parent == SimpleBotDemoFiles.root)
        let pdf = try #require(reports.files.first { $0.mimeType == "application/pdf" })
        let contents = try await demo.download(agentID: "finance", file: pdf)
        #expect(contents.bytes.count == pdf.byteCount)
        let travel = try await demo.list(agentID: "travel", path: nil)
        #expect(travel.path == SimpleBotDemoFiles.travelRoot)
        #expect(travel.files.contains { $0.isDirectory && $0.name == "Lisbon trip" })
        #expect(!travel.files.contains { $0.name == "Reports" })
        let trip = try await demo.list(agentID: "travel", path: SimpleBotDemoFiles.travelRoot + "/Lisbon trip")
        let itinerary = try #require(trip.files.first { $0.name == "Itinerary.md" })
        #expect(try await demo.download(agentID: "travel", file: itinerary).bytes.count == itinerary.byteCount)
        // One bot's folder never opens another's.
        await #expect(throws: DirectHermesManagedFilesError.invalidPath) {
            try await demo.list(agentID: "travel", path: SimpleBotDemoFiles.root + "/Reports")
        }
        await #expect(throws: DirectHermesManagedFilesError.invalidPath) {
            try await demo.download(agentID: "travel", file: pdf)
        }
        #expect(try await demo.list(agentID: "new-bot", path: nil).files.isEmpty)
    }

    @Test func demoMediaIsEachBotsOwn() async throws {
        let client = DemoAgentMediaClient()
        let finance = try await client.recent(agentID: "finance")
        #expect(!finance.isEmpty)
        #expect(finance.allSatisfy { $0.mimeType.hasPrefix("image/") || $0.mimeType.hasPrefix("video/") })
        #expect(finance.contains { $0.isVideo })
        #expect(try await client.recent(agentID: "home").isEmpty)
        let first = try #require(finance.first)
        #expect(try await client.data(agentID: "finance", item: first).count == first.byteCount)

        let store = AgentMediaStore()
        store.configure(client: client)
        await store.load(agentID: "travel")
        #expect(store.state == .loaded)
        #expect(store.items.map(\.fileName).contains("lisbon-evening.png"))
    }

    @Test func liveMediaWithoutAConnectionSaysTheHostIsUnavailable() async {
        let store = AgentMediaStore()
        store.configure(client: SimpleBotHostMedia { nil })
        await store.load(agentID: "finance")
        #expect(store.state == .failed(WorkspaceClientError.transportUnavailable.localizedDescription))
    }

    private static func file(_ path: String, directory: Bool = false, size: Int? = 10,
                             mime: String? = nil) -> HermesManagedFile {
        HermesManagedFile(path: path, name: (path as NSString).lastPathComponent, isDirectory: directory,
                          byteCount: directory ? nil : size, modifiedAt: Date(timeIntervalSince1970: 1_000),
                          mimeType: mime)
    }
}

/// Serves "finance"'s folder only, like the plugin.
@MainActor
private final class FakeFilesSource: SimpleBotFilesSource {
    var listed: [String?] = []
    var agents: [String] = []
    var failure: Error?

    var downloadLimit: Int { 1_000_000 }

    func list(agentID: String, path: String?) async throws -> HermesManagedFileDirectory {
        agents.append(agentID)
        listed.append(path)
        if let failure { throw failure }
        switch path ?? "/w" {
        case "/w":
            return .init(path: "/w", parent: nil, files: [
                file("/w/notes.md", size: 7, mime: "text/markdown"), file("/w/Reports", directory: true),
            ])
        case "/w/Reports":
            return .init(path: "/w/Reports", parent: "/w", files: [file("/w/Reports/chart.png", size: 4, mime: "image/png")])
        default:
            throw DirectHermesManagedFilesError.invalidPath
        }
    }

    func download(agentID: String, file: HermesManagedFile) async throws -> HermesManagedFileContents {
        .init(file: file, bytes: Data("# Notes".utf8), sha256: "")
    }

    func canStream(agentID: String, file: HermesManagedFile) -> Bool { false }
    func playback(agentID: String, file: HermesManagedFile) -> DirectHermesManagedMediaPlayback? { nil }

    private func file(_ path: String, directory: Bool = false, size: Int? = nil, mime: String? = nil) -> HermesManagedFile {
        HermesManagedFile(path: path, name: (path as NSString).lastPathComponent, isDirectory: directory,
                          byteCount: size, modifiedAt: Date(timeIntervalSince1970: 1_000), mimeType: mime)
    }
}
