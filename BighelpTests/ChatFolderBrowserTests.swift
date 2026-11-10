import Foundation
import Testing
@testable import Bighelp

/// A chat's Files (#944): the working folder as a tree, a path field and a search.
@MainActor
struct ChatFolderBrowserTests {
    /// The demo's folders, counting what was listed.
    private final class Counting: HostFolderAccess {
        let folders = DemoHostFolders()
        var listed: [String] = []
        var working = DemoHostFolders.project

        func workingFolder() async -> String { working }
        func list(_ path: String) async throws -> [HostFolderEntry] {
            listed.append(path)
            return try await folders.list(path)
        }
        func picture(_ path: String) async throws -> Data { try await folders.picture(path) }
    }

    private func names(_ model: ChatFolderBrowserModel) -> [String] {
        model.rows.map { String(repeating: "  ", count: $0.depth) + $0.entry.name }
    }

    @Test func itOpensTheWorkingFolderWithFoldersFirst() async {
        let access = Counting()
        let model = ChatFolderBrowserModel(access: access)
        await model.start()
        #expect(model.root == DemoHostFolders.project)
        #expect(model.pathText == DemoHostFolders.project)
        #expect(model.isAtWorkingFolder && model.canGoUp)
        #expect(names(model) == ["assets", "src", "tests", "notes.md", "package.json", "README.md", "SUMMARY.md"])
        #expect(access.listed == [DemoHostFolders.project], "Only the folder on show is read")
        await model.start()
        #expect(access.listed.count == 1, "Opening Files again doesn't read it again")
    }

