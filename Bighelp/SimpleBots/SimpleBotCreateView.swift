import SwiftUI

/// The shape grid and color dots. The pick has a gray ring around it.
struct SimpleBotMarkPicker: View {
    @Binding var mark: SimpleBotMark
    var shapeSize: CGFloat = 44
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(spacing: BighelpTokens.space24) {
            rows(SimpleBotShape.allCases, perRow: 5) { shape in
                Button { mark.shape = shape } label: {
                    SimpleBotShapeSwatch(shape: shape, color: mark.color, size: shapeSize)
                        .padding(5)
                        .overlay {
                            if mark.shape == shape {
                                SimpleBotShapeRing(shape: shape)
                                    .stroke(theme.tertiaryText, lineWidth: 3)
                            }
                        }
                        .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(shape.title)
                .accessibilityAddTraits(mark.shape == shape ? .isSelected : [])
                .accessibilityIdentifier("simple-bots.shape.\(shape.rawValue)")
            }
            rows(SimpleBotColor.allCases, perRow: 6) { color in
                Button { mark.color = color } label: {
                    Circle()
                        .fill(color.color)
                        .frame(width: shapeSize * 0.66, height: shapeSize * 0.66)
                        .overlay {
                            if color == .black { Circle().stroke(theme.tertiaryText.opacity(0.5), lineWidth: 1) }
                        }
                        .padding(5)
                        .overlay {
                            if mark.color == color { Circle().stroke(theme.tertiaryText, lineWidth: 3) }
                        }
                        .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.title)
                .accessibilityAddTraits(mark.color == color ? .isSelected : [])
                .accessibilityIdentifier("simple-bots.color.\(color.rawValue)")
            }
        }
    }

    /// Full rows, then the rest centered under them, each cell the same width.
    private func rows<Item: Identifiable, Cell: View>(_ items: [Item], perRow: Int,
                                                      @ViewBuilder cell: @escaping (Item) -> Cell) -> some View {
        let chunks = stride(from: 0, to: items.count, by: perRow).map { Array(items[$0..<min($0 + perRow, items.count)]) }
        let cellWidth = perRow > 5 ? shapeSize + 4 : shapeSize + 14
        return VStack(spacing: BighelpTokens.space12) {
            ForEach(chunks.indices, id: \.self) { index in
                HStack(spacing: perRow > 5 ? 6 : BighelpTokens.space8) {
                    ForEach(chunks[index]) { item in
                        cell(item).frame(width: cellWidth)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// A shape without eyes, for the picker.
private struct SimpleBotShapeSwatch: View {
    let shape: SimpleBotShape
    let color: SimpleBotColor
    let size: CGFloat

    var body: some View {
        SimpleBotShapeRing(shape: shape).fill(color.color).frame(width: size, height: size)
    }
}

private struct SimpleBotShapeRing: Shape {
    let shape: SimpleBotShape
    func path(in rect: CGRect) -> Path { shape.path(in: rect) }
}

/// Create New Bot: a big preview, its name, a shape and a color. The bot
/// starts with bighelp's everyday helper personality and the default bot's
/// setup, like New agent; its mark becomes its picture.
@MainActor
struct SimpleBotCreateView: View {
    let makeCreator: () -> AgentEditorModel?
    let onCreated: (AgentProfile) -> Void

    @State private var name = ""
    @State private var mark = SimpleBotMark(shape: SimpleBotShape.allCases.randomElement() ?? .hexagon,
                                            color: [.orange, .pink, .green, .blue, .purple, .teal].randomElement() ?? .orange)
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.companionAgentScope) private var scope
    @BighelpThemeReader private var theme

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: BighelpTokens.space12) {
                SimpleBotsCircleButton(systemImage: "xmark", label: "Close", identifier: "simple-bots.create.close") {
                    dismiss()
                }
                Text("Create New Bot")
                    .font(.bighelp(.title3, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.top, BighelpTokens.space16)

            ScrollView {
                VStack(spacing: BighelpTokens.space32) {
                    SimpleBotMarkView(mark: mark, size: 168)
                        .padding(.top, BighelpTokens.space24)
                        .animation(.snappy, value: mark)
                    TextField("Name your Bot", text: $name)
                        .font(.bighelp(.title2, weight: .medium))
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($isNameFocused)
                        .padding(.horizontal, BighelpTokens.space16)
                        .frame(minHeight: 60)
                        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius20, style: .continuous))
                        .accessibilityIdentifier("simple-bots.create.name")
                    SimpleBotMarkPicker(mark: $mark)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.danger)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, BighelpTokens.space20)
                .padding(.bottom, BighelpTokens.space24)
            }
            .dismissesKeyboardOnScroll(true)

            Button {
                Task { await create() }
            } label: {
                if isCreating { ProgressView().tint(theme.actionForeground) } else { Text("Create") }
            }
            .buttonStyle(SimpleBotsPrimaryButtonStyle())
            .disabled(trimmedName.isEmpty || isCreating)
            .padding(.horizontal, BighelpTokens.space32)
            .padding(.bottom, BighelpTokens.space12)
            .accessibilityIdentifier("simple-bots.create.submit")
        }
        .background(theme.canvas.ignoresSafeArea())
        .interactiveDismissDisabled(isCreating)
    }

    private func create() async {
        guard let model = makeCreator() else {
            errorMessage = "This computer can't make new bots."
            return
        }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        let template = AgentSoulTemplate.bundled.first { $0.id == "anchor" }
        model.draft.name = trimmedName
        model.draft.role = template?.profile ?? "Everyday helper"
        model.draft.summary = template?.about ?? "Warm, direct, adaptable."
        model.draft.instructions = template?.soul
            ?? "You are {{agent_name}}, a friendly helper. Keep answers short and clear, and ask before doing anything that can't be undone."
        if let picture = SimpleBotMarkView.png(mark) { try? await model.importLookAvatar(data: picture, look: .photo) }
        do {
            let profile = try await model.save()
            SimpleBotMarkStore.shared.set(mark, scope: scope, agentID: profile.id)
            onCreated(profile)
        } catch {
            errorMessage = model.saveError ?? "The bot couldn't be made. Check the computer, then try again."
        }
    }
}
