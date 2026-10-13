import SwiftUI

/// Debug builds only: every loader in every state, opened with the launch
/// argument `-bighelp-loader-gallery`. Optional presets for screenshots:
/// `-bighelp-loader-gallery-section noodle|images|cards|hosts|activity|buttons|scroll`,
/// `-bighelp-loader-gallery-appearance light|dark`,
/// `-bighelp-loader-gallery-motion still|low-power|inactive` and
/// `-bighelp-loader-gallery-anchor "<panel title>"` (scrolls to that panel),
/// `-bighelp-loader-gallery-loading NO` (cards start loaded),
/// `-bighelp-loader-gallery-phase <phase>`, `-bighelp-loader-gallery-autocheck YES`
/// (runs a connection check: connecting, then connected after 2.6 s) and
/// `-bighelp-loader-gallery-autoscroll YES` (the scroll test scrolls itself while
/// the frame meter in the title bar counts late frames).
/// Everything shown is made-up demo data.
enum BighelpLoaderGallery {
    static let launchArgument = "-bighelp-loader-gallery"

    static var isRequested: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(launchArgument)
        #else
        false
        #endif
    }

    @MainActor @ViewBuilder
    static func rootView() -> some View {
        #if DEBUG
        BighelpLoaderGalleryView()
        #endif
    }
}

#if DEBUG
private enum GallerySection: String, CaseIterable, Identifiable {
    case noodle, images, cards, hosts, activity, buttons, scroll
    var id: Self { self }
    var title: String {
        switch self {
        case .noodle: "Noodle"
        case .images: "Images"
        case .cards: "Cards"
        case .hosts: "Hosts"
        case .activity: "Activity"
        case .buttons: "Buttons"
        case .scroll: "Scroll"
        }
    }
}

private enum GalleryAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
}

private enum GalleryMotion: String, CaseIterable, Identifiable {
    case automatic, still, lowPower = "low-power", inactive
    var id: Self { self }
    var title: String {
        switch self {
        case .automatic: "Live"
        case .still: "Reduce Motion"
        case .lowPower: "Low Power"
        case .inactive: "Inactive"
        }
    }
    var override: BighelpLoaderMotionOverride {
        switch self {
        case .automatic: .init()
        case .still: .init(reduceMotion: true)
        case .lowPower: .init(lowPowerMode: true)
        case .inactive: .init(sceneInactive: true)
        }
    }
}

private struct BighelpLoaderGalleryView: View {
    @State private var section = GallerySection(
        rawValue: UserDefaults.standard.string(forKey: "bighelp-loader-gallery-section") ?? "") ?? .noodle
    @State private var appearance = GalleryAppearance(
        rawValue: UserDefaults.standard.string(forKey: "bighelp-loader-gallery-appearance") ?? "") ?? .system
    @State private var motion = GalleryMotion(
        rawValue: UserDefaults.standard.string(forKey: "bighelp-loader-gallery-motion") ?? "") ?? .automatic

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: BighelpTokens.space24) {
                        controls
                        content
                    }
                    .padding(BighelpTokens.space16)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .task {
                    guard let anchor = UserDefaults.standard.string(forKey: "bighelp-loader-gallery-anchor") else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    reader.scrollTo(anchor, anchor: .top)
                }
                .task(id: section) {
                    guard section == .scroll, UserDefaults.standard.bool(forKey: "bighelp-loader-gallery-autoscroll") else { return }
                    try? await Task.sleep(for: .seconds(1))
                    while !Task.isCancelled {
                        for index in [9, 0] {
                            withAnimation(.easeInOut(duration: 2.5)) { reader.scrollTo("scroll-\(index)", anchor: .top) }
                            try? await Task.sleep(for: .seconds(3))
                        }
                    }
                }
            }
            .modifier(GalleryCanvas())
            .modifier(GalleryRootLook())
            .navigationTitle("Loaders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if section == .scroll {
                    ToolbarItem(placement: .topBarTrailing) { GalleryFrameMeterLabel() }
                }
            }
        }
        .environment(\.bighelpLoaderMotionOverride, motion.override)
        .preferredColorScheme(appearance.scheme)
        .accessibilityIdentifier("loader-gallery")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Picker("Section", selection: $section) {
                ForEach(GallerySection.allCases) { Text($0.title).tag($0) }
            }
            .bighelpSegmentedPicker()
            .accessibilityIdentifier("loader-gallery.section")
            HStack {
                Picker("Look", selection: $appearance) {
                    Text("System").tag(GalleryAppearance.system)
                    Text("Light").tag(GalleryAppearance.light)
                    Text("Dark").tag(GalleryAppearance.dark)
                }
                .accessibilityIdentifier("loader-gallery.appearance")
                Spacer()
                Picker("Motion", selection: $motion) {
                    ForEach(GalleryMotion.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("loader-gallery.motion")
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .noodle: GalleryNoodle()
        case .images: GalleryImages()
        case .cards: GalleryCards()
        case .hosts: GalleryHosts()
        case .activity: GalleryActivity()
        case .buttons: GalleryButtons()
        case .scroll: GalleryScrollTest()
        }
    }
}

