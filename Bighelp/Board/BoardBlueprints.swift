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
    /// Its topic (Productivity, Marketing…); Other when the catalog names none the app knows.
    var category: TemplateCategory = .other
}

/// One topic's blueprints on a page.
struct BoardBlueprintGroup: Identifiable, Equatable, Sendable {
    let category: TemplateCategory
    let blueprints: [BoardBlueprint]
    var id: String { category.id }
    var title: String { category.title }
}

/// The bundled blueprints, `Resources/BoardBlueprints.json`: the 45 starter prompts on
/// https://bighelp.app/quick-start (source: promptclickrun/bighelp-site, `src/quick-start.html`,
/// the `qs-section` lists for Feed, Ideas and Goals). To refresh them, regenerate the JSON from
/// that page with the same ids, keeping each goal blueprint's `goalCategory`. Bundled so they
/// work offline and cost nothing until tapped.
struct BoardBlueprintCatalog: Sendable {
    /// Each page's blueprints in the catalog's order.
    private let pages: [AgentBoardItem.Kind: [BoardBlueprint]]

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

    private init(pages: [AgentBoardItem.Kind: [BoardBlueprint]]) { self.pages = pages }

    /// Lenient like host data: unknown pages and keys are ignored, blank prompts and empty
    /// groups dropped, and an unknown goal category is none. A group's ID is its topic.
    init(data: Data) throws {
        guard data.count <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
        let file = try JSONDecoder().decode(File.self, from: data)
        var pages: [AgentBoardItem.Kind: [BoardBlueprint]] = [:]
        for page in file.pages {
            guard let kind = Self.kind(page.page) else { continue }
            for group in page.groups ?? [] {
                guard group.id != nil else { continue }
                pages[kind, default: []] += (group.prompts ?? []).compactMap { prompt -> BoardBlueprint? in
                    let text = prompt.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard let id = prompt.id, !id.isEmpty, !text.isEmpty else { return nil }
                    return BoardBlueprint(id: id, text: text,
                                          goalCategory: prompt.goalCategory.flatMap(GoalCategory.init(stored:)),
                                          credit: Self.credit(prompt.credit), category: .blueprint(group.id))
                }
            }
        }
        self.pages = pages
    }

