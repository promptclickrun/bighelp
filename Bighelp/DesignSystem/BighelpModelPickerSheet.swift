import SwiftUI

struct BighelpModelPickerProviderGroup: Identifiable, Equatable {
    let provider: BighelpLinkModelProvider
    let models: [String]

    var id: String { provider.id }
}

struct BighelpModelPickerDisclosureState: Equatable, Sendable {
    private var expandedProviderIDs = Set<String>()

    init(expandedProviderIDs: Set<String> = []) {
        self.expandedProviderIDs = expandedProviderIDs
    }

    func isExpanded(_ providerID: String) -> Bool {
        expandedProviderIDs.contains(providerID)
    }

    mutating func toggle(_ providerID: String) {
        if expandedProviderIDs.remove(providerID) == nil {
            expandedProviderIDs.insert(providerID)
        }
    }
}

enum BighelpModelPickerFiltering {
    @MainActor
    static func groups(
        providers: [BighelpLinkModelProvider],
        currentProviderID: String?,
        query: String
    ) -> [BighelpModelPickerProviderGroup] {
        groups(
            providers: providers,
            currentProviderID: currentProviderID,
            query: query,
            displayName: { ModelNameCatalogStore.shared.displayName(for: $0) }
        )
    }

    static func groups(
        providers: [BighelpLinkModelProvider],
        currentProviderID: String?,
        query: String,
        displayName: (String) -> String
    ) -> [BighelpModelPickerProviderGroup] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return providers.enumerated()
            .sorted { left, right in
                let leftIsCurrent = left.element.id == currentProviderID
                let rightIsCurrent = right.element.id == currentProviderID
                if leftIsCurrent != rightIsCurrent { return leftIsCurrent }
                return left.offset < right.offset
            }
            .compactMap { _, provider in
                guard !normalizedQuery.isEmpty else {
                    return BighelpModelPickerProviderGroup(
                        provider: provider,
                        models: provider.models
                    )
                }

                let providerMatches = provider.name.localizedCaseInsensitiveContains(normalizedQuery)
                    || provider.id.localizedCaseInsensitiveContains(normalizedQuery)
                let models = providerMatches
                    ? provider.models
                    : provider.models.filter {
                        $0.localizedCaseInsensitiveContains(normalizedQuery)
                            || displayName($0).localizedCaseInsensitiveContains(normalizedQuery)
                    }
                guard !models.isEmpty else { return nil }
                return BighelpModelPickerProviderGroup(provider: provider, models: models)
            }
    }
}

enum BighelpPickerSheetLayout {
    static let rootSurfaceRole: BighelpSurfaceRole = .sheet
    static let panelComponent: BighelpComponentKind = .menuPanel
    static let rowComponent: BighelpComponentKind = .menuRow
    static let searchComponent: BighelpComponentKind = .searchField
    static let dismissButtonStyle: BighelpIconButtonStyle = .neutralGlass
    static let centersProviderHeaders = true
    static let centersModelRows = true
    static let centersReasoningRows = true
}

struct BighelpPickerSheetSurfacePresentation: Equatable, Sendable {
    enum Base: Equatable, Sendable {
        case clear
        case canvas
    }

    let base: Base
    let opacity: Double

    static let usesColoredOutline = false

    static func resolve(isDarkMode: Bool) -> Self {
        isDarkMode
            ? BighelpPickerSheetSurfacePresentation(base: .canvas, opacity: 0.72)
            : BighelpPickerSheetSurfacePresentation(base: .clear, opacity: 0)
    }

    func color(in theme: BighelpTheme) -> Color {
        switch base {
        case .clear: .clear
        case .canvas: theme.canvas
        }
    }

    var surfaceTint: BighelpSurfaceTint {
        switch base {
        case .clear:
            .none
        case .canvas:
            .canvas(opacity: opacity)
        }
    }
}

