import CryptoKit
import Foundation
import Testing
@testable import Bighelp

/// Big files (#721): pieces, resume after a drop, the plugin gate and the host's answers.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BigFileUploadTests {
    // Piece math

    @Test func piecesCoverTheFileWithAShortLastPiece() throws {
        let plan = try BigFileUploadPlan(byteCount: 80 * 1_000 * 1_000, chunkBytes: 4 * 1_024 * 1_024)
        #expect(plan.chunkCount == 20)
        #expect(plan.range(of: 0) == 0..<4_194_304)
        #expect(plan.range(of: 19) == 79_691_776..<80_000_000)
        #expect((0..<plan.chunkCount).map { plan.range(of: $0).count }.reduce(0, +) == plan.byteCount)
        #expect(plan.missing([0, 2, 19]).count == 17)
        #expect(plan.receivedBytes([19]) == 308_224)
        #expect(throws: (any Error).self) { try BigFileUploadPlan(byteCount: BigFileUploads.maximumBytes + 1, chunkBytes: 4_194_304) }
        #expect(throws: (any Error).self) { try BigFileUploadPlan(byteCount: 10, chunkBytes: 1_000) }
    }

    @Test func anEightyMegabyteVideoIsBigAndFits() {
        #expect(BigFileUploads.isBig(80 * 1_000 * 1_000))
        #expect(!BigFileUploads.isBig(ChatAttachment.maximumBytes))
        #expect(BigFileUploads.maximumBytes >= 100 * 1_000 * 1_000)
    }

    @Test func theHostsAnswerIsReadStrictly() throws {
        let good: [String: BighelpJSONValue] = [
            "uploadId": .string(String(repeating: "a", count: 32)), "byteCount": .integer(10_000_000),
            "chunkBytes": .integer(4_194_304), "receivedChunks": .array([.integer(0), .integer(2)]),
            "receivedBytes": .integer(4_194_304 + 1_611_392), "finished": .boolean(false),
        ]
        let receipt = try BigFileUploadReceipt(good, expectedByteCount: 10_000_000)
        #expect(receipt.received == [0, 2])
        var bad = good; bad["receivedChunks"] = .array([.integer(3)])
        #expect(throws: (any Error).self) { try BigFileUploadReceipt(bad, expectedByteCount: 10_000_000) }
        bad = good; bad["receivedChunks"] = .array([.integer(0), .integer(0)])
        #expect(throws: (any Error).self) { try BigFileUploadReceipt(bad, expectedByteCount: 10_000_000) }
        bad = good; bad["uploadId"] = .string("../../etc")
        #expect(throws: (any Error).self) { try BigFileUploadReceipt(bad, expectedByteCount: 10_000_000) }
        #expect(throws: (any Error).self) { try BigFileUploadReceipt(good, expectedByteCount: 9) }
        bad = good; bad["receivedBytes"] = .integer(1)
        #expect(throws: (any Error).self) { try BigFileUploadReceipt(bad, expectedByteCount: 10_000_000) }
    }

    @Test func onlyTheAgentsUploadsFolderOrThePluginsStagingGoesToFileAttach() throws {
        let id = String(repeating: "b", count: 32)
        func answer(_ path: String, _ inWorkspace: Bool) -> [String: BighelpJSONValue] {
            ["finished": .boolean(true), "uploadId": .string(id), "path": .string(path), "inWorkspace": .boolean(inWorkspace)]
        }
        let workspace = "/home/hermes/projects/garden/uploads/2026-10-31/Trip.mov"
        let inFolder = try BigFileUploadReceipt.finishedFile(answer(workspace, true), uploadID: id)
        #expect(inFolder.path == workspace && inFolder.inWorkspace)
        let staged = "/home/hermes/.hermes/plugin-data/loopdy/uploads/\(id)/file/Trip.mov"
        let stagedFile = try BigFileUploadReceipt.finishedFile(answer(staged, false), uploadID: id)
        #expect(stagedFile.path == staged && !stagedFile.inWorkspace)
        for (path, inWorkspace) in [
            ("/etc/passwd", true), ("/etc/passwd", false), (workspace, false), (staged, true),
            ("relative/uploads/2026-10-31/a.mov", true), ("/x/uploads/2026-10-31/../../.ssh/id", true),
            ("/x/uploads/31-10-2026/a.mov", true), ("/x/uploads/2026-10-31/.hidden", true),
            ("/x/uploads/2026-10-31/a\nb", true),
            ("/x/plugin-data/loopdy/uploads/\(String(repeating: "c", count: 32))/file/a.mov", false),
        ] {
            #expect(throws: (any Error).self, "\(path)") {
                try BigFileUploadReceipt.finishedFile(answer(path, inWorkspace), uploadID: id)
            }
        }
        var missing = answer(workspace, true); missing["inWorkspace"] = nil
        #expect(throws: (any Error).self) { try BigFileUploadReceipt.finishedFile(missing, uploadID: id) }
    }

    @Test func eachPieceRequestCarriesItsUploadOffsetAndGuard() throws {
        let http = DirectHermesHTTP(endpoint: try DirectHermesEndpoint(address: "https://hermes.example.invalid"))
        let chunk = try DirectHermesBigFileChunk(uploadID: String(repeating: "d", count: 32), offset: 8_388_608,
                                                 length: 4_194_304, sha256: String(repeating: "e", count: 64))
        let guardValue = try DirectHermesNativeRequestGuard(etag: "\"sha256:" + String(repeating: "f", count: 64) + "\"")
        let request = try http.bigFileChunkRequest(chunk, bearer: "fixture-token", legacyToken: nil, nativeGuard: guardValue)
        #expect(request.url?.path == "/api/plugins/loopdy/native/uploads/chunk")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Loopdy-Upload-Offset") == "8388608")
        #expect(request.value(forHTTPHeaderField: "X-Loopdy-Upload-ID") == chunk.uploadID)
        #expect(request.value(forHTTPHeaderField: "If-Match") == guardValue.etag)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect(request.httpBody == nil)
        #expect(throws: (any Error).self) {
            try DirectHermesBigFileChunk(uploadID: "x", offset: 0, length: 1, sha256: chunk.sha256)
        }
    }

    // The uploader against a host that behaves like the plugin

    @Test func aFileGoesInPiecesAndFinishesWithTheStagedPath() async throws {
        let file = try await Self.file(bytes: 10_000_000)
        defer { BigFileStore.remove(file) }
        let host = FakeUploadHost()
        var progress: [Int] = []
        let staged = try await BigFileUploader(host: host, sender: host, retryDelays: [], sleep: { _ in })
            .upload(file, agentID: "default") { progress.append($0.sentBytes) }
        #expect(staged.path == "/srv/agent/uploads/2026-10-31/Clip.mov" && staged.inWorkspace)
        #expect(host.stored == (try Data(contentsOf: file.localURL)))
        #expect(host.pieceRequests.count == 3)
        #expect(progress.last == 10_000_000)
        #expect(progress == progress.sorted())
        // Every piece went as a file on disk, never as an in-memory body.
        #expect(host.pieceRequests.allSatisfy { $0.httpBody == nil && $0.httpBodyStream == nil })
    }

    @Test func aDropMidPieceResumesFromThePiecesTheHostConfirmed() async throws {
        let file = try await Self.file(bytes: 10_000_000)
        defer { BigFileStore.remove(file) }
        let host = FakeUploadHost()
        host.dropPieces = [1]
        let waits = WaitCount()
        let staged = try await BigFileUploader(host: host, sender: host, parallelPieces: 1,
                                               retryDelays: [.seconds(1)], sleep: { _ in waits.add() })
            .upload(file, agentID: "default")
        #expect(waits.value == 0)
        #expect(host.pieceOffsets == [0, 4_194_304, 8_388_608, 4_194_304])
        #expect(host.stored == (try Data(contentsOf: file.localURL)))
        #expect(!staged.path.isEmpty)
    }

    @Test func aRelaunchStartsTheSameFileAgainAndSendsOnlyWhatIsMissing() async throws {
        let file = try await Self.file(bytes: 10_000_000)
        defer { BigFileStore.remove(file) }
        let host = FakeUploadHost()
        host.preloaded = [0, 2]
        host.preloadSource = file.localURL
        _ = try await BigFileUploader(host: host, sender: host, retryDelays: [], sleep: { _ in })
            .upload(file, agentID: "default")
        #expect(host.pieceOffsets == [4_194_304])
    }

    /// A background session hands over the response only with the finished task. Taking it from
    /// there is what lets a piece the host took count; without it every piece read as a refusal.
    @Test func aFinishedBackgroundPieceUsesTheTasksOwnResponse() throws {
        let url = URL(string: "https://hermes.example.invalid" + DirectHermesBigFileChunk.route)!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let body = Data(#"{"uploadId":"x"}"#.utf8)
        let finished = try BigFilePieceSession.outcome(failure: nil, captured: nil, taskResponse: response,
                                                            requested: url, body: body).get()
        #expect(finished.1.statusCode == 200 && finished.0 == body)
        #expect(throws: (any Error).self) {
            try BigFilePieceSession.outcome(failure: nil, captured: nil, taskResponse: nil, requested: url, body: body).get()
        }
        let elsewhere = HTTPURLResponse(url: URL(string: "https://other.example.invalid/")!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!
        #expect(throws: DirectHermesError.redirectRefused) {
            try BigFilePieceSession.outcome(failure: nil, captured: nil, taskResponse: elsewhere, requested: url,
                                                 body: body).get()
        }
        #expect(throws: CancellationError.self) {
            try BigFilePieceSession.outcome(failure: URLError(.cancelled), captured: nil, taskResponse: response,
                                                 requested: url, body: body).get()
        }
    }

    /// An answer that doesn't read (or a 400 with no code, from a proxy) is no refusal: the upload asks the host
    /// what it has and goes on, instead of saying the computer didn't take the file.
    @Test func anAnswerThatDoesNotReadIsTriedAgainNotAFinalRefusal() async throws {
        let file = try await Self.file(bytes: 5_000_000)
        defer { BigFileStore.remove(file) }
        let host = FakeUploadHost()
        host.unreadableOnce = true
        let staged = try await BigFileUploader(host: host, sender: host, retryDelays: [.seconds(1)], sleep: { _ in })
            .upload(file, agentID: "default")
        #expect(host.stored == (try Data(contentsOf: file.localURL)))
        #expect(!staged.path.isEmpty)
    }

    @Test func aChangedContextIsReadAgainAndThePieceRetried() async throws {
        let file = try await Self.file(bytes: 5_000_000)
        defer { BigFileStore.remove(file) }
        let host = FakeUploadHost()
        host.staleOnce = true
        _ = try await BigFileUploader(host: host, sender: host, retryDelays: [.seconds(1)], sleep: { _ in })
            .upload(file, agentID: "default")
        #expect(host.contextReloads == 1)
        #expect(host.stored == (try Data(contentsOf: file.localURL)))
    }

    @Test func aFullDiskSaysWhyAndStops() async throws {
        let file = try await Self.file(bytes: 5_000_000)
        defer { BigFileStore.remove(file) }
        let host = FakeUploadHost()
        host.startRefusal = "upload_no_space"
        await #expect(throws: BigFileUploadError(failure: .noSpace)) {
            try await BigFileUploader(host: host, sender: host, retryDelays: [.seconds(1)], sleep: { _ in })
                .upload(file, agentID: "default")
        }
        #expect(BigFileUploadFailure.noSpace.message.contains("out of space"))
    }

    @Test func aHostWithoutTheFeatureKeepsTheEightMegabyteLimit() async throws {
        let file = try await Self.file(bytes: 9_000_000)
        defer { BigFileStore.remove(file) }
        let host = FakeUploadHost()
        host.features = []
        await #expect(throws: BigFileUploadError(failure: .pluginRequired)) {
            try await BigFileUploader(host: host, sender: host, retryDelays: [], sleep: { _ in })
                .upload(file, agentID: "default")
        }
        #expect(host.operations.isEmpty)
        #expect(BigFileUploadFailure.pluginRequired.message.contains("update") || BigFileUploadFailure.pluginRequired.message.contains("Update"))
    }

    /// A proxy in front of Hermes that takes 1 MB at most (nginx's and aiohttp's default) answers each 4 MB
    /// piece with a plain 413. The file starts again in 512 KB pieces, at once, and goes through.
    @Test func aProxyThatRefusesBigPiecesGetsTheFileInSmallPieces() async throws {
        let file = try await Self.file(bytes: 5_000_000)
        defer { BigFileStore.remove(file) }
        let host = FakeUploadHost()
        host.features.insert(BigFileUploads.smallPiecesFeature)
        host.proxyLimit = 1_048_576
        let waits = WaitCount()
        let staged = try await BigFileUploader(host: host, sender: host, retryDelays: [.seconds(1), .seconds(1)],
                                               sleep: { _ in waits.add() }).upload(file, agentID: "default")
        #expect(!staged.path.isEmpty)
        #expect(host.stored == (try Data(contentsOf: file.localURL)))
        #expect(host.startPieceSizes == [nil, BigFileUploads.smallChunkBytes])
        #expect(host.discardedUploads == [String(repeating: "9", count: 32)], "The refused upload is let go")
        #expect(waits.value == 0, "A refusal is no dropped connection: nothing waits to try again")
    }

    @Test func aProxyRefusalOnAnOlderPluginSaysToUpdateItAtOnce() async throws {
        let file = try await Self.file(bytes: 5_000_000)
        defer { BigFileStore.remove(file) }
        let host = FakeUploadHost()
        host.proxyLimit = 1_048_576
        let waits = WaitCount()
        await #expect(throws: BigFileUploadError(failure: .proxyLimitNeedsPlugin)) {
            try await BigFileUploader(host: host, sender: host, retryDelays: [.seconds(1), .seconds(1)],
                                      sleep: { _ in waits.add() }).upload(file, agentID: "default")
        }
        #expect(waits.value == 0)
        #expect(BigFileUploadFailure.proxyLimitNeedsPlugin.message.contains("Update the Bighelp plugin"))
    }

    @Test func smallPiecesThatAreRefusedTooStopWithTheReason() async throws {
        let file = try await Self.file(bytes: 5_000_000)
        defer { BigFileStore.remove(file) }
        let host = FakeUploadHost()
        host.features.insert(BigFileUploads.smallPiecesFeature)
        host.proxyLimit = 100_000
        let waits = WaitCount()
        await #expect(throws: BigFileUploadError(failure: .proxyLimit)) {
            try await BigFileUploader(host: host, sender: host, retryDelays: [.seconds(1), .seconds(1)],
                                      sleep: { _ in waits.add() }).upload(file, agentID: "default")
        }
        #expect(waits.value == 0)
        #expect(host.startPieceSizes == [nil, BigFileUploads.smallChunkBytes])
    }

    /// A proxy that can't reach Hermes for a moment answers 502 with an error code of its own. That is a
    /// dropped connection, not the plugin refusing the file: the piece goes again.
    @Test func aProxysGatewayErrorIsADropNotARefusal() async throws {
        let file = try await Self.file(bytes: 5_000_000)
        defer { BigFileStore.remove(file) }
        let host = FakeUploadHost()
        host.gatewayErrors = [1]
        let staged = try await BigFileUploader(host: host, sender: host, retryDelays: [.seconds(1)],
                                               sleep: { _ in }).upload(file, agentID: "default")
        #expect(!staged.path.isEmpty)
        #expect(host.stored == (try Data(contentsOf: file.localURL)))
        #expect(host.pieceOffsets.filter { $0 == host.chunkBytes }.count == 2)
    }

    @Test func aHostThatStaysAwayEndsWithAReasonNotAnEndlessLoad() async throws {
        let file = try await Self.file(bytes: 5_000_000)
        defer { BigFileStore.remove(file) }
        let host = FakeUploadHost()
        host.offline = true
        let waits = WaitCount()
        await #expect(throws: BigFileUploadError(failure: .connection)) {
            try await BigFileUploader(host: host, sender: host, retryDelays: [.seconds(1), .seconds(1)],
                                      sleep: { _ in waits.add() }).upload(file, agentID: "default")
        }
        #expect(waits.value == 2)
    }

    @Test func aFileThatArrivedIsNotSentAgainWhenItsMessageIsTriedAgain() async throws {
        let file = try await Self.file(bytes: 9 * 1_024 * 1_024)
        defer { BigFileStore.remove(file) }
        let host = FakeUploadHost()
        let first = try await BigFileUploader(host: host, sender: host).upload(file, agentID: "default")
        let sentOnce = host.pieceOffsets.count
        // The chat's connection changed before Hermes took the file: Try again uploads it anew,
        // on a link that drops the first call.
        host.dropsNextCall = true
        var progress: [Int] = []
        let again = try await BigFileUploader(host: host, sender: host, retryDelays: [.zero], sleep: { _ in })
            .upload(file, agentID: "default") { progress.append($0.sentBytes) }
        #expect(again == first)
        #expect(host.pieceOffsets.count == sentOnce, "The host has the whole file: no piece goes twice")
        #expect(progress == [file.byteCount], "Its tile shows the file as up")

        // Once Hermes has it and the staged copy is gone, the same file is a new upload.
        await BigFileUploader(host: host, sender: host).discard(first.uploadID)
        let later = try await BigFileUploader(host: host, sender: host).upload(file, agentID: "default")
        #expect(later.uploadID != first.uploadID)
        #expect(host.pieceOffsets.count == sentOnce * 2)
    }

    /// The first pieces of a file start at the same moment. Each once made a session of its own,
    /// their tasks shared numbers, and all but one waited for an answer that went to another.
    @Test func piecesThatStartTogetherEachGetAnAnswer() async throws {
        let piece = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".part")
        try Data(count: 64).write(to: piece)
        defer { try? FileManager.default.removeItem(at: piece) }
        // Nothing listens here, so every piece ends at once, with an error.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:9/piece")!)
        request.httpMethod = "POST"
        let sent = request
        let sends = (0..<3).map { _ in
            Task.detached {
                (try? await BigFilePieceSession.inFront.send(sent, fromFile: piece, onSent: { _ in })) == nil
            }
        }
        var ended = 0
        for send in sends {
            if await send.value { ended += 1 }
        }
        #expect(ended == 3)
    }

    @Test func piecesGoStraightToTheHostInFrontAndThroughIOSWhenBighelpIsAway() async throws {
        let piece = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".part")
        try Data([1, 2, 3]).write(to: piece)
        defer { try? FileManager.default.removeItem(at: piece) }
        let inFront = CountingSender(), away = CountingSender()
        let place = AppPlace()
        let sender = BigFilePieceSender(inFront: inFront, away: away, isAway: { place.isAway })
        let request = URLRequest(url: URL(string: "https://hermes.example.invalid/piece")!)
        _ = try await sender.send(request, fromFile: piece, onSent: { _ in })
        #expect((inFront.count, away.count) == (1, 0))
        place.isAway = true
        _ = try await sender.send(request, fromFile: piece, onSent: { _ in })
        #expect((inFront.count, away.count) == (1, 1))
        place.isAway = false
        _ = try await sender.send(request, fromFile: piece, onSent: { _ in })
        #expect((inFront.count, away.count) == (2, 1))
    }

    @Test func preparingCopiesAndChecksumsWithoutLoadingTheWholeFile() async throws {
        let file = try await Self.file(bytes: 3_000_000)
        defer { BigFileStore.remove(file) }
        let bytes = try Data(contentsOf: file.localURL)
        #expect(bytes.count == 3_000_000)
        #expect(file.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(file.video == nil)
        await #expect(throws: (any Error).self) {
            try await BigFileStore.prepare(copying: file.localURL, fileName: "../x.bin", mimeType: "application/zip")
        }
    }

    // Fixtures

    static func file(bytes: Int) async throws -> ChatBigFile {
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mov")
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in
            for index in stride(from: 0, to: buffer.count, by: 997) { buffer[index] = UInt8(truncatingIfNeeded: index / 997) }
        }
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        return try await BigFileStore.prepare(copying: source, fileName: "Clip.mov", mimeType: "application/octet-stream")
    }
}

