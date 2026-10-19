import Foundation
import Observation
import UIKit

/// My Templates: bots the person saved as templates, kept on their computer by the bighelp plugin
/// (`native-my-templates-v1`; bighelp-plugin docs/MY_TEMPLATES.md) in the Template Catalog's agent
/// shape, so they open in the same picker. Read leniently: a template that doesn't read is skipped
/// and counted, never the whole list.
enum MyTemplatesWire {
    static let feature = "native-my-templates-v1"
    /// The plugin's limits, counted as it counts them (Unicode scalars).
    static let maximumNameLength = 40
    static let maximumRoleLength = 160
    static let maximumVibeLength = 160
    static let maximumDescriptionLength = 400
    static let maximumInstructions = 20_000
    /// More than the plugin keeps (40), so a newer plugin that keeps more still lists.
    static let maximumTemplates = 200
    /// Keeps their IDs apart from the catalog's.
    static let idPrefix = "mine-"

    struct Page {
        let templates: [AgentSoulTemplate]
        /// Saved templates the computer or the app couldn't read.
        let skipped: Int
    }

    /// A `list` reply. Only a reply without a list is an error.
    static func page(_ json: [String: BighelpJSONValue]) throws -> Page {
        guard let rows = json["templates"]?.array else { throw WorkspaceClientError.invalidResponse }
        var skipped = json["skipped"]?.number.map { Int(max(0, min($0, 10_000))) } ?? 0
        var seen = Set<String>()
        var templates: [AgentSoulTemplate] = []
        for row in rows.prefix(maximumTemplates) {
            if let template = template(row), seen.insert(template.id).inserted {
                templates.append(template)
            } else {
                skipped += 1
            }
        }
        skipped += max(0, rows.count - maximumTemplates)
        return Page(templates: templates, skipped: skipped)
    }

    /// One saved template, or nil when it lacks its ID, name or instructions.
    static func template(_ value: BighelpJSONValue) -> AgentSoulTemplate? {
        guard let row = value.object else { return nil }
        func text(_ key: String, max: Int) -> String? {
            guard let value = row[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value.count <= max else { return nil }
            return value
        }
        guard let id = row["id"]?.string, isTemplateID(id),
              let name = text("name", max: 80),
              let instructions = row["instructions"]?.string,
              !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              instructions.count <= 64_000 else { return nil }
        let symbol = text("symbol", max: 80).flatMap { UIImage(systemName: $0) == nil ? nil : $0 }
        return AgentSoulTemplate(
            id: idPrefix + id, title: name, profile: text("role", max: 400) ?? "", voice: text("vibe", max: 400) ?? "",
            strength: text("description", max: 400) ?? "", systemImage: symbol ?? "person.crop.square",
            inlineSoul: instructions, updatedAt: TemplateCatalogDate.parse(row["updatedAt"]?.string),
            variables: TemplateVariables.parse(foundation(row["variables"])), savedTemplateID: id
        )
    }

    /// What a `save` sends: the bot's role, vibe and instructions with its own name turned into
    /// `{{agent_name}}`. Never its picture, model or settings.
    static func savePayload(name: String, from profile: AgentProfile) throws -> [String: BighelpJSONValue] {
        let title = line(name, limit: maximumNameLength)
        guard !title.isEmpty, !title.contains("{{"), !title.contains("}}") else { throw MyTemplatesSaveError.needsName }
        let instructions = AgentNamePlaceholder.generalize(profile.instructions, name: profile.name)
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MyTemplatesSaveError.noInstructions
        }
        guard instructions.unicodeScalars.count <= maximumInstructions else { throw MyTemplatesSaveError.tooLong }
        var template: [String: BighelpJSONValue] = [
            "name": .string(title), "instructions": .string(instructions),
            "role": .string(line(profile.role, limit: maximumRoleLength)),
        ]
        let vibe = line(profile.summary, limit: maximumVibeLength)
        if !vibe.isEmpty { template["vibe"] = .string(vibe) }
        let botName = line(profile.name, limit: 80)
        if !botName.isEmpty { template["description"] = .string(line("Saved from \(botName)", limit: maximumDescriptionLength)) }
        return ["template": .object(template)]
    }

