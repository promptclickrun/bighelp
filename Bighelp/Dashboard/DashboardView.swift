import Foundation
import SwiftUI

enum DashboardInboxInteractionAction: Equatable {
    case openSession
    case startChat
}

enum DashboardInboxInteractionPolicy {
    static let primaryAction: DashboardInboxInteractionAction = .openSession
    static let secondaryAction: DashboardInboxInteractionAction = .startChat
}

enum DashboardGreeting {
    static func title(
        at date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12:
            "Good morning"
        case 12..<17:
            "Good afternoon"
        default:
            "Good evening"
        }
    }

    static func nextTransition(
        after date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let hour = calendar.component(.hour, from: date)
        let nextHour = switch hour {
        case 0..<5: 5
        case 5..<12: 12
        case 12..<17: 17
        default: 5
        }
        var components = DateComponents()
        components.timeZone = calendar.timeZone
        components.hour = nextHour
        components.minute = 0
        components.second = 0
        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) ?? date.addingTimeInterval(60)
    }
}

struct DashboardHeaderPresentation: Equatable, Sendable {
    enum LogoPlacement: Equatable, Sendable {
        case greetingRow
    }

    static let showsSessionsShortcut = false
    static let logoPlacement = LogoPlacement.greetingRow
}

enum DashboardInboxManagementPresentation {
    static let showsBulkRemoveControl = false
    static let showsDestructiveSwipeLabel = false
    static let menuActionTitles = [
        "Mark read",
        "Pin",
        "Start a chat about this",
        "Delete",
    ]
}

