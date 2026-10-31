import Foundation
import WidgetKit

/// Keeps the Usage widgets' numbers current: the last 30 days from Hermes and the plans the plugin
/// found, for each gateway a Usage widget on this device shows (the one in use, or the one it's set
/// to). It reads while bighelp is open, at most every 15 minutes a gateway, and when iOS wakes
/// bighelp in the background (`BighelpWidgetBackgroundRefresh`). A read that fails keeps the
/// numbers the widget shows, and the next chance (a reconnect, coming back) reads again.
@MainActor
enum UsageWidgetPublisher {
    static let days = 30
    static let interval: Duration = .seconds(15 * 60)

    /// Where the numbers come from.
    struct Sources {
        /// The gateway in use: its ID in bighelp. Nil in the demo.
        let inUseID: @MainActor () -> String?
        /// The gateway in use, with its plans, over the app's own connection.
        let readInUse: @MainActor () async -> HostUsage
        /// Every other gateway, each over its own saved sign-in.
        let others: (any FleetHostReading)?
    }

    /// When each gateway was last read in full (nil: the demo's).
    private static var lastRead: [String?: ContinuousClock.Instant] = [:]
    private static var foreground: Task<Void, Never>?

    /// From the app's screen while it's open. The reads aren't the screen's: leaving bighelp doesn't
    /// cut them short, so even a quick visit fills the widgets. A newer start (a reconnect) takes
    /// over from one still reading over the connection before it.
    static func start(_ sources: Sources) {
        let previous = foreground
        previous?.cancel()
        foreground = Task {
            await previous?.value
            await refresh(sources)
        }
    }

    /// Reads each gateway the Usage widgets show that wasn't read in the last 15 minutes.
    /// `gateways`: what the widgets are set to, nil for the one in use; this device's widgets
    /// when left out.
    static func refresh(_ sources: Sources, gateways: [String?]? = nil,
                        directory: URL? = BighelpUsageSnapshot.directory) async {
        let shown: [String?]
        if let gateways { shown = gateways } else if let installed = await shownGateways() { shown = installed } else { return }
        let inUse = sources.inUseID()
        let wanted = shown.map { $0 ?? inUse }
        // The gateway in use first: it's connected already.
        let targets = ([inUse] + wanted).reduce(into: [String?]()) { list, id in
            if wanted.contains(id), !list.contains(id) { list.append(id) }
        }
        var wrote = false
        for id in targets {
            guard !Task.isCancelled else { break }
            if let last = lastRead[id], ContinuousClock.now - last < interval { continue }
            // From when the read started, so the next 15-minute tick reads again.
            let started = ContinuousClock.now
            let host: HostUsage
            if id == inUse {
                host = await sources.readInUse()
                // Switched while it read: those numbers may be the next gateway's.
                guard sources.inUseID() == id else { continue }
            } else if let others = sources.others, let hostID = id.flatMap(UUID.init(uuidString:)) {
                host = await others.usage(hostID, name: "", days: days, refresh: false)
            } else {
                continue
            }
            guard !Task.isCancelled else { break }
            var snapshot = BighelpUsageSnapshot.load(gateway: id, in: directory)
            if apply(host, to: &snapshot, hidden: currentHidden()) { lastRead[id] = started }
            if save(snapshot, gateway: id, in: directory) { wrote = true }
        }
        if wrote { WidgetCenter.shared.reloadTimelines(ofKind: BighelpUsageSnapshot.kind) }
    }

