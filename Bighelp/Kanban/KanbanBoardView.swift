import SwiftUI

/// Kanban: the host's boards in five lanes. Drag a card to move it; on iPhone,
/// drop it on a lane's tab or swipe it. Everything else is one tap away.
struct KanbanScreen: View {
    @Bindable var model: KanbanBoardModel
    var isNerdMode = false
    /// Vision Pro: open the board in its own window.
    var openInWindow: (() -> Void)? = nil
    /// A card to open once the board loads (from a widget or a link).
    var initialTaskID: String? = nil

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var openTask: KanbanTaskRef?
    @State private var newTaskLane: KanbanLane?
    @State private var compactLane: KanbanLane = .needsYou
    @State private var isNamingBoard = false
    @State private var boardName = ""
    @State private var confirmsAutoPlan = false
    @State private var choseStartingLane = false
    @State private var spatialDrag = KanbanSpatialDrag()
    @AppStorage("bighelp.kanban.auto-plan-explained") private var autoPlanExplained = false

    var body: some View {
        content
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            // The system's place, like every other searchable screen (see AgentsView).
            .searchable(text: $model.searchText, prompt: "Find a card")
            .bighelpSheet(item: $openTask) { ref in
                KanbanTaskSheet(model: model, taskID: ref.id, isNerdMode: isNerdMode)
                    .bighelpSheetSize(.large)
            }
            .bighelpSheet(item: $newTaskLane) { lane in
                KanbanNewTaskSheet(model: model, lane: lane)
                    .bighelpSheetSize(.standard)
            }
            .alert("New board", isPresented: $isNamingBoard) {
                TextField("Board name", text: $boardName)
                Button("Create") { Task { await model.createBoard(named: boardName); boardName = "" } }
                    .disabled(boardName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) { boardName = "" }
            } message: {
                Text("Boards keep separate projects apart. Your agents see every board.")
            }
            .alert("Turn on Auto plan?", isPresented: $confirmsAutoPlan) {
                Button("Turn On") {
                    autoPlanExplained = true
                    Task { await model.setAutoPlan(true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Hermes reads each new card in Later and splits big ones into smaller tasks. This uses your AI provider, so it costs a little each time.")
            }
            .overlay(alignment: .bottom) { toast }
            .task { await startIfNeeded() }
            .onAppear { model.setOnScreen(true) }
            .onDisappear { model.setOnScreen(false) }
            .onChange(of: model.snapshot?.board.slug) { _, _ in chooseStartingLane(force: true) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kanban.screen")
    }

    // MARK: Layout

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading where model.snapshot == nil:
            ProgressView("Loading your boards…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label("Kanban isn't on this computer", systemImage: "rectangle.split.3x1")
            } description: {
                Text("Kanban comes with Hermes. Update Hermes on your computer, then open Kanban again.")
            }
        case .failed(let message) where model.snapshot == nil:
            ContentUnavailableView {
                Label("The board didn't load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.start() } }.buttonStyle(.borderedProminent)
            }
        default:
            if model.snapshot == nil {
                noBoards
            } else {
                VStack(spacing: 0) {
                    KanbanAgentFilterBar(model: model)
                    if model.nobodyIsPickingUpWork { idleBanner }
                    if usesColumns { columns } else { pages }
                }
            }
        }
    }

    /// Vision Pro drags with its own pinch gesture; iPhone and iPad use the system's.
    private var usesSpatialDrag: Bool {
        #if os(visionOS)
        true
        #else
        false
        #endif
    }

    private var usesColumns: Bool {
        #if os(visionOS)
        true
        #else
        sizeClass == .regular
        #endif
    }

    private var noBoards: some View {
        ContentUnavailableView {
            Label("No boards yet", systemImage: "rectangle.split.3x1")
        } description: {
            Text("A board holds your agents' tasks in lanes: Later, Ready, Working, Needs you and Done.")
        } actions: {
            Button("New Board") { isNamingBoard = true }.buttonStyle(.borderedProminent)
        }
    }

    /// iPad and Vision Pro: every lane side by side, sharing the width. Lanes
    /// never get narrower than a readable card; below that the board scrolls.
    private var columns: some View {
        GeometryReader { proxy in
            let spacing = BighelpTokens.space16
            let fitted = (proxy.size.width - 2 * spacing - 4 * spacing) / 5
            let width = max(fitted, 250)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(KanbanLane.allCases) { lane in
                        KanbanLaneColumn(model: model, lane: lane, width: width, open: open, add: { newTaskLane = $0 })
                    }
                }
                .padding(spacing)
                .frame(minHeight: proxy.size.height, alignment: .top)
                .coordinateSpace(.named(KanbanSpatialDrag.space))
                .overlay(alignment: .topLeading) {
                    if usesSpatialDrag { KanbanDraggedCard(model: model, drag: spatialDrag) }
                }
            }
            .scrollDisabled(fitted >= 250 || spatialDrag.task != nil)
        }
        .environment(\.kanbanSpatialDrag, usesSpatialDrag ? spatialDrag : nil)
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kanban.columns")
    }

    /// iPhone: one lane at a time. Swipe between lanes, or drop a card on a tab.
    private var pages: some View {
        VStack(spacing: 0) {
            KanbanLaneTabs(model: model, selection: $compactLane)
            TabView(selection: $compactLane) {
                ForEach(KanbanLane.allCases) { lane in
                    KanbanLaneList(model: model, lane: lane, open: open, add: { newTaskLane = $0 })
                        .tag(lane)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    private var idleBanner: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: "moon.zzz.fill")
                .font(.bighelp(.title3))
                .foregroundStyle(KanbanLane.ready.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nobody's picking up work")
                    .bighelpFont(.body, weight: .semibold)
                Text("Ready cards are waiting. Hermes starts them while it's running on your computer.")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
            Button("Start now") { Task { await model.startReadyWork() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("kanban.start-now")
        }
        .padding(BighelpTokens.space12)
        .background(KanbanLane.ready.tint.opacity(0.1), in: .rect(cornerRadius: BighelpTokens.radius16))
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.bottom, BighelpTokens.space8)
    }

    @ViewBuilder private var toast: some View {
        if let notice = model.notice {
            Label(notice.text, systemImage: notice.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.bighelp(.subheadline).weight(.medium))
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, BighelpTokens.space16)
                .padding(.vertical, BighelpTokens.space12)
                .background(.regularMaterial, in: .capsule)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.horizontal, BighelpTokens.space24)
                .padding(.bottom, BighelpTokens.space24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(3.5))
                    withAnimation { if model.notice?.id == notice.id { model.notice = nil } }
                }
                .onTapGesture { withAnimation { model.notice = nil } }
                .accessibilityIdentifier("kanban.notice")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) { KanbanBoardSwitcher(model: model, newBoard: { isNamingBoard = true }) }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { newTaskLane = .later } label: { Image(systemName: "plus") }
                .accessibilityLabel("New card")
                .accessibilityIdentifier("kanban.new")
                .disabled(model.snapshot == nil)
            Menu {
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                if let autoPlan = model.autoPlan {
                    Toggle(isOn: Binding(get: { autoPlan }, set: { isOn in
                        if isOn, !autoPlanExplained { confirmsAutoPlan = true } else { Task { await model.setAutoPlan(isOn) } }
                    })) {
                        Label("Auto plan (uses AI)", systemImage: "sparkles")
                    }
                }
                Button { isNamingBoard = true } label: { Label("New board", systemImage: "plus.rectangle.on.rectangle") }
                if let openInWindow {
                    Button(action: openInWindow) { Label("Open in its own window", systemImage: "macwindow.badge.plus") }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Board options")
            .accessibilityIdentifier("kanban.options")
        }
    }

    // MARK: Actions

    private func open(_ task: HermesKanbanTask) { openTask = KanbanTaskRef(id: task.id) }

    private func startIfNeeded() async {
        if model.phase != .ready || model.snapshot == nil { await model.start() }
        chooseStartingLane(force: false)
        if let initialTaskID, model.snapshot?.tasks.contains(where: { $0.id == initialTaskID }) == true {
            openTask = KanbanTaskRef(id: initialTaskID)
        }
    }

    /// iPhone opens on what needs you, else what's in motion.
    private func chooseStartingLane(force: Bool) {
        guard force || !choseStartingLane, model.snapshot != nil else { return }
        choseStartingLane = true
        compactLane = [KanbanLane.needsYou, .working, .ready, .later].first { model.count(in: $0) > 0 } ?? .later
    }

    @BighelpThemeReader private var theme
}

struct KanbanTaskRef: Identifiable, Hashable {
    let id: String
}

extension KanbanLane {
    /// A card being dragged travels as "kanban:<task id>".
    static func draggedTaskID(_ payload: String) -> String? {
        guard payload.hasPrefix("kanban:") else { return nil }
        return String(payload.dropFirst("kanban:".count))
    }
}

// MARK: - Board switcher

struct KanbanBoardSwitcher: View {
    @Bindable var model: KanbanBoardModel
    let newBoard: () -> Void

    var body: some View {
        Menu {
            Section("Boards") {
                ForEach(model.boards.filter { !$0.isArchived }) { board in
                    Button { Task { await model.select(board: board.slug) } } label: {
                        let open = board.total - (board.counts["done"] ?? 0) - (board.counts["archived"] ?? 0)
                        Label("\(board.name) · \(max(0, open))",
                              systemImage: board.slug == model.board?.slug ? "checkmark" : "circle")
                    }
                    .accessibilityIdentifier("kanban.board.\(board.slug)")
                }
            }
            Button(action: newBoard) { Label("New board", systemImage: "plus") }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.board?.color.map { Color(hex: $0.replacingOccurrences(of: "#", with: "")) } ?? theme.action)
                    .frame(width: 8, height: 8)
                Text(model.board?.name ?? "Kanban")
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.bighelp(.caption).weight(.bold))
                    .foregroundStyle(theme.secondaryText)
                if model.isLive {
                    Circle().fill(KanbanLane.done.tint).frame(width: 6, height: 6)
                        .accessibilityLabel("Live")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(.capsule)
        }
        .kanbanMacMenu(.asDrawn)
        .accessibilityLabel("Board: \(model.board?.name ?? "none")")
        .accessibilityHint("Switch boards or make a new one.")
        .accessibilityIdentifier("kanban.board-switcher")
    }

    @BighelpThemeReader private var theme
}

// MARK: - Mac menus

enum KanbanMacMenuLook { case bordered, asDrawn }

extension View {
    /// The Mac turns a labeled menu into a bare pull-down without its arrow
    /// (the app hides the arrow for icon menus). These show what they choose
    /// instead: as a button, or with their own label and chevron as drawn.
    @ViewBuilder func kanbanMacMenu(_ look: KanbanMacMenuLook) -> some View {
        #if targetEnvironment(macCatalyst)
        switch look {
        case .bordered: menuStyle(.button).buttonStyle(.bordered)
        case .asDrawn: menuStyle(.button).buttonStyle(.plain)
        }
        #else
        self
        #endif
    }
}

// MARK: - Agent filter

struct KanbanAgentFilterBar: View {
    @Bindable var model: KanbanBoardModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: BighelpTokens.space8) {
                chip(.everyone) {
                    Image(systemName: "person.2.fill").font(.bighelp(.caption))
                    Text("Everyone")
                }
                ForEach(model.assignableAgents) { agent in
                    chip(.agent(agent.id)) {
                        AvatarView(stableID: agent.id, displayName: agent.name, imageURL: agent.imageURL, size: 20)
                        Text(agent.name.split(separator: " ").first.map(String.init) ?? agent.name)
                    }
                }
                chip(.unassigned) {
                    Image(systemName: "person.crop.circle.badge.questionmark").font(.bighelp(.caption))
                    Text("Anyone")
                }
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.vertical, BighelpTokens.space8)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kanban.agent-filter")
    }

    private func chip<Label: View>(_ filter: KanbanBoardModel.AgentFilter,
                                   @ViewBuilder label: () -> Label) -> some View {
        let selected = model.agentFilter == filter
        return Button {
            withAnimation(.snappy) { model.agentFilter = selected && filter != .everyone ? .everyone : filter }
        } label: {
            HStack(spacing: 6) { label() }
                .font(.bighelp(.subheadline).weight(.medium))
                .foregroundStyle(selected ? theme.actionForeground : theme.primaryText)
                .padding(.leading, 8)
                .padding(.trailing, 12)
                .frame(minHeight: 34)
                .background(selected ? theme.action : theme.surface, in: .capsule)
                .overlay { Capsule().strokeBorder(theme.border.opacity(selected ? 0 : 0.7), lineWidth: BighelpTokens.hairline) }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("kanban.filter.\(Self.id(filter))")
    }

    private static func id(_ filter: KanbanBoardModel.AgentFilter) -> String {
        switch filter {
        case .everyone: "everyone"
        case .unassigned: "anyone"
        case .agent(let id): id
        }
    }

    @BighelpThemeReader private var theme
}