struct DashboardView: View {
    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    @Environment(\.bighelpUIV2Enabled) private var uiV2Enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionStore) private var companionStore
    @State private var model: DashboardModel
    @State private var greetingDate = Date()
    @State private var isClearAttentionConfirmationPresented = false
    @State private var knownAttentionIDs: Set<String>?
    @State private var companionReaction: CompanionReaction = .idle
    @State private var companionReactionTask: Task<Void, Never>?
    let connection: HostConnectionStatus
    let onInboxItemTap: (DashboardInboxItem) -> Void
    let onAttentionItemTap: (DashboardAttentionItem) -> Void
    let onWorkItemTap: (DashboardWorkItem) -> Void

    init(
        model: DashboardModel,
        connection: HostConnectionStatus = .init(dashboardIsConnected: true),
        onInboxItemTap: @escaping (DashboardInboxItem) -> Void = { _ in },
        onAttentionItemTap: @escaping (DashboardAttentionItem) -> Void = { _ in },
        onWorkItemTap: @escaping (DashboardWorkItem) -> Void = { _ in }
    ) {
        _model = State(initialValue: model)
        self.connection = connection
        self.onInboxItemTap = onInboxItemTap
        self.onAttentionItemTap = onAttentionItemTap
        self.onWorkItemTap = onWorkItemTap
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                header
                    .listRowSeparator(.hidden)
                    .listRowBackground(theme.canvas)
                Group {
                    if holdsHomeLoadingForTesting {
                        loading
                    } else {
                        switch (model.state, model.snapshot) {
                        case (.failure(let message), _):
                            failure(message: message)
                        case (_, .some(let snapshot)):
                            if uiV2Enabled && model.state == .loading
                                && companionStore?.isEnabled != true {
                                ProgressView("Refreshing activity")
                                    .accessibilityIdentifier("dashboard.refreshing")
                            }
                            dashboard(snapshot: snapshot)
                        case (.loading, nil):
                            loading
                        case (.idle, nil), (.loaded, nil):
                            loading
                        }
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(theme.canvas)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .listSectionSpacing(BighelpTokens.space20)
            .accessibilityIdentifier("dashboard.screen")
            .onChange(of: model.focusedUpdateID) { _, focusedUpdateID in
                guard let focusedUpdateID else { return }
                Task { @MainActor in
                    await Task.yield()
                    withAnimation(uiV2Enabled && reduceMotion ? nil : .snappy) {
                        proxy.scrollTo(updateAnchor(focusedUpdateID), anchor: .center)
                    }
                    model.consumeFocusedUpdate(id: focusedUpdateID)
                }
            }
            .onChange(of: model.focusedAttentionID) { _, focusedAttentionID in
                guard let focusedAttentionID else { return }
                Task { @MainActor in
                    await Task.yield()
                    withAnimation(uiV2Enabled && reduceMotion ? nil : .snappy) {
                        proxy.scrollTo(attentionAnchor(focusedAttentionID), anchor: .center)
                    }
                    model.consumeFocusedAttention(id: focusedAttentionID)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let companionStore, companionStore.isEnabled, !showsInitialHomeLoading {
                CompanionInteractionLayer(
                    appearance: companionStore.defaultAppearance,
                    reaction: floatingHomeCompanionReaction,
                    itemSize: homeCompanionSize,
                    insets: CompanionSurfaceInsets(top: 0, leading: 8, bottom: 8, trailing: 12),
                    restsAtTop: true,
                    accessibilityID: "companion-home"
                )
                .transition(.identity)
            }
        }
        .background(theme.canvas.ignoresSafeArea())
        .alert(
            "Unable to update Home",
            isPresented: Binding(
                get: { model.mutationErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { model.clearMutationError() }
                }
            )
        ) {
            Button("OK") { model.clearMutationError() }
        } message: {
            Text(model.mutationErrorMessage ?? "Please try again.")
        }
        .alert(
            model.notificationOpenMessage ?? "",
            isPresented: Binding(
                get: { model.notificationOpenMessage != nil },
                set: { isPresented in
                    if !isPresented { model.clearNotificationOpenMessage() }
                }
            )
        ) {
            Button("Okay", role: .cancel) { model.clearNotificationOpenMessage() }
        }
        .task(id: connection.phase) {
            if model.state == .idle { await model.load() }
        }
        .task(id: model.nextAttentionExpiry) {
            await model.expireAttentionWhenDue()
        }
        .onAppear { model.expireAttention() }
        .refreshable { await refreshHome() }
        #if targetEnvironment(macCatalyst)
        // A Mac list can't be pulled down to refresh.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refreshHome() } }
                    .keyboardShortcut("r")
                    .accessibilityIdentifier("dashboard.refresh")
            }
        }
        #endif
        .task(id: scenePhase) {
            await refreshGreetingWhileActive()
        }
        .onChange(of: homeAttentionIDs, initial: true) { _, IDs in
            reconcileCompanionAttention(IDs)
        }
        .onChange(of: companionStore?.isEnabled) { _, enabled in
            if enabled != true {
                companionReactionTask?.cancel()
                companionReactionTask = nil
                companionReaction = .idle
            }
        }
        .onDisappear {
            companionReactionTask?.cancel()
            companionReactionTask = nil
            companionReaction = .idle
        }
    }

    private var homeAttentionIDs: Set<String> {
        Set(model.snapshot?.attentionItems.map(\.id) ?? [])
    }

    private var showsInitialHomeLoading: Bool {
        if holdsHomeLoadingForTesting { return true }
        guard model.snapshot == nil else { return false }
        switch model.state {
        case .idle, .loading, .loaded:
            return true
        case .failure:
            return false
        }
    }

    private var floatingHomeCompanionReaction: CompanionReaction {
        switch model.state {
        case .loading:
            return .thinking
        case .failure:
            return .failed
        case .idle, .loaded:
            return companionReaction
        }
    }

    private var homeCompanionSize: CGFloat {
        let scale = companionStore?.sizeScale ?? CompanionStore.defaultSizeScale
        return 72 * CGFloat(CompanionStore.sanitizedSizeScale(scale))
    }

    private var holdsHomeLoadingForTesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-test-home-loading")
        #else
        false
        #endif
    }

    private func reconcileCompanionAttention(_ IDs: Set<String>) {
        guard let previous = knownAttentionIDs else {
            // Hydration and replay establish a baseline without performing a
            // celebration/attention animation for old work.
            knownAttentionIDs = IDs
            return
        }
        knownAttentionIDs = IDs
        guard companionStore?.isEnabled == true, !IDs.subtracting(previous).isEmpty else { return }
        companionReactionTask?.cancel()
        companionReaction = .attention
        companionReactionTask = Task { @MainActor in
            do {
                try await Task.sleep(for: CompanionReactionDuration.homeAttention)
            } catch {
                return
            }
            companionReaction = .idle
            companionReactionTask = nil
        }
    }

    private func dashboard(snapshot: DashboardSnapshot) -> some View {
        Group {
            needsYou(snapshot.attentionItems)
            workInFlight(model.workInFlightItems)
            inbox(snapshot.inbox)
            completed(model.presentedCompletedItems)
        }
    }

    @ViewBuilder
    private var header: some View {
        if uiV3Enabled {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: BighelpTokens.space12) {
                    v3ConnectionLabel
                    Spacer(minLength: 0)
                    Text(model.lastUpdatedLabel)
                }
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    v3ConnectionLabel
                    Text(model.lastUpdatedLabel)
                }
            }
            .font(.bighelp(.caption))
            .foregroundStyle(theme.secondaryText)
            .accessibilityElement(children: .combine)
        } else {
            legacyHeader
        }
    }

    private var v3ConnectionLabel: some View {
        Label {
            Text(connection.label)
        } icon: {
            BighelpConnectionIndicator(phase: connection.phase)
        }
            .foregroundStyle(connection.phase == .connected ? theme.secondaryText : theme.warning)
            .accessibilityIdentifier("dashboard.connection-status")
    }

    private var legacyHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: BighelpTokens.space12) {
                v3ConnectionLabel
                Spacer(minLength: BighelpTokens.space8)
                Text(model.lastUpdatedLabel)
            }
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                v3ConnectionLabel
                Text(model.lastUpdatedLabel)
            }
        }
        .font(.bighelp(.caption))
        .foregroundStyle(theme.secondaryText)
        .accessibilityElement(children: .combine)
    }

    private func refreshHome() async {
        await model.refresh()
    }

    private func refreshGreetingWhileActive() async {
        greetingDate = Date()
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
            let transition = DashboardGreeting.nextTransition(after: greetingDate)
            do {
                try await Task.sleep(for: .seconds(max(1, transition.timeIntervalSinceNow)))
            } catch {
                return
            }
            greetingDate = Date()
        }
    }

    @ViewBuilder
    private func dashboardCard(_ item: DashboardInboxItem) -> some View {
        switch item.cardEnvelope {
        case .legacy(let card):
            GenerativeUICardView(card: card)
                .accessibilityIdentifier("dashboard.generative-ui.\(item.id)")
        case .card(let card):
            BighelpCardView(card: card)
                .accessibilityIdentifier("dashboard.loopdy-card.\(item.id)")
        case nil:
            EmptyView()
        }
    }

    private func inbox(_ items: [DashboardInboxItem]) -> some View {
        section(
            title: "Updates",
            status: "\(items.count) updates",
            identifier: "dashboard.inbox"
        ) {
            if items.isEmpty {
                empty("No agent updates right now.")
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                        if item.cardEnvelope != nil {
                            dashboardCard(item)
                            HStack(spacing: BighelpTokens.space8) {
                                Button {
                                    openInboxItem(item)
                                } label: {
                                    cardActionsRow(item)
                                }
                                    .buttonStyle(.plain)
                                    .modifier(
                                        DashboardSwipeToRemoveModifier(
                                            opensOnTap: false,
                                            onOpen: {},
                                            onRemove: {
                                                Task { await model.dismissUpdate(id: item.id) }
                                            }
                                        )
                                    )
                                    .accessibilityIdentifier("dashboard.update.row.\(item.id)")
                                updateActionsMenu(item)
                            }
                        } else {
                            HStack(alignment: .top, spacing: BighelpTokens.space8) {
                                Button {
                                    openInboxItem(item)
                                } label: {
                                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                        HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                                            Text(item.title)
                                                .bighelpFont(.label)
                                                .foregroundStyle(theme.primaryText)
                                                .multilineTextAlignment(.leading)
                                            Spacer(minLength: BighelpTokens.space4)
                                            Text(item.status)
                                                .bighelpFont(.metadata, weight: .semibold)
                                                .foregroundStyle(theme.information)
                                        }
                                        Text(item.detail)
                                            .bighelpFont(.body)
                                            .foregroundStyle(theme.secondaryText)
                                            .multilineTextAlignment(.leading)
                                        Text("From \(item.agentName)")
                                            .bighelpFont(.metadata)
                                            .foregroundStyle(theme.tertiaryText)
                                    }
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                                .contentShape(.rect)
                                .accessibilityLabel("\(item.title). \(item.detail). From \(item.agentName). \(item.status).")
                                .modifier(
                                    DashboardSwipeToRemoveModifier(
                                        opensOnTap: false,
                                        onOpen: {},
                                        onRemove: {
                                            Task { await model.dismissUpdate(id: item.id) }
                                        }
                                    )
                                )
                                .accessibilityIdentifier("dashboard.update.row.\(item.id)")
                                updateActionsMenu(item)
                            }
                        }
                    }
                    .id(updateAnchor(item.id))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await model.dismissUpdate(id: item.id) }
                        }
                    }
                    if index < items.count - 1 {
                        Divider()
                            .padding(.vertical, BighelpTokens.space12)
                    }
                }
            }
        }
    }

    private func cardActionsRow(_ item: DashboardInboxItem) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            Text("From \(item.agentName) · \(item.status)")
                .bighelpFont(.metadata, weight: item.isRead ? .regular : .semibold)
                .foregroundStyle(theme.tertiaryText)
            Spacer(minLength: BighelpTokens.space8)
            Image(systemName: "arrow.right.circle")
                .foregroundStyle(theme.tertiaryText)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open \(item.title). From \(item.agentName). \(item.status).")
    }

    private func openInboxItem(_ item: DashboardInboxItem) {
        if !item.isRead {
            Task { await model.setUpdateRead(id: item.id, isRead: true) }
        }
        onInboxItemTap(item)
    }

    private func updateActionsMenu(_ item: DashboardInboxItem) -> some View {
        Menu {
            Button(item.isRead ? "Mark unread" : "Mark read") {
                Task { await model.setUpdateRead(id: item.id, isRead: !item.isRead) }
            }
            Button(item.isPinned ? "Unpin" : "Pin") {
                Task { await model.setUpdatePinned(id: item.id, isPinned: !item.isPinned) }
            }
            Button("Open conversation", systemImage: "arrow.right.circle") {
                openInboxItem(item)
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await model.dismissUpdate(id: item.id) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
        }
        .accessibilityLabel("Manage \(item.title)")
        .accessibilityIdentifier("dashboard.update.manage.\(item.id)")
    }

    private func needsYou(_ items: [DashboardAttentionItem]) -> some View {
        section(
            title: "Needs You",
            status: "\(items.count) items",
            identifier: "dashboard.needs-you"
        ) {
            if items.isEmpty {
                empty("Nothing needs your attention.")
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .top, spacing: BighelpTokens.space8) {
                        Group {
                            switch item.interaction {
                            case .clarification(let request):
                                DashboardClarificationAttentionCard(
                                    itemID: item.id,
                                    request: request,
                                    model: model,
                                    sessionTitle: model.session(for: item).map {
                                        DashboardWorkProjection.meaningfulTitle($0.title) ?? "Conversation"
                                    } ?? "Conversation unavailable",
                                    onOpenSession: { onAttentionItemTap(item) }
                                )
                                .accessibilityElement(children: .contain)
                            case .approval(let request):
                                DashboardApprovalAttentionCard(
                                    itemID: item.id,
                                    title: item.title,
                                    detail: item.detail,
                                    request: request,
                                    model: model
                                )
                            case .none:
                                genericAttentionRow(item)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("dashboard.attention.row.\(item.id)")
                        attentionActionsMenu(item)
                    }
                    .id(attentionAnchor(item.id))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await model.dismissAttention(id: item.id) }
                        }
                    }
                    if index < items.count - 1 {
                        Divider()
                            .padding(.vertical, BighelpTokens.space12)
                    }
                }
                Divider()
                    .padding(.vertical, BighelpTokens.space12)
                Button("Clear Needs You", systemImage: "trash", role: .destructive) {
                    isClearAttentionConfirmationPresented = true
                }
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("dashboard.attention.clear")
                .confirmationDialog(
                    "Clear everything in Needs You?",
                    isPresented: $isClearAttentionConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button("Clear Needs You", role: .destructive) {
                        Task { await model.clearAttention() }
                    }
                }
            }
        }
    }

    private func genericAttentionRow(_ item: DashboardAttentionItem) -> some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: item.urgency.systemImage)
                .font(.bighelp(.title3).weight(.semibold))
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(item.urgency.title)
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.warning)
                Text(item.title)
                    .bighelpFont(.label, weight: item.isRead ? .regular : .semibold)
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.leading)
                Text(item.detail)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(theme.information)
                    .accessibilityLabel("Pinned")
            }
        }
        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.urgency.title). \(item.title). \(item.detail)")
        .modifier(
            DashboardSwipeToRemoveModifier(
                opensOnTap: true,
                onOpen: { onAttentionItemTap(item) },
                onRemove: {
                    Task { await model.dismissAttention(id: item.id) }
                }
            )
        )
    }

    private func attentionActionsMenu(_ item: DashboardAttentionItem) -> some View {
        Menu {
            Button(item.isRead ? "Mark unread" : "Mark read") {
                Task { await model.setAttentionRead(id: item.id, isRead: !item.isRead) }
            }
            Button(item.isPinned ? "Unpin" : "Pin") {
                Task { await model.setAttentionPinned(id: item.id, isPinned: !item.isPinned) }
            }
            Button("Remove", role: .destructive) {
                Task { await model.dismissAttention(id: item.id) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
        }
        .accessibilityLabel("Manage \(item.title)")
        .accessibilityIdentifier("dashboard.attention.manage.\(item.id)")
    }

    private func workInFlight(_ items: [DashboardWorkItem]) -> some View {
        section(
            title: "In progress",
            status: "\(items.count) active",
            identifier: "dashboard.work-in-flight"
        ) {
            if items.isEmpty {
                empty("No work in flight.")
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button { onWorkItemTap(item) } label: {
                        HStack(spacing: BighelpTokens.space12) {
                            Image(systemName: "circle.dotted")
                                .foregroundStyle(theme.information)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                Text(item.title)
                                    .bighelpFont(.label)
                                    .foregroundStyle(theme.primaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(connection.phase == .connected ? item.subtitle : connection.label)
                                    .bighelpFont(.body)
                                    .foregroundStyle(theme.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.title). \(connection.phase == .connected ? item.subtitle : connection.label)")
                    .accessibilityHint("Opens this conversation")
                    .accessibilityIdentifier("dashboard.work.row.\(item.id)")
                    if index < items.count - 1 {
                        Divider().padding(.vertical, BighelpTokens.space12)
                    }
                }
            }
        }
    }

    private func completed(_ items: [DashboardCompletion]) -> some View {
        section(
            title: "Finished",
            status: "\(items.count) complete",
            identifier: "dashboard.completed"
        ) {
            if items.isEmpty {
                empty("No completed work yet today.")
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .top, spacing: BighelpTokens.space12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.success)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            Text(item.title)
                                .bighelpFont(.label)
                                .foregroundStyle(theme.primaryText)
                            Text(item.detail)
                                .bighelpFont(.body)
                                .foregroundStyle(theme.secondaryText)
                            Text(item.completedLabel)
                                .bighelpFont(.metadata)
                                .foregroundStyle(theme.tertiaryText)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    if index < items.count - 1 {
                        Divider()
                            .padding(.vertical, BighelpTokens.space12)
                    }
                }
            }
        }
    }

    private func section<Content: View>(
        title: String,
        status: String,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            content()
        } header: {
            Text(title)
                .bighelpFont(.sectionTitle)
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(identifier)
                .accessibilityValue(status)
        }
    }

    private var loading: some View {
        VStack(spacing: BighelpTokens.space12) {
            if let companionStore, companionStore.isEnabled {
                CompanionAvatar(
                    appearance: companionStore.defaultAppearance,
                    reaction: .thinking,
                    isAnimating: true
                )
                .frame(width: homeCompanionSize, height: homeCompanionSize)
                .accessibilityIdentifier("companion-home-loading")
            } else {
                ProgressView()
            }
            Text("Loading activity…")
                .bighelpFont(.body)
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .accessibilityElement(children: .contain)
    }

    private func failure(message: String) -> some View {
        ContentUnavailableView {
            Label("Home unavailable", systemImage: "house")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") {
                Task { await model.load() }
            }
        }
    }

    private func empty(_ message: String) -> some View {
        Text(message)
            .bighelpFont(.body)
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
    }

    private func updateAnchor(_ id: String) -> String {
        "dashboard.update.\(id)"
    }

    private func attentionAnchor(_ id: String) -> String {
        "dashboard.attention.\(id)"
    }

    @BighelpThemeReader private var theme

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
}

