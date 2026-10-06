import SwiftUI

/// Which app a chat belongs to: Hermes' own, or Codex or Claude Code. Those
/// cover the chats Hermes already brought in and the ones it can bring in from
/// the computer (`session.foreign.*`). Sessions shows the choice above its list,
/// on one computer and on all of them.
enum SessionAppFilter: String, CaseIterable, Identifiable, Sendable {
    case all, hermes, codex, claudeCode

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .hermes: "Hermes"
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }

    /// The `source` Hermes' `session.foreign.list` takes; nil lists both apps.
    var foreignSource: String? {
        switch self {
        case .codex: "codex"
        case .claudeCode: "claude"
        case .all, .hermes: nil
        }
    }

    /// Chats still in Codex or Claude Code show under every choice but Hermes.
    var showsOtherAppChats: Bool { self != .hermes }

    /// A chat by Hermes' `source` for it (`codex-cli`, `claude-code`, `bighelp`…),
    /// or a Codex or Claude Code chat by its app (`codex`, `claude`).
    func includes(source: String?) -> Bool {
        let label = SessionOrigin.label(source)
        switch self {
        case .all: return true
        case .hermes: return label != Self.codexLabel && label != Self.claudeCodeLabel
        case .codex: return label == Self.codexLabel
        case .claudeCode: return label == Self.claudeCodeLabel
        }
    }

    /// What an empty list says under this choice.
    var emptyTitle: String {
        switch self {
        case .all, .hermes: "No matching chats"
        case .codex: "No Codex chats"
        case .claudeCode: "No Claude Code chats"
        }
    }

    private static let codexLabel = SessionOrigin.label("codex")
    private static let claudeCodeLabel = SessionOrigin.label("claude")
}

/// All, Hermes, Codex, Claude Code: one tap, above the list.
struct SessionAppFilterBar: View {
    @Binding var selection: SessionAppFilter

    var body: some View {
        Picker("Chats from", selection: $selection) {
            ForEach(SessionAppFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .labelsHidden()
        .bighelpSegmentedPicker()
        .accessibilityIdentifier("sessions.app-filter")
    }
}
