import SwiftUI

/// Goals: what the agent is tracking (the latest one in a block of its category's color, the
/// rest by category in a card), then done ones, then Create a goal by category. Every goal is
/// a List row of its own (`BoardScroll`), so goals swipe left to remove. Goals have no progress
/// number, so nothing here draws one.
struct AgentGoalsView: View {
    let context: AgentBoardContext
    @State private var showsDone = false
    @State private var showsBlueprints = false
    @State private var fillingBlueprint: BoardBlueprint?

    /// One row of the Tracking or Done card: a category's heading or a goal.
    private struct CardEntry: Identifiable {
        let id: String
        var category: GoalCategory?
        var goal: AgentBoardItem?
    }

    var body: some View {
        let store = context.store
        let goals = store.goals
        let active = goals.filter { !$0.isDone }
        let isLoaded = store.state == .loaded
        // The one the agent touched last leads.
        let hero = active.max { $0.updatedAt < $1.updatedAt }
        let groups = GoalCategory.grouped(active.filter { $0.id != hero?.id })
        let tracking: [CardEntry] = groups.flatMap { group -> [CardEntry] in
            [CardEntry(id: "category.\(group.category.rawValue)", category: group.category)]
                + group.items.map { CardEntry(id: $0.id, goal: $0) }
        }
        BoardScroll(context: context, title: "Goals", identifier: "board.goals", seen: goals,
                    onBlueprints: { showsBlueprints = true }) {
            BoardStateBanner(state: store.state, context: context)
                .boardRow()
            if isLoaded || !goals.isEmpty {
                BoardSectionCaption(title: "Tracking")
                    .boardRow(top: BighelpTokens.space8, bottom: 0)
                if active.isEmpty {
                    Text("Nothing is being tracked yet")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityIdentifier("board.goals.tracking.empty")
                        .boardRow()
                }
                if let hero {
                    let category = hero.goalCategory ?? .other
                    // The category's heading carries its name for tests and VoiceOver; with no
                    // other goals in it, the block's pill does.
                    GoalHeroBlock(goal: hero, context: context,
                                  categoryIdentifier: groups.contains { $0.category == category }
                                      ? "board.goals.hero.category" : "board.goals.category.\(category.rawValue)")
                        .boardRow()
                        .boardItemSwipe(hero, store: store)
                }
                card(tracking)
                done(goals.filter(\.isDone))
            }
            if isLoaded {
                createHeader
                    .boardRow(top: BighelpTokens.space16, bottom: BighelpTokens.space4)
                createList
                    .boardRow()
                if !store.supportsGoalCategories {
                    categoriesNeedUpdate
                        .boardRow()
                }
            }
        }
        .boardBlueprints(isPresented: $showsBlueprints, kind: .goal, context: context)
        .blueprintFill($fillingBlueprint, context: context)
    }