/// Every brand-kit motion where the app plays it, and the chat's one-loader rule.
private struct GalleryNoodle: View {
    private static let uses: [(BighelpNoodleMotion, String)] = [
        (.loader, "Loading"), (.thinking, "Thinking"), (.listening, "Voice: listening"),
        (.talking, "Voice: talking"), (.resting, "Voice: paused"), (.launch, "Connecting"),
        (.spring, "Reconnecting"), (.lasso, "Searching"), (.infinity, "Helper agents"),
        (.squiggle, "Sending"), (.question, "Can't open a page"), (.exit, "Ending a call"),
        (.reveal, "First run"), (.hello, "After the reveal"), (.idle, "Empty places"),
        (.done, "Work finished"), (.heart, "Favorite model"), (.bunny, "Settings, three taps"),
        (.pull, "Pull to refresh"),
    ]
    @State private var focus = BighelpActivityLoaderFocus()

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space24) {
            GalleryPanel(title: "Wordmark") {
                BighelpWordmark(height: 44)
            }
            GalleryPanel(title: "Motions", note: "One-shots repeat here so you can watch them.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: BighelpTokens.space16)],
                          spacing: BighelpTokens.space20) {
                    ForEach(Self.uses, id: \.0) { motion, use in
                        VStack(spacing: BighelpTokens.space8) {
                            BighelpNoodleView(motion: motion, size: 44,
                                              playback: motion == .pull ? .progress(0.7) : .loop(pause: 0.8))
                                .frame(width: 64, height: 64)
                            Text(motion.rawValue).font(.bighelp(.footnote, weight: .semibold))
                            Text(use).font(.bighelp(.caption)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            GalleryPanel(title: "Chat: one loader", note: "Both folders are live; only the newest plays.") {
                VStack(alignment: .leading, spacing: 0) {
                    BighelpActivityRow(phase: .thinking, loaderID: "thinking")
                    BighelpActivityRow(phase: .working(BighelpToolActivityCatalog.fallback), loaderID: "work")
                }
                .environment(\.bighelpActivityLoaderFocus, focus)
                .onAppear { focus.activeID = "work" }
            }
        }
    }
}

/// The app's own root look (fixture screens skip the app's root), so loaders
/// are seen as they will be: text size, Vision Pro's ink, the lavender tint.
private struct GalleryRootLook: ViewModifier {
    @BighelpThemeReader private var theme
    func body(content: Content) -> some View {
        content
            .bighelpThemePresentation(theme)
            .modifier(BighelpTextSizing())
            #if os(visionOS)
            .modifier(BighelpVisionInk())
            #else
            .tint(Color.accentColor)
            #endif
    }
}

private struct GalleryCanvas: ViewModifier {
    @BighelpThemeReader private var theme
    func body(content: Content) -> some View {
        content.background(theme.canvas.ignoresSafeArea())
    }
}

/// A titled panel, like the design file's.
private struct GalleryPanel<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var content: () -> Content

    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack {
                Text(title).font(.bighelp(.footnote, weight: .semibold)).foregroundStyle(theme.secondaryText)
                Spacer()
                if let note {
                    Text(note).font(.bighelp(.caption, design: .monospaced)).foregroundStyle(theme.tertiaryText)
                }
            }
            content()
        }
        .padding(18)
        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.cardCornerRadius).strokeBorder(theme.border, lineWidth: 1)
        }
        .id(title)
    }
}

