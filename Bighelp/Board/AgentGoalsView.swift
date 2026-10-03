import SwiftUI

/// Goals: what the agent is tracking, by category, then done ones, then Create a goal by category.
/// Every row here is a List row (`BoardScroll`), so goals swipe left to remove.
struct AgentGoalsView: View {
    let context: AgentBoardContext
    @State private var showsDone = false
    @State private var showsBlueprints = false
    @State private var fillingBlueprint: BoardBlueprint?

    var body: some View {
        let store = context.store
        let goals = store.goals
        let active = goals.filter { !$0.isDone }
        let isLoaded = store.state == .loaded
        BoardScroll(context: context, title: "Goals", identifier: "board.goals", seen: goals,
                    onBlueprints: { showsBlueprints = true }) {
            BoardStateBanner(state: store.state, context: context)
            if isLoaded || !goals.isEmpty {
                sectionTitle("Tracking")
                if active.isEmpty {
                    Text("Nothing is being tracked yet")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityIdentifier("board.goals.tracking.empty")
                }
                ForEach(GoalCategory.grouped(active), id: \.category) { group in
                    categoryHeader(group.category)
                    ForEach(group.items) { goal in goalRow(goal) }
                }
                done(goals.filter(\.isDone))
            }
            if isLoaded {
                createHeader
                createList
                if !store.supportsGoalCategories {
                    categoriesNeedUpdate
                }
            }
        }
        .boardBlueprints(isPresented: $showsBlueprints, kind: .goal, context: context)
        .blueprintFill($fillingBlueprint, context: context)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.bighelp(.title2).weight(.bold))
            .foregroundStyle(theme.primaryText)
            .padding(.top, BighelpTokens.space8)
            .accessibilityAddTraits(.isHeader)
    }

    private func categoryHeader(_ category: GoalCategory) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            CategoryBadge(category: category, size: 28)
            Text(category.groupTitle)
                .font(.bighelp(.headline))
                .foregroundStyle(theme.primaryText)
        }
        .padding(.top, BighelpTokens.space4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("board.goals.category.\(category.rawValue)")
    }

    @ViewBuilder
    private func done(_ items: [AgentBoardItem]) -> some View {
        if !items.isEmpty {
            HStack(spacing: BighelpTokens.space8) {
                Circle().fill(Color.gray).frame(width: 8, height: 8)
                    .padding(6)
                    .background(Circle().fill(Color.gray.opacity(0.18)))
                Text("Done")
                    .font(.bighelp(.headline))
                    .foregroundStyle(Color.gray)
            }
            .padding(.top, BighelpTokens.space8)
            .accessibilityAddTraits(.isHeader)
            if showsDone {
                ForEach(items) { goal in goalRow(goal) }
            } else {
                Button {
                    withAnimation(.snappy) { showsDone = true }
                } label: {
                    Label("Show \(items.count) done", systemImage: "ellipsis")
                        .font(.bighelp(.subheadline).weight(.medium))
                        .foregroundStyle(theme.secondaryText)
                        .frame(minHeight: BighelpTokens.hitTarget)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var createHeader: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            Text("Create a goal")
                .font(.bighelp(.title2).weight(.bold))
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text("Pick a category and tell \(context.agentName) a little about what you're after. "
                 + "It'll build a personalized plan that evolves with you.")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, BighelpTokens.space16)
    }

    /// One card, one row per category. A tap opens a chat with that category's request in the
    /// message box; touch and hold starts from one of its blueprints instead.
    private var createList: some View {
        VStack(spacing: 0) {
            ForEach(Array(GoalCategory.allCases.enumerated()), id: \.element) { index, category in
                if index > 0 {
                    Divider().overlay(theme.border).padding(.leading, 56)
                }
                createRow(category)
            }
        }
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(theme.border))
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
            CategoryBadge(category: category, size: 32)
            Text(category.title)
                .font(.bighelp(.body).weight(.medium))
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: BighelpTokens.space8)
            Image(systemName: "plus")
                .font(.bighelp(.body).weight(.semibold))
                .foregroundStyle(theme.action)
                .frame(width: 32, height: 32)
                .background(Circle().fill(theme.action.opacity(0.12)))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, BighelpTokens.space12)
        .frame(maxWidth: .infinity, minHeight: max(BighelpTokens.hitTarget, 52))
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

    private func goalRow(_ goal: AgentBoardItem) -> some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Button {
                Task { await context.store.setDone(goal, !goal.isDone) }
            } label: {
                Image(systemName: goal.isDone ? "checkmark.square.fill" : "square")
                    .font(.bighelp(.title2))
                    .foregroundStyle(goal.isDone ? theme.action : theme.secondaryText)
                    .frame(width: 30, height: BighelpTokens.hitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(goal.isDone ? "Mark \(goal.title) not done" : "Mark \(goal.title) done")
            .accessibilityIdentifier("board.goal.toggle.\(goal.id)")
            VStack(alignment: .leading, spacing: 2) {
                Text(goal.title)
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                    .strikethrough(goal.isDone)
                if !goal.note.isEmpty {
                    Text(goal.note)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.top, 10)
            Spacer(minLength: 0)
            UnreadDot(item: goal, store: context.store)
                .padding(.top, 18)
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
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
            }
            .accessibilityLabel("More for \(goal.title)")
        }
        .contentShape(.rect)
        .boardItemActions(goal, context: context)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.goal.\(goal.id)")
        .boardItemSwipe(goal, store: context.store)
    }

    @BighelpThemeReader private var theme
}

/// A category's symbol in a soft circle of the action color.
private struct CategoryBadge: View {
    let category: GoalCategory
    let size: CGFloat

    var body: some View {
        Image(systemName: category.systemImage)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(theme.action)
            .frame(width: size, height: size)
            .background(Circle().fill(theme.action.opacity(0.12)))
            .accessibilityHidden(true)
    }

    @BighelpThemeReader private var theme
}
