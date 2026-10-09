import SwiftUI

@MainActor
struct AgentRuntimeDefaultsSection: View {
    @Bindable var model: AgentRuntimeDefaultsEditorModel
    var allowsEdits = true
    var scopes: [AgentRuntimeScope] = AgentRuntimeScope.allCases

    @Binding var modelPickerScope: AgentRuntimeScope?

    var body: some View {
        Group {
            if model.isLoading {
                Section {
                    ProgressView("Loading model settings…")
                } header: {
                    AgentStudioCaption(statusCaption)
                }
                .listRowBackground(theme.surface)
                .accessibilityIdentifier("agent.runtime.loading")
            } else if !model.hasLoaded {
                Section {
                    recoveryMessage(
                        model.errorMessage
                            ?? "We couldn’t load this agent’s model defaults. Try again."
                    )
                    Button("Try again") {
                        Task { await model.load() }
                    }
                    .foregroundStyle(theme.action)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityIdentifier("agent.runtime.retry")
                } header: {
                    AgentStudioCaption(statusCaption)
                }
                .listRowBackground(theme.surface)
            } else {
                if let errorMessage = model.errorMessage {
                    Section {
                        recoveryMessage(errorMessage)
                    }
                    .listRowBackground(theme.surface)
                }
                ForEach(scopes) { scope in
                    scopeSection(scope)
                }
            }
        }
        // Loading starts from the editor (AgentEditorView): a `.task` here would be
        // attached to each section, restarting as they swap and flooding the host.
        .onChange(of: allowsEdits) { _, canEdit in
            if !canEdit {
                modelPickerScope = nil
            }
        }
    }

    private func scopeSection(_ scope: AgentRuntimeScope) -> some View {
        let selection = model.draft[scope]
        let canChangeModel = !model.providers.isEmpty && model.support.modelUnavailableReasons[scope] == nil
        let canChangeReasoning = model.support.reasoningUnavailableReasons[scope] == nil
        let isEditable = allowsEdits && (canChangeModel || canChangeReasoning)
        return Section {
            // The same picker as the chat's model control: model, reasoning, then apply.
            BighelpModelChoiceRow(
                providerID: selection.providerID,
                providerName: providerName(for: selection.providerID),
                modelID: selection.modelID,
                detail: "Reasoning: \(reasoningTitle(for: scope))",
                showsDefaultBadge: true,
                isEnabled: isEditable
            ) {
                modelPickerScope = scope
            }
            .accessibilityLabel("Choose model and reasoning for \(scope.title)")
            .accessibilityValue("\(modelLabel(for: selection)), reasoning \(reasoningTitle(for: scope))")
            .accessibilityIdentifier("agent.runtime.\(scope.rawValue).model")
            if scope == .mainChats {
                AgentFastModeRow(model: model, allowsEdits: allowsEdits)
            }
            if let reason = model.support.modelUnavailableReasons[scope] {
                Text(reason)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reason = model.support.reasoningUnavailableReasons[scope] ?? model.support.reasoningNotes[scope] {
                Text(reason)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("agent.runtime.\(scope.rawValue).reasoning-note")
            }
        } header: {
            AgentStudioCaption(scope == .mainChats ? "Model" : scope.title)
        } footer: {
            Text(scope.detail)
        }
        .listRowBackground(theme.surface)
    }

    private func reasoningTitle(for scope: AgentRuntimeScope) -> String {
        guard model.support.reasoningUnavailableReasons[scope] == nil else { return "Inherited" }
        let value = model.draft[scope].reasoningEffort
        return AgentReasoningOption.all.first(where: { $0.value == value })?.title ?? value
    }

    private var statusCaption: String {
        scopes.contains(.mainChats) ? "Model" : "Subagent and task models"
    }

    private func providerName(for providerID: String) -> String {
        model.providers.first(where: { $0.id == providerID })?.name
            ?? (providerID.isEmpty ? "Hermes" : providerID)
    }

    private func modelName(for selection: AgentRuntimeSelection) -> String {
        ModelNameCatalogStore.shared.displayName(for: selection.modelID)
    }

    private func modelLabel(for selection: AgentRuntimeSelection) -> String {
        guard !selection.modelID.isEmpty else { return "Default model" }
        return "\(modelName(for: selection)) · \(providerName(for: selection.providerID))"
    }

    private func recoveryMessage(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .bighelpFont(.metadata)
            .foregroundStyle(theme.danger)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }

    @BighelpThemeReader private var theme
}