struct DashboardClarificationAttentionCard: View {
    let itemID: String
    let request: DashboardClarificationRequest
    let model: DashboardModel
    let accessibilityPrefix: String
    let sessionTitle: String?
    let onOpenSession: (() -> Void)?

    init(
        itemID: String,
        request: DashboardClarificationRequest,
        model: DashboardModel,
        accessibilityPrefix: String = "dashboard",
        sessionTitle: String? = nil,
        onOpenSession: (() -> Void)? = nil
    ) {
        self.itemID = itemID
        self.request = request
        self.model = model
        self.accessibilityPrefix = accessibilityPrefix
        self.sessionTitle = sessionTitle
        self.onOpenSession = onOpenSession
        self.draft = model.clarificationDraft(itemID: itemID, request: request)
    }

    @Bindable private var draft: DashboardClarificationDraft

    private var accessibilityIdentifiers: DashboardClarificationAccessibilityIdentifiers {
        DashboardClarificationAccessibilityIdentifiers(prefix: accessibilityPrefix)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let isExpired = request.isExpired(at: context.date)
            let canRespond = !isExpired
            BighelpCard {
                VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                    Label("Clarification needed", systemImage: "questionmark.bubble.fill")
                        .bighelpFont(.sectionTitle)
                        .foregroundStyle(isExpired ? theme.tertiaryText : theme.warning)
                    if let sessionTitle, let onOpenSession {
                        Button(action: onOpenSession) {
                            Label(sessionTitle, systemImage: "bubble.left.and.bubble.right")
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(minHeight: BighelpTokens.hitTarget, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.action)
                        .accessibilityHint("Opens the conversation that asked this question")
                        .accessibilityIdentifier("\(accessibilityPrefix).clarification.session.\(itemID)")
                    }

                    ForEach(Array(request.questions.enumerated()), id: \.offset) { questionIndex, question in
                        questionView(question, questionIndex: questionIndex, canRespond: canRespond)
                    }

                    if ClarificationAnswers.acceptsOwnWords(shapes) {
                        ownWordsField(canRespond: canRespond)
                    }

                    BighelpPillControl(
                        isEnabled: completedResponse() != nil && canRespond && !isResolving
                    ) {
                        submitCompletedResponse()
                    } label: {
                        Text("Done")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .accessibilityIdentifier(accessibilityIdentifiers.done)

                    status(at: context.date)

                    if let message = model.clarificationDeliveryMessages[itemID] {
                        Text(message)
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(accessibilityIdentifiers.fallbackMessage)
                    }
                }
            }
            .opacity(isExpired ? 0.68 : 1)
        }
        .accessibilityIdentifier(accessibilityIdentifiers.card(itemID: itemID))
    }

