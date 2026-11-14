import CryptoKit
import Foundation

// MARK: - Raw configuration

struct HermesRawConfigurationSnapshot: Equatable, Sendable {
    let yaml: String
    let path: String
    let profileID: String
    let loadedAt: Date
    let digest: Data
}

struct HermesRawConfigurationReview: Equatable, Sendable {
    let original: HermesRawConfigurationSnapshot
    let proposedYAML: String
    let proposedDigest: Data
    let reviewedAt: Date
    fileprivate let owner: WorkspaceOwner
}

struct HermesRawConfigurationCommit: Equatable, Sendable {
    let acknowledged: Bool
    let readback: HermesRawConfigurationSnapshot
    let serverPreservedExactText: Bool
}

private struct HermesHostOperationProfilePath: Hashable {
    let name: String
    let path: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        Data(lhs.name.utf8) == Data(rhs.name.utf8)
            && Data(lhs.path.utf8) == Data(rhs.path.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(Data(name.utf8))
        hasher.combine(Data(path.utf8))
    }
}

extension DirectHermesHostOperationsClient {
    /// Resolves the profile home used by unscoped `/api/ops/*` routes without
    /// substituting the selected profile. `/api/profiles` supplies exact profile
    /// homes; unscoped `/api/config/raw` supplies the serving process's config
    /// path. Its bounded response is type checked and its YAML is immediately
    /// discarded without inspection or publication.
    func servingProfileID(consistentWith suppliedProfileID: String?) async throws -> String {
        try requireOwner()
        let supplied = try suppliedProfileID.map(DirectHermesHostPayload.profile)
        let before = try await operationProfilePaths()
        let configPath = try await servingConfigurationPath()
        let after = try await operationProfilePaths()
        guard before == after else { throw HostOperationsError.reviewChanged }

        let matches = before.filter {
            DirectHermesHostPayload.isConfigPath(configPath, insideProfileHome: $0.path)
        }
        guard matches.count == 1, let resolved = matches.first else {
            throw HostOperationsError.unavailable("a uniquely verified serving profile for unscoped computer operations")
        }
        if let supplied,
           !Data(supplied.utf8).elementsEqual(Data(resolved.name.utf8)) {
            throw HostOperationsError.reviewChanged
        }
        try requireOwner()
        return resolved.name
    }

    private func servingConfigurationPath() async throws -> String {
        let raw = try DirectHermesHostPayload.object(try await json(
            .init(
                path: "/api/config/raw", method: .get,
                maximumResponseBytes: 2 * 1_024 * 1_024
            ),
            feature: "serving-profile discovery"
        ))
        // Do not retain, inspect, log, or return private configuration content.
        // The overall authenticated response is bounded; only its documented type
        // is checked before the value falls out of scope.
        guard raw["yaml"]?.string != nil else { throw HostOperationsError.invalidResponse }
        return try DirectHermesHostPayload.hostFilesystemPath(raw["path"])
    }

    private func operationProfilePaths() async throws -> Set<HermesHostOperationProfilePath> {
        let value = try await json(
            .init(path: "/api/profiles", method: .get, maximumResponseBytes: 256 * 1_024),
            feature: "serving-profile discovery"
        )
        let object = try DirectHermesHostPayload.object(value)
        let rows = try DirectHermesHostPayload.array(object["profiles"], maximum: 256)
        var names = Set<Data>()
        var profiles = Set<HermesHostOperationProfilePath>()
        profiles.reserveCapacity(rows.count)
        for value in rows {
            let row = try DirectHermesHostPayload.object(value)
            let name = try DirectHermesHostPayload.profile(try DirectHermesHostPayload.text(row["name"], maximumBytes: 128))
            let path = try DirectHermesHostPayload.hostFilesystemPath(row["path"])
            guard names.insert(Data(name.utf8)).inserted,
                  profiles.insert(.init(name: name, path: path)).inserted else {
                throw HostOperationsError.invalidResponse
            }
        }
        guard !profiles.isEmpty else { throw HostOperationsError.invalidResponse }
        return profiles
    }

