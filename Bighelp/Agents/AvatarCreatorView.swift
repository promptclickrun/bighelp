import PhotosUI
import SwiftUI
import UIKit

/// What the creator hands back to Agent Studio.
enum AvatarCreatorResult {
    case companion(CompanionAppearance)
    /// A Hermes face or shape; the studio draws its picture.
    case look(AgentAvatarLook)
    /// A petdex pet's first frame, ready to save; its moves play in chats.
    case pet(PetdexPet, avatar: Data)
    case photo(PhotosPickerItem)
}

/// Agent Studio avatar creator: pick a character or a Bit, then make it yours
/// with a colorway or color, headwear (or a Bit's face), a pattern and how it moves.
/// Hermes Desktop's faces and shapes, a petdex pet or a photo work too.
@MainActor
@Observable
final class AvatarCreatorModel {
    /// The kind of avatar: the app's own characters, or Hermes Desktop's choices.
    enum Style: String, CaseIterable, Identifiable {
        case characters, face, shapes, pets, photo

        var id: String { rawValue }

        var title: String {
            switch self {
            case .characters: "Characters"
            case .face: "Face"
            case .shapes: "Shapes"
            case .pets: "Pets"
            case .photo: "Photo"
            }
        }
    }

    var style: Style = .characters
    /// The blob face: follows the name unless locked, optionally pinned to a silhouette.
    var blobShape = HermesBlobShape()
    var shape = "circle"
    /// A picked shape color; nil matches the name.
    var shapeColor: String?
    /// A picked face color; nil is the color the face's name gives it.
    var faceColor: String?
    private(set) var selectedPet: PetdexPet?
    private(set) var selectedPetFrame: Data?
    private(set) var selectedPetAvatar: Data?
    private(set) var isLoadingPet = false
    private(set) var petError: String?
    enum Tab: String, CaseIterable, Identifiable {
        case character, color, extras, moves

        var id: String { rawValue }

        var title: String {
            switch self {
            case .character: "Character"
            case .color: "Color"
            case .extras: "Extras"
            case .moves: "Moves"
            }
        }

        var systemImage: String {
            switch self {
            case .character: "face.smiling"
            case .color: "paintpalette"
            case .extras: "crown"
            case .moves: "figure.dance"
            }
        }
    }

    /// Curated body colors; a custom color and the app theme are also offered.
    static let palette: [(name: String, hex: String)] = [
        ("Coral", "#FF6B5A"), ("Tangerine", "#FF9A3C"), ("Sunflower", "#F6C445"), ("Lime", "#A6D65A"),
        ("Mint", "#4CC9A0"), ("Teal", "#2BB3B1"), ("Sky", "#56AEE0"), ("Cobalt", "#3F6FD8"),
        ("Lavender", "#9B87F5"), ("Grape", "#7B4FD6"), ("Bubblegum", "#F28FC0"), ("Rose", "#E5487A"),
        ("Cocoa", "#8B5E3C"), ("Stone", "#9AA0A6"), ("Charcoal", "#2E3238"), ("Snow", "#F2F1EC"),
    ]

    var appearance: CompanionAppearance
    var tab: Tab = .character
    /// A short celebration after a tap on the stage.
    private(set) var isCelebrating = false
    private var celebration: Task<Void, Never>?

    init(appearance: CompanionAppearance, look: AgentAvatarLook? = nil) {
        self.appearance = appearance
        switch look?.style {
        case .face:
            style = .face
            blobShape = HermesBlobShape(look?.shape) ?? HermesBlobShape()
            faceColor = look?.color
        case .shape:
            style = .shapes
            shape = look?.shape ?? shape
            shapeColor = look?.color
        default:
            break
        }
    }

    func randomizeFace() {
        blobShape.seedPart = HermesBlobShape.randomSeed()
    }

    /// Lock keeps today's face even if the name changes; unlock follows the name again.
    func toggleFaceLock(name: String) {
        blobShape.seedPart = blobShape.isLocked ? "" : name
    }

    func select(_ pet: PetdexPet, gallery: PetdexGalleryModel) async {
        selectedPet = pet
        selectedPetFrame = gallery.cachedThumbnail(pet)
        selectedPetAvatar = nil
        petError = nil
        isLoadingPet = true
        defer { if selectedPet == pet { isLoadingPet = false } }
        let frame = await gallery.thumbnail(pet)
        let avatar = await gallery.avatar(for: pet)
        guard selectedPet == pet else { return }
        selectedPetFrame = frame
        selectedPetAvatar = avatar
        if avatar == nil { petError = "Couldn’t load that pet. Try another." }
    }

    /// The finished choice for this style, or nil when there's nothing to use yet.
    func result(faceName: String) -> AvatarCreatorResult? {
        switch style {
        case .characters:
            .companion(appearance)
        case .face:
            .look(AgentAvatarLook(style: .face, shape: blobShape.string, color: faceColor,
                                  faceSeed: blobShape.isLocked ? nil : faceName))
        case .shapes:
            .look(AgentAvatarLook(style: .shape, shape: shape, color: shapeColor))
        case .pets:
            selectedPetAvatar.flatMap { data in selectedPet.map { .pet($0, avatar: data) } }
        case .photo:
            nil
        }
    }

