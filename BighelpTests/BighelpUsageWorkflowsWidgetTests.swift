import SwiftUI
import Testing
import UIKit
import WidgetKit
@testable import Bighelp

/// The Usage and Workflows widgets: what the app saves for them, the links
/// they open, and every layout drawn in the app's light and dark colors.
/// BIGHELP_WIDGET_RENDER_DIR (TEST_RUNNER_…) names a folder for the pictures.
@MainActor
struct BighelpUsageWorkflowsWidgetTests {
    // MARK: Workflows

    @Test func workflowsShowRunningRunsWithTheirStepNeedsYouFirst() {
        let list = WorkflowsList(workflows: [], waiting: [
            run("w", name: "Launch checklist", state: .waitingForYou, stage: "Approve the budget", done: 2, count: 3,
                waiting: .init(kind: "signoff", stageKey: "approve", since: .now)),
        ], active: [
            run("a", name: "Weekly newsletter", state: .running, stage: "Draft the issue", done: 1, count: 4,
                started: .now.addingTimeInterval(-60)),
            run("old", name: "Old run", state: .running, stage: "Collect", done: 0, count: 2,
                started: .now.addingTimeInterval(-3_600)),
            run("s", name: "Sample", state: .running, stage: "Try it", done: 0, count: 1, sample: true),
            run("f", name: "Finished", state: .succeeded, stage: nil, done: 3, count: 3),
        ])
        let snapshot = WorkflowsWidgetPublisher.snapshot(list)
        #expect(snapshot.isAvailable)
        #expect(snapshot.runs.map(\.id) == ["w", "a", "old"], "Waiting for you first, then newest; no samples or finished runs")
        let waiting = snapshot.runs[0]
        #expect(waiting.phase == .waitingForYou)
        #expect(waiting.stepLine == "Step 3 of 3")
        #expect(waiting.detail == "Waiting for your OK")
        let drafting = snapshot.runs[1]
        #expect(drafting.stepLine == "Step 2 of 4")
        #expect(drafting.step == "Draft the issue")
        #expect(drafting.detail == "Running")
        #expect(drafting.progress == 0.25)
    }

    @Test func aRunWithoutStepsSaysNoStepAndShowsNoProgress() {
        let snapshot = WorkflowsWidgetPublisher.snapshot(WorkflowsList(workflows: [], waiting: [], active: [
            run("x", name: "Quick", state: .launched, stage: nil, done: 0, count: 0),
        ]))
        #expect(snapshot.runs.first?.stepLine == nil)
        #expect(snapshot.runs.first?.progress == 0)
        #expect(snapshot.runs.first?.detail == "Starting")
    }

    @Test func staleSnapshotsSayHowOldTheyAre() {
        let snapshot = BighelpWorkflowsSnapshot(runs: [], isAvailable: true, generatedAt: .now.addingTimeInterval(-11 * 60))
        #expect(snapshot.isStale(at: .now))
        #expect(!BighelpWorkflowsSnapshot(runs: [], isAvailable: true, generatedAt: .now).isStale(at: .now))
    }

    // MARK: Usage

    @Test func usageKeepsTheLast30DaysAndTheTopFiveModels() {
        let hosts = [HostUsage(id: "home", name: "Home", agents: [
            AgentUsage(id: "juno", name: "Juno", report: UsageFixtures.report(seed: 3, days: 30)),
        ])]
        var snapshot = BighelpUsageSnapshot.empty
        UsageWidgetPublisher.apply(UsageSummary(hosts: hosts, days: 30), to: &snapshot)
        let totals = try? #require(snapshot.totals)
        #expect((totals?.tokens ?? 0) > 0)
        #expect(snapshot.daily.count == 30)
        #expect(snapshot.models.count <= BighelpUsageSnapshot.maximumModels)
        #expect(snapshot.models.map(\.cost) == snapshot.models.map(\.cost).sorted(by: >), "Most used first")
    }

    @Test func plansFollowUsageHidingAndPutTheOneInUseFirst() {
        func provider(_ id: String, inUse: Bool, used: Double) -> ProviderUsage {
            ProviderUsage(id: id, name: id.capitalized, status: .ok, message: nil, plan: "Pro", detectedVia: [],
                          activeInHermes: inUse,
                          windows: [.init(label: "Week", usedPercent: used, resetsAt: nil, detail: nil)],
                          facts: [], manageURL: nil, approximate: false)
        }
        let report = ProviderUsageReport(agentID: "default", fetchedAt: nil, cached: false, providers: [
            provider("openrouter", inUse: false, used: 10), provider("claude", inUse: true, used: 63),
            provider("deepseek", inUse: false, used: 5),
        ])
        let plans = UsageWidgetPublisher.plans(report, hidden: ["deepseek"])
        #expect(plans.map(\.id) == ["claude", "openrouter"])
        #expect(plans[0].tightest?.leftPercent == 37)
        #expect(plans[0].inUse)
    }

    @Test func usageNumbersReadShort() {
        #expect(UsageWidgetFormat.cost(598.84) == "$598.84")
        #expect(UsageWidgetFormat.tokens(96_600_000) == "96.6M")
        #expect(UsageWidgetFormat.percent(36.6) == "37%")
    }

