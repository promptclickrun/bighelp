import Foundation
import WidgetKit

/// Keeps the Usage widget's snapshot current while bighelp is open: the last 30
/// days from Hermes and the plans the plugin found. Reads only when a Usage
/// widget is on the Home Screen, at most every 15 minutes, and keeps the last
/// numbers when a read fails.
@MainActor
enum UsageWidgetPublisher {
    static let days = 30
    static let interval: Duration = .seconds(15 * 60)

    private static var lastRead: ContinuousClock.Instant?
    private static var lastScope: AnyHashable?
    private static var pending: Task<Void, Never>?

    /// Reads and saves. Another computer or sign-in starts over.
    static func refresh(reader: (any UsageReading)?, plans: (any ProviderUsageClient)?, agentID: String,
                        scope: AnyHashable?, hidden: Set<String> = currentHidden(), force: Bool = false) async {
        guard let scope else {
            lastScope = nil
            lastRead = nil
            clear()
            return
        }
        var snapshot = BighelpUsageSnapshot.load()
        if scope != lastScope {
            lastScope = scope
            lastRead = nil
            snapshot = .empty
        }
        if !force, let last = lastRead, ContinuousClock.now - last < interval { return }
        lastRead = .now
        if let reader {
            let hosts = await reader.read(days: days, refresh: false)
            if hosts.contains(where: { $0.failure == nil }) {
                apply(UsageSummary(hosts: hosts, days: days), to: &snapshot)
            }
        }
        if let plans {
            do {
                let report = try await plans.usage(agentID: agentID, refresh: false)
                snapshot.plans = Self.plans(report, hidden: hidden)
                snapshot.plansNote = nil
            } catch WorkspaceClientError.unavailable(.unsupportedOperation), WorkspaceClientError.unavailable(.pluginRequired) {
                snapshot.plans = nil
                snapshot.plansNote = "Update the bighelp plugin on your computer to see plans and limits."
            } catch {
                // Keep the last plans on the widget.
            }
        }
        guard !Task.isCancelled, scope == lastScope else { return }
        snapshot.generatedAt = .now
        write(snapshot)
    }

    /// A signed-out or switched computer must not leave its numbers on the Home Screen.
    static func clear() {
        write(.empty)
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
                    note: note(provider), inUse: provider.activeInHermes)
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

    static func currentHidden() -> Set<String> {
        ProviderUsagePreferences.hidden(UserDefaults.standard.string(forKey: ProviderUsagePreferences.hiddenKey) ?? "")
    }

    /// Whether a Usage widget is on this device's Home Screen or Lock Screen.
    static func isInstalled() async -> Bool {
        await BighelpWidgetInstalls.contains(kind: BighelpUsageSnapshot.kind)
    }

    private static func write(_ snapshot: BighelpUsageSnapshot) {
        var previous = BighelpUsageSnapshot.load()
        previous.generatedAt = snapshot.generatedAt
        guard previous != snapshot || snapshot.generatedAt == .distantPast else { return }
        try? snapshot.save()
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadTimelines(ofKind: BighelpUsageSnapshot.kind)
        }
    }

    private static func clip(_ value: String, _ limit: Int) -> String {
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit - 1)) + "…"
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
