import Foundation

/// The host side a big file goes to: the plugin's JSON routes, and a signed-in
/// request for each piece.
@MainActor
protocol BigFileUploadHost: AnyObject {
    /// Whether this computer's plugin takes big files (`native-uploads-v1`); reads its context if needed.
    func supportsBigFiles() async -> Bool
    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue]) async throws
        -> [String: BighelpJSONValue]
    func chunkRequest(_ chunk: DirectHermesBigFileChunk) async throws -> URLRequest
    /// After a piece came back `412` (the plugin's context changed): read it again.
    func reloadContext() async throws
}

struct BigFileUploadError: Error, Equatable, LocalizedError {
    let failure: BigFileUploadFailure
    var errorDescription: String? { failure.message }
}

/// A file the host holds whole and checked, ready for Hermes' `file.attach`.
struct BigFileStagedUpload: Equatable, Sendable {
    let uploadID: String
    let path: String
    /// In the agent's working folder, so the chat's line for it opens it in the agent's Files.
    let inWorkspace: Bool
}

/// Sends one big file: `start`, every piece the host doesn't have yet (a few at
/// a time, in any order), then `finish`. Whatever drops on the way, the host's
/// own record of its pieces decides what goes again, so nothing is sent twice
/// after a confirmed piece and nothing is guessed.
@MainActor
final class BigFileUploader {
    struct Progress: Equatable, Sendable {
        let sentBytes: Int
        let byteCount: Int
    }

    private let host: any BigFileUploadHost
    private let sender: any BigFileChunkSending
    private let parallelPieces: Int
    private let retryDelays: [Duration]
    private let sleep: @Sendable (Duration) async throws -> Void