// MARK: Images

private struct GalleryImages: View {
    @State private var showsProgress = true
    @State private var progress = 0.34

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            GalleryPanel(title: "Glow", note: "1:1") {
                BighelpImageGeneratingView()
            }
            GalleryPanel(title: "Develop", note: "16:10") {
                BighelpImageGeneratingView(caption: progress < 0.6 ? "Sketching the layout" : "Adding the details",
                                           variant: .develop, aspectRatio: 16 / 10,
                                           progress: showsProgress ? progress : nil)
                Toggle("Real progress from the host", isOn: $showsProgress)
                    .font(.bighelp(.subheadline))
                    .accessibilityIdentifier("loader-gallery.progress-toggle")
                if showsProgress {
                    Slider(value: $progress, in: 0...1)
                        .accessibilityIdentifier("loader-gallery.progress")
                }
            }
            GalleryPanel(title: "Set of four", note: "compact") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(0..<4, id: \.self) { index in
                        BighelpImageGeneratingView(variant: index % 2 == 0 ? .glow : .develop, size: .compact,
                                                   phaseOffset: Double(index) * 1.3)
                    }
                }
                BighelpImageGeneratingCaption(text: "Making 4 versions", count: BighelpImageCount(completed: 2, total: 4))
            }
        }
    }
}

// MARK: Cards

private struct GalleryCards: View {
    @State private var isLoading = UserDefaults.standard.string(forKey: "bighelp-loader-gallery-loading") != "NO"
    @State private var assembleRun = 0
    @BighelpThemeReader private var theme

    private var weather: BighelpCardDocument { BighelpCardDemoFixtures.documents[2] }
    private var bitcoin: BighelpCardDocument { BighelpCardDemoFixtures.documents[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            Toggle("Loading", isOn: $isLoading)
                .font(.bighelp(.subheadline, weight: .semibold))
                .accessibilityIdentifier("loader-gallery.skeleton-toggle")
            GalleryPanel(title: "Real card, steady", note: "BighelpCardView") {
                cardHeader("Putting together the forecast")
                BighelpCardView(card: weather)
                    .bighelpSkeleton(isLoading: isLoading, accessibilityLabel: "Loading the forecast")
            }
            GalleryPanel(title: "Real card, assembles", note: "option") {
                cardHeader("Building the card")
                BighelpCardView(card: bitcoin)
                    .bighelpSkeleton(isLoading: isLoading, style: .assembles)
                    .id(assembleRun)
                Button("Replay") { assembleRun += 1 }
                    .font(.bighelp(.subheadline, weight: .semibold))
            }
            GalleryPanel(title: "Custom blocks", note: "BighelpSkeletonBlock") {
                VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                    BighelpSkeletonBlock(width: 120, height: 10)
                    ForEach(0..<3, id: \.self) { index in
                        HStack(spacing: 10) {
                            BighelpSkeletonBlock(width: 32, height: 32, cornerRadius: 9)
                            VStack(alignment: .leading, spacing: 7) {
                                BighelpSkeletonBlock(width: [170, 130, 150][index], height: 12)
                                BighelpSkeletonBlock(width: [90, 70, 110][index], height: 9)
                            }
                            Spacer()
                            BighelpSkeletonBlock(width: 44, height: 22, cornerRadius: 11)
                        }
                    }
                }
                .padding(14)
                .bighelpSkeleton(isLoading: true, accessibilityLabel: "Loading the list")
            }
        }
    }

    private func cardHeader(_ text: String) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            Image(BighelpGlyph.sparkles.assetName).resizable().renderingMode(.template).frame(width: 15, height: 15)
                .foregroundStyle(theme.action)
            Text(text).bighelpShimmer(isActive: isLoading)
        }
        .font(.bighelp(.subheadline, weight: .medium))
    }
}

// MARK: Hosts

