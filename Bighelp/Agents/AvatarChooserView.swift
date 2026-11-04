import PhotosUI
import SwiftUI

/// Edit avatar: make one in Bot Studio, pick a PetDex pet (which keeps its own look and moves), or
/// use a photo. Each choice opens in place, in the same sheet; Back returns here.
struct AvatarChooserView: View {
    private enum Page { case choose, studio, petdex }

    let start: AvatarCreatorStart
    let characters: CompanionAppearance
    let agentName: String
    let faceName: String
    let petSource: PetdexSource
    /// What the confirm buttons say: "Use avatar" in Agent Studio, "Save" where it saves at once.
    var useTitle = "Use avatar"
    let onUse: (AvatarCreatorResult) -> Void

    @State private var page = Page.choose
    @State private var photoItem: PhotosPickerItem?
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme
    private let library = BotBodyLibrary.shared

    var body: some View {
        switch page {
        case .choose:
            chooser
        case .studio:
            BotStudioView(start: BotLook.studioStart(for: start), agentName: agentName, saveTitle: useTitle,
                          onBack: { page = .choose }) { look in
                onUse(.look(AgentAvatarLook(style: .photo, studio: look)))
                dismiss()
            }
        case .petdex:
            AvatarCreatorView(start: start, characters: characters, agentName: agentName, faceName: faceName,
                              petSource: petSource, petsOnly: true, useTitle: useTitle, onUse: onUse)
        }
    }

    private var chooser: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: BighelpTokens.space16) {
                    option(title: "Bot Studio", detail: "Make your own. Pick a body, eyes, colors and how it moves.",
                           id: "studio") {
                        HStack(spacing: BighelpTokens.space8) {
                            ForEach(samples, id: \.body.id) { look in
                                BotLookView(look: look).frame(width: 48, height: 48)
                            }
                        }
                    } open: { page = .studio }
                    option(title: "PetDex", detail: "Pick a pixel pet. It keeps its own look and moves.", id: "petdex") {
                        Image(systemName: "pawprint.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(theme.secondaryText)
                            .frame(height: 48)
                    } open: { page = .petdex }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Text("Use a photo instead")
                            .bighelpFont(.label)
                            .underline()
                            .foregroundStyle(theme.secondaryText)
                            .frame(minHeight: BighelpTokens.hitTarget)
                    }
                    .accessibilityIdentifier("avatar.chooser.photo")
                }
                .padding(BighelpTokens.space16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("\(agentName)'s avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("avatar.chooser.cancel")
                }
            }
        }
        .task { await library.refreshIfNeeded() }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            onUse(.photo(item))
            dismiss()
        }
    }

    /// A few bodies from different sets, so the card shows the range.
    private var samples: [BotLook] {
        let sets = library.catalog.available(at: .now)
        return sets.prefix(6).compactMap { $0.bodies.first.map(BotLook.init(body:)) }
    }

    private func option<Preview: View>(title: String, detail: String, id: String,
                                       @ViewBuilder preview: () -> Preview, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                HStack {
                    Text(title)
                        .bighelpFont(.sectionTitle, weight: .bold)
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.bighelp(.body).weight(.semibold))
                        .foregroundStyle(theme.tertiaryText)
                }
                Text(detail)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                preview()
            }
            .padding(BighelpTokens.space16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: .rect(cornerRadius: 22))
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("avatar.chooser.\(id)")
    }
}
