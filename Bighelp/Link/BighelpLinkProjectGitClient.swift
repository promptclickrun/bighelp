import Foundation

enum ProjectGitOperation: String, CaseIterable, Codable, Equatable, Sendable {
    case stage, commit, fetch, pull, push
}

enum ProjectGitCapabilityOperation: String, CaseIterable, Codable, Equatable, Sendable {
    case status, stage, commit, fetch, pull, push
}

enum ProjectGitStageMode: String, Codable, Equatable, Sendable { case stage, unstage }
enum ProjectGitDiffSide: String, Codable, Equatable, Sendable { case staged, worktree }
enum ProjectGitFileKind: String, Codable, Equatable, Sendable { case ordinary, renamed, unmerged, untracked }
enum ProjectGitDiffAvailability: String, Codable, Equatable, Sendable { case available, binary, oversized }
enum ProjectGitDiffLineKind: String, Codable, Equatable, Sendable {
    case header, hunk, context, addition, deletion
    case noNewline = "no_newline"
}

struct ProjectGitChangeCounts: Codable, Equatable, Sendable {
    let files: Int
    let insertions: Int
    let deletions: Int
}

struct ProjectGitCapabilityFlags: Codable, Equatable, Sendable {
    let status: Bool
    let stage: Bool
    let commit: Bool
    let push: Bool
    let fetch: Bool
    let pull: Bool
    let arbitraryCommand: Bool
}

struct ProjectGitWorkspaceCapabilities: Identifiable, Codable, Equatable, Sendable {
    var id: String { workspaceID }
    let workspaceID: String
    let label: String
    let visibility: String
    let operations: [ProjectGitCapabilityOperation]
    let remotes: [String]
    let branches: [String]
    let mutationsEnabled: Bool
}

struct ProjectGitCapabilities: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let capabilities: ProjectGitCapabilityFlags
    let workspaces: [ProjectGitWorkspaceCapabilities]
}

struct ProjectGitHead: Codable, Equatable, Sendable {
    let oid: String?
    let branch: String?
    let isDetached: Bool
    let upstream: String?
    let ahead: Int
    let behind: Int
}

struct ProjectGitFileChange: Identifiable, Codable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let originalPath: String?
    let indexStatus: String
    let worktreeStatus: String
    let kind: ProjectGitFileKind
    let insertions: Int
    let deletions: Int
    let isBinary: Bool

    var availableDiffSides: [ProjectGitDiffSide] {
        if kind == .untracked {
            return [.worktree]
        }
        var sides: [ProjectGitDiffSide] = []
        if indexStatus != ".", indexStatus != "?" {
            sides.append(.staged)
        }
        if worktreeStatus != "." {
            sides.append(.worktree)
        }
        return sides.isEmpty ? [.worktree] : sides
    }
}

struct ProjectGitPageMetadata: Codable, Equatable, Sendable {
    let offset: Int
    let limit: Int
    let returned: Int
    let total: Int
    let nextOffset: Int?
    let isComplete: Bool
}

struct ProjectGitStatus: Codable, Equatable, Sendable {
    let workspaceID: String
    let statusToken: String
    let head: ProjectGitHead
    let files: [ProjectGitFileChange]
    let filesPage: ProjectGitPageMetadata
    let staged: ProjectGitChangeCounts
    let changes: ProjectGitChangeCounts
    let conflicts: [String]
    let conflictsPage: ProjectGitPageMetadata
    let isDirty: Bool
}

struct ProjectGitDiffLine: Identifiable, Codable, Equatable, Sendable {
    var id: String { String(offset) }
    let offset: Int
    let kind: ProjectGitDiffLineKind
    let oldLine: Int?
    let newLine: Int?
    let content: String
}

struct ProjectGitDiffPage: Codable, Equatable, Sendable {
    let path: String
    let side: ProjectGitDiffSide
    let availability: ProjectGitDiffAvailability
    let offset: Int
    let lines: [ProjectGitDiffLine]
    let nextOffset: Int?
    let previewContent: String?

    init(
        path: String,
        side: ProjectGitDiffSide,
        availability: ProjectGitDiffAvailability,
        offset: Int,
        lines: [ProjectGitDiffLine],
        nextOffset: Int?,
        previewContent: String? = nil
    ) {
        self.path = path
        self.side = side
        self.availability = availability
        self.offset = offset
        self.lines = lines
        self.nextOffset = nextOffset
        self.previewContent = previewContent
    }
}

