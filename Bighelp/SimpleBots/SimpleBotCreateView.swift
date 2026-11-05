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


/// Create New Bot's short lists from Bot Studio's catalog: a body from each set and eight colors.
/// Every other body, the eyes, the shape and the moves are in Bot Studio, a tap away.
enum SimpleBotQuickPicks {
    struct Swatch: Identifiable, Sendable {
        let key: String
        let hex: String
        let name: LocalizedStringResource
        var id: String { key }
    }

    static let bodyCount = 7

    static let palette = [
        Swatch(key: "red", hex: "#E5484D", name: "Red"), Swatch(key: "orange", hex: "#EF6F2E", name: "Orange"),
        Swatch(key: "yellow", hex: "#F2C94C", name: "Yellow"), Swatch(key: "green", hex: "#58C47A", name: "Green"),
        Swatch(key: "teal", hex: "#14B8A6", name: "Teal"), Swatch(key: "blue", hex: "#3B82F6", name: "Blue"),
        Swatch(key: "purple", hex: "#8B5CF6", name: "Purple"), Swatch(key: "pink", hex: "#E8459A", name: "Pink"),
    ]

    /// The first body of each set on offer. The bot's own body goes first when it isn't one of them
    /// (Surprise me and Bot Studio reach every body), so the pick always shows.
    static func bodies(in catalog: BotBodyCatalog, keeping current: BotBody?, at now: Date = .now) -> [BotBody] {
        let firsts = Array(catalog.available(at: now).compactMap(\.bodies.first).prefix(bodyCount))
        guard let current, !firsts.contains(where: { $0.id == current.id }) else { return firsts }
        return Array(([current] + firsts).prefix(bodyCount))
    }

    /// The body's own color, then seven from the palette (one more is there for a body whose own
    /// color is one of them).
    static func colors(for body: BotBody) -> [Swatch] {
        let own = Swatch(key: "own", hex: body.colors.main, name: "Its own color")
        return [own] + palette.filter { $0.hex != own.hex }.prefix(7)
    }
}

/// Create New Bot: the bot's face with Surprise me, its name, a body from each of Bot Studio's sets
/// and eight colors. More and Eyes, shape and moves open the full Bot Studio. The bot starts with
/// bighelp's everyday helper personality, or a template attached with Templates, and the default
/// bot's setup, like New agent; its look is saved on the computer, as Edit avatar saves one.
@MainActor
struct SimpleBotCreateView: View {
    let makeCreator: () -> AgentEditorModel?
    let onCreated: (AgentProfile) -> Void

    @State private var name = ""
    @State private var look: BotLook
    /// Bot Studio, open on this tab.
    @State private var studioTab: BotStudioView.Tab?
    @State private var isCreating = false
    @State private var errorMessage: String?
    /// Made when the screen opens, so a template can fill it in before Create.
    @State private var creator: AgentEditorModel?
    @State private var isPickingTemplate = false
    /// Picked in Templates; attached once that sheet has closed, since a template's form opens as a sheet of its own.
    @State private var pickedTemplate: AgentSoulTemplate?
    @State private var lastTemplate: AgentSoulTemplate?
    @FocusState private var isNameFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme
    private let library = BotBodyLibrary.shared

    init(makeCreator: @escaping () -> AgentEditorModel?, onCreated: @escaping (AgentProfile) -> Void) {
        self.makeCreator = makeCreator
        self.onCreated = onCreated
        // One of the bodies on show, as it comes.
        let bodies = SimpleBotQuickPicks.bodies(in: BotBodyLibrary.shared.catalog, keeping: nil)
        _look = State(initialValue: BotLook(body: bodies.randomElement() ?? BotLook.fallbackBody))
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The template filling this bot in, once it has.
    private var attachedTemplate: AgentSoulTemplate? {
        guard let creator, let id = SimpleBotCreation.attachedID(creator) else { return nil }
        return lastTemplate?.id == id ? lastTemplate : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: BighelpTokens.space12) {
                SimpleBotsCircleButton(systemImage: "xmark", label: "Close", identifier: "simple-bots.create.close") {
                    dismiss()
                }
                Text("Create New Bot")
                    .font(.bighelp(.title3, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: BighelpTokens.space8)
                if creator != nil {
                    SimpleBotTemplatesButton { isPickingTemplate = true }
                }
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.top, BighelpTokens.space16)
            if let attachedTemplate {
                SimpleBotTemplateChip(template: attachedTemplate) {
                    if let creator { SimpleBotCreation.detach(creator) }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, BighelpTokens.space16)
                .padding(.top, BighelpTokens.space8)
                .transition(.opacity)
            }

            ScrollView {
                VStack(spacing: BighelpTokens.space24) {
                    face
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
                    if let attachedTemplate {
                        // Its role as filled in, fields and all.
                        let role = creator?.draft.role.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        Text(role.isEmpty ? String(localized: "From \(attachedTemplate.title)")
                                           : String(localized: "From \(attachedTemplate.title): \(role)"))
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, -BighelpTokens.space12)
                            .accessibilityIdentifier("simple-bots.create.template-note")
                    }
                    bodies
                    colors
                    studioButton
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.danger)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, BighelpTokens.space16)
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
        .onAppear { if creator == nil { creator = makeCreator() } }
        .task { await library.refreshIfNeeded() }
        .bighelpSheet(isPresented: $isPickingTemplate, onDismiss: attachPickedTemplate) {
            AgentTemplateBrowser(title: String(localized: "Templates")) { pickedTemplate = $0 }
                .bighelpSheetSize(.large)
        }
        .bighelpSheet(item: $studioTab) { tab in
            BotStudioView(start: look, agentName: trimmedName.isEmpty ? String(localized: "Your new bot") : trimmedName,
                          saveTitle: String(localized: "Done"), tab: tab) { picked in
                look = picked
                studioTab = nil
            }
            .presentationDragIndicator(.visible)
            #if os(visionOS)
            .presentationSizing(.page)
            #endif
            .bighelpSheetSize(.large)
        }
        .agentTemplateForm(creator)
        .onChange(of: creator?.appliedTemplateID) { _, applied in
            // A template's form asks for the name too; what was typed there shows here.
            if applied != nil, let typed = creator?.draft.name, !typed.isEmpty { name = typed }
        }
    }

