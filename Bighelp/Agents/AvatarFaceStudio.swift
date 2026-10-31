import SwiftUI

/// The face designer's tools. They switch what the panel under the play strip shows;
/// they are the designer's own picker, never a second copy of the app's tab bar.
enum AvatarFaceTool: String, CaseIterable, Identifiable {
    case sets, shape, size, colors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sets: "Sets"
        case .shape: "Shape"
        case .size: "Size"
        case .colors: "Colors"
        }
    }

    var systemImage: String {
        switch self {
        case .sets: "square.grid.2x2"
        case .shape: "seal"
        case .size: "arrow.up.left.and.arrow.down.right"
        case .colors: "paintpalette"
        }
    }
}

/// A segmented switcher inside the designer: a row along the sheet's bottom on a
/// phone, a rail beside the panel where there's room (iPad, the Mac, Vision Pro).
struct AvatarFaceToolPicker: View {
    @Binding var selection: AvatarFaceTool
    var isRail = false
    @ScaledMetric(relativeTo: .caption2) private var railWidth: CGFloat = 78
    @BighelpThemeReader private var theme

    var body: some View {
        let layout = isRail ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        layout {
            ForEach(AvatarFaceTool.allCases) { tool in
                let isSelected = selection == tool
                Button {
                    withAnimation(.snappy) { selection = tool }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tool.systemImage)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(height: 22)
                        Text(tool.title)
                            .font(.bighelp(.caption2).weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(isSelected ? theme.actionForeground : theme.secondaryText)
                    .padding(.vertical, BighelpTokens.space4)
                    .frame(maxWidth: isRail ? railWidth : .infinity, minHeight: max(52, BighelpTokens.hitTarget))
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.action)
                        }
                    }
                    .contentShape(.rect)
                }
                .bighelpPlainButtonStyle()
                .accessibilityLabel(tool.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("avatar.creator.face.tool.\(tool.rawValue)")
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.incomingMessageBackground))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Face tools")
        .accessibilityIdentifier("avatar.creator.face.tools")
    }
}

/// Every state the agent shows, each a small copy of the face being edited.
/// Only the big face loops; these rest in a pose of their state and play it
/// once when they first show and each time they're tapped.
struct AvatarPlayStrip: View {
    let seed: String
    let kind: HermesBlobFace.Kind?
    let edits: HermesBlobEdits?
    let color: String?
    @Binding var selection: AvatarPlayState
    @State private var plays: [AvatarPlayState: Int] = [:]
    @ScaledMetric(relativeTo: .caption2) private var cellWidth: CGFloat = 50
    @ScaledMetric(relativeTo: .caption2) private var faceSize: CGFloat = 32
    @BighelpThemeReader private var theme

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: cellWidth), spacing: 6)], spacing: 6) {
            ForEach(AvatarPlayState.allCases) { state in
                let isSelected = selection == state
                Button {
                    withAnimation(.snappy) { selection = state }
                    plays[state, default: 0] += 1
                } label: {
                    VStack(spacing: 1) {
                        HermesBlobFacePlayer(seed: seed, kind: kind, edits: edits, color: color, state: state,
                                             playback: .once(trigger: plays[state] ?? 0))
                            .frame(width: faceSize, height: faceSize)
                        Text(state.title)
                            .font(.bighelp(.caption2).weight(.semibold))
                            .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.vertical, BighelpTokens.space4)
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isSelected ? theme.canvas : theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? theme.primaryText : Color.clear, lineWidth: 2))
                    .contentShape(.rect)
                }
                .bighelpPlainButtonStyle()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(state.title)
                .accessibilityHint("Plays it on the big face. Only a preview; nothing is saved.")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("avatar.creator.face.play.\(state.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Try a state")
        .accessibilityIdentifier("avatar.creator.face.play")
    }
}

// MARK: Tools

