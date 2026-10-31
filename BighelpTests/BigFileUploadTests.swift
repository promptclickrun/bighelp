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
        #expect(try BigFileUploadReceipt.finishedFile(answer(workspace, true), uploadID: id) == (workspace, true))
        let staged = "/home/hermes/.hermes/plugin-data/loopdy/uploads/\(id)/file/Trip.mov"
        #expect(try BigFileUploadReceipt.finishedFile(answer(staged, false), uploadID: id) == (staged, false))
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

/// How many times the uploader waited before trying again; its sleep runs off the main actor.
private final class WaitCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

/// The plugin's `uploads/*` as it behaves: fixed 4 MiB pieces in any order, a piece
/// recorded only once all of it arrived and matched its checksum, the same file started
/// again gets its pieces back, and `finish` checks the whole file.
@MainActor
private final class FakeUploadHost: BigFileUploadHost, BigFileChunkSending, @unchecked Sendable {
    let chunkBytes = 4 * 1_024 * 1_024
    var features: Set<String> = [BigFileUploads.feature]
    var operations: [WorkspaceOperation] = []
    var pieceRequests: [URLRequest] = []
    var pieceOffsets: [Int] = []
    var dropPieces: Set<Int> = []
    var preloaded: Set<Int> = []
    var preloadSource: URL?
    var staleOnce = false
    var offline = false
    var startRefusal: String?
    var contextReloads = 0
    private var uploadID = String(repeating: "9", count: 32)
    private var byteCount = 0
    private var sha = ""
    private var received: Set<Int> = []
    private var bytes = Data()
    var stored: Data { bytes }

    func supportsBigFiles() async -> Bool { features.contains(BigFileUploads.feature) }

    func perform(_ operation: WorkspaceOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        operations.append(operation)
        if offline { throw WorkspaceClientError.transportUnavailable }
        switch operation {
        case .uploadsStart:
            if let startRefusal { throw WorkspaceClientError.rejected(code: startRefusal) }
            byteCount = payload["byteCount"]?.integer ?? 0
            sha = payload["sha256"]?.string ?? ""
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
            guard received.count == (byteCount + chunkBytes - 1) / chunkBytes else {
                throw WorkspaceClientError.rejected(code: "upload_incomplete")
            }
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == sha else {
                received = []
                throw WorkspaceClientError.rejected(code: "upload_corrupt")
            }
            return answer().merging(["finished": .boolean(true), "inWorkspace": .boolean(true),
                                     "path": .string("/srv/agent/uploads/2026-10-31/Clip.mov")]) { $1 }
        case .uploadsDiscard: return ["discarded": .boolean(true)]
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
        if staleOnce {
            staleOnce = false
            return reply(412, ["error": .object(["code": .string("context_changed")])])
        }
        let index = offset / chunkBytes
        if dropPieces.remove(index) != nil {
            onSent(Int64(body.count / 2))
            throw URLError(.networkConnectionLost)
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