    static func isTemplateID(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                    options: .regularExpression) != nil
    }

    /// One line of plain words, cut to the plugin's limit.
    private static func line(_ text: String, limit: Int) -> String {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(String.UnicodeScalarView(words.unicodeScalars.prefix(limit)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The catalog's variable parser reads Foundation values.
    private static func foundation(_ value: BighelpJSONValue?) -> Any? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }
}

/// Why a template wasn't saved, in plain words.
enum MyTemplatesSaveError: Error, Equatable {
    case needsName, noInstructions, tooLong, holdsSecret, full, needsPluginUpdate, noConnection, failed

    init(_ error: any Error) {
        switch error as? WorkspaceClientError {
        case .unavailable(.unsupportedOperation)?, .unavailable(.pluginRequired)?: self = .needsPluginUpdate
        case .rejected(let code, _)? where code == "secret_scan_blocked": self = .holdsSecret
        case .rejected(let code, _)? where code == "store_full": self = .full
        case .rejected(let code, _)? where code == "template_too_large": self = .tooLong
        case .capacityExceeded?: self = .tooLong
        default: self = (error as? MyTemplatesSaveError) ?? .failed
        }
    }

    var message: String {
        switch self {
        case .needsName: "Give the template a name."
        case .noInstructions: "This bot has no instructions to save yet."
        case .tooLong: "This bot's instructions are too long for a template."
        case .holdsSecret: "Templates can't hold keys or passwords. Take them out of this bot's instructions, then try again."
        case .full: "Your computer keeps up to 40 templates. Delete one in Templates, then try again."
        case .needsPluginUpdate: "Update the bighelp plugin to save templates."
        case .noConnection: "Connect to your computer to save templates."
        case .failed: "The template wasn't saved. Check your computer, then try again."
        }
    }
}

enum MyTemplatesOperation: Sendable {
    case list, save, delete

    var workspaceOperation: WorkspaceOperation {
        switch self {
        case .list: .myTemplatesList
        case .save: .myTemplatesSave
        case .delete: .myTemplatesDelete
        }
    }
}

@MainActor
protocol MyTemplatesClient: AnyObject {
    func perform(_ operation: MyTemplatesOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue]
}

/// The plugin's `my-templates` routes on the computer in use.
@MainActor
final class DirectHermesMyTemplatesClient: MyTemplatesClient {
    private let workspace: @MainActor () -> (any WorkspaceOperationPerforming)?

    init(workspace: @escaping @MainActor () -> (any WorkspaceOperationPerforming)?) {
        self.workspace = workspace
    }

    func perform(_ operation: MyTemplatesOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        guard let workspace = workspace(), let owner = workspace.owner else {
            throw WorkspaceClientError.transportUnavailable
        }
        do {
            return try await workspace.perform(operation.workspaceOperation, payload: payload, owner: owner)
        } catch WorkspaceClientError.conflict {
            // The plugin's context changed (412): the next call loads it again. Once.
            return try await workspace.perform(operation.workspaceOperation, payload: payload, owner: owner)
        }
    }
}

/// Demo mode's computer: one saved template with fill-in fields, and one broken file it skips.
@MainActor
final class DemoMyTemplatesClient: MyTemplatesClient {
    static let shared = DemoMyTemplatesClient()

    private var rows: [BighelpJSONValue] = [.object([
        "id": .string("3d2b7c1e-5a4f-4b6d-9e8c-1f2a3b4c5d6e"), "name": .string("Weekend Planner"),
        "role": .string("Plans easy weekends"), "vibe": .string("Cheerful, organized"),
        "description": .string("Saved from Sunny"), "source": .string("mine"),
        "instructions": .string("# {{agent_name}}\n\nYou are {{agent_name}}, a weekend planner. Suggest two or three "
                                + "easy plans near {{home_town}}, with times and a rainy-day backup. Keep it short."),
        "variables": .array([.object(["key": .string("home_town"), "label": .string("Home town"),
                                      "type": .string("text"), "example": .string("Porto")])]),
        "updatedAt": .string("2026-10-12T09:30:00Z"),
    ])]

    func perform(_ operation: MyTemplatesOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        switch operation {
        case .list:
            // A file the computer could read but the app can't: it's skipped, the rest still show.
            return ["templates": .array(rows + [.object(["id": .string("not-an-id"), "name": .string("Broken")])]),
                    "skipped": .integer(0)]
        case .save:
            guard var template = payload["template"]?.object,
                  let name = template["name"]?.string, !name.isEmpty,
                  let instructions = template["instructions"]?.string, !instructions.isEmpty else {
                throw WorkspaceClientError.rejected(code: "invalid_template")
            }
            template["id"] = .string(UUID().uuidString.lowercased())
            template["source"] = .string("mine")
            template["updatedAt"] = .string(ISO8601DateFormatter().string(from: .now))
            rows.insert(.object(template), at: 0)
            return ["template": .object(template)]
        case .delete:
            let id = payload["id"]?.string
            let before = rows.count
            rows.removeAll { $0.object?["id"]?.string == id }
            return ["id": payload["id"] ?? .null, "deleted": .boolean(rows.count < before)]
        }
    }
}

/// The computer in use: its cache scope (`WorkspaceOwner.cacheScopeID`) and its client.
typealias MyTemplatesConnection = (scope: String, client: any MyTemplatesClient)

/// The person's saved templates on the computer in use, for every template picker.
@MainActor
@Observable
final class MyTemplatesStore {
    /// Set up by the app with the computer in use (`BighelpApp`).
    static let shared = MyTemplatesStore()

    enum Load: Equatable { case idle, loading, loaded, needsPluginUpdate, unavailable }

    private(set) var load: Load = .idle
    private(set) var templates: [AgentSoulTemplate] = []
    private(set) var skipped = 0

    @ObservationIgnored var connection: @MainActor () -> MyTemplatesConnection?
    @ObservationIgnored private var scope: String?
    @ObservationIgnored private var refreshing: Task<Void, Never>?

    init(connection: @escaping @MainActor () -> MyTemplatesConnection? = { nil }) {
        self.connection = connection
    }

    /// One refresh at a time; callers during it wait for that one.
    func refresh() async {
        if let refreshing {
            await refreshing.value
            return
        }
        let task = Task { await reload() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func reload() async {
        // No connection is the gap of a reconnect, not another computer: what's here stays.
        guard let connection = connection() else {
            if templates.isEmpty { load = .unavailable }
            return
        }
        adopt(connection.scope)
        if templates.isEmpty, load != .needsPluginUpdate { load = .loading }
        do {
            let page = try MyTemplatesWire.page(try await connection.client.perform(.list, payload: [:]))
            guard scope == connection.scope else { return }
            templates = page.templates
            skipped = page.skipped
            load = .loaded
        } catch WorkspaceClientError.unavailable(.unsupportedOperation),
                WorkspaceClientError.unavailable(.pluginRequired) {
            guard scope == connection.scope else { return }
            templates = []
            skipped = 0
            load = .needsPluginUpdate
        } catch {
            // A failed check keeps the list it has.
            guard scope == connection.scope, load != .loaded else { return }
            load = .unavailable
        }
    }

    /// Saves the bot as a template on the computer; it shows first in every picker.
    @discardableResult
    func save(name: String, from profile: AgentProfile) async throws -> AgentSoulTemplate {
        let payload = try MyTemplatesWire.savePayload(name: name, from: profile)
        guard let connection = connection() else { throw MyTemplatesSaveError.noConnection }
        adopt(connection.scope)
        let reply: [String: BighelpJSONValue]
        do {
            reply = try await connection.client.perform(.save, payload: payload)
        } catch {
            let failure = MyTemplatesSaveError(error)
            if failure == .needsPluginUpdate, scope == connection.scope {
                templates = []
                load = .needsPluginUpdate
            }
            throw failure
        }
        guard let value = reply["template"], let template = MyTemplatesWire.template(value) else {
            throw MyTemplatesSaveError.failed
        }
        if scope == connection.scope {
            templates.removeAll { $0.id == template.id }
            templates.insert(template, at: 0)
            load = .loaded
        }
        return template
    }

    /// Deletes it on the computer; it leaves the list once the computer says so.
    @discardableResult
    func delete(_ template: AgentSoulTemplate) async -> Bool {
        guard let id = template.savedTemplateID, let connection = connection() else { return false }
        do {
            _ = try await connection.client.perform(.delete, payload: ["id": .string(id)])
        } catch {
            return false
        }
        if scope == connection.scope { templates.removeAll { $0.id == template.id } }
        return true
    }

    private func adopt(_ next: String) {
        guard scope != next else { return }
        scope = next
        templates = []
        skipped = 0
        load = .idle
    }
}
