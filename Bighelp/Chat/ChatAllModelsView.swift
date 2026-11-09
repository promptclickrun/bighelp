import SwiftUI

/// One model a provider offers, as a row of All models.
struct ChatModelListItem: Identifiable, Equatable, Sendable {
    let providerID: String
    let providerName: String
    let modelID: String
    var id: String { providerID + ":" + modelID }
}

/// All models, from a chat's Model settings: search on top, then the starred models and one
/// folding section for each provider. A tap picks a model for the chat at once; the star keeps
/// one on top. The chat's own provider starts unfolded.
struct ChatAllModelsView: View {
    @Bindable var controls: SessionRuntimeControlModel
    let onPick: (_ providerID: String, _ modelID: String) -> Void
    let onDone: () -> Void

    @State private var searchText = ""
    /// The sections the person unfolded or folded, over the default.
    @State private var folding: [String: Bool] = [:]

    private static let starredID = "starred"

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                BighelpSearchField(
                    text: $searchText,
                    prompt: modelCount == 0 ? String(localized: "Search all models")
                        : String(localized: "Search \(modelCount) models"),
                    accessibilityLabel: String(localized: "Search all models"),
                    accessibilityIdentifier: "chat.models.search"
                )
                .padding(.bottom, BighelpTokens.space8)
                if let errorMessage = controls.errorMessage {
                    BighelpInlineNotice(
                        message: errorMessage,
                        actionTitle: "Retry",
                        actionIdentifier: "chat.models.retry",
                        isActionEnabled: !controls.isLoadingModel,
                        action: { Task { await controls.loadModelPickerIfNeeded() } },
                        onDismiss: controls.clearError
                    )
                    .padding(.bottom, BighelpTokens.space8)
                }
                content
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.bottom, BighelpTokens.space24)
        }
        .dismissesKeyboardOnScroll(true)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("All models")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ChatModelSettingsDone(action: onDone) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.models")
    }

    @ViewBuilder
    private var content: some View {
        let sections = shownSections
        if controls.modelProviders.isEmpty, controls.isLoadingModel || controls.modelPicker == nil,
           controls.errorMessage == nil {
            BighelpThinkingOrb(scenario: .searching, scale: .inline, visibleLabel: "Loading models")
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if sections.isEmpty {
            Text(isSearching ? "No models match \u{201C}\(searchText)\u{201D}." : "No models here yet.")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            ForEach(sections) { section in
                header(section)
                if isUnfolded(section) {
                    ForEach(section.models) { model in
                        row(model)
                    }
                }
            }
        }
    }

    // MARK: Sections

    private struct ModelSection: Identifiable {
        let id: String
        let title: String
        /// Nil for Starred, which has no one provider.
        let providerID: String?
        let plan: ModelProviderPlan.Summary?
        let models: [ChatModelListItem]
    }

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var modelCount: Int { controls.modelProviders.reduce(0) { $0 + $1.models.count } }

    /// Starred first, then every provider in the computer's order. A search keeps only what matches.
    private var shownSections: [ModelSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ item: ChatModelListItem) -> Bool {
            query.isEmpty
                || ModelNameCatalogStore.shared.displayName(for: item.modelID).localizedCaseInsensitiveContains(query)
                || item.modelID.localizedCaseInsensitiveContains(query)
                || item.providerName.localizedCaseInsensitiveContains(query)
        }
        let now = Date()
        var sections: [ModelSection] = []
        let starred = controls.pinnedModelChoices.map {
            ChatModelListItem(providerID: $0.providerID, providerName: providerName(for: $0.providerID, fallback: $0.providerName),
                              modelID: $0.modelID)
        }.filter(matches)
        if !starred.isEmpty {
            sections.append(ModelSection(id: Self.starredID, title: String(localized: "Starred"), providerID: nil,
                                         plan: nil, models: starred))
        }
        for provider in controls.modelProviders {
            let name = providerName(for: provider.id, fallback: provider.name)
            let models = provider.models
                .map { ChatModelListItem(providerID: provider.id, providerName: name, modelID: $0) }
                .filter(matches)
            guard !models.isEmpty else { continue }
            sections.append(ModelSection(id: provider.id, title: name, providerID: provider.id,
                                         plan: provider.plan?.summary(now: now), models: models))
        }
        return sections
    }

    /// A search shows what it found. Otherwise Starred and the chat's own provider start unfolded.
    private func isUnfolded(_ section: ModelSection) -> Bool {
        if isSearching { return true }
        return folding[section.id] ?? (section.id == Self.starredID || section.providerID == controls.currentProvider)
    }

    private func header(_ section: ModelSection) -> some View {
        let unfolded = isUnfolded(section)
        return Button {
            folding[section.id] = !unfolded
        } label: {
            HStack(spacing: BighelpTokens.space8) {
                if let providerID = section.providerID {
                    AIProviderMarkView(providerID: providerID, providerName: section.title,
                                       context: .chatSessionCompactControl, size: BighelpTokens.scaled(18))
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "star.fill")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(Self.starColor)
                        .accessibilityHidden(true)
                }
                Text(section.title)
                    .bighelpFont(.label, weight: .semibold)
                    .textCase(.uppercase)
                    .lineLimit(1)
                Text("\(section.models.count)")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                if let plan = section.plan {
                    Text(plan.text)
                        .bighelpFont(.metadata)
                        .foregroundStyle(plan.isLow ? theme.danger : theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: BighelpTokens.space8)
                Image(systemName: unfolded ? "chevron.down" : "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // A search shows every match; there is nothing to fold.
        .disabled(isSearching)
        .accessibilityLabel([section.title, String(localized: "\(section.models.count) models"), section.plan?.text]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(unfolded ? "Shown" : "Hidden")
        .accessibilityIdentifier("chat.models.section.\(section.id)")
    }

    private func row(_ item: ChatModelListItem) -> some View {
        let selected = controls.currentProvider == item.providerID && controls.currentModel == item.modelID
        let starred = controls.isModelPinned(providerID: item.providerID, modelID: item.modelID)
        let name = ModelNameCatalogStore.shared.displayName(for: item.modelID)
        // "Limited until 3:00 PM": this model's own limit, when the plan has run out for it.
        let limit = controls.modelProviders.first { $0.id == item.providerID }?.plan?.modelLimit(item.modelID, now: Date())
        return HStack(spacing: 0) {
            Button {
                BighelpKeyboard.dismiss()
                onPick(item.providerID, item.modelID)
            } label: {
                HStack(spacing: BighelpTokens.space8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .bighelpFont(.body, weight: selected ? .semibold : .regular)
                            .foregroundStyle(selected ? theme.actionForeground : theme.primaryText)
                            .lineLimit(2)
                        if let limit {
                            Text(limit)
                                .bighelpFont(.metadata)
                                .foregroundStyle(selected ? theme.actionForeground : theme.danger)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: BighelpTokens.space8)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(theme.actionForeground)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.leading, BighelpTokens.space12)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(controls.isApplyingSelection || controls.selectionSupport.modelUnavailableReason != nil)
            .accessibilityLabel([name, limit].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("chat.models.row.\(item.id)")

            Button {
                controls.toggleModelPin(providerID: item.providerID, modelID: item.modelID)
            } label: {
                Image(systemName: starred ? "star.fill" : "star")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(starred ? Self.starColor : (selected ? theme.actionForeground : theme.tertiaryText))
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(starred ? "Remove the star from \(name)" : "Star \(name)")
            .accessibilityIdentifier("chat.models.star.\(item.id)")
        }
        .background(selected ? theme.action : Color.clear, in: .rect(cornerRadius: BighelpTokens.space12))
        .padding(.leading, BighelpTokens.space16)
    }

    private static let starColor = Color(red: 0.89, green: 0.66, blue: 0.23)

    private func providerName(for id: String, fallback: String? = nil) -> String {
        let name = fallback ?? controls.modelProviders.first { $0.id == id }?.name ?? id
        return AIProviderVisibleIdentity.resolve(providerID: id, providerName: name).visibleProviderName
    }

    @BighelpThemeReader private var theme: BighelpTheme
}
