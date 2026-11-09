import Foundation
import Testing
@testable import Bighelp

/// What the share sheet saves for bighelp, and how it waits until the person sends or deletes it
/// (#922). Foundation only: these run on any platform Swift runs on.
@Suite(.serialized)
struct PendingShareInboxTests {
    private let directory: URL
    private let inbox: PendingShareInbox

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-share-tests-" + UUID().uuidString, isDirectory: true)
        inbox = PendingShareInbox(root: directory.appendingPathComponent("PendingShares/v1", isDirectory: true),
                                  limits: Self.smallLimits, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    /// Small enough to reach in a test, the same shape as the real ones.
    private static let smallLimits: PendingShareLimits = {
        var limits = PendingShareLimits()
        limits.files = 3
        limits.imageBytes = 64
        limits.fileBytes = 256
        limits.shareBytes = 400
        limits.inlineTextBytes = 48
        limits.textBytes = 1_024
        limits.noteBytes = 32
        limits.shares = 2
        limits.inboxBytes = 600
        return limits
    }()

    private func source(_ name: String, _ bytes: Int, fill: UInt8 = 0x61) throws -> URL {
        let folder = directory.appendingPathComponent("sources/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(repeating: fill, count: bytes).write(to: url)
        return url
    }

    private func addFile(_ draft: PendingShareDraft, _ name: String, _ bytes: Int,
                         kind: PendingShare.File.Kind = .file) throws {
        try draft.addFile(copying: source(name, bytes), suggestedName: name, kind: kind,
                          typeIdentifier: kind == .image ? "public.png" : "com.adobe.pdf",
                          mimeType: kind == .image ? "image/png" : "application/pdf",
                          preferredExtension: kind == .image ? "png" : "pdf")
    }

    private var shares: [PendingShare] {
        inbox.entries().compactMap { if case .share(let share, _) = $0 { return share } else { return nil } }
    }

    private func stagingNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: inbox.staging.path)) ?? []).sorted()
    }

    // MARK: - What a share keeps

    @Test func textOnlyKeepsTheTextExactlyAndFillsTheMessageBox() throws {
        let draft = try inbox.begin()
        let shared = "  Two lines,\nexactly as selected.  "
        try draft.addText(shared)
        _ = try draft.commit(note: "")

        let share = try #require(shares.first)
        #expect(share.text == shared)
        #expect(share.files.isEmpty && share.links.isEmpty)
        #expect(share.composerText == shared)
    }

    @Test func aLinkAndThePersonsNoteBothReachTheMessageBox() throws {
        let draft = try inbox.begin()
        try draft.addLink("https://example.com/article?id=7")
        _ = try draft.commit(note: "Worth a read?")

        let share = try #require(shares.first)
        #expect(share.links == ["https://example.com/article?id=7"])
        #expect(share.note == "Worth a read?")
        #expect(share.composerText == "Worth a read?\n\nhttps://example.com/article?id=7")
    }

    @Test func aPageTitleThatHoldsItsLinkShowsTheLinkOnce() throws {
        let draft = try inbox.begin()
        try draft.addText("A made-up page https://example.com/p")
        try draft.addLink("https://example.com/p")
        try draft.addLink("https://example.com/p")
        _ = try draft.commit(note: "")
        #expect(try #require(shares.first).composerText == "A made-up page https://example.com/p")
    }

    @Test func aLinkThatIsNotAWebLinkTravelsAsText() throws {
        let draft = try inbox.begin()
        try draft.addLink("mailto:someone@example.com")
        _ = try draft.commit(note: "")
        let share = try #require(shares.first)
        #expect(share.links.isEmpty)
        #expect(share.text == "mailto:someone@example.com")
    }

    @Test func longTextBecomesATextFileWithEveryByte() throws {
        let draft = try inbox.begin()
        // Over the 48-byte inline limit in bytes, though not in characters.
        let long = String(repeating: "é", count: 30)
        #expect(long.count < 48 && long.utf8.count > 48)
        try draft.addText(long)
        _ = try draft.commit(note: "Summarize")

        let share = try #require(shares.first)
        #expect(share.text.isEmpty)
        let file = try #require(share.files.first)
        #expect(file.name == "Shared text.txt" && file.mimeType == "text/plain")
        #expect(try Data(contentsOf: inbox.fileURL(file, in: share)) == Data(long.utf8))
        #expect(share.composerText == "Summarize")
    }

    @Test func picturesKeepTheirOwnTypeAndName() throws {
        let draft = try inbox.begin()
        try draft.addFile(copying: source("IMG_0007", 40), suggestedName: "IMG_0007", kind: .image,
                          typeIdentifier: "public.heic", mimeType: "image/heic", preferredExtension: "heic")
        _ = try draft.commit(note: "")
        let file = try #require(shares.first?.files.first)
        #expect(file.name == "IMG_0007.heic")
        #expect(file.typeIdentifier == "public.heic" && file.mimeType == "image/heic" && file.kind == .image)
        #expect(file.byteCount == 40)
    }

    // MARK: - All or nothing

    @Test func oneRejectedFileRollsTheWholeShareBack() throws {
        let draft = try inbox.begin()
        try draft.addText("Look at these")
        try addFile(draft, "fits.pdf", 100)
        #expect(throws: PendingShareError.fileTooLarge(name: "too big.pdf", limit: 256)) {
            try addFile(draft, "too big.pdf", 257)
        }
        draft.rollback()

        #expect(inbox.entries().isEmpty)
        #expect(stagingNames().isEmpty, "The file that fit is gone with the rest")
        #expect(throws: PendingShareError.finished) { try draft.commit(note: "") }
    }

    @Test func aPictureOverItsLimitIsRefusedByName() throws {
        let draft = try inbox.begin()
        #expect(throws: PendingShareError.fileTooLarge(name: "photo.png", limit: 64)) {
            try addFile(draft, "photo.png", 65, kind: .image)
        }
    }

    @Test func filesThatFitAloneButNotTogetherAreRefusedAsAShare() throws {
        let draft = try inbox.begin()
        try addFile(draft, "one.pdf", 200)
        #expect(throws: PendingShareError.shareTooLarge(limit: 400)) { try addFile(draft, "two.pdf", 201) }
    }

    @Test func oneFileTooManyIsRefused() throws {
        let draft = try inbox.begin()
        for index in 0..<3 { try addFile(draft, "file \(index).pdf", 10) }
        #expect(throws: PendingShareError.tooManyFiles(limit: 3)) { try addFile(draft, "file 3.pdf", 10) }
    }

    @Test func unreadableAndEmptyFilesAreNamed() throws {
        let draft = try inbox.begin()
        let missing = directory.appendingPathComponent("missing.pdf")
        #expect(throws: PendingShareError.unreadable(name: "missing.pdf")) {
            try draft.addFile(copying: missing, suggestedName: "missing.pdf", kind: .file,
                              typeIdentifier: "com.adobe.pdf", mimeType: "application/pdf", preferredExtension: "pdf")
        }
        #expect(throws: PendingShareError.emptyFile(name: "empty.pdf")) { try addFile(draft, "empty.pdf", 0) }
        // A folder is not a file it can read.
        let folder = directory.appendingPathComponent("a folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: PendingShareError.unreadable(name: "a folder")) {
            try draft.addFile(copying: folder, suggestedName: "a folder", kind: .file, typeIdentifier: "public.folder",
                              mimeType: "application/octet-stream", preferredExtension: nil)
        }
    }

    @Test func theCopyStopsAtTheLimitWhateverTheSizeSaid() throws {
        // A file that grows after its size was read, or a size that was wrong: the count decides.
        let source = try source("growing.bin", 300)
        let target = directory.appendingPathComponent("copy.bin")
        #expect(throws: PendingShareError.fileTooLarge(name: "growing.bin", limit: 299)) {
            _ = try PendingShareInbox.copy(source, to: target, name: "growing.bin", limit: 299, isCancelled: { false })
        }
    }

    @Test func tooMuchTextAndALongNoteAreRefused() throws {
        let draft = try inbox.begin()
        #expect(throws: PendingShareError.textTooLong(limit: 1_024)) {
            try draft.addText(String(repeating: "a", count: 1_025))
        }
        try draft.addText("fine")
        #expect(throws: PendingShareError.noteTooLong(limit: 32)) {
            _ = try draft.commit(note: String(repeating: "n", count: 33))
        }
        // Refused, not finished: a shorter note still saves it.
        _ = try draft.commit(note: "short")
        #expect(shares.count == 1)
    }

    @Test func aShareWithNothingInItIsNotSaved() throws {
        let draft = try inbox.begin()
        try draft.addText(" \n\t ")
        #expect(throws: PendingShareError.nothingToShare) { _ = try draft.commit(note: "Just a note") }
    }

    @Test func cancellingMidCopyLeavesNothing() throws {
        let draft = try inbox.begin()
        #expect(throws: PendingShareError.cancelled) {
            try draft.addFile(copying: source("big.pdf", 200), suggestedName: "big.pdf", kind: .file,
                              typeIdentifier: "com.adobe.pdf", mimeType: "application/pdf", preferredExtension: "pdf",
                              isCancelled: { true })
        }
        draft.rollback()
        #expect(stagingNames().isEmpty && inbox.entries().isEmpty)
    }

    // MARK: - Waiting until it's sent or deleted

    @Test func aSavedShareIsStillThereAfterARelaunch() throws {
        let draft = try inbox.begin()
        try draft.addText("Keep me")
        try addFile(draft, "report.pdf", 120)
        let saved = try draft.commit(note: "")

        // A new process: nothing in memory, only what's on disk.
        let reopened = PendingShareInbox(root: inbox.root, limits: Self.smallLimits)
        reopened.removeAbandonedStaging()
        let entries = reopened.entries()
        #expect(entries == [.share(saved, placement: nil)])
        let file = try #require(saved.files.first)
        #expect(try Data(contentsOf: reopened.fileURL(file, in: saved)).count == 120)
    }

    @Test func aDraftIsNeverListedAndOnlyItsWritersDeathFreesIt() throws {
        let alive = try inbox.begin()
        try alive.addText("Still writing")
        let killed = try inbox.begin()
        try addFile(killed, "half.pdf", 50)
        killed.abandonForTesting()

        #expect(inbox.entries().isEmpty, "Staged shares are never offered")
        inbox.removeAbandonedStaging()
        #expect(stagingNames() == [alive.id, alive.id + ".lock"])

        // The sheet that's still open saves as usual.
        _ = try alive.commit(note: "")
        #expect(shares.map(\.id) == [alive.id])
        #expect(stagingNames().isEmpty)
    }

    @Test func savingTwiceIsRefusedAndPlacingASentShareSaysGone() throws {
        let draft = try inbox.begin()
        try draft.addText("Once")
        let share = try draft.commit(note: "")
        #expect(throws: PendingShareError.finished) { _ = try draft.commit(note: "") }
        #expect(shares.count == 1)

        let placement = PendingSharePlacement(
            destination: .init(scope: "scope-a", agentID: "juno", sessionID: nil),
            agentName: "Juno", placedAt: Date(timeIntervalSince1970: 1_800_000_100))
        try inbox.place(share.id, placement)
        #expect(inbox.entries() == [.share(share, placement: placement)])

        #expect(try inbox.remove(share.id))
        #expect(try !inbox.remove(share.id), "Removing again is a no-op")
        #expect(inbox.entries().isEmpty)
        #expect(throws: PendingShareError.gone) { try inbox.place(share.id, placement) }
    }

    @Test func aFullInboxRefusesTheNextShareAndKeepsTheOthers() throws {
        var saved: [PendingShare] = []
        for index in 0..<2 {
            let draft = try inbox.begin()
            try draft.addText("Share \(index)")
            saved.append(try draft.commit(note: ""))
        }
        let third = try inbox.begin()
        try third.addText("One more")
        #expect(throws: PendingShareError.inboxFull(shares: 2)) { _ = try third.commit(note: "") }
        third.rollback()
        #expect(shares.sorted { $0.id < $1.id } == saved.sorted { $0.id < $1.id })
    }

    @Test func theInboxLimitCountsBytesToo() throws {
        let first = try inbox.begin()
        try addFile(first, "a.pdf", 250)
        try addFile(first, "b.pdf", 150)
        _ = try first.commit(note: "")
        let second = try inbox.begin()
        try addFile(second, "c.pdf", 201)
        #expect(throws: PendingShareError.inboxFull(shares: 1)) { _ = try second.commit(note: "") }
    }

    @Test func aDamagedShareIsListedForDeletionNeverDropped() throws {
        let draft = try inbox.begin()
        try addFile(draft, "report.pdf", 100)
        let share = try draft.commit(note: "")

        // A file that isn't the size its share says.
        try Data(repeating: 0, count: 99).write(to: inbox.fileURL(try #require(share.files.first), in: share))
        #expect(inbox.entries() == [.unreadable(id: share.id)])

        // A manifest that doesn't read.
        let other = PendingShare.newID()
        try FileManager.default.createDirectory(at: inbox.folder(other), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: inbox.folder(other).appendingPathComponent("share.json"))
        #expect(Set(inbox.entries().map(\.id)) == [share.id, other])

        #expect(try inbox.remove(other))
        #expect(inbox.entries() == [.unreadable(id: share.id)])
    }

    @Test func aManifestPointingOutsideItsFolderIsUnreadable() throws {
        let draft = try inbox.begin()
        try addFile(draft, "report.pdf", 10)
        let share = try draft.commit(note: "")
        // A real file of the right size, outside the share's folder.
        try Data(repeating: 0x62, count: 10).write(to: inbox.root.appendingPathComponent("elsewhere.bin"))
        let manifest = inbox.folder(share.id).appendingPathComponent("share.json")
        let tampered = try String(contentsOf: manifest, encoding: .utf8)
            .replacingOccurrences(of: "files\\/0", with: "..\\/elsewhere.bin")
            .replacingOccurrences(of: "files/0", with: "../elsewhere.bin")
        #expect(tampered.contains("elsewhere.bin"))
        try Data(tampered.utf8).write(to: manifest)
        #expect(inbox.entries() == [.unreadable(id: share.id)])
    }

    // MARK: - Names

    @Test func namesAreMadeSafeForTheMessageBoxAndTheComputer() {
        func name(_ suggested: String?, _ kind: PendingShare.File.Kind = .file, ext: String? = "pdf",
                  taken: Set<String> = []) -> String {
            PendingShare.fileName(suggested: suggested, kind: kind, preferredExtension: ext, taken: taken)
        }
        #expect(name("../../etc/passwd", ext: nil) == "passwd")
        #expect(name("  .hidden report.pdf ") == "hidden report.pdf")
        #expect(name("line\nbreak\u{0}.pdf") == "linebreak.pdf")
        #expect(name("a:b.pdf") == "a-b.pdf")
        #expect(name(nil, .image, ext: "heic") == "Shared picture.heic")
        #expect(name("", ext: nil) == "Shared file")
        #expect(name("Report.pdf", taken: ["report.pdf"]) == "Report 2.pdf")
        #expect(name("Report.pdf", taken: ["report.pdf", "Report 2.pdf"]) == "Report 3.pdf")
        let long = name(String(repeating: "x", count: 300) + ".pdf")
        #expect(long.count == 180 && long.hasSuffix(".pdf"))
        for candidate in ["../../etc/passwd", " .x", "a\u{7}b", String(repeating: "y", count: 400)] {
            #expect(PendingShare.isValidFileName(name(candidate)))
        }
    }

    @Test func longNamesThatClashStillGetNamesOfTheirOwn() async throws {
        // Over 180 characters, the same name twice, or names alike in their first 180: each number
        // keeps its room, so the search for a free name always ends. It once looped for good,
        // holding the share's lock so Cancel couldn't stop it; run off this task, so a loop like
        // that fails here instead of hanging the run.
        let long = String(repeating: "x", count: 300) + ".pdf"
        let alike = String(repeating: "x", count: 290) + "y.pdf"
        let named: Result<[String], PendingShareError> = await PendingShareWait.first(
            deadline: .seconds(10), timedOut: .cancelled, cancelled: .cancelled, cancellation: .init()) { finish in
            DispatchQueue.global().async {
                var taken: Set<String> = []
                var names: [String] = []
                for suggested in [long, long, alike] {
                    let name = PendingShare.fileName(suggested: suggested, kind: .file, preferredExtension: nil,
                                                     taken: taken)
                    taken.insert(name)
                    names.append(name)
                }
                finish(.success(names))
            }
        }
        let names = try named.get()
        #expect(Set(names).count == 3)
        for name in names {
            #expect(name.count <= 180 && name.hasSuffix(".pdf") && PendingShare.isValidFileName(name))
        }
        #expect(names[1].hasSuffix(" 2.pdf") && names[2].hasSuffix(" 3.pdf"))

        // Through a share being saved, where the name is picked under its lock.
        var limits = Self.smallLimits
        limits.files = 10
        let roomy = PendingShareInbox(root: inbox.root, limits: limits)
        let draft = try roomy.begin()
        let sources = try (0..<4).map { _ in try source("x.pdf", 4) }
        let added: Result<[String], PendingShareError> = await PendingShareWait.first(
            deadline: .seconds(10), timedOut: .cancelled, cancelled: .cancelled, cancellation: .init()) { finish in
            DispatchQueue.global().async {
                do {
                    finish(.success(try sources.map {
                        try draft.addFile(copying: $0, suggestedName: long, kind: .file, typeIdentifier: "com.adobe.pdf",
                                          mimeType: "application/pdf", preferredExtension: "pdf").name
                    }))
                } catch {
                    finish(.failure(error as? PendingShareError ?? .storageUnavailable))
                }
            }
        }
        let addedNames = try added.get()
        #expect(Set(addedNames).count == 4)
        let saved = try draft.commit(note: "")
        #expect(roomy.entries() == [.share(saved, placement: nil)])
        #expect(saved.files.map(\.name) == addedNames)
    }

    // MARK: - Into the message box

    @Test func theMessageBoxGetsTheWordsOnceBelowWhatWasTyped() {
        #expect(PendingShare.draft("", adding: "Shared") == "Shared")
        #expect(PendingShare.draft("Typed first", adding: "Shared") == "Typed first\n\nShared")
        // Back after a relaunch, the draft already holds them.
        #expect(PendingShare.draft("Typed first\n\nShared", adding: "Shared") == nil)
        #expect(PendingShare.draft("Typed", adding: "  \n") == nil)
    }

    @Test func aDestinationIsNeverMovedToAnotherComputerAgentOrChat() {
        let destination = PendingShareDestination(scope: "scope-a", agentID: "juno", sessionID: "chat-1")
        #expect(destination.problem(currentScope: "scope-a", agentIDs: ["juno"], sessionIDs: ["chat-1"]) == nil)
        #expect(destination.problem(currentScope: "scope-b", agentIDs: ["juno"], sessionIDs: ["chat-1"])
                == .computerChanged)
        #expect(destination.problem(currentScope: nil, agentIDs: ["juno"], sessionIDs: ["chat-1"]) == .computerChanged)
        #expect(destination.problem(currentScope: "scope-a", agentIDs: ["kai"], sessionIDs: ["chat-1"]) == .agentGone)
        #expect(destination.problem(currentScope: "scope-a", agentIDs: ["juno"], sessionIDs: []) == .chatGone)
        let newChat = PendingShareDestination(scope: "scope-a", agentID: "juno", sessionID: nil)
        #expect(newChat.problem(currentScope: "scope-a", agentIDs: ["juno"], sessionIDs: []) == nil)
    }

    @Test func theStandardLimitsMatchTheMessageBox() {
        let limits = PendingShareLimits.standard
        #expect(limits.files == 10)
        #expect(limits.imageBytes == 64 * 1_024 * 1_024)
        #expect(limits.fileBytes == 256 * 1_024 * 1_024)
    }
}
