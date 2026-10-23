import SwiftUI

/// Bots mode's switcher beside a chat (`BighelpChatSwitcher`): the bots on top of the home, in the
/// order the person arranged them, each face showing what its Bot Chat is doing.
struct SimpleBotsSwitcher: View {
    let context: SimpleBotsContext
    /// The bot whose chat is open.
    let currentAgentID: String?

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        BighelpChatSwitcherColumn(stops: Self.top(context).map(stop))
            // The home's own updates stop while a chat covers it.
            .botChatActivityUpdates(context.activity, source: context.activitySource, isActive: scenePhase == .active)
    }

    /// The primary and pinned bots, as the home's top shows them (every gateway's with Multi-gateway),
    /// then the bots under them in the home's order, six in all.
    static func top(_ context: SimpleBotsContext) -> [SimpleBotsBot] {
        let home = home(context)
        let listed = home.rows.compactMap { item -> SimpleBotsBot? in
            if case .bot(let bot) = item.kind { return bot }
            return nil
        }
        return Array((home.top + listed).prefix(BighelpChatSwitcher.limit))
    }

    private static func home(_ context: SimpleBotsContext) -> SimpleBotsHomeProjection.Home {
        let order = SimpleBotsOrderStore.shared
        let scope = context.gateways == nil ? context.scope : "multi-gateway"
        guard let gateways = context.gateways else {
            return SimpleBotsHomeProjection.home(
                profiles: context.agents.profiles, primaryID: context.agents.primaryAgentID,
                pinnedIDs: context.agents.pinnedAgentIDs,
                summaries: context.catalog.recentSummaries(includeCronSessions: false),
                order: order.order(scope: scope), topOrder: order.order(scope: "top|" + scope),
                picture: { context.agents.avatarURL(for: $0) })
        }
        // Filter by Gateway: the gateway the home shows, as it does.
        let shown = gateways.filter.flatMap { hosts -> UUID? in
            guard let id = UserDefaults.standard.string(forKey: "bighelp.simple-bots.gateway-filter.shown")
                .flatMap(UUID.init(uuidString:)), hosts.contains(where: { $0.id == id }) else { return nil }
            return id
        }
        return SimpleBotsHomeProjection.home(
            bots: gateways.bots.filter { shown == nil || $0.hostID == shown },
            primaryID: gateways.primaryID, pinnedIDs: gateways.pinnedIDs,
            latest: gateways.latest, groups: [], order: order.order(scope: scope),
            topOrder: order.order(scope: "top|" + scope))
    }

    private func stop(_ bot: SimpleBotsBot) -> BighelpChatSwitcherStop {
        let isCurrent = bot.profileID == currentAgentID
            && (bot.hostID == nil || bot.hostID == context.gateways?.selectedHostID)
        return BighelpChatSwitcherStop(
            id: bot.id, title: bot.name,
            state: context.activity?.activity(bot.activityKey)?.accessibilityLabel ?? "",
            isCurrent: isCurrent,
            face: AnyView(SimpleBotLiveFace(bot: bot, size: 38, activity: context.activity)),
            open: { open(bot) })
    }

    /// As the home opens it: read, then on its own gateway.
    private func open(_ bot: SimpleBotsBot) {
        let multi = context.gateways != nil
        SimpleBotsUnreadStore.shared.set(false, id: multi ? bot.id : bot.profileID, scope: multi ? "multi-gateway" : context.scope)
        if let gateways = context.gateways, let host = bot.hostID {
            gateways.open(.agent(profileID: bot.profileID), host)
        } else {
            context.onOpenBot(bot.profileID)
        }
    }
}