private struct GalleryHosts: View {
    @State private var phase = BighelpConnectionPhase(
        rawValue: UserDefaults.standard.string(forKey: "bighelp-loader-gallery-phase") ?? "") ?? .connecting
    @State private var checkRun = 0
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            GalleryPanel(title: "Live check") {
                Picker("Phase", selection: $phase) {
                    ForEach(BighelpConnectionPhase.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .bighelpSegmentedPicker()
                .accessibilityIdentifier("loader-gallery.phase")
                BighelpConnectionLine(phase: phase, hostName: "Studio Mac", detail: detail(for: phase))
                    .padding(.vertical, BighelpTokens.space12)
                Button("Run a check (connects after 2.6 s)") {
                    phase = .connecting
                    checkRun += 1
                }
                .font(.bighelp(.subheadline, weight: .semibold))
                .accessibilityIdentifier("loader-gallery.run-check")
            }
            .task(id: checkRun) {
                if checkRun == 0, UserDefaults.standard.bool(forKey: "bighelp-loader-gallery-autocheck") {
                    phase = .connecting
                    checkRun = 1
                    return
                }
                guard checkRun > 0 else { return }
                try? await Task.sleep(for: .seconds(2.6))
                if !Task.isCancelled { phase = .connected }
            }
            GalleryPanel(title: "All states") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: BighelpTokens.space8, alignment: .leading)],
                          alignment: .leading, spacing: BighelpTokens.space8) {
                    ForEach(BighelpConnectionPhase.allCases, id: \.self) { BighelpConnectionPill(phase: $0) }
                }
                VStack(spacing: 0) {
                    hostRow("Studio Mac mini", .connected, detail(for: .connected))
                    Divider()
                    hostRow("Home server", .reconnecting, detail(for: .reconnecting))
                    Divider()
                    hostRow("Office laptop", .connecting, nil)
                    Divider()
                    hostRow("Old MacBook", .disconnected, BighelpConnectionDetail(message: "Hermes didn't answer."))
                }
                .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16))
                .overlay { RoundedRectangle(cornerRadius: BighelpTokens.radius16).strokeBorder(theme.border) }
                Text("Detail lines show only real values; \"Office laptop\" passes none.")
                    .font(.bighelp(.caption)).foregroundStyle(theme.tertiaryText)
            }
        }
    }

    /// Made-up host facts, as a real connection would report them.
    private func detail(for phase: BighelpConnectionPhase) -> BighelpConnectionDetail? {
        switch phase {
        case .connecting: nil
        case .reconnecting: BighelpConnectionDetail(attempt: 2, maximumAttempts: 5)
        case .connected: BighelpConnectionDetail(latencyMilliseconds: 24, hermesVersion: "0.21.4")
        case .disconnected: BighelpConnectionDetail(message: "Hermes didn't answer.")
        }
    }

    private func hostRow(_ name: String, _ phase: BighelpConnectionPhase, _ detail: BighelpConnectionDetail?) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            BighelpIconTile(systemName: "server.rack", tint: BighelpConnectionLine.hostTint(theme))
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.bighelp(.body, weight: .medium))
                if let text = detail?.text(for: phase) {
                    Text(text).font(.bighelp(.footnote)).monospacedDigit().foregroundStyle(theme.secondaryText)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: BighelpTokens.space8)
            BighelpConnectionPill(phase: phase)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: BighelpTokens.hitTarget)
    }
}

// MARK: Activity

/// The design's scripted run, with real Hermes tool names through the catalog.
private struct GalleryActivity: View {
    private struct Beat {
        let tool: String?
        let label: String
        let detail: String
        let meta: String?
        var isAddition = false
        let seconds: Double
    }

    private static let script: [Beat] = [
        Beat(tool: nil, label: "", detail: "", meta: nil, seconds: 1.8),
        Beat(tool: "web_search", label: "Searched the web", detail: "ryokan near Gion under $200", meta: "1.9s", seconds: 2),
        Beat(tool: "browser_navigate", label: "Opened", detail: "kyoto-stays.example/gion", meta: "1.2s", seconds: 1.6),
        Beat(tool: "delegate_task", label: "Asked Otto", detail: "“Is the Oct 10 dinner still on?”", meta: "1.2s", seconds: 1.7),
        Beat(tool: "write_file", label: "Created", detail: "Kyoto plan.md", meta: "+64", isAddition: true, seconds: 1.5),
    ]