    init(host: any BigFileUploadHost, sender: any BigFileChunkSending = BighelpBackgroundUploads.shared,
         parallelPieces: Int = 3,
         retryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(10), .seconds(30), .seconds(60)],
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.host = host
        self.sender = sender
        self.parallelPieces = max(1, parallelPieces)
        self.retryDelays = retryDelays
        self.sleep = sleep
    }

    func upload(_ file: ChatBigFile, agentID: String,
                onProgress: @escaping @MainActor (Progress) -> Void = { _ in }) async throws -> BigFileStagedUpload {
        guard await host.supportsBigFiles() else { throw BigFileUploadError(failure: .pluginRequired) }
        guard (1...BigFileUploads.maximumBytes).contains(file.byteCount) else {
            throw BigFileUploadError(failure: .other)
        }
        var waits = retryDelays[...]
        var restartedDamaged = false
        var receipt = try await retrying(&waits) { try await self.start(file, agentID: agentID) }
        let sent = SentBytes(onProgress: onProgress, byteCount: file.byteCount)
        sent.confirm(receipt)
        while true {
            try Task.checkCancellation()
            let missing = receipt.plan.missing(receipt.received)
            if missing.isEmpty {
                do {
                    let value = try await host.perform(.uploadsFinish, payload: ["uploadId": .string(receipt.uploadID)])
                    let finished = try BigFileUploadReceipt.finishedFile(value, uploadID: receipt.uploadID)
                    BigFileStore.remove(pieceFolderOf: file)
                    return BigFileStagedUpload(uploadID: receipt.uploadID, path: finished.path,
                                               inWorkspace: finished.inWorkspace)
                } catch let error where Self.code(of: error) == "upload_corrupt" && !restartedDamaged {
                    // The host forgot its pieces; send them all once more.
                    restartedDamaged = true
                } catch let error where Self.code(of: error) == "upload_incomplete" {
                } catch {
                    let failure = BigFileUploadFailure(error)
                    guard failure.retriesQuietly, let wait = waits.popFirst() else { throw Self.error(error) }
                    try await sleep(wait)
                }
                receipt = try await retrying(&waits) { try await self.status(receipt, file: file, agentID: agentID) }
                sent.confirm(receipt)
                continue
            }
            let before = receipt.received
            let round = await sendPieces(missing, of: file, receipt: receipt, sent: sent)
            receipt = round.receipt
            if let failure = round.failure, !failure.retriesQuietly {
                throw BigFileUploadError(failure: failure)
            }
            if receipt.received.isSuperset(of: before), receipt.received.count > before.count {
                waits = retryDelays[...]
                continue
            }
            // Nothing new arrived: wait, then ask the host what it has.
            guard let wait = waits.popFirst() else {
                throw BigFileUploadError(failure: round.failure ?? .connection)
            }
            try await sleep(wait)
            receipt = try await retrying(&waits) { try await self.status(receipt, file: file, agentID: agentID) }
            sent.confirm(receipt)
        }
    }

    /// Removes the host's staged copy once Hermes has its own (or the message is dropped).
    func discard(_ uploadID: String) async {
        _ = try? await host.perform(.uploadsDiscard, payload: ["uploadId": .string(uploadID)])
    }

    // Steps

    private func start(_ file: ChatBigFile, agentID: String) async throws -> BigFileUploadReceipt {
        let value = try await host.perform(.uploadsStart, payload: [
            "agentId": .string(agentID), "fileName": .string(file.fileName), "mimeType": .string(file.mimeType),
            "byteCount": .integer(file.byteCount), "sha256": .string(file.sha256),
        ])
        return try BigFileUploadReceipt(value, expectedByteCount: file.byteCount)
    }

    private func status(_ receipt: BigFileUploadReceipt, file: ChatBigFile,
                        agentID: String) async throws -> BigFileUploadReceipt {
        do {
            let value = try await host.perform(.uploadsStatus, payload: ["uploadId": .string(receipt.uploadID)])
            return try BigFileUploadReceipt(value, expectedByteCount: file.byteCount, expectedUploadID: receipt.uploadID)
        } catch let error where Self.code(of: error) == "upload_not_found" {
            // A day went by, or the host was cleaned up: begin again.
            return try await start(file, agentID: agentID)
        }
    }

    private struct Round {
        var receipt: BigFileUploadReceipt
        var failure: BigFileUploadFailure?
    }

    private enum PieceResult: Sendable {
        case received(Int, BigFileUploadReceipt)
        case failed(Int, BigFileUploadFailure, staleContext: Bool)
    }

    private func sendPieces(_ indices: [Int], of file: ChatBigFile, receipt: BigFileUploadReceipt,
                            sent: SentBytes) async -> Round {
        var round = Round(receipt: receipt)
        var queue = indices[...]
        var staleContext = false
        let uploadID = receipt.uploadID
        let plan = receipt.plan
        // A few pieces at a time. Plain tasks, not a task group: each piece's work stays on the
        // main actor between its file read and its network wait.
        while !queue.isEmpty, !Task.isCancelled {
            let batch = queue.prefix(parallelPieces)
            queue = queue.dropFirst(batch.count)
            let tasks = batch.map { index in
                let progress = sent.reporter(for: index)
                return Task { await self.sendPiece(index, of: file, uploadID: uploadID, plan: plan, onSent: progress) }
            }
            let results = await withTaskCancellationHandler {
                var results: [PieceResult] = []
                for task in tasks { results.append(await task.value) }
                return results
            } onCancel: {
                for task in tasks { task.cancel() }
            }
            var stop = false
            for result in results {
                switch result {
                case .received(let index, let answer):
                    // Answers can arrive in any order; keep every piece any of them confirmed.
                    let known = round.receipt.received.union(answer.received).union([index])
                    round.receipt = (try? round.receipt.with(received: known)) ?? round.receipt
                    sent.confirm(round.receipt)
                    BigFileStore.removePiece(of: file, index: index)
                case .failed(let index, let failure, let stale):
                    sent.drop(index)
                    staleContext = staleContext || stale
                    round.failure = round.failure.map { $0.retriesQuietly ? failure : $0 } ?? failure
                    if !failure.retriesQuietly { stop = true }
                }
            }
            if stop { break }
        }
        if staleContext { try? await host.reloadContext() }
        return round
    }

    private func sendPiece(_ index: Int, of file: ChatBigFile, uploadID: String, plan: BigFileUploadPlan,
                           onSent: @escaping @Sendable (Int64) -> Void) async -> PieceResult {
        do {
            let range = plan.range(of: index)
            let (pieceFile, checksum) = try await BigFileStore.piece(of: file, index: index, range: range)
            let chunk = try DirectHermesBigFileChunk(uploadID: uploadID, offset: range.lowerBound,
                                                     length: range.count, sha256: checksum)
            let request = try await host.chunkRequest(chunk)
            let (body, response) = try await sender.send(request, fromFile: pieceFile, onSent: onSent)
            let value = (try? JSONDecoder().decode(BighelpJSONValue.self, from: body))?.object
            guard (200...299).contains(response.statusCode) else {
                if response.statusCode == 412 || response.statusCode == 428 {
                    return .failed(index, .connection, staleContext: true)
                }
                if response.statusCode == 401 || response.statusCode == 403 {
                    return .failed(index, .connection, staleContext: false)
                }
                let code = value?["error"]?.object?["code"]?.string ?? ""
                if code == "upload_finished" { return .failed(index, .connection, staleContext: false) }
                return .failed(index, code.isEmpty && response.statusCode >= 500 ? .connection
                               : BigFileUploadFailure(code: code), staleContext: false)
            }
            guard let value else { return .failed(index, .connection, staleContext: false) }
            let answer = try BigFileUploadReceipt(value, expectedByteCount: file.byteCount, expectedUploadID: uploadID)
            return .received(index, answer)
        } catch is CancellationError {
            return .failed(index, .connection, staleContext: false)
        } catch {
            return .failed(index, BigFileUploadFailure(error), staleContext: false)
        }
    }

    private func retrying<T>(_ waits: inout ArraySlice<Duration>,
                             _ step: () async throws -> T) async throws -> T {
        while true {
            do { return try await step() } catch {
                let failure = BigFileUploadFailure(error)
                guard failure.retriesQuietly, failure != .expired, let wait = waits.popFirst() else {
                    throw Self.error(error)
                }
                try await sleep(wait)
            }
        }
    }

    private static func code(of error: any Error) -> String? {
        guard case WorkspaceClientError.rejected(let code, _) = error else { return nil }
        return code
    }

    private static func error(_ error: any Error) -> any Error {
        if error is CancellationError || error is BigFileUploadError { return error }
        return BigFileUploadError(failure: BigFileUploadFailure(error))
    }
}

