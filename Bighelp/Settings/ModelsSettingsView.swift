import Observation
import SwiftUI

/// Settings › Models' Default model: every bot's model for new chats, read for its row. A row opens the
/// bot's own Default Model page (`AgentDefaultModelsView`), the same page its profile opens, with the
/// same editor, so a change there shows on the row when you come back.
@MainActor @Observable
final class ModelsBotDefaults {
    private(set) var agents: [ModelAdministrationAgent] = []
    private(set) var editors: [String: AgentRuntimeDefaultsEditorModel] = [:]
    private(set) var helpers: [String: AgentHelperModelsModel] = [:]

    @ObservationIgnored private let client: any AgentRuntimeDefaultsClient
    @ObservationIgnored private let makeHelpers: @MainActor (String) -> AgentHelperModelsModel?

    init(agents: [ModelAdministrationAgent], client: any AgentRuntimeDefaultsClient,
         makeHelpers: @escaping @MainActor (String) -> AgentHelperModelsModel? = { _ in nil }) {
        self.client = client
        self.makeHelpers = makeHelpers
        show(agents)
    }

    /// The computer's bots changed (they're read after the page opened, or one was added): each new
    /// one gets its editor; the ones still there keep theirs.
    func show(_ agents: [ModelAdministrationAgent]) {
        guard agents != self.agents else { return }
        self.agents = agents
        for agent in agents where editors[agent.id] == nil {
            editors[agent.id] = AgentRuntimeDefaultsEditorModel(agentID: agent.id, client: client)
            if let helper = makeHelpers(agent.id) { helpers[agent.id] = helper }
        }
    }

    /// Reads every bot's defaults at once; each loads only once.
    func loadAll() async {
        let pending = agents.compactMap { editors[$0.id] }.filter { !$0.hasLoaded }
        await withTaskGroup(of: Void.self) { group in
            for editor in pending {
                group.addTask { await editor.loadIfNeeded() }
            }
        }
    }

    /// "Hermes 4 405B · High": the model new chats use and how hard it thinks. Nil until read.
    func summary(for agentID: String) -> String? {
        guard let editor = editors[agentID], editor.hasLoaded else { return nil }
        let selection = editor.draft[.mainChats]
        let model = selection.modelID.isEmpty ? String(localized: "Automatic")
            : ModelNameCatalog.empty.displayName(for: selection.modelID)
        guard !selection.reasoningEffort.isEmpty,
              let thinking = AgentReasoningOption.all.first(where: { $0.value == selection.reasoningEffort })?.title
        else { return model }
        return "\(model) · \(thinking)"
    }
}

/// Settings › Models › Default model: one row per bot, its face, its name and its model under it.
@MainActor
struct ModelsDefaultModelSection: View {
    let defaults: ModelsBotDefaults

    var body: some View {
        Section {
            ForEach(defaults.agents) { agent in
                if let editor = defaults.editors[agent.id] {
                    NavigationLink {
                        AgentDefaultModelsView(defaults: editor, helpers: defaults.helpers[agent.id], botName: agent.name)
                    } label: {
                        row(agent)
                    }
                    .bighelpSettingsLink()
                    .accessibilityIdentifier("models.bot.\(agent.id)")
                    .driveTarget("models.bot.\(agent.id)")
                }
            }
            if defaults.agents.isEmpty {
                Text("Your bots show here once your computer answers.")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
            }
        } header: {
            Text("Default model")
        } footer: {
            Text("New chats use these. A chat keeps its own.")
        }
        .task(id: defaults.agents.map(\.id)) { await defaults.loadAll() }
    }

    private func row(_ agent: ModelAdministrationAgent) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            AvatarView(stableID: agent.id, displayName: agent.name, imageURL: agent.imageURL, size: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                if let summary = defaults.summary(for: agent.id) {
                    Text(summary)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: BighelpTokens.space8)
            if BighelpPlatform.drawsOwnLinkChevron {
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, BighelpTokens.space8)
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(.rect)
        .bighelpSettingsLinkLabel()
    }

    @BighelpThemeReader private var theme
}