struct BighelpPickerSheetBackgroundModifier: ViewModifier {
    let usesNativePresentation: Bool
    let legacyTint: BighelpSurfaceTint
    /// A page pushed inside another presentation (the Mac's Model & reasoning
    /// pop-up) draws its own surface and leaves that presentation's background alone.
    var isEmbedded = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.appAppearance) private var appAppearance

    @ViewBuilder
    func body(content: Content) -> some View {
        let theme = BighelpTheme.resolve(
            appearance: appAppearance,
            colorScheme: colorScheme,
            contrast: colorSchemeContrast
        )
        if isEmbedded {
            content.bighelpSurface(BighelpPickerSheetLayout.rootSurfaceRole, tint: .none)
        } else if usesNativePresentation {
            content
                .background(Color.clear)
                .bighelpTranslucentPresentationBackground(fallback: theme.canvas)
        } else {
            content
                .bighelpSurface(BighelpPickerSheetLayout.rootSurfaceRole, tint: legacyTint)
                .presentationBackground(.clear)
        }
    }
}

/// A sheet brings its own navigation stack; a page pushed into one mustn't nest a second.
private struct BighelpPickerNavigation<Content: View>: View {
    let isEmbedded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if isEmbedded {
            content
        } else {
            NavigationStack { content }
                .bighelpSheetSize(.standard)
        }
    }
}

private struct BighelpPickerSearchModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var text: String
    @Binding var isPresented: Bool
    let prompt: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $text, isPresented: $isPresented, prompt: prompt)
        } else {
            content
        }
    }
}

struct BighelpModelPickerApplyPresentation: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case disabled
        case enabled
        case applying
    }

    enum ColorRole: Equatable, Sendable {
        case disabledGray
        case secondaryText
        case action
        case actionForeground
    }

    let state: State
    let background: ColorRole
    let foreground: ColorRole
    let isInteractive: Bool

    static func resolve(hasChanges: Bool, isApplying: Bool) -> Self {
        if isApplying {
            return BighelpModelPickerApplyPresentation(
                state: .applying,
                background: .action,
                foreground: .actionForeground,
                isInteractive: false
            )
        }
        if hasChanges {
            return BighelpModelPickerApplyPresentation(
                state: .enabled,
                background: .action,
                foreground: .actionForeground,
                isInteractive: true
            )
        }
        return BighelpModelPickerApplyPresentation(
            state: .disabled,
            background: .disabledGray,
            foreground: .secondaryText,
            isInteractive: false
        )
    }

    static func disabledBackgroundOpacity(isDarkMode: Bool) -> Double {
        isDarkMode ? 0.28 : 0.10
    }
}

struct BighelpModelPickerApplyButton: View {
    let title: String
    let hasChanges: Bool
    let isApplying: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let presentation = BighelpModelPickerApplyPresentation.resolve(
            hasChanges: hasChanges,
            isApplying: isApplying
        )
        Button(action: action) {
            HStack(spacing: BighelpTokens.space8) {
                if presentation.state == .applying {
                    BighelpThinkingOrb(
                        scenario: .working,
                        scale: .inline,
                        surface: theme.actionThinkingOrbSurface
                    )
                        .accessibilityHidden(true)
                }
                Text(presentation.state == .applying ? "Applying…" : title)
                    .bighelpFont(.label, weight: .semibold)
            }
            .foregroundStyle(foregroundColor(for: presentation))
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.controlHeight)
            .background(backgroundColor(for: presentation), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!presentation.isInteractive)
        .accessibilityValue(accessibilityValue(for: presentation))
    }

    private func backgroundColor(
        for presentation: BighelpModelPickerApplyPresentation
    ) -> Color {
        switch presentation.background {
        case .disabledGray:
            theme.primaryText.opacity(
                BighelpModelPickerApplyPresentation.disabledBackgroundOpacity(
                    isDarkMode: colorScheme == .dark
                )
            )
        case .action:
            theme.action
        case .secondaryText:
            theme.secondaryText
        case .actionForeground:
            theme.actionForeground
        }
    }

    private func foregroundColor(
        for presentation: BighelpModelPickerApplyPresentation
    ) -> Color {
        switch presentation.foreground {
        case .secondaryText, .disabledGray:
            theme.secondaryText
        case .action:
            theme.action
        case .actionForeground:
            theme.actionForeground
        }
    }

    private func accessibilityValue(
        for presentation: BighelpModelPickerApplyPresentation
    ) -> String {
        switch presentation.state {
        case .disabled: "No changes to apply"
        case .enabled: "Ready to apply"
        case .applying: "Applying changes"
        }
    }

    @BighelpThemeReader private var theme
}

