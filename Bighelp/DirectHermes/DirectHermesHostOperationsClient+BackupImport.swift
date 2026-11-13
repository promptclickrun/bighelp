import CryptoKit
import Foundation

// MARK: - Backup import

struct HermesHostImportReview: Equatable, Sendable, Identifiable {
    enum Source: Equatable, Sendable {
        case hostPath(String)
        case uploadedFile(name: String, byteCount: Int)
    }

    let id: UUID
    let hostName: String
    let selectedProfileID: String
    let targetProfileID: String
    let source: Source
    let reviewedAt: Date
    fileprivate let owner: WorkspaceOwner
    fileprivate let uploadedBytes: Data?
    fileprivate let uploadDigest: Data?
}

/// Fixed multipart seam for `POST /api/ops/import-upload`. Implementations own
/// authentication and must not accept a caller-supplied route, method, header,
/// or form field name. The existing JSON request primitive cannot encode this.
@MainActor
protocol DirectHermesHostImportUploadHTTP: AnyObject {
    func uploadHermesBackupForImport(
        filename: String,
        bytes: Data,
        force: Bool,
        maximumResponseBytes: Int
    ) async throws -> BighelpJSONValue
}

extension DirectHermesHostOperationsClient {
    func downloadBackup(_ receipt: HermesHostActionReceipt) async throws -> HermesBackupDownload {
        guard receipt.action == .backup, let archive = receipt.archivePath,
              !archive.isEmpty, archive.utf8.count <= 4_096,
              !archive.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HostOperationsError.invalidRequest
        }
        guard let raw = http as? any DirectHermesNativeHTTP else {
            throw HostOperationsError.downloadUnavailable
        }
        try requireOwner()
        let response: DirectHermesHTTP.Response
        do {
            response = try await raw.nativeResponse(
                .init(
                    path: "/api/ops/backup/download", method: .get,
                    query: [.init(name: "archive", value: archive)],
                    maximumResponseBytes: DirectHermesWire.maximumMessageBytes
                ),
                requestGuard: nil
            )
        } catch DirectHermesError.messageTooLarge {
            throw HostOperationsError.downloadTooLarge
        }
        try requireOwner()
        guard response.http.statusCode == 200,
              DirectHermesHostPayload.hasZIPSignature(response.body) else {
            throw HostOperationsError.invalidResponse
        }
        let mediaType = response.http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard mediaType.contains("application/zip") || mediaType.contains("application/octet-stream") else {
            throw HostOperationsError.invalidResponse
        }
        let fallback = URL(fileURLWithPath: archive).lastPathComponent
        let filename = try DirectHermesHostPayload.downloadFilename(fallback)
        return .init(filename: filename, bytes: response.body)
    }

    // MARK: Full backup import

    func reviewHostImport(
        path: String,
        hostName: String,
        selectedProfileID: String,
        targetProfileID: String
    ) throws -> HermesHostImportReview {
        try requireOwner()
        let selectedProfile = try DirectHermesHostPayload.profile(selectedProfileID)
        let targetProfile = try DirectHermesHostPayload.profile(targetProfileID)
        let source = try DirectHermesHostPayload.hostArchivePath(path)
        return .init(
            id: UUID(), hostName: hostName,
            selectedProfileID: selectedProfile, targetProfileID: targetProfile,
            source: .hostPath(source), reviewedAt: Date(), owner: owner,
            uploadedBytes: nil, uploadDigest: nil
        )
    }

    func reviewUploadedImport(
        filename: String,
        bytes: Data,
        hostName: String,
        selectedProfileID: String,
        targetProfileID: String
    ) throws -> HermesHostImportReview {
        try requireOwner()
        guard !bytes.isEmpty, bytes.count <= Self.maximumImportUploadBytes else {
            throw HostOperationsError.importTooLarge
        }
        guard DirectHermesHostPayload.hasZIPSignature(bytes) else { throw HostOperationsError.invalidRequest }
        let name = try DirectHermesHostPayload.uploadFilename(filename)
        return .init(
            id: UUID(), hostName: hostName,
            selectedProfileID: try DirectHermesHostPayload.profile(selectedProfileID),
            targetProfileID: try DirectHermesHostPayload.profile(targetProfileID),
            source: .uploadedFile(name: name, byteCount: bytes.count), reviewedAt: Date(),
            owner: owner, uploadedBytes: bytes,
            uploadDigest: Data(SHA256.hash(data: bytes))
        )
    }

    func launchReviewedImport(_ review: HermesHostImportReview) async throws -> HermesHostActionReceipt {
        try requireOwner()
        guard review.owner == owner else { throw HostOperationsError.ownerChanged }
        _ = try DirectHermesHostPayload.profile(review.selectedProfileID)
        _ = try DirectHermesHostPayload.profile(review.targetProfileID)
        switch review.source {
        case .hostPath(let path):
            let checked = try DirectHermesHostPayload.hostArchivePath(path)
            return try await launch(
                .init(
                    path: "/api/ops/import", method: .post,
                    body: ["archive": .string(checked), "force": .boolean(true)]
                ),
                expectedAction: .importArchive,
                feature: "computer backup import"
            )
        case .uploadedFile(let name, let byteCount):
            guard let bytes = review.uploadedBytes, bytes.count == byteCount,
                  review.uploadDigest == Data(SHA256.hash(data: bytes)) else {
                throw HostOperationsError.reviewChanged
            }
            guard let upload = http as? any DirectHermesHostImportUploadHTTP else {
                throw HostOperationsError.importUploadUnavailable
            }
            let value: BighelpJSONValue
            do {
                value = try await upload.uploadHermesBackupForImport(
                    filename: try DirectHermesHostPayload.uploadFilename(name), bytes: bytes, force: true,
                    maximumResponseBytes: 64 * 1_024
                )
                try requireOwner()
            } catch WorkspaceClientError.outcomeUnknown {
                // Cancellation remains uncertain once the fixed transport marked
                // dispatch. Revalidate identity without letting cancellation
                // incorrectly turn that into a safe-to-retry pre-dispatch result.
                try requireOwnerIdentity()
                throw HostOperationsError.outcomeUnknown
            } catch {
                try requireOwner()
                throw error
            }
            let object = try DirectHermesHostPayload.object(value)
            guard try DirectHermesHostPayload.integer(object["uploaded_bytes"], range: 0...Self.maximumImportUploadBytes) == bytes.count else {
                throw HostOperationsError.outcomeUnknown
            }
            return try launchReceipt(object, expectedAction: .importArchive)
        }
    }
}
