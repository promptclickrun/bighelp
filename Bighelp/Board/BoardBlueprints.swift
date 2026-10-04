import SwiftUI

// MARK: - Catalog

/// A starter prompt for Feed, Ideas or Goals. Tapping one puts it in a new chat's message box to
/// edit (many have [placeholders]); nothing runs until the person sends it.
struct BoardBlueprint: Identifiable, Hashable, Sendable {
    let id: String
    let text: String
    /// Goals blueprints: the category the goal belongs in.
    let goalCategory: GoalCategory?
    /// Who shared it, for community blueprints from the catalog.
    var credit: String? = nil
    /// bighelp's own (bundled, or `source: bighelp` in the catalog) rather than a community one.
    var isOfficial = true
    /// When the catalog last changed it; nil for bundled ones.
    var updatedAt: Date? = nil
    /// Its group (productivity, marketing…), for the category filter.
    var category = ""
}

struct BoardBlueprintGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let blueprints: [BoardBlueprint]
}

/// The bundled blueprints, `Resources/BoardBlueprints.json`: the 45 starter prompts on
/// https://bighelp.app/quick-start (source: promptclickrun/bighelp-site, `src/quick-start.html`,
/// the `qs-section` lists for Feed, Ideas and Goals). To refresh them, regenerate the JSON from
/// that page with the same ids, keeping each goal blueprint's `goalCategory`. Bundled so they
/// work offline and cost nothing until tapped.
struct BoardBlueprintCatalog: Sendable {
    private let pages: [AgentBoardItem.Kind: [BoardBlueprintGroup]]

    /// The catalog's blueprints when there are some, otherwise the bundled ones. Observed, so a
    /// refresh shows without a relaunch.
    @MainActor static var shared: BoardBlueprintCatalog { TemplateCatalogStore.shared.blueprints }
    static let empty = BoardBlueprintCatalog(pages: [:])