struct BighelpModelPickerSheet: View {
    let title: String
    let scopeLabel: String
    let providers: [BighelpLinkModelProvider]
    let currentProviderID: String?
    let currentModelID: String?
    let currentReasoningValue: String?
    let isLoading: Bool
    let isApplying: Bool
    let errorMessage: String?
    let onClearError: () -> Void
    let onRetry: (() -> Void)?
    let onSelect: (String, String) -> Void
    let isModelPinned: ((String, String) -> Bool)?
    let onToggleModelPin: ((String, String) -> Void)?
    let reasoningOptions: [RuntimeReasoningOption]
    let onApply: ((SessionRuntimeSelectionDraft) -> Void)?
    let statusMessage: String?
    let modelUnavailableReason: String?
    let reasoningUnavailableReason: String?
    let modelConfirmation: SessionRuntimeModelConfirmation?
    let onConfirmModel: ((SessionRuntimeModelConfirmation) -> Void)?
    let onCancelModelConfirmation: ((SessionRuntimeModelConfirmation) -> Void)?
    /// The staged flow's button, e.g. "Apply to current chat" or "Save as profile default".
    let applyTitle: String
    /// Shown when nothing specific is chosen, e.g. an agent that uses the default model.
    let defaultModelTitle: String
    /// Pushed inside another navigation stack (the Mac's Model & reasoning
    /// pop-up) instead of presented as its own sheet.
    let isEmbedded: Bool
    /// Close replaces `dismiss`, which only pops an embedded page.
    let onClose: (() -> Void)?

    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var disclosure: BighelpModelPickerDisclosureState
    @State private var draft: SessionRuntimeSelectionDraft
    @State private var isReasoningPresented = false
    @State private var pinMutationRevision = 0
    #if targetEnvironment(macCatalyst)
    @FocusState private var isSearchFocused: Bool
    #endif
    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(
        title: String,
        scopeLabel: String,
        providers: [BighelpLinkModelProvider],
        currentProviderID: String?,
        currentModelID: String?,
        isLoading: Bool,
        isApplying: Bool,
        errorMessage: String?,
        onClearError: @escaping () -> Void,
        onRetry: (() -> Void)?,
        onSelect: @escaping (String, String) -> Void,
        isModelPinned: ((String, String) -> Bool)? = nil,
        onToggleModelPin: ((String, String) -> Void)? = nil,
        reasoningOptions: [RuntimeReasoningOption] = [],
        currentReasoningValue: String? = nil,
        statusMessage: String? = nil,
        modelUnavailableReason: String? = nil,
        reasoningUnavailableReason: String? = nil,
        modelConfirmation: SessionRuntimeModelConfirmation? = nil,
        onConfirmModel: ((SessionRuntimeModelConfirmation) -> Void)? = nil,
        onCancelModelConfirmation: ((SessionRuntimeModelConfirmation) -> Void)? = nil,
        applyTitle: String = "Apply to current chat",
        defaultModelTitle: String = "Host default",
        isEmbedded: Bool = false,
        onClose: (() -> Void)? = nil,
        onApply: ((SessionRuntimeSelectionDraft) -> Void)? = nil
    ) {
        self.title = title
        self.scopeLabel = scopeLabel
        self.providers = providers
        self.currentProviderID = currentProviderID
        self.currentModelID = currentModelID
        self.currentReasoningValue = currentReasoningValue
        self.isLoading = isLoading
        self.isApplying = isApplying
        self.errorMessage = errorMessage
        self.onClearError = onClearError
        self.onRetry = onRetry
        self.onSelect = onSelect
        self.isModelPinned = isModelPinned
        self.onToggleModelPin = onToggleModelPin
        self.reasoningOptions = reasoningOptions
        self.onApply = onApply
        self.statusMessage = statusMessage
        self.modelUnavailableReason = modelUnavailableReason
        self.reasoningUnavailableReason = reasoningUnavailableReason
        self.modelConfirmation = modelConfirmation
        self.onConfirmModel = onConfirmModel
        self.onCancelModelConfirmation = onCancelModelConfirmation
        self.applyTitle = applyTitle
        self.defaultModelTitle = defaultModelTitle
        self.isEmbedded = isEmbedded
        self.onClose = onClose
        _disclosure = State(initialValue: BighelpModelPickerDisclosureState(
            expandedProviderIDs: Set([currentProviderID].compactMap { $0 })
        ))
        _draft = State(initialValue: SessionRuntimeSelectionDraft(
            providerID: currentProviderID,
            modelID: currentModelID,
            reasoningValue: currentReasoningValue
        ))
    }