    private var isResolving: Bool {
        model.resolvingAttentionIDs.contains(itemID)
    }

    @ViewBuilder
    private func questionView(
        _ question: DashboardClarificationQuestion,
        questionIndex: Int,
        canRespond: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text(question.question)
                .bighelpFont(.label)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier(accessibilityIdentifiers.question(questionIndex))

            if let locked = question.lockedAnswer {
                Label(locked, systemImage: "lock.fill")
                    .foregroundStyle(theme.secondaryText)
                    .textSelection(.enabled)
                    .accessibilityLabel("Locked answer: \(locked)")
            } else {
                ForEach(Array(question.choices.enumerated()), id: \.offset) { choiceIndex, choice in
                    let selected = draft.selectedIndices(questionIndex: questionIndex).contains(choiceIndex)
                    BighelpPillControl(
                        isSelected: selected,
                        isEnabled: canRespond && !isResolving
                    ) {
                        choose(
                            question: question,
                            questionIndex: questionIndex,
                            choiceIndex: choiceIndex
                        )
                    } label: {
                        HStack(spacing: BighelpTokens.space8) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .accessibilityHidden(true)
                            Text(choice)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .accessibilityIdentifier(
                        accessibilityIdentifiers.choice(
                            questionIndex: questionIndex,
                            choiceIndex: choiceIndex
                        )
                    )
                }
            }
        }
    }