enum ProjectGitMutation: Codable, Equatable, Sendable {
    case stage(mode: ProjectGitStageMode, paths: [String])
    case commit(message: String)
    case fetch(remote: String)
    case pull(remote: String, branch: String)
    case push(remote: String, branch: String)

    var operation: ProjectGitOperation {
        switch self {
        case .stage: .stage
        case .commit: .commit
        case .fetch: .fetch
        case .pull: .pull
        case .push: .push
        }
    }
}

struct ProjectGitMutationRequest: Codable, Equatable, Sendable {
    let agentID: String
    let sessionID: String
    let workspaceID: String
    let statusToken: String
    let mutation: ProjectGitMutation
}

struct ProjectGitExecutionRequest: Codable, Equatable, Sendable {
    let mutation: ProjectGitMutationRequest
    let confirmationToken: String
    let idempotencyKey: String
}

struct ProjectGitOperationPreview: Codable, Equatable, Sendable {
    let summary: String
    let paths: [String]
    let remote: String?
    let branch: String?
    let commits: Int?
}

struct ProjectGitPreparedOperation: Codable, Equatable, Sendable {
    let operation: ProjectGitOperation
    let confirmationToken: String
    let operationDigest: String
    let expiresAt: Date
    let preview: ProjectGitOperationPreview
}

struct ProjectGitChangedRef: Codable, Equatable, Sendable {
    let ref: String
    let before: String?
    let after: String?
}

enum ProjectGitOperationResult: Codable, Equatable, Sendable {
    case stage(mode: ProjectGitStageMode, paths: [String])
    case commit(commitOID: String, parentOID: String, treeOID: String, subject: String)
    case fetch(remote: String, updatedRefs: [ProjectGitChangedRef])
    case pull(remote: String, branch: String, commitOID: String)
    case push(remote: String, branch: String, commitOID: String)
}

struct ProjectGitExecutionResult: Codable, Equatable, Sendable {
    let operationID: String
    let workspaceID: String
    let operation: ProjectGitOperation
    let result: ProjectGitOperationResult
    let status: ProjectGitStatus
}