    /// `/v1/catalog.json`'s flat `blueprints` (board, category, source and updatedAt on each).
    /// Leniently: an item that doesn't read is dropped.
    init(catalogRows rows: [Any]) {
        var pages: [AgentBoardItem.Kind: [BoardBlueprint]] = [:]
        var seen = Set<String>()
        for value in rows.prefix(2_000) {
            guard let row = value as? [String: Any], let blueprint = Self.blueprint(row),
                  seen.insert(blueprint.id).inserted, let kind = Self.kind(row["board"] as? String) else { continue }
            pages[kind, default: []].append(blueprint)
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
        let goalCategory = (row["goalCategory"] as? String).flatMap(GoalCategory.init(stored:))
        return BoardBlueprint(id: id, text: text, goalCategory: goalCategory, credit: credit(row["credit"] as? String),
                              isOfficial: (row["source"] as? String) != "community",
                              updatedAt: TemplateCatalogDate.parse(row["updatedAt"] as? String),
                              category: .blueprint(row["category"] as? String))
    }

    /// A community username ("@sam" or "sam"), or nil when it isn't one.
    static func credit(_ value: String?) -> String? {
        guard var name = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if name.hasPrefix("@") { name.removeFirst() }
        return name.range(of: "^[A-Za-z0-9_.-]{1,39}$", options: .regularExpression) == nil ? nil : name
    }

    /// A page's blueprints by topic, in the topics' fixed order with Other last.
    func groups(for kind: AgentBoardItem.Kind) -> [BoardBlueprintGroup] {
        TemplateTopics.sections(blueprints(for: kind), topics: TemplateCategory.blueprintTopics, category: \.category)
            .compactMap { section in section.category.map { BoardBlueprintGroup(category: $0, blueprints: section.items) } }
    }

    /// A page's blueprints in the catalog's order.
    func blueprints(for kind: AgentBoardItem.Kind) -> [BoardBlueprint] { pages[kind] ?? [] }

    /// Goals blueprints for one category, for its Create a goal row.
    func blueprints(for category: GoalCategory) -> [BoardBlueprint] {
        groups(for: .goal).flatMap(\.blueprints).filter { $0.goalCategory == category }
    }

    var count: Int { pages.values.map(\.count).reduce(0, +) }

    private struct File: Decodable {
        let pages: [Page]
    }

    private struct Page: Decodable {
        let page: String
        let groups: [Group]?
    }

    /// Its `title` isn't read: the topic's name comes from `TemplateCategory`.
    private struct Group: Decodable {
        let id: String?
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

/// One board's blueprints by topic: search, topic chips and Sort. A pick opens its fill-in page.
struct BoardBlueprintsSheet: View {
    let kind: AgentBoardItem.Kind
    let agentName: String
    let blueprints: [BoardBlueprint]
    let onSend: (String) -> Void
    let onEdit: (String) -> Void
    @State private var filling: BoardBlueprint?
    @State private var search = ""
    @State private var filter = TemplateTopicFilter.all
    @State private var order = TemplateOrder.forYou
    @State private var officialOnly = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let offersOfficialOnly = blueprints.contains { !$0.isOfficial }
        let listing = BlueprintBrowsing.listing(blueprints, search: search, officialOnly: officialOnly && offersOfficialOnly,
                                                filter: filter, order: order, usage: TemplateUsage.shared)
        NavigationStack {
            List {
                Section {
                    BighelpSearchField(text: $search, prompt: "Search blueprints", accessibilityLabel: "Search blueprints",
                                       accessibilityIdentifier: "board.blueprints.search")
                        .bighelpListSearchRow()
                    TemplateTopicChips(filters: listing.filters, selection: $filter, identifier: "board.blueprints")
                        .templateChipsRow()
                } footer: {
                    Text("Pick one, fill in the blanks, and send it to \(agentName). Nothing runs until you send it.")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                }
                ForEach(listing.sections) { section in
                    Section {
                        ForEach(section.items) { blueprint in
                            Button { filling = blueprint } label: {
                                row(blueprint, showsCategory: section.category == nil, showsSource: offersOfficialOnly)
                            }
                            .bighelpPlainButtonStyle()
                            .listRowBackground(theme.surface)
                            .accessibilityIdentifier("board.blueprint.\(blueprint.id)")
                        }
                    } header: {
                        TemplateSectionHeader(title: section.title, systemImage: section.category?.systemImage,
                                              count: section.items.count,
                                              identifier: "board.blueprints.section.\(section.id)")
                    }
                }
                if listing.isEmpty {
                    TemplateEmptyView(state: TemplateEmptyState(search: search, filter: listing.filter, noun: "blueprints"),
                                      identifier: "board.blueprints.empty") { filter = .all }
                        .listRowBackground(Color.clear)
                }
                Section {
                    Link(destination: TemplateCatalogPolicy.submitURL) {
                        Label("Share yours", systemImage: "square.and.arrow.up")
                            .font(.bighelp(.body))
                    }
                    .listRowBackground(theme.surface)
                    .accessibilityIdentifier("board.blueprints.share")
                } footer: {
                    Text("Send a blueprint on bighelp.app. Approved ones show up here for everyone.")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
            .dismissesKeyboardOnScroll(true)
            .animation(.snappy, value: filter)
            .animation(.snappy, value: order)
            .animation(.snappy, value: officialOnly)
            .navigationDestination(item: $filling) { blueprint in
                BlueprintFillView(blueprint: blueprint, agentName: agentName,
                                  onSend: { TemplateUsage.shared.recordUse(blueprint.id); onSend($0) },
                                  onEdit: { TemplateUsage.shared.recordUse(blueprint.id); onEdit($0) })
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .bighelpToolbarText()
                        .accessibilityIdentifier("board.blueprints.done")
                }
                ToolbarItem(placement: .primaryAction) {
                    TemplateSortMenu(order: $order, officialOnly: $officialOnly, offersOfficialOnly: offersOfficialOnly,
                                     identifier: "board.blueprints.sort")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.blueprints.sheet")
    }

    private var title: String {
        switch kind {
        case .feed: "Feed blueprints"
        case .idea: "Ideas blueprints"
        case .goal: "Goals blueprints"
        }
    }

    /// The prompt, then only what tells it apart: whose it is (when some are the community's), its
    /// topic in a ranked list, and how often it was used.
    private func row(_ blueprint: BoardBlueprint, showsCategory: Bool, showsSource: Bool) -> some View {
        let uses = TemplateUsage.shared.count(blueprint.id)
        var details: [String] = []
        if showsSource {
            details.append(blueprint.isOfficial ? "bighelp" : blueprint.credit.map { "by @\($0)" } ?? "Community")
        }
        if showsCategory { details.append(blueprint.category.title) }
        if uses > 0 { details.append(uses == 1 ? "Used once" : "Used \(uses) times") }
        return VStack(alignment: .leading, spacing: BighelpTokens.space4) {
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
            if !details.isEmpty {
                Text(verbatim: details.joined(separator: " · "))
                    .font(.bighelp(.caption).weight(.medium))
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(1)
            }
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

/// Search, bighelp-only, topic and order for blueprints.
enum BlueprintBrowsing {
    /// Every word of the search somewhere in its text, topic or credit.
    private static func matches(_ blueprint: BoardBlueprint, words: [String]) -> Bool {
        words.allSatisfy { word in
            blueprint.text.lowercased().contains(word)
                || blueprint.category.title.lowercased().contains(word)
                || (blueprint.credit?.lowercased().contains(word) ?? false)
        }
    }

    /// What the sheet shows: the page's blueprints by topic, or ranked for Newest and Most used.
    @MainActor
    static func listing(_ items: [BoardBlueprint], search: String, officialOnly: Bool, filter: TemplateTopicFilter,
                        order: TemplateOrder, usage: TemplateUsage) -> TemplateListing<BoardBlueprint> {
        let words = TemplateTopics.words(search)
        let ranked: (title: String, sort: ([BoardBlueprint]) -> [BoardBlueprint])? = order == .forYou ? nil
            : (order.title, { sorted($0, by: order, usage: usage) })
        return TemplateTopics.listing(catalog: officialOnly ? items.filter(\.isOfficial) : items,
                                      topics: TemplateCategory.blueprintTopics, filter: filter, category: \.category,
                                      matches: { matches($0, words: words) }, ranked: ranked)
    }

    /// Newest by the catalog's date (bundled ones last), most used by this device's count; ties keep
    /// the catalog's order.
    @MainActor
    static func sorted(_ items: [BoardBlueprint], by order: TemplateOrder,
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
        content.bighelpSheet(isPresented: $isPresented, onDismiss: {
            guard let outcome else { return }
            self.outcome = nil
            outcome.perform(in: context)
        }) {
            BoardBlueprintsSheet(kind: kind, agentName: context.agentName,
                                 blueprints: BoardBlueprintCatalog.shared.blueprints(for: kind),
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
        content.bighelpSheet(item: $blueprint, onDismiss: {
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