    private var shapes: [ClarificationAnswers.Question] { request.questions.map(\.answerShape) }

    /// One field for the whole card. On a single question it replaces the
    /// picked choice; on several it answers each one without a choice.
    private func ownWordsField(canRespond: Bool) -> some View {
        TextField(
            request.questions.count > 1 ? "Or answer in your own words" : "Type another response",
            text: Binding(
                get: { draft.customResponse },
                set: { value in
                    draft.customResponse = value
                    if request.questions.count == 1, !value.isEmpty {
                        draft.setSelectedIndices([], questionIndex: 0)
                        draft.selectedChoices = []
                    }
                }
            ),
            axis: .vertical
        )
        .lineLimit(1...4)
        .bighelpFont(.body)
        .disabled(!canRespond || isResolving)
        .submitLabel(.done)
        .onSubmit { submitCompletedResponse() }
        .accessibilityIdentifier(accessibilityIdentifiers.customResponse)
        .bighelpSurface(.composer)
    }

    private func choose(
        question: DashboardClarificationQuestion,
        questionIndex: Int,
        choiceIndex: Int
    ) {
        guard question.choices.indices.contains(choiceIndex) else { return }
        var selected = draft.selectedIndices(questionIndex: questionIndex)
        if question.isMultiSelect {
            if selected.contains(choiceIndex) { selected.remove(choiceIndex) }
            else { selected.insert(choiceIndex) }
        } else {
            selected = [choiceIndex]
        }
        if request.questions.count == 1 { draft.customResponse = "" }
        draft.setSelectedIndices(selected, questionIndex: questionIndex)
        if questionIndex == 0 {
            draft.selectedChoices = Set(selected.compactMap { index in
                question.choices.indices.contains(index) ? question.choices[index] : nil
            })
        }

        guard let response = completedResponse(), !requiresExplicitDone() else { return }
        submit(response)
    }

