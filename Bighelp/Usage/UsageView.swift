import SwiftUI

/// ☰ › Usage: plans and limits, then what the agents used. Cost or tokens over
/// 7, 30 or 90 days, totals, when you use it, and the models, agents and (with
/// All hosts) computers behind it. Tap a bar for its day, a row to chart it.
struct UsageView: View {
    let store: UsageStore
    /// Plans and limits of the computer in use; nil hides them.
    let providerUsage: ProviderUsageStore?
    /// The computer in use, whose limits come from `providerUsage`.
    let selectedHostID: String
    var selectedHostName: String?

    @State private var selectedDay: String?
    @State private var isChoosingProviders = false
    /// Which computers' plans Limits shows (`UsageLimitsComputers.Choice`).
    @AppStorage(UsageLimitsComputers.choiceKey) private var limitsChoice = "current"
    @AppStorage(ProviderUsagePreferences.hiddenKey) private var hiddenProviders = ""
    @Environment(\.appAppearance) private var appearance
    @BighelpThemeReader private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space24) {
                if let providerUsage, providerUsage.isAvailable || limitsComputers.offersChoice {
                    BighelpDeferredSection {
                        UsageLimitsSection(store: providerUsage, computers: limitsComputers, summary: store.summary,
                                           range: store.range, onChoose: { isChoosingProviders = true },
                                           onPickComputers: { limitsChoice = $0 })
                    }
                }
                rangePicker
                content
            }
            .padding(.top, BighelpTokens.space8)
            .padding(.bottom, BighelpTokens.space48)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("usage")
        }
        .scrollIndicators(.hidden)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { shareMenu }
            ToolbarItem(placement: .topBarTrailing) { refreshButton }
        }
        // Exports are only for the share sheet.
        .onDisappear { UsageExporter.removeAll() }
        .refreshable { await refresh() }
        .task {
            await store.load(refresh: false)
            if let providerUsage, providerUsage.isAvailable, providerUsage.report == nil {
                await providerUsage.load(refresh: false)
            }
        }
        .sheet(isPresented: $isChoosingProviders) {
            NavigationStack {
                ProviderUsageSettingsView(store: providerUsage)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isChoosingProviders = false }
                                .bighelpDefaultAction()
                                .accessibilityIdentifier("usage.limits.done")
                        }
                    }
            }
            .bighelpSheetSize(.compact)
        }
    }

    /// The computer in use and, while All hosts is on, the others.
    private var limitsComputers: UsageLimitsComputers {
        UsageLimitsComputers(selectedID: selectedHostID, selectedName: selectedHostName, hosts: store.hosts,
                             saved: limitsChoice)
    }

    private var refreshButton: some View {
        Button {
            Task { await refresh() }
        } label: {
            if store.isRefreshing || providerUsage?.isRefreshing == true {
                ProgressView()
            } else {
                Image(systemName: "arrow.clockwise")
                    .bighelpToolbarIcon()
            }
        }
        .disabled(store.isRefreshing)
        .bighelpIconLabel("Refresh", shortcut: BighelpPlatform.isMac ? "⌘R" : nil)
        #if targetEnvironment(macCatalyst)
        .keyboardShortcut("r")
        #endif
        .accessibilityIdentifier("usage.refresh")
    }

    /// PDF, PNG and HTML show the page as it is (range, Cost or Tokens, the
    /// computers in Limits); CSV has the numbers. Written when shared.
    @ViewBuilder
    private var shareMenu: some View {
        let snapshot = UsageExportSnapshot.make(store: store, providerUsage: providerUsage, computers: limitsComputers,
                                                hidden: ProviderUsagePreferences.hidden(hiddenProviders))
        Menu {
            if let snapshot {
                Section("Share as") {
                    ForEach(UsageExportFormat.allCases) { format in
                        ShareLink(item: UsageExportItem(format: format, snapshot: snapshot, appearance: appearance),
                                  preview: SharePreview("Usage, \(snapshot.dateRangeText)")) {
                            Label(format.title, systemImage: format.symbol)
                        }
                        .accessibilityIdentifier("usage.share.\(format.rawValue)")
                    }
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .bighelpToolbarIcon()
        }
        .disabled(snapshot == nil)
        .bighelpIconLabel("Share")
        .accessibilityIdentifier("usage.share")
    }

    private func refresh() async {
        if let providerUsage, providerUsage.isAvailable {
            async let limits: Void = providerUsage.load(refresh: true)
            await store.load(refresh: true)
            await limits
        } else {
            await store.load(refresh: true)
        }
    }

    // MARK: Range

    private var rangePicker: some View {
        UsagePillPicker(
            options: UsageRange.allCases.map { ($0, $0.title) },
            selection: store.range, expands: true, label: "Time range", identifier: "usage.range"
        ) { range in
            selectedDay = nil
            Task { await store.select(range) }
        }
        .padding(.horizontal, BighelpTokens.space16)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let summary = store.summary {
            if case .unavailable(let message) = store.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, BighelpTokens.space20)
            }
            BighelpDeferredSection {
                UsageHeroCard(store: store, summary: summary, selectedDay: $selectedDay)
            }
            BighelpDeferredSection { UsageTotalsSection(summary: summary) }
            BighelpDeferredSection { UsageWhenSection(summary: summary) }
            BighelpDeferredSection {
                UsageBreakdownSection(title: "By model", rows: summary.models, summary: summary, store: store,
                                      identifier: "usage.models", showsDetail: false)
            }
            BighelpDeferredSection {
                UsageBreakdownSection(title: "By agent", rows: summary.agents, summary: summary, store: store,
                                      identifier: "usage.agents", showsDetail: summary.isMultiHost)
            }
            if summary.isMultiHost {
                BighelpDeferredSection {
                    UsageBreakdownSection(title: "By computer", rows: summary.hosts, summary: summary, store: store,
                                          identifier: "usage.hosts", showsDetail: false)
                }
            }
        } else if case .unavailable(let message) = store.state {
            UsageMessageCard(title: message, action: ("Try Again", { Task { await store.load(refresh: false) } }))
        } else {
            UsageMessageCard(title: "Reading usage from your computer…", isLoading: true)
        }
    }
}