    // MARK: Raw configuration

    func rawConfiguration(profileID: String) async throws -> HermesRawConfigurationSnapshot {
        let profile = try DirectHermesHostPayload.profile(profileID)
        let object = try DirectHermesHostPayload.object(try await json(
            .init(
                path: "/api/config/raw", method: .get,
                query: [.init(name: "profile", value: profile)],
                maximumResponseBytes: 2 * 1_024 * 1_024
            ),
            feature: "raw configuration"
        ))
        let yaml = try DirectHermesHostPayload.text(object["yaml"], maximumBytes: Self.maximumRawConfigurationBytes)
        let path = try DirectHermesHostPayload.text(object["path"], maximumBytes: 4_096)
        return .init(
            yaml: yaml, path: path, profileID: profile, loadedAt: Date(),
            digest: Data(SHA256.hash(data: Data(yaml.utf8)))
        )
    }

    func reviewRawConfiguration(
        original: HermesRawConfigurationSnapshot,
        proposedYAML: String
    ) throws -> HermesRawConfigurationReview {
        try requireOwner()
        guard original.profileID == (try DirectHermesHostPayload.profile(original.profileID)),
              !proposedYAML.isEmpty,
              proposedYAML.utf8.count <= Self.maximumRawConfigurationBytes,
              !proposedYAML.unicodeScalars.contains(where: { $0.value == 0 }) else {
            if proposedYAML.utf8.count > Self.maximumRawConfigurationBytes {
                throw HostOperationsError.privateDocumentTooLarge
            }
            throw HostOperationsError.invalidRequest
        }
        let digest = Data(SHA256.hash(data: Data(proposedYAML.utf8)))
        guard digest != original.digest || Data(proposedYAML.utf8) != Data(original.yaml.utf8) else {
            throw HostOperationsError.noChanges
        }
        return .init(
            original: original, proposedYAML: proposedYAML,
            proposedDigest: digest, reviewedAt: Date(), owner: owner
        )
    }

    func saveRawConfiguration(reviewed review: HermesRawConfigurationReview) async throws
        -> HermesRawConfigurationCommit {
        try requireOwner()
        guard review.owner == owner,
              review.proposedYAML.utf8.count <= Self.maximumRawConfigurationBytes,
              review.proposedDigest == Data(SHA256.hash(data: Data(review.proposedYAML.utf8))) else {
            throw HostOperationsError.reviewChanged
        }
        let current = try await rawConfiguration(profileID: review.original.profileID)
        guard current.path.utf8.elementsEqual(review.original.path.utf8),
              Data(current.yaml.utf8) == Data(review.original.yaml.utf8),
              current.digest == review.original.digest else {
            throw HostOperationsError.reviewChanged
        }
        let response = try DirectHermesHostPayload.object(try await json(
            .init(
                path: "/api/config/raw", method: .put,
                query: [.init(name: "profile", value: review.original.profileID)],
                body: ["yaml_text": .string(review.proposedYAML)],
                maximumResponseBytes: 64 * 1_024
            ),
            feature: "raw configuration save", mutation: true
        ))
        guard response["ok"]?.boolean == true else { throw HostOperationsError.outcomeUnknown }
        let readback: HermesRawConfigurationSnapshot
        do {
            readback = try await rawConfiguration(profileID: review.original.profileID)
        } catch {
            try requireOwner()
            throw HostOperationsError.outcomeUnknown
        }
        guard readback.path.utf8.elementsEqual(review.original.path.utf8) else {
            throw HostOperationsError.outcomeUnknown
        }
        return .init(
            acknowledged: true, readback: readback,
            serverPreservedExactText: Data(readback.yaml.utf8) == Data(review.proposedYAML.utf8)
        )
    }
}
