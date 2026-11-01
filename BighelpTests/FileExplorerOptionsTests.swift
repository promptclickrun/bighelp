import Foundation
import Testing
@testable import Bighelp

struct FileExplorerOptionsTests {
    struct File: FileExplorerEntry {
        let path: String
        let name: String
        var isDirectory = false
        var modifiedAt: Date? = nil
        var createdAt: Date? = nil
        var mimeType: String? = nil
        var explorerModifiedAt: Date? { modifiedAt }
    }

    @Test func naturalNamesAndDirectionsKeepFoldersFirst() {
        let files = [File(path: "/10", name: "File10"), File(path: "/2", name: "File2"),
                     File(path: "/folder", name: "Z", isDirectory: true)]
        var options = FileExplorerOptions(sort: .name, ascending: true)
        #expect(options.apply(files).map(\.name) == ["Z", "File2", "File10"])
        options.ascending = false
        #expect(options.apply(files).map(\.name) == ["Z", "File10", "File2"])
    }

    @Test func datesUseCorrectFieldAndKeepUnknownLastInBothDirections() {
        let files = [File(path: "/a", name: "A", modifiedAt: Date(timeIntervalSince1970: 2), createdAt: Date(timeIntervalSince1970: 1)),
                     File(path: "/b", name: "B", modifiedAt: Date(timeIntervalSince1970: 1), createdAt: Date(timeIntervalSince1970: 2)),
                     File(path: "/c", name: "C")]
        var options = FileExplorerOptions(sort: .modified, ascending: false)
        #expect(options.apply(files).map(\.name) == ["A", "B", "C"])
        options.sort = .created
        #expect(options.apply(files).map(\.name) == ["B", "A", "C"])
        options.ascending = true
        #expect(options.apply(files).map(\.name) == ["A", "B", "C"])
    }

    @Test func searchAndTypeFilterComposeWithoutChangingInput() {
        let files = [File(path: "/a", name: "Résumé.PDF"), File(path: "/b", name: "resume.png"),
                     File(path: "/c", name: "Archive", isDirectory: true)]
        var options = FileExplorerOptions()
        options.query = "  resume  "
        options.filter = .documents
        #expect(options.apply(files).map(\.name) == ["Résumé.PDF"])
        options.filter = .images
        #expect(options.apply(files).map(\.name) == ["resume.png"])
        options.query = "missing"
        #expect(options.apply(files).isEmpty)
        #expect(files.count == 3)
    }
    @Test func everyTypeFilterUsesMetadataOrExtension() {
        let files = [File(path: "/folder", name: "folder", isDirectory: true),
                     File(path: "/image", name: "image", mimeType: "image/png"),
                     File(path: "/movie", name: "movie.MP4"),
                     File(path: "/song", name: "song.mp3"),
                     File(path: "/document", name: "report.docx"),
                     File(path: "/other", name: "data.bin")]
        let expected: [(FileExplorerOptions.Filter, String)] = [
            (.folders, "folder"), (.images, "image"), (.video, "movie.MP4"),
            (.audio, "song.mp3"), (.documents, "report.docx"), (.other, "data.bin")
        ]
        for (filter, name) in expected {
            var options = FileExplorerOptions()
            options.filter = filter
            #expect(options.apply(files).map(\.name) == [name])
        }
    }

    @Test func equalDatesAndNamesHaveStableOrderAndWhitespaceDoesNotFilter() {
        let files = [File(path: "/b", name: "same"), File(path: "/a", name: "same")]
        var options = FileExplorerOptions(sort: .created, ascending: false)
        options.query = " \n "
        #expect(!options.isFiltering)
        #expect(options.apply(files).map(\.path) == ["/a", "/b"])
        options.ascending = true
        #expect(options.apply(files).map(\.path) == ["/a", "/b"])
    }

}