// MARK: - iPhone lanes

/// Five tabs across the top, all on screen at once, so each is also a drop
/// target: drag a card up onto one to move it there.
struct KanbanLaneTabs: View {
    @Bindable var model: KanbanBoardModel
    @Binding var selection: KanbanLane
    @State private var target: KanbanLane?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(KanbanLane.allCases) { lane in tab(lane) }
        }
        .padding(4)
        .background(theme.surface, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.border.opacity(0.7), lineWidth: BighelpTokens.hairline)
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.bottom, BighelpTokens.space8)
    }

    private func tab(_ lane: KanbanLane) -> some View {
        let selected = selection == lane
        let targeted = target == lane
        let count = model.count(in: lane)
        return Button { withAnimation(.snappy) { selection = lane } } label: {
            VStack(spacing: 1) {
                Text("\(count)")
                    .font(.bighelp(.headline).weight(.bold).monospacedDigit())
                    .foregroundStyle(count > 0 || selected ? lane.tint : theme.tertiaryText)
                Text(lane.title)
                    .font(.bighelp(.caption2).weight(selected ? .bold : .semibold))
                    .foregroundStyle(selected ? theme.primaryText : theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(targeted ? lane.tint.opacity(0.3) : selected ? lane.tint.opacity(0.14) : .clear,
                        in: .rect(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(targeted ? lane.tint : .clear, lineWidth: 1.5)
            }
            .scaleEffect(targeted ? 1.06 : 1)
            .animation(.snappy, value: targeted)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { items, _ in
            drop(items, on: lane)
        } isTargeted: { isTargeted in
            if isTargeted { target = lane } else if target == lane { target = nil }
        }
        .accessibilityLabel("\(lane.title), \(count) card\(count == 1 ? "" : "s")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("kanban.lane-tab.\(lane.rawValue)")
    }

    private func drop(_ items: [String], on lane: KanbanLane) -> Bool {
        guard let id = items.first.flatMap(KanbanLane.draggedTaskID),
              let task = model.visibleTasks.first(where: { $0.id == id }), lane.accepts(task) else { return false }
        Task { await model.move(task, to: lane) }
        return true
    }

    @BighelpThemeReader private var theme
}

/// One lane on iPhone: a list with swipe actions for the next obvious step.
struct KanbanLaneList: View {
    @Bindable var model: KanbanBoardModel
    let lane: KanbanLane
    let open: (HermesKanbanTask) -> Void
    let add: (KanbanLane) -> Void

    var body: some View {
        let tasks = model.tasks(in: lane)
        List {
            Text(lane.subtitle)
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            ForEach(tasks) { task in
                KanbanCardButton(model: model, task: task, open: open)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .swipeActions(edge: .leading, allowsFullSwipe: true) { leadingSwipe(task) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) { trailingSwipe(task) }
            }
            if tasks.isEmpty {
                KanbanEmptyLane(lane: lane)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if lane == .later || lane == .ready {
                KanbanQuickAdd(model: model, lane: lane, more: { add(lane) })
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 24, trailing: 16))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.refresh() }
        .accessibilityIdentifier("kanban.lane.\(lane.rawValue)")
    }

    @ViewBuilder private func leadingSwipe(_ task: HermesKanbanTask) -> some View {
        switch lane {
        case .later:
            swipe("Start", "play.fill", KanbanLane.ready.tint) { await model.move(task, to: .ready) }
        case .ready:
            swipe("Later", "tray.fill", KanbanLane.later.tint) { await model.move(task, to: .later) }
        case .needsYou where task.status == .review:
            swipe("Approve", "checkmark", KanbanLane.done.tint) { await model.approve(task) }
        case .needsYou:
            swipe("Try again", "arrow.clockwise", KanbanLane.ready.tint) { await model.tryAgain(task) }
        case .done:
            swipe("Reopen", "arrow.uturn.backward", KanbanLane.later.tint) { await model.move(task, to: .later) }
        case .working:
            EmptyView()
        }
    }

    @ViewBuilder private func trailingSwipe(_ task: HermesKanbanTask) -> some View {
        if lane != .done {
            swipe("Done", "checkmark.circle.fill", KanbanLane.done.tint) { await model.move(task, to: .done) }
        }
    }

    private func swipe(_ title: String, _ symbol: String, _ tint: Color,
                       _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { Label(title, systemImage: symbol) }
            .tint(tint)
    }

    @BighelpThemeReader private var theme
}

// MARK: - iPad and Vision Pro lanes

struct KanbanLaneColumn: View {
    @Bindable var model: KanbanBoardModel
    let lane: KanbanLane
    var width: CGFloat = 300
    let open: (HermesKanbanTask) -> Void
    let add: (KanbanLane) -> Void
    @State private var dropTargeted = false
    @Environment(\.kanbanSpatialDrag) private var spatialDrag

    private var isTargeted: Bool { dropTargeted || spatialDrag?.target == lane }

    var body: some View {
        let tasks = model.tasks(in: lane)
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            header(count: tasks.count)
            ScrollView {
                LazyVStack(spacing: BighelpTokens.space12) {
                    ForEach(tasks) { task in
                        KanbanCardButton(model: model, task: task, open: open)
                    }
                    if tasks.isEmpty { KanbanEmptyLane(lane: lane) }
                    if lane == .later || lane == .ready {
                        KanbanQuickAdd(model: model, lane: lane, more: { add(lane) })
                    }
                }
                .padding(.bottom, BighelpTokens.space16)
            }
            .scrollIndicators(.hidden)
            .refreshable { await model.refresh() }
        }
        .padding(BighelpTokens.space12)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { laneBackground }
        #if os(visionOS)
        // Glass on the lane itself, not in its background: in a background
        // it floats over the cards and eats every pinch.
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: BighelpTokens.radius20, style: .continuous))
        #endif
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius20, style: .continuous)
                .strokeBorder(isTargeted ? lane.tint : .clear, lineWidth: 2)
        }
        .scaleEffect(isTargeted ? 1.01 : 1)
        .animation(.snappy, value: isTargeted)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(KanbanLane.draggedTaskID),
                  let task = model.visibleTasks.first(where: { $0.id == id }), lane.accepts(task) else { return false }
            Task { await model.move(task, to: lane) }
            return true
        } isTargeted: { dropTargeted = $0 && lane.dropStatus != nil }
        .kanbanLaneFrame(lane, drag: spatialDrag)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kanban.lane.\(lane.rawValue)")
    }

    private func header(count: Int) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            Image(systemName: lane.symbol)
                .font(.bighelp(.body).weight(.semibold))
                .foregroundStyle(lane.tint)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(lane.title).bighelpFont(.body, weight: .semibold)
                    Text("\(count)")
                        .font(.bighelp(.subheadline).weight(.semibold).monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                }
                Text(lane.subtitle)
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if lane == .later || lane == .ready {
                Button { add(lane) } label: { Image(systemName: "plus").font(.bighelp(.body).weight(.semibold)) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("New card in \(lane.title)")
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var laneBackground: some View {
        let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius20, style: .continuous)
        #if os(visionOS)
        shape.fill(lane.tint.opacity(isTargeted ? 0.18 : 0.06))
        #else
        shape.fill(isTargeted ? lane.tint.opacity(0.1) : theme.incomingMessageBackground.opacity(theme.isDarkPalette ? 0.55 : 0.6))
        #endif
    }

    @BighelpThemeReader private var theme
}

