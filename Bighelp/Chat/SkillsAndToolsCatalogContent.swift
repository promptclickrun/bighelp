import SwiftUI

@MainActor
struct SkillsAndToolsCatalogContent: View {
    let store: SkillsAndToolsStore
    let onRetry: (() -> Void)?
    let onSkillSelected: ((String) -> Void)?
    let onCapabilitySelected: ((HermesCapabilityKind, String, String) -> Void)?
    @State private var selectedKind: HermesCapabilityKind?
    @State private var query = ""
    @Environment(\.bighelpUIV2Enabled) private var uiV2Enabled

    init(
        store: SkillsAndToolsStore,
        onRetry: (() -> Void)? = nil,
        onSkillSelected: ((String) -> Void)? = nil,
        onCapabilitySelected: ((HermesCapabilityKind, String, String) -> Void)? = nil
    ) {
        self.store = store
        self.onRetry = onRetry
        self.onSkillSelected = onSkillSelected
        self.onCapabilitySelected = onCapabilitySelected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space20) {
            if let message = store.compatibilityMessage {
                Label(message, systemImage: "info.circle")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("skills-tools.compatibility")
            }
            if let message = store.errorMessage, store.catalog != nil {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = store.statusMessage {
                Label(message, systemImage: "checkmark.circle")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
            }
            if store.isLoading, store.catalog != nil {
                ProgressView("Loading from Hermes…").tint(theme.action)
            }
            if store.isSaving {
                ProgressView("Saving skill on Hermes…").tint(theme.action)
            }
            if store.isLoading, store.catalog == nil {
                BighelpThinkingOrb(
                    scenario: .searching,
                    visibleLabel: "Loading Hermes capabilities"
                )
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else if let catalog = store.catalog {
                if uiV2Enabled { v2CatalogContent(catalog) } else { catalogContent(catalog) }
            } else {
                ContentUnavailableView(
                    "Capabilities unavailable",
                    systemImage: "shippingbox",
                    description: Text(store.errorMessage ?? "Connect to the selected Hermes host and try again.")
                )
            }

            if store.errorMessage != nil, let onRetry {
                Button(action: onRetry) {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.controlHeight)
                }
                .bighelpActionStyle()
                .tint(theme.action)
                .accessibilityIdentifier("skills-tools.retry")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills-tools.content")
    }

    private struct TypedCapabilityRow: Identifiable {
        let kind: HermesCapabilityKind
        let sourceID: String
        let title: String
        let detail: String
        let metadata: String
        let enabled: Bool
        var id: String { "\(kind.rawValue):\(sourceID)" }
        var symbol: String {
            switch kind {
            case .skill: "sparkles"
            case .plugin: "puzzlepiece.extension"
            case .mcpServer: "server.rack"
            case .toolset: "wrench.and.screwdriver"
            }
        }
    }

    private func typedRows(_ catalog: HermesSkillsAndToolsCatalog) -> [TypedCapabilityRow] {
        let skills = catalog.skills.map {
            TypedCapabilityRow(kind: .skill, sourceID: $0.id, title: $0.name, detail: $0.description,
                               metadata: $0.category, enabled: $0.isEnabled)
        }
        let plugins = catalog.plugins.map {
            TypedCapabilityRow(kind: .plugin, sourceID: $0.id, title: $0.name, detail: $0.description,
                               metadata: $0.kind, enabled: $0.isEnabled)
        }
        let servers = catalog.mcpServers.map {
            TypedCapabilityRow(kind: .mcpServer, sourceID: $0.id, title: $0.name, detail: "MCP server configuration",
                               metadata: $0.transport, enabled: $0.isEnabled)
        }
        let tools = catalog.tools.map {
            TypedCapabilityRow(kind: .toolset, sourceID: $0.id, title: $0.name, detail: $0.description,
                               metadata: "\($0.platform) · \($0.toolCount) tools", enabled: $0.isEnabled)
        }
        return skills + plugins + servers + tools
    }

    private func v2CatalogContent(_ catalog: HermesSkillsAndToolsCatalog) -> some View {
        let rows = typedRows(catalog).filter { row in
            (selectedKind == nil || selectedKind == row.kind) && (
                query.isEmpty || [row.title, row.sourceID, row.detail, row.metadata].contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
            )
        }
        return VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            BighelpSearchField(text: $query, prompt: "Search capabilities", accessibilityLabel: "Search capabilities")
            ScrollView(.horizontal) {
                HStack(spacing: BighelpTokens.space8) {
                    typeFilter(nil, title: "All")
                    ForEach(HermesCapabilityKind.allCases, id: \.self) { kind in
                        typeFilter(kind, title: kind.title)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("skills-tools.type-filter")
            Text("\(rows.count) capabilities · \(catalog.agentID)")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
            if selectedKind == .toolset {
                Text("Tools are configured through Hermes toolsets. This does not edit executable tool code or change the current chat’s tools.")
                    .bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
                if !catalog.toolsNotice.isEmpty {
                    Text(catalog.toolsNotice).bighelpFont(.metadata).foregroundStyle(theme.warning)
                }
            }
            if selectedKind == .plugin {
                Text("Plugins discovered by this profile’s Hermes runtime. Provider and control-channel plugins may be locked.")
                    .bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
            }
            if rows.isEmpty {
                ContentUnavailableView("No matching capabilities", systemImage: "line.3.horizontal.decrease",
                                       description: Text("Choose another type or clear the search."))
                Button("Show all capabilities") { query = ""; selectedKind = nil }
                    .bighelpActionStyle().tint(theme.action)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        Button {
                            if let onCapabilitySelected {
                                onCapabilitySelected(row.kind, row.sourceID, row.title)
                            } else if row.kind == .skill, let onSkillSelected {
                                onSkillSelected(row.sourceID)
                            } else {
                                store.reportError("Open Skills & Tools from the workspace menu to manage this capability.")
                            }
                        } label: {
                            HStack(alignment: .top, spacing: BighelpTokens.space12) {
                                Image(systemName: row.symbol).font(.bighelp(.title3))
                                    .foregroundStyle(theme.action).frame(width: 28)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.title).bighelpFont(.label, weight: .semibold).foregroundStyle(theme.primaryText)
                                    Text(row.detail).bighelpFont(.body).foregroundStyle(theme.secondaryText).lineLimit(3)
                                    Text("\(row.kind.title) · \(row.metadata)")
                                        .bighelpFont(.metadata).foregroundStyle(theme.tertiaryText)
                                }
                                Spacer(minLength: 4)
                                VStack(spacing: 6) {
                                    Text(row.enabled ? "On" : "Off")
                                        .bighelpFont(.metadata, weight: .semibold)
                                    Image(systemName: "chevron.right").font(.bighelp(.caption).weight(.semibold))
                                }
                                .foregroundStyle(theme.secondaryText)
                            }
                            .padding(.vertical, BighelpTokens.space12)
                            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(row.title), \(row.kind.title), configured \(row.enabled ? "on" : "off")")
                        .accessibilityHint("View settings and supported enable or disable controls")
                        .accessibilityIdentifier("skills-tools.v2.\(row.id)")
                        Rectangle().fill(theme.border).frame(height: BighelpTokens.hairline)
                    }
                }
            }
        }
        .accessibilityIdentifier("skills-tools.v2")
    }

    private func typeFilter(_ kind: HermesCapabilityKind?, title: String) -> some View {
        BighelpPillControl(isSelected: selectedKind == kind) {
            selectedKind = kind
        } label: {
            Text(title).bighelpFont(.metadata, weight: .semibold)
                .foregroundStyle(selectedKind == kind ? theme.action : theme.secondaryText)
        }
        .accessibilityIdentifier("skills-tools.filter.\(kind?.rawValue ?? "all")")
    }

    private func catalogContent(_ catalog: HermesSkillsAndToolsCatalog) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space20) {
            capabilitySection(
                title: "Skills",
                emptyMessage: "No skills are enabled for this agent.",
                rows: catalog.skills.map { skill in
                    CapabilityRow(
                        id: skill.id,
                        title: skill.name,
                        detail: skill.description,
                        metadata: skill.category,
                        symbol: "sparkles",
                        isEnabled: skill.isEnabled
                    )
                },
                onSelect: onSkillSelected
            )
            capabilitySection(
                title: "Plugins",
                emptyMessage: "No Hermes plugins are installed.",
                rows: catalog.plugins.map { plugin in
                    let version = plugin.version.isEmpty
                        ? plugin.kind
                        : "\(plugin.kind) · \(plugin.version)"
                    return CapabilityRow(
                        id: plugin.id,
                        title: plugin.name,
                        detail: plugin.description,
                        metadata: "\(version) · \(plugin.capabilityCount) capabilities",
                        symbol: "puzzlepiece.extension",
                        isEnabled: plugin.isEnabled
                    )
                },
                onSelect: selectionHandler(kind: .plugin)
            )
            capabilitySection(
                title: "MCP servers",
                emptyMessage: "No MCP servers are configured.",
                rows: catalog.mcpServers.map { server in
                    let tools = server.toolCount.map { " · \($0) tools" } ?? ""
                    return CapabilityRow(
                        id: server.id,
                        title: server.name,
                        detail: "",
                        metadata: "\(server.transport.uppercased())\(tools)",
                        symbol: "server.rack",
                        isEnabled: server.isEnabled
                    )
                },
                onSelect: selectionHandler(kind: .mcpServer)
            )
        }
    }

    private func selectionHandler(kind: HermesCapabilityKind) -> ((String) -> Void)? {
        guard let onCapabilitySelected else { return nil }
        return { id in onCapabilitySelected(kind, id, id) }
    }

    @ViewBuilder
    private func capabilitySection(
        title: String,
        emptyMessage: String,
        rows: [CapabilityRow],
        onSelect: ((String) -> Void)? = nil
    ) -> some View {
        LazyVStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text(title.uppercased())
                .bighelpFont(.metadata, weight: .semibold)
                .foregroundStyle(theme.secondaryText)
            if rows.isEmpty {
                Text(emptyMessage)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.vertical, BighelpTokens.space8)
            } else {
                ForEach(rows) { row in
                    if let onSelect {
                        Button { onSelect(row.id) } label: {
                            capabilityRow(row, showsDisclosure: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        capabilityRow(row)
                    }
                }
            }
        }
    }

    private func capabilityRow(
        _ row: CapabilityRow,
        showsDisclosure: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: row.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(row.isEnabled ? theme.action : theme.tertiaryText)
                .frame(width: 34, height: 34)
                .background(theme.raisedSurface, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: BighelpTokens.space8) {
                    Text(row.title)
                        .bighelpFont(.label, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                    if !row.isEnabled {
                        Text("OFF")
                            .bighelpFont(.metadata, weight: .bold)
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .bighelpFont(.body)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !row.metadata.isEmpty {
                    Text(row.metadata)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.tertiaryText)
                }
            }
            Spacer(minLength: BighelpTokens.space8)
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .padding(.top, BighelpTokens.space8)
            }
        }
        .padding(BighelpTokens.space12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)
                .stroke(theme.border, lineWidth: BighelpTokens.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("skills-tools.item.\(row.id)")
    }

    private struct CapabilityRow: Identifiable {
        let id: String
        let title: String
        let detail: String
        let metadata: String
        let symbol: String
        let isEnabled: Bool
    }

    @BighelpThemeReader private var theme: BighelpTheme

}