    var body: some View {
        BighelpPickerNavigation(isEmbedded: isEmbedded) {
            VStack(spacing: 0) {
                if !uiV3Enabled {
                    ZStack(alignment: .topTrailing) {
                        VStack(alignment: .center, spacing: BighelpTokens.space4) {
                            Text(isChoosingReasoning ? "Reasoning level" : title)
                                .bighelpFont(.screenTitle, weight: .bold)
                                .foregroundStyle(theme.primaryText)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(scopeLabel)
                                .bighelpFont(.metadata, weight: .semibold)
                                .foregroundStyle(theme.secondaryText)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, BighelpTokens.hitTarget)

                        BighelpIconButton(
                            systemImage: isChoosingReasoning ? "chevron.left" : "xmark",
                            accessibilityLabel: isChoosingReasoning
                                ? "Back to model picker"
                                : "Close model picker",
                            style: BighelpPickerSheetLayout.dismissButtonStyle,
                            action: closeOrReturn
                        )
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                        #endif
                        .accessibilityIdentifier("model-picker.dismiss")
                    }
                    .padding(.horizontal, BighelpTokens.space20)
                    .padding(.top, BighelpTokens.space20)
                }

                if showsInlineSearch {
                    searchField
                        .padding(.horizontal, BighelpTokens.space20)
                        .padding(.top, BighelpTokens.space16)
                        .padding(.bottom, BighelpTokens.space12)
                }

            ScrollView {
                LazyVStack(alignment: .center, spacing: BighelpTokens.space16) {
                    if uiV3Enabled {
                        Text(scopeLabel)
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let errorMessage {
                        errorCard(errorMessage)
                    }
                    if let statusMessage {
                        availabilityText(statusMessage, identifier: "model-picker.pending-status")
                    }
                    if let modelUnavailableReason {
                        availabilityText(modelUnavailableReason, identifier: "model-picker.model-unavailable")
                    }

                    if uiV3Enabled, isStagedFlow, searchText.isEmpty {
                        selectionSummary
                    }
                    if isChoosingReasoning {
                        reasoningChoices
                    } else if isLoading && providers.isEmpty {
                        BighelpThinkingOrb(
                            scenario: .searching,
                            visibleLabel: "Loading configured models"
                        )
                            .bighelpFont(.metadata)
                            .frame(maxWidth: .infinity, minHeight: 180)
                            .accessibilityIdentifier("model-picker.loading")
                    } else if filteredProviders.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        ForEach(filteredProviders) { group in
                            providerSection(group)
                        }
                    }
                }
                .padding(.horizontal, BighelpTokens.space20)
                .padding(.bottom, BighelpTokens.space32)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .id(isChoosingReasoning ? "model-picker.reasoning-step" : "model-picker.models-step")
            .scrollIndicators(.visible)

            if isStagedFlow {
                applyBar
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(BighelpPickerSheetBackgroundModifier(
                usesNativePresentation: uiV3Enabled,
                legacyTint: sheetSurfacePresentation.surfaceTint,
                isEmbedded: isEmbedded
            ))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("model-picker.surface")
            .overlay {
                if isApplying {
                    BighelpCard {
                        BighelpThinkingOrb(
                            scenario: .working,
                            scale: .inline,
                            visibleLabel: "Updating…"
                        )
                            .bighelpFont(.label)
                    }
                        .accessibilityIdentifier("model-picker.updating")
                }
            }
            .navigationTitle(uiV3Enabled ? title : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(uiV3Enabled ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                if uiV3Enabled {
                    // Pushed, the leading spot is the back button.
                    ToolbarItem(placement: isEmbedded ? .topBarTrailing : .cancellationAction) {
                        Button("Close", systemImage: "xmark", action: close)
                            .labelStyle(.iconOnly)
                            #if targetEnvironment(macCatalyst)
                            .keyboardShortcut(.cancelAction)
                            #endif
                            .accessibilityIdentifier("model-picker.dismiss")
                    }
                }
            }
            // The Mac's search sits in the page (see `showsInlineSearch`).
            .modifier(BighelpPickerSearchModifier(
                isEnabled: uiV3Enabled && !BighelpPlatform.isMac,
                text: $searchText,
                isPresented: $isSearchPresented,
                prompt: "Search providers and models"
            ))
            #if targetEnvironment(macCatalyst)
            .onAppear {
                // Typing goes straight to search; focus only takes once the field is in its window.
                Task { @MainActor in isSearchFocused = true }
            }
            #endif
        }
        .presentationDragIndicator(.visible)
        .onChange(of: [currentProviderID, currentModelID, currentReasoningValue], initial: true) { _, _ in
            draft.reconcile(providerID: currentProviderID, modelID: currentModelID, reasoningValue: currentReasoningValue)
        }
        .modifier(BighelpModelConfirmationModifier(
            confirmation: modelConfirmation,
            onConfirm: onConfirmModel,
            onCancel: onCancelModelConfirmation
        ))
    }

    private var isStagedFlow: Bool { onApply != nil }

    /// A search field in the page: the original look, and always on the Mac,
    /// where a navigation-bar search is easy to miss and hard to reach by keyboard.
    private var showsInlineSearch: Bool {
        (!uiV3Enabled || BighelpPlatform.isMac) && !isChoosingReasoning
    }

    private var canApply: Bool {
        draft.hasChanges && canApplyDraft && modelConfirmation == nil && statusMessage == nil
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var isChoosingReasoning: Bool {
        isStagedFlow && isReasoningPresented && !uiV3Enabled
    }

    private func closeOrReturn() {
        if isChoosingReasoning {
            isReasoningPresented = false
            draft.showModels()
        } else {
            close()
        }
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Model").bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
                Text(draft.modelID.flatMap { $0.isEmpty ? nil : ModelNameCatalogStore.shared.displayName(for: $0) }
                     ?? defaultModelTitle)
                    .bighelpFont(.sectionTitle)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let providerID = draft.providerID,
                   let provider = providers.first(where: { $0.id == providerID }) {
                    Text(provider.name).bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
                }
            }
            if !reasoningOptions.isEmpty {
                Divider()
                reasoningChoices
            } else if let reasoningUnavailableReason {
                availabilityText(reasoningUnavailableReason, identifier: "model-picker.reasoning-unavailable")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model-picker.selection-summary")
    }

    private var applyBar: some View {
        BighelpModelPickerApplyButton(
            title: applyTitle,
            hasChanges: canApply,
            isApplying: isApplying
        ) {
            onApply?(draft)
        }
        #if targetEnvironment(macCatalyst)
        // Return in the search field is the field's own (`submitSearch`).
        .keyboardShortcut(isSearchFocused ? nil : .defaultAction)
        #endif
        .padding(.horizontal, BighelpTokens.space20)
        .padding(.vertical, BighelpTokens.space12)
        .background(colorScheme == .dark ? theme.canvas : theme.raisedSurface, ignoresSafeAreaEdges: [])
        .accessibilityIdentifier("model-picker.apply")
    }

    private var sheetSurfacePresentation: BighelpPickerSheetSurfacePresentation {
        .resolve(isDarkMode: colorScheme == .dark)
    }

    private var reasoningChoices: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            BighelpReasoningLevelControl(
                choices: reasoningOptions.map {
                    BighelpReasoningChoice(value: $0.value, label: $0.label, detail: $0.detail)
                },
                selectedValue: draft.reasoningValue,
                isEnabled: !isApplying && reasoningUnavailableReason == nil,
                accessibilityIdentifier: "model-picker.reasoning-slider",
                onSelect: chooseReasoning,
                isEmbedded: uiV3Enabled
            )
            if let reasoningUnavailableReason {
                availabilityText(reasoningUnavailableReason, identifier: "model-picker.reasoning-unavailable")
            }
        }
    }

    private var canApplyDraft: Bool {
        let changesModel = draft.providerID != draft.originalProviderID || draft.modelID != draft.originalModelID
        let changesReasoning = draft.reasoningValue != draft.originalReasoningValue
        return (!changesModel || modelUnavailableReason == nil)
            && (!changesReasoning || reasoningUnavailableReason == nil)
    }

    private func availabilityText(_ message: String, identifier: String) -> some View {
        Text(message)
            .bighelpFont(.metadata)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }

    private var searchField: some View {
        #if targetEnvironment(macCatalyst)
        BighelpSearchField(
            text: $searchText,
            prompt: "Search providers and models",
            accessibilityLabel: "Search providers and models",
            accessibilityIdentifier: "model-picker.search",
            onSubmit: submitSearch
        )
        .focused($isSearchFocused)
        #else
        BighelpSearchField(
            text: $searchText,
            prompt: "Search providers and models",
            accessibilityLabel: "Search providers and models",
            accessibilityIdentifier: "model-picker.search"
        )
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// Return picks the first match; with nothing typed it applies the choice.
    private func submitSearch() {
        defer {
            // Return ends editing; stay in the field so a second Return applies.
            Task { @MainActor in isSearchFocused = true }
        }
        guard !isApplying else { return }
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isStagedFlow, canApply { onApply?(draft) }
            return
        }
        guard modelUnavailableReason == nil,
              let group = filteredProviders.first,
              let modelID = group.models.first else { return }
        chooseModel(providerID: group.provider.id, modelID: modelID)
    }
    #endif

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .reflectiveVisionIcon()
                .foregroundStyle(theme.danger)
            Text(message)
                .bighelpFont(.metadata)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: BighelpTokens.space4)
            if let onRetry {
                Button("Retry", action: onRetry)
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.action)
                    .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                    .disabled(isApplying)
                    .accessibilityIdentifier("model-picker.retry")
            }
            Button(action: onClearError) {
                Image(systemName: "xmark")
                    .reflectiveVisionIcon()
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss model picker error")
        }
        .padding(BighelpTokens.space12)
        .background(theme.danger.opacity(0.08), in: .rect(cornerRadius: BighelpTokens.radius12))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
                .stroke(theme.danger.opacity(0.24), lineWidth: BighelpTokens.hairline)
        }
    }

    private func providerSection(_ group: BighelpModelPickerProviderGroup) -> some View {
        let visibleIdentity = AIProviderVisibleIdentity.resolve(
            providerID: group.provider.id,
            providerName: group.provider.name
        )
        return BighelpMenuPanel {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Button {
                    disclosure.toggle(group.provider.id)
                } label: {
                    HStack(alignment: .center, spacing: BighelpTokens.space12) {
                        AIProviderMarkView(
                            providerID: visibleIdentity.rawProviderID,
                            providerName: visibleIdentity.visibleProviderName,
                            context: .modelPickerProviderHeader,
                            size: 36
                        )
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(visibleIdentity.visibleProviderName)
                                .bighelpFont(.label, weight: .semibold)
                                .foregroundStyle(theme.primaryText)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            if group.provider.id == currentProviderID {
                                Text("Current provider")
                                    .bighelpFont(.metadata)
                                    .foregroundStyle(theme.action)
                            } else if group.provider.isCustom {
                                Text("Custom provider")
                                    .bighelpFont(.metadata)
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                        Spacer(minLength: BighelpTokens.space8)
                        Image(systemName: providerIsExpanded(group.provider.id)
                              ? "chevron.down"
                              : "chevron.right")
                            .reflectiveVisionIcon()
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, BighelpTokens.space12)
                    .padding(.vertical, BighelpTokens.space4)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(providerIsExpanded(group.provider.id) ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("model-picker.provider.\(group.provider.id)")

                if providerIsExpanded(group.provider.id) {
                    ForEach(group.models, id: \.self) { modelID in
                        modelRow(provider: group.provider, modelID: modelID)
                    }
                }
            }
        }
    }

    private func modelRow(provider: BighelpLinkModelProvider, modelID: String) -> some View {
        let selected = isCurrent(providerID: provider.id, modelID: modelID)
        let _ = pinMutationRevision
        let pinned = isModelPinned?(provider.id, modelID) ?? false
        let displayName = ModelNameCatalogStore.shared.displayName(for: modelID)
        let providerName = AIProviderVisibleIdentity.resolve(
            providerID: provider.id,
            providerName: provider.name
        ).visibleProviderName
        return HStack(alignment: .center, spacing: 0) {
            BighelpMenuRow(
                isSelected: selected,
                isEnabled: !isApplying && modelUnavailableReason == nil,
                action: { chooseModel(providerID: provider.id, modelID: modelID) }
            ) {
                HStack(alignment: .center, spacing: BighelpTokens.space12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .bighelpFont(.label)
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if displayName != modelID {
                            Text(modelID)
                                .bighelpFont(.metadata)
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1)
                                .multilineTextAlignment(.leading)
                        }
                        Text(providerName)
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: BighelpTokens.space8)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .reflectiveVisionIcon()
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(selected ? theme.action : theme.tertiaryText)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, BighelpTokens.space12)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("\(displayName), \(providerName)")
            .accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityIdentifier("model-picker.\(provider.id).\(modelID)")

            if let onToggleModelPin, isModelPinned != nil {
                Button {
                    onToggleModelPin(provider.id, modelID)
                    pinMutationRevision &+= 1
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .reflectiveVisionIcon()
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(pinned ? theme.action : theme.secondaryText)
                        .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .disabled(isApplying)
                .accessibilityLabel("\(pinned ? "Unpin model" : "Pin model") \(displayName)")
                .accessibilityIdentifier("model-picker.pin.\(provider.id).\(modelID)")
            }
        }
    }

    private var filteredProviders: [BighelpModelPickerProviderGroup] {
        BighelpModelPickerFiltering.groups(
            providers: providers,
            currentProviderID: currentProviderID,
            query: searchText
        )
    }

    private func isCurrent(providerID: String, modelID: String) -> Bool {
        if isStagedFlow {
            return providerID == draft.providerID && modelID == draft.modelID
        }
        return providerID == currentProviderID && modelID == currentModelID
    }

    private func providerIsExpanded(_ providerID: String) -> Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || disclosure.isExpanded(providerID)
    }

    private func chooseModel(providerID: String, modelID: String) {
        if isStagedFlow {
            draft.selectModel(providerID: providerID, modelID: modelID)
            if uiV3Enabled {
                searchText = ""
                isSearchPresented = false
            }
            // Skip the reasoning step when there is nothing to choose there.
            isReasoningPresented = !uiV3Enabled && (!reasoningOptions.isEmpty || reasoningUnavailableReason != nil)
        } else {
            onSelect(providerID, modelID)
        }
    }

    private func chooseReasoning(_ value: String) {
        draft.selectReasoning(value)
    }

    @BighelpThemeReader private var theme
}