    private var face: some View {
        BotLookPlayer(look: look, state: .idle)
            .frame(width: 170, height: 170)
            .accessibilityElement()
            .accessibilityLabel(Text("Your bot's avatar: \(look.body.name)"))
            .accessibilityIdentifier("simple-bots.create.face")
            .overlay(alignment: .bottomTrailing) {
                SimpleBotsCircleButton(systemImage: "dice", label: "Surprise me",
                                       identifier: "simple-bots.create.surprise") {
                    let everyBody = library.catalog.available(at: .now).flatMap(\.bodies)
                    guard var surprise = BotLook.surprise(from: everyBody) else { return }
                    // A move picked in Bot Studio stays; Surprise me never adds one.
                    surprise.move = look.move
                    look = surprise
                }
                .offset(x: BighelpTokens.space8)
            }
            .padding(.top, BighelpTokens.space16)
    }

    /// A body from each set, each as it comes (what picking it gives), and More for the rest.
    private var bodies: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BighelpTokens.space8), count: 4),
                  spacing: BighelpTokens.space8) {
            ForEach(SimpleBotQuickPicks.bodies(in: library.catalog, keeping: look.body)) { option in
                let isSelected = option.id == look.body.id
                Button {
                    if !isSelected { look.use(option) }
                } label: {
                    BotLookView(look: isSelected ? look : BotLook(body: option))
                        .frame(width: 52, height: 52)
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)
                                .strokeBorder(isSelected ? theme.primaryText : .clear, lineWidth: 2)
                        }
                        .contentShape(.rect(cornerRadius: BighelpTokens.radius16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.name)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("simple-bots.create.body.\(option.id)")
            }
            Button { studioTab = .body } label: {
                Text("More")
                    .font(.bighelp(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16, style: .continuous))
                    .contentShape(.rect(cornerRadius: BighelpTokens.radius16))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Every body, in Bot Studio")
            .accessibilityIdentifier("simple-bots.create.more")
        }
    }

    /// One row of colors, or two on a narrow screen, so each keeps a full-size target.
    private var colors: some View {
        let swatches = SimpleBotQuickPicks.colors(for: look.body)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) { colorButtons(swatches) }
            VStack(spacing: BighelpTokens.space4) {
                HStack(spacing: 0) { colorButtons(Array(swatches.prefix(4))) }
                HStack(spacing: 0) { colorButtons(Array(swatches.dropFirst(4))) }
            }
        }
    }

    private func colorButtons(_ swatches: [SimpleBotQuickPicks.Swatch]) -> some View {
        ForEach(swatches) { swatch in
            let isSelected = look.main == swatch.hex
            Button { look.main = swatch.hex } label: {
                Circle()
                    .fill(HermesFaceColor.color(swatch.hex))
                    .overlay { Circle().strokeBorder(theme.border, lineWidth: 1) }
                    .padding(4)
                    .overlay { Circle().strokeBorder(isSelected ? theme.primaryText : .clear, lineWidth: 2.5) }
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(swatch.name))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("simple-bots.create.color.\(swatch.key)")
        }
    }

    private var studioButton: some View {
        Button { studioTab = .eyes } label: {
            HStack(spacing: BighelpTokens.space8) {
                Text("Eyes, shape and moves")
                    .font(.bighelp(.body, weight: .semibold))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote, weight: .semibold))
                    .foregroundStyle(theme.tertiaryText)
            }
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, BighelpTokens.space16)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16, style: .continuous))
            .contentShape(.rect(cornerRadius: BighelpTokens.radius16))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Bot Studio")
        .accessibilityIdentifier("simple-bots.create.studio")
    }

    private func attachPickedTemplate() {
        guard let template = pickedTemplate, let creator else { return }
        pickedTemplate = nil
        TemplateUsage.shared.recordUse(AgentTemplateBrowsing.usageID(template))
        lastTemplate = template
        SimpleBotCreation.attach(template, to: creator, name: name)
    }

    private func create() async {
        guard let model = creator ?? makeCreator() else {
            errorMessage = String(localized: "This computer can't make new bots.")
            return
        }
        creator = model
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        SimpleBotCreation.prepare(model, name: trimmedName)
        // Without its picture the bot is still made, with no avatar.
        try? await SimpleBotCreation.use(look, for: model)
        do {
            onCreated(try await model.save())
        } catch {
            errorMessage = model.saveError
                ?? String(localized: "The bot couldn't be made. Check the computer, then try again.")
        }
    }
}