// MARK: - Shared pieces

/// A card you can tap, drag, or long-press for every other action.
struct KanbanCardButton: View {
    @Bindable var model: KanbanBoardModel
    let task: HermesKanbanTask
    let open: (HermesKanbanTask) -> Void
    @Environment(\.kanbanSpatialDrag) private var spatialDrag
    @State private var frame: CGRect = .zero

    var body: some View {
        if spatialDrag == nil {
            button
                .draggable("kanban:\(task.id)") {
                    KanbanCardView(task: task, agent: model.agent(task.assignee))
                        .frame(width: 280)
                }
        } else {
            button
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(KanbanSpatialDrag.space)) } action: { frame = $0 }
                .kanbanSpatialDraggable(task, drag: spatialDrag, frame: frame) { task, lane in
                    Task { await model.move(task, to: lane) }
                }
        }
    }

    private var button: some View {
        Button { open(task) } label: {
            KanbanCardView(task: task, agent: model.agent(task.assignee), isBusy: model.isBusy(task))
        }
        .buttonStyle(KanbanCardPressStyle())
        #if os(visionOS)
        .hoverEffect(.highlight)
        #endif
        .contextMenu { KanbanCardMenu(model: model, task: task, open: { open(task) }) }
    }
}

struct KanbanCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// Every action for a card, so nothing depends on dragging.
struct KanbanCardMenu: View {
    @Bindable var model: KanbanBoardModel
    let task: HermesKanbanTask
    let open: () -> Void

