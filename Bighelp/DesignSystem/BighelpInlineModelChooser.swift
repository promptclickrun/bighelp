import SwiftUI

/// The model list inside a page, opened right under the row it changes, never a sheet over the
/// page. "Same as chat" comes first where the setting has one, a search field once there are many
/// models, then each provider with its logo (the current one open) and its models. A pick calls
/// back at once; the page saves it. Lives in a `List` or `Form` section, one row per item.
struct BighelpInlineModelChooser: View {
    let providers: [BighelpLinkModelProvider]
    let currentProviderID: String?
    let currentModelID: String?
    /// Set where the setting can follow the chat model.
    var onSameAsChat: (() -> Void)? = nil
    var isEnabled = true
    /// Identifies the chooser's rows for tests and drives.
    var identifier = "inline-model"
    let onPick: (_ providerID: String, _ modelID: String) -> Void

    @State private var search = ""
    @State private var expanded: Set<String> = []
    @State private var hasOpened = false

    /// Past this many models, the list gets a search field.
    static let searchThreshold = 12

    var body: some View {
        if providers.reduce(0, { $0 + $1.models.count }) > Self.searchThreshold {
            BighelpSearchField(text: $search, prompt: String(localized: "Search models"),
                               accessibilityLabel: String(localized: "Search models"),
                               accessibilityIdentifier: "\(identifier).search")
        }
        if let onSameAsChat, !isSearching {
            choiceRow(title: String(localized: "Same as chat"), detail: nil,
                      isSelected: (currentModelID ?? "").isEmpty, id: "\(identifier).same-as-chat",
                      action: onSameAsChat)
        }
        let groups = BighelpModelPickerFiltering.groups(providers: providers, currentProviderID: currentProviderID,
                                                        query: search)
        if groups.isEmpty {
            Text(isSearching ? "No models match." : "No models are set up on this computer.")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
        }
        ForEach(groups) { group in
            providerRow(group)
            if isSearching || expanded.contains(group.provider.id) {
                ForEach(group.models, id: \.self) { modelID in modelRow(group.provider, modelID) }
            }
        }
        .onAppear(perform: openCurrentProvider)
    }

    private var isSearching: Bool { ManagementSearch.isActive(search) }

    private func openCurrentProvider() {
        guard !hasOpened else { return }
        hasOpened = true
        if let currentProviderID, providers.contains(where: { $0.id == currentProviderID }) {
            expanded = [currentProviderID]
        } else if providers.count == 1, let only = providers.first {
            expanded = [only.id]
        }
    }

    private func providerRow(_ group: BighelpModelPickerProviderGroup) -> some View {
        let identity = AIProviderVisibleIdentity.resolve(providerID: group.provider.id,
                                                         providerName: group.provider.name)
        let isOpen = isSearching || expanded.contains(group.provider.id)
        return Button {
            guard !isSearching else { return }
            withAnimation(reduceMotion ? nil : .snappy) {
                if expanded.remove(group.provider.id) == nil { expanded.insert(group.provider.id) }
            }
        } label: {
            HStack(spacing: BighelpTokens.space12) {
                AIProviderMarkView(providerID: identity.rawProviderID, providerName: identity.visibleProviderName,
                                   context: .chatQuickChoice, size: 28)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(identity.visibleProviderName)
                        .font(.bighelp(.body, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let plan = group.provider.plan?.summary(now: Date()) {
                        Text(plan.text)
                            .font(.bighelp(.footnote))
                            .foregroundStyle(plan.isLow ? theme.danger : theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(group.models.count == 1 ? "1 model" : "\(group.models.count.formatted()) models")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                Spacer(minLength: BighelpTokens.space8)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.bighelp(.footnote, weight: .bold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOpen ? Text("Open") : Text("Closed"))
        .accessibilityIdentifier("\(identifier).provider.\(group.provider.id)")
    }

    private func modelRow(_ provider: BighelpLinkModelProvider, _ modelID: String) -> some View {
        let name = ModelNameCatalogStore.shared.displayName(for: modelID)
        var details: [String] = []
        if name != modelID { details.append(modelID) }
        if let limit = provider.plan?.modelLimit(modelID, now: Date()) { details.append(limit) }
        return choiceRow(title: name, detail: details.isEmpty ? nil : details.joined(separator: " · "),
                         isSelected: provider.id == currentProviderID && modelID == currentModelID,
                         id: "\(identifier).\(provider.id).\(modelID)", indent: 44) {
            onPick(provider.id, modelID)
        }
    }

    private func choiceRow(title: String, detail: String?, isSelected: Bool, id: String, indent: CGFloat = 0,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: BighelpTokens.space12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: BighelpTokens.space8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.bighelp(.body, weight: .semibold))
                        .foregroundStyle(theme.action)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, indent)
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @BighelpThemeReader private var theme
}

/// The thinking levels as rows under the Thinking row, each with what it does.
struct BighelpInlineReasoningChooser: View {
    let current: String
    var isEnabled = true
    var identifier = "inline-reasoning"
    let onPick: (String) -> Void

    var body: some View {
        ForEach(AgentReasoningOption.all) { option in
            let isSelected = option.value == current
            Button { onPick(option.value) } label: {
                HStack(spacing: BighelpTokens.space12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.title)
                            .font(.bighelp(.body))
                            .foregroundStyle(theme.primaryText)
                        Text(option.detail)
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: BighelpTokens.space8)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.bighelp(.body, weight: .semibold))
                            .foregroundStyle(theme.action)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("\(identifier).\(option.id)")
        }
    }

    @BighelpThemeReader private var theme
}
