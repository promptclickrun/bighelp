import Foundation

struct WorkspaceProject: Identifiable, Equatable, Sendable {
    struct Folder: Identifiable, Equatable, Sendable {
        let path: String
        let label: String?
        let isPrimary: Bool
        var id: String { path }
    }
    let id: String
    let name: String
    let summary: String
    let isArchived: Bool
    let folders: [Folder]
}

struct WorkspaceModelCatalog: Equatable, Sendable {
    struct Provider: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let models: [String]
        let isAuthenticated: Bool?
    }
    let providers: [Provider]
    let currentProvider: String
    let currentModel: String
}

struct WorkspaceInventoryItem: Identifiable, Equatable, Sendable {
    struct Detail: Identifiable, Equatable, Sendable {
        let label: String
        let value: String
        var id: String { label }
    }
    let id: String
    let title: String
    let summary: String
    let status: String?
    let details: [Detail]
}

struct WorkspaceCredentialStatus: Identifiable, Equatable, Sendable {
    let id: String
    let description: String
    let category: String
    let isSet: Bool
    let canReplace: Bool
}

struct WorkspaceWebhook: Identifiable, Equatable, Sendable {
    let id: String
    let description: String
    let events: [String]
    let isEnabled: Bool
    let hasSecret: Bool
}

struct WorkspaceFileListing: Equatable, Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        let path: String
        let name: String
        let isDirectory: Bool
        let size: Int?
        /// True filesystem birth time, absent when the host cannot provide it.
        let createdAt: Date?
        let modifiedAt: Date?
        let mimeType: String?

        init(
            path: String,
            name: String,
            isDirectory: Bool,
            size: Int?,
            modifiedAt: Date? = nil,
            mimeType: String? = nil,
            createdAt: Date? = nil
        ) {
            self.path = path
            self.name = name
            self.isDirectory = isDirectory
            self.size = size
            self.modifiedAt = modifiedAt
            self.mimeType = mimeType
            self.createdAt = createdAt
        }

        // Hermes resolves symlink targets but preserves the listed name. Two
        // aliases of one target are distinct rows with the same open path.
        var id: String { "\(name.utf8.count):\(name)\(path)" }
    }
    let path: String
    let root: String
    let parent: String?
    let entries: [Entry]
    let rootLabel: String?
    let nextPage: WorkspaceFilePageCursor?

    init(path: String, root: String, parent: String?, entries: [Entry], rootLabel: String? = nil, nextPage: WorkspaceFilePageCursor? = nil) {
        self.path = path
        self.root = root
        self.parent = parent
        self.entries = entries
        self.rootLabel = rootLabel
        self.nextPage = nextPage
    }
}

struct WorkspaceFilePageCursor: Equatable, Sendable {
    let revision: String
    let offset: Int
    let limit: Int
    let total: Int
}

struct WorkspaceFileRoot: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
}

struct WorkspaceFilePreview: Equatable, Sendable {
    let path: String
    let name: String
    let text: String
}

enum WorkspaceManagementContent: Equatable, Sendable {
    case projects([WorkspaceProject])
    case models(WorkspaceModelCatalog)
    case inventory([WorkspaceInventoryItem])
    case fileRoots([WorkspaceFileRoot])
    case files(WorkspaceFileListing)
    case logs([String])
    case credentials([WorkspaceCredentialStatus])
    case webhooks([WorkspaceWebhook], platformEnabled: Bool)
}

enum WorkspaceManagementMutation: Identifiable, Equatable, Sendable {
    case archiveProject(id: String, restore: Bool)
    case renameProject(id: String, name: String)
    case replaceCredential(key: String, value: String)
    case setWebhookEnabled(name: String, enabled: Bool)

    var id: String { reviewTitle }

    var destination: WorkspaceDestination {
        switch self {
        case .archiveProject, .renameProject: .projects
        case .replaceCredential: .keys
        case .setWebhookEnabled: .webhooks
        }
    }

    var reviewTitle: String {
        switch self {
        case .archiveProject(_, let restore): restore ? "Restore project?" : "Archive project?"
        case .renameProject: "Rename project?"
        case .replaceCredential: "Replace host credential?"
        case .setWebhookEnabled(_, let enabled): enabled ? "Enable webhook?" : "Disable webhook?"
        }
    }

    var reviewMessage: String {
        switch self {
        case .archiveProject(_, let restore):
            restore ? "Restore this project registration. No files will be changed."
                : "Archive this project registration in Hermes. Files remain on the host, and the project can be restored."
        case .renameProject(_, let name):
            "Change the project display name to \(name). Folder names and files will not change."
        case .replaceCredential(let key, _):
            "Replace \(key) in the selected Hermes profile. The value is sent only to this host and is not stored by this screen. Saving does not verify the provider account."
        case .setWebhookEnabled(_, let enabled):
            enabled ? "Allow this existing webhook to handle incoming events using its current Hermes configuration."
                : "Stop this webhook accepting incoming events. Its configuration remains and it can be enabled again."
        }
    }
}

enum WorkspaceManagementError: Error, Equatable, LocalizedError {
    case invalidResponse
    case invalidInput
    case unavailable(String)
    case fileRootNotConfined
    case filePreviewUnavailable
    case unconfirmedMutation
    case staleOwner

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Hermes returned an incomplete or invalid response. Refresh to check the current state before making changes."
        case .invalidInput:
            "Check the entered value and try again."
        case .unavailable(let reason): reason
        case .fileRootNotConfined:
            "This host has not provided a confined file root. Configure a permitted root on Hermes before browsing files here."
        case .filePreviewUnavailable:
            "This file is not a bounded UTF-8 text document. Open it through its original session attachment."
        case .unconfirmedMutation:
            "Hermes did not confirm the requested change. Refresh to inspect the current state before trying again."
        case .staleOwner:
            "The selected host or profile changed. Reopen this page in the current workspace."
        }
    }
}