@MainActor
protocol ProjectGitClient: AnyObject {
    func capabilities(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitCapabilities
    func status(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitStatus
    func diff(agentID: String, sessionID: String, workspaceID: String, path: String, side: ProjectGitDiffSide, statusToken: String, offset: Int, limit: Int) async throws -> ProjectGitDiffPage
    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation
    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult
}

@MainActor
final class FixtureProjectGitClient: ProjectGitClient {
    private let usesMarkdownPreview: Bool
    private let isNonRepository: Bool

    init(usesMarkdownPreview: Bool = false, isNonRepository: Bool = false) {
        self.usesMarkdownPreview = usesMarkdownPreview
        self.isNonRepository = isNonRepository
    }

    func capabilities(
        agentID _: String,
        sessionID _: String,
        workspaceID: String
    ) async throws -> ProjectGitCapabilities {
        if isNonRepository {
            throw BighelpLinkWorkspaceClientError.remote(
                status: .failed,
                code: "project_not_repository",
                message: "This project is not a Git repository."
            )
        }
        return ProjectGitCapabilities(
            schemaVersion: 1,
            capabilities: ProjectGitCapabilityFlags(
                status: true,
                stage: false,
                commit: false,
                push: false,
                fetch: false,
                pull: false,
                arbitraryCommand: false
            ),
            workspaces: [ProjectGitWorkspaceCapabilities(
                workspaceID: workspaceID,
                label: workspaceID == "loopdy" ? "bighelp" : "Workspace",
                visibility: "private",
                operations: [.status],
                remotes: ["origin"],
                branches: ["main"],
                mutationsEnabled: false
            )]
        )
    }

    func status(
        agentID _: String,
        sessionID _: String,
        workspaceID: String
    ) async throws -> ProjectGitStatus {
        let files: [ProjectGitFileChange] = if usesMarkdownPreview {
            [
                ProjectGitFileChange(
                    path: "README.md", originalPath: nil, indexStatus: "?", worktreeStatus: "?",
                    kind: .untracked, insertions: 40, deletions: 0, isBinary: false
                ),
                ProjectGitFileChange(
                    path: "notes.txt", originalPath: nil, indexStatus: "?", worktreeStatus: "?",
                    kind: .untracked, insertions: 1, deletions: 0, isBinary: false
                ),
            ]
        } else {
            [ProjectGitFileChange(
                path: "Bighelp/App/RootShellView.swift", originalPath: nil,
                indexStatus: ".", worktreeStatus: "M", kind: .ordinary,
                insertions: 12, deletions: 4, isBinary: false
            )]
        }
        let page = ProjectGitPageMetadata(
            offset: 0,
            limit: 200,
            returned: files.count,
            total: files.count,
            nextOffset: nil,
            isComplete: true
        )
        return ProjectGitStatus(
            workspaceID: workspaceID,
            statusToken: "fixture-status-\(workspaceID)",
            head: ProjectGitHead(
                oid: "0123456789abcdef",
                branch: "main",
                isDetached: false,
                upstream: "origin/main",
                ahead: 0,
                behind: 0
            ),
            files: files,
            filesPage: page,
            staged: ProjectGitChangeCounts(files: 0, insertions: 0, deletions: 0),
            changes: ProjectGitChangeCounts(
                files: files.count,
                insertions: usesMarkdownPreview ? 41 : 12,
                deletions: usesMarkdownPreview ? 0 : 4
            ),
            conflicts: [],
            conflictsPage: ProjectGitPageMetadata(
                offset: 0,
                limit: 200,
                returned: 0,
                total: 0,
                nextOffset: nil,
                isComplete: true
            ),
            isDirty: true
        )
    }

    func diff(
        agentID _: String,
        sessionID _: String,
        workspaceID _: String,
        path: String,
        side: ProjectGitDiffSide,
        statusToken _: String,
        offset: Int,
        limit _: Int
    ) async throws -> ProjectGitDiffPage {
        let markdownLines: [ProjectGitDiffLine] = [
            .init(offset: offset, kind: .addition, oldLine: nil, newLine: 1, content: "# Fixture Markdown Preview"),
            .init(offset: offset + 1, kind: .addition, oldLine: nil, newLine: 2, content: ""),
            .init(offset: offset + 2, kind: .addition, oldLine: nil, newLine: 3, content: "Rendered **Markdown** stays readable."),
            .init(offset: offset + 3, kind: .addition, oldLine: nil, newLine: 4, content: ""),
            .init(offset: offset + 4, kind: .addition, oldLine: nil, newLine: 5, content: "`wrapped code stays inside the panel`"),
        ] + (6...40).map { line in
            .init(
                offset: offset + line - 1,
                kind: .addition,
                oldLine: nil,
                newLine: line,
                content: "Fixture section \(line)"
            )
        }
        let lines: [ProjectGitDiffLine] = usesMarkdownPreview
            ? (path == "README.md" ? markdownLines : [ProjectGitDiffLine(
                offset: offset, kind: .addition, oldLine: nil, newLine: 1,
                content: "Plain text diff opens in Diff mode"
            )])
            : [ProjectGitDiffLine(
                offset: offset,
                kind: .addition,
                oldLine: nil,
                newLine: 1,
                content: "Fixture project change"
            )]
        if usesMarkdownPreview {
            let content = path == "README.md"
                ? markdownLines.map(\.content).joined(separator: "\n") + "\nMarkdown final preview marker"
                : "Plain text diff opens in Diff mode\n\n**This stays literal in TXT.**\n"
                    + (1...40).map { "Text fixture line \($0)" }.joined(separator: "\n")
                    + "\nText final preview marker"
            // Exercise the real decoder, including the field emitted by older hosts.
            return try ProjectGitCodec.decodeDiffPage([
                "path": .string(path), "side": .string(side.rawValue),
                "availability": .string("available"), "offset": .integer(offset),
                "lines": .array(lines.map { line in .object([
                    "kind": .string(line.kind.rawValue),
                    "oldLine": line.oldLine.map(BighelpJSONValue.integer) ?? .null,
                    "newLine": line.newLine.map(BighelpJSONValue.integer) ?? .null,
                    "content": .string(line.content),
                ]) }),
                "nextOffset": .null,
                (path == "README.md" ? "preview_content" : "previewContent"): .string(content),
            ])
        }
        return ProjectGitDiffPage(
            path: path,
            side: side,
            availability: .available,
            offset: offset,
            lines: lines,
            nextOffset: nil
        )
    }

    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation {
        throw CancellationError()
    }

    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult {
        throw CancellationError()
    }
}
