import Observation
import SwiftUI

/// Hermes settings Simple Bot mode shows: approvals and the time zone, read
/// from and saved to the bot's own config on its computer.
@MainActor
protocol SimpleBotHostConfiguring: AnyObject {
    func read(profile: String) async throws -> [String: BighelpJSONValue]
    /// Saves only these keys; Hermes merges them into the rest of the config.
    func write(_ config: [String: BighelpJSONValue], profile: String) async throws
}

/// The live host: Hermes' dashboard config routes, the same ones voice settings use.
@MainActor
final class SimpleBotWorkspaceConfiguration: SimpleBotHostConfiguring {
    private let workspace: @MainActor () -> (any WorkspaceOperationPerforming)?

    init(workspace: @escaping @MainActor () -> (any WorkspaceOperationPerforming)?) {
        self.workspace = workspace
    }

    func read(profile: String) async throws -> [String: BighelpJSONValue] {
        guard let workspace = workspace(), let owner = workspace.owner else {
            throw WorkspaceClientError.transportUnavailable
        }
        return try await workspace.perform(.workspaceConfigGet, payload: ["profile": .string(profile)], owner: owner)
    }

    func write(_ config: [String: BighelpJSONValue], profile: String) async throws {
        guard let workspace = workspace(), let owner = workspace.owner else {
            throw WorkspaceClientError.transportUnavailable
        }
        let result = try await workspace.perform(.workspaceConfigSet, payload: [
            "profile": .string(profile), "config": .object(config),
        ], owner: owner)
        guard result["ok"]?.boolean != false else { throw WorkspaceClientError.invalidResponse }
    }
}

/// Demo mode's config, in memory, merged like Hermes merges a save.
@MainActor
final class SimpleBotDemoConfiguration: SimpleBotHostConfiguring {
    static let shared = SimpleBotDemoConfiguration()
    private var configs: [String: [String: BighelpJSONValue]] = [:]

    func read(profile: String) async throws -> [String: BighelpJSONValue] {
        configs[profile] ?? ["approvals": .object(["mode": .string("smart")]), "timezone": .string("")]
    }

    func write(_ config: [String: BighelpJSONValue], profile: String) async throws {
        configs[profile] = Self.merge(try await read(profile: profile), config)
    }

    static func merge(_ base: [String: BighelpJSONValue], _ incoming: [String: BighelpJSONValue])
        -> [String: BighelpJSONValue] {
        var result = base
        for (key, value) in incoming {
            if case .object(let inner) = value, case .object(let existing)? = result[key] {
                result[key] = .object(merge(existing, inner))
            } else {
                result[key] = value
            }
        }
        return result
    }
}

/// Auto-review and the time zone for a bot. Auto-review on is Hermes' smart
/// approvals (a reviewer lets safe actions through and asks you about risky
/// ones); off is manual (you're asked every time). It never turns approvals off.
@MainActor
@Observable
final class SimpleBotHostSettings {
    enum Load: Equatable { case idle, loading, loaded, unavailable }

    private(set) var load: Load = .idle
    private(set) var autoReview = true
    private(set) var rules = ""
    /// Hermes' time zone; empty means the computer's own.
    private(set) var timeZone = ""
    private(set) var isSaving = false
    var errorMessage: String?

    @ObservationIgnored private let client: any SimpleBotHostConfiguring
    @ObservationIgnored private let profile: String
    @ObservationIgnored private let allProfiles: () -> [String]

    init(client: any SimpleBotHostConfiguring, profile: String, allProfiles: @escaping () -> [String]) {
        self.client = client
        self.profile = profile
        self.allProfiles = allProfiles
    }

    func refresh() async {
        if load == .idle { load = .loading }
        do {
            apply(try await client.read(profile: profile))
            load = .loaded
        } catch {
            load = .unavailable
        }
    }

    func setAutoReview(_ on: Bool) async {
        await save(["approvals": .object(["mode": .string(on ? "smart" : "manual")])],
                   profiles: [profile])
    }

    func setRules(_ text: String) async {
        await save(["approvals": .object(["smart_policy": .string(text.trimmingCharacters(in: .whitespacesAndNewlines))])],
                   profiles: [profile])
    }

    /// The time zone every bot on this computer works in (schedules, "today").
    func setTimeZone(_ identifier: String) async {
        guard identifier != timeZone else { return }
        await save(["timezone": .string(identifier)], profiles: allProfiles())
    }

