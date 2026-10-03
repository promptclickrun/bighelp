import SwiftUI

/// Usage › Limits: each plan, limit and balance the computers' providers report
/// (bighelp plugin, `native-provider-usage-v1`), with what the agents used
/// through it in the range beside it. With several computers a menu picks one
/// or all; all of them show each computer's plans under its own name.
struct UsageLimitsSection: View {
    let store: ProviderUsageStore
    let computers: UsageLimitsComputers
    let summary: UsageSummary?
    let range: UsageRange
    let onChoose: () -> Void
    /// Saves a `UsageLimitsComputers.Choice`.
    let onPickComputers: (String) -> Void

    @AppStorage(ProviderUsagePreferences.hiddenKey) private var hiddenRaw = ""
    @State private var showsAll = false
    @BighelpThemeReader private var theme

    private static let shortList = 1

    private var hidden: Set<String> { ProviderUsagePreferences.hidden(hiddenRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageCaption(title: "Limits") {
                HStack(spacing: BighelpTokens.space16) {
                    if computers.offersChoice { computerMenu }
                    if canChoose {
                        Button("Choose", action: onChoose)
                            .font(.bighelp(.footnote).weight(.semibold))
                            .foregroundStyle(theme.action)
                            .frame(minHeight: 28)
                            .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius8))
                            .accessibilityHint("Choose which plans and balances show here.")
                            .accessibilityIdentifier("usage.limits.choose")
                    }
                }
            }
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                ForEach(computers.shown) { computer in
                    VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                        if computers.showsNames { heading(computer) }
                        if computer.isSelected {
                            selectedHost(name: computer.name)
                        } else if let usage = computer.usage {
                            otherHost(usage)
                        }
                    }
                    .padding(.top, computers.showsNames && computer.id != computers.shown.first?.id
                             ? BighelpTokens.space12 : 0)
                }
            }
            if computers.shown.contains(where: \.isSelected),
               let updated = ProviderUsagePresentation.updatedText(store.report?.fetchedAt) {
                Text(updated)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.tertiaryText)
                    .padding(.horizontal, BighelpTokens.space20)
                    .padding(.top, BighelpTokens.space8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider-usage")
    }

    /// Choose hides a provider on every computer; it shows once there's one to hide.
    private var canChoose: Bool {
        computers.shown.contains { computer in
            if computer.isSelected { return store.report?.providers.isEmpty == false }
            if case .loaded(let report)? = computer.usage?.limits { return !report.providers.isEmpty }
            return false
        }
    }

    private var computerMenu: some View {
        Menu {
            Button { onPickComputers(UsageLimitsComputers.Choice.all.saved) } label: {
                if computers.choice == .all {
                    Label("All computers", systemImage: "checkmark")
                } else {
                    Text("All computers")
                }
            }
            Section {
                ForEach(computers.computers) { computer in
                    Button { onPickComputers(UsageLimitsComputers.saved(for: computer)) } label: {
                        if computers.isChosen(computer) {
                            Label(computer.name, systemImage: "checkmark")
                        } else {
                            Text(computer.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: BighelpTokens.space4) {
                Image(systemName: "desktopcomputer")
                Text(computers.title)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.bighelp(.caption2).weight(.semibold))
            }
            .font(.bighelp(.footnote).weight(.semibold))
            .foregroundStyle(theme.action)
            .frame(minHeight: 28)
            .contentShape(.rect)
        }
        .textCase(nil)
        .accessibilityLabel("Computer: \(computers.title)")
        .accessibilityHint("Shows plans and limits for one computer or all of them.")
        .accessibilityIdentifier("usage.limits.computer")
    }

    /// The computer's name over its plans, so a Claude card plainly belongs to it.
    private func heading(_ computer: UsageLimitsComputers.Computer) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            Image(systemName: "desktopcomputer")
                .font(.bighelp(.subheadline).weight(.semibold))
                .foregroundStyle(theme.secondaryText)
                .accessibilityHidden(true)
            Text(computer.name)
                .font(.bighelp(.headline))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
            if computer.isSelected {
                Text("In use")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        .padding(.horizontal, BighelpTokens.space20)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("usage.limits.host.\(computer.name)")
    }

    @ViewBuilder
    private func selectedHost(name: String) -> some View {
        let hostName: String? = computers.offersChoice ? name : nil
        if store.isAvailable {
            if case .unavailable(let message) = store.state, store.report != nil {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, BighelpTokens.space20)
            }
            if store.state == .needsPluginUpdate {
                UsageMessageCard(title: "Update the bighelp plugin\(hostName.map { " on \($0)" } ?? "") to see plans and limits.")
            } else if let report = store.report {
                let providers = ProviderUsagePresentation.visible(report.providers, hidden: hidden)
                if report.providers.isEmpty {
                    UsageMessageCard(title: "No AI plans found\(hostName.map { " on \($0)" } ?? "").",
                                     detail: "bighelp shows coding tools on the computer and providers set up in Hermes.")
                } else if providers.isEmpty {
                    UsageMessageCard(title: "Every plan is hidden.", action: ("Choose", onChoose))
                } else {
                    // The provider in use first; the rest wait a tap away so usage stays in view.
                    ForEach(showsAll ? providers : Array(providers.prefix(Self.shortList))) { provider in
                        UsageLimitCard(provider: provider,
                                       used: summary?.agentsUse(of: provider, hostID: computers.computers[0].id),
                                       range: range)
                    }
                    if providers.count > Self.shortList {
                        Button(showsAll ? "Show fewer" : "Show \(providers.count - Self.shortList) more") {
                            withAnimation(.easeOut(duration: 0.2)) { showsAll.toggle() }
                        }
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .foregroundStyle(theme.action)
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                        .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12))
                        .accessibilityIdentifier("usage.limits.more")
                    }
                }
            } else if case .unavailable(let message) = store.state {
                UsageMessageCard(title: message, action: ("Try Again", { Task { await store.load(refresh: false) } }))
            } else {
                UsageMessageCard(title: "Checking your plans…", isLoading: true)
            }
        } else {
            UsageMessageCard(title: "Connect to \(name) to see its plans and limits.")
        }
    }

    @ViewBuilder
    private func otherHost(_ host: HostUsage) -> some View {
        switch host.limits {
        case .loaded(let report)?:
            let providers = ProviderUsagePresentation.visible(report.providers, hidden: hidden)
            if report.providers.isEmpty {
                UsageMessageCard(title: "No AI plans found on \(host.name).")
            } else if providers.isEmpty {
                UsageMessageCard(title: "Every plan is hidden.", action: ("Choose", onChoose))
            } else {
                ForEach(providers) { provider in
                    UsageLimitCard(provider: provider, used: summary?.agentsUse(of: provider, hostID: host.id),
                                   range: range)
                }
            }
        case .needsPluginUpdate?:
            UsageMessageCard(title: "Update the bighelp plugin on \(host.name) to see its plans and limits.")
        case .unavailable(let message)?:
            UsageMessageCard(title: host.name, detail: message)
        case nil:
            UsageMessageCard(title: host.name, detail: host.failure ?? "Its plans and limits couldn't be read.")
        }
    }
}