    var body: some View {
        Button(action: open) { Label("Open", systemImage: "arrow.up.left.and.arrow.down.right") }
        if task.status == .review {
            Button { Task { await model.approve(task) } } label: { Label("Approve", systemImage: "checkmark") }
        }
        if task.status == .blocked {
            Button { Task { await model.tryAgain(task) } } label: { Label("Try again", systemImage: "arrow.clockwise") }
        }
        Menu {
            ForEach(KanbanLane.allCases.filter { $0.accepts(task) }) { lane in
                Button { Task { await model.move(task, to: lane) } } label: { Label(lane.title, systemImage: lane.symbol) }
            }
        } label: { Label("Move to", systemImage: "arrow.right.square") }
        Menu {
            Button { Task { await model.assign(task, to: nil) } } label: {
                Label("Anyone", systemImage: task.assignee == nil ? "checkmark" : "person.crop.circle.badge.questionmark")
            }
            ForEach(model.assignableAgents) { agent in
                Button { Task { await model.assign(task, to: agent.id) } } label: {
                    Label(agent.name, systemImage: task.assignee == agent.id ? "checkmark" : "person")
                }
            }
        } label: { Label("Give to", systemImage: "person.crop.circle") }
        Menu {
            ForEach(KanbanPriority.allCases.reversed()) { priority in
                Button { Task { await model.setPriority(task, priority) } } label: {
                    Label(priority.title, systemImage: task.urgency == priority ? "checkmark" : "flag")
                }
            }
        } label: { Label("Priority", systemImage: "flag") }
        Divider()
        Button(role: .destructive) { Task { await model.archive(task) } } label: { Label("Archive", systemImage: "archivebox") }
    }
}

