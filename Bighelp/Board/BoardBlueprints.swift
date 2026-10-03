import SwiftUI

// MARK: - Catalog

/// A starter prompt for Feed, Ideas or Goals. Tapping one puts it in a new chat's message box to
/// edit (many have [placeholders]); nothing runs until the person sends it.
struct BoardBlueprint: Identifiable, Equatable, Sendable {
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

/// One board's blueprints by topic. A pick closes the sheet; the page then opens the chat.
struct BoardBlueprintsSheet: View {
    let kind: AgentBoardItem.Kind
    let agentName: String
    let groups: [BoardBlueprintGroup]
    let onPick: (BoardBlueprint) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Pick one to start a chat with \(agentName). Fill in the [brackets] and change anything "
                         + "first; nothing runs until you send it.")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .listRowBackground(Color.clear)
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.blueprints) { blueprint in
                            Button { onPick(blueprint) } label: { row(blueprint) }
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

extension View {
    /// Presents a board's blueprints; a pick opens a chat with it in the message box once the
    /// sheet is gone (a push under a closing sheet gets dropped).
    func boardBlueprints(isPresented: Binding<Bool>, kind: AgentBoardItem.Kind,
                         context: AgentBoardContext) -> some View {
        modifier(BoardBlueprintsPresenter(isPresented: isPresented, kind: kind, context: context))
    }
}

private struct BoardBlueprintsPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let kind: AgentBoardItem.Kind
    let context: AgentBoardContext
    @State private var picked: BoardBlueprint?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            guard let picked else { return }
            self.picked = nil
            context.onAsk(picked.text)
        }) {
            BoardBlueprintsSheet(kind: kind, agentName: context.agentName,
                                 groups: BoardBlueprintCatalog.shared.groups(for: kind)) { blueprint in
                picked = blueprint
                isPresented = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .bighelpSheetSize(.standard)
        }
    }
}
