import SwiftUI

/// The runs of one computer, filtered. Asks the host every 15 seconds while on screen.
@MainActor
@Observable
final class WorkflowRunListModel {
    private(set) var runs: [WorkflowRunSummary] = []
    private(set) var counts: [WorkflowRunFilter: Int] = [:]
    private(set) var state: WorkflowsLoadState = .idle
    var filter: WorkflowRunFilter = .all {
        didSet { if filter != oldValue { Task { await load() } } }
    }
    let client: any WorkflowsClient
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(client: any WorkflowsClient) {
        self.client = client
    }

    func setOnScreen(_ onScreen: Bool) {
        pollTask?.cancel()
        pollTask = nil
        guard onScreen else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.load()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func load() async {
        if runs.isEmpty { state = .loading }
        do {
            let page = try await client.runs(workflowID: nil, filter: filter, before: nil, limit: 50)
            runs = page.runs
            state = .loaded
            for other in WorkflowRunFilter.allCases where other != .all {
                counts[other] = other == filter ? page.runs.count
                    : (try? await client.runs(workflowID: nil, filter: other, before: nil, limit: 50))?.runs.count
            }
        } catch is CancellationError {
            return
        } catch {
            state = WorkflowsLoadState.from(error, hasContent: !runs.isEmpty)
        }
    }
}

/// All runs. At regular width (the Mac's monitor): runs with filters, the
/// selected run with its stage rail, and an inspector with what waits for you,
/// the events and the workflow service. Narrow: the list, opening each run.
struct WorkflowRunMonitorView: View {
    let context: WorkflowsContext
    @State private var list: WorkflowRunListModel
    @State private var selected: String?
    @State private var runModel: WorkflowRunModel?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @BighelpThemeReader private var theme