/// Sets: finished faces, one tap each.
struct AvatarFaceSetsPanel: View {
    let model: AvatarCreatorModel
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            ForEach(AvatarFacePresetSet.all) { set in
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    AgentStudioCaption(set.title)
                    AvatarStudioGrid(minimum: 76) {
                        ForEach(set.presets) { preset in
                            AvatarStudioTile(
                                title: preset.name,
                                isSelected: model.blobShape == preset.shape && model.faceColor == nil,
                                identifier: "avatar.creator.face.preset.\(preset.shape.seedPart)"
                            ) {
                                withAnimation(.snappy) { model.apply(preset) }
                            } preview: {
                                HermesBlobFaceView(seed: preset.shape.seedPart, kind: preset.shape.kind,
                                                   edits: preset.shape.edits)
                            }
                        }
                    }
                }
            }
            Text("A set face keeps its own look, so Hermes Desktop shows the same face.")
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shape's outline controls, under the silhouettes: bumps, wobble and mirror.
struct AvatarBlobOutlineControls: View {
    let model: AvatarCreatorModel
    let seed: String
    @State private var isDragging = false
    @BighelpThemeReader private var theme

    var body: some View {
        let silhouette = HermesBlobFace.silhouette(seed: seed, kind: model.blobShape.kind)
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            AgentStudioCaption("Outline")
            if HermesBlobFace.hasWobblyOutline(silhouette) {
                Stepper(value: Binding(
                    get: { model.blobShape.bumps(seed: seed) },
                    set: { count in model.editFace { shape, _ in shape.setBumps(count, seed: seed) } }
                ), in: 6...8) {
                    labeled("Bumps", value: "\(model.blobShape.bumps(seed: seed))")
                }
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("avatar.creator.face.bumps")
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    labeled("Wobble", value: wobbleName(model.blobShape.wobble(seed: seed)))
                    Slider(value: Binding(
                        get: { model.blobShape.wobble(seed: seed) },
                        set: { strength in
                            // VoiceOver steps without a drag; each of those steps is its own Undo.
                            if !isDragging { model.recordFaceUndo() }
                            model.blobShape.setWobble(strength, seed: seed)
                        }
                    ), in: 0...1) {
                        Text("Wobble")
                    } minimumValueLabel: {
                        Text("Smooth").font(.bighelp(.caption)).foregroundStyle(theme.secondaryText)
                    } maximumValueLabel: {
                        Text("Wobbly").font(.bighelp(.caption)).foregroundStyle(theme.secondaryText)
                    } onEditingChanged: { editing in
                        // One Undo for the whole drag.
                        if editing { model.recordFaceUndo() }
                        isDragging = editing
                    }
                    .tint(theme.action)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityLabel("Wobble")
                    .accessibilityValue(wobbleName(model.blobShape.wobble(seed: seed)))
                    .accessibilityIdentifier("avatar.creator.face.wobble")
                }
                Toggle(isOn: Binding(
                    get: { model.blobShape.isMirrored(seed: seed) },
                    set: { isOn in model.editFace { shape, _ in shape.setMirrored(isOn, seed: seed) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mirror")
                            .font(.bighelp(.callout).weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                        Text("Left and right match.")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .tint(theme.action)
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("avatar.creator.face.mirror")
            } else {
                Text("Bumps, wobble and mirror work on the Organic and Cloud shapes.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("avatar.creator.face.outline.unavailable")
            }
        }
    }

    private func labeled(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.bighelp(.callout).weight(.semibold))
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: BighelpTokens.space8)
            Text(value)
                .font(.bighelp(.footnote).monospacedDigit())
                .foregroundStyle(theme.secondaryText)
        }
    }

    private func wobbleName(_ strength: Double) -> String {
        switch strength {
        case ..<0.05: "None"
        case ..<0.35: "Soft"
        case ..<0.65: "Medium"
        default: "Strong"
        }
    }
}

/// Size: taller, wider, smaller and bigger, one step at a time.
struct AvatarBlobSizePanel: View {
    let model: AvatarCreatorModel
    let seed: String
    @BighelpThemeReader private var theme