    /// Puts what was read into `snapshot`; true when every part was. A part that couldn't be read
    /// keeps what the widget shows; with no numbers yet, the widget says why. Totals that miss an
    /// agent aren't the gateway's totals, so they count as not read.
    @discardableResult
    static func apply(_ host: HostUsage, to snapshot: inout BighelpUsageSnapshot, hidden: Set<String>) -> Bool {
        var read = false, complete = true
        if host.failure == nil, !host.agents.isEmpty, host.unreadAgents.isEmpty {
            apply(UsageSummary(hosts: [host], days: days), to: &snapshot)
            snapshot.note = nil
            read = true
        } else {
            complete = false
            let why = host.failure ?? (host.unreadAgents.isEmpty ? nil : "Couldn't read every agent's usage.")
            if snapshot.totals == nil, let why { snapshot.note = why }
        }
        switch host.limits {
        case .loaded(let report):
            snapshot.plans = plans(report, hidden: hidden)
            snapshot.plansNote = nil
            read = true
        case .needsPluginUpdate:
            snapshot.plans = nil
            snapshot.plansNote = "Update the bighelp plugin on your computer to see plans and limits."
            read = true
        case .unavailable:
            complete = false
        case nil:
            break
        }
        if read { snapshot.generatedAt = .now }
        return complete
    }

    static func apply(_ summary: UsageSummary, to snapshot: inout BighelpUsageSnapshot) {
        snapshot.days = days
        let totals = summary.totals
        snapshot.totals = .init(cost: totals.cost, billedCost: totals.billedCost, inputTokens: totals.inputTokens,
                                outputTokens: totals.outputTokens, cacheReadTokens: totals.cacheReadTokens,
                                sessions: totals.sessions)
        let useCost = summary.models.contains { $0.amount.cost > 0 }
        snapshot.models = summary.models
            .sorted { useCost ? $0.amount.cost > $1.amount.cost : $0.amount.tokens > $1.amount.tokens }
            .prefix(BighelpUsageSnapshot.maximumModels)
            .map { .init(id: $0.id, name: clip($0.title, 40), provider: $0.detail.map { clip($0, 40) },
                         cost: $0.amount.cost, tokens: $0.amount.tokens) }
        snapshot.daily = summary.points.suffix(days).map { .init(date: $0.date, cost: $0.amount.cost, tokens: $0.amount.tokens) }
    }

    /// The plans Usage shows, in its order: the ones Hermes uses first, hidden ones left out.
    static func plans(_ report: ProviderUsageReport, hidden: Set<String>) -> [BighelpUsageSnapshot.Plan] {
        ProviderUsagePresentation.visible(report.providers, hidden: hidden)
            .prefix(BighelpUsageSnapshot.maximumPlans)
            .map { provider in
                BighelpUsageSnapshot.Plan(
                    id: provider.id, name: clip(provider.name, 40), plan: provider.plan.map { clip($0, 30) },
                    limits: provider.windows.prefix(4).map {
                        .init(label: clip($0.label, 40), leftPercent: max(0, min(100, $0.leftPercent)), resetsAt: $0.resetsAt)
                    },
                    facts: provider.facts.prefix(2).map { .init(label: clip($0.label, 30), value: clip($0.value, 30)) },
                    note: note(provider), inUse: provider.activeInHermes, key: ProviderUsagePreferences.key(for: provider.id))
            }
    }

    private static func note(_ provider: ProviderUsage) -> String? {
        switch provider.status {
        case .ok: nil
        case .signInNeeded: "Sign in needed on your computer"
        case .notShared: "This provider doesn't share usage"
        case .error: "Couldn't be read"
        }
    }