    /// A bordered card a row at a time: headings and goals, each goal swiping on its own.
    private func card(_ entries: [CardEntry]) -> some View {
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            let isFirst = index == 0
            let isLast = index == entries.count - 1
            // A hairline between goals and above each later heading, none under a heading.
            let separates = !isFirst && entries[index - 1].category == nil
            if let category = entry.category {
                categoryHeader(category)
                    .boardCardSegment(isFirst: isFirst, isLast: isLast, showsSeparator: !isFirst, separatorInset: 0)
            } else if let goal = entry.goal {
                goalRow(goal)
                    .boardCardSegment(isFirst: isFirst, isLast: isLast, showsSeparator: separates)
                    .boardItemSwipe(goal, store: context.store)
            }
        }
    }

    private func categoryHeader(_ category: GoalCategory) -> some View {
        Text(category.groupTitle)
            .font(.bighelp(.footnote, weight: .bold))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.top, BighelpTokens.space12)
            .padding(.bottom, BighelpTokens.space4)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("board.goals.category.\(category.rawValue)")
    }

    @ViewBuilder
    private func done(_ items: [AgentBoardItem]) -> some View {
        if !items.isEmpty {
            HStack(spacing: BighelpTokens.space8) {
                Image(systemName: "checkmark.circle")
                    .font(.bighelp(.headline))
                Text("Done")
                    .font(.bighelp(.title3, weight: .bold))
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.top, BighelpTokens.space8)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .boardRow(top: BighelpTokens.space8, bottom: 0)
            if showsDone {
                card(items.map { CardEntry(id: $0.id, goal: $0) })
            } else {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy) { showsDone = true }
                } label: {
                    Label("Show \(items.count) done", systemImage: "ellipsis")
                        .font(.bighelp(.subheadline).weight(.medium))
                        .foregroundStyle(theme.secondaryText)
                        .frame(minHeight: BighelpTokens.hitTarget)
                }
                .buttonStyle(.plain)
                .boardRow(top: 0)
            }
        }
    }

    private var createHeader: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            Text("Create a goal")
                .font(.bighelp(.title3, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text("Pick a category and tell \(context.agentName) a little about what you're after. "
                 + "It'll build a personalized plan that evolves with you.")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One card, one row per category. A tap opens a chat with that category's request in the
    /// message box; touch and hold starts from one of its blueprints instead.
    private var createList: some View {
        VStack(spacing: 0) {
            ForEach(Array(GoalCategory.allCases.enumerated()), id: \.element) { index, category in
                if index > 0 {
                    Rectangle()
                        .fill(theme.separator)
                        .frame(height: BighelpTokens.hairline)
                        .padding(.leading, 60)
                }
                createRow(category)
            }
        }
        .background(RoundedRectangle(cornerRadius: BoardBlockMetrics.cardRadius, style: .continuous)
            .fill(theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: BoardBlockMetrics.cardRadius, style: .continuous)
            .strokeBorder(theme.separator, lineWidth: BighelpTokens.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.goals.create")
    }

    @ViewBuilder
    private func createRow(_ category: GoalCategory) -> some View {
        let blueprints = BoardBlueprintCatalog.shared.blueprints(for: category)
        // Seven rows share one List row, and a List row shows only its first context menu:
        // each row carries its own Menu instead.
        Group {
            if blueprints.isEmpty {
                Button { context.onAsk(category.prompt) } label: { createLabel(category) }
                    .bighelpPlainButtonStyle()
            } else {
                Menu {
                    Section("Start from a blueprint") {
                        ForEach(blueprints) { blueprint in
                            Button(blueprint.text) { fillingBlueprint = blueprint }
                        }
                    }
                } label: {
                    createLabel(category)
                } primaryAction: {
                    context.onAsk(category.prompt)
                }
            }
        }
        .accessibilityLabel(category == .other ? "Create a goal: something else" : "Create a \(category.title) goal")
        .accessibilityIdentifier("board.goals.create.\(category.rawValue)")
    }

    private func createLabel(_ category: GoalCategory) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            CategoryBadge(category: category, size: 34)
            Text(category.title)
                .font(.bighelp(.body).weight(.medium))
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: BighelpTokens.space8)
            // The control in the row: the color picked in Appearance.
            Image(systemName: "plus")
                .font(.bighelp(.subheadline).weight(.bold))
                .foregroundStyle(theme.actionForeground)
                .frame(width: 30, height: 30)
                .background(Circle().fill(theme.action))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: max(BighelpTokens.hitTarget, 54))
        .contentShape(.rect)
    }

    /// Older plugins keep goals without categories: they all show under Other.
    private var categoriesNeedUpdate: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            Label("Update the bighelp plugin on your computer to sort goals by category.",
                  systemImage: "puzzlepiece.extension")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
            Button {
                context.onAsk("Please update the bighelp plugin on this host: \(BoardStateBanner.updateInstruction), "
                    + "then restart every Hermes dashboard process (including launchd or systemd services) "
                    + "so they load it, and tell me when it's back.")
            } label: {
                Text("Ask \(context.agentName) to update it")
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .frame(minHeight: BighelpTokens.hitTarget)
            }
            .buttonStyle(.borderless)
            .tint(theme.action)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.goals.categories-need-update")
    }

    /// A goal in the card: its category's tile, title and the agent's note, then done and ⋯.
    private func goalRow(_ goal: AgentBoardItem) -> some View {
        HStack(alignment: .center, spacing: BighelpTokens.space12) {
            CategoryBadge(category: goal.goalCategory ?? .other, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(goal.title)
                    .font(.bighelp(.subheadline, weight: .semibold))
                    .foregroundStyle(goal.isDone ? theme.secondaryText : theme.primaryText)
                    .strikethrough(goal.isDone)
                    .fixedSize(horizontal: false, vertical: true)
                if !goal.note.isEmpty {
                    Text(goal.note)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            UnreadDot(item: goal, store: context.store)
            HStack(spacing: 0) {
                GoalDoneToggle(goal: goal, store: context.store, ink: theme.secondaryText)
                GoalMoreMenu(goal: goal, context: context, ink: theme.secondaryText)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, BighelpTokens.space8)
        .contentShape(.rect)
        .boardItemActions(goal, context: context)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.goal.\(goal.id)")
    }

    @BighelpThemeReader private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

/// The goal the agent updated last, as a block in its category's color: the category, a big
/// title and the agent's latest note, with Mark done.
private struct GoalHeroBlock: View {
    let goal: AgentBoardItem
    let context: AgentBoardContext
    let categoryIdentifier: String

    var body: some View {
        let category = goal.goalCategory ?? .other
        let block = BighelpBlockColor.goal(category)
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack(alignment: .center, spacing: BighelpTokens.space8) {
                BoardOutlinePill(title: category.groupTitle, systemImage: category.systemImage, ink: block.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(categoryIdentifier)
                Spacer(minLength: 0)
                UnreadDot(item: goal, store: context.store)
                GoalMoreMenu(goal: goal, context: context, ink: block.ink)
            }
            Text(goal.title)
                .font(.bighelp(.title, weight: .bold))
                .tracking(-0.6)
                .fixedSize(horizontal: false, vertical: true)
            if !goal.note.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Latest from \(context.agentName)")
                        .font(.bighelp(.caption, weight: .semibold))
                        .foregroundStyle(block.ink.opacity(0.65))
                    Text(goal.note)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(block.ink.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                Task { await context.store.setDone(goal, true) }
            } label: {
                BoardActionPillLabel(title: "Mark done", systemImage: "checkmark")
            }
            .bighelpPlainButtonStyle()
            .accessibilityLabel("Mark \(goal.title) done")
            .accessibilityIdentifier("board.goal.toggle.\(goal.id)")
        }
        .boardBlock(block, padding: 20)
        .contentShape(.rect)
        .boardItemActions(goal, context: context)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.goal.\(goal.id)")
    }
}

/// Done or not, as a round check. Done fills with the color picked in Appearance.
private struct GoalDoneToggle: View {
    let goal: AgentBoardItem
    let store: AgentBoardStore
    let ink: Color

    var body: some View {
        Button {
            Task { await store.setDone(goal, !goal.isDone) }
        } label: {
            Image(systemName: goal.isDone ? "checkmark.circle.fill" : "circle")
                .font(.bighelp(.title3))
                .foregroundStyle(goal.isDone ? theme.action : ink)
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .accessibilityLabel(goal.isDone ? "Mark \(goal.title) not done" : "Mark \(goal.title) done")
        .accessibilityIdentifier("board.goal.toggle.\(goal.id)")
    }

    @BighelpThemeReader private var theme
}

/// ⋯ on a goal: Discuss, done and Remove, for people who don't touch and hold.
private struct GoalMoreMenu: View {
    let goal: AgentBoardItem
    let context: AgentBoardContext
    let ink: Color

    var body: some View {
        Menu {
            Button("Discuss", systemImage: "bubble.left") { context.onAsk("About my goal “\(goal.title)”: ") }
            Button(goal.isDone ? "Mark not done" : "Mark done", systemImage: "checkmark") {
                Task { await context.store.setDone(goal, !goal.isDone) }
            }
            let dismiss = BoardDismissAction(kind: .goal)
            Button(dismiss.title, systemImage: dismiss.systemImage, role: .destructive) {
                Task { await context.store.dismiss(goal) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.bighelp(.body).weight(.semibold))
                .foregroundStyle(ink)
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .accessibilityLabel("More for \(goal.title)")
    }
}

/// A category's symbol on a small square of its block color: content, not a control.
private struct CategoryBadge: View {
    let category: GoalCategory
    let size: CGFloat

    var body: some View {
        BoardIconTile(icon: "", fallback: category.systemImage, color: BighelpBlockColor.goal(category), size: size)
    }
}