    var body: some View {
        let shape = model.blobShape
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            AgentStudioCaption("Size")
            AvatarStudioGrid(minimum: 140) {
                step("Taller", systemImage: "arrow.up.and.down", identifier: "taller",
                     isEnabled: shape.canGrowTaller(seed: seed)) { $0.taller(seed: seed) }
                step("Wider", systemImage: "arrow.left.and.right", identifier: "wider",
                     isEnabled: shape.canGrowWider(seed: seed)) { $0.wider(seed: seed) }
                step("Smaller", systemImage: "arrow.down.right.and.arrow.up.left", identifier: "smaller",
                     isEnabled: shape.canShrink(seed: seed)) { $0.smaller(seed: seed) }
                step("Bigger", systemImage: "arrow.up.left.and.arrow.down.right", identifier: "bigger",
                     isEnabled: shape.canGrow(seed: seed)) { $0.bigger(seed: seed) }
            }
            if shape.edits?.ratio != nil || shape.edits?.size != nil {
                Button {
                    withAnimation(.snappy) {
                        model.editFace { shape, _ in
                            shape.edits?.ratio = nil
                            shape.edits?.size = nil
                            if shape.edits?.isEmpty == true { shape.edits = nil }
                        }
                    }
                } label: {
                    Label("Back to its own size", systemImage: "arrow.counterclockwise")
                        .font(.bighelp(.callout).weight(.semibold))
                        .foregroundStyle(theme.action)
                        .padding(.horizontal, BighelpTokens.space16)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .background(Capsule().fill(theme.incomingMessageBackground))
                        .contentShape(.capsule)
                }
                .bighelpPlainButtonStyle()
                .accessibilityIdentifier("avatar.creator.face.size.reset")
            }
        }
    }

    private func step(_ title: String, systemImage: String, identifier: String, isEnabled: Bool,
                      change: @escaping (inout HermesBlobShape) -> Void) -> some View {
        Button {
            withAnimation(.snappy) { model.editFace { shape, _ in change(&shape) } }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.bighelp(.callout).weight(.semibold))
                .foregroundStyle(isEnabled ? theme.primaryText : theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, BighelpTokens.space12)
                .padding(.vertical, BighelpTokens.space8)
                .frame(maxWidth: .infinity, minHeight: max(52, BighelpTokens.hitTarget))
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.surface))
                .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .disabled(!isEnabled)
        .accessibilityIdentifier("avatar.creator.face.size.\(identifier)")
    }
}

/// Colors: named palettes, each a swatch with the face's own shape on it.
struct AvatarFacePaletteGrid: View {
    let model: AvatarCreatorModel
    let seed: String

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            AgentStudioCaption("Palettes")
            AvatarStudioGrid(minimum: 72) {
                ForEach(AvatarFacePalette.all) { palette in
                    AvatarStudioTile(
                        title: palette.name,
                        isSelected: model.faceColor?.caseInsensitiveCompare(palette.hex) == .orderedSame,
                        identifier: "avatar.creator.face.palette.\(palette.id)",
                        previewSize: 44
                    ) {
                        withAnimation(.snappy) { model.editFace { _, color in color = palette.hex } }
                    } preview: {
                        HermesBlobFaceView(seed: seed, kind: model.blobShape.kind, edits: model.blobShape.edits,
                                           color: palette.hex)
                    }
                }
            }
        }
    }
}

// MARK: Building blocks

struct AvatarStudioGrid<Content: View>: View {
    let minimum: CGFloat
    @ViewBuilder let content: Content
    @ScaledMetric(relativeTo: .caption) private var scale: CGFloat = 1

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum * max(1, scale)), spacing: BighelpTokens.space12)],
                  spacing: BighelpTokens.space12) {
            content
        }
    }
}

/// A picture over its name, ringed when picked: the designer's tile.
struct AvatarStudioTile<Preview: View>: View {
    let title: String
    let isSelected: Bool
    let identifier: String
    var previewSize: CGFloat = 58
    let action: () -> Void
    @ViewBuilder let preview: Preview
    @BighelpThemeReader private var theme

    var body: some View {
        Button(action: action) {
            VStack(spacing: BighelpTokens.space4) {
                preview
                    .frame(width: previewSize, height: previewSize)
                    .allowsHitTesting(false)
                Text(title)
                    .font(.bighelp(.caption).weight(.semibold))
                    .foregroundStyle(isSelected ? theme.action : theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BighelpTokens.space8)
            .padding(.horizontal, BighelpTokens.space4)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(isSelected ? theme.action : theme.border, lineWidth: isSelected ? 2.5 : 1)
            )
            .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }
}
