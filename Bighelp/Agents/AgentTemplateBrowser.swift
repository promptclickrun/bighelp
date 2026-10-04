import SwiftUI

/// Every agent template from the catalog: search, newest or most used, and bighelp's own only.
/// Picking one fills in the editor like the Templates rail.
struct AgentTemplateBrowser: View {
    let onPick: (AgentSoulTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var order = BoardBlueprintsSheet.BlueprintOrder.forYou
    @State private var officialOnly = false

    var body: some View {
        let shown = AgentTemplateBrowsing.sorted(
            AgentTemplateBrowsing.filter(AgentSoulTemplate.all, search: search, officialOnly: officialOnly),
            by: order, usage: TemplateUsage.shared)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                    HStack(spacing: BighelpTokens.space12) {
                        Picker("Order", selection: $order) {
                            ForEach(BoardBlueprintsSheet.BlueprintOrder.allCases) { Text($0.title).tag($0) }
                        }
                        .bighelpSegmentedPicker()
                        .accessibilityIdentifier("agent.templates.order")
                    }
                    Toggle(isOn: $officialOnly) {
                        Label("bighelp only", systemImage: "checkmark.seal.fill")
                            .font(.bighelp(.subheadline).weight(.semibold))
                    }
                    .tint(theme.action)
                    .accessibilityIdentifier("agent.templates.official")
                    if shown.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: BighelpTokens.space12)],
                                  spacing: BighelpTokens.space12) {
                            ForEach(shown) { template in card(template) }
                        }
                    }
                    Link(destination: TemplateCatalogPolicy.submitURL) {
                        Label("Share yours", systemImage: "square.and.arrow.up")
                            .font(.bighelp(.subheadline).weight(.semibold))
                    }
                    .accessibilityIdentifier("agent.templates.share")
                }
                .padding(BighelpTokens.space16)
                .animation(.snappy, value: order)
                .animation(.snappy, value: officialOnly)
            }
            .background(theme.canvas.ignoresSafeArea())
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search templates")
            .navigationTitle("Agent templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .bighelpToolbarText()
                        .accessibilityIdentifier("agent.templates.done")
                }
            }
        }
        .accessibilityIdentifier("agent.templates.browser")
    }

    private func card(_ template: AgentSoulTemplate) -> some View {
        let uses = TemplateUsage.shared.count(AgentTemplateBrowsing.usageID(template))
        return Button {
            onPick(template)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Image(systemName: template.systemImage)
                    .font(.bighelp(.title3))
                    .foregroundStyle(theme.action)
                    .frame(height: 28)
                    .accessibilityHidden(true)
                Text(verbatim: template.title)
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(verbatim: template.profile)
                    .font(.bighelp(.subheadline).weight(.medium))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
                if !template.strength.isEmpty {
                    Text(verbatim: template.strength)
                        .font(.bighelp(.caption))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(3)
                }
                Spacer(minLength: BighelpTokens.space4)
                HStack(spacing: BighelpTokens.space4) {
                    if !template.isCommunity {
                        Label("bighelp", systemImage: "checkmark.seal.fill").foregroundStyle(theme.action)
                    } else if let credit = template.credit {
                        Text(verbatim: "by @\(credit)")
                    } else {
                        Text("Community")
                    }
                    if uses > 0 { Text(uses == 1 ? "· Used once" : "· Used \(uses) times") }
                }
                .font(.bighelp(.caption2).weight(.medium))
                .foregroundStyle(theme.tertiaryText)
                .labelStyle(.titleAndIcon)
            }
            .padding(BighelpTokens.space12)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius20))
            .overlay {
                RoundedRectangle(cornerRadius: BighelpTokens.radius20).strokeBorder(theme.border)
            }
            .contentShape(.rect(cornerRadius: BighelpTokens.radius20))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(template.title), \(template.profile)")
        .accessibilityIdentifier("agent.templates.\(template.id)")
    }

    @BighelpThemeReader private var theme
}

enum AgentTemplateBrowsing {
    static func usageID(_ template: AgentSoulTemplate) -> String { "agent:" + template.id }

    static func filter(_ items: [AgentSoulTemplate], search: String, officialOnly: Bool) -> [AgentSoulTemplate] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        return items.filter { template in
            let text = [template.title, template.profile, template.voice, template.strength, template.credit ?? ""]
                .joined(separator: " ").lowercased()
            return (!officialOnly || !template.isCommunity) && words.allSatisfy { text.contains($0) }
        }
    }

    @MainActor
    static func sorted(_ items: [AgentSoulTemplate], by order: BoardBlueprintsSheet.BlueprintOrder,
                       usage: TemplateUsage) -> [AgentSoulTemplate] {
        let indexed = Array(items.enumerated())
        switch order {
        case .forYou:
            return items
        case .newest:
            return indexed.sorted { lhs, rhs in
                let left = lhs.element.updatedAt ?? .distantPast, right = rhs.element.updatedAt ?? .distantPast
                return left == right ? lhs.offset < rhs.offset : left > right
            }.map(\.element)
        case .mostUsed:
            return indexed.sorted { lhs, rhs in
                let left = usage.count(usageID(lhs.element)), right = usage.count(usageID(rhs.element))
                return left == right ? lhs.offset < rhs.offset : left > right
            }.map(\.element)
        }
    }
}
