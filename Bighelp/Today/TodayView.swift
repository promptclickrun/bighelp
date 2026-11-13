import SwiftUI

/// What the Today tab needs from the shell.
@MainActor
struct TodayContext {
    /// The home header (`HomeHeaderBar`), drawn on top. Its trailing slot holds `TodayEditButton`.
    let header: AnyView
    /// Nil while nothing waits: then there is no card.
    var needsYou: TodayNeedsYouSummary?
    /// Opens the Needs you deck.
    let onOpenNeedsYou: () -> Void
    /// Nil while no share waits.
    var pendingShares: TodayPendingShares? = nil
    /// Every panel there is: the built-in boards panel (`TodayBoardsPanel.descriptor`), later Spaces.
    let panels: [TodayPanelDescriptor]
    /// Draws a panel's content at the size in the descriptor it's given.
    let makePanel: (TodayPanelDescriptor) -> AnyView
    let layout: TodayPanelLayoutStore
    /// Edit Today, toggled by the header's `TodayEditButton`.
    let isEditing: Binding<Bool>
    /// Delete for a panel that `canDelete`: the shell confirms, deletes, then calls `layout.forget`.
    var onDeletePanel: ((TodayPanelDescriptor) -> Void)? = nil
    /// Which bots work or need you, kept current while Today shows (the tab's dot reads it too).
    var activity: BotChatActivityStore? = nil
    var activitySource: BotChatActivitySource? = nil
    /// Just above the grid: one line per computer whose plugin can't show spaces (`SpacesTodayNotes`).
    var aboveGrid: AnyView? = nil
    /// Just below the grid: Make a space (`TodayCreateBox`).
    var belowGrid: AnyView? = nil
    /// A panel's own rows in its long-press menu (a Space's Open and Update now).
    var panelMenu: ((TodayPanelDescriptor) -> AnyView)? = nil
}

/// Today: Needs you on top while something waits, waiting shares, then the person's panels.
struct TodayView: View {
    let context: TodayContext
    @State private var width: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if context.isEditing.wrappedValue {
                TodayPanelEditList(panels: context.panels, layout: context.layout)
                    .frame(maxWidth: ChatCanvasLayout.regularLaneMaximumWidth)
                    .frame(maxWidth: .infinity)
            } else {
                scroll
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { context.header }
        .background(theme.canvas.ignoresSafeArea())
        .botChatActivityUpdates(context.activity, source: context.activitySource, isActive: scenePhase == .active)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.home")
    }

    private var scroll: some View {
        ScrollView {
            VStack(spacing: BighelpTokens.space12) {
                if let needsYou = context.needsYou, needsYou.count > 0 {
                    TodayNeedsYouCard(summary: needsYou, open: context.onOpenNeedsYou)
                }
                if let shares = context.pendingShares, shares.count > 0 {
                    TodaySharesCard(shares: shares)
                }
                context.aboveGrid
                BighelpDeferredSection {
                    panels
                }
                context.belowGrid
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.top, BighelpTokens.space8)
            .padding(.bottom, BighelpTokens.space32)
            .frame(maxWidth: ChatCanvasLayout.regularLaneMaximumWidth)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var panels: some View {
        let shown = context.layout.shown(context.panels)
        if shown.isEmpty {
            // Every panel is hidden: Edit brings them back.
            Text("Every panel is hidden. Tap Edit to show one.")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, BighelpTokens.space16)
                .accessibilityIdentifier("today.panels.empty")
        } else {
            TodayPanelGrid(panels: shown,
                           columns: TodayPanelPacking.columns(width: width - 2 * BighelpTokens.space16,
                                                              isAccessibilitySize: dynamicTypeSize.isAccessibilitySize),
                           makePanel: context.makePanel, layout: context.layout, onDelete: context.onDeletePanel,
                           menuItems: context.panelMenu)
        }
    }

    @BighelpThemeReader private var theme
}

/// Edit and Done for the header's trailing slot.
struct TodayEditButton: View {
    @Binding var isEditing: Bool

    var body: some View {
        Button {
            isEditing.toggle()
        } label: {
            Text(isEditing ? "Done" : "Edit")
                .font(.bighelp(.body, weight: isEditing ? .semibold : .regular))
                .foregroundStyle(theme.action)
                .padding(.horizontal, BighelpTokens.space8)
                .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                .contentShape(Rectangle())
        }
        .bighelpPlainButtonStyle()
        .accessibilityIdentifier("today.edit")
    }

    @BighelpThemeReader private var theme
}
