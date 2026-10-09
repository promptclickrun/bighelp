import SwiftUI

enum ChatSessionControlChoiceAlignment: Equatable, Sendable {
    case center

    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .center:
            .center
        }
    }
}

enum ChatSessionControlsPresentation {
    static let choiceAlignment: ChatSessionControlChoiceAlignment = .center
    static let choicesFillAvailableWidth = true
    static let quickChoiceCentersTextIndependentlyOfAccessories = true
    static let quickChoiceAccessoryWidth: CGFloat = 40
    static let compactChipCentersModelIndependentlyOfProviderMark = true
    static let compactChipAccessoryWidth: CGFloat = 24
    static let showsCompactChipDisclosureIndicator = false

    static func preferredHeight(isVerticallyCompact: Bool) -> CGFloat {
        isVerticallyCompact ? 320 : 560
    }

    static func surfacePresentation(
        isDarkMode: Bool
    ) -> BighelpPickerSheetSurfacePresentation {
        .resolve(isDarkMode: isDarkMode)
    }
}

struct ChatSessionControlsPopover: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @Bindable var controls: SessionRuntimeControlModel
    let usesWideLayout: Bool
    let onSeeAllModels: () -> Void
    let onApplied: () -> Void
    /// The Mac pop-up fits this page's content: its height, with the buttons.
    var onContentHeight: ((CGFloat) -> Void)? = nil

    @State private var draft: SessionRuntimeSelectionDraft
    @State private var confirmationToSubmit: SessionRuntimeModelConfirmation?
    #if targetEnvironment(macCatalyst)
    /// Off while All models covers this page, so Return and Esc reach that page's buttons.
    @State private var isFrontmost = true
    @State private var buttonsHeight: CGFloat = 0
    #endif
    @State private var contentHeight: CGFloat = 0

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(
        controls: SessionRuntimeControlModel,
        usesWideLayout: Bool,
        onSeeAllModels: @escaping () -> Void,
        onApplied: @escaping () -> Void,
        onContentHeight: ((CGFloat) -> Void)? = nil
    ) {
        self.controls = controls
        self.usesWideLayout = usesWideLayout
        self.onSeeAllModels = onSeeAllModels
        self.onApplied = onApplied
        self.onContentHeight = onContentHeight
        _draft = State(initialValue: SessionRuntimeSelectionDraft(
            providerID: controls.currentProvider,
            modelID: controls.currentModel,
            reasoningValue: controls.currentReasoningValue
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: BighelpTokens.space16) {
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
                pickerContent
            }
            .padding(BighelpTokens.space16)
            .frame(maxWidth: .infinity, alignment: .center)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        #if targetEnvironment(macCatalyst)
        // Cancel and Apply stay along the bottom of the Mac pop-up, like a dialog's buttons.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: BighelpTokens.space8) { cancelButton; applyButton }
                .padding(.horizontal, BighelpTokens.space16)
                .padding(.vertical, BighelpTokens.space12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { buttonsHeight = $0 }
        }
        .onChange(of: contentHeight + buttonsHeight, initial: true) { _, height in onContentHeight?(height) }
        #endif
        .accessibilityIdentifier("chat.session-controls.popover")
        #if targetEnvironment(macCatalyst)
        // The Mac pop-up sizes itself to the window (ChatSessionControlsMacPopover).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        .frame(minWidth: 280, idealWidth: usesWideLayout ? 600 : 338,
               maxWidth: usesWideLayout ? 600 : 338)
        .frame(
            height: ChatSessionControlsPresentation.preferredHeight(
                isVerticallyCompact: verticalSizeClass == .compact
            )
        )
        #endif
        .bighelpSurface(
            BighelpPickerSheetLayout.rootSurfaceRole,
            tint: .none
        )
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
        #if targetEnvironment(macCatalyst)
        .onAppear { isFrontmost = true }
        .onDisappear { isFrontmost = false }
        #endif
    }

    private var pickerContent: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            HStack(spacing: BighelpTokens.space12) {
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text(controls.hasPinnedModels ? "Pinned models" : "Model & reasoning").bighelpFont(.sectionTitle)
                    Text("This chat only").bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
                Button(action: onSeeAllModels) {
                    #if targetEnvironment(macCatalyst)
                    // A bare chevron reads as decoration with a mouse; name where it goes.
                    HStack(spacing: BighelpTokens.space4) {
                        Text("All models").bighelpFont(.label, weight: .semibold)
                        Image(systemName: "chevron.right")
                    }
                    .foregroundStyle(theme.action)
                    .padding(.horizontal, BighelpTokens.space8)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .contentShape(.rect)
                    #else
                    Image(systemName: "chevron.right")
                        .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        .contentShape(.circle)
                    #endif
                }
                .buttonStyle(.plain)
                .accessibilityLabel("See all models")
                .accessibilityIdentifier("chat.models.see-all")
            }
            if (controls.isLoadingModel || (controls.modelPicker == nil && controls.modelProviders.isEmpty))
                && controls.errorMessage == nil {
                BighelpThinkingOrb(scenario: .searching, scale: .inline, visibleLabel: "Loading models")
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BighelpTokens.space8),
                                         count: dynamicTypeSize.isAccessibilitySize ? 1 : (usesWideLayout ? 3 : 2)), spacing: BighelpTokens.space8) {
                    ForEach(controls.quickModelChoices) { choice in
                        let selected = draft.providerID == choice.providerID && draft.modelID == choice.modelID
                        Button {
                            draft.selectModel(providerID: choice.providerID, modelID: choice.modelID)
                        } label: {
                            VStack(spacing: BighelpTokens.space8) {
                                AIProviderMarkView(providerID: choice.providerID, providerName: choice.providerName, context: .chatQuickChoice)
                                    .accessibilityHidden(true)
                                Text(ModelNameCatalogStore.shared.displayName(for: choice.modelID))
                                    .bighelpFont(.metadata, weight: .semibold)
                                Text(choice.providerName).bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
                                Image(systemName: "checkmark.circle.fill")
                                    .opacity(selected ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                            .multilineTextAlignment(.center)
                            .foregroundStyle(selected ? theme.action : theme.primaryText)
                            .padding(BighelpTokens.space12)
                            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                            .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16))
                            .overlay {
                                RoundedRectangle(cornerRadius: BighelpTokens.radius16)
                                    .stroke(selected ? theme.action : theme.border, lineWidth: BighelpTokens.hairline)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(controls.isApplyingSelection)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("chat.quick-model.\(choice.id)")
                    }
                }
            }
            Divider()
            Text("Reasoning depth").bighelpFont(.label, weight: .semibold)
            if (controls.isLoadingReasoning || controls.reasoningPicker == nil) && controls.errorMessage == nil {
                BighelpThinkingOrb(scenario: .searching, scale: .inline, visibleLabel: "Loading reasoning choices")
            } else {
                BighelpReasoningLevelControl(
                    choices: controls.reasoningOptions.map {
                        BighelpReasoningChoice(value: $0.value, label: $0.label, detail: $0.detail)
                    },
                    selectedValue: draft.reasoningValue,
                    isEnabled: !controls.isApplyingSelection,
                    accessibilityIdentifier: "chat.reasoning-slider",
                    onSelect: { draft.selectReasoning($0) },
                    takesKeyboardFocus: true
                )
            }
            #if !targetEnvironment(macCatalyst)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: BighelpTokens.space8) { cancelButton; applyButton }
                VStack(spacing: BighelpTokens.space8) { cancelButton; applyButton }
            }
            #endif
        }
        .foregroundStyle(theme.primaryText)
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
        .keyboardShortcut(isFrontmost ? .cancelAction : nil)
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
        .keyboardShortcut(isFrontmost ? .defaultAction : nil)
        #endif
        .disabled(controls.pendingModelConfirmation != nil)
        .accessibilityIdentifier("chat.session-controls.apply")
    }

    @BighelpThemeReader private var theme: BighelpTheme
}

