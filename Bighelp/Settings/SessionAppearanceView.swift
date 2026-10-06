import PhotosUI
import SwiftUI
import UIKit

struct SessionAppearanceBackgroundView: View {
    let snapshot: SessionAppearanceSnapshot

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            background
            if snapshot.choice != .inherit, snapshot.dimming > 0 {
                Color.black.opacity(snapshot.dimming)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var background: some View {
        switch snapshot.choice {
        case .inherit:
            Color.clear
        case .sky:
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.08, green: 0.16, blue: 0.29), Color(red: 0.44, green: 0.24, blue: 0.35)]
                    : [Color(red: 0.71, green: 0.86, blue: 0.98), Color(red: 0.98, green: 0.73, blue: 0.65)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .ocean:
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.02, green: 0.19, blue: 0.27), Color(red: 0.05, green: 0.39, blue: 0.46)]
                    : [Color(red: 0.62, green: 0.88, blue: 0.91), Color(red: 0.18, green: 0.55, blue: 0.68)],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
        case .violet:
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.13, green: 0.10, blue: 0.27), Color(red: 0.39, green: 0.19, blue: 0.43)]
                    : [Color(red: 0.88, green: 0.80, blue: 0.98), Color(red: 0.63, green: 0.43, blue: 0.77)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .graphite:
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.08, green: 0.09, blue: 0.11), Color(red: 0.20, green: 0.22, blue: 0.25)]
                    : [Color(red: 0.78, green: 0.80, blue: 0.83), Color(red: 0.43, green: 0.46, blue: 0.51)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .photo:
            if let decodedPhoto = snapshot.decodedPhoto {
                Image(uiImage: decodedPhoto.image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.clear
            }
        }
    }
}

@MainActor
struct SessionAppearanceView: View {
    let store: SessionAppearanceStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var choice: SessionAppearanceChoice
    @State private var dimming: Double
    @State private var photoSelection: PhotosPickerItem?
    @State private var preparedPhoto: SessionAppearancePreparedPhoto?
    @State private var preparedImage: UIImage?
    @State private var errorMessage: String?
    @State private var isLoadingPhoto = false
    @State private var isApplying = false
    @State private var isDraftEdited = false
    @State private var photoLoadTask: Task<Void, Never>?

    init(store: SessionAppearanceStore) {
        self.store = store
        _choice = State(initialValue: store.preference?.choice ?? .inherit)
        _dimming = State(initialValue: store.preference?.dimming ?? 0.18)
    }