enum AIProviderMarkContext: CaseIterable, Equatable, Sendable {
    case agentRuntimeSelection
    case modelPickerProviderHeader
    case chatSessionCompactControl
    case chatQuickChoice
    case chatLegacyModelRow
    case chatLegacyProviderHeader
    case chatActionMenuProviderHeader

    var hasVisibleProviderName: Bool {
        switch self {
        case .modelPickerProviderHeader, .chatQuickChoice,
             .chatLegacyProviderHeader, .chatActionMenuProviderHeader:
            true
        case .agentRuntimeSelection, .chatSessionCompactControl, .chatLegacyModelRow:
            false
        }
    }
}

enum AIProviderMarkLayout {
    static let centersMarksVertically = true

    static func size(
        for context: AIProviderMarkContext,
        isRegularWidth: Bool
    ) -> CGFloat {
        switch (context, isRegularWidth) {
        case (.agentRuntimeSelection, false): 40
        case (.agentRuntimeSelection, true): 48
        case (.modelPickerProviderHeader, false): 44
        case (.modelPickerProviderHeader, true): 52
        case (.chatSessionCompactControl, false): 24
        case (.chatSessionCompactControl, true): 32
        case (.chatQuickChoice, false): 40
        case (.chatQuickChoice, true): 48
        case (.chatLegacyModelRow, false): 40
        case (.chatLegacyModelRow, true): 48
        case (.chatLegacyProviderHeader, false): 32
        case (.chatLegacyProviderHeader, true): 40
        case (.chatActionMenuProviderHeader, false): 36
        case (.chatActionMenuProviderHeader, true): 44
        }
    }
}

