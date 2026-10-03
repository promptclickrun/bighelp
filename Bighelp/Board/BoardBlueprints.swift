import SwiftUI

// MARK: - Catalog

/// A starter prompt for Feed, Ideas or Goals. Tapping one puts it in a new chat's message box to
/// edit (many have [placeholders]); nothing runs until the person sends it.
struct BoardBlueprint: Identifiable, Hashable, Sendable {
    let id: String
    let text: String
    /// Goals blueprints: the category the goal belongs in.
    let goalCategory: GoalCategory?
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

    static let shared: BoardBlueprintCatalog = (try? bundled()) ?? BoardBlueprintCatalog(pages: [:])

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
                                          goalCategory: prompt.goalCategory.flatMap(GoalCategory.init(stored:)))
                }
                guard let id = group.id, !blueprints.isEmpty else { return nil }
                return BoardBlueprintGroup(id: id, title: group.title ?? id, blueprints: blueprints)
            }
            pages[kind, default: []] += groups
        }
        self.pages = pages
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Pick one, fill in the blanks, and send it to \(agentName). Nothing runs until you send it.")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .listRowBackground(Color.clear)
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.blueprints) { blueprint in
                            Button { filling = blueprint } label: { row(blueprint) }
                                .bighelpPlainButtonStyle()
                                .listRowBackground(theme.surface)
                                .accessibilityIdentifier("board.blueprint.\(blueprint.id)")
                        }
                    } header: {
                        Text(group.title.uppercased())
                            .font(.bighelp(.caption).weight(.bold))
                            .tracking(1)
                            .foregroundStyle(theme.secondaryText)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationDestination(item: $filling) { blueprint in
                BlueprintFillView(blueprint: blueprint, agentName: agentName, onSend: onSend, onEdit: onEdit)
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

    private var title: String {
        switch kind {
        case .feed: "Feed blueprints"
        case .idea: "Ideas blueprints"
        case .goal: "Goals blueprints"
        }
    }

    private func row(_ blueprint: BoardBlueprint) -> some View {
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
        .padding(.vertical, BighelpTokens.space4)
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
                                  onSend: { finish(.send($0)) }, onEdit: { finish(.edit($0)) })
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