    /// New agents start from a random pleasant look instead of the same one.
    static func surprise() -> CompanionAppearance {
        let model = AvatarCreatorModel(appearance: CompanionAppearance(usesCharacterColors: true))
        model.shuffle()
        return model.appearance
    }

    var tabs: [Tab] { Tab.allCases }

    func select(_ character: CompanionCharacter) {
        appearance.character = character
        if !tabs.contains(tab) { tab = .character }
    }

    func selectColor(_ hex: String) {
        appearance.usesCharacterColors = false
        appearance.matchesTheme = false
        appearance.colorHex = hex
    }

    func selectThemeColor() {
        appearance.usesCharacterColors = false
        appearance.matchesTheme = true
    }

    /// A kit colorway; "original" keeps each character's own palette.
    func selectColorway(_ id: String) {
        appearance.colorway = id == "original" ? nil : id
        appearance.usesCharacterColors = true
    }

    /// Kit colorways, Original first.
    static var colorways: [AvatarKit.Theme] { AvatarKit.bundled?.themes ?? [] }

    func shuffle() {
        var next = appearance
        let characters = CompanionCharacter.allCases.filter { $0 != appearance.character }
        next.character = characters.randomElement() ?? .lobster
        next.matchesTheme = false
        if Int.random(in: 0..<3) == 0 {
            next.usesCharacterColors = false
            next.colorHex = Self.palette.filter { $0.hex != appearance.colorHex }.randomElement()?.hex
                ?? CompanionAppearance.fallbackColorHex
        } else {
            next.usesCharacterColors = true
            let way = Self.colorways.randomElement()?.id ?? "original"
            next.colorway = way == "original" ? nil : way
        }
        next.topper = !next.character.isBit && Int.random(in: 0..<3) == 0
            ? CompanionTopper.allCases.randomElement() : CompanionTopper.none
        next.bitEyes = Int.random(in: 0..<3) == 0 ? CompanionBitEyes.allCases.randomElement() : nil
        next.bitMouth = Int.random(in: 0..<3) == 0 ? CompanionBitMouth.allCases.randomElement() : nil
        next.bitAccessory = Int.random(in: 0..<3) == 0 ? CompanionBitAccessory.allCases.randomElement() : nil
        next.pattern = Int.random(in: 0..<3) == 0 ? CompanionPattern.allCases.randomElement() : CompanionPattern.none
        next.vibe = CompanionVibe.allCases.randomElement()
        appearance = next
        if !tabs.contains(tab) { tab = .character }
    }

    func celebrate() {
        celebration?.cancel()
        isCelebrating = true
        celebration = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.isCelebrating = false
        }
    }

    /// The current look on another character, for tile previews.
    func appearance(for character: CompanionCharacter) -> CompanionAppearance {
        var preview = appearance
        preview.character = character
        preview.vibe = nil
        return preview
    }
}

struct AvatarCreatorView: View {
    @State private var model: AvatarCreatorModel
    @State private var pets: PetdexGalleryModel
    @State private var photoItem: PhotosPickerItem?
    /// While typing a pet search on a phone the stage steps aside, so the
    /// matches show above the keyboard.
    @FocusState private var isSearchingPets: Bool
    let agentName: String
    /// The profile name Hermes faces are drawn from.
    let faceName: String
    let onUse: (AvatarCreatorResult) -> Void
    @Environment(\.dismiss) private var dismiss
    #if os(visionOS)
    /// A mood being tried on the 3D stage; nil plays the chosen moves.
    @State private var tryingMood: String?
    @State private var isShowingInRoom = false
    @Environment(\.spatialAvatar) private var spatialAvatar
    @Environment(\.openWindow) private var openWindow
    #endif

    init(
        appearance: CompanionAppearance,
        look: AgentAvatarLook? = nil,
        agentName: String,
        faceName: String,
        petSource: PetdexSource,
        onUse: @escaping (AvatarCreatorResult) -> Void
    ) {
        _model = State(initialValue: AvatarCreatorModel(appearance: appearance, look: look))
        _pets = State(initialValue: PetdexGalleryModel(source: petSource))
        self.agentName = agentName
        self.faceName = faceName
        self.onUse = onUse
    }