/// Bytes the host confirmed, plus what is on its way, for the progress the message shows.
@MainActor
private final class SentBytes {
    private let onProgress: @MainActor (BigFileUploader.Progress) -> Void
    private let byteCount: Int
    private var confirmed = 0
    private var inFlight: [Int: Int] = [:]
    private var reported = -1

    init(onProgress: @escaping @MainActor (BigFileUploader.Progress) -> Void, byteCount: Int) {
        self.onProgress = onProgress
        self.byteCount = byteCount
    }

    func confirm(_ receipt: BigFileUploadReceipt) {
        confirmed = receipt.plan.receivedBytes(receipt.received)
        for index in receipt.received { inFlight[index] = nil }
        report()
    }

    func drop(_ index: Int) {
        inFlight[index] = nil
        report()
    }

    nonisolated func reporter(for index: Int) -> @Sendable (Int64) -> Void {
        { [weak self] sent in
            Task { @MainActor in
                self?.inFlight[index] = Int(sent)
                self?.report()
            }
        }
    }

    private func report() {
        let total = min(byteCount, confirmed + inFlight.values.reduce(0, +))
        // A step of 256 KB is finer than the message can show.
        guard total == byteCount || abs(total - reported) >= 256 * 1_024 else { return }
        reported = total
        onProgress(.init(sentBytes: total, byteCount: byteCount))
    }
}

extension BigFileUploadReceipt {
    func with(received: Set<Int>) throws -> BigFileUploadReceipt {
        try BigFileUploadReceipt([
            "uploadId": .string(uploadID), "byteCount": .integer(byteCount), "chunkBytes": .integer(plan.chunkBytes),
            "receivedChunks": .array(received.sorted().map { .integer($0) }), "finished": .boolean(finished),
        ], expectedByteCount: byteCount, expectedUploadID: uploadID)
    }
}

extension BigFileStore {
    static func remove(pieceFolderOf file: ChatBigFile) {
        try? FileManager.default.removeItem(at: pieces.appending(path: file.id, directoryHint: .isDirectory))
    }
}
