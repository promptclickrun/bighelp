import Foundation
import WidgetKit

/// Reads the boards of agents a Feed, Ideas or Goals widget is set to, so a widget
/// can stay on one agent. The picked agent's board already comes from the app's
/// own store; Auto widgets need nothing more. Reads only, a few agents at most.
@MainActor
final class BighelpWidgetBoardLoader {
    static let shared = BighelpWidgetBoardLoader()
    static let maximumAgents = 6

    private let extras: BighelpWidgetExtras
    private let pickedAgentIDs: @MainActor () async -> [String]
    private var client: (any AgentBoardClient)?
    private var generation = 0

    init(extras: BighelpWidgetExtras = .shared,
         pickedAgentIDs: @escaping @MainActor () async -> [String] = BighelpWidgetBoardLoader.configuredAgentIDs) {
        self.extras = extras
        self.pickedAgentIDs = pickedAgentIDs
    }

    /// A new host, account or plugin drops every board read so far.
    func configure(client: (any AgentBoardClient)?) {
        guard client !== self.client else { return }
        self.client = client
        generation &+= 1
        if !extras.agentBoards.isEmpty { extras.agentBoards = [:] }
    }

    func refresh(homeAgentID: String?, knownAgentIDs: Set<String>) async {
        guard let client else {
            if !extras.agentBoards.isEmpty { extras.agentBoards = [:] }
            return
        }
        let generation = generation
        var wanted: [String] = []
        for id in await pickedAgentIDs() where id != homeAgentID && knownAgentIDs.contains(id) && !wanted.contains(id) {
            wanted.append(id)
        }
        var boards: [String: BighelpWidgetSnapshot.AgentBoard] = [:]
        for id in wanted.prefix(Self.maximumAgents) {
            guard generation == self.generation, !Task.isCancelled else { return }
            if let items = try? await client.items(agentID: id) {
                boards[id] = BighelpWidgetExtras.board(agentID: id, items: items)
            } else if let previous = extras.agentBoards[id] {
                // A dropped read keeps what the widget already shows.
                boards[id] = previous
            }
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        if boards != extras.agentBoards { extras.agentBoards = boards }
    }

    /// The agents Feed, Ideas and Goals widgets on this device are set to (not Auto).
    static func configuredAgentIDs() async -> [String] {
        // The async form needs iOS 18; this one reaches back to iOS 17.
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { @Sendable result in
                let widgets = (try? result.get()) ?? []
                continuation.resume(returning: widgets.filter { BighelpWidgetSnapshot.boardWidgetKinds.contains($0.kind) }
                    .compactMap { $0.widgetConfigurationIntent(of: BoardWidgetIntent.self)?.agent?.id }
                    .filter { $0 != BoardWidgetAgent.autoID })
            }
        }
    }
}
