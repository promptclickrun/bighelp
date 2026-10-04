import SwiftUI

/// Pet Companion's character list: the same catalog characters Agent Studio offers, by set.
struct CompanionCatalogPicker: View {
    let title: String
    /// The look tiles draw with, so colors match what's chosen.
    let appearance: CompanionAppearance
    /// Shows "Use app default" first when set.
    var defaultTitle: String?
    let isDefault: Bool
    let onPick: (AvatarCatalogEntry?) -> Void

    @Environment(\.dismiss) private var dismiss
    private let store = AvatarCatalogStore.shared

    var body: some View {
        let _ = store.kitRevision
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space20) {
                if let defaultTitle {
                    Button {
                        onPick(nil)
                        dismiss()
                    } label: {
                        Label(defaultTitle, systemImage: isDefault ? "checkmark.circle.fill" : "circle")
                            .font(.bighelp(.body).weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("companion.picker.default")
                }
                ForEach([AvatarCatalog.Group.bighelp, .other], id: \.self) { group in
                    ForEach(store.catalog.sets(in: group, at: store.now)) { set in
                        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                            Text(set.name)
                                .font(.bighelp(.footnote).weight(.semibold))
                                .foregroundStyle(theme.secondaryText)
                                .textCase(.uppercase)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: BighelpTokens.space12)],
                                      spacing: BighelpTokens.space12) {
                                ForEach(store.catalog.avatars(in: set, at: store.now)) { entry in
                                    tile(entry)
                                }
                            }
                        }
                    }
                }
            }
            .padding(BighelpTokens.space20)
        }
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.keepCurrent() }
    }

    private func tile(_ entry: AvatarCatalogEntry) -> some View {
        let isSelected = !isDefault && appearance.catalogAvatar?.id == entry.id
        let preview = CompanionAppearance(usesCharacterColors: true, catalogAvatar: AvatarCatalogReference(entry))
        return Button {
            Task { _ = await store.pack(for: entry) }
            onPick(entry)
            dismiss()
        } label: {
            VStack(spacing: BighelpTokens.space4) {
                CompanionAvatar(appearance: preview, reaction: .idle, isAnimating: false)
                    .frame(width: 60, height: 60)
                Text(entry.name)
                    .font(.bighelp(.caption).weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isSelected ? theme.action : theme.border, lineWidth: isSelected ? 2.5 : 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("companion.picker.\(entry.id)")
    }

    @BighelpThemeReader private var theme
}
