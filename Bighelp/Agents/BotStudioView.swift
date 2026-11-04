import SwiftUI

/// Bot Studio: one editor for every avatar. The avatar fills the top of the screen and plays its
/// move; a drawer below shows one row of choices at a time (Body, Eyes, Color, Shape, Moves), so a
/// choice never pushes the others off screen. Every body in the catalog takes every choice.
struct BotStudioView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case body, eyes, color, shape, moves

        var id: String { rawValue }

        var title: String {
            switch self {
            case .body: "Body"
            case .eyes: "Eyes"
            case .color: "Color"
            case .shape: "Shape"
            case .moves: "Moves"
            }
        }

        var symbol: String {
            switch self {
            case .body: "circle.dashed"
            case .eyes: "eye"
            case .color: "paintpalette"
            case .shape: "slider.horizontal.3"
            case .moves: "figure.wave"
            }
        }
    }

    let agentName: String
    let saveTitle: String
    let onBack: (() -> Void)?
    let onSave: (BotLook) -> Void

    @State private var look: BotLook
    @State private var history: [BotLook] = []
    @State private var tab = Tab.body
    /// The set the Body row shows; nil shows every set.
    @State private var setID: String?
    /// A state being tried on the stage; nil plays the move.
    @State private var trying: AvatarPlayState?
    @State private var tryTask: Task<Void, Never>?
    @State private var customColor = Color.blue
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme
    private let library = BotBodyLibrary.shared

    init(start: BotLook, agentName: String, saveTitle: String = "Save", onBack: (() -> Void)? = nil,
         onSave: @escaping (BotLook) -> Void) {
        _look = State(initialValue: start)
        self.agentName = agentName
        self.saveTitle = saveTitle
        self.onBack = onBack
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stage
                drawer
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Bot Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if let onBack {
                        Button("Back", systemImage: "chevron.left", action: onBack)
                            .accessibilityIdentifier("bot.studio.back")
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle) { onSave(look) }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("bot.studio.save")
                }
            }
        }
        .task { await library.refreshIfNeeded() }
        .onDisappear { tryTask?.cancel() }
    }

    // MARK: Stage

    private var stage: some View {
        VStack(spacing: BighelpTokens.space8) {
            Spacer(minLength: BighelpTokens.space8)
            BotLookPlayer(look: look, state: trying ?? .idle)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 260, maxHeight: 260)
                .accessibilityElement()
                .accessibilityLabel("\(agentName)'s avatar: \(look.body.name)")
                .accessibilityIdentifier("bot.studio.stage")
            Text(agentName)
                .bighelpFont(.sectionTitle, weight: .bold)
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
            Spacer(minLength: BighelpTokens.space8)
            HStack {
                Button {
                    guard let previous = history.popLast() else { return }
                    look = previous
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.bighelp(.body).weight(.semibold))
                        .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        .background(theme.surface, in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.primaryText)
                .disabled(history.isEmpty)
                .opacity(history.isEmpty ? 0.4 : 1)
                .accessibilityLabel("Undo")
                .accessibilityIdentifier("bot.studio.undo")
                Spacer()
                Button {
                    let bodies = library.catalog.available(at: .now).flatMap(\.bodies)
                    guard var surprise = BotLook.surprise(from: bodies) else { return }
                    // A move the person picked stays; Surprise me never adds one.
                    surprise.move = look.move
                    change { $0 = surprise }
                } label: {
                    Label("Surprise me", systemImage: "dice")
                        .bighelpFont(.label, weight: .semibold)
                        .padding(.horizontal, BighelpTokens.space16)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .background(theme.surface, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.primaryText)
                .accessibilityIdentifier("bot.studio.surprise")
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.bottom, BighelpTokens.space12)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Drawer

    private var drawer: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack(alignment: .firstTextBaseline) {
                Text(tab.title)
                    .bighelpFont(.label, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Text(summary)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, BighelpTokens.space20)
            Group {
                switch tab {
                case .body: bodyRow
                case .eyes: eyesRow
                case .color: colorRow
                case .shape: shapeRow
                case .moves: movesRow
                }
            }
            .frame(minHeight: 150, alignment: .top)
            rail
        }
        .padding(.top, BighelpTokens.space16)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                .fill(theme.raisedSurface)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var summary: String {
        switch tab {
        case .body: look.body.name
        case .eyes: look.eyes.title
        case .color: look.cheeks ? "Cheeks on" : ""
        case .shape: ""
        case .moves: look.move.title
        }
    }

    private var rail: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { item in
                let isSelected = item == tab
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .font(.bighelp(.body).weight(isSelected ? .semibold : .regular))
                        Text(item.title)
                            .bighelpFont(.metadata, weight: isSelected ? .semibold : .regular)
                    }
                    .foregroundStyle(isSelected ? theme.primaryText : theme.tertiaryText)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("bot.studio.tab.\(item.rawValue)")
            }
        }
        .padding(.horizontal, BighelpTokens.space8)
        .overlay(alignment: .top) { theme.separator.frame(height: 1) }
    }

    // MARK: Body

    private var bodyRow: some View {
        let sets = library.catalog.available(at: .now)
        let shown = sets.filter { setID == nil || $0.set.id == setID }.flatMap(\.bodies)
        return VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            chips([("", "All")] + sets.map { ($0.set.id, $0.set.name) },
                  selected: setID ?? "") { setID = $0.isEmpty ? nil : $0 }
            tiles(shown, id: \.id) { body in
                // Each body as it comes, which is what picking it gives.
                (body.id == look.body.id ? look : BotLook(body: body), body.id == look.body.id, body.name)
            } pick: { body in
                guard body.id != look.body.id else { return }
                change { $0.use(body) }
            }
        }
    }

    // MARK: Eyes

    private var eyesRow: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            tiles(BotLook.Eyes.allCases, id: \.self) { eyes in
                var preview = look
                preview.eyes = eyes
                return (preview, eyes == look.eyes, eyes.title)
            } pick: { eyes in
                change { $0.eyes = eyes }
            }
            chips(BotLook.Mouth.allCases.map { ($0.rawValue, $0 == .none ? "No mouth" : $0.title) },
                  selected: look.mouth.rawValue) { raw in
                change { $0.mouth = BotLook.Mouth(rawValue: raw) ?? .none }
            }
            slider("Size", value: \.eyeSize, in: BotLook.eyeSizes, id: "eye-size")
        }
    }

    // MARK: Color

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            tiles(BotLook.colorways, id: \.name) { way in
                var preview = look
                preview.main = way.main
                preview.accent = way.accent
                preview.eyeColor = way.eyes
                return (preview, look.main == way.main && look.accent == way.accent, way.name)
            } pick: { way in
                change { $0.main = way.main; $0.accent = way.accent; $0.eyeColor = way.eyes }
            }
            swatches(BotLook.palette, selected: look.main, label: "Main color", id: "main") { hex in
                change { $0.main = hex }
            } custom: { hex in
                change { $0.main = hex }
            }
            if look.body.hasAccent {
                swatches(BotLook.palette, selected: look.accentColor, label: "Second color", id: "accent") { hex in
                    change { $0.accent = hex }
                } custom: { hex in
                    change { $0.accent = hex }
                }
            }
            toggle("Cheeks", isOn: \.cheeks, id: "cheeks")
        }
    }

    // MARK: Shape

    private var shapeRow: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            slider("Tilt", value: \.tilt, in: BotLook.tilts, id: "tilt")
            slider("Lean", value: \.lean, in: BotLook.leans, id: "lean")
            slider("Taller or wider", value: \.stretch, in: BotLook.stretches, id: "stretch")
            slider("Size", value: \.scale, in: BotLook.scales, id: "scale")
            HStack {
                toggle("Mirror", isOn: \.mirror, id: "mirror")
                Button("Reset") {
                    change { $0.tilt = 0; $0.lean = 0; $0.stretch = 0; $0.scale = 1; $0.mirror = false }
                }
                .bighelpFont(.label)
                .foregroundStyle(theme.action)
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("bot.studio.shape.reset")
            }
            .padding(.horizontal, BighelpTokens.space20)
        }
    }

    // MARK: Moves

    private var movesRow: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            chips(BotLook.Move.allCases.map { ($0.rawValue, $0.title) }, selected: look.move.rawValue) { raw in
                change { $0.move = BotLook.Move(rawValue: raw) ?? .calm }
                trying = nil
            }
            Text("Try how it looks while your agent works")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, BighelpTokens.space20)
            let states: [(AvatarPlayState, String)] = [(.think, "Thinking"), (.speak, "Talking"), (.listen, "Listening"),
                                                       (.love, "Happy"), (.sleep, "Sleepy"), (.oops, "Oops")]
            chips(states.map { ($0.0.rawValue, $0.1) }, selected: trying?.rawValue ?? "") { raw in
                tryState(AvatarPlayState(rawValue: raw))
            }
        }
    }

    private func tryState(_ state: AvatarPlayState?) {
        tryTask?.cancel()
        trying = state
        tryTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            trying = nil
        }
    }

    // MARK: Parts

    /// One edit, which Undo can take back.
    private func change(_ edit: (inout BotLook) -> Void) {
        var next = look
        edit(&next)
        guard next != look else { return }
        history.append(look)
        if history.count > 50 { history.removeFirst() }
        look = next
    }

    private func tiles<Item, ID: Hashable>(
        _ items: [Item], id: KeyPath<Item, ID>, preview: @escaping (Item) -> (BotLook, Bool, String),
        pick: @escaping (Item) -> Void
    ) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: BighelpTokens.space12) {
                ForEach(items, id: id) { item in
                    let (shown, isSelected, name) = preview(item)
                    Button { pick(item) } label: {
                        VStack(spacing: BighelpTokens.space4) {
                            BotLookView(look: shown)
                                .frame(width: 60, height: 60)
                                .frame(width: 78, height: 78)
                                .background(theme.surface, in: .rect(cornerRadius: 20))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 20)
                                        .strokeBorder(isSelected ? theme.primaryText : .clear, lineWidth: 2)
                                }
                            Text(name)
                                .bighelpFont(.metadata)
                                .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
                                .lineLimit(1)
                                .frame(width: 78)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("bot.studio.choice.\(name)")
                }
            }
            .padding(.horizontal, BighelpTokens.space16)
        }
        .scrollIndicators(.hidden)
        // As tall as its row: a horizontal scroll view otherwise takes the drawer's spare height.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chips(_ items: [(String, String)], selected: String, pick: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: BighelpTokens.space8) {
                ForEach(items, id: \.0) { id, title in
                    let isSelected = id == selected
                    Button { pick(id) } label: {
                        Text(title)
                            .bighelpFont(.label, weight: isSelected ? .semibold : .regular)
                            .foregroundStyle(isSelected ? theme.actionForeground : theme.primaryText)
                            .padding(.horizontal, BighelpTokens.space16)
                            .frame(minHeight: 36)
                            .background(Capsule().fill(isSelected ? theme.action : theme.surface))
                            .frame(minHeight: BighelpTokens.hitTarget)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("bot.studio.chip.\(id.isEmpty ? "all" : id)")
                }
            }
            .padding(.horizontal, BighelpTokens.space16)
        }
        .scrollIndicators(.hidden)
        // As tall as its row: a horizontal scroll view otherwise takes the drawer's spare height.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func swatches(_ colors: [String], selected: String, label: String, id: String,
                          pick: @escaping (String) -> Void, custom: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: BighelpTokens.space8) {
                ForEach(colors, id: \.self) { hex in
                    let isSelected = hex == selected
                    Button { pick(hex) } label: {
                        Circle()
                            .fill(HermesFaceColor.color(hex))
                            .overlay { Circle().strokeBorder(theme.border, lineWidth: 1) }
                            .padding(3)
                            .overlay { Circle().strokeBorder(isSelected ? theme.primaryText : .clear, lineWidth: 2.5) }
                            .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(label) \(hex)")
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
                ColorPicker(selection: Binding(get: { HermesFaceColor.color(selected) }, set: { color in
                    if let hex = Self.hex(color) { custom(hex) }
                }), supportsOpacity: false) { EmptyView() }
                    .labelsHidden()
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .accessibilityLabel("Custom \(label.lowercased())")
                    .accessibilityIdentifier("bot.studio.custom.\(id)")
            }
            .padding(.horizontal, BighelpTokens.space16)
        }
        .scrollIndicators(.hidden)
        // As tall as its row: a horizontal scroll view otherwise takes the drawer's spare height.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(label)
    }

    private func slider(_ title: String, value: WritableKeyPath<BotLook, Double>, in range: ClosedRange<Double>,
                        id: String) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            Text(title)
                .bighelpFont(.label)
                .foregroundStyle(theme.primaryText)
                .frame(minWidth: 96, alignment: .leading)
            Slider(value: Binding(get: { look[keyPath: value] }, set: { look[keyPath: value] = $0 }), in: range) { editing in
                // One Undo step for each drag.
                if editing { history.append(look) }
            }
            .tint(theme.action)
            .accessibilityLabel(title)
            .accessibilityIdentifier("bot.studio.slider.\(id)")
        }
        .frame(minHeight: BighelpTokens.hitTarget)
        .padding(.horizontal, BighelpTokens.space20)
    }

    private func toggle(_ title: String, isOn value: WritableKeyPath<BotLook, Bool>, id: String) -> some View {
        Toggle(title, isOn: Binding(get: { look[keyPath: value] }, set: { new in change { $0[keyPath: value] = new } }))
            .bighelpFont(.label)
            .foregroundStyle(theme.primaryText)
            .frame(minHeight: BighelpTokens.hitTarget)
            .padding(.horizontal, id == "mirror" ? 0 : BighelpTokens.space20)
            .accessibilityIdentifier("bot.studio.toggle.\(id)")
    }

    private static func hex(_ color: Color) -> String? {
        let resolved = UIColor(color)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

extension BotLook {
    /// Where Bot Studio opens: the agent's Bot Studio avatar, else the body nearest its old avatar in
    /// that avatar's color, else something new.
    @MainActor
    static func studioStart(for start: AvatarCreatorStart, library: BotBodyLibrary = .shared) -> BotLook {
        if case .look(let look) = start, let studio = look.studio { return studio }
        let catalog = library.catalog
        let bodies = catalog.available(at: .now).flatMap(\.bodies)
        if let id = catalogBodyID(for: start, in: catalog) ?? bodyID(for: start), let body = catalog.body(id: id) {
            var look = BotLook(body: body)
            if let color = color(for: start) { look.main = color }
            return look
        }
        if let surprise = surprise(from: bodies) { return surprise }
        return BotLook(body: catalog.bodies.first ?? BotLook.fallbackBody)
    }

    /// A catalog character (`bighelp-biggie`) is redrawn as the body of the same set and name
    /// (`bighelp.biggie`).
    private static func catalogBodyID(for start: AvatarCreatorStart, in catalog: BotBodyCatalog) -> String? {
        guard case .character(let appearance) = start, let id = appearance.catalogAvatar?.id else { return nil }
        return catalog.sets.lazy.compactMap { set in
            id.hasPrefix(set.id + "-") ? set.id + "." + id.dropFirst(set.id.count + 1) : nil
        }.first
    }

    /// Drawn when the catalog can't be read at all.
    static let fallbackBody = BotBody(
        id: "shapes.ball", name: "Ball", set: "shapes",
        parts: [.init(d: "M18 52a32 32 0 1 0 64 0a32 32 0 1 0 -64 0Z")],
        eyes: [[54, 44, 12], [66, 46, 12]], eyeTilt: -24, rotation: 0, colors: .init(main: "#3B82F6", accent: nil))
}
