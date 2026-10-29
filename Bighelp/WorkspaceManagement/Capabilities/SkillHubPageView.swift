import SwiftUI

/// A Hub skill's page: its tile, name, where it comes from and how far Hermes trusts it, and one
/// Add button. Opening the page runs Hermes' preview and security scan, so the verdict and files
/// show before Add (above it when the scan found things to check); a scan that blocks the skill
/// leaves Add off. Add asks once more, then installs exactly the identifier that was scanned,
/// never with a force flag.
@MainActor
struct SkillHubPageView: View {
    @Bindable var model: SkillsHubManagementModel
    let profileName: String
    let item: SkillHubItem

    @State private var confirmsRemoval = false
    @State private var isAdding = false
    @State private var confirmsAdd = false
    @State private var showsMarkdown = false

    private var review: SkillsHubManagementModel.Review? {
        model.review?.id == item.id ? model.review : nil
    }

    var body: some View {
        let item = model.latest(self.item)
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                header(item)
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.bighelp(.body))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Findings to check come before Add, so they're read first.
                if let review, review.scan.policy != .allow { verdict(review.scan) }
                action(item)
                CatalogStatusBanner(support: model.support, isBusy: model.isBusy,
                                    errorMessage: model.errorMessage, successMessage: model.successMessage,
                                    retry: { Task { await model.inspect(item) } })
                    .padding(.horizontal, -CatalogMetrics.margin)
                if let review {
                    if review.scan.policy == .allow { verdict(review.scan) }
                    files(review.preview)
                }
            }
            .padding(.horizontal, CatalogMetrics.margin)
            .padding(.vertical, BighelpTokens.space16)
        }
        .catalogPage()
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: item.id) {
            model.clearMessages()
            if !item.isInstalled, review == nil { await model.inspect(item) }
        }
        .confirmationDialog(Text("Add \(item.name)?"), isPresented: $confirmsAdd, titleVisibility: .visible) {
            Button(review?.scan.policy == .ask ? "Add anyway" : "Add") {
                Task {
                    await model.installReviewed(item.id)
                    if model.errorMessage == nil { isAdding = true }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(addMessage(item))
        }
        .confirmationDialog("Remove this skill?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove \(item.name)", role: .destructive) { Task { await model.uninstall(item) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes removes only this Hub skill from \(profileName).")
        }
        .accessibilityIdentifier("skill.page")
    }

    private func header(_ item: SkillHubItem) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack(alignment: .center, spacing: BighelpTokens.space16) {
                CatalogCategoryTile(category: CatalogCategory(id: item.tileKey), symbolSize: 40,
                                    cornerRadius: CatalogMetrics.heroRadius)
                    .frame(width: 96, height: 96)
                Text(item.name)
                    .font(.bighelp(.title, weight: .heavy))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            if let repository = item.repository, !repository.isEmpty {
                Text("From \(repository)")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            BighelpFlowLayout(spacing: 6) {
                if !item.trustLevel.isEmpty { CatalogBadge(text: item.trustLevel, style: .tier) }
                if !item.source.isEmpty { CatalogBadge(text: model.sourceLabel(item.source)) }
                if let category = item.catalogCategory { CatalogBadge(text: category.title) }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func action(_ item: SkillHubItem) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            if item.isInstalled {
                Label("On \(profileName)", systemImage: "checkmark.circle.fill")
                    .font(.bighelp(.body, weight: .semibold))
                Button(role: .destructive) { confirmsRemoval = true } label: {
                    Text("Remove")
                        .font(.bighelp(.body, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                        .background(theme.surface, in: Capsule())
                        .contentShape(Capsule())
                }
                .bighelpPlainButtonStyle(.capsule)
                .foregroundStyle(theme.danger)
                .disabled(model.isBusy)
                .accessibilityIdentifier("skill.remove")
            } else if isAdding {
                Label("Hermes is adding it to \(profileName).", systemImage: "arrow.down.circle")
                    .font(.bighelp(.body, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let review {
                if review.scan.policy == .block {
                    CatalogPrimaryButton(title: String(localized: "Blocked by Hermes' scan"), isEnabled: false) {}
                        .accessibilityIdentifier("skill.add")
                    note("Hermes blocked this skill, so it can't be added. bighelp never forces it.")
                } else {
                    CatalogPrimaryButton(title: model.isBusy ? String(localized: "Adding…")
                                                             : String(localized: "Add to \(profileName)"),
                                         isEnabled: !model.isBusy) {
                        confirmsAdd = true
                    }
                    .accessibilityIdentifier("skill.add")
                    note(review.scan.policy == .ask
                         ? "Hermes' scan found things to look at first. They're listed above."
                         : "Hermes checked this skill. Add installs exactly what it checked.")
                }
            } else {
                CatalogPrimaryButton(title: model.isBusy ? String(localized: "Checking this skill…")
                                                         : String(localized: "Check and add"),
                                     isEnabled: !model.isBusy) {
                    Task { await model.inspect(item) }
                }
                .accessibilityIdentifier("skill.add")
                note("Hermes checks a skill before it can be added.")
            }
        }
    }

    private func verdict(_ scan: SkillHubScan) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Text("Hermes' check")
                .font(.bighelp(.title3, weight: .heavy))
                .accessibilityAddTraits(.isHeader)
            CatalogFactCard {
                CatalogFactRow(title: String(localized: "Verdict"), value: scan.verdict.capitalized, detail: scan.summary)
                CatalogFactDivider()
                CatalogFactRow(title: String(localized: "Decision"), value: Self.decision(scan.policy),
                               detail: scan.policyReason)
                ForEach(scan.findings.prefix(100)) { finding in
                    CatalogFactDivider()
                    CatalogFactRow(
                        title: "\(finding.severity.capitalized) · \(finding.category)", value: "",
                        detail: [finding.detail, finding.file.isEmpty ? nil
                                 : finding.line.map { "\(finding.file):\($0)" } ?? finding.file]
                            .compactMap { $0 }.joined(separator: "\n"))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("skill.verdict")
        }
    }

    private func files(_ preview: SkillHubPreview) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Text("Files")
                .font(.bighelp(.title3, weight: .heavy))
                .accessibilityAddTraits(.isHeader)
            CatalogFactCard {
                CatalogFactRow(title: String(localized: "In this skill"), value: preview.files.count.formatted(),
                               detail: preview.files.prefix(50).joined(separator: "\n"), monospaced: true)
                if !preview.skillMarkdown.isEmpty {
                    CatalogFactDivider()
                    DisclosureGroup(isExpanded: $showsMarkdown) {
                        Text(String(preview.skillMarkdown.prefix(20_000)))
                            .font(.bighelp(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, BighelpTokens.space8)
                    } label: {
                        Text("Read SKILL.md").font(.bighelp(.subheadline, weight: .bold))
                            .frame(minHeight: BighelpTokens.hitTarget)
                    }
                    .padding(.horizontal, CatalogMetrics.margin)
                    .padding(.vertical, BighelpTokens.space4)
                }
            }
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.bighelp(.footnote))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func addMessage(_ item: SkillHubItem) -> String {
        guard let scan = review?.scan, scan.policy == .ask else {
            return String(localized: "Hermes' scan found nothing to check. \(item.name) is added to \(profileName) for new chats.")
        }
        let count = max(scan.findings.count, 1)
        return String(localized: "Hermes' scan found \(count.formatted()) \(count == 1 ? "thing" : "things") to check. Add \(item.name) anyway?")
    }

    private static func decision(_ policy: SkillHubScan.Policy) -> String {
        switch policy {
        case .allow: String(localized: "Allowed")
        case .ask: String(localized: "Look first")
        case .block: String(localized: "Blocked")
        }
    }

    @BighelpThemeReader private var theme
}
