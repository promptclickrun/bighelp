import BuzzKit
import Foundation

/// BuzzKit is the only category-preference store. Device authorization and
/// ActivityKit enablement remain distinct OS/local lifecycle states.
struct BighelpBuzzKitPreference: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let detail: String?
    let category: String?
    let enabled: Bool
    let isDefault: Bool
}

enum BighelpBuzzKitTopic: String, CaseIterable, Sendable {
    case chatRepliesAndCompletions = "chat-replies-completions"
    case scheduledTasksAndDeliveries = "scheduled-tasks-deliveries"
    case questionsAndApprovals = "questions-approvals"
    case subagentCompletions = "subagent-completions"
}

struct BighelpBuzzKitPreferencesClient: Sendable {
    func load() async throws -> [BighelpBuzzKitPreference] {
        try await BuzzKit.preferences.all().compactMap(Self.project)
    }

    /// Migrates only explicit legacy provider choices, once, into the replacement
    /// provider topic. No local preference bit is created and a resolved default
    /// never overwrites an explicit value on the new topic.
    func migrateLegacyPreferences() async throws {
        var topics = try await BuzzKit.preferences.all()
        var changed = false
        defer {
            // The service applies these choices when it sends straight to Apple; tell it about the move.
            if changed { Task { @MainActor in BighelpPushPreferenceChanges.notify() } }
        }
        for migration in Self.legacyMigrations {
            guard let replacement = topics.first(where: { $0.slug == migration.topic.rawValue }),
                  let replacementPush = replacement.channels[.push], replacementPush.isDefault else { continue }
            let legacyChoices = topics.filter { migration.legacySlugs.contains($0.slug) }
                .compactMap { $0.channels[.push] }
                .filter { !$0.isDefault }
            guard !legacyChoices.isEmpty else { continue }
            // A combined category preserves every earlier opt-out.
            let enabled = legacyChoices.allSatisfy(\.isOptedIn)
            topics = try await BuzzKit.preferences.set(
                migration.topic.rawValue,
                channel: .push,
                enabled: enabled
            )
            changed = true
        }
    }

    @discardableResult
    func set(_ topic: BighelpBuzzKitTopic, enabled: Bool) async throws -> [BighelpBuzzKitPreference] {
        let preferences = try await BuzzKit.preferences.set(topic.rawValue, channel: .push, enabled: enabled)
            .compactMap(Self.project)
        if topic == .questionsAndApprovals {
            await MainActor.run { BighelpPromptAlerts.shared.questionsAndApprovalsChanged(enabled: enabled) }
        }
        // The notification service applies these itself when it sends straight to Apple.
        await MainActor.run { BighelpPushPreferenceChanges.notify() }
        return preferences
    }

    private static let legacyMigrations: [(topic: BighelpBuzzKitTopic, legacySlugs: Set<String>)] = [
        (.chatRepliesAndCompletions, ["session-completed-desktop", "session-failed-desktop"]),
        (.questionsAndApprovals, ["approval-required-desktop", "clarification-required-desktop"]),
    ]

    private static func project(_ topic: BuzzKit.Topic) -> BighelpBuzzKitPreference? {
        guard BighelpBuzzKitTopic(rawValue: topic.slug) != nil,
              let push = topic.channels[.push] else { return nil }
        return BighelpBuzzKitPreference(
            id: topic.slug,
            name: topic.name,
            detail: topic.description,
            category: topic.category,
            enabled: push.isOptedIn,
            isDefault: push.isDefault
        )
    }
}
