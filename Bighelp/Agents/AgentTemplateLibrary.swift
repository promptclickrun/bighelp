import Foundation
import Observation
import SwiftUI

/// An agent's setup saved to reuse later: its role, description, instructions
/// and look. New agents made from it still start from the host's usual setup
/// (skills, memory and settings copied from the default agent).
struct SavedAgentTemplate: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var role: String
    var summary: String
    var instructions: String
    var avatar: AgentAvatar?
    let sourceAgentName: String
    let createdAt: Date
}

/// Saved on this device, so a template works with any of the person's computers.
@MainActor @Observable
final class AgentTemplateLibrary {
    static let shared = AgentTemplateLibrary()

    private(set) var templates: [SavedAgentTemplate] = []
    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        load()
    }

    static var defaultFileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return folder.appendingPathComponent("agent-templates.json")
    }

    @discardableResult
    func save(from agent: AgentProfile, now: Date = .now) -> SavedAgentTemplate {
        let template = SavedAgentTemplate(
            id: UUID(), title: uniqueTitle(agent.name), role: agent.role, summary: agent.summary,
            instructions: agent.instructions, avatar: agent.avatar, sourceAgentName: agent.name, createdAt: now
        )
        templates.insert(template, at: 0)
        persist()
        return template
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = templates.firstIndex(where: { $0.id == id }) else { return }
        templates[index].title = String(trimmed.prefix(80))
        persist()
    }

    func delete(_ id: UUID) {
        templates.removeAll { $0.id == id }
        persist()
    }

    private func uniqueTitle(_ name: String) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Bot" : name
        let taken = Set(templates.map(\.title))
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SavedAgentTemplate].self, from: data) else { return }
        templates = decoded
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(templates).write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // A failed write keeps the in-memory list; the next change retries.
        }
    }
}