    @Test func snapshotsSurviveTheTripToTheWidget() throws {
        let usage = UsageWidgetEntry.preview.snapshot
        let decoded = try JSONDecoder.bighelpWidget.decode(BighelpUsageSnapshot.self,
                                                          from: JSONEncoder.bighelpWidget.encode(usage))
        // Dates keep whole seconds on the way; everything else arrives as it left.
        #expect(decoded.plans?.map(\.id) == usage.plans?.map(\.id))
        #expect(decoded.plans?.first?.limits.map(\.leftPercent) == usage.plans?.first?.limits.map(\.leftPercent))
        #expect(decoded.totals == usage.totals && decoded.models == usage.models)
        #expect(decoded.daily.map(\.cost) == usage.daily.map(\.cost))
        let runs = WorkflowsWidgetEntry.preview.snapshot
        let back = try JSONDecoder.bighelpWidget.decode(BighelpWorkflowsSnapshot.self, from: JSONEncoder.bighelpWidget.encode(runs))
        #expect(back.runs.map(\.id) == runs.runs.map(\.id))
        #expect(back.runs.map(\.stepLine) == runs.runs.map(\.stepLine))
        #expect(back.runs.map(\.phase) == runs.runs.map(\.phase))
    }

    // MARK: Links

    @Test func widgetLinksOpenARunOrUsage() {
        #expect(BighelpIncomingURLRoute.parse(BighelpWorkflowsSnapshot.url(run: "run_8f2-a")) == .workflowRun(id: "run_8f2-a"))
        #expect(BighelpIncomingURLRoute.parse(BighelpWorkflowsSnapshot.url()) == .workflows)
        #expect(BighelpIncomingURLRoute.parse(BighelpUsageSnapshot.url) == .usage)
        #expect(BighelpIncomingURLRoute.parse(URL(string: "loopdy://workflow-run/a%20b")!) == nil)
        #expect(BighelpIncomingURLRoute.parse(URL(string: "loopdy://workflow-run/%C3%A9")!) == nil)
        #expect(BighelpIncomingURLRoute.parse(URL(string: "loopdy://workflow-run/a?x=1")!) == nil)
        #expect(BighelpIncomingURLRoute.parse(URL(string: "loopdy://workflow-run")!) == nil)
    }

    // MARK: Pictures

    @Test func everyLayoutRendersInBothModes() throws {
        let palette = BighelpWidgetSnapshot.preview
        let out = ProcessInfo.processInfo.environment["BIGHELP_WIDGET_RENDER_DIR"].map(URL.init(fileURLWithPath:))
        let families: [(String, WidgetFamily, CGSize)] = [("small", .systemSmall, .init(width: 170, height: 170)),
                                                          ("medium", .systemMedium, .init(width: 364, height: 170)),
                                                          ("large", .systemLarge, .init(width: 364, height: 382))]
        let emptyRuns = WorkflowsWidgetEntry(date: .now, snapshot: .init(runs: [], isAvailable: true, generatedAt: .now),
                                             palette: palette)
        for scheme in [ColorScheme.light, .dark] {
            let colors = BighelpWidgetColors(snapshot: palette, scheme: scheme, isFullColor: true)
            for (name, family, size) in families {
                var views: [(String, AnyView)] = [
                    ("workflows", AnyView(BighelpWorkflowsWidgetView(entry: WorkflowsWidgetEntry.preview, familyOverride: family))),
                    ("workflows-none", AnyView(BighelpWorkflowsWidgetView(entry: emptyRuns, familyOverride: family))),
                ]
                for content in [UsageWidgetContent.overview, .plans, .cost, .tokens, .models] {
                    let preview = UsageWidgetEntry.preview
                    let entry = UsageWidgetEntry(date: .now, snapshot: preview.snapshot, palette: palette,
                                                 content: content, planID: nil)
                    views.append(("usage-\(content.rawValue)",
                                  AnyView(BighelpUsageWidgetView(entry: entry, familyOverride: family))))
                }
                for (kind, view) in views {
                    let content = view
                        .padding(16)
                        .frame(width: size.width, height: size.height)
                        .environment(\.bighelpWidgetColors, colors)
                        .environment(\.colorScheme, scheme)
                        .foregroundStyle(colors.primary)
                        .background(colors.canvas)
                        .clipShape(.rect(cornerRadius: 22))
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 2
                    let image = try #require(renderer.uiImage, "\(kind) \(name) did not render")
                    #expect(image.size.width >= size.width && image.size.height >= size.height)
                    if let out, let data = image.pngData() {
                        try data.write(to: out.appendingPathComponent("widget-\(kind)-\(name)-\(scheme == .dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }

    private func run(_ id: String, name: String, state: WorkflowRunState, stage: String?, done: Int, count: Int,
                     started: Date = .now, sample: Bool = false,
                     waiting: WorkflowRunSummary.Waiting? = nil) -> WorkflowRunSummary {
        WorkflowRunSummary(id: id, number: 1, workflowID: "wf", workflowName: name, revision: 1, state: state,
                           stageKey: stage == nil ? nil : "stage", stageTitle: stage, stageState: state,
                           stagesDone: done, stageCount: count, startedAt: started, updatedAt: started,
                           waiting: waiting, version: 1, sample: sample)
    }
}