    private func save(_ config: [String: BighelpJSONValue], profiles: [String]) async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            for profile in Set(profiles + [self.profile]).sorted() {
                try await client.write(config, profile: profile)
            }
            apply(try await client.read(profile: profile))
        } catch {
            errorMessage = "The computer didn't save that. Try again in a moment."
        }
    }

    private func apply(_ config: [String: BighelpJSONValue]) {
        let approvals = config["approvals"]?.object ?? [:]
        // Hermes' default is smart; "off" (no approvals) reads as on/off only by what it does.
        let mode = approvals["mode"]?.string?.lowercased() ?? "smart"
        autoReview = mode == "smart"
        rules = approvals["smart_policy"]?.string ?? ""
        timeZone = config["timezone"]?.string ?? ""
        approvalsOff = mode == "off" || mode == "false"
    }

    /// Hermes runs with approvals off: risky actions go ahead without asking.
    private(set) var approvalsOff = false
}

/// What Simple Bot mode's Settings needs from the shell.
@MainActor
struct SimpleBotsSettingsContext {
    let settings: SettingsStore
    let userIdentity: UserIdentityStore
    let agents: AgentDirectoryStore
    /// The primary bot's Hermes settings; nil without a computer to ask.
    let makeHostSettings: () -> SimpleBotHostSettings?
    let usage: ProviderUsageStore?
    /// Teamwork for the computer in use; nil hides the row.
    let makeTeamwork: () -> TeamworkModel?
    /// Settings' own pages (Settings › Appearance and the rest).
    let page: (SimpleBotsSettingsPage) -> AnyView
    let allSettings: () -> AnyView
    let onOpenUsage: () -> Void
    let onOpenComputer: (String) -> Void
    let onDone: () -> Void
    /// Your gateways (computers) and how to pick the one in use.
    var gateways = BighelpMenuHosts()
}

enum SimpleBotsSettingsPage: Hashable {
    case you, appearance, notifications, apps
}

/// Simple Bot mode's Settings: you, usage, apps, your primary bot's approvals
/// and time zone, notifications and appearance, then the way back to all of bighelp.
@MainActor
struct SimpleBotsSettingsView: View {
    let context: SimpleBotsSettingsContext

    @State private var host: SimpleBotHostSettings?
    @State private var teamwork: TeamworkModel?
    @State private var isRulesPresented = false
    @State private var isTimeZonePresented = false
    @AppStorage("bighelp.simple-bots.automatic-time-zone") private var automaticTimeZone = false
    @Environment(\.scenePhase) private var scenePhase
    @BighelpThemeReader private var theme

    private var primary: AgentProfile? { context.agents.resolvedAgent(explicitID: nil) }