    var body: some View {
        NavigationStack {
            layout
            .background(theme.canvas.ignoresSafeArea())
            #if os(visionOS)
            // What you try on in the room follows every change, until you're done here.
            .onChange(of: model.appearance) { _, appearance in
                if isShowingInRoom { spatialAvatar?.previewAppearance = appearance }
            }
            .onDisappear { spatialAvatar?.previewAppearance = nil }
            #endif
            .navigationTitle("Avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .frame(minHeight: BighelpTokens.toolbarHitTarget)
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                        #endif
                        .accessibilityIdentifier("avatar.creator.cancel")
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use avatar") {
                        guard let result = model.result(faceName: faceName) else { return }
                        onUse(result)
                        dismiss()
                    }
                    .disabled(model.result(faceName: faceName) == nil)
                    .fontWeight(.semibold)
                    .bighelpProminentButtonStyle()
                    .buttonBorderShape(.capsule)
                    .tint(theme.action)
                    .foregroundStyle(theme.actionForeground)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityIdentifier("avatar.creator.use")
                }
            }
        }
        .accessibilityIdentifier("avatar.creator")
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            onUse(.photo(item))
            dismiss()
        }
    }

    /// Phone and iPad: the character on top, choices under it. Vision Pro: the
    /// 3D character beside the choices, in a wider sheet, so both have room.
    /// The Mac too: its sheet is wide and short, so a stage on top left the
    /// choices a sliver.
    @ViewBuilder
    private var layout: some View {
        #if os(visionOS) || targetEnvironment(macCatalyst)
        GeometryReader { proxy in
            HStack(spacing: 0) {
                stage
                    .frame(width: min(440, proxy.size.width * 0.46))
                    .padding([.leading, .vertical], BighelpTokens.space20)
                VStack(spacing: 0) {
                    styleBar
                        .padding(.top, BighelpTokens.space12)
                    if model.style == .characters {
                        tabBar
                            .padding(.top, BighelpTokens.space8)
                    }
                    choices
                        .padding(.top, BighelpTokens.space12)
                }
            }
        }
        #else
        VStack(spacing: 0) {
            if !(isSearchingPets && model.style == .pets) {
                stage
                    .padding(.horizontal, BighelpTokens.space20)
                    .padding(.top, BighelpTokens.space8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            styleBar
                .padding(.top, BighelpTokens.space12)
            if model.style == .characters {
                tabBar
                    .padding(.top, BighelpTokens.space8)
            }
            choices
                .padding(.top, BighelpTokens.space12)
        }
        #endif
    }

    private var choices: some View {
        ScrollView {
            panel
                .padding(.horizontal, BighelpTokens.space20)
                .padding(.bottom, BighelpTokens.space20)
        }
        .scrollIndicators(.hidden)
        .dismissesKeyboardOnScroll(true)
        // Each tab opens at its top, not where the last one was scrolled.
        .id("\(model.style.rawValue).\(model.tab.rawValue)")
    }

    // MARK: Stage

    private var stage: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(theme.surface)
                .overlay {
                    RadialGradient(
                        colors: [stageColor.opacity(0.28), stageColor.opacity(0.06), .clear],
                        center: .center, startRadius: 10, endRadius: 190
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                }
                .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            if model.style == .characters {
                characterStage
            } else {
                hermesStage
                    .frame(width: Self.hermesPreviewSize, height: Self.hermesPreviewSize)
                    .accessibilityIdentifier("avatar.creator.preview")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, BighelpTokens.space20)
            }
            Text(stageTitle)
                .font(.bighelp(.headline))
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, BighelpTokens.space16)
                .padding(.vertical, BighelpTokens.space16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
                .accessibilityIdentifier("avatar.creator.name")
            if model.style == .characters || model.style == .face {
            Button {
                withAnimation(.snappy) {
                    if model.style == .face { model.randomizeFace() } else { model.shuffle() }
                }
            } label: {
                Image(systemName: "dice")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(theme.incomingMessageBackground))
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .padding(BighelpTokens.space8)
            .accessibilityLabel(model.style == .face ? "Randomize" : "Shuffle")
            .accessibilityHint(model.style == .face ? "Tries a random face." : "Tries a random character and look.")
            .accessibilityIdentifier("avatar.creator.shuffle")
            }
        }
        #if os(visionOS) || targetEnvironment(macCatalyst)
        .frame(maxHeight: .infinity)
        #else
        .frame(height: 260)
        #endif
    }

    @ViewBuilder
    private var characterStage: some View {
        #if os(visionOS)
        spatialStage
        #else
        CompanionAvatar(
            appearance: model.appearance,
            reaction: model.isCelebrating ? .celebrate : .idle,
            isAnimating: true
        )
        .frame(width: Self.previewSize, height: Self.previewSize)
        .contentShape(.rect)
        .onTapGesture { model.celebrate() }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Plays a little celebration.")
        .accessibilityIdentifier("avatar.creator.preview")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, BighelpTokens.space20)
        #endif
    }

    private var stageTitle: String {
        switch model.style {
        case .characters: model.appearance.character.displayName
        case .face: model.blobShape.kind?.displayName ?? "Face"
        case .shapes: HermesShapeFace.displayName(model.shape)
        case .pets: model.selectedPet?.displayName ?? "Pets"
        case .photo: "Photo"
        }
    }

    #if !os(visionOS)
    /// The Mac's stage is the sheet's full height, so the character can be bigger.
    private static var previewSize: CGFloat { BighelpPlatform.isMac ? 240 : 180 }
    #endif
    private static var hermesPreviewSize: CGFloat { BighelpPlatform.isMac ? 220 : 160 }

    #if os(visionOS)
    /// Moods to try on the 3D stage: how it looks while the agent works.
    private static let tryouts: [(title: String, mood: String?)] = [
        ("Its moves", nil), ("Listening", "listening"), ("Thinking", "thinking"),
        ("Talking", "nod"), ("Happy", "excited"), ("Sleepy", "sleepy"),
    ]

    /// Vision Pro: the character in 3D, as it will stand in your room.
    private var spatialStage: some View {
        VStack(spacing: BighelpTokens.space12) {
            if let look = SpatialAvatarLook(appearance: model.appearance, themeHex: theme.actionHex) {
                SpatialAvatarPreview(look: look, mood: tryingMood ?? model.appearance.vibe?.moodID, height: 380) {
                    model.celebrate()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(model.appearance.character.displayName) in 3D")
                .accessibilityHint("Pinch for a hop; drag to turn it around.")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default) { model.celebrate() }
                .accessibilityIdentifier("avatar.creator.preview")
            }
            // Wraps onto two rows in the narrow stage, so every mood is in view.
            FlowLayout(spacing: BighelpTokens.space8) {
                    ForEach(Self.tryouts, id: \.title) { tryout in
                        let isSelected = tryingMood == tryout.mood
                        Button {
                            withAnimation(.snappy) { tryingMood = tryout.mood }
                        } label: {
                            Text(tryout.title)
                                .font(.bighelp(.callout).weight(.semibold))
                                .foregroundStyle(isSelected ? theme.actionForeground : theme.primaryText)
                                .padding(.horizontal, BighelpTokens.space16)
                                .frame(minHeight: BighelpTokens.hitTarget)
                                .background(Capsule().fill(isSelected ? theme.action : theme.incomingMessageBackground))
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityIdentifier("avatar.creator.try.\(tryout.mood ?? "moves")")
                    }
                    if spatialAvatar != nil {
                        Button {
                            spatialAvatar?.previewAppearance = model.appearance
                            isShowingInRoom = true
                            if spatialAvatar?.isVolumeOpen != true { openWindow(id: SpatialAvatarSceneID.avatar) }
                        } label: {
                            Label(isShowingInRoom ? "In your room" : "See it in your room",
                                  systemImage: "cube.transparent")
                                .font(.bighelp(.callout).weight(.semibold))
                                .foregroundStyle(theme.action)
                                .padding(.horizontal, BighelpTokens.space16)
                                .frame(minHeight: BighelpTokens.hitTarget)
                                .background(Capsule().strokeBorder(theme.action, lineWidth: 1.5))
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityHint("Shows this look at full size in your space while you design it.")
                        .accessibilityIdentifier("avatar.creator.in-room")
                    }
            }
            .padding(.horizontal, BighelpTokens.space16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, BighelpTokens.space16)
    }
    #endif

    private var stageColor: Color {
        Color(hex: String(resolvedBodyHex.dropFirst()))
    }

    private var resolvedBodyHex: String {
        let themeHex = CompanionAppearance.validatedColorHex(theme.actionHex) ?? CompanionAppearance.fallbackColorHex
        return model.appearance.avatarKitColors(themeHex: themeHex)?.primary ?? themeHex
    }

    // MARK: Tabs

    /// Equal-width strip: every category is visible at once, no scrolling.
    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(model.tabs) { tab in
                let isSelected = model.tab == tab
                Button {
                    withAnimation(.snappy) { model.tab = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.bighelp(.caption2).weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(isSelected ? theme.actionForeground : theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.action)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("avatar.creator.tab.\(tab.rawValue)")
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.incomingMessageBackground))
        .padding(.horizontal, BighelpTokens.space20)
    }

    @ViewBuilder
    private var panel: some View {
        switch model.style {
        case .characters:
            switch model.tab {
            case .character: characterPanel
            case .color: colorPanel
            case .extras: extrasPanel
            case .moves: movesPanel
            }
        case .face: facePanel
        case .shapes: shapesPanel
        case .pets: petsPanel
        case .photo: photoPanel
        }
    }

    // MARK: Character

    private var characterPanel: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            characterSection("Characters", CompanionCharacter.characters)
            characterSection("Bits", CompanionCharacter.bits)
        }
    }

    private func characterSection(_ title: String, _ characters: [CompanionCharacter]) -> some View {
        section(title) {
            grid(minimum: 76) {
                ForEach(characters) { character in
                    tile(
                        title: character.displayName,
                        isSelected: model.appearance.character == character,
                        identifier: "avatar.creator.character.\(character.rawValue)"
                    ) {
                        withAnimation(.snappy) { model.select(character) }
                    } preview: {
                        CompanionAvatar(appearance: model.appearance(for: character), reaction: .idle, isAnimating: false)
                    }
                }
            }
        }
    }

    // MARK: Color

    private var colorPanel: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            section("Colorway") {
                grid(minimum: 76) {
                    ForEach(AvatarCreatorModel.colorways) { way in
                        tile(
                            title: way.name,
                            isSelected: model.appearance.usesCharacterColors && (model.appearance.colorway ?? "original") == way.id,
                            identifier: "avatar.creator.colorway.\(way.id)"
                        ) {
                            model.selectColorway(way.id)
                        } preview: {
                            CompanionAvatar(appearance: preview {
                                $0.colorway = way.id == "original" ? nil : way.id
                                $0.usesCharacterColors = true
                            }, reaction: .idle, isAnimating: false)
                        }
                    }
                }
            }
            mainColorSection
        }
    }

    private var mainColorSection: some View {
        section("Main color") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BighelpTokens.space12), count: 6),
                      spacing: BighelpTokens.space12) {
                swatch(
                    fill: AnyShapeStyle(AngularGradient(colors: [theme.action, theme.action.opacity(0.55), theme.action],
                                                        center: .center)),
                    isSelected: !model.appearance.usesCharacterColors && model.appearance.matchesTheme,
                    label: "Theme color",
                    identifier: "avatar.creator.color.theme"
                ) { model.selectThemeColor() } overlay: {
                    Image(systemName: "sparkles").font(.bighelp(.caption).weight(.bold)).foregroundStyle(theme.actionForeground)
                }
                ForEach(AvatarCreatorModel.palette, id: \.hex) { color in
                    swatch(
                        fill: AnyShapeStyle(Color(hex: String(color.hex.dropFirst()))),
                        isSelected: !model.appearance.usesCharacterColors && !model.appearance.matchesTheme
                            && model.appearance.colorHex == color.hex,
                        label: color.name,
                        identifier: "avatar.creator.color.\(color.name.lowercased())"
                    ) { model.selectColor(color.hex) } overlay: { EmptyView() }
                }
                ColorPicker("Custom color", selection: customColorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 44, height: 44)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Custom color")
                    .accessibilityIdentifier("avatar.creator.color.custom")
            }
        }
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { stageColor },
            set: { color in
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
                guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: nil) else { return }
                model.selectColor(CompanionColor.hex(red: red, green: green, blue: blue))
            }
        )
    }

    // MARK: Extras

    private var extrasPanel: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            if model.appearance.character.isBit {
                bitFaceSections
            } else {
                headwearSection
            }
            section("Pattern") {
                grid(minimum: 76) {
                    ForEach(CompanionPattern.allCases) { pattern in
                        tile(
                            title: pattern.displayName,
                            isSelected: (model.appearance.pattern ?? .none) == pattern,
                            identifier: "avatar.creator.pattern.\(pattern.rawValue)"
                        ) {
                            model.appearance.pattern = pattern
                        } preview: {
                            CompanionAvatar(appearance: preview { $0.pattern = pattern }, reaction: .idle, isAnimating: false)
                        }
                    }
                }
            }
        }
    }

    private var headwearSection: some View {
        section("Headwear") {
            grid(minimum: 76) {
                ForEach(CompanionTopper.allCases) { topper in
                    tile(
                        title: topper.displayName,
                        isSelected: (model.appearance.topper ?? .none) == topper,
                        identifier: "avatar.creator.topper.\(topper.rawValue)"
                    ) {
                        model.appearance.topper = topper
                    } preview: {
                        CompanionAvatar(appearance: preview { $0.topper = topper }, reaction: .idle, isAnimating: false)
                            .padding(.top, 6)
                    }
                }
            }
        }
    }

    /// A Bit's own face parts, from the kit.
    @ViewBuilder
    private var bitFaceSections: some View {
        let face = model.appearance.avatarKitFace ?? AvatarKitFace(
            AvatarKit.bundled?.character(model.appearance.character.rawValue)?.face
        )
        section("Eyes") {
            grid(minimum: 76) {
                ForEach(CompanionBitEyes.allCases) { eyes in
                    tile(title: eyes.displayName, isSelected: face.eyes == eyes.rawValue,
                         identifier: "avatar.creator.eyes.\(eyes.rawValue)") {
                        model.appearance.bitEyes = eyes
                    } preview: {
                        CompanionAvatar(appearance: preview { $0.bitEyes = eyes }, reaction: .idle, isAnimating: false)
                    }
                }
            }
        }
        section("Mouth") {
            grid(minimum: 76) {
                ForEach(CompanionBitMouth.allCases) { mouth in
                    tile(title: mouth.displayName, isSelected: face.mouth == mouth.rawValue,
                         identifier: "avatar.creator.mouth.\(mouth.rawValue)") {
                        model.appearance.bitMouth = mouth
                    } preview: {
                        CompanionAvatar(appearance: preview { $0.bitMouth = mouth }, reaction: .idle, isAnimating: false)
                    }
                }
            }
        }
        section("On top") {
            grid(minimum: 76) {
                ForEach(CompanionBitAccessory.allCases) { accessory in
                    tile(title: accessory.displayName, isSelected: face.accessory == accessory.rawValue,
                         identifier: "avatar.creator.accessory.\(accessory.rawValue)") {
                        model.appearance.bitAccessory = accessory
                    } preview: {
                        CompanionAvatar(appearance: preview { $0.bitAccessory = accessory }, reaction: .idle, isAnimating: false)
                            .padding(.top, 6)
                    }
                }
            }
        }
        section("Cheeks") {
            grid(minimum: 76) {
                ForEach([true, false], id: \.self) { shows in
                    tile(title: shows ? "Blush" : "No blush", isSelected: face.cheeks == shows,
                         identifier: "avatar.creator.cheeks.\(shows ? "on" : "off")") {
                        model.appearance.showsCheeks = shows
                    } preview: {
                        CompanionAvatar(appearance: preview { $0.showsCheeks = shows }, reaction: .idle, isAnimating: false)
                    }
                }
            }
        }
    }

    // MARK: Moves

    private var movesPanel: some View {
        section("When it's idle") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: BighelpTokens.space12),
                                GridItem(.flexible(), spacing: BighelpTokens.space12)],
                      spacing: BighelpTokens.space12) {
                ForEach(CompanionVibe.allCases) { vibe in
                    let isSelected = (model.appearance.vibe ?? .calm) == vibe
                    Button {
                        withAnimation(.snappy) { model.appearance.vibe = vibe }
                    } label: {
                        Label(vibe.displayName, systemImage: vibe.systemImage)
                            .font(.bighelp(.body).weight(.semibold))
                            .foregroundStyle(isSelected ? theme.actionForeground : theme.primaryText)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(isSelected ? theme.action : theme.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(isSelected ? Color.clear : theme.border, lineWidth: 1)
                            )
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("avatar.creator.move.\(vibe.rawValue)")
                }
            }
        }
    }

    // MARK: Hermes styles

    /// Characters, Hermes faces and shapes, petdex pets, or a photo.
    private var styleBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: BighelpTokens.space8) {
                ForEach(AvatarCreatorModel.Style.allCases) { style in
                    let isSelected = model.style == style
                    Button {
                        withAnimation(.snappy) { model.style = style }
                    } label: {
                        Text(style.title)
                            .font(.bighelp(.callout).weight(.semibold))
                            .foregroundStyle(isSelected ? theme.actionForeground : theme.primaryText)
                            .padding(.horizontal, BighelpTokens.space16)
                            .frame(minHeight: 36)
                            .background(Capsule().fill(isSelected ? theme.action : theme.incomingMessageBackground))
                            .frame(minHeight: BighelpTokens.hitTarget)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("avatar.creator.style.\(style.rawValue)")
                }
            }
            .padding(.horizontal, BighelpTokens.space20)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var hermesStage: some View {
        switch model.style {
        case .face:
            HermesBlobFaceView(seed: model.blobShape.seed(name: faceName), kind: model.blobShape.kind,
                               color: model.faceColor)
        case .shapes:
            HermesShapeFaceView(shape: model.shape, color: HermesShapeFace.color(model.shapeColor, name: faceName))
        case .pets:
            if let frame = model.selectedPetFrame, let image = UIImage(data: frame) {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
            } else if model.isLoadingPet {
                ProgressView()
            } else {
                stagePlaceholder("pawprint", "Pick a pet below")
            }
        case .photo, .characters:
            stagePlaceholder("photo.on.rectangle", "Choose a photo below")
        }
    }

    private func stagePlaceholder(_ systemImage: String, _ text: String) -> some View {
        VStack(spacing: BighelpTokens.space8) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Text(text)
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var facePanel: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            section("Shape") {
                grid(minimum: 76) {
                    ForEach([HermesBlobFace.Kind?.none] + HermesBlobFace.Kind.allCases.map(Optional.some), id: \.self) { kind in
                        tile(
                            title: kind?.displayName ?? "Auto",
                            isSelected: model.blobShape.kind == kind,
                            identifier: "avatar.creator.face.\(kind?.rawValue ?? "auto")"
                        ) {
                            withAnimation(.snappy) { model.blobShape.kind = kind }
                        } preview: {
                            HermesBlobFaceView(seed: model.blobShape.seed(name: faceName), kind: kind,
                                               color: model.faceColor)
                        }
                    }
                }
            }
            HStack(spacing: BighelpTokens.space8) {
                pill(model.blobShape.isLocked ? "Unlock" : "Lock face",
                     systemImage: model.blobShape.isLocked ? "lock.open" : "lock",
                     identifier: "avatar.creator.face.lock") {
                    model.toggleFaceLock(name: faceName)
                }
                pill("Randomize", systemImage: "dice", identifier: "avatar.creator.face.randomize") {
                    withAnimation(.snappy) { model.randomizeFace() }
                }
            }
            Text(model.blobShape.isLocked
                 ? "Face locked. It stays the same even if the name changes."
                 : "The face comes from the agent’s name. Hermes Desktop shows the same face.")
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            colorSection(selection: Binding(get: { model.faceColor }, set: { model.faceColor = $0 }),
                         nameColor: HermesBlobFace.render(seed: model.blobShape.seed(name: faceName),
                                                          kind: model.blobShape.kind).head,
                         identifier: "avatar.creator.face-color")
        }
    }

    /// "Match the name", Hermes Desktop's twelve swatches, any color from the wheel, and how
    /// colorful it is (down to gray), for faces and shapes alike.
    private func colorSection(selection: Binding<String?>, nameColor: String, identifier: String) -> some View {
        section("Color") {
            let matchesName = selection.wrappedValue == nil
            Button {
                selection.wrappedValue = nil
            } label: {
                Label {
                    Text("Match the name")
                } icon: {
                    Circle()
                        .fill(HermesFaceColor.color(nameColor))
                        .frame(width: 18, height: 18)
                }
                .font(.bighelp(.callout).weight(.semibold))
                .foregroundStyle(matchesName ? theme.actionForeground : theme.primaryText)
                .padding(.horizontal, BighelpTokens.space16)
                .frame(minHeight: 36)
                .background(Capsule().fill(matchesName ? theme.action : theme.incomingMessageBackground))
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(matchesName ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("\(identifier).name")
            // Hermes Desktop's twelve swatches, two even rows.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BighelpTokens.space12), count: 6),
                      spacing: BighelpTokens.space12) {
                ForEach(Array(HermesShapeFace.swatches.enumerated()), id: \.element) { index, color in
                    swatch(
                        fill: AnyShapeStyle(HermesFaceColor.color(color)),
                        isSelected: selection.wrappedValue == color,
                        label: "Color \(index + 1)",
                        identifier: "\(identifier).\(index)"
                    ) { selection.wrappedValue = color } overlay: { EmptyView() }
                }
            }
            let current = selection.wrappedValue ?? nameColor
            HStack(spacing: BighelpTokens.space12) {
                ColorPicker(selection: Binding(
                    get: { HermesFaceColor.color(current) },
                    set: { color in
                        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
                        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: nil) else { return }
                        selection.wrappedValue = CompanionColor.hex(red: red, green: green, blue: blue)
                    }), supportsOpacity: false) {
                    Text("Custom color")
                        .font(.bighelp(.callout).weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                }
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("\(identifier).custom")
            }
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                HStack {
                    Text("Saturation")
                        .font(.bighelp(.callout).weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Text(AvatarColorAdjust.saturation(of: current) < 0.02 ? "Grayscale" : "\(Int((AvatarColorAdjust.saturation(of: current) * 100).rounded()))%")
                        .font(.bighelp(.footnote).monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                }
                HStack(spacing: BighelpTokens.space8) {
                    Circle().fill(HermesFaceColor.color(AvatarColorAdjust.color(current, saturation: 0)))
                        .frame(width: 14, height: 14).accessibilityHidden(true)
                    Slider(value: Binding(
                        get: { AvatarColorAdjust.saturation(of: current) },
                        set: { selection.wrappedValue = AvatarColorAdjust.color(current, saturation: $0) }
                    ), in: 0...1)
                    .tint(HermesFaceColor.color(current))
                    .accessibilityLabel("Saturation")
                    .accessibilityIdentifier("\(identifier).saturation")
                    Circle().fill(HermesFaceColor.color(AvatarColorAdjust.color(current, saturation: 1)))
                        .frame(width: 14, height: 14).accessibilityHidden(true)
                }
            }
        }
    }

    private var shapesPanel: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            section("Shape") {
                grid(minimum: 76) {
                    ForEach(HermesShapeFace.pickerShapes, id: \.self) { shape in
                        tile(
                            title: HermesShapeFace.displayName(shape),
                            isSelected: model.shape == shape,
                            identifier: "avatar.creator.shape.\(shape)"
                        ) {
                            withAnimation(.snappy) { model.shape = shape }
                        } preview: {
                            HermesShapeFaceView(shape: shape, color: HermesShapeFace.color(model.shapeColor, name: faceName))
                        }
                    }
                }
            }
            colorSection(selection: Binding(get: { model.shapeColor }, set: { model.shapeColor = $0 }),
                         nameColor: HermesShapeFace.color(nil, name: faceName),
                         identifier: "avatar.creator.shape-color")
        }
    }

    private var petsPanel: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack(spacing: BighelpTokens.space8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.secondaryText)
                TextField("Search", text: $pets.query,
                          prompt: Text(pets.pets.isEmpty ? "Search pets" : "Search \(pets.pets.count) pets").bighelpFieldHint(theme))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isSearchingPets)
                    .accessibilityIdentifier("avatar.creator.pets.search")
            }
            .padding(.horizontal, BighelpTokens.space12)
            .frame(minHeight: BighelpTokens.hitTarget)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            if let error = model.petError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.danger)
            }
            petsContent
        }
        .task { await pets.loadIfNeeded() }
        .animation(.snappy, value: isSearchingPets)
    }

    @ViewBuilder
    private var petsContent: some View {
        switch pets.phase {
        case .idle, .loading:
            ProgressView("Loading pets")
                .frame(maxWidth: .infinity, minHeight: 160)
                .accessibilityIdentifier("avatar.creator.pets.loading")
        case .failed:
            VStack(spacing: BighelpTokens.space8) {
                Text("Couldn’t load the pet gallery.")
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                Button("Try again") { Task { await pets.loadIfNeeded() } }
                    .font(.bighelp(.body).weight(.semibold))
                    .frame(minHeight: BighelpTokens.hitTarget)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        case .loaded:
            let matches = pets.matches
            if matches.isEmpty {
                Text("No pets match.")
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                grid(minimum: 76) {
                    ForEach(pets.visible) { pet in
                        tile(
                            title: pet.displayName,
                            isSelected: model.selectedPet == pet,
                            identifier: "avatar.creator.pet.\(pet.slug)"
                        ) {
                            isSearchingPets = false
                            Task { await model.select(pet, gallery: pets) }
                        } preview: {
                            PetdexThumbnailView(pet: pet, gallery: pets)
                        }
                        .onAppear { pets.reached(pet) }
                    }
                }
                Text(pets.isFromPetdex
                     ? "Showing \(pets.visible.count) of \(matches.count) pets from petdex.dev"
                     : "Showing \(pets.visible.count) of \(matches.count) pets")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("avatar.creator.pets.count")
            }
        }
    }

    private var photoPanel: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Text("Use any picture you like.")
                .font(.bighelp(.body))
                .foregroundStyle(theme.secondaryText)
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Upload a photo", systemImage: "photo")
                    .font(.bighelp(.body).weight(.semibold))
                    .foregroundStyle(theme.actionForeground)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                    .background(Capsule().fill(theme.action))
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("avatar.creator.photo")
        }
    }

    private func pill(_ title: String, systemImage: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.bighelp(.callout).weight(.semibold))
                .foregroundStyle(theme.action)
                .padding(.horizontal, BighelpTokens.space16)
                .frame(minHeight: BighelpTokens.hitTarget)
                .background(Capsule().fill(theme.incomingMessageBackground))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Building blocks

    private func preview(_ change: (inout CompanionAppearance) -> Void) -> CompanionAppearance {
        var look = model.appearance
        look.vibe = nil
        change(&look)
        return look
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            AgentStudioCaption(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid<Content: View>(minimum: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: BighelpTokens.space12)],
                  spacing: BighelpTokens.space12) {
            content()
        }
    }

    private func tile<Preview: View>(
        title: String,
        isSelected: Bool,
        identifier: String,
        action: @escaping () -> Void,
        @ViewBuilder preview: () -> Preview
    ) -> some View {
        Button(action: action) {
            VStack(spacing: BighelpTokens.space4) {
                preview()
                    .frame(width: 58, height: 58)
                    .allowsHitTesting(false)
                Text(title)
                    .font(.bighelp(.caption).weight(.semibold))
                    .foregroundStyle(isSelected ? theme.action : theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BighelpTokens.space8)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(isSelected ? theme.action : theme.border, lineWidth: isSelected ? 2.5 : 1)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }

    private func swatch<Overlay: View>(
        fill: AnyShapeStyle,
        isSelected: Bool,
        label: String,
        identifier: String,
        action: @escaping () -> Void,
        @ViewBuilder overlay: () -> Overlay
    ) -> some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .overlay(Circle().strokeBorder(theme.border, lineWidth: 1))
                .overlay(overlay())
                .frame(width: 40, height: 40)
                .padding(3)
                .overlay(Circle().strokeBorder(isSelected ? theme.action : Color.clear, lineWidth: 2.5))
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }

    @BighelpThemeReader private var theme
}

