import Foundation
import Testing
@testable import Bighelp

/// How a big file shows in the chat (#721, Colt's picks): a tile while it goes up, then a line on
/// the rail once Hermes takes the message, the same as a reread of the saved history shows.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BigFileChatTests {
    private static let file = ChatBigFile(
        id: String(repeating: "a", count: 32), fileName: "Trip to the coast.mov", mimeType: "video/quicktime",
        byteCount: 80_000_000, sha256: String(repeating: "0", count: 64),
        video: .init(seconds: 72.4, width: 1920, height: 1080))
    private static let path = "/home/fixture/garden/uploads/2026-10-31/Trip to the coast.mov"
    /// What `sendDraftAttachments` sends: the words, Hermes' reference, then the app's note.
    private static var sentText: String {
        "Cut the best 10 seconds\n@file:`\(path)`\n" + file.agentNote
    }

    @Test func theNoteGivesSizeAndLengthForTheLineAndTheAgent() {
        let note = Self.file.agentNote
        #expect(note.hasPrefix("[Video attached: Trip to the coast.mov ("))
        #expect(note.contains("1 min 12 s") && note.contains("1920×1080"))
        let parsed = ChatSentFileNote(note)
        #expect(parsed?.fileName == "Trip to the coast.mov")
        #expect(parsed?.meta.contains("1 min 12 s") == true)
        let plain = ChatBigFile(id: Self.file.id, fileName: "logs (old).zip", mimeType: "application/zip",
                                byteCount: 120_000_000, sha256: Self.file.sha256, video: nil)
        #expect(ChatSentFileNote(plain.agentNote)?.fileName == "logs (old).zip")
    }

    @Test func aSentFileIsALineAndItsPathNeverShowsAsText() {
        let split = ChatSentFiles.split(Self.sentText)
        #expect(split.text == "Cut the best 10 seconds")
        #expect(split.files.count == 1)
        #expect(split.files.first?.name == "Trip to the coast.mov")
        #expect(split.files.first?.path == Self.path)
        #expect(split.files.first?.isVideo == true)
        #expect(!split.text.contains("/home/") && !split.text.contains("@file:") && !split.text.contains("attached:"))
        // A file alone has no words left to show.
        #expect(ChatSentFiles.split("@file:\(Self.path.replacingOccurrences(of: " ", with: "_"))").text.isEmpty)
        // The chat list says Attachment, without the note or the path.
        #expect(HermesUserMessageDisplay.preview(Self.sentText) == "Cut the best 10 seconds")
    }

    /// The tile turns into the line once, when Hermes takes the message, and a reread of the
    /// saved history then shows the same row. A tile kept until the reread fails this.
    @Test func theTileTurnsIntoTheLineOnceWhenHermesTakesTheMessageAndAReadKeepsIt() throws {
        let model = ChatModel(conversationID: "big-file-chat", client: ConversationFixtureClient(), initialItems: [])
        let human = model.humanItem(content: "Cut the best 10 seconds").carrying(bigFiles: [Self.file])
        // While its file goes up, the message waits outside the transcript, where a reread can't drop it.
        model.bigFileSends.append(human)
        BigFileUploadBoard.shared.uploading(Self.file.id, sentBytes: 34_000_000, byteCount: Self.file.byteCount)
        #expect(model.bigFileSends.first?.metadata.bigFiles == [Self.file])
        #expect(!model.items.contains { $0.id == human.id })

        model.bigFileMessageAccepted(rowID: human.id, text: Self.sentText, files: [Self.file])
        let accepted = try #require(model.items.last)
        #expect(accepted.id == human.id)
        #expect(model.bigFileSends.isEmpty)
        #expect(accepted.metadata.bigFiles.isEmpty)
        #expect(BigFileUploadBoard.shared.state(for: Self.file.id) == nil)
        let live = ChatSentFiles.split(Self.text(accepted))

        // What a reread gets for this row: Hermes' saved text, as the history shows a person's message.
        let reread = ChatSentFiles.split(HermesUserMessageDisplay.text(Self.sentText))
        #expect(live.text == reread.text)
        #expect(live.files == reread.files)
        #expect(live.files.count == 1)

        // Once: a second answer for the same message changes nothing.
        model.bigFileMessageAccepted(rowID: human.id, text: "Something else", files: [Self.file])
        #expect(Self.text(model.items.last) == Self.sentText)
    }

    /// VoiceOver reads the message the way the row shows it: the words and the file's name.
    @Test func theMessageIsReadAloudWithItsFileNameNeverItsPath() {
        let model = ChatModel(conversationID: "big-file-spoken", client: ConversationFixtureClient(), initialItems: [])
        let item = model.humanItem(content: Self.sentText)
        let spoken = TimelineSenderResolver().accessibilityDescription(for: item)
        #expect(spoken.contains("Cut the best 10 seconds"))
        #expect(spoken.contains("Video Trip to the coast.mov"))
        #expect(!spoken.contains("/home/") && !spoken.contains("@file:") && !spoken.contains("attached:"))
        let reply = model.humanItem(content: "[Replying to: \"Send me the clip\"]\n\n" + Self.sentText)
        #expect(!TimelineSenderResolver().accessibilityDescription(for: reply).contains("@file:"))
    }

    /// What Hermes saves for the turn (real-host probe, run 4): the reference relative to the chat's
    /// folder, the app's note, then its attached context for the model with the host path. None of
    /// that shows as text; the file is one line, and it opens where the block says the file is.
    private static var hermesSaved: String {
        "Cut the best 10 seconds\n@file:`uploads/2026-10-31/Trip to the coast.mov`\n" + file.agentNote
            + "\n\n--- Attached Context ---\n\n📎 @file:`uploads/2026-10-31/Trip to the coast.mov` (video/quicktime, "
            + "76.3 MB) — binary file, not inlined as text. It is available on disk at `" + path + "`. Use your tools "
            + "to work with it (read or convert it, extract its text, or view/render it as needed); do not tell the "
            + "user the file type is unsupported."
    }

    @Test func hermesSavedFormIsOneLineAndNoPathOrContextShows() {
        for shown in [ChatSentFiles.split(Self.hermesSaved), ChatSentFiles.split(HermesUserMessageDisplay.text(Self.hermesSaved))] {
            #expect(shown.text == "Cut the best 10 seconds")
            #expect(shown.files.count == 1)
            #expect(shown.files.first?.name == "Trip to the coast.mov")
            #expect(shown.files.first?.path == Self.path, "Files opens it where Hermes' block says it is")
            #expect(shown.files.first?.meta?.contains("1 min 12 s") == true)
            for raw in ["Attached Context", "available on disk", "/home/", "@file:", "attached:", "Use your tools"] {
                #expect(!shown.text.contains(raw), "\(raw)")
            }
        }
        #expect(HermesUserMessageDisplay.preview(Self.hermesSaved) == "Cut the best 10 seconds")
        // The media loader never fetches a big file back to show it as a tile on a reread.
        #expect(DirectHermesGeneratedMediaClient.messageMarkers(HermesUserMessageDisplay.text(Self.hermesSaved),
                                                                role: .human).isEmpty)
        let model = ChatModel(conversationID: "big-file-saved", client: ConversationFixtureClient(), initialItems: [])
        let spoken = TimelineSenderResolver().accessibilityDescription(for: model.humanItem(content: Self.hermesSaved))
        #expect(!spoken.contains("/home/") && !spoken.contains("Attached Context"))
    }

    /// The live row (what the app sent: a relative reference when Hermes used the file in place) and
    /// the reread (Hermes' saved form) show the same words and the same line.
    @Test func theLiveRowAndTheRereadLookTheSame() {
        let live = ChatSentFiles.split("Cut the best 10 seconds\n@file:`uploads/2026-10-31/Trip to the coast.mov`\n"
                                       + Self.file.agentNote)
        let reread = ChatSentFiles.split(HermesUserMessageDisplay.text(Self.hermesSaved))
        #expect(live.text == reread.text)
        #expect(live.files.map(\.name) == reread.files.map(\.name))
        #expect(live.files.map(\.meta) == reread.files.map(\.meta))
        #expect(live.files.first?.path == "uploads/2026-10-31/Trip to the coast.mov")
    }

    @Test func aRelativeFileOpensUnderTheAgentsFolder() async {
        let source = FixtureFiles()
        let model = SimpleBotFilesModel(agentID: "default", source: source)
        await model.reveal(path: "uploads/2026-10-31/Trip to the coast.mov")
        #expect(source.listed.last == "/home/fixture/garden/uploads/2026-10-31")
    }

    @Test func aFailedUploadSaysWhyAndTryAgainRunsItsRetry() {
        let board = BigFileUploadBoard.shared
        var retried = 0
        board.failed("failing-file", message: BigFileUploadFailure.noSpace.message) { retried += 1 }
        #expect(board.state(for: "failing-file") == .failed("Not sent. The computer is out of space for this file."))
        board.retry("failing-file")
        board.retry("failing-file")
        #expect(retried == 1)
        board.finish("failing-file")
        #expect(board.state(for: "failing-file") == nil)
        #expect(BigFileUploadTile.counted(34_000_000, of: 80_000_000).hasSuffix("MB"))
        #expect(BigFileUploadTile.counted(34_000_000, of: 80_000_000).hasPrefix("34"))
    }

    @Test func filesOpensTheSentFileInItsFolder() async {
        let source = FixtureFiles()
        let model = SimpleBotFilesModel(agentID: "default", source: source)
        await model.reveal(path: Self.path)
        #expect(source.listed == ["/home/fixture/garden/uploads/2026-10-31"])
        #expect(model.playback != nil || model.openingPath == nil)
        #expect(source.opened == [Self.path])
        await model.reveal(path: "/home/fixture/garden/uploads/2026-10-31/gone.mov")
        #expect(model.notice?.contains("gone.mov") == true)
    }

    @Test func aProfileOpeningForAFileStartsOnFiles() {
        #expect(BotProfileOpening(file: Self.path).wantedTab == .files)
        #expect(BotProfileOpening(tab: .info).wantedTab == .info)
    }

    private static func text(_ item: TimelineItem?) -> String {
        guard case .message(let text)? = item?.content else { return "" }
        return text
    }
}

@MainActor
private final class FixtureFiles: SimpleBotFilesSource {
    var listed: [String] = []
    var opened: [String] = []
    var downloadLimit: Int { 25 * 1_024 * 1_024 }

    func list(agentID: String, path: String?) async throws -> HermesManagedFileDirectory {
        listed.append(path ?? "")
        let folder = path ?? "/home/fixture/garden"
        // The top folder has no parent, as on the computer.
        return HermesManagedFileDirectory(path: folder, parent: path == nil ? nil : "/home/fixture/garden", files: [
            HermesManagedFile(path: folder + "/Trip to the coast.mov", name: "Trip to the coast.mov", isDirectory: false,
                              byteCount: 80_000_000, modifiedAt: .now, mimeType: "video/quicktime"),
        ])
    }

    func download(agentID: String, file: HermesManagedFile) async throws -> HermesManagedFileContents {
        opened.append(file.path)
        throw CancellationError()
    }

    func canStream(agentID: String, file: HermesManagedFile) -> Bool {
        opened.append(file.path)
        return false
    }

    func playback(agentID: String, file: HermesManagedFile) -> DirectHermesManagedMediaPlayback? { nil }
}
