import SwiftUI

/// One of a bot's core files: what Hermes reads at the start of each chat about who the bot is, what it
/// knows about you, its own notes and its project's rules.
struct CoreFile: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case soul, user, memory, agents

        var fileName: String {
            switch self {
            case .soul: "SOUL.md"
            case .user: "USER.md"
            case .memory: "MEMORY.md"
            case .agents: "AGENTS.md"
            }
        }

        var symbol: String {
            switch self {
            case .soul: "sparkles"
            case .user: "person.crop.circle"
            case .memory: "brain.head.profile"
            case .agents: "list.bullet.rectangle"
            }
        }

        init?(fileName: String) {
            guard let kind = Self.allCases.first(where: { $0.fileName == fileName }) else { return nil }
            self = kind
        }
    }

    let kind: Kind
    let exists: Bool
    /// The active project AGENTS.md belongs to.
    var project: String?
    var id: String { kind.rawValue }

    /// "Who Lantern is", "Rules for the Garden project".
    func detail(botName: String) -> String {
        switch kind {
        case .soul: String(localized: "Who \(botName) is")
        case .user: String(localized: "What \(botName) remembers about you")
        case .memory: String(localized: "\(botName)'s own notes")
        case .agents: project.map { String(localized: "Rules for the \($0) project") } ?? String(localized: "Project rules")
        }
    }
}

/// A bot's core files on its computer: the list, and the editor's reads and saves by file name.
@MainActor
protocol CoreFilesSource: HostTextFileAccess {
    func list() async throws -> [CoreFile]
}

/// The plugin's `core-files/*` routes (`native-core-files-v1`) for one bot. A save sends the hash of the
/// text last read, so the computer refuses it when the file changed since (`409 file_changed`).
@MainActor
final class DirectHermesCoreFilesClient: CoreFilesSource {
    static let feature = "native-core-files-v1"

    private let agentID: String
    private let currentWorkspace: @MainActor () -> (any WorkspaceOperationPerforming)?
    /// The hash of each file as last read; nil for a file that wasn't there.
    private var readHashes: [CoreFile.Kind: String?] = [:]

    init(agentID: String, currentWorkspace: @escaping @MainActor () -> (any WorkspaceOperationPerforming)?) {
        self.agentID = agentID
        self.currentWorkspace = currentWorkspace
    }

    func list() async throws -> [CoreFile] {
        let response = try await perform(.coreFilesList, [:])
        return Self.files(from: response)
    }

    func read(_ path: String) async throws -> HostTextFile {
        guard let kind = CoreFile.Kind(fileName: path) else { throw WorkspaceClientError.invalidRequest }
        let response = try await perform(.coreFilesRead, ["kind": .string(kind.rawValue)])
        guard let text = response["text"]?.string else { throw WorkspaceClientError.invalidResponse }
        readHashes[kind] = .some(response["sha256"]?.string)
        return HostTextFile(path: kind.fileName, text: text, isTruncated: response["truncated"]?.boolean == true,
                            isBinary: false)
    }

    func write(_ path: String, text: String) async throws {
        guard let kind = CoreFile.Kind(fileName: path), let base = readHashes[kind] else {
            throw WorkspaceClientError.invalidRequest
        }
        var payload: [String: BighelpJSONValue] = ["kind": .string(kind.rawValue), "text": .string(text)]
        payload["expectedSha256"] = base.map(BighelpJSONValue.string) ?? .null
        let response = try await perform(.coreFilesWrite, payload)
        readHashes[kind] = .some(response["sha256"]?.string)
    }

    private func perform(_ operation: WorkspaceOperation,
                         _ payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        guard let workspace = currentWorkspace(), let owner = workspace.owner else {
            throw WorkspaceClientError.unavailable(.notConnected)
        }
        var payload = payload
        payload["profile"] = .string(agentID)
        do {
            return try await workspace.perform(operation, payload: payload, owner: owner)
        } catch WorkspaceClientError.conflict where operation != .coreFilesWrite {
            // The plugin's context changed (412): the next call loads it again. Once.
            return try await workspace.perform(operation, payload: payload, owner: owner)
        }
    }