    @Test func aFolderIsReadWhenItFirstOpensAndKeepsItsPlaceInTheTree() async throws {
        let access = Counting()
        let model = ChatFolderBrowserModel(access: access)
        await model.start()
        let src = try #require(model.rows.first { $0.entry.name == "src" }).entry
        await model.toggle(src)
        #expect(names(model) == ["assets", "src", "  api", "  forecast.ts", "  units.ts", "tests", "notes.md",
                                 "package.json", "README.md", "SUMMARY.md"])
        let api = try #require(model.rows.first { $0.entry.name == "api" }).entry
        await model.toggle(api)
        #expect(names(model).contains("    client.ts"))

        // Closing hides what's inside; opening again doesn't read it again.
        await model.toggle(src)
        #expect(!names(model).contains("  forecast.ts"))
        await model.toggle(src)
        #expect(names(model).contains("    client.ts"), "The folder inside is still open")
        #expect(access.listed.count == 3)
    }

    @Test func searchFindsNamesInEveryFolderOpenedAndSaysWhere() async throws {
        let model = ChatFolderBrowserModel(access: Counting())
        await model.start()
        let src = try #require(model.rows.first { $0.entry.name == "src" }).entry
        await model.toggle(src)
        await model.toggle(src)
        model.search = "FORECAST"
        #expect(model.rows.map(\.entry.name) == ["forecast.ts"], "A closed folder that was read is searched too")
        #expect(model.rows.first?.place == "src" && model.rows.first?.depth == 0)
        model.search = "md"
        #expect(model.rows.map(\.entry.name) == ["notes.md", "README.md", "SUMMARY.md"])
        #expect(model.rows.allSatisfy { $0.place == nil })
        model.search = "nothing"
        #expect(model.rows.isEmpty)
    }

    @Test func namesThatStartWithADotStayOutOfTheWayUntilAskedFor() async throws {
        let model = ChatFolderBrowserModel(access: Counting())
        await model.start()
        #expect(model.hiddenCount == 2)
        #expect(!names(model).contains(".gitignore") && !names(model).contains(".hermes"))
        model.showsHidden = true
        #expect(Array(names(model).prefix(2)) == [".hermes", "assets"] && names(model).contains(".gitignore"))
        model.showsHidden = false
        // A search that starts with a dot looks for them.
        model.search = ".git"
        #expect(model.rows.map(\.entry.name) == [".gitignore"])
    }

    @Test func thePathFieldShowsAnotherFolder() async {
        let access = Counting()
        let model = ChatFolderBrowserModel(access: access)
        await model.start()

        // A "~" path gets its real name from what Hermes lists.
        model.pathText = "~/Projects"
        await model.submitPath()
        #expect(model.root == "/Users/demo/Projects" && model.pathText == "/Users/demo/Projects")
        #expect(names(model) == ["travel", "weather-app"])
        #expect(!model.isAtWorkingFolder)

        // A name alone is a folder inside the one on show.
        model.pathText = "travel"
        await model.submitPath()
        #expect(model.root == "/Users/demo/Projects/travel")
        #expect(names(model) == ["budget.csv"])

        // A path that isn't there says so and leaves the folder on show.
        model.pathText = "/Users/demo/missing"
        await model.submitPath()
        #expect(model.rootMessage == "There's no folder at that path.")
        #expect(model.root == "/Users/demo/Projects/travel" && names(model) == ["budget.csv"])
        model.pathText = "/Users/demo/Projects/travel/budget.csv"
        await model.submitPath()
        #expect(model.rootMessage == "That path is a file, not a folder.")

        await model.goUp()
        #expect(model.root == "/Users/demo/Projects" && model.rootMessage == nil)
        await model.openWorkingFolder()
        #expect(model.isAtWorkingFolder)
        #expect(names(model).first == "assets")
    }

    @Test func aHomeWorkingFolderIsStillTheWorkingFolderOnceItHasItsName() async {
        let access = Counting()
        access.working = "~"
        let model = ChatFolderBrowserModel(access: access)
        await model.start()
        #expect(model.root == "/Users/demo")
        #expect(model.isAtWorkingFolder)
    }

    @Test func hermesListingIsReadLeniently() throws {
        let entries = try LiveHostFolders.entries(.object(["entries": .array([
            .object(["name": .string("b.txt"), "path": .string("/w/b.txt"), "isDirectory": .boolean(false),
                     "added": .string("later")]),
            .object(["name": .string("src"), "path": .string("/w/src"), "isDirectory": .boolean(true)]),
            .object(["name": .string("a10.txt"), "path": .string("/w/a10.txt")]),
            .object(["name": .string("a2.txt"), "path": .string("/w/a2.txt")]),
            .object(["path": .string("/w/nameless")]),
            .string("not a row"),
        ])]))
        #expect(entries.map(\.name) == ["src", "a2.txt", "a10.txt", "b.txt"], "Folders first; a bad row hides only itself")
        #expect(entries.first?.isDirectory == true)

        #expect(throws: WorkspaceClientError.self) {
            try LiveHostFolders.entries(.object(["entries": .array([]), "error": .string("ENOENT")]))
        }
        #expect(throws: WorkspaceClientError.self) { try LiveHostFolders.entries(.array([])) }
    }

    @Test func filesOpenByTheirKindAndPicturesComeFromADataURL() {
        func preview(_ name: String) -> HostFolderEntry.Preview {
            HostFolderEntry(path: "/w/\(name)", name: name, isDirectory: false).preview
        }
        #expect(preview("README.md") == .markdown && preview("Plan.MARKDOWN") == .markdown)
        #expect(preview("icon.PNG") == .picture && preview("photo.jpeg") == .picture)
        #expect(preview("main.swift") == .text && preview("Makefile") == .text)

        #expect(HostPictureFile.data(fromDataURL: "data:image/png;base64,aGVsbG8=") == Data("hello".utf8))
        #expect(HostPictureFile.data(fromDataURL: "data:image/png,hello") == nil)
        #expect(HostPictureFile.data(fromDataURL: "https://example.com/a.png") == nil)

        // A picture needs more room than an ordinary answer, on its own route only.
        let query = [URLQueryItem(name: "path", value: "/w/icon.png"), URLQueryItem(name: "profile", value: "default")]
        #expect(DirectHermesHTTP.responseLimit(route: "/api/fs/read-data-url", method: "GET", query: query)
            == HostPictureFile.maximumResponseBytes)
        #expect(DirectHermesHTTP.responseLimit(route: "/api/fs/read-text", method: "GET", query: query)
            < HostPictureFile.maximumResponseBytes)
    }
}
