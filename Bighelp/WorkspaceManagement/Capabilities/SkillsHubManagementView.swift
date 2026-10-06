import SwiftUI

@MainActor
struct SkillsHubManagementView: View {
    @Bindable var model: SkillsHubManagementModel
    let hostName: String
    let profileName: String
    @State private var uninstallCandidate: SkillHubItem?
    @State private var toggleCandidate: InstalledSkill?
    @State private var visibleLimit = 40

    var body: some View {
        List {
            CapabilitiesScopeSection(hostName: hostName, profileName: profileName)
            CapabilitiesStatusSections(
                support: model.support, isBusy: model.isBusy,
                errorMessage: model.errorMessage, successMessage: model.successMessage,
                retry: { Task { await model.load() } }
            )
            if let snapshot = model.snapshot {
                let installed = snapshot.installedSkills.filter {
                    ManagementSearch.matches(model.query, $0.name, $0.summary, $0.category)
                }
                if !ManagementSearch.isActive(model.query) || !installed.isEmpty {
                    Section {
                        if snapshot.installedSkills.isEmpty {
                            Text("No active skills were reported.").foregroundStyle(.secondary)
                        }
                        ForEach(installed) { skill in
                            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                        Text(skill.name).font(.bighelp(.headline))
                                        Text([skill.category, skill.provenance].filter { !$0.isEmpty }.joined(separator: " • "))
                                            .font(.bighelp(.caption)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(skill.isEnabled ? "Enabled" : "Disabled").font(.bighelp(.caption))
                                }
                                if !skill.summary.isEmpty { Text(skill.summary).font(.bighelp(.subheadline)) }
                                Button(skill.isEnabled ? "Disable this skill" : "Enable this skill") {
                                    toggleCandidate = skill
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    } header: { Text("Your skills") }
                      footer: {
                        Text("A disabled skill stays visible here only after Hermes confirms it is absent, so you can turn it back on.")
                    }
                }

                Section {
                    Picker("Source", selection: $model.source) {
                        Text("All sources").tag("all")
                        ForEach(snapshot.sources.filter(\.isSearchable)) { source in
                            Text(source.label).tag(source.id)
                        }
                    }
                    Button("Search the Skills Hub", systemImage: "magnifyingglass") { Task { await model.search() } }
                        .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .accessibilityIdentifier("skills.hub.search")
                } header: { Text("Find skills") }
                  footer: { Text("Results come from this host’s configured sources and are scanned before installation.") }

                if let result = model.searchResult {
                    skillRows(title: "Search results", items: result.items)
                    if !result.timedOutSources.isEmpty {
                        Section("Search issues") {
                            Text(result.timedOutSources.joined(separator: ", ")).foregroundStyle(.secondary)
                        }
                    }
                } else if !snapshot.featured.isEmpty, !ManagementSearch.isActive(model.query) {
                    skillRows(title: "Featured", items: snapshot.featured)
                }

                let official = snapshot.official.filter {
                    ManagementSearch.matches(model.query, $0.name, $0.summary, $0.category)
                }
                if !ManagementSearch.isActive(model.query) || !official.isEmpty {
                    skillRows(title: "Official skills", items: Array(official.prefix(visibleLimit)))
                }
                if official.count > visibleLimit {
                    Section {
                        Button("Show more official skills") { visibleLimit += 40 }
                            .frame(minHeight: BighelpTokens.hitTarget)
                    }
                }

                Section {
                    Button("Check installed Hub skills for updates", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await model.updateInstalled() }
                    }
                    .disabled(model.isBusy || snapshot.installedIdentifiers.isEmpty)
                    .frame(minHeight: BighelpTokens.hitTarget)
                } header: { Text("Advanced") } footer: {
                    Text("Updates stay pending until a later refresh reports the resulting catalog state.")
                }
            }
        }
        .listStyle(.insetGrouped)
        // Typing narrows your skills and the official list; Return also searches the Hub.
        .searchable(text: $model.query, prompt: "Search skills")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(of: .search) { Task { await model.search() } }
        .onChange(of: model.query) { _, query in
            if !ManagementSearch.isActive(query) { model.clearSearch() }
        }
        .refreshable { await model.load() }
        .task { if model.snapshot == nil { await model.load() } }
        .bighelpSheet(item: Binding(
            get: { model.review },
            set: { if $0 == nil { model.dismissReview() } }
        )) { review in
            SkillHubInstallReviewView(
                review: review,
                isBusy: model.isBusy,
                install: { Task { await model.installReviewed() } },
                cancel: { model.dismissReview() }
            )
            .bighelpSheetSize(.standard)
        }
        .confirmationDialog(
            "Change this skill’s enabled state?",
            isPresented: Binding(get: { toggleCandidate != nil }, set: { if !$0 { toggleCandidate = nil } }),
            titleVisibility: .visible
        ) {
            if let skill = toggleCandidate {
                Button(skill.isEnabled ? "Disable \(skill.name)" : "Enable \(skill.name)") {
                    toggleCandidate = nil
                    Task { await model.setEnabled(!skill.isEnabled, skill: skill) }
                }
            }
            Button("Cancel", role: .cancel) { toggleCandidate = nil }
        } message: {
            Text("Only the selected profile skill is changed. The updated tool prompt applies to new sessions.")
        }
        .confirmationDialog(
            "Uninstall this skill?",
            isPresented: Binding(get: { uninstallCandidate != nil }, set: { if !$0 { uninstallCandidate = nil } }),
            titleVisibility: .visible
        ) {
            if let item = uninstallCandidate {
                Button("Uninstall \(item.name)", role: .destructive) {
                    uninstallCandidate = nil
                    Task { await model.uninstall(item) }
                }
            }
            Button("Cancel", role: .cancel) { uninstallCandidate = nil }
        } message: {
            Text("Hermes will remove the selected Hub-managed skill from this profile. No other skill is selected by this action.")
        }
    }

    @ViewBuilder
    private func skillRows(title: String, items: [SkillHubItem]) -> some View {
        Section(title) {
            if items.isEmpty { Text("No skills in this view.").foregroundStyle(.secondary) }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    HStack {
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            Text(item.name).font(.bighelp(.headline))
                            Text([item.category, item.source, item.trustLevel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • "))
                                .font(.bighelp(.caption)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if item.isInstalled { Image(systemName: "checkmark.circle.fill").accessibilityLabel("Installed") }
                    }
                    if !item.summary.isEmpty { Text(item.summary).font(.bighelp(.subheadline)) }
                    HStack {
                        Button(item.isInstalled ? "Review" : "Preview & scan") {
                            Task { await model.inspect(item) }
                        }
                        .buttonStyle(.bordered)
                        if item.isInstalled {
                            Button("Uninstall", role: .destructive) { uninstallCandidate = item }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.vertical, BighelpTokens.space4)
                .accessibilityIdentifier("skills.hub.\(item.id)")
            }
        }
    }
}

private struct SkillHubInstallReviewView: View {
    let review: SkillsHubManagementModel.Review
    let isBusy: Bool
    let install: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Skill source") {
                    LabeledContent("Name", value: review.preview.item.name)
                    LabeledContent("Source", value: review.preview.item.source)
                    LabeledContent("Trust", value: review.preview.item.trustLevel)
                    if let repository = review.preview.item.repository {
                        LabeledContent("Repository", value: repository).textSelection(.enabled)
                    }
                }
                Section("Security review") {
                    LabeledContent("Policy", value: review.scan.policy.rawValue.capitalized)
                    LabeledContent("Verdict", value: review.scan.verdict)
                    Text(review.scan.summary)
                    if !review.scan.policyReason.isEmpty {
                        Text(review.scan.policyReason).font(.bighelp(.footnote)).foregroundStyle(.secondary)
                    }
                    ForEach(review.scan.findings.prefix(100)) { finding in
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            Text("\(finding.severity.capitalized) • \(finding.category)").font(.bighelp(.headline))
                            Text(finding.detail)
                            if !finding.file.isEmpty {
                                Text(finding.line.map { "\(finding.file):\($0)" } ?? finding.file)
                                    .font(.bighelp(.caption)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Preview") {
                    LabeledContent("Files", value: review.preview.files.count.formatted())
                    if review.preview.skillMarkdown.isEmpty {
                        Text("This source did not provide a text preview.").foregroundStyle(.secondary)
                    } else {
                        Text(String(review.preview.skillMarkdown.prefix(20_000)))
                            .font(.bighelp(.footnote).monospaced())
                            .textSelection(.enabled)
                    }
                }
                Section {
                    Button("Install this reviewed skill") { install() }
                        .disabled(isBusy || review.scan.policy == .block || review.preview.item.isInstalled)
                        .frame(minHeight: BighelpTokens.hitTarget)
                } footer: {
                    Text(review.scan.policy == .block
                         ? "Hermes blocked installation. bighelp will not force it."
                         : "This installs only the displayed identifier. bighelp never sends a force-install flag.")
                }
            }
            .navigationTitle("Review installation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).bighelpToolbarText() }
            }
        }
    }
}
