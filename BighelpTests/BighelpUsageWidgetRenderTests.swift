import SwiftUI
import Testing
import UIKit
import WidgetKit
@testable import Bighelp

/// Every Usage widget size and style, drawn with made-up plans in each state
/// (plenty left, near a limit, a limit used up, hours-old numbers, nothing read
/// yet) in light, dark, tinted and clear looks, plus the Lock Screen. Each size
/// and look is one sheet: a row per state, a column per style.
/// BIGHELP_WIDGET_RENDER_DIR (TEST_RUNNER_…) names a folder for the sheets.
/// These are fixture renders, not WidgetKit or installed-widget evidence: the
/// tinted and clear looks stand in for the system's own tinting.
@MainActor
struct BighelpUsageWidgetRenderTests {
    typealias Plan = BighelpUsageSnapshot.Plan

    enum Look: String, CaseIterable {
        case light, dark, tinted, clear
    }

    static let small = CGSize(width: 170, height: 170)
    static let medium = CGSize(width: 364, height: 170)
    static let large = CGSize(width: 364, height: 382)
    static let extraLarge = CGSize(width: 715, height: 342)

    @Test func everyStyleRendersInEveryLookAndState() throws {
        let families: [(String, WidgetFamily, CGSize, [(String, UsageWidgetStyles)])] = [
            ("small", .systemSmall, Self.small, [
                ("Ring", .init(small: .ring)), ("Two meters", .init(small: .twoMeters)),
                ("What's left", .init(small: .whatsLeft)), ("Four plans", .init(small: .fourPlans)),
                ("Closest", .init(small: .closest)), ("Cost", .init(small: .spending)),
            ]),
            ("medium", .systemMedium, Self.medium, [
                ("One plan", .init(medium: .onePlan)), ("Every plan", .init(medium: .everyPlan)),
                ("Next resets", .init(medium: .nextResets)), ("Side by side", .init(medium: .sideBySide)),
                ("Cost", .init(medium: .spending)),
            ]),
            ("large", .systemLarge, Self.large, [
                ("Every plan", .init(large: .everyPlan)), ("One plan", .init(large: .onePlan)),
                ("Cost", .init(large: .spending)),
            ]),
            ("xl", .systemExtraLarge, Self.extraLarge, [("Columns", .init())]),
        ]
        for (name, family, size, styles) in families {
            for look in Look.allCases {
                try sheet("usage-\(name)-\(look.rawValue)", family: family, size: size, styles: styles, look: look,
                          states: Self.states, text: .large)
            }
            try sheet("usage-\(name)-xxxl", family: family, size: size, styles: styles, look: .light,
                      states: Array(Self.states.prefix(3)), text: .xxxLarge)
        }
    }