    /// A plan was given a name. The widgets put the names on themselves, so they only need drawing again.
    /// Files from before plans carried their key get one first, or the name would wait for the next read.
    static func namesChanged(directory: URL? = BighelpUsageSnapshot.directory) {
        let stem = String(BighelpUsageSnapshot.fileName.dropLast(".json".count))
        if let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names where name.hasPrefix(stem) && name.hasSuffix(".json") {
                let url = directory.appendingPathComponent(name, isDirectory: false)
                guard let data = try? Data(contentsOf: url), data.count <= 131_072,
                      var snapshot = try? JSONDecoder.bighelpWidget.decode(BighelpUsageSnapshot.self, from: data),
                      snapshot.plans?.contains(where: { $0.key == nil }) == true else { continue }
                snapshot.plans = snapshot.plans?.map { plan in
                    var plan = plan
                    plan.key = plan.key ?? ProviderUsagePreferences.key(for: plan.id)
                    return plan
                }
                try? JSONEncoder.bighelpWidget.encode(snapshot)
                    .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        WidgetCenter.shared.reloadTimelines(ofKind: BighelpUsageSnapshot.kind)
    }

    static func currentHidden() -> Set<String> {
        ProviderUsagePreferences.hidden(UserDefaults.standard.string(forKey: ProviderUsagePreferences.hiddenKey) ?? "")
    }

    /// The plans on a gateway, as the limits part of its usage.
    static func limits(_ plans: any ProviderUsageClient, agentID: String) async -> HostUsage.Limits {
        do {
            return .loaded(try await plans.usage(agentID: agentID, refresh: false))
        } catch WorkspaceClientError.unavailable(.unsupportedOperation), WorkspaceClientError.unavailable(.pluginRequired) {
            return .needsPluginUpdate
        } catch {
            return .unavailable(ProviderUsageStore.reason(error))
        }
    }

    /// What the Usage widgets on this device are set to, nil for the gateway in use; nil when there are none.
    static func shownGateways() async -> [String?]? {
        #if targetEnvironment(macCatalyst)
        nil
        #else
        // The async form needs iOS 18; this one reaches back to iOS 17.
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { @Sendable result in
                let widgets = ((try? result.get()) ?? []).filter { $0.kind == BighelpUsageSnapshot.kind }
                continuation.resume(returning: widgets.isEmpty ? nil
                    : widgets.map { $0.widgetConfigurationIntent(of: UsageWidgetIntent.self)?.gateway?.hostID })
            }
        }
        #endif
    }

    /// Writes a gateway's file when what it shows changed; true when it did.
    private static func save(_ snapshot: BighelpUsageSnapshot, gateway: String?, in directory: URL?) -> Bool {
        var previous = BighelpUsageSnapshot.load(gateway: gateway, in: directory)
        previous.generatedAt = snapshot.generatedAt
        guard previous != snapshot else { return false }
        return (try? snapshot.save(gateway: gateway, in: directory)) != nil
    }

    private static func clip(_ value: String, _ limit: Int) -> String {
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit - 1)) + "…"
    }
}

@MainActor
extension UsageWidgetPublisher.Sources {
    /// The gateway in use through `reader` and `plans`.
    init(inUseID: @escaping @MainActor () -> String?, reader: any UsageReading, plans: (any ProviderUsageClient)?,
         agentID: String, others: (any FleetHostReading)?) {
        self.init(inUseID: inUseID, readInUse: {
            var host = await reader.read(days: UsageWidgetPublisher.days, refresh: false).first
                ?? HostUsage(id: "", name: "")
            if let plans { host.limits = await UsageWidgetPublisher.limits(plans, agentID: agentID) }
            return host
        }, others: others)
    }

    /// A real gateway in use over `connections`, with `agents` its agents; the others through `fleet`.
    static func live(connections: WorkspaceConnectionStore, agents: AgentDirectoryStore, fleet: FleetStore?) -> Self {
        let workspace: @MainActor () -> (any WorkspaceOperationPerforming)? = { [weak connections] in connections?.workspace }
        let reader = LiveUsageReader(hostID: "", hostName: "", currentWorkspace: workspace, agents: { [weak agents] in
            agents?.profiles.map { ($0.id, $0.name) } ?? []
        }, fleet: nil)
        return Self(inUseID: { [weak connections] in connections?.hosts.selectedHostID?.uuidString }, reader: reader,
                    plans: DirectHermesProviderUsageClient(currentWorkspace: workspace),
                    agentID: agents.resolvedAgent(explicitID: nil)?.id ?? "default", others: fleet?.reader)
    }
}

/// Which widget kinds are on this device. Reads are skipped for widgets nobody added.
enum BighelpWidgetInstalls {
    static func contains(kind: String) async -> Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        // The async form needs iOS 18; this one reaches back to iOS 17.
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { @Sendable result in
                continuation.resume(returning: ((try? result.get()) ?? []).contains { $0.kind == kind })
            }
        }
        #endif
    }
}
