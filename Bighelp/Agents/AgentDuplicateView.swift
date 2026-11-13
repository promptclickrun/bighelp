import SwiftUI

struct AgentDuplicateView: View {
    @Bindable var model: AgentDuplicateModel
    let onDone: () -> Void


    var body: some View {
        NavigationStack {
            Form {
                if let result = model.result {
                    resultSection(result)
                } else if let plan = model.plan {
                    Section {
                        LabeledContent("Source", value: model.source.name)
                        LabeledContent("New profile", value: plan.destinationProfileID)
                        copyScope("Credentials", included: plan.includesCredentials)
                        copyScope("Memory", included: plan.includesMemory)
                        copyScope("Installed skills", included: plan.includesSkills)
                        copyScope("Avatar", included: plan.includesAvatar)
                        copyScope("Chat history", included: plan.includesHistory)
                        Text("Creates a separate profile with the source configuration and instructions. Scheduled tasks and local pins stay behind.")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                    } header: {
                        AgentStudioCaption("What gets copied")
                    }
                    .listRowBackground(theme.surface)
                    if model.requiresSensitiveConsent {
                        Section {
                            Toggle("I understand sensitive settings or memory may be copied.", isOn: $model.acknowledgesSensitiveCopy)
                                .accessibilityIdentifier("agent.duplicate.consent")
                        } footer: {
                            Text("Configuration may include provider credentials. The contents are never displayed here.")
                        }
                        .listRowBackground(theme.surface)
                    }
                    Section {
                        Button { Task { await model.confirm() } } label: {
                            Text("Duplicate bot")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                        }
                        .bighelpProminentButtonStyle()
                        .buttonBorderShape(.capsule)
                        .tint(theme.action)
                        .foregroundStyle(theme.actionForeground)
                        .disabled(!model.canConfirm)
                        .accessibilityIdentifier("agent.duplicate.confirm")
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        Button("Change profile identifier") { model.revise() }
                            .foregroundStyle(theme.action)
                            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                            .disabled(model.isSubmitting)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        TextField("New profile identifier", text: $model.destinationProfileID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .frame(minHeight: BighelpTokens.hitTarget)
                            .accessibilityIdentifier("agent.duplicate.identifier")
                        Button("Review duplication") { Task { await model.prepare() } }
                            .fontWeight(.semibold)
                            .foregroundStyle(theme.action)
                            .frame(minHeight: BighelpTokens.hitTarget)
                            .disabled(model.isPreparing || model.destinationProfileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("agent.duplicate.review")
                    } header: {
                        AgentStudioCaption("New profile")
                    } footer: {
                        Text("The identifier is verified before you review what will be copied.")
                    }
                    .listRowBackground(theme.surface)
                }
                if model.isPreparing || model.isSubmitting {
                    ProgressView(model.isSubmitting ? "Duplicating bot" : "Preparing review")
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(theme.danger)
                        .accessibilityIdentifier("agent.duplicate.error")
                        .listRowBackground(theme.surface)
                }
            }
            .disabled(model.isSubmitting)
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Duplicate bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.result == nil ? "Cancel" : "Done", action: onDone)
                        .foregroundStyle(theme.action)
                        .disabled(model.isSubmitting)
                        .frame(minHeight: BighelpTokens.toolbarHitTarget)
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                        #endif
                        .bighelpToolbarText()
                }
            }
        }
        .interactiveDismissDisabled(model.isSubmitting)
        .onDisappear { model.cancel() }
        .accessibilityIdentifier("agent.duplicate.screen")
    }

    private func copyScope(_ title: String, included: Bool) -> some View {
        LabeledContent(title, value: included ? "Copied" : "Not copied")
    }

    private func resultSection(_ result: AgentDuplicateModel.Result) -> some View {
        Section {
            switch result {
            case .committed:
                Label("Bot duplicated", systemImage: "checkmark.circle")
                Text("Hermes confirmed the new profile. Return to Bots to view it.")
                    .foregroundStyle(theme.secondaryText)
            case .partial:
                Label("Bot created with incomplete settings", systemImage: "exclamationmark.triangle")
                Text("Some requested settings were not copied. Review the new bot before using it. Do not submit another duplicate to finish these changes.")
                    .foregroundStyle(theme.secondaryText)
            case .unconfirmed:
                Label("Duplication not confirmed", systemImage: "questionmark.circle")
                Text("Hermes may have created the new profile. Return to Bots and refresh before trying again; another submission could create unwanted work.")
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .listRowBackground(theme.surface)
        .accessibilityIdentifier("agent.duplicate.result")
    }

    @BighelpThemeReader private var theme
}