    var body: some View {
        Form {
            previewSection
            backgroundSection
            if choice != .inherit {
                readabilitySection
            }
            privacySection
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(isApplying)
                    .bighelpToolbarText()
                    .bighelpCancelAction()
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isApplying ? "Applying…" : "Apply") { apply() }
                    .disabled(!hasChanges || isLoadingPhoto || isApplying || (choice == .photo && !hasPhoto))
                    .bighelpToolbarText()
                    .bighelpDefaultAction()
                    .accessibilityIdentifier("session-appearance.apply")
            }
        }
        .interactiveDismissDisabled(hasChanges && !isApplying)
        .onChange(of: photoSelection) { _, item in
            guard let item else { return }
            load(item)
        }
        .onChange(of: store.preference) { _, preference in
            guard !isDraftEdited, !isApplying else { return }
            choice = preference?.choice ?? .inherit
            dimming = preference?.dimming ?? 0.18
        }
        .onDisappear {
            photoLoadTask?.cancel()
            photoLoadTask = nil
        }
        .accessibilityIdentifier("session-appearance")
    }

    private var previewSection: some View {
        Section {
            ZStack {
                SessionAppearanceBackgroundView(snapshot: draftSnapshot)
                if choice == .photo, let preparedImage {
                    Image(uiImage: preparedImage)
                        .resizable()
                        .scaledToFill()
                    Color.black.opacity(dimming)
                }
                VStack(spacing: BighelpTokens.space12) {
                    Text("Conversation preview")
                        .font(.bighelp(.caption).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.86))
                    HStack {
                        Text("Incoming message")
                            .font(.bighelp(.callout))
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
                            .padding(.horizontal, BighelpTokens.space12)
                            .padding(.vertical, BighelpTokens.space8)
                            .background(.regularMaterial, in: .rect(cornerRadius: 17))
                        Spacer(minLength: BighelpTokens.space24)
                    }
                    HStack {
                        Spacer(minLength: BighelpTokens.space24)
                        Text("Outgoing message")
                            .font(.bighelp(.callout))
                            .foregroundStyle(.white)
                            .padding(.horizontal, BighelpTokens.space12)
                            .padding(.vertical, BighelpTokens.space8)
                            .background(Color.accentColor, in: .rect(cornerRadius: 17))
                    }
                }
                .padding(BighelpTokens.space16)
            }
            .frame(height: 220)
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview of the selected conversation background")
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private var backgroundSection: some View {
        Section {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 82), spacing: BighelpTokens.space12)],
                spacing: BighelpTokens.space16
            ) {
                ForEach(SessionAppearanceChoice.allCases.filter { $0 != .photo }) { option in
                    Button { select(option) } label: {
                        choiceTile(option)
                    }
                    // A plain button on Catalyst only receives clicks where its
                    // label paints. Keep the whole tile targetable with a mouse.
                    .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12))
                    .accessibilityValue(choice == option ? "Selected" : "")
                }

                let photoTile = choiceTile(.photo)
                PhotosPicker(selection: $photoSelection, matching: .images) {
                    photoTile
                }
                .buttonStyle(.plain)
                .disabled(isLoadingPhoto || isApplying)
                .accessibilityValue(choice == .photo ? "Selected" : "")
                .accessibilityIdentifier("session-appearance.choose-photo")
            }
            .padding(.vertical, BighelpTokens.space8)

            if store.preference != nil, choice != .inherit {
                Button("Reset to App Background", systemImage: "arrow.uturn.backward") {
                    choice = .inherit
                    isDraftEdited = true
                    errorMessage = nil
                }
                .accessibilityHint("Selects the inherited bighelp background. Apply to save the reset.")
                .accessibilityIdentifier("session-appearance.reset")
            }

            if isLoadingPhoto {
                ProgressView("Preparing photo…")
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Background")
        } footer: {
            Text("App inherits the normal bighelp background. Other choices apply only to this conversation and are not shared with its host or participants.")
        }
    }

    private var readabilitySection: some View {
        Section {
            Slider(value: Binding(
                get: { dimming },
                set: {
                    dimming = $0
                    isDraftEdited = true
                }
            ), in: 0...SessionAppearancePreference.maximumDimming, step: 0.05) {
                Text("Background dimming")
            } minimumValueLabel: {
                Image(systemName: "sun.max")
                    .accessibilityLabel("Less dimming")
            } maximumValueLabel: {
                Image(systemName: "moon.fill")
                    .accessibilityLabel("More dimming")
            }
            Text("Dimming: \(Int((dimming * 100).rounded()))%")
                .font(.bighelp(.caption))
                .foregroundStyle(.secondary)
        } header: {
            Text("Readability")
        } footer: {
            Text("Message colors and text contrast continue to follow bighelp’s conversation style.")
        }
    }

    private var privacySection: some View {
        Section {
            Label("Saved for this conversation", systemImage: "lock.shield")
            Label("Not shared with the host or participants", systemImage: "person.2.slash")
        } header: {
            Text("Privacy")
        } footer: {
            Text("Appearance preferences may be restored with app data. Selected photos are resized, protected while the device is locked, excluded from backup, and erased with local account data.")
        }
    }

    private func choiceTile(_ option: SessionAppearanceChoice) -> some View {
        VStack(spacing: BighelpTokens.space8) {
            ZStack {
                Circle()
                    .fill(tileBackground(option))
                    .frame(width: 58, height: 58)
                Image(systemName: option.systemImage)
                    .font(.bighelp(.title3).weight(.semibold))
                    .foregroundStyle(option == .inherit ? Color.accentColor : (option == .photo ? Color.primary : .white))
                if choice == option {
                    Circle()
                        .stroke(.primary, lineWidth: 2)
                        .frame(width: 66, height: 66)
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .offset(x: 23, y: 23)
                }
            }
            Text(option.title)
                .font(.bighelp(.caption))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(option == .photo ? "Choose a photo background" : "\(option.title) background")
    }

    private func tileBackground(_ option: SessionAppearanceChoice) -> AnyShapeStyle {
        switch option {
        case .inherit:
            AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
        case .sky:
            AnyShapeStyle(LinearGradient(colors: [.blue.opacity(0.75), .orange.opacity(0.75)], startPoint: .top, endPoint: .bottom))
        case .ocean:
            AnyShapeStyle(LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .violet:
            AnyShapeStyle(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .graphite:
            AnyShapeStyle(LinearGradient(colors: [.gray, .black], startPoint: .top, endPoint: .bottom))
        case .photo:
            if let preparedImage {
                AnyShapeStyle(ImagePaint(image: Image(uiImage: preparedImage), scale: 0.12))
            } else if let decodedPhoto = store.snapshot.decodedPhoto {
                AnyShapeStyle(ImagePaint(
                    image: Image(uiImage: decodedPhoto.image),
                    scale: 0.12
                ))
            } else {
                AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
            }
        }
    }

    private var draftSnapshot: SessionAppearanceSnapshot {
        guard choice != .photo || preparedPhoto == nil else {
            return SessionAppearanceSnapshot(choice: .photo, dimming: dimming, photoURL: nil)
        }
        if choice == .photo {
            return SessionAppearanceSnapshot(
                choice: .photo,
                dimming: dimming,
                photoURL: store.snapshot.photoURL,
                decodedPhoto: store.snapshot.decodedPhoto
            )
        }
        return SessionAppearanceSnapshot(choice: choice, dimming: dimming, photoURL: nil)
    }

    private var hasPhoto: Bool {
        preparedPhoto != nil || store.snapshot.decodedPhoto != nil
    }

    private var hasChanges: Bool {
        preparedPhoto != nil
            || choice != (store.preference?.choice ?? .inherit)
            || (choice != .inherit && dimming != (store.preference?.dimming ?? 0.18))
    }

    private func select(_ option: SessionAppearanceChoice) {
        guard !isApplying else { return }
        choice = option
        isDraftEdited = true
        errorMessage = nil
    }

    private func load(_ item: PhotosPickerItem) {
        guard !isLoadingPhoto, !isApplying else { return }
        isLoadingPhoto = true
        errorMessage = nil
        photoLoadTask = Task { @MainActor in
            defer {
                isLoadingPhoto = false
                photoSelection = nil
                photoLoadTask = nil
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw SessionAppearanceStoreError.unsupportedPhoto
                }
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) {
                    try SessionAppearanceStore.preparePhoto(data)
                }
                let prepared = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                preparedPhoto = prepared
                preparedImage = prepared.decodedPhoto.image
                choice = .photo
                isDraftEdited = true
            } catch is CancellationError {
                return
            } catch {
                errorMessage = photoError(error)
            }
        }
    }

    private func apply() {
        guard hasChanges, !isApplying else { return }
        isApplying = true
        errorMessage = nil
        do {
            try store.apply(choice: choice, dimming: dimming, preparedPhoto: preparedPhoto)
            dismiss()
        } catch {
            errorMessage = "bighelp couldn’t save this background. Your current conversation appearance is unchanged."
            isApplying = false
        }
    }

    private func photoError(_ error: any Error) -> String {
        switch error as? SessionAppearanceStoreError {
        case .photoTooLarge(let maximumBytes):
            "That photo is too large. Choose one smaller than \(maximumBytes / 1_000_000) MB."
        case .photoDimensionsTooLarge:
            "That photo has too many pixels. Choose a smaller image."
        default:
            "bighelp couldn’t use that photo. Choose a JPEG, PNG, or HEIF image."
        }
    }
}