    private func completedResponse() -> DashboardClarificationResponse? {
        let selections = Dictionary(uniqueKeysWithValues: request.questions.indices.map {
            ($0, draft.selectedIndices(questionIndex: $0))
        })
        guard let values = ClarificationAnswers.answers(for: shapes, selections: selections,
                                                        ownWords: draft.customResponse) else { return nil }
        let response = DashboardClarificationResponse(answers: zip(request.questions, values).map {
            DashboardClarificationAnswer(questionID: $0.id, value: $1)
        })
        return request.accepts(response) ? response : nil
    }

    private func requiresExplicitDone() -> Bool {
        ClarificationAnswers.needsDone(shapes, ownWords: draft.customResponse)
    }

    private func submitCompletedResponse() {
        guard let response = completedResponse() else { return }
        submit(response)
    }

    private func submit(_ response: DashboardClarificationResponse) {
        guard !isResolving else { return }
        Task { await model.respondToClarification(itemID: itemID, response: response) }
    }

    @ViewBuilder
    private func status(at date: Date) -> some View {
        if request.isExpired(at: date) {
            Label("Expired · no response was sent", systemImage: "clock.badge.xmark")
                .foregroundStyle(theme.tertiaryText)
                .accessibilityIdentifier(accessibilityIdentifiers.expired)
        } else if isResolving {
            HStack(spacing: BighelpTokens.space8) {
                BighelpThinkingOrb(scenario: .working, scale: .inline)
                Text("Sending response…")
            }
        } else if let expiresAt = request.expiresAt {
            Label(Self.remaining(until: expiresAt, from: date), systemImage: "clock")
                .foregroundStyle(theme.secondaryText)
                .accessibilityIdentifier(accessibilityIdentifiers.countdown)
        } else {
            Text("Awaiting your response")
                .foregroundStyle(theme.secondaryText)
        }
    }

