import SwiftUI

@MainActor
struct HermesAchievementsView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case unlocked = "Unlocked"
        case inProgress = "In Progress"
        case secret = "Secret"
        var id: String { rawValue }
    }

    @Bindable var store: HermesAchievementsStore
    @State private var filter: Filter = .all

    var body: some View {
        Group {
            if !store.ownsScope {
                ContentUnavailableView(
                    "Workspace changed", systemImage: "trophy.slash",
                    description: Text("Return to Workspace and reopen Achievements on the selected host.")
                )
            } else if store.mount == .unavailable {
                ContentUnavailableView(
                    "Achievements unavailable", systemImage: "trophy.slash",
                    description: Text("This destination appears only when the selected Hermes host mounts the bundled Achievements dashboard plugin.")
                )
            } else {
                List {
                    Section("Overview") {
                        LabeledContent("Host", value: store.hostName)
                        if let status = store.status {
                            LabeledContent("Scanner", value: status.state.rawValue.capitalized)
                            LabeledContent("Completed runs", value: String(status.runCount))
                        }
                        if let message = store.statusMessage {
                            Text(message).font(.bighelp(.footnote)).foregroundStyle(.secondary)
                        }
                    }
                    feedback
                    if let catalog = store.catalog {
                        Section("Progress") {
                            LabeledContent("Unlocked", value: "\(catalog.unlockedCount) of \(catalog.totalCount)")
                            LabeledContent("Discovered", value: String(catalog.discoveredCount))
                            LabeledContent("Still secret", value: String(catalog.secretCount))
                            LabeledContent("Sessions scanned", value: String(catalog.sessionsTotal))
                            if catalog.isStale {
                                Label("Hermes marks this snapshot as stale.", systemImage: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Section {
                            Picker("Show", selection: $filter) {
                                ForEach(Filter.allCases) { value in Text(value.rawValue).tag(value) }
                            }
                            .bighelpSegmentedPicker()
                        }
                        ForEach(categories(in: catalog), id: \.self) { category in
                            Section(category) {
                                ForEach(filtered(catalog).filter { $0.category == category }) { achievement in
                                    NavigationLink {
                                        HermesAchievementDetailView(achievement: achievement)
                                    } label: {
                                        HermesAchievementRow(achievement: achievement)
                                    }
                                    .accessibilityIdentifier("achievement.\(achievement.id)")
                                }
                            }
                        }
                    } else if store.mount == .available && !store.isLoading {
                        Section {
                            ContentUnavailableView(
                                "No snapshot loaded", systemImage: "trophy",
                                description: Text("Refresh reads the plugin catalog. On a reset or stale cache, Hermes may start its documented background scan.")
                            )
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .bighelpRefreshable { await store.refresh() }
            }
        }
        .navigationTitle("Achievements")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.mount == .available {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Section("Maintenance") {
                            Button("Force Rescan", systemImage: "arrow.clockwise") {
                                Task { await store.prepare(.rescan) }
                            }
                            Button("Reset", systemImage: "trash", role: .destructive) {
                                Task { await store.prepare(.reset) }
                            }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .disabled(!store.canAct || store.catalog == nil)
                }
            }
        }
        .task { if store.mount == .unknown { await store.load() } }
        .confirmationDialog(
            reviewTitle,
            isPresented: Binding(
                get: { store.review != nil },
                set: { if !$0 { store.review = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let review = store.review {
                Button(review.action == .reset ? "Reset Achievement State" : "Start Full Rescan",
                       role: review.action == .reset ? .destructive : nil) {
                    Task { await store.confirm(review) }
                }
                Button("Cancel", role: .cancel) { store.review = nil }
            }
        } message: {
            if let review = store.review {
                if review.action == .reset {
                    Text("Clear \(review.unlockedCount) recorded unlocks and the cached scan/checkpoint for \(review.totalCount) achievements. The current scanner revision is checked again before reset.")
                } else {
                    Text("Force a synchronous scan of the complete Hermes session history. Large histories can take minutes; bighelp will show running or failed status without claiming success early.")
                }
            }
        }
        .onChange(of: store.ownsScope) { _, current in if !current { store.retire() } }
        .accessibilityIdentifier("hermes.achievements")
    }

    @ViewBuilder
    private var feedback: some View {
        if store.isLoading || store.isMutating || store.status?.state == .running {
            Section {
                ProgressView(store.isMutating ? "Waiting for Hermes job status" : "Loading achievements")
            }
        }
        if let message = store.errorMessage {
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                Button("Refresh Status") { Task { await store.refresh() } }
                    .disabled(store.isLoading || store.isMutating)
            }
        }
        if let message = store.successMessage {
            Section { Label(message, systemImage: "checkmark.circle") }
        }
    }

    private var reviewTitle: String {
        switch store.review?.action {
        case .reset: "Reset achievement history?"
        case .rescan: "Scan all Hermes sessions?"
        case nil: "Review Achievements action"
        }
    }

    private func filtered(_ catalog: HermesAchievementsCatalog) -> [HermesAchievement] {
        switch filter {
        case .all: catalog.achievements
        case .unlocked: catalog.achievements.filter(\.isUnlocked)
        case .inProgress: catalog.achievements.filter { !$0.isUnlocked && $0.isDiscovered }
        case .secret: catalog.achievements.filter { $0.state == "secret" }
        }
    }

    private func categories(in catalog: HermesAchievementsCatalog) -> [String] {
        var seen = Set<String>()
        return filtered(catalog).compactMap { seen.insert($0.category).inserted ? $0.category : nil }
    }
}

private struct HermesAchievementRow: View {
    let achievement: HermesAchievement

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: achievement.isUnlocked ? "trophy.fill" : (achievement.state == "secret" ? "questionmark.circle" : "trophy"))
                    .foregroundStyle(achievement.isUnlocked ? .yellow : .secondary)
                    .accessibilityHidden(true)
                Text(achievement.name).font(.bighelp(.headline))
                Spacer()
                if let tier = achievement.tier { Text(tier).font(.bighelp(.caption)).foregroundStyle(.secondary) }
            }
            Text(achievement.summary).font(.bighelp(.subheadline)).foregroundStyle(.secondary).lineLimit(2)
            ProgressView(value: Double(achievement.progressPercent), total: 100)
                .accessibilityLabel("Achievement progress")
                .accessibilityValue("\(achievement.progressPercent) percent")
        }
        .padding(.vertical, 4)
    }
}

private struct HermesAchievementDetailView: View {
    let achievement: HermesAchievement

    var body: some View {
        List {
            Section("Status") {
                LabeledContent("State", value: achievement.state.capitalized)
                LabeledContent("Progress", value: "\(achievement.progressPercent)%")
                if let tier = achievement.tier { LabeledContent("Tier", value: tier) }
                if let next = achievement.nextTier, let threshold = achievement.nextThreshold {
                    LabeledContent("Next", value: "\(next) at \(threshold)")
                }
                if let unlockedAt = achievement.unlockedAt {
                    LabeledContent("Unlocked", value: unlockedAt.formatted())
                }
            }
            Section("About") {
                Text(achievement.summary)
                Text(achievement.criteria).foregroundStyle(.secondary)
            }
            if let evidence = achievement.evidence {
                Section("Evidence") {
                    if let title = evidence.sessionTitle { LabeledContent("Session", value: title) }
                    if let value = evidence.value { LabeledContent("Observed value", value: String(value)) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(achievement.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