    /// Leniently: an unknown kind is left out, so a newer plugin's extra file never breaks the page.
    nonisolated static func files(from response: [String: BighelpJSONValue]) -> [CoreFile] {
        (response["files"]?.array ?? []).compactMap { value in
            guard let row = value.object, let kind = row["kind"]?.string.flatMap(CoreFile.Kind.init(rawValue:)) else {
                return nil
            }
            return CoreFile(kind: kind, exists: row["exists"]?.boolean == true,
                            project: row["project"]?.string.flatMap { $0.isEmpty ? nil : $0 })
        }
    }
}

#if DEBUG
/// Demo runs: a bot's core files, kept in memory for the run.
@MainActor
final class DemoCoreFiles: CoreFilesSource {
    private var files: [CoreFile.Kind: String] = [
        .soul: "# Who you are\n\nYou are a calm, friendly helper. Keep answers short, and ask before you do anything that costs money.\n",
        .user: "Likes short answers.\u{a7}Waters the garden on Sundays.\u{a7}Prefers metric units.",
        .agents: "# Garden project\n\n- Keep the planting plan in plan.md.\n- Ask before you order seeds.\n",
    ]

    func list() async throws -> [CoreFile] {
        [CoreFile(kind: .soul, exists: true), CoreFile(kind: .user, exists: true),
         CoreFile(kind: .memory, exists: files[.memory] != nil), CoreFile(kind: .agents, exists: true, project: "Garden")]
    }

    func read(_ path: String) async throws -> HostTextFile {
        guard let kind = CoreFile.Kind(fileName: path) else { throw WorkspaceClientError.invalidRequest }
        return HostTextFile(path: path, text: files[kind] ?? "", isTruncated: false, isBinary: false)
    }

    func write(_ path: String, text: String) async throws {
        guard let kind = CoreFile.Kind(fileName: path) else { throw WorkspaceClientError.invalidRequest }
        files[kind] = text
    }
}
#endif

/// The Core Files sheet's source and whose files they are.
struct CoreFilesPresentation: Identifiable {
    let id = UUID()
    let source: any CoreFilesSource
    let botName: String
}

/// A bot's Core Files (its profile › Core Files): SOUL.md, USER.md, MEMORY.md and, when its active project has
/// one, AGENTS.md. A file opens in the Markdown viewer, whose Edit saves it whole and never over a file that
/// changed on the computer.
@MainActor
struct CoreFilesView: View {
    let source: any CoreFilesSource
    let botName: String

    @State private var files: [CoreFile]?
    @State private var problem: String?
    @State private var opened: CoreFile?
    @BighelpThemeReader private var theme

    var body: some View {
        Form {
            if let files {
                Section {
                    ForEach(files) { file in
                        Button { opened = file } label: { row(file) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("core-files.\(file.kind.rawValue)")
                    }
                } footer: {
                    Text("\(botName) reads these when a chat starts, so a change reaches the next chat.")
                }
                .listRowBackground(theme.surface)
            } else if let problem {
                Section {
                    Text(problem)
                        .foregroundStyle(theme.secondaryText)
                    Button(String(localized: "Try again")) { Task { await load() } }
                }
                .listRowBackground(theme.surface)
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
                    .listRowBackground(theme.surface)
            }
        }
        .bighelpFormSurface()
        .navigationTitle(String(localized: "Core Files"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .bighelpSheet(item: $opened, onDismiss: { Task { await load() } }) { file in
            MarkdownFileSheet(path: file.kind.fileName, access: source)
                .bighelpSheetSize(.large)
        }
        .accessibilityIdentifier("core-files.screen")
    }

    private func row(_ file: CoreFile) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            HermesToolIcon(art: .symbol(file.kind.symbol, key: "core-files.\(file.kind.rawValue)"), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.kind.fileName)
                    .font(.bighelp(.body, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Text(file.exists ? file.detail(botName: botName) : String(localized: "Empty. Tap to write it."))
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: BighelpTokens.space8)
            Image(systemName: "chevron.right")
                .font(.bighelp(.footnote).weight(.semibold))
                .foregroundStyle(theme.tertiaryText)
                .accessibilityHidden(true)
        }
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(.rect)
    }

    private func load() async {
        do {
            files = try await source.list()
            problem = nil
        } catch is CancellationError {
        } catch WorkspaceClientError.unavailable(.unsupportedOperation) {
            problem = String(localized: "Update the bighelp plugin on your computer to see these files.")
        } catch {
            problem = String(localized: "The files didn't load. Check your connection, then try again.")
        }
    }
}