    @State private var beat = 0
    @State private var run = 0
    @State private var startedAt = Date()
    @State private var finishedAfter: TimeInterval?
    @State private var liveExpanded = true
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            GalleryPanel(title: "In a chat") {
                HStack {
                    Spacer()
                    Button("Replay") { replay() }
                        .font(.bighelp(.subheadline, weight: .semibold))
                        .accessibilityIdentifier("loader-gallery.replay")
                }
                chat
            }
            .task(id: run) { await play() }
            GalleryPanel(title: "Every action", note: "tap to unfold") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(Self.catalogSamples.enumerated()), id: \.offset) { index, sample in
                        BighelpActivityRow(phase: sample.tool == "reasoning" ? .thinking
                                                : .working(BighelpToolActivityCatalog.activity(forTool: sample.tool)),
                                           steps: sample.steps, note: sample.note, startsExpanded: index == 2)
                    }
                    BighelpActivityRow(phase: .waitingForApproval(),
                                       steps: [BighelpActivityStep(id: "book", glyph: .symbol("bag"),
                                                                   label: "Book Hotel Gion Hatanaka",
                                                                   detail: "$412.00 · saved card")])
                    BighelpActivityRow(phase: .done(elapsed: 14), steps: [
                        step("web_search", "Searched the web", "ryokan near Gion"),
                        step("read_file", "Read a file", "itinerary.md"),
                        BighelpActivityStep(id: "created", glyph: .glyph(.docRich), label: "Created",
                                            detail: "Kyoto plan.md", meta: "+64", metaIsAddition: true),
                    ])
                }
            }
            GalleryPanel(title: "Stale scene phase", note: "chat-row trap") {
                Text("Browsing the web…")
                    .font(.bighelp(.subheadline, weight: .medium))
                    .bighelpShimmer(isActive: true)
                    .environment(\.scenePhase, .inactive)
                Text("This label carries a stale \"inactive\" scene phase, like chat rows once did. It still moves while the app is active.")
                    .font(.bighelp(.caption)).foregroundStyle(theme.tertiaryText)
            }
        }
    }

    private var chat: some View {
        let finished = beat >= Self.script.count
        let shown = Self.script[1..<max(1, min(beat + 1, Self.script.count))]
        let steps = shown.enumerated().map { offset, beat in
            BighelpActivityStep(
                id: "\(run)-\(offset)", glyph: BighelpToolActivityCatalog.activity(forTool: beat.tool).glyph,
                label: beat.label, detail: beat.detail, meta: beat.meta, metaIsAddition: beat.isAddition,
                isRunning: !finished && offset == shown.count - 1)
        }
        let current = Self.script[min(beat, Self.script.count - 1)]
        let phase: BighelpActivityPhase = finished ? .done(elapsed: finishedAfter)
            : beat == 0 ? .thinking : .working(BighelpToolActivityCatalog.activity(forTool: current.tool))
        return VStack(alignment: .leading, spacing: 10) {
            Text("Find me a ryokan in Kyoto for the Oct trip?")
                .font(.bighelp(.body))
                .foregroundStyle(theme.outgoingMessageForeground)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(theme.outgoingMessageBackground, in: .rect(cornerRadius: 20))
                .frame(maxWidth: .infinity, alignment: .trailing)
            HStack(alignment: .top, spacing: BighelpTokens.space8) {
                Circle().fill(theme.action.opacity(0.85)).frame(width: 28, height: 28).padding(.top, 8)
                BighelpActivityRow(phase: phase, steps: steps,
                                   note: beat == 0 ? nil : "Two nights near Gion, under $400, after the 4 PM landing.",
                                   isExpanded: $liveExpanded,
                                   accessibilityIdentifier: "loader-gallery.live-activity")
            }
            if finished {
                Text("Found three near Gion under $200 a night. Hatanaka has your Oct 9 check-in open. Want me to hold it?")
                    .font(.bighelp(.body))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(theme.incomingMessageBackground, in: .rect(cornerRadius: 20))
                    .padding(.leading, 36)
                    .transition(.opacity)
            }
        }
        .frame(minHeight: 300, alignment: .top)
    }

    private func replay() {
        run += 1
    }

    private func play() async {
        beat = 0
        finishedAfter = nil
        startedAt = Date()
        liveExpanded = true
        for index in Self.script.indices {
            try? await Task.sleep(for: .seconds(Self.script[index].seconds))
            guard !Task.isCancelled else { return }
            if index == Self.script.count - 1 {
                finishedAfter = Date().timeIntervalSince(startedAt)
                liveExpanded = false
            }
            withAnimation { beat = index + 1 }
        }
    }

    private struct Sample {
        let tool: String
        var steps: [BighelpActivityStep] = []
        var note: String?
    }

    private func step(_ tool: String, _ label: String, _ detail: String, meta: String? = nil,
                      running: Bool = false) -> BighelpActivityStep {
        BighelpActivityStep(id: "\(tool)-\(label)-\(detail)", glyph: BighelpToolActivityCatalog.activity(forTool: tool).glyph,
                            label: label, detail: detail, meta: meta, isRunning: running)
    }

    private static let catalogSamples: [Sample] = {
        func s(_ tool: String, _ label: String, _ detail: String, _ meta: String? = nil, add: Bool = false,
               running: Bool = false) -> BighelpActivityStep {
            BighelpActivityStep(id: "\(tool)-\(label)-\(detail)", glyph: BighelpToolActivityCatalog.activity(forTool: tool).glyph,
                                label: label, detail: detail, meta: meta, metaIsAddition: add, isRunning: running)
        }
        return [
            Sample(tool: "reasoning", note: "You want two nights near Gion under $400. The Oct 9 flight lands at 4 PM, so check-in that evening works."),
            Sample(tool: "web_search", steps: [s("web_search", "Searched", "“best ramen Shibuya”", "0.8s"),
                                               s("web_search", "Searching", "“ramen open late”", running: true)]),
            Sample(tool: "patch", steps: [s("write_file", "Created", "src/booking.ts", "+48", add: true),
                                          s("patch", "Edited", "src/api/client.ts", "+12 −3", add: true),
                                          s("terminal", "Running", "npm test", running: true)]),
            Sample(tool: "browser_navigate", steps: [s("browser_navigate", "Opened", "tokyo-food.example/ramen", "1.2s"),
                                                     s("browser_navigate", "Opening", "tokyo-food.example/late", running: true)]),
            Sample(tool: "search_files", steps: [s("search_files", "Looked in", "~/Documents/Taxes", "6 found"),
                                                 s("search_files", "Matching", "“1099” “invoice”", running: true)]),
            Sample(tool: "read_file", steps: [s("read_file", "Reading", "Lease_2026.pdf · page 9 of 14", running: true)]),
            Sample(tool: "write_file", steps: [s("write_file", "Writing", "Trip plan.md", running: true)]),
            Sample(tool: "terminal", steps: [s("terminal", "Running", "brew upgrade hermes", running: true)]),
            Sample(tool: "delegate_task", steps: [s("delegate_task", "Asked Otto", "“Can you hold the 7:30 table?”", "2s"),
                                                  s("delegate_task", "Waiting on Otto", "", running: true)]),
            Sample(tool: "image_generate", steps: [s("image_generate", "Making", "a watercolor of Gion at dusk", running: true)]),
            Sample(tool: "memory", steps: [s("memory", "Saving", "Prefers ryokan over hotels", running: true)]),
            Sample(tool: "cronjob", steps: [s("cronjob", "Scheduling", "Every day at 8:00 AM", running: true)]),
            Sample(tool: "some_new_plugin_tool"),
        ]
    }()
}