#if targetEnvironment(macCatalyst)
/// The pages inside the Mac's Model & reasoning pop-up.
enum ChatSessionControlsPage: Hashable {
    case allModels
}

/// The Mac's one surface for Model & reasoning: pinned and recent models with
/// the reasoning level, and every model pushed inside the same pop-up. iPhone
/// and iPad close the pop-up and open a sheet for every model instead.
struct ChatSessionControlsMacPopover<AllModels: View>: View {
    let controls: SessionRuntimeControlModel
    @Binding var path: [ChatSessionControlsPage]
    /// Fits the window; the caller measures the room beside the button.
    let size: CGSize
    let onApplied: () -> Void
    @ViewBuilder let allModels: () -> AllModels

    /// The quick choices' own height; All models takes all the room there is.
    @State private var firstPageHeight: CGFloat = 0

    var body: some View {
        NavigationStack(path: $path) {
            ChatSessionControlsPopover(
                controls: controls,
                usesWideLayout: true,
                onSeeAllModels: { path = [.allModels] },
                onApplied: onApplied,
                onContentHeight: { firstPageHeight = $0 }
            )
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ChatSessionControlsPage.self) { _ in allModels() }
        }
        .frame(width: size.width,
               height: path.isEmpty && firstPageHeight > 0 ? min(size.height, firstPageHeight) : size.height)
        .animation(.snappy, value: path.isEmpty)
    }
}
#endif