    /// The most used of your AI plans' limits, like the Usage page's tightest one.
    private var usagePercent: Double? {
        context.usage?.report?.providers.filter(\.activeInHermes).flatMap(\.windows).map(\.usedPercent).max()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: BighelpTokens.space16) {
                accountCard
                appsCard
                botSection
                appCard
                gatewaysCard
                modeCard
            }
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.top, BighelpTokens.space8)
            .padding(.bottom, BighelpTokens.space32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { context.onDone() } label: {
                    Image(systemName: "xmark").font(.bighelp(.body, weight: .semibold))
                }
                .accessibilityLabel("Close")
                .accessibilityIdentifier("simple-bots.settings.close")
            }
        }
        .navigationDestination(for: SimpleBotsSettingsPage.self) { page in context.page(page) }
        .task {
            if host == nil { host = context.makeHostSettings() }
            if teamwork == nil { teamwork = context.makeTeamwork() }
            await host?.refresh()
        }
        .task {
            if let usage = context.usage, usage.state == .idle { await usage.load(refresh: false) }
        }
        .task(id: scenePhase) { await followDeviceTimeZone() }
        .bighelpSheet(isPresented: $isRulesPresented) {
            if let host = host {
                SimpleBotRulesEditor(host: host).bighelpSheetSize(.large)
            }
        }
        .bighelpSheet(isPresented: $isTimeZonePresented) {
            if let host = host {
                SimpleBotTimeZonePicker(current: host.timeZone) { identifier in
                    isTimeZonePresented = false
                    Task { await host.setTimeZone(identifier) }
                }
                .bighelpSheetSize(.large)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple-bots.settings")
    }

    private var accountCard: some View {
        SimpleBotsCard {
            NavigationLink(value: SimpleBotsSettingsPage.you) {
                HStack(spacing: BighelpTokens.space16) {
                    AvatarView(stableID: UserIdentity.stableID, displayName: context.userIdentity.identity.displayName,
                               imageURL: context.userIdentity.avatarURL(), size: 48, kind: .person)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.userIdentity.identity.displayName)
                            .font(.bighelp(.title3))
                            .foregroundStyle(theme.primaryText)
                        Text("Your name and photo in chats")
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer()
                    SimpleBotsDisclosure()
                }
                .padding(.horizontal, BighelpTokens.space20)
                .padding(.vertical, BighelpTokens.space12)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("simple-bots.settings.you")
            SimpleBotsDivider()
            Button(action: context.onOpenUsage) {
                SimpleBotsRow(title: "Usage", value: usagePercent.map { "\(Int($0.rounded()))%" })
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("simple-bots.settings.usage")
        }
    }

    private var appsCard: some View {
        SimpleBotsCard {
            NavigationLink(value: SimpleBotsSettingsPage.apps) {
                SimpleBotsRow(title: "Connect apps",
                              detail: "Tools and skills for \(primary?.name ?? "your bots")")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("simple-bots.settings.apps")
        }
    }

    @ViewBuilder
    private var botSection: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            SimpleBotsSectionLabel(title: primary?.name ?? "Bot")
            SimpleBotsCard {
                if let host = host, host.load == .loaded {
                    Toggle(isOn: Binding(get: { host.autoReview },
                                         set: { on in Task { await host.setAutoReview(on) } })) {
                        rowText("Auto-review", detail: host.approvalsOff
                                ? "Approvals are off on this computer: risky actions run without asking."
                                : "A reviewer lets safe shell, MCP and computer actions through and asks you about risky ones.")
                    }
                    .tint(SimpleBotColor.green.color)
                    .disabled(host.isSaving)
                    .padding(.horizontal, BighelpTokens.space20)
                    .padding(.vertical, BighelpTokens.space12)
                    .accessibilityIdentifier("simple-bots.settings.auto-review")
                    SimpleBotsDivider()
                    Button { isRulesPresented = true } label: {
                        SimpleBotsRow(title: "Auto-review Rules", value: host.rules.isEmpty ? "None" : "Set")
                    }
                    .buttonStyle(.plain)
                    .disabled(!host.autoReview)
                    .accessibilityIdentifier("simple-bots.settings.rules")
                    SimpleBotsDivider()
                    Toggle(isOn: Binding(get: { automaticTimeZone }, set: { on in
                        automaticTimeZone = on
                        if on { Task { await host.setTimeZone(TimeZone.current.identifier) } }
                    })) {
                        rowText("Set Time Zone Automatically", detail: "Your bots' computer follows this device's time zone.")
                    }
                    .tint(SimpleBotColor.green.color)
                    .padding(.horizontal, BighelpTokens.space20)
                    .padding(.vertical, BighelpTokens.space12)
                    .accessibilityIdentifier("simple-bots.settings.auto-time-zone")
                    SimpleBotsDivider()
                    Button { isTimeZonePresented = true } label: {
                        SimpleBotsRow(title: "Time Zone") {
                            Text(host.timeZone.isEmpty ? "The computer's own" : host.timeZone)
                                .font(.bighelp(.body))
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(automaticTimeZone)
                    .accessibilityIdentifier("simple-bots.settings.time-zone")
                    if let error = host.errorMessage {
                        SimpleBotsDivider()
                        Text(error)
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(BighelpTokens.space16)
                    }
                } else if host?.load == .unavailable {
                    Text("Connect to your bots' computer to change these.")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(BighelpTokens.space20)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 56)
                }
                if let teamwork {
                    SimpleBotsDivider()
                    TeamworkToggle(model: teamwork) { detail in
                        rowText("Teamwork", detail: detail.replacingOccurrences(of: "agents", with: "bots")
                            .replacingOccurrences(of: "agent", with: "bot"))
                    }
                    .tint(SimpleBotColor.green.color)
                    .padding(.horizontal, BighelpTokens.space20)
                    .padding(.vertical, BighelpTokens.space12)
                }
                SimpleBotsDivider()
                Button { if let primary { context.onOpenComputer(primary.id) } } label: {
                    SimpleBotsRow(title: "Bot Computer")
                }
                .buttonStyle(.plain)
                .disabled(primary == nil)
                .accessibilityIdentifier("simple-bots.settings.computer")
            }
        }
    }

    private var appCard: some View {
        SimpleBotsCard {
            NavigationLink(value: SimpleBotsSettingsPage.notifications) {
                SimpleBotsRow(title: "Notifications")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("simple-bots.settings.notifications")
            SimpleBotsDivider()
            NavigationLink(value: SimpleBotsSettingsPage.appearance) {
                SimpleBotsRow(title: "Appearance", value: appearanceSummary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("simple-bots.settings.appearance")
        }
    }

    /// Multi-gateway shows every gateway's bots on the home; off, you pick the one gateway it shows.
    private var gatewaysCard: some View {
        SimpleBotsCard {
            Toggle(isOn: Binding(get: { context.settings.simpleBotsMultiGateway },
                                 set: { context.settings.simpleBotsMultiGateway = $0 })) {
                rowText("Multi-gateway", detail: "Show, use and manage the bots on all your gateways.")
            }
            .tint(SimpleBotColor.green.color)
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.vertical, BighelpTokens.space12)
            .accessibilityIdentifier("simple-bots.settings.multi-gateway")
            if !context.settings.simpleBotsMultiGateway, !context.gateways.hosts.isEmpty {
                SimpleBotsDivider()
                Menu {
                    ForEach(context.gateways.hosts) { host in
                        Button {
                            guard !host.isSelected else { return }
                            context.gateways.select(host.id)
                        } label: {
                            if host.isSelected { Label(host.name, systemImage: "checkmark") } else { Text(host.name) }
                        }
                    }
                } label: {
                    SimpleBotsRow(title: "Active gateway",
                                  value: context.gateways.hosts.first(where: \.isSelected)?.name)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("simple-bots.settings.active-gateway")
            }
        }
    }

    private var modeCard: some View {
        SimpleBotsCard {
            Toggle(isOn: Binding(get: { context.settings.simpleBotsEnabled },
                                 set: { context.settings.simpleBotsEnabled = $0 })) {
                rowText("Simple Bot mode", detail: "Turn off to see everything bighelp can do.")
            }
            .tint(SimpleBotColor.green.color)
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.vertical, BighelpTokens.space12)
            .accessibilityIdentifier("simple-bots.settings.mode")
            SimpleBotsDivider()
            NavigationLink {
                context.allSettings()
            } label: {
                SimpleBotsRow(title: "All Settings")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("simple-bots.settings.all")
        }
    }

    /// "System", "Light" or "Dark".
    private var appearanceSummary: String {
        switch context.settings.appearance {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    private func rowText(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.bighelp(.body)).foregroundStyle(theme.primaryText)
            Text(detail)
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// With the automatic time zone on, coming back after travel moves the bots' clock too.
    private func followDeviceTimeZone() async {
        guard automaticTimeZone, scenePhase == .active, let host = host else { return }
        if host.load != .loaded { await host.refresh() }
        guard host.load == .loaded, host.timeZone != TimeZone.current.identifier else { return }
        await host.setTimeZone(TimeZone.current.identifier)
    }
}

/// Auto-review Rules: extra words for Hermes' reviewer ("Never let it delete files").
@MainActor
private struct SimpleBotRulesEditor: View {
    let host: SimpleBotHostSettings
    @State private var text: String
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    init(host: SimpleBotHostSettings) {
        self.host = host
        _text = State(initialValue: host.rules)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                Text("Tell the reviewer what to always ask you about, in your own words.")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                TextEditor(text: $text)
                    .font(.bighelp(.body))
                    .scrollContentBackground(.hidden)
                    .padding(BighelpTokens.space12)
                    .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius20, style: .continuous))
                    .accessibilityIdentifier("simple-bots.rules.editor")
            }
            .padding(BighelpTokens.space16)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Auto-review Rules")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await host.setRules(text)
                            if host.errorMessage == nil { dismiss() }
                        }
                    }
                    .disabled(host.isSaving)
                }
            }
        }
    }
}

/// Every time zone, searchable.
@MainActor
private struct SimpleBotTimeZonePicker: View {
    let current: String
    let onPick: (String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var zones: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return all }
        return all.filter { $0.replacingOccurrences(of: "_", with: " ").localizedCaseInsensitiveContains(words) }
    }

    var body: some View {
        NavigationStack {
            List(zones, id: \.self) { zone in
                Button { onPick(zone) } label: {
                    HStack {
                        Text(zone.replacingOccurrences(of: "_", with: " "))
                        Spacer()
                        if zone == current { Image(systemName: "checkmark") }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query)
            .navigationTitle("Time Zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