    static func bundled(_ bundle: Bundle = .main) throws -> BoardBlueprintCatalog {
        guard let url = bundle.url(forResource: "BoardBlueprints", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try BoardBlueprintCatalog(data: Data(contentsOf: url))
    }

    private init(pages: [AgentBoardItem.Kind: [BoardBlueprintGroup]]) { self.pages = pages }

    /// Lenient like host data: unknown pages and keys are ignored, blank prompts and empty
    /// groups dropped, and an unknown goal category is none.
    init(data: Data) throws {
        guard data.count <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
        let file = try JSONDecoder().decode(File.self, from: data)
        var pages: [AgentBoardItem.Kind: [BoardBlueprintGroup]] = [:]
        for page in file.pages {
            let kind: AgentBoardItem.Kind? = switch page.page {
            case "feed": .feed
            case "ideas": .idea
            case "goals": .goal
            default: nil
            }
            guard let kind else { continue }
            let groups = (page.groups ?? []).compactMap { group -> BoardBlueprintGroup? in
                let blueprints = (group.prompts ?? []).compactMap { prompt -> BoardBlueprint? in
                    let text = prompt.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard let id = prompt.id, !id.isEmpty, !text.isEmpty else { return nil }
                    return BoardBlueprint(id: id, text: text,
                                          goalCategory: prompt.goalCategory.flatMap(GoalCategory.init(stored:)),
                                          credit: Self.credit(prompt.credit), category: group.id ?? "")
                }
                guard let id = group.id, !blueprints.isEmpty else { return nil }
                return BoardBlueprintGroup(id: id, title: group.title ?? id, blueprints: blueprints)
            }
            pages[kind, default: []] += groups
        }
        self.pages = pages
    }

    /// `/v1/catalog.json`'s flat `blueprints` (board, category, source and updatedAt on each), grouped
    /// like the bundled file. Leniently: an item that doesn't read is dropped.
    init(catalogRows rows: [Any]) {
        var order: [AgentBoardItem.Kind: [String]] = [:]
        var items: [AgentBoardItem.Kind: [String: [BoardBlueprint]]] = [:]
        var seen = Set<String>()
        for value in rows.prefix(2_000) {
            guard let row = value as? [String: Any], let blueprint = Self.blueprint(row),
                  seen.insert(blueprint.id).inserted, let kind = Self.kind(row["board"] as? String) else { continue }
            if items[kind, default: [:]][blueprint.category] == nil { order[kind, default: []].append(blueprint.category) }
            items[kind, default: [:]][blueprint.category, default: []].append(blueprint)
        }
        var pages: [AgentBoardItem.Kind: [BoardBlueprintGroup]] = [:]
        for (kind, categories) in order {
            pages[kind] = categories.compactMap { category in
                items[kind]?[category].map {
                    BoardBlueprintGroup(id: category, title: Self.groupTitle(category), blueprints: $0)
                }
            }
        }
        self.pages = pages
    }

    private static func kind(_ board: String?) -> AgentBoardItem.Kind? {
        switch board {
        case "feed": .feed
        case "ideas": .idea
        case "goals": .goal
        default: nil
        }
    }

    private static func blueprint(_ row: [String: Any]) -> BoardBlueprint? {
        guard let id = row["id"] as? String, !id.isEmpty, id.count <= 64,
              let text = (row["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 2_000 else { return nil }
        let category = (row["category"] as? String).flatMap { $0.isEmpty || $0.count > 40 ? nil : $0 } ?? "other"
        let goalCategory = (row["goalCategory"] as? String).flatMap(GoalCategory.init(stored:))
        return BoardBlueprint(id: id, text: text, goalCategory: goalCategory, credit: credit(row["credit"] as? String),
                              isOfficial: (row["source"] as? String) != "community",
                              updatedAt: TemplateCatalogDate.parse(row["updatedAt"] as? String), category: category)
    }

    static func groupTitle(_ category: String) -> String {
        switch category {
        case "productivity": "Productivity"
        case "marketing": "Marketing"
        case "content": "Content creation"
        case "personal": "Personal life"
        case "research": "Research"
        default: category.prefix(1).uppercased() + category.dropFirst()
        }
    }

    /// A community username ("@sam" or "sam"), or nil when it isn't one.
    static func credit(_ value: String?) -> String? {
        guard var name = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if name.hasPrefix("@") { name.removeFirst() }
        return name.range(of: "^[A-Za-z0-9_.-]{1,39}$", options: .regularExpression) == nil ? nil : name
    }

    func groups(for kind: AgentBoardItem.Kind) -> [BoardBlueprintGroup] { pages[kind] ?? [] }

    /// Goals blueprints for one category, for its Create a goal row.
    func blueprints(for category: GoalCategory) -> [BoardBlueprint] {
        groups(for: .goal).flatMap(\.blueprints).filter { $0.goalCategory == category }
    }

    var count: Int { pages.values.joined().map(\.blueprints.count).reduce(0, +) }

    private struct File: Decodable {
        let pages: [Page]
    }

    private struct Page: Decodable {
        let page: String
        let groups: [Group]?
    }

    private struct Group: Decodable {
        let id: String?
        let title: String?
        let prompts: [Prompt]?
    }

    private struct Prompt: Decodable {
        let id: String?
        let text: String?
        let goalCategory: String?
        let credit: String?
    }
}

// MARK: - Views

/// A blueprint's [placeholders] as blanks to fill in, like an ad-lib. "[videos / posts]" is a
/// choice, a number like "[20]" starts filled with its example, anything else is typed.
struct BlueprintAdLib: Equatable {
    enum Piece: Equatable { case text(String), blank(Int) }

    struct Blank: Identifiable, Equatable {
        let id: Int
        /// What the brackets said, shown as the field's hint.
        let hint: String
        let options: [String]
        let initialValue: String
        var isChoice: Bool { options.count > 1 }
        var isNumber: Bool { !isChoice && hint.allSatisfy { $0.isNumber || $0 == "," || $0 == "." } }
    }

    let pieces: [Piece]
    let blanks: [Blank]

    init(_ text: String) {
        var pieces: [Piece] = []
        var blanks: [Blank] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            if open > rest.startIndex { pieces.append(.text(String(rest[..<open]))) }
            let hint = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            let options = hint.components(separatedBy: " / ").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let isNumber = options.count <= 1 && !hint.isEmpty
                && hint.allSatisfy { $0.isNumber || $0 == "," || $0 == "." }
            let initial = options.count > 1 ? options[0] : (isNumber ? hint : "")
            blanks.append(Blank(id: blanks.count, hint: hint, options: options, initialValue: initial))
            pieces.append(.blank(blanks.count - 1))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { pieces.append(.text(String(rest))) }
        self.pieces = pieces
        self.blanks = blanks
    }

    var initialValues: [Int: String] {
        Dictionary(uniqueKeysWithValues: blanks.map { ($0.id, $0.initialValue) })
    }

    func isComplete(_ values: [Int: String]) -> Bool {
        blanks.allSatisfy { !(values[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The prompt with every blank filled in. A blank left empty keeps its brackets.
    func filled(_ values: [Int: String]) -> String {
        pieces.map { piece in
            switch piece {
            case .text(let text): text
            case .blank(let id):
                Self.value(values[id]) ?? "[\(blanks[id].hint)]"
            }
        }.joined()
    }

    static func value(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ") ?? ""
        return value.isEmpty ? nil : String(value.prefix(200))
    }
}

/// "Blueprints" beside a board's title and in its empty state.
struct BoardBlueprintsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Blueprints", systemImage: "square.grid.2x2")
                .font(.bighelp(.subheadline).weight(.semibold))
                .foregroundStyle(theme.action)
                .padding(.horizontal, BighelpTokens.space12)
                .padding(.vertical, BighelpTokens.space8)
                .background(Capsule().fill(theme.action.opacity(0.12)))
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .accessibilityHint("Starter prompts to set up this page")
        .accessibilityIdentifier("board.blueprints")
    }

    @BighelpThemeReader private var theme
}

/// One board's blueprints by topic. A pick opens its fill-in page.
struct BoardBlueprintsSheet: View {
    let kind: AgentBoardItem.Kind
    let agentName: String
    let groups: [BoardBlueprintGroup]
    let onSend: (String) -> Void
    let onEdit: (String) -> Void
    @State private var filling: BoardBlueprint?
    @State private var search = ""
    @State private var order = BlueprintOrder.forYou
    @State private var officialOnly = false
    @State private var category: String?
    @Environment(\.dismiss) private var dismiss

    enum BlueprintOrder: String, CaseIterable, Identifiable {
        case forYou, newest, mostUsed
        var id: Self { self }
        var title: String {
            switch self {
            case .forYou: "For you"
            case .newest: "Newest"
            case .mostUsed: "Most used"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                controls
                let shown = BlueprintBrowsing.filter(groups.flatMap(\.blueprints), search: search,
                                                     officialOnly: officialOnly, category: category)
                if shown.isEmpty {
                    ContentUnavailableView.search(text: search)
                        .listRowBackground(Color.clear)
                } else if order == .forYou, search.isEmpty {
                    ForEach(groups) { group in
                        let items = shown.filter { $0.category == group.id }
                        if !items.isEmpty { section(group.title, items) }
                    }
                } else {
                    section(search.isEmpty ? order.title : "Results",
                            BlueprintBrowsing.sorted(shown, by: order, usage: TemplateUsage.shared), showsCategory: true)
                }
                Section {
                    Link(destination: TemplateCatalogPolicy.submitURL) {
                        Label("Share yours", systemImage: "square.and.arrow.up")
                    }
                    .listRowBackground(theme.surface)
                    .accessibilityIdentifier("board.blueprints.share")
                } footer: {
                    Text("Send a blueprint on bighelp.app. Approved ones show up here for everyone.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search blueprints")
            .animation(.snappy, value: order)
            .animation(.snappy, value: officialOnly)
            .animation(.snappy, value: category)
            .navigationDestination(item: $filling) { blueprint in
                BlueprintFillView(blueprint: blueprint, agentName: agentName,
                                  onSend: { TemplateUsage.shared.recordUse(blueprint.id); onSend($0) },
                                  onEdit: { TemplateUsage.shared.recordUse(blueprint.id); onEdit($0) })
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("board.blueprints.done")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.blueprints.sheet")
    }

    /// Order, bighelp-only and the categories, above the list.
    private var controls: some View {
        Section {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                Text("Pick one, fill in the blanks, and send it to \(agentName). Nothing runs until you send it.")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Order", selection: $order) {
                    ForEach(BlueprintOrder.allCases) { Text($0.title).tag($0) }
                }
                .bighelpSegmentedPicker()
                .accessibilityIdentifier("board.blueprints.order")
                ScrollView(.horizontal) {
                    HStack(spacing: BighelpTokens.space8) {
                        BlueprintChip(title: "bighelp only", systemImage: "checkmark.seal.fill", isOn: officialOnly,
                                      identifier: "board.blueprints.official") { officialOnly.toggle() }
                        Divider().frame(height: 22)
                        BlueprintChip(title: "All", isOn: category == nil, identifier: "board.blueprints.category.all") {
                            category = nil
                        }
                        ForEach(groups) { group in
                            BlueprintChip(title: group.title, isOn: category == group.id,
                                          identifier: "board.blueprints.category.\(group.id)") {
                                category = category == group.id ? nil : group.id
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: BighelpTokens.space16, bottom: 0, trailing: BighelpTokens.space16))
        }
    }

    private func section(_ title: String, _ items: [BoardBlueprint], showsCategory: Bool = false) -> some View {
        Section {
            ForEach(items) { blueprint in
                Button { filling = blueprint } label: { row(blueprint, showsCategory: showsCategory) }
                    .bighelpPlainButtonStyle()
                    .listRowBackground(theme.surface)
                    .accessibilityIdentifier("board.blueprint.\(blueprint.id)")
            }
        } header: {
            Text(title.uppercased())
                .font(.bighelp(.caption).weight(.bold))
                .tracking(1)
                .foregroundStyle(theme.secondaryText)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var title: String {
        switch kind {
        case .feed: "Feed blueprints"
        case .idea: "Ideas blueprints"
        case .goal: "Goals blueprints"
        }
    }

    private func row(_ blueprint: BoardBlueprint, showsCategory: Bool) -> some View {
        let uses = TemplateUsage.shared.count(blueprint.id)
        return VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(alignment: .top, spacing: BighelpTokens.space12) {
                Text(Self.highlighted(blueprint.text, placeholder: theme.action))
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
            }
            HStack(spacing: BighelpTokens.space8) {
                if blueprint.isOfficial {
                    Label("bighelp", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(theme.action)
                } else if let credit = blueprint.credit {
                    Text(verbatim: "by @\(credit)")
                } else {
                    Text("Community")
                }
                if showsCategory, !blueprint.category.isEmpty {
                    Text("·")
                    Text(BoardBlueprintCatalog.groupTitle(blueprint.category))
                }
                if uses > 0 {
                    Text("·")
                    Text(uses == 1 ? "Used once" : "Used \(uses) times")
                }
            }
            .font(.bighelp(.caption).weight(.medium))
            .foregroundStyle(theme.tertiaryText)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, BighelpTokens.space8)
        .contentShape(.rect)
    }

    /// [Placeholders] in the action color, so it's clear what to fill in.
    static func highlighted(_ text: String, placeholder: Color) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            result += AttributedString(String(rest[..<open]))
            var slot = AttributedString(String(rest[open...close]))
            slot.foregroundColor = placeholder
            result += slot
            rest = rest[rest.index(after: close)...]
        }
        result += AttributedString(String(rest))
        return result
    }

    @BighelpThemeReader private var theme
}

/// A filter or category pill above the blueprints.
private struct BlueprintChip: View {
    let title: String
    var systemImage: String?
    let isOn: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                if let systemImage { Image(systemName: systemImage) }
            }
            .labelStyle(.titleAndIcon)
            .font(.bighelp(.subheadline).weight(.semibold))
            .foregroundStyle(isOn ? theme.actionForeground : theme.primaryText)
            .padding(.horizontal, BighelpTokens.space12)
            .frame(minHeight: 36)
            .background(isOn ? theme.action : theme.surface, in: .capsule)
            .overlay { Capsule().strokeBorder(isOn ? .clear : theme.border) }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }

    @BighelpThemeReader private var theme
}

/// Search, bighelp-only, category and order for blueprints and agent templates.
enum BlueprintBrowsing {
    static func filter(_ items: [BoardBlueprint], search: String, officialOnly: Bool, category: String?) -> [BoardBlueprint] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        return items.filter { blueprint in
            (!officialOnly || blueprint.isOfficial)
                && (category == nil || blueprint.category == category)
                && words.allSatisfy { word in
                    blueprint.text.lowercased().contains(word)
                        || BoardBlueprintCatalog.groupTitle(blueprint.category).lowercased().contains(word)
                        || (blueprint.credit?.lowercased().contains(word) ?? false)
                }
        }
    }

    /// Newest by the catalog's date (bundled ones last), most used by this device's count; ties keep
    /// the catalog's order.
    @MainActor
    static func sorted(_ items: [BoardBlueprint], by order: BoardBlueprintsSheet.BlueprintOrder,
                       usage: TemplateUsage) -> [BoardBlueprint] {
        let indexed = Array(items.enumerated())
        switch order {
        case .forYou:
            return items
        case .newest:
            return indexed.sorted { lhs, rhs in
                let left = lhs.element.updatedAt ?? .distantPast, right = rhs.element.updatedAt ?? .distantPast
                return left == right ? lhs.offset < rhs.offset : left > right
            }.map(\.element)
        case .mostUsed:
            return indexed.sorted { lhs, rhs in
                let left = usage.count(lhs.element.id), right = usage.count(rhs.element.id)
                return left == right ? lhs.offset < rhs.offset : left > right
            }.map(\.element)
        }
    }
}

/// Fill in a blueprint's blanks, then send it to the agent in a new chat, or take it to the
/// message box to change more first.
struct BlueprintFillView: View {
    let blueprint: BoardBlueprint
    let agentName: String
    let onSend: (String) -> Void
    let onEdit: (String) -> Void
    @State private var values: [Int: String]
    private let adLib: BlueprintAdLib

    init(blueprint: BoardBlueprint, agentName: String,
         onSend: @escaping (String) -> Void, onEdit: @escaping (String) -> Void) {
        self.blueprint = blueprint
        self.agentName = agentName
        self.onSend = onSend
        self.onEdit = onEdit
        let adLib = BlueprintAdLib(blueprint.text)
        self.adLib = adLib
        _values = State(initialValue: adLib.initialValues)
    }

    var body: some View {
        Form {
            Section {
                Text(preview)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("board.blueprint.fill.preview")
            } header: {
                Text("What \(agentName) will get").font(.bighelp(.caption).weight(.semibold))
            }
            if !adLib.blanks.isEmpty {
                Section {
                    ForEach(adLib.blanks) { blank in field(blank) }
                } header: {
                    Text("Fill in the blanks").font(.bighelp(.caption).weight(.semibold))
                }
            }
            Section {
                Button {
                    onSend(adLib.filled(values))
                } label: {
                    Label("Send to agent", systemImage: "paperplane.fill")
                        .font(.bighelp(.body).weight(.semibold))
                        .foregroundStyle(theme.actionForeground)
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.action)
                .disabled(!adLib.isComplete(values))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("board.blueprint.fill.send")
                Button("Edit in message box") { onEdit(adLib.filled(values)) }
                    .font(.bighelp(.subheadline))
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("board.blueprint.fill.edit")
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Blueprint")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("board.blueprint.fill")
    }

    /// The prompt as it stands, with what's filled in shown in the action color.
    private var preview: AttributedString {
        var result = AttributedString()
        for piece in adLib.pieces {
            switch piece {
            case .text(let text):
                result += AttributedString(text)
            case .blank(let id):
                var slot = AttributedString(BlueprintAdLib.value(values[id]) ?? "[\(adLib.blanks[id].hint)]")
                slot.foregroundColor = theme.action
                result += slot
            }
        }
        return result
    }

    @ViewBuilder
    private func field(_ blank: BlueprintAdLib.Blank) -> some View {
        let binding = Binding(get: { values[blank.id] ?? "" }, set: { values[blank.id] = $0 })
        if blank.isChoice {
            Picker(blank.options.joined(separator: " or ").capitalizedFirst, selection: binding) {
                ForEach(blank.options, id: \.self) { Text($0).tag($0) }
            }
            .font(.bighelp(.body))
            .accessibilityIdentifier("board.blueprint.fill.blank.\(blank.id)")
        } else {
            TextField(blank.hint.capitalizedFirst, text: binding,
                      prompt: Text(blank.hint.capitalizedFirst).bighelpFieldHint(theme))
                .font(.bighelp(.body))
                .keyboardType(blank.isNumber ? .numbersAndPunctuation : .default)
                .submitLabel(.done)
                .accessibilityIdentifier("board.blueprint.fill.blank.\(blank.id)")
        }
    }

    @BighelpThemeReader private var theme
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension View {
    /// Presents a board's blueprints. A pick opens its fill-in page; Send to agent starts a new
    /// chat that sends it, Edit leaves it in the message box. Either happens once the sheet is
    /// gone (a push under a closing sheet gets dropped).
    func boardBlueprints(isPresented: Binding<Bool>, kind: AgentBoardItem.Kind,
                         context: AgentBoardContext) -> some View {
        modifier(BoardBlueprintsPresenter(isPresented: isPresented, kind: kind, context: context))
    }

    /// One blueprint's fill-in page on its own, for Goals' category menus.
    func blueprintFill(_ blueprint: Binding<BoardBlueprint?>, context: AgentBoardContext) -> some View {
        modifier(BlueprintFillPresenter(blueprint: blueprint, context: context))
    }
}

/// What the fill-in page asked for, carried out once its sheet has closed.
enum BlueprintOutcome: Equatable {
    case send(String), edit(String)

    @MainActor func perform(in context: AgentBoardContext) {
        switch self {
        case .send(let text): context.onSend(text)
        case .edit(let text): context.onAsk(text)
        }
    }
}

private struct BoardBlueprintsPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let kind: AgentBoardItem.Kind
    let context: AgentBoardContext
    @State private var outcome: BlueprintOutcome?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            guard let outcome else { return }
            self.outcome = nil
            outcome.perform(in: context)
        }) {
            BoardBlueprintsSheet(kind: kind, agentName: context.agentName,
                                 groups: BoardBlueprintCatalog.shared.groups(for: kind),
                                 onSend: { finish(.send($0)) }, onEdit: { finish(.edit($0)) })
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .bighelpSheetSize(.standard)
        }
    }

    private func finish(_ outcome: BlueprintOutcome) {
        self.outcome = outcome
        isPresented = false
    }
}

private struct BlueprintFillPresenter: ViewModifier {
    @Binding var blueprint: BoardBlueprint?
    let context: AgentBoardContext
    @State private var outcome: BlueprintOutcome?

    func body(content: Content) -> some View {
        content.sheet(item: $blueprint, onDismiss: {
            guard let outcome else { return }
            self.outcome = nil
            outcome.perform(in: context)
        }) { picked in
            NavigationStack {
                BlueprintFillView(blueprint: picked, agentName: context.agentName,
                                  onSend: { TemplateUsage.shared.recordUse(picked.id); finish(.send($0)) },
                                  onEdit: { TemplateUsage.shared.recordUse(picked.id); finish(.edit($0)) })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { blueprint = nil }
                        }
                    }
            }
            .presentationDetents([.large])
            .bighelpSheetSize(.standard)
        }
    }

    private func finish(_ outcome: BlueprintOutcome) {
        self.outcome = outcome
        blueprint = nil
    }
}