    @Test func lockScreenAccessoriesRender() throws {
        let views: [(String, WidgetFamily, CGSize, UsageWidgetStyles)] = [
            ("Inline", .accessoryInline, .init(width: 250, height: 26), .init()),
            ("Circular", .accessoryCircular, .init(width: 76, height: 76), .init()),
            ("One plan", .accessoryRectangular, .init(width: 172, height: 76), .init(lock: .onePlan)),
            ("Every plan", .accessoryRectangular, .init(width: 172, height: 76), .init(lock: .everyPlan)),
            ("Next reset", .accessoryRectangular, .init(width: 172, height: 76), .init(lock: .nextReset)),
        ]
        let palette = BighelpWidgetSnapshot.preview
        let colors = BighelpWidgetColors(snapshot: palette, scheme: .dark, isFullColor: false)
        let content = VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(Self.states.enumerated()), id: \.offset) { _, state in
                VStack(alignment: .leading, spacing: 6) {
                    Text(state.name).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                    HStack(alignment: .center, spacing: 18) {
                        ForEach(Array(views.enumerated()), id: \.offset) { _, view in
                            BighelpUsageWidgetView(entry: entry(state, styles: view.3, planID: state.planID),
                                                   familyOverride: view.1)
                                .frame(width: view.2.width, height: view.2.height)
                                .environment(\.bighelpWidgetColors, colors)
                                .environment(\.colorScheme, .dark)
                                .environment(\.widgetRenderingMode, .vibrant)
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
        }
        .padding(24)
        .background(Self.wallpaper)
        .environment(\.colorScheme, .dark)
        try write(content, name: "usage-lockscreen")
    }

    // MARK: Sheets

    private func sheet(_ name: String, family: WidgetFamily, size: CGSize, styles: [(String, UsageWidgetStyles)],
                       look: Look, states: [State], text: DynamicTypeSize) throws {
        let palette = BighelpWidgetSnapshot.preview
        let scheme: ColorScheme = look == .light ? .light : .dark
        let colors = BighelpWidgetColors(snapshot: palette, scheme: scheme, isFullColor: look == .light || look == .dark)
        let label: Color = look == .light ? .black.opacity(0.6) : .white.opacity(0.7)
        let content = VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                ForEach(Array(styles.enumerated()), id: \.offset) { _, style in
                    Text(style.0).font(.caption.weight(.semibold)).foregroundStyle(label).frame(width: size.width, alignment: .leading)
                }
            }
            .padding(.leading, 96)
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                HStack(spacing: 16) {
                    Text(state.name).font(.caption.weight(.semibold)).foregroundStyle(label).frame(width: 80, alignment: .leading)
                    ForEach(Array(styles.enumerated()), id: \.offset) { _, style in
                        widget(entry(state, styles: style.1, planID: state.planID), family: family, size: size,
                               colors: colors, look: look, text: text)
                    }
                }
            }
        }
        .padding(24)
        .background(look == .light ? AnyView(Color(white: 0.9)) : look == .dark ? AnyView(Color.black) : AnyView(Self.wallpaper))
        try write(content, name: name)
    }

    private func widget(_ entry: UsageWidgetEntry, family: WidgetFamily, size: CGSize, colors: BighelpWidgetColors,
                        look: Look, text: DynamicTypeSize) -> some View {
        let scheme: ColorScheme = look == .light ? .light : .dark
        return BighelpUsageWidgetView(entry: entry, familyOverride: family)
            .padding(16)
            .frame(width: size.width, height: size.height)
            .environment(\.bighelpWidgetColors, colors)
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, text)
            .environment(\.widgetRenderingMode, look == .light || look == .dark ? .fullColor : .accented)
            .environment(\.usageWidgetTintPreview, look == .tinted ? Color(red: 1, green: 0.74, blue: 0.5) : look == .clear ? .white : nil)
            .foregroundStyle(colors.primary)
            .background {
                switch look {
                case .light, .dark: colors.canvas
                case .tinted: Color(red: 0.2, green: 0.13, blue: 0.09).opacity(0.82)
                case .clear: Color.white.opacity(0.1)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(look == .clear ? 0.3 : 0), lineWidth: 1))
            .clipShape(.rect(cornerRadius: 22))
    }

    private func write(_ view: some View, name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.uiImage, "\(name) did not render")
        #expect(image.size.width > 100 && image.size.height > 100)
        let data = try #require(image.pngData())
        if let out = ProcessInfo.processInfo.environment["BIGHELP_WIDGET_RENDER_DIR"].map(URL.init(fileURLWithPath:)) {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try data.write(to: out.appendingPathComponent("\(name).png"))
        }
    }

    static let wallpaper = LinearGradient(colors: [Color(red: 0.55, green: 0.3, blue: 0.18), Color(red: 0.12, green: 0.16, blue: 0.3),
                                                   Color(red: 0.25, green: 0.14, blue: 0.3)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Made-up data

    struct State {
        let name: String
        let snapshot: BighelpUsageSnapshot
        var planID: String? = nil
    }

    /// Now, to the minute: a used-up limit's countdown reads the real clock.
    static let now = Date(timeIntervalSinceReferenceDate: (Date.now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)

    static func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    /// The next Monday at 9 AM.
    static let monday: Date = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2),
                                                        matchingPolicy: .nextTime) ?? at(241_200)

    static func plans(sessionUsed: Double = 62) -> [Plan] {
        [
            Plan(id: "claude", name: "Claude", plan: "Max 20x", limits: [
                .init(label: "Session (5 hours)", leftPercent: 100 - sessionUsed, resetsAt: at(5_280)),
                .init(label: "Week", leftPercent: 59, resetsAt: monday),
                .init(label: "Sonnet week", leftPercent: 82, resetsAt: monday),
            ], facts: [.init(label: "Extra usage", value: "$4.20")], inUse: true, logo: "ProviderLogoClaude", tint: "D97757"),
            Plan(id: "codex", name: "Codex", plan: "Pro", limits: [
                .init(label: "Session (5 hours)", leftPercent: 77, resetsAt: at(9_780)),
                .init(label: "Week", leftPercent: 27, resetsAt: at(165_600)),
            ], logo: "ProviderLogoCodex", tint: "6A7DFF"),
            Plan(id: "gemini", name: "Gemini", plan: "AI Pro", limits: [
                .init(label: "Day", leftPercent: 77, resetsAt: at(42_480)),
            ], logo: "ProviderLogoGoogle", tint: "3186FF"),
            Plan(id: "copilot", name: "Copilot", plan: "Pro+", limits: [
                .init(label: "Premium requests", leftPercent: 19.2, resetsAt: at(17_280), detail: "1,212 of 1,500 used"),
            ], logo: "ProviderLogoGitHubCopilot", tint: "8957E5"),
            Plan(id: "openrouter", name: "OpenRouter", facts: [.init(label: "Balance", value: "$18.40")],
                 logo: "ProviderLogoOpenRouter", tint: "6467F2"),
        ]
    }

    static func usage(_ plans: [Plan]?, generated: Date = now) -> BighelpUsageSnapshot {
        var snapshot = UsageWidgetEntry.preview.snapshot
        snapshot.plans = plans
        snapshot.generatedAt = generated
        return snapshot
    }

    static let states: [State] = {
        var stale = plans()
        stale[0].limits[0] = .init(label: "Session (5 hours)", leftPercent: 4, resetsAt: at(-600))
        var update = usage(nil)
        update.plansNote = "Update the bighelp plugin on your computer to see plans and limits."
        return [
            State(name: "Plenty left", snapshot: usage(plans())),
            State(name: "Near a limit", snapshot: usage(plans(sessionUsed: 86))),
            State(name: "Limit reached", snapshot: usage(plans(sessionUsed: 100))),
            State(name: "Hours old", snapshot: usage(stale, generated: at(-5 * 3_600))),
            State(name: "One plan", snapshot: usage(Array(plans().prefix(1)))),
            State(name: "Picked: Copilot", snapshot: usage(plans()), planID: "copilot"),
            State(name: "No plans", snapshot: usage([])),
            State(name: "Old plugin", snapshot: update),
            State(name: "Nothing read", snapshot: .empty),
        ]
    }()

    private func entry(_ state: State, styles: UsageWidgetStyles, planID: String?) -> UsageWidgetEntry {
        UsageWidgetEntry(date: Self.now, snapshot: state.snapshot, palette: .preview, styles: styles, planID: planID)
    }
}