struct AIProviderVisibleIdentity: Equatable, Sendable {
    let rawProviderID: String
    let visibleProviderName: String
    let brand: AIProviderBrand

    static func resolve(
        providerID: String,
        providerName: String
    ) -> AIProviderVisibleIdentity {
        let brand = AIProviderBrandRegistry.resolve(id: providerID, name: providerName)
        return AIProviderVisibleIdentity(
            rawProviderID: providerID,
            visibleProviderName: AIProviderBrandRegistry.displayName(
                id: providerID,
                authoritativeName: providerName
            ),
            brand: brand
        )
    }
}

enum AIProviderMarkPresentation: Equatable, Sendable {
    case official(assetName: String)
    case fallback

    static func resolve(
        brand: AIProviderBrand,
        context: AIProviderMarkContext,
        visibleProviderName: String?
    ) -> AIProviderMarkPresentation {
        switch brand.artwork {
        case let .official(assetName):
            return .official(assetName: assetName)
        case .fallback:
            return .fallback
        }
    }
}

struct AIProviderMarkView: View {
    let providerID: String
    let providerName: String
    let context: AIProviderMarkContext
    let size: CGFloat?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.providerLogoStore) private var providerLogoStore

    init(
        providerID: String,
        providerName: String,
        context: AIProviderMarkContext,
        size: CGFloat? = nil
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.context = context
        self.size = size
    }

    private var brand: AIProviderBrand {
        AIProviderBrandRegistry.resolve(id: providerID, name: providerName)
    }

    private var presentation: AIProviderMarkPresentation {
        AIProviderMarkPresentation.resolve(
            brand: brand,
            context: context,
            visibleProviderName: context.hasVisibleProviderName ? providerName : nil
        )
    }

    @ViewBuilder
    var body: some View {
        let resolvedSize = size ?? AIProviderMarkLayout.size(
            for: context,
            isRegularWidth: horizontalSizeClass == .regular
        )
        switch presentation {
        case let .official(assetName):
            officialArtwork(assetName: assetName, resolvedSize: resolvedSize)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(providerName) provider")
        case .fallback:
            ZStack {
                Circle()
                    .fill(Color(uiColor: .secondarySystemBackground))
                Text(brand.monogram)
                    .font(.system(
                        size: max(8, resolvedSize * 0.38),
                        weight: .bold,
                        design: .rounded
                    ))
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.5)
                    .padding(resolvedSize * 0.12)
            }
            .frame(width: resolvedSize, height: resolvedSize, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(providerName) provider")
        }
    }

    @ViewBuilder
    private func officialArtwork(assetName: String, resolvedSize: CGFloat) -> some View {
        let geometry = brand.officialArtworkGeometry
        let image = providerLogoStore?.image(for: assetName, colorScheme: colorScheme)
            .map { Image(uiImage: $0) } ?? Image(decorative: assetName)
        let artwork = image
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .padding(resolvedSize * geometry.insetFraction)
            .frame(width: resolvedSize, height: resolvedSize, alignment: .center)
            .scaleEffect(geometry.opticalScale)
            .frame(width: resolvedSize, height: resolvedSize, alignment: .center)

        if geometry.clipsToFrame {
            artwork.clipped()
        } else {
            artwork
        }
    }
}