    init(context: WorkflowsContext, selected: String?) {
        self.context = context
        _list = State(initialValue: WorkflowRunListModel(client: context.client))
        _selected = State(initialValue: selected)
    }

    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        GeometryReader { proxy in
            if isWide, proxy.size.width >= 900 {
                HStack(spacing: 0) {
                    BighelpDeferredSection { runsColumn }
                        .frame(width: 300)
                    Divider().overlay(theme.separator)
                    BighelpDeferredSection { detailColumn }
                        .frame(maxWidth: .infinity)
                    Divider().overlay(theme.separator)
                    BighelpDeferredSection { inspectorColumn }
                        .frame(width: 340)
                }
            } else if isWide {
                HStack(spacing: 0) {
                    BighelpDeferredSection { runsColumn }
                        .frame(width: 300)
                    Divider().overlay(theme.separator)
                    BighelpDeferredSection { detailColumn }
                }
            } else {
                runsColumn
            }
        }
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflows.monitor")
        .navigationTitle("Runs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // One line: a long computer name shortens in the middle instead of wrapping.
                HStack(spacing: BighelpTokens.space4) {
                    Circle().fill(serviceColor).frame(width: 8, height: 8)
                    Text(context.store.status?.hostName ?? context.hostName)
                        .font(.bighelp(.footnote).weight(.medium))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, BighelpTokens.space4)
                .frame(maxWidth: isWide ? 260 : 132)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("workflows.monitor.host")
            }
        }
        .onAppear {
            list.setOnScreen(true)
            if context.store.status == nil { Task { await context.store.load() } }
            if isWide { select(selected) }
        }
        .onDisappear {
            list.setOnScreen(false)
            runModel?.setOnScreen(false)
        }
        .onChange(of: list.runs) { _, runs in
            // Start on the run that's doing something, as the design does.
            if isWide, selected == nil,
               let first = runs.first(where: { [.running, .checkingOutput, .launched].contains($0.state) }) ?? runs.first {
                select(first.id)
            }
        }
    }

    private var serviceColor: Color {
        switch context.store.status?.coordinator {
        case .online?: theme.success
        case .starting?: theme.warning
        case .offline?: theme.danger
        default: theme.tertiaryText
        }
    }

    private func select(_ id: String?) {
        guard let id else { return }
        if !isWide {
            context.open(.workflowRun(id: id))
            return
        }
        selected = id
        guard runModel?.runID != id else { return }
        runModel?.setOnScreen(false)
        let model = WorkflowRunModel(runID: id, client: context.client)
        runModel = model
        model.setOnScreen(true)
    }

    // MARK: Runs

    private var runsColumn: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            WorkflowFlowLayout(spacing: BighelpTokens.space8) {
                    ForEach(WorkflowRunFilter.allCases) { filter in
                        let count = list.counts[filter]
                        Button {
                            list.filter = filter
                        } label: {
                            Text(count.map { "\(filter.title) \($0)" } ?? filter.title)
                                .font(.bighelp(.footnote).weight(.semibold))
                                .foregroundStyle(list.filter == filter ? theme.canvas : theme.primaryText)
                                .padding(.horizontal, BighelpTokens.space12)
                                .frame(minHeight: BighelpPlatform.isMac ? 30 : BighelpTokens.hitTarget - 12)
                                .background(list.filter == filter ? theme.primaryText : theme.surface, in: Capsule())
                                .overlay(Capsule().strokeBorder(theme.border))
                                .contentShape(Capsule())
                        }
                        .bighelpPlainButtonStyle()
                        .accessibilityAddTraits(list.filter == filter ? .isSelected : [])
                        .accessibilityIdentifier("workflows.monitor.filter.\(filter.rawValue)")
                    }
            }
            .padding(.horizontal, BighelpTokens.space16)
            if list.runs.isEmpty, list.state != .loaded {
                WorkflowLoadStateView(state: list.state) { Task { await list.load() } }
            } else if list.runs.isEmpty {
                Text("No runs here.")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, BighelpTokens.space16)
            }
            ScrollView {
                LazyVStack(spacing: BighelpTokens.space4) {
                    ForEach(list.runs) { run in
                        WorkflowRunRow(run: run, isSelected: isWide && run.id == selected) { select(run.id) }
                            .padding(.horizontal, BighelpTokens.space12)
                            .clipShape(RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous))
                            .contextMenu { runMenu(run) }
                    }
                }
                .padding(.horizontal, BighelpTokens.space4)
            }
            .refreshable { await list.load() }
        }
        .padding(.top, BighelpTokens.space12)
    }

    @ViewBuilder
    private func runMenu(_ run: WorkflowRunSummary) -> some View {
        Button("Open", systemImage: "arrow.right.circle") { select(run.id) }
        if run.state == .waitingForYou {
            Button("Review", systemImage: "doc.text.magnifyingglass") { context.open(.workflowSignoff(runID: run.id)) }
        }
        if [.needsAttention, .failed].contains(run.state) {
            Button("Try again", systemImage: "arrow.clockwise") { control(run, .retry) }
        }
        if !run.state.isFinished {
            Button("Cancel run", systemImage: "stop.circle", role: .destructive) { control(run, .cancel) }
        }
    }

    private func control(_ run: WorkflowRunSummary, _ action: WorkflowRunAction) {
        Task {
            _ = try? await context.client.control(runID: run.id, action: action, expectedVersion: run.version)
            await list.load()
            await runModel?.load()
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detailColumn: some View {
        if let runModel, let detail = runModel.detail {
            ScrollView {
                WorkflowRunContent(model: runModel, context: context, detail: detail, showsGraph: true)
                    .padding(BighelpTokens.space20)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .topTrailing) {
                if let updated = runModel.updatedAt, detail.summary.state.isWorking {
                    Text("Updated \(WorkflowWords.ago(updated)) ago")
                        .font(.bighelp(.caption))
                        .foregroundStyle(theme.secondaryText)
                        .padding(BighelpTokens.space8)
                }
            }
        } else if let runModel {
            WorkflowLoadStateView(state: runModel.state) { Task { await runModel.load() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Choose a run", systemImage: "list.bullet.rectangle")
        }
    }

    // MARK: Inspector

    private var inspectorColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                if !context.store.waiting.isEmpty {
                    Text("Waiting for you").font(.bighelp(.subheadline).weight(.semibold))
                    ForEach(context.store.waiting) { run in
                        HStack(spacing: BighelpTokens.space12) {
                            WorkflowStageIcon(kind: .signoff, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ready for your sign-off")
                                    .font(.bighelp(.subheadline).weight(.semibold))
                                Text("Run \(run.number)")
                                    .font(.bighelp(.caption))
                                    .foregroundStyle(theme.secondaryText)
                            }
                            Spacer(minLength: 0)
                            Button("Review") { context.open(.workflowSignoff(runID: run.id)) }
                                .workflowProminent(theme)
                                .accessibilityIdentifier("workflows.monitor.review")
                        }
                        .workflowCard(theme, padding: BighelpTokens.space12)
                    }
                }
                if context.isNerdMode, let events = runModel?.events, !events.isEmpty {
                    HStack {
                        Text("Events").font(.bighelp(.subheadline).weight(.semibold))
                        Spacer()
                        Text("newest first").font(.bighelp(.caption)).foregroundStyle(theme.secondaryText)
                    }
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        ForEach(events.suffix(40).reversed()) { event in
                            HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                                Text(event.at?.formatted(date: .omitted, time: .standard) ?? "")
                                    .font(.bighelp(.caption).monospacedDigit())
                                    .foregroundStyle(theme.tertiaryText)
                                Text(event.text).font(.bighelp(.caption))
                            }
                        }
                    }
                    .workflowCard(theme, padding: BighelpTokens.space12)
                    .accessibilityIdentifier("workflows.monitor.events")
                }
                serviceCard
            }
            .padding(BighelpTokens.space16)
        }
        .background(theme.surface.opacity(0.4))
    }

    private var serviceCard: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack {
                Image(systemName: "server.rack")
                Text(context.store.status?.hostName ?? context.hostName)
                    .font(.bighelp(.subheadline).monospaced())
                Spacer()
                Text(serviceTitle)
                    .font(.bighelp(.caption))
                    .foregroundStyle(serviceColor)
            }
            if let status = context.store.status {
                if context.isNerdMode, let heartbeat = status.heartbeatAt {
                    LabeledContent("Heartbeat", value: "\(WorkflowWords.ago(heartbeat)) ago")
                }
                if context.isNerdMode, let epoch = status.epoch {
                    LabeledContent("Epoch", value: "\(epoch)")
                }
                LabeledContent("Workflow slots in use", value: "\(status.slotsUsed) of \(status.slotsTotal)")
                LabeledContent("Runs keep going when you close the app", value: status.survivesAppClose ? "Yes" : "No")
                if status.runnerMode == .text {
                    // Older Hermes gives only the reply at the end: no live lines, no token counts.
                    Text("Stages report only when they end. Update Hermes on this computer to follow them live.")
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("workflows.monitor.text-runner")
                }
            }
        }
        .font(.bighelp(.footnote))
        .workflowCard(theme, padding: BighelpTokens.space12)
        .accessibilityIdentifier("workflows.monitor.service")
    }

    private var serviceTitle: String {
        switch context.store.status?.coordinator {
        case .online?: "Workflows on"
        case .starting?: "Starting"
        case .offline?: "Off"
        default: ""
        }
    }
}