// MARK: - Shared pieces

/// The mockups' colors, from the theme.
struct UsagePalette {
    let theme: BighelpTheme

    /// Bars: bighelp's lavender, a little deeper after dark.
    var bar: Color { theme.isDarkPalette ? Color(hex: "9474E7") : theme.action }
    /// Bars for everything else, and empty tracks.
    var ghost: Color { Color(hex: theme.isDarkPalette ? "3A3634" : "E6DED7") }
    var wash: Color { theme.action.opacity(theme.isDarkPalette ? 0.16 : 0.12) }
    var segment: Color { theme.isDarkPalette ? theme.surface : Color(hex: "F0EAE5") }
    var grid: Color { theme.isDarkPalette ? Color(hex: "2E2B29") : theme.separator }
}

/// Small, bold, letterspaced and muted, like every section caption in bighelp.
struct UsageCaption<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.bighelp(.caption).weight(.bold))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(theme.tertiaryText)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: BighelpTokens.space8)
            trailing()
        }
        .padding(.horizontal, BighelpTokens.space20)
        .padding(.bottom, BighelpTokens.space8)
    }

    @BighelpThemeReader private var theme
}

extension UsageCaption where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

extension View {
    /// A white (or graphite) card with the mockups' hairline and soft shadow.
    func usageCard(_ theme: BighelpTheme, padding: EdgeInsets) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: BighelpTokens.cardCornerRadius, style: .continuous)
                    .fill(theme.surface)
                    .shadow(color: .black.opacity(theme.isDarkPalette ? 0.2 : 0.06), radius: 3, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: BighelpTokens.cardCornerRadius, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            }
            .padding(.horizontal, BighelpTokens.space16)
    }
}

/// A row of choices in a capsule, the chosen one raised.
struct UsagePillPicker<Value: Hashable>: View {
    let options: [(Value, String)]
    let selection: Value
    var expands = false
    var compact = false
    let label: String
    let identifier: String
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let isOn = value == selection
                Button { onSelect(value) } label: {
                    Text(title)
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .foregroundStyle(isOn ? theme.primaryText : theme.secondaryText)
                        .lineLimit(1)
                        .padding(.horizontal, BighelpTokens.space12)
                        .frame(maxWidth: expands ? .infinity : nil)
                        .frame(height: BighelpTokens.hitTarget - (compact ? 6 : 8))
                        .background {
                            if isOn {
                                Capsule().fill(theme.surface)
                                    .shadow(color: .black.opacity(theme.isDarkPalette ? 0.3 : 0.12), radius: 1.5, y: 1)
                                    .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
                            }
                        }
                        .contentShape(.capsule)
                }
                .bighelpPlainButtonStyle(.capsule)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier("\(identifier).\(String(describing: value))")
            }
        }
        .padding(compact ? 3 : 4)
        .background(Capsule().fill(UsagePalette(theme: theme).segment))
        .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    @BighelpThemeReader private var theme
}

/// A plain pill: "Busiest", "Credits".
struct UsageBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.bighelp(.caption).weight(.bold))
            .foregroundStyle(theme.action)
            .padding(.horizontal, BighelpTokens.space8)
            .padding(.vertical, 3)
            .background(Capsule().fill(UsagePalette(theme: theme).wash))
            .lineLimit(1)
    }

    @BighelpThemeReader private var theme
}

/// Loading, a reason something didn't load, or a plugin to update.
struct UsageMessageCard: View {
    let title: String
    var detail: String?
    var isLoading = false
    var action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: BighelpTokens.space8) {
            if isLoading { ProgressView() }
            Text(title)
                .font(.bighelp(.body).weight(.semibold))
                .foregroundStyle(theme.primaryText)
            if let detail {
                Text(detail).font(.bighelp(.footnote)).foregroundStyle(theme.secondaryText)
            }
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.borderedProminent)
                    .tint(theme.action)
                    .padding(.top, BighelpTokens.space4)
                    .accessibilityIdentifier("usage.message.action")
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .usageCard(theme, padding: EdgeInsets(top: 24, leading: 18, bottom: 24, trailing: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage.message")
    }

    @BighelpThemeReader private var theme
}