struct KanbanEmptyLane: View {
    let lane: KanbanLane

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: lane == .needsYou ? "checkmark.seal" : lane.symbol)
                .font(.bighelp(.title3))
                .foregroundStyle(lane.tint.opacity(0.8))
            Text(text)
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BighelpTokens.space24)
        .background {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .foregroundStyle(theme.border)
        }
    }

    private var text: String {
        switch lane {
        case .later: "Nothing planned. Add a card for later."
        case .ready: "Drop a card here and an agent picks it up."
        case .working: "No agent is working on anything."
        case .needsYou: "Nothing needs you."
        case .done: "Finished cards land here."
        }
    }

    @BighelpThemeReader private var theme
}

/// Type and press return to add a card to this lane; "More" opens the full form.
struct KanbanQuickAdd: View {
    @Bindable var model: KanbanBoardModel
    let lane: KanbanLane
    let more: () -> Void
    @State private var text = ""
    @State private var isEditing = false
    @FocusState private var focused: Bool

    var body: some View {
        if isEditing {
            HStack(spacing: BighelpTokens.space8) {
                TextField("New card in \(lane.title)", text: $text)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .accessibilityIdentifier("kanban.quick-add.\(lane.rawValue).field")
                Button("More", action: more).font(.bighelp(.footnote).weight(.semibold))
            }
            .padding(BighelpTokens.space12)
            .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16, style: .continuous))
            .onAppear { focused = true }
        } else {
            Button { isEditing = true } label: {
                Label("Add a card", systemImage: "plus")
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(theme.action)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.horizontal, BighelpTokens.space12)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("kanban.quick-add.\(lane.rawValue)")
        }
    }

    private func save() {
        let title = text
        text = ""
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { isEditing = false; return }
        let assignee: String? = if case .agent(let id) = model.agentFilter { id } else { nil }
        Task { await model.create(title: title, lane: lane, assignee: assignee) }
        focused = true
    }

    @BighelpThemeReader private var theme
}