/// Whether Bighelp is in the background, as a test says.
private final class AppPlace: @unchecked Sendable {
    private let lock = NSLock()
    private var away = false
    var isAway: Bool {
        get { lock.withLock { away } }
        set { lock.withLock { away = newValue } }
    }
}

/// A piece session that only counts what it was given.
private final class CountingSender: BigFileChunkSending, @unchecked Sendable {
    private let lock = NSLock()
    private var sent = 0
    var count: Int { lock.withLock { sent } }

    func send(_ request: URLRequest, fromFile file: URL,
              onSent: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { sent += 1 }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// How many times the uploader waited before trying again; its sleep runs off the main actor.
private final class WaitCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

/// The plugin's `uploads/*` as it behaves: fixed pieces in any order (4 MiB, or the size `start`
/// asked for), a piece recorded only once all of it arrived and matched its checksum, the same file
/// started again gets its pieces back, and `finish` checks the whole file. `proxyLimit` is a proxy
/// in front of it that answers a bigger request with a plain 413, as aiohttp and nginx do;
/// `gatewayErrors` are pieces that proxy answers once with a 502 and an error code of its own.
@MainActor
private final class FakeUploadHost: BigFileUploadHost, BigFileChunkSending, @unchecked Sendable {
    var chunkBytes = 4 * 1_024 * 1_024
    var features: Set<String> = [BigFileUploads.feature]
    var proxyLimit: Int?
    var startPieceSizes: [Int?] = []
    var discardedUploads: [String] = []
    var operations: [WorkspaceOperation] = []
    var pieceRequests: [URLRequest] = []
    var pieceOffsets: [Int] = []
    var dropPieces: Set<Int> = []
    var gatewayErrors: Set<Int> = []
    var preloaded: Set<Int> = []
    var preloadSource: URL?
    var staleOnce = false
    var unreadableOnce = false
    var offline = false
    var dropsNextCall = false
    var startRefusal: String?
    var contextReloads = 0
    private var uploadID = String(repeating: "9", count: 32)
    private var byteCount = 0
    private var sha = ""
    private var received: Set<Int> = []
    private var finishedUploads: Set<String> = []
    private var bytes = Data()
    var stored: Data { bytes }

    func supportsBigFiles() async -> Bool { features.contains(BigFileUploads.feature) }

    func supportsSmallPieces() async -> Bool { features.contains(BigFileUploads.smallPiecesFeature) }

    func perform(_ operation: WorkspaceOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        operations.append(operation)
        if offline { throw WorkspaceClientError.transportUnavailable }
        if dropsNextCall {
            dropsNextCall = false
            throw WorkspaceClientError.transportUnavailable
        }
        switch operation {
        case .uploadsStart:
            if let startRefusal { throw WorkspaceClientError.rejected(code: startRefusal) }
            byteCount = payload["byteCount"]?.integer ?? 0
            sha = payload["sha256"]?.string ?? ""
            let requested = payload["chunkBytes"]?.integer
            startPieceSizes.append(requested)
            if let requested, requested != chunkBytes {
                // Another piece size is another upload.
                chunkBytes = requested
                uploadID = String(repeating: "8", count: 32)
                received = []
                bytes = Data()
            }
            if finishedUploads.contains(uploadID) {
                // The plugin's `start` never gives a finished upload back: the file begins again.
                uploadID = String(repeating: "7", count: 32)
                received = []
                bytes = Data()
            }
            if bytes.isEmpty { bytes = Data(count: byteCount) }
            if let preloadSource, received.isEmpty {
                // Pieces an earlier run sent before the app was closed.
                let source = try Data(contentsOf: preloadSource)
                for index in preloaded {
                    let range = (index * chunkBytes)..<min((index + 1) * chunkBytes, byteCount)
                    bytes.replaceSubrange(range, with: source[range])
                    received.insert(index)
                }
            }
            return answer()
        case .uploadsStatus: return answer()
        case .uploadsFinish:
            let finishedPath = BighelpJSONValue.string("/srv/agent/uploads/2026-10-31/Clip.mov")
            if let asked = payload["uploadId"]?.string, finishedUploads.contains(asked) {
                // Asked again, a finished upload answers with the same file.
                return answer().merging(["uploadId": .string(asked), "finished": .boolean(true),
                                         "inWorkspace": .boolean(true), "path": finishedPath]) { $1 }
            }
            guard received.count == (byteCount + chunkBytes - 1) / chunkBytes else {
                throw WorkspaceClientError.rejected(code: "upload_incomplete")
            }
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == sha else {
                received = []
                throw WorkspaceClientError.rejected(code: "upload_corrupt")
            }
            finishedUploads.insert(uploadID)
            return answer().merging(["finished": .boolean(true), "inWorkspace": .boolean(true),
                                     "path": finishedPath]) { $1 }
        case .uploadsDiscard:
            let discarded = payload["uploadId"]?.string ?? ""
            finishedUploads.remove(discarded)
            if discarded == uploadID {
                // The upload is gone from the host: the same file is a new upload.
                uploadID = String(repeating: "6", count: 32)
                received = []
                bytes = Data()
            }
            discardedUploads.append(discarded)
            return ["discarded": .boolean(true)]
        default: throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
    }

    func chunkRequest(_ chunk: DirectHermesBigFileChunk) async throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://hermes.example.invalid" + DirectHermesBigFileChunk.route)!)
        request.setValue(String(chunk.offset), forHTTPHeaderField: "X-Loopdy-Upload-Offset")
        request.setValue(chunk.sha256, forHTTPHeaderField: "X-Loopdy-Chunk-SHA256")
        return request
    }

    func reloadContext() async throws { contextReloads += 1 }

    nonisolated func send(_ request: URLRequest, fromFile file: URL,
                          onSent: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        let body = try Data(contentsOf: file)
        return try await MainActor.run { try self.accept(request, body: body, onSent: onSent) }
    }

    private func accept(_ request: URLRequest, body: Data,
                        onSent: @Sendable (Int64) -> Void) throws -> (Data, HTTPURLResponse) {
        pieceRequests.append(request)
        let offset = Int(request.value(forHTTPHeaderField: "X-Loopdy-Upload-Offset") ?? "") ?? -1
        pieceOffsets.append(offset)
        if let proxyLimit, body.count > proxyLimit {
            return (Data("Maximum request body size \(proxyLimit) exceeded.".utf8),
                    HTTPURLResponse(url: URL(string: "https://hermes.example.invalid")!, statusCode: 413,
                                    httpVersion: nil, headerFields: ["Content-Type": "text/plain"])!)
        }
        if staleOnce {
            staleOnce = false
            return reply(412, ["error": .object(["code": .string("context_changed")])])
        }
        if unreadableOnce {
            unreadableOnce = false
            throw DirectHermesError.invalidResponse
        }
        let index = offset / chunkBytes
        if dropPieces.remove(index) != nil {
            onSent(Int64(body.count / 2))
            throw URLError(.networkConnectionLost)
        }
        if gatewayErrors.remove(index) != nil {
            return reply(502, ["error": .object(["code": .string("proxy_upstream_error")])])
        }
        let checksum = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        guard offset % chunkBytes == 0, body.count == min(chunkBytes, byteCount - offset),
              checksum == request.value(forHTTPHeaderField: "X-Loopdy-Chunk-SHA256") else {
            return reply(422, ["error": .object(["code": .string("upload_length_invalid")])])
        }
        bytes.replaceSubrange(offset..<(offset + body.count), with: body)
        onSent(Int64(body.count))
        received.insert(index)
        return reply(200, answer())
    }

    private func answer() -> [String: BighelpJSONValue] {
        return [
            "uploadId": .string(uploadID), "byteCount": .integer(byteCount), "chunkBytes": .integer(chunkBytes),
            "receivedChunks": .array(received.sorted().map { .integer($0) }), "finished": .boolean(false),
        ]
    }

    private func reply(_ status: Int, _ value: [String: BighelpJSONValue]) -> (Data, HTTPURLResponse) {
        let data = (try? JSONEncoder().encode(BighelpJSONValue.object(value))) ?? Data()
        return (data, HTTPURLResponse(url: URL(string: "https://hermes.example.invalid")!, statusCode: status,
                                      httpVersion: nil, headerFields: nil)!)
    }
}