    fileprivate static func remaining(until expiry: Date, from date: Date) -> String {
        let remaining = max(0, Int(expiry.timeIntervalSince(date)))
        let hours = remaining / 3_600
        let minutes = (remaining % 3_600) / 60
        let seconds = remaining % 60
        if hours > 0 { return "Expires in \(hours)h \(minutes)m" }
        if minutes > 0 { return "Expires in \(minutes)m \(seconds)s" }
        return "Expires in \(seconds)s"
    }

    @BighelpThemeReader private var theme

}

struct DashboardClarificationAccessibilityIdentifiers: Equatable, Sendable {
    let prefix: String

    func card(itemID: String) -> String {
        identifier("card.\(itemID)")
    }

    func choice(_ choice: String) -> String {
        identifier("choice.\(choice)")
    }

    func question(_ index: Int) -> String {
        identifier("question.\(index)")
    }

    func choice(questionIndex: Int, choiceIndex: Int) -> String {
        identifier("question.\(questionIndex).choice.\(choiceIndex)")
    }

    var sendSelected: String { identifier("send-selected") }
    var customResponse: String { identifier("custom-response") }
    var submitCustom: String { identifier("submit-custom") }
    var done: String { identifier("done") }
    var expired: String { identifier("expired") }
    var countdown: String { identifier("countdown") }
    var fallbackMessage: String { identifier("fallback-message") }
    var retryCleanup: String { identifier("retry-cleanup") }

    private func identifier(_ component: String) -> String {
        "\(prefix).clarification.\(component)"
    }
}

enum ClarificationComposerLayout {
    static var inputMinimumHeight: CGFloat { BighelpTokens.hitTarget }

    static func leadingBalanceWidth(trailingControlWidth: CGFloat) -> CGFloat {
        max(0, trailingControlWidth)
    }
}