// MARK: Buttons

private struct GalleryButtons: View {
    @State private var state = BighelpButtonLoadState.idle
    @State private var run = 0
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            GalleryPanel(title: "Working keeps the width", note: "tap it") {
                createAgent(state) { if state == .idle { run += 1 } }
                    .accessibilityIdentifier("loader-gallery.create-agent")
                    .task(id: run) {
                        guard run > 0 else { return }
                        state = .working("Setting it up…")
                        try? await Task.sleep(for: .seconds(1.8))
                        guard !Task.isCancelled else { return }
                        state = .success("Mina's ready")
                        try? await Task.sleep(for: .seconds(1.8))
                        guard !Task.isCancelled else { return }
                        state = .idle
                    }
            }
            GalleryPanel(title: "Each state, same width") {
                VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                    createAgent(.idle) {}
                    createAgent(.working("Setting it up…")) {}
                    createAgent(.success("Mina's ready")) {}
                }
            }
            GalleryPanel(title: "Press: shrink and dim, never a color shift") {
                HStack(spacing: BighelpTokens.space12) {
                    Button {} label: {
                        Text("New chat").font(.bighelp(.body, weight: .semibold))
                            .foregroundStyle(theme.actionForeground)
                            .padding(.horizontal, 18).frame(minHeight: BighelpTokens.hitTarget)
                            .background(theme.action, in: Capsule())
                    }
                    Button {} label: {
                        Text("Rename").font(.bighelp(.subheadline, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                            .padding(.horizontal, 14).frame(minHeight: BighelpTokens.hitTarget)
                            .background(theme.primaryText.opacity(0.07), in: Capsule())
                    }
                }
                .buttonStyle(.bighelpScaleDim)
            }
        }
    }

    /// The design's New agent button: action-colored, success-green when done.
    private func createAgent(_ state: BighelpButtonLoadState, action: @escaping () -> Void) -> some View {
        let isSuccess = if case .success = state { true } else { false }
        // After dark the success green is light, so it takes dark ink.
        let ink = isSuccess ? (theme.isDarkPalette ? Color(hex: BighelpTheme.light.primaryTextHex) : .white)
            : theme.actionForeground
        return Button(action: action) {
            BighelpButtonLoadingLabel(state: state, ink: ink) {
                Label("New agent", systemImage: "person.badge.plus")
                    .frame(minWidth: 132)
            }
            .font(.bighelp(.body, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 18)
            .frame(minHeight: BighelpTokens.hitTarget)
            .background(isSuccess ? theme.success : theme.action, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.bighelpScaleDim)
    }
}

// MARK: Scroll test

/// Ten image placeholders and ten shimmering rows, for checking that scrolling
/// stays smooth and the main thread stays quiet.
private struct GalleryScrollTest: View {
    var body: some View {
        LazyVStack(alignment: .leading, spacing: BighelpTokens.space16) {
            ForEach(0..<10, id: \.self) { index in
                BighelpActivityRow(phase: .working(BighelpToolActivityCatalog.activity(
                    forTool: ["web_search", "terminal", "read_file", "image_generate", "browser_click"][index % 5])),
                                   stepCount: index + 1)
                BighelpImageGeneratingView(variant: index % 2 == 0 ? .glow : .develop,
                                           aspectRatio: index % 3 == 0 ? 1 : 4 / 3,
                                           progress: index % 4 == 1 ? Double(index) / 10 : nil,
                                           phaseOffset: Double(index) * 0.7)
                    .accessibilityIdentifier("loader-gallery.scroll.\(index)")
                    .id("scroll-\(index)")
            }
        }
    }
}

/// Counts frames that arrived late (more than 1.5 frame intervals after the
/// last), in the window since it appeared: "late 3/1200 · max 25 ms".
private struct GalleryFrameMeterLabel: View {
    @State private var meter = GalleryFrameMeter()
    @State private var summary = "measuring…"

    var body: some View {
        Text(summary)
            .font(.bighelp(.caption, design: .monospaced))
            .accessibilityIdentifier("loader-gallery.frame-meter")
            .task {
                // Skip launch and the first layout; count steady frames only.
                try? await Task.sleep(for: .seconds(2))
                meter.start()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    summary = meter.summary
                }
            }
            .onDisappear { meter.stop() }
    }
}

@MainActor
private final class GalleryFrameMeter: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames = 0
    private var late = 0
    private var longest: CFTimeInterval = 0

    var summary: String { "late \(late)/\(frames) · max \(Int((longest * 1000).rounded())) ms" }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { return }
        let gap = link.timestamp - last
        let interval = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
        frames += 1
        longest = max(longest, gap)
        if gap > interval * 1.5 { late += 1 }
    }
}
#endif
