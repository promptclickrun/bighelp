import Foundation
import Testing
@testable import Bighelp

/// The list of chats is a small root file and the rows in parts, so a save writes only the
/// parts that changed. As one file, a change to one row wrote the whole list: megabytes on a
/// computer with thousands of chats (#1000).
@MainActor
struct SessionListPartsTests {
    /// The list as builds before parts kept it: every row in one file.
    private struct OneFileList: Codable {
        var revision: UUID?
        var records: [SessionRecord] = []
    }

    @Test func aChangeToOneRowWritesOnlyItsPartOfTheList() throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionContentRepository(directory: directory)
        var rows = Self.rows(2_000)
        try repository.save(rows)
        let wholeList = repository.lastSaveByteCount

        rows[700].title = "Renamed"
        try repository.save(rows)
        #expect(repository.lastSaveByteCount * 8 < wholeList,
                "One changed row wrote \(repository.lastSaveByteCount) of the list's \(wholeList) bytes.")
        try repository.save(rows)
        #expect(repository.lastSaveByteCount * 100 < wholeList, "A save with nothing changed writes no rows.")
        let reopened = try SessionContentRepository(directory: directory).load()
        #expect(reopened.map(\.id) == rows.map(\.id))
        #expect(reopened[700].title == "Renamed")
    }

    @Test func theListComesBackInTheOrderItWasSaved() throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionContentRepository(directory: directory)
        var rows = Array(Self.rows(600).reversed())
        rows.swapAt(3, 411)
        try repository.save(rows)
        #expect(try SessionContentRepository(directory: directory).load().map(\.id) == rows.map(\.id))

        // The chat in use goes to the top of the list.
        rows.insert(rows.remove(at: 250), at: 0)
        try repository.save(rows)
        #expect(try SessionContentRepository(directory: directory).load().map(\.id) == rows.map(\.id))
    }

    @Test func aListWithNoRowsAndAListThatOutgrowsItsPartsBothComeBack() throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionContentRepository(directory: directory)
        try repository.save([])
        #expect(try SessionContentRepository(directory: directory).load().isEmpty)

        try repository.save(Self.rows(100))
        #expect(try Self.partFiles(in: directory).count == 1, "A list that fits one part has one.")

        let grown = Self.rows(300)
        try repository.save(grown)
        let parts = try Self.partFiles(in: directory).count
        #expect(parts > 1 && parts <= 4, "The parts double, and the ones before go.")
        #expect(try SessionContentRepository(directory: directory).load() == repository.load())
        #expect(try repository.load().map(\.id) == grown.map(\.id))

        // Fewer rows keep the parts they have.
        try repository.save(Array(grown.prefix(5)))
        #expect(try SessionContentRepository(directory: directory).load().map(\.id) == grown.prefix(5).map(\.id))
    }

    @Test func aListSavedAsOneFileMovesIntoPartsWithItsDraftsAndCheckpoints() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chats = Self.chatsWithDrafts
        try Self.keepAsOneFile(chats, in: directory)

        let repository = SessionContentRepository(directory: directory)
        let rows = try repository.load()
        #expect(rows.map(\.id) == chats.map(\.id))
        for chat in chats { #expect(try repository.loadSession(id: chat.id) == chat) }
        #expect(FileManager.default.fileExists(
            atPath: directory.appending(path: "sessions-catalog-root-v1.json").path(percentEncoded: false)))
        #expect(throws: DemoRepositoryError.unsupportedSchemaVersion(found: 1_000_000, current: 1),
                "A build from before refuses the list instead of reading an older copy.") {
            try Self.oneFileList(in: directory).loadExistingPreservingSource()
        }

        // The send path's checkpoint: prepared off the main actor, then adopted.
        var changed = rows
        changed[0].title = "Renamed"
        let pending = try await repository.encodeSnapshot(changed)
        try repository.saveEncoded(pending)
        let reopened = SessionContentRepository(directory: directory)
        #expect(try reopened.loadSession(id: chats[0].id)?.title == "Renamed")
        #expect(try reopened.loadSession(id: chats[0].id)?.draft == chats[0].draft)
        #expect(try reopened.loadSession(id: chats[1].id) == chats[1])
    }

    @Test func aNewListLeavesNothingABuildFromBeforeCanRead() throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try SessionContentRepository(directory: directory).save(Self.chatsWithDrafts)
        #expect(throws: DemoRepositoryError.unsupportedSchemaVersion(found: 1_000_000, current: 1)) {
            try Self.oneFileList(in: directory).loadExistingPreservingSource()
        }
        #expect(throws: DemoRepositoryError.unsupportedSchemaVersion(found: 1_000_000, current: 1),
                "And it can't write its own list over the marker.") {
            try Self.oneFileList(in: directory).save(OneFileList(revision: UUID(), records: []))
        }
    }

    /// Two copies of the list in memory, as a second process would hold: the one that didn't
    /// see the other's save must not write its parts over it.
    @Test func aSaveFromACopyOfTheListThatIsNoLongerCurrentIsRefused() throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        var rows = Self.rows(300)
        try SessionContentRepository(directory: directory).save(rows)
        let first = SessionContentRepository(directory: directory)
        let second = SessionContentRepository(directory: directory)
        var stale = try first.load()
        var current = try second.load()

        current[10].title = "Renamed by the second"
        try second.save(current)
        stale[200].title = "Renamed by the first"
        #expect(throws: SessionContentRepositoryError.staleCheckpoint) { try first.save(stale) }

        rows[10].title = "Renamed by the second"
        #expect(try SessionContentRepository(directory: directory).load().map(\.title) == rows.map(\.title))
        // Having read the list again, the first can save.
        var reread = try first.load()
        reread[200].title = "Renamed by the first"
        try first.save(reread)
        #expect(try SessionContentRepository(directory: directory).load()[200].title == "Renamed by the first")
    }

    @Test func aMoveStoppedBeforeTheRootKeepsTheOneFileList() throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chats = Self.chatsWithDrafts
        try Self.keepAsOneFile(chats, in: directory)

        // The part is written, the root is not.
        let stopped = SessionContentRepository(directory: directory, fileProtection: FailingWrites(failing: 2))
        #expect(throws: (any Error).self) { try stopped.load() }
        #expect(try Self.oneFileList(in: directory).loadExistingPreservingSource()?.records.count == chats.count,
                "The one file is still the list.")

        let repository = SessionContentRepository(directory: directory)
        #expect(try repository.load().map(\.id) == chats.map(\.id))
        for chat in chats { #expect(try repository.loadSession(id: chat.id) == chat) }
    }

    /// A part that doesn't hold what was written to it (a bad write, a fault in this code): the
    /// move reads its parts back, so it stops with the one file still the list.
    @Test func aMoveWhosePartsDoNotReadBackKeepsTheOneFileList() throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chats = Self.chatsWithDrafts
        try Self.keepAsOneFile(chats, in: directory)

        let emptyPart = Data(#"{"schemaVersion":1,"value":[]}"#.utf8)
        let faulty = SessionContentRepository(directory: directory, fileProtection: FailingWrites(replacing: 1, with: emptyPart))
        #expect(throws: SessionContentRepositoryError.invalidManifest) { try faulty.load() }
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "sessions-catalog-root-v1.json").path(percentEncoded: false)))
        #expect(try Self.oneFileList(in: directory).loadExistingPreservingSource()?.records.count == chats.count,
                "The one file is still the list.")

        let repository = SessionContentRepository(directory: directory)
        #expect(try repository.load().map(\.id) == chats.map(\.id))
        for chat in chats { #expect(try repository.loadSession(id: chat.id) == chat) }
    }

    @Test func aMoveStoppedAfterTheRootIsFinishedAtTheNextLaunch() throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chats = Self.chatsWithDrafts
        try Self.keepAsOneFile(chats, in: directory)

        // The part and the root are written, the marker is not.
        let stopped = SessionContentRepository(directory: directory, fileProtection: FailingWrites(failing: 3))
        #expect(try stopped.load().map(\.id) == chats.map(\.id))
        #expect(try Self.oneFileList(in: directory).loadExistingPreservingSource() != nil)

        let repository = SessionContentRepository(directory: directory)
        #expect(try repository.load().map(\.id) == chats.map(\.id))
        for chat in chats { #expect(try repository.loadSession(id: chat.id) == chat) }
        #expect(throws: DemoRepositoryError.unsupportedSchemaVersion(found: 1_000_000, current: 1)) {
            try Self.oneFileList(in: directory).loadExistingPreservingSource()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aSaveStoppedBeforeTheRootKeepsTheListAsItWas() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chats = Self.chatsWithDrafts
        try SessionContentRepository(directory: directory).save(chats)

        // A changed row: its part is written, the root is not.
        let stopped = SessionContentRepository(directory: directory, fileProtection: FailingWrites(failing: 2))
        var changed = try stopped.load()
        changed[1].title = "Renamed"
        #expect(throws: (any Error).self) { try stopped.save(changed) }

        let repository = SessionContentRepository(directory: directory)
        #expect(try repository.load().map(\.title) == chats.map(\.title))
        for chat in chats { #expect(try repository.loadSession(id: chat.id) == chat) }

        // The part that save left is no row's any more, and goes once it isn't new.
        #expect(try Self.partFiles(in: directory).count == 2)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-3_600)],
                                                  ofItemAtPath: file.path(percentEncoded: false))
        }
        #expect(await repository.removeUnreferencedContent() == 1)
        #expect(try Self.partFiles(in: directory).count == 1)
        #expect(try SessionContentRepository(directory: directory).load().map(\.id) == chats.map(\.id))
    }

    /// Saved lists name a row's part by this hash, so it must give the same answer in every build.
    @Test func aChatsPartNeverChanges() {
        #expect(SessionListParts.part(of: "session-7", among: 64) == 6)
        #expect(SessionListParts.part(of: "open-chat", among: 64) == 44)
        #expect(SessionListParts.part(of: "chat-👨‍👨‍👦", among: 256) == 92)
        #expect(SessionListParts.part(of: "", among: 1) == 0)
        #expect(SessionListParts.count(for: 128, current: 0) == 1)
        #expect(SessionListParts.count(for: 129, current: 1) == 2)
        #expect(SessionListParts.count(for: 7_000, current: 1) == 64)
        #expect(SessionListParts.count(for: 5, current: 64) == 64, "Parts never get fewer.")
        #expect(SessionListParts.count(for: 1_000_000, current: 1) == SessionListParts.maximumCount)
        #expect(SessionListParts.count(for: 1_000_000, current: 200) == SessionListParts.maximumCount)
    }

    // MARK: Helpers

    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    private static func rows(_ count: Int) -> [SessionRecord] {
        (0..<count).map { index in
            let at = Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index) * 900)
            return SessionRecord(id: "session-\(index)", kind: .direct, agentIDs: ["default"],
                                 title: "Scheduled run \(index)", remoteStoredID: "stored-\(index)",
                                 remoteSource: "cron", createdAt: at, updatedAt: at, hasAcceptedMessage: true)
        }
    }

    private static let chatsWithDrafts = [
        SessionRecord(id: "one", kind: .direct, agentIDs: ["default"], title: "First", draft: "An unsent draft"),
        SessionRecord(id: "two", kind: .direct, agentIDs: ["default"], title: "Second", draft: "Another 👨‍👨‍👦"),
        SessionRecord(id: "three", kind: .direct, agentIDs: ["default"], title: "Third"),
    ]

    private static func oneFileList(in directory: URL) -> DemoRepository<OneFileList> {
        DemoRepository(directory: directory, name: "sessions-catalog", seed: OneFileList())
    }

    private static func partFiles(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasPrefix("sessions-catalog-part-") }
    }

    /// Leaves the folder as a build before parts left it: the content files, and every row in
    /// the one file `sessions-catalog-v1.json`.
    private static func keepAsOneFile(_ chats: [SessionRecord], in directory: URL) throws {
        try SessionContentRepository(directory: directory).save(chats)
        let rows = try SessionContentRepository(directory: directory).load()
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.lastPathComponent.hasPrefix("sessions-catalog") {
            try FileManager.default.removeItem(at: file)
        }
        try oneFileList(in: directory).save(OneFileList(revision: UUID(), records: rows))
    }
}