#if os(visionOS)
/// Lays views out left to right, starting a new row when one is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = self.rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            // Each row is centered, like the stage above it.
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
#endif

/// One pet's first frame, fetched when its tile shows and kept pixel-sharp.
private struct PetdexThumbnailView: View {
    let pet: PetdexPet
    let gallery: PetdexGalleryModel
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.incomingMessageBackground)
                    .overlay {
                        if failed {
                            Image(systemName: "pawprint").foregroundStyle(theme.secondaryText)
                        }
                    }
            }
        }
        .task(id: pet.id) {
            if let cached = gallery.cachedThumbnail(pet) { image = UIImage(data: cached); return }
            let data = await gallery.thumbnail(pet)
            guard !Task.isCancelled else { return }
            image = data.flatMap(UIImage.init(data:))
            failed = image == nil
        }
    }

    @BighelpThemeReader private var theme
}

/// How colorful a face or shape color is: 0 is gray at the same brightness, 1 fully vivid.
enum AvatarColorAdjust {
    static func saturation(of css: String) -> Double {
        hsb(css)?.saturation ?? 0
    }

    /// The color with that saturation, as hex; the hue and brightness stay.
    static func color(_ css: String, saturation: Double) -> String {
        guard let hsb = hsb(css) else { return css }
        let color = UIColor(hue: hsb.hue, saturation: min(max(saturation, 0), 1), brightness: hsb.brightness, alpha: 1)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        return CompanionColor.hex(red: red, green: green, blue: blue)
    }

    private static func hsb(_ css: String) -> (hue: Double, saturation: Double, brightness: Double)? {
        guard let rgb = HermesCSSColor.rgb(css) else { return nil }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return (hue, saturation, brightness)
    }
}