private struct DashboardApprovalAttentionCard: View {
    let itemID: String
    let title: String
    let detail: String
    let request: DashboardApprovalRequest
    let model: DashboardModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let isExpired = request.isExpired(at: context.date)
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                    Label("Needs your approval", systemImage: "exclamationmark.triangle.fill")
                        .bighelpFont(.sectionTitle)
                        .foregroundStyle(isExpired ? theme.tertiaryText : theme.warning)
                    Text(title)
                        .bighelpFont(.label)
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if detail != title {
                        Text(detail)
                            .bighelpFont(.body)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: BighelpTokens.space8) {
                        ForEach(request.allowedDecisions, id: \.self) { decision in
                            Button(role: decision == .deny ? .destructive : nil) {
                                Task {
                                    await model.respondToApproval(
                                        itemID: itemID,
                                        decision: decision
                                    )
                                }
                            } label: {
                                Text(decision.buttonTitle)
                                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                            }
                            .buttonStyle(.bordered)
                            .tint(decision == .deny ? theme.danger : theme.action)
                            .disabled(isExpired || isResolving)
                            .accessibilityHint(decision.accessibilityHint)
                            .accessibilityIdentifier(
                                "dashboard.approval.\(decision.rawValue)"
                            )
                        }
                    }
                    if isExpired {
                        Label("Expired", systemImage: "clock.badge.xmark")
                            .foregroundStyle(theme.tertiaryText)
                            .accessibilityIdentifier("dashboard.approval.expired")
                    } else if isResolving {
                        HStack(spacing: BighelpTokens.space8) {
                            BighelpThinkingOrb(scenario: .working, scale: .inline)
                            Text("Submitting decision…")
                        }
                    } else {
                        Text(DashboardClarificationAttentionCard.remaining(
                            until: request.expiresAt,
                            from: context.date
                        ))
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                    }
                    Text("Review this request before choosing a decision.")
                        .bighelpFont(.metadata)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            .padding(BighelpTokens.space16)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: BighelpTokens.radius16))
            .overlay {
                RoundedRectangle(cornerRadius: BighelpTokens.radius16)
                    .stroke(Color(uiColor: .separator), lineWidth: BighelpTokens.hairline)
            }
            .opacity(isExpired ? 0.68 : 1)
        }
        .accessibilityIdentifier("dashboard.approval.card.\(itemID)")
    }

    private var isResolving: Bool {
        model.resolvingAttentionIDs.contains(itemID)
    }

    @BighelpThemeReader private var theme

}

private struct DashboardInboxUpdateCanvas: View {
    let item: DashboardInboxItem
    let onStartChat: () -> Void
    let onDelete: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space20) {
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        Text(item.title)
                            .bighelpFont(.screenTitle)
                            .foregroundStyle(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("dashboard.update.canvas.title")
                        Text("From \(item.agentName) · \(item.status)")
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.tertiaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if item.cardEnvelope != nil {
                        cardContent
                    } else {
                        BighelpCard {
                            MarkdownMessageView(document: MarkdownDocument(item.detail))
                                .bighelpFont(.body)
                                .foregroundStyle(theme.primaryText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("dashboard.update.canvas.content")
                        }
                    }

                    Button("Start a chat about this", systemImage: "bubble.left.and.bubble.right") {
                        dismiss()
                        onStartChat()
                    }
                    .bighelpProminentButtonStyle()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("dashboard.update.canvas.start-chat")
                }
                .padding(BighelpTokens.space20)
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Agent Update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        dismiss()
                        onDelete()
                    }
                    .accessibilityIdentifier("dashboard.update.canvas.delete")
                }
            }
        }
        .accessibilityIdentifier("dashboard.update.canvas.\(item.id)")
    }

    @ViewBuilder
    private var cardContent: some View {
        switch item.cardEnvelope {
        case .legacy(let card): GenerativeUICardView(card: card)
        case .card(let card): BighelpCardView(card: card)
        case nil: EmptyView()
        }
    }

    @BighelpThemeReader private var theme

    @Environment(\.dismiss) private var dismiss
}

private struct DashboardSwipeToRemoveModifier: ViewModifier {
    let opensOnTap: Bool
    let onOpen: () -> Void
    let onRemove: () -> Void

    func body(content: Content) -> some View {
        Group {
            if opensOnTap {
                Button(action: onOpen) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityAction(named: Text("Delete"), onRemove)
    }
}

#Preview("Dashboard") {
    DashboardView(model: DashboardModel(source: DashboardFixtureSource()))
}

#Preview("Dashboard - Accessibility Extra Large") {
    DashboardView(model: DashboardModel(source: DashboardFixtureSource()))
        .dynamicTypeSize(.accessibility3)
}
