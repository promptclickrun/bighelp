import SwiftUI
import UniformTypeIdentifiers

enum ChatActionMenuAction: String, CaseIterable, Identifiable, Sendable {
    case camera
    case photo
    case file
    case scanDocument
    case voice
    case startSession
    case chooseAgent
    case skillsAndTools
    case changeModel

    var id: Self { self }

    var accessibilityIdentifier: String {
        switch self {
        case .camera: "chat.action.camera"
        case .photo: "chat.action.photo"
        case .file: "chat.action.file"
        case .scanDocument: "chat.action.scan-document"
        case .voice: "chat.action.voice"
        case .startSession: "chat.action.start-session"
        case .chooseAgent: "chat.action.choose-agent"
        case .skillsAndTools: "chat.action.skills-tools"
        case .changeModel: "chat.action.change-model"
        }
    }

    var submenu: ChatActionMenuPage? {
        switch self {
        case .chooseAgent: .agents
        case .skillsAndTools: .skillsAndTools
        case .changeModel: .modelAndReasoning
        case .camera, .photo, .file, .scanDocument, .voice, .startSession: nil
        }
    }
}

enum ChatActionMenuPage: Equatable, Sendable {
    case main
    case agents
    case skillsAndTools
    case modelAndReasoning
}

enum ChatActionMenuLayout {
    static let mediaActions: [ChatActionMenuAction] = [
        .camera,
        .photo,
        .file,
    ]
    static let mediaColumnCount = 3
    static let rowActions: [ChatActionMenuAction] = [
        .scanDocument,
        .voice,
        .startSession,
        .chooseAgent,
        .skillsAndTools,
        .changeModel,
    ]
    static let rootSurfaceRole: BighelpSurfaceRole = .sheet
    static let usesColoredOutline = false

    static func surfacePresentation(
        isDarkMode: Bool
    ) -> BighelpPickerSheetSurfacePresentation {
        .resolve(isDarkMode: isDarkMode)
    }
}

enum ChatActionMenuAvailability {
    static func isEnabled(
        _ action: ChatActionMenuAction,
        hasRuntimeControls: Bool,
        isTurnActive: Bool
    ) -> Bool {
        guard action == .changeModel else { return true }
        return hasRuntimeControls
            && !ChatRuntimeSelectionLockout.isLocked(isTurnActive: isTurnActive)
    }
}

enum ChatPDFPagesAttachmentAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)

    var unavailableReason: String? {
        switch self {
        case .available: nil
        case .unavailable(let reason): reason
        }
    }
}

struct ChatActionMenuAgentSelectionState: Equatable {
    let page: ChatActionMenuPage
    let errorMessage: String?
}

enum ChatActionMenuAgentSelectionTransition {
    static func resolve(_ result: DirectChatAgentSelectionResult) -> ChatActionMenuAgentSelectionState {
        switch result {
        case .reassigned, .unchanged:
            ChatActionMenuAgentSelectionState(page: .main, errorMessage: nil)
        case .blockedByHistory:
            ChatActionMenuAgentSelectionState(
                page: .agents,
                errorMessage: "This chat already has messages. Start a new chat to use a different agent."
            )
        case .unavailable:
            ChatActionMenuAgentSelectionState(
                page: .agents,
                errorMessage: "This chat’s agent could not be changed. Try again."
            )
        }
    }
}

enum ChatSkillsAndPluginsKind: Equatable {
    case skill
    case plugin

    var slashCommandSource: SlashCommandSource {
        switch self {
        case .skill: .skill
        case .plugin: .plugin
        }
    }
}

struct ChatSkillsAndPluginsEntry: Identifiable, Equatable {
    let id: String
    let kind: ChatSkillsAndPluginsKind
    let name: String
    let detail: String
    let metadata: String
    let isEnabled: Bool
}

struct ChatSkillsAndPluginsIndex {
    let catalog: HermesSkillsAndToolsCatalog

    func entries(query: String) -> [ChatSkillsAndPluginsEntry] {
        let entries = catalog.skills.map { skill in
            ChatSkillsAndPluginsEntry(
                id: skill.id,
                kind: .skill,
                name: skill.name,
                detail: skill.description,
                metadata: skill.category,
                isEnabled: skill.isEnabled
            )
        } + catalog.plugins.map { plugin in
            ChatSkillsAndPluginsEntry(
                id: plugin.id,
                kind: .plugin,
                name: plugin.name,
                detail: plugin.description,
                metadata: plugin.version.isEmpty ? plugin.kind : "\(plugin.kind) · \(plugin.version)",
                isEnabled: plugin.isEnabled
            )
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            entry.id.localizedCaseInsensitiveContains(query)
                || entry.name.localizedCaseInsensitiveContains(query)
                || entry.detail.localizedCaseInsensitiveContains(query)
                || entry.metadata.localizedCaseInsensitiveContains(query)
        }
    }
}

enum ChatCapabilitySlashCommandResolver {
    static func command(
        for entry: ChatSkillsAndPluginsEntry,
        commands: [SlashCommandDescriptor]
    ) -> SlashCommandDescriptor? {
        let identities = Set([entry.id, entry.name].map(normalizedIdentity))
        let matches = commands.filter { command in
            guard command.source == entry.kind.slashCommandSource else { return false }
            let commandIdentities = [command.name] + command.aliases
            return commandIdentities.contains { identities.contains(normalizedIdentity($0)) }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func normalizedIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum ChatReferenceDocumentBuilder {
    static func markdown(for record: SessionRecord) throws -> String {
        var result = "# \(record.title)\n\nReferenced bighelp session: `\(record.id)`\n"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        for item in record.items {
            var section = "\n## \(item.sender.snapshot.name)\n\n"
            switch item.content {
            case .message(let text):
                section += text
            default:
                section += "```json\n"
                section += String(data: try encoder.encode(item.content), encoding: .utf8) ?? "{}"
                section += "\n```"
            }
            if !item.attachments.isEmpty {
                section += "\n\nAttachments: "
                section += item.attachments.map(\.fileName).joined(separator: ", ")
            }
            section += "\n"

            guard result.utf8.count + section.utf8.count < 7_500_000 else {
                result += "\n_This reference was shortened to fit the attachment limit._\n"
                break
            }
            result += section
        }
        return result
    }

    static func fileName(for record: SessionRecord) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let slug = record.title.lowercased().unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
        let compact = slug.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "session-reference-\(String((compact.isEmpty ? record.id : compact).prefix(120))).md"
    }
}
