import SwiftUI

/// 11pt bold, letterspaced, uppercase section caption used across the Agent Studio.
struct AgentStudioCaption: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.bighelp(.caption2).weight(.bold))
            .tracking(0.9)
            .textCase(.uppercase)
            .foregroundStyle(theme.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }

    @BighelpThemeReader private var theme
}

/// Where a new agent starts: from scratch, a built-in personality, or one of
/// the person's saved templates. Picking one only fills in the editor; nothing
/// reaches Hermes until Create.
struct AgentStartPicker: View {
    let model: AgentEditorModel
    @Bindable var library: AgentTemplateLibrary
    @State private var renaming: SavedAgentTemplate?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            AgentStudioCaption("Start from")
            Picker("Start from", selection: Binding(get: { model.startChoice },
                                                    set: { model.showStartChoice($0) })) {
                Text("Scratch").tag(AgentEditorModel.StartChoice.scratch)
                Text("Templates").tag(AgentEditorModel.StartChoice.builtIn)
                Text("My templates").tag(AgentEditorModel.StartChoice.saved)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("agent.editor.start")
            switch model.startChoice {
            case .scratch:
                note("Empty details. Write your agent's personality yourself in Instructions.")
            case .builtIn:
                carousel {
                    ForEach(AgentSoulTemplate.all) { template in
                        card(title: template.title, subtitle: template.profile, detail: template.strength,
                             credit: template.isCommunity ? template.credit : nil,
                             systemImage: template.systemImage, selected: "builtin:\(template.id)",
                             identifier: "agent.editor.template.\(template.id)") {
                            model.startFrom(template)
                        }
                        .accessibilityHint("Fills in its role, vibe and personality. Your agent's name goes into it.")
                    }
                }
                note(model.appliedTemplateID?.hasPrefix("builtin:") == true
                     ? "Its personality is in Instructions below, with your agent's name filled in."
                     : "Each is a full personality. Pick one, then give your agent its name.")
                Link(destination: TemplateCatalogPolicy.submitURL) {
                    Label("Share yours", systemImage: "square.and.arrow.up")
                        .font(.bighelp(.footnote).weight(.semibold))
                }
                .accessibilityIdentifier("agent.editor.templates.share")
            case .saved:
                if library.templates.isEmpty {
                    note("No saved templates yet. Save one from an agent's Edit screen or by holding it in Agents.")
                        .accessibilityIdentifier("agent.editor.saved-templates.empty")
                } else {
                    carousel {
                        ForEach(library.templates) { template in
                            card(title: template.title,
                                 subtitle: template.role.isEmpty ? "From \(template.sourceAgentName)" : template.role,
                                 detail: template.summary, systemImage: "person.crop.square",
                                 selected: "saved:\(template.id.uuidString)",
                                 identifier: "agent.editor.saved-template.\(template.id.uuidString)") {
                                model.startFrom(template)
                            }
                            .accessibilityHint("Fills in everything from this template. Hold to rename or delete.")
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") {
                                    renameText = template.title
                                    renaming = template
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    library.delete(template.id)
                                }
                            }
                        }
                    }
                    note("Saved on this device. Hold one to rename or delete it.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Rename template", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let template = renaming { library.rename(template.id, to: renameText) }
                renaming = nil
            }
        }
    }

    private func carousel<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        BighelpCardRail(content: content)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.bighelp(.footnote))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func card(title: String, subtitle: String, detail: String, credit: String? = nil,
                      systemImage: String, selected: String,
                      identifier: String, action: @escaping () -> Void) -> some View {
        let isSelected = model.appliedTemplateID == selected
        return Button(action: action) {
            BighelpRailCard(isSelected: isSelected, width: 196, height: 176) { ink, secondary in
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : systemImage)
                        .font(.bighelp(.title3))
                        .foregroundStyle(isSelected ? theme.actionForeground : theme.action)
                        .frame(height: 28)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.bighelp(.headline))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.bighelp(.subheadline).weight(.medium))
                        .foregroundStyle(secondary)
                        .lineLimit(2)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.bighelp(.caption))
                            .foregroundStyle(secondary)
                            .lineLimit(credit == nil ? 3 : 2)
                    }
                    if let credit {
                        Text(verbatim: "by @\(credit)")
                            .font(.bighelp(.caption2))
                            .foregroundStyle(secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    @BighelpThemeReader private var theme
}
