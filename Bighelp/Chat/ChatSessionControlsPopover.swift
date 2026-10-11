import SwiftUI

enum ChatSessionControlsPresentation {
    /// Tall enough for the model card, the filters and about five models.
    static func preferredHeight(isVerticallyCompact: Bool) -> CGFloat {
        isVerticallyCompact ? 320 : 640
    }

    static func surfacePresentation(
        isDarkMode: Bool
    ) -> BighelpPickerSheetSurfacePresentation {
        .resolve(isDarkMode: isDarkMode)
    }
}

/// Which models the list shows: pinned, recent, or one provider's. Search looks through all of them.
enum ChatModelListFilter: Hashable, Sendable {
    case pinned
    case recent
    case provider(String)
}

struct ChatModelListItem: Identifiable, Equatable, Sendable {
    let providerID: String
    let providerName: String
    let modelID: String
    var id: String { providerID + ":" + modelID }
}

/// Model & reasoning for one chat, on one screen: the chosen model and its
/// reasoning slider stay on top, and below them a short list (pinned by
/// default) with search and a filter per provider, so nothing needs a long
/// scroll. Nothing changes until Apply.
struct ChatSessionControlsPopover: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Bindable var controls: SessionRuntimeControlModel
    let usesWideLayout: Bool
    let onApplied: () -> Void

    @State private var draft: SessionRuntimeSelectionDraft
    @State private var confirmationToSubmit: SessionRuntimeModelConfirmation?
    @State private var searchText = ""
    @State private var filter: ChatModelListFilter?

    init(controls: SessionRuntimeControlModel, usesWideLayout: Bool, onApplied: @escaping () -> Void) {
        self.controls = controls
        self.usesWideLayout = usesWideLayout
        self.onApplied = onApplied
        _draft = State(initialValue: SessionRuntimeSelectionDraft(
            providerID: controls.currentProvider,
            modelID: controls.currentModel,
            reasoningValue: controls.currentReasoningValue
        ))
    }

    var body: some View {
        content
            .foregroundStyle(theme.primaryText)
            // `.contain` keeps the rows', search's and buttons' own identifiers reachable.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.session-controls.popover")
            #if targetEnvironment(macCatalyst)
            // The Mac pop-up sizes itself to the window (ChatSessionControlsMacPopover).
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #else
            .frame(minWidth: 300, idealWidth: usesWideLayout ? 560 : 360, maxWidth: usesWideLayout ? 560 : 400)
            .frame(height: ChatSessionControlsPresentation.preferredHeight(isVerticallyCompact: isVerticallyCompact))
            #endif
            .bighelpSurface(BighelpPickerSheetLayout.rootSurfaceRole, tint: .none)
            .task {
                await controls.loadPickersIfNeeded()
                guard !draft.hasChanges else { return }
                draft = SessionRuntimeSelectionDraft(
                    providerID: controls.currentProvider,
                    modelID: controls.currentModel,
                    reasoningValue: controls.currentReasoningValue
                )
            }
            .overlay {
                if controls.isApplyingSelection {
                    BighelpThinkingOrb(scenario: .working, scale: .inline)
                        .padding(BighelpTokens.space12)
                        .background(.regularMaterial, in: .circle)
                        .accessibilityLabel("Updating this session")
                }
            }
            .modifier(BighelpModelConfirmationModifier(
                confirmation: controls.pendingModelConfirmation,
                onConfirm: { confirmationToSubmit = $0 },
                onCancel: { controls.cancelModelConfirmation(expected: $0) }
            ))
            .task(id: confirmationToSubmit?.id) {
                guard !Task.isCancelled, let confirmationToSubmit,
                      await controls.confirmModelSelection(confirmationToSubmit), !Task.isCancelled else { return }
                await controls.loadPickersIfNeeded()
                guard !Task.isCancelled, controls.errorMessage == nil else { return }
                onApplied()
            }
            .onDisappear { confirmationToSubmit = nil }
            .onChange(of: [controls.currentProvider, controls.currentModel, controls.currentReasoningValue]) { _, _ in
                draft.reconcile(providerID: controls.currentProvider, modelID: controls.currentModel,
                                reasoningValue: controls.currentReasoningValue)
            }
    }

    private var isVerticallyCompact: Bool { verticalSizeClass == .compact }

    /// The top stays put while the list scrolls. A landscape phone has no room
    /// for both, so there everything scrolls together, reasoning still first.
    @ViewBuilder
    private var content: some View {
        if isVerticallyCompact {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space12) { top; modelList; buttons }
                    .padding(BighelpTokens.space16)
            }
        } else {
            VStack(spacing: 0) {
                top
                    .padding([.horizontal, .top], BighelpTokens.space16)
                    .padding(.bottom, BighelpTokens.space12)
                ScrollView {
                    modelList
                        .padding(.horizontal, BighelpTokens.space16)
                        .padding(.bottom, BighelpTokens.space12)
                }
                .dismissesKeyboardOnScroll(true)
                buttons
                    .padding(.horizontal, BighelpTokens.space16)
                    .padding(.vertical, BighelpTokens.space12)
            }
        }
    }

    private var top: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text("Model & reasoning").bighelpFont(.sectionTitle)
                Text("This chat only").bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
            }
            if let errorMessage = controls.errorMessage {
                BighelpInlineNotice(
                    message: errorMessage,
                    actionTitle: "Retry",
                    actionIdentifier: "chat.session-controls-retry",
                    isActionEnabled: !(controls.isLoadingModel || controls.isLoadingReasoning),
                    action: { Task { await controls.loadPickersIfNeeded() } },
                    onDismiss: controls.clearError
                )
            }
            selectionCard
            BighelpSearchField(
                text: $searchText,
                prompt: allItems.isEmpty ? "Search models" : "Search \(allItems.count) models",
                accessibilityLabel: "Search models",
                accessibilityIdentifier: "chat.models.search"
            )
            if searchText.isEmpty, !filters.isEmpty { filterChips }
        }
    }

    /// The model the chat will use, and its reasoning, always in view.
    private var selectionCard: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack(spacing: BighelpTokens.space12) {
                if let providerID = draft.providerID {
                    AIProviderMarkView(providerID: providerID, providerName: providerName(for: providerID),
                                       context: .chatQuickChoice, size: BighelpTokens.scaled(36))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.modelID.map { ModelNameCatalogStore.shared.displayName(for: $0) } ?? "No model reported")
                        .bighelpFont(.label, weight: .semibold)
                        .lineLimit(2)
                    Text(selectionDetail)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.models.selected")
            if let reason = controls.selectionSupport.modelUnavailableReason {
                Text(reason).bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            reasoning
        }
        .padding(BighelpTokens.space16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius20))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius20).stroke(theme.border, lineWidth: BighelpTokens.hairline)
        }
    }

    private var selectionDetail: String {
        let provider = draft.providerID.map { providerName(for: $0) } ?? "Provider not reported"
        let isCurrent = draft.providerID == controls.currentProvider && draft.modelID == controls.currentModel
        return isCurrent ? provider + " · in use" : provider + " · applies when you tap Apply"
    }

    @ViewBuilder
    private var reasoning: some View {
        if (controls.isLoadingReasoning || controls.reasoningPicker == nil) && controls.errorMessage == nil {
            BighelpThinkingOrb(scenario: .searching, scale: .inline, visibleLabel: "Loading reasoning levels")
        } else if controls.reasoningOptions.isEmpty {
            Text("This model has no reasoning levels to choose.")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .accessibilityIdentifier("chat.reasoning-none")
        } else {
            BighelpReasoningSlider(
                choices: controls.reasoningOptions.map {
                    BighelpReasoningChoice(value: $0.value, label: $0.label, detail: $0.detail)
                },
                selectedValue: draft.reasoningValue,
                isEnabled: !controls.isApplyingSelection && controls.selectionSupport.reasoningUnavailableReason == nil,
                accessibilityIdentifier: "chat.reasoning-slider",
                onSelect: { draft.selectReasoning($0) }
            )
        }
    }

    // MARK: The list

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BighelpTokens.space8) {
                ForEach(filters, id: \.self) { option in
                    let selected = option == activeFilter
                    Button { filter = option } label: {
                        HStack(spacing: BighelpTokens.space4) {
                            if option == .pinned { Image(systemName: "star.fill").imageScale(.small) }
                            Text(title(for: option)).bighelpFont(.label, weight: .semibold)
                            Text("\(items(for: option).count)")
                                .bighelpFont(.label)
                                .foregroundStyle(selected ? theme.action.opacity(0.75) : theme.secondaryText)
                        }
                        .foregroundStyle(selected ? theme.action : theme.primaryText)
                        .padding(.horizontal, BighelpTokens.space12)
                        .frame(minHeight: BighelpTokens.scaled(36))
                        .background(selected ? theme.action.opacity(0.14) : theme.secondaryText.opacity(0.1), in: .capsule)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("chat.models.filter.\(identifier(for: option))")
                }
            }
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    private var modelList: some View {
        if controls.modelProviders.isEmpty && (controls.isLoadingModel || controls.modelPicker == nil)
            && controls.errorMessage == nil {
            BighelpThinkingOrb(scenario: .searching, scale: .inline, visibleLabel: "Loading models")
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if shownItems.isEmpty {
            Text(searchText.isEmpty ? "No models here yet." : "No models match \u{201C}\(searchText)\u{201D}.")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(shownItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, BighelpTokens.space16) }
                    row(item)
                }
            }
            .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius20))
            .overlay {
                RoundedRectangle(cornerRadius: BighelpTokens.radius20).stroke(theme.border, lineWidth: BighelpTokens.hairline)
            }
        }
    }

    private func row(_ item: ChatModelListItem) -> some View {
        let selected = draft.providerID == item.providerID && draft.modelID == item.modelID
        let pinned = controls.isModelPinned(providerID: item.providerID, modelID: item.modelID)
        return HStack(spacing: 0) {
            Button {
                draft.selectModel(providerID: item.providerID, modelID: item.modelID)
                // A pick after searching closes the keyboard, so Apply is in view.
                BighelpKeyboard.dismiss()
            } label: {
                HStack(spacing: BighelpTokens.space12) {
                    AIProviderMarkView(providerID: item.providerID, providerName: item.providerName,
                                       context: .chatQuickChoice, size: BighelpTokens.scaled(32))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ModelNameCatalogStore.shared.displayName(for: item.modelID))
                            .bighelpFont(.label, weight: .semibold)
                            .lineLimit(2)
                        Text(item.providerName).bighelpFont(.metadata).foregroundStyle(theme.secondaryText).lineLimit(1)
                    }
                    Spacer(minLength: BighelpTokens.space8)
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.action)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.leading, BighelpTokens.space12)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget + BighelpTokens.space8, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(controls.isApplyingSelection || controls.selectionSupport.modelUnavailableReason != nil)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("chat.models.row.\(item.id)")

            Button {
                controls.toggleModelPin(providerID: item.providerID, modelID: item.modelID)
            } label: {
                Image(systemName: pinned ? "star.fill" : "star")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(pinned ? Color(red: 0.89, green: 0.66, blue: 0.23) : theme.tertiaryText)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pinned ? "Unpin \(ModelNameCatalogStore.shared.displayName(for: item.modelID))"
                                : "Pin \(ModelNameCatalogStore.shared.displayName(for: item.modelID))")
            .accessibilityIdentifier("chat.models.pin.\(item.id)")
        }
        .padding(.trailing, BighelpTokens.space4)
    }

    // MARK: Filters

    /// Every configured provider's models, in the host's order.
    private var allItems: [ChatModelListItem] {
        controls.modelProviders.flatMap { provider in
            let name = providerName(for: provider.id, fallback: provider.name)
            return provider.models.map { ChatModelListItem(providerID: provider.id, providerName: name, modelID: $0) }
        }
    }

    private var pinnedItems: [ChatModelListItem] { controls.pinnedModelChoices.map(item) }
    private var recentItems: [ChatModelListItem] { controls.recentModelChoices.map(item) }

    private var filters: [ChatModelListFilter] {
        (pinnedItems.isEmpty ? [] : [.pinned]) + (recentItems.isEmpty ? [] : [.recent])
            + controls.modelProviders.map { .provider($0.id) }
    }

    /// Pinned first, then recent, then the chat's own provider.
    private var activeFilter: ChatModelListFilter? {
        if let filter, filters.contains(filter) { return filter }
        if !pinnedItems.isEmpty { return .pinned }
        if !recentItems.isEmpty { return .recent }
        if let current = controls.currentProvider, controls.modelProviders.contains(where: { $0.id == current }) {
            return .provider(current)
        }
        return controls.modelProviders.first.map { .provider($0.id) }
    }

    private var shownItems: [ChatModelListItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty else {
            return Array(allItems.filter { item in
                ModelNameCatalogStore.shared.displayName(for: item.modelID).localizedCaseInsensitiveContains(query)
                    || item.modelID.localizedCaseInsensitiveContains(query)
                    || item.providerName.localizedCaseInsensitiveContains(query)
            }.prefix(200))
        }
        return activeFilter.map(items(for:)) ?? []
    }

    private func items(for option: ChatModelListFilter) -> [ChatModelListItem] {
        switch option {
        case .pinned: pinnedItems
        case .recent: recentItems
        case .provider(let id): allItems.filter { $0.providerID == id }
        }
    }

    private func title(for option: ChatModelListFilter) -> String {
        switch option {
        case .pinned: "Pinned"
        case .recent: "Recent"
        case .provider(let id): providerName(for: id)
        }
    }

    private func identifier(for option: ChatModelListFilter) -> String {
        switch option {
        case .pinned: "pinned"
        case .recent: "recent"
        case .provider(let id): "provider.\(id)"
        }
    }

    private func item(_ choice: RecentModelChoice) -> ChatModelListItem {
        ChatModelListItem(providerID: choice.providerID,
                          providerName: providerName(for: choice.providerID, fallback: choice.providerName),
                          modelID: choice.modelID)
    }

    private func providerName(for id: String, fallback: String? = nil) -> String {
        let name = fallback ?? controls.modelProviders.first { $0.id == id }?.name ?? id
        return AIProviderVisibleIdentity.resolve(providerID: id, providerName: name).visibleProviderName
    }

    // MARK: Buttons

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: BighelpTokens.space8) { cancelButton; applyButton }
            VStack(spacing: BighelpTokens.space8) { cancelButton; applyButton }
        }
    }

    private var cancelButton: some View {
        Button { dismiss() } label: {
            Text("Cancel")
                .bighelpFont(.label, weight: .semibold)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .bighelpSurface(.capsuleControl, isInteractive: true)
        .disabled(controls.isApplyingSelection)
        #if targetEnvironment(macCatalyst)
        .keyboardShortcut(.cancelAction)
        #endif
    }

    private var applyButton: some View {
        BighelpModelPickerApplyButton(title: "Apply to chat", hasChanges: draft.hasChanges,
                                    isApplying: controls.isApplyingSelection) {
            Task {
                await controls.apply(draft)
                guard controls.errorMessage == nil, !controls.hasPendingSelection else { return }
                await controls.loadModelPicker()
                guard controls.errorMessage == nil else { return }
                await controls.loadReasoningPicker()
                guard controls.errorMessage == nil else { return }
                onApplied()
            }
        }
        #if targetEnvironment(macCatalyst)
        .keyboardShortcut(.defaultAction)
        #endif
        .disabled(controls.pendingModelConfirmation != nil)
        .accessibilityIdentifier("chat.session-controls.apply")
    }

    @BighelpThemeReader private var theme: BighelpTheme
}

#if targetEnvironment(macCatalyst)
/// The Mac's Model & reasoning pop-up: the same one screen, fitted to the room beside the button.
struct ChatSessionControlsMacPopover: View {
    let controls: SessionRuntimeControlModel
    /// Fits the window; the caller measures the room beside the button.
    let size: CGSize
    let onApplied: () -> Void

    var body: some View {
        ChatSessionControlsPopover(controls: controls, usesWideLayout: true, onApplied: onApplied)
            .frame(width: size.width, height: size.height)
    }
}
#endif