/// One plan or balance: what's left of each limit, the balances, and what the
/// agents used through it.
struct UsageLimitCard: View {
    let provider: ProviderUsage
    let used: UsageAmount?
    let range: UsageRange
    /// A shared copy of the page: nothing to tap, and resets counted from when it was made.
    var isExport = false
    var now: Date?
    @Environment(\.openURL) private var openURL
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            header
            if provider.status == .ok {
                windows
                facts
            } else if let message = provider.message {
                Text(message)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if used != nil || (provider.manageURL != nil && !isExport) {
                Rectangle().fill(theme.separator).frame(height: 1)
                footer
            }
        }
        .usageCard(theme, padding: EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider-usage.\(provider.id)")
    }

    private var header: some View {
        HStack(spacing: BighelpTokens.space8) {
            AIProviderMarkView(providerID: ProviderUsagePresentation.logoProviderID(provider.id),
                               providerName: provider.name, context: .chatQuickChoice, size: 22)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text(provider.name)
                .font(.bighelp(.headline))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
            Spacer(minLength: BighelpTokens.space8)
            if provider.activeInHermes { UsageBadge(text: "In use") }
            if let plan = provider.plan { UsageBadge(text: plan) }
        }
    }

    @ViewBuilder
    private var windows: some View {
        ForEach(provider.windows) { window in
            let color = ProviderUsagePresentation.barColor(for: provider, window: window, theme: theme)
            let left = ProviderUsagePresentation.percentText(window.leftPercent)
            let reset = ProviderUsagePresentation.resetText(window.resetsAt, now: now ?? .now)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(window.label)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: BighelpTokens.space8)
                    Text((provider.approximate ? "About " : "") + "\(left) left")
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(color)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(color.opacity(0.16))
                        Capsule().fill(color).frame(width: proxy.size.width * min(max(window.leftPercent / 100, 0), 1))
                    }
                }
                .frame(height: 6)
                if let detail = [window.detail, reset].compactMap({ $0 }).joined(separator: " · ").nonEmpty {
                    Text(detail).font(.bighelp(.footnote)).monospacedDigit().foregroundStyle(theme.tertiaryText)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(window.label), \(Int(window.usedPercent.rounded())) percent used\(reset.map { ", \($0.lowercased())" } ?? "")")
        }
    }

    @ViewBuilder
    private var facts: some View {
        if let first = provider.facts.first {
            HStack(alignment: .firstTextBaseline) {
                (Text(first.value).font(.bighelp(.title2).weight(.bold))
                 + Text(" " + first.label.lowercased()).font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText))
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: BighelpTokens.space8)
                if provider.facts.count == 2 {
                    factText(provider.facts[1])
                }
            }
            .accessibilityElement(children: .combine)
            if provider.facts.count > 2 {
                ForEach(provider.facts.dropFirst()) { fact in
                    HStack {
                        Text(fact.label).foregroundStyle(theme.secondaryText)
                        Spacer(minLength: BighelpTokens.space8)
                        Text(fact.value).foregroundStyle(theme.primaryText).monospacedDigit()
                    }
                    .font(.bighelp(.footnote))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func factText(_ fact: ProviderUsage.Fact) -> some View {
        Text("\(fact.label) \(fact.value)")
            .font(.bighelp(.footnote))
            .monospacedDigit()
            .foregroundStyle(theme.tertiaryText)
            .lineLimit(1)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
            if let used {
                Text(usedText(used))
                    .font(.bighelp(.footnote))
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("provider-usage.\(provider.id).agents-used")
            }
            Spacer(minLength: 0)
            if let url = provider.manageURL, !isExport {
                Button {
                    openURL(url)
                } label: {
                    Label("Manage", systemImage: "arrow.up.right")
                        .labelStyle(.titleAndIcon)
                        .font(.bighelp(.footnote).weight(.semibold))
                        .frame(minHeight: 28)
                }
                .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius8))
                .foregroundStyle(theme.action)
                .accessibilityHint("Opens \(provider.name) in the browser")
                .accessibilityIdentifier("provider-usage.manage.\(provider.id)")
            }
        }
    }

    /// "Your agents: 2.5M tokens · $126.09 in 30 days".
    private func usedText(_ used: UsageAmount) -> String {
        var parts = ["\(UsageFormat.short(used.tokens)) tokens"]
        if used.cost > 0 { parts.append(UsageFormat.money(used.cost)) }
        return "Your agents: " + parts.joined(separator: " · ") + " in \(range.days) days"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