/// Writes as the app does, but one write fails (the save or the move stops there), or one write
/// puts other bytes in the file.
private final class FailingWrites: BighelpLocalFileProtecting, @unchecked Sendable {
    private let failing: Int?
    private let replaced: (write: Int, data: Data)?
    private var writes = 0

    init(failing: Int) {
        self.failing = failing
        replaced = nil
    }

    init(replacing write: Int, with data: Data) {
        failing = nil
        replaced = (write, data)
    }

    func prepareDirectory(_ directory: URL, protection: BighelpLocalProtectionClass, fileManager: FileManager) throws {
        try BighelpLocalFileProtector().prepareDirectory(directory, protection: protection, fileManager: fileManager)
    }

    func write(_ data: Data, to file: URL, protection: BighelpLocalProtectionClass) throws {
        writes += 1
        if writes == failing { throw CocoaError(.fileWriteOutOfSpace) }
        let written = replaced.flatMap { $0.write == writes ? $0.data : nil } ?? data
        try BighelpLocalFileProtector().write(written, to: file, protection: protection)
    }

    func apply(_ protection: BighelpLocalProtectionClass, to file: URL, fileManager: FileManager) throws {
        try BighelpLocalFileProtector().apply(protection, to: file, fileManager: fileManager)
    }
}
