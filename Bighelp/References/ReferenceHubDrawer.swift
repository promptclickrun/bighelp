import SwiftUI

/// One bottom-anchored suggestion surface, shared by compact and expanded source.
/// Provider previews are inline, so browsing never steals the native responder.
/// One header line (filters, count, close), then rows in the same style as Bighelp
/// IDE's lists (`BighelpSuggestionList`); the rows take the room above the message box.
struct ReferenceHubDrawer: View {
    let hub: ReferenceHubStore
    let commands: SlashCommandCatalogModel?
    var skills: SkillsAndToolsStore? = nil
    var agentID: String? = nil
    var reservesResultsSpace = false
    @State private var inspectedCommand: SlashCommandDescriptor?
    @State private var inspectedSkill: HermesSkillSummary?
    @State private var resultsContentHeight: CGFloat = 0
    @State private var roomAbove: CGFloat = 0

    @BighelpThemeReader private var theme

    private var term: String { hub.query?.query ?? "" }
    private var matchingCommands: [SlashCommandDescriptor] {
        (commands?.commands ?? []).filter { command in
            let categoryMatches = hub.category == .all || (hub.category == .skills && command.source == .skill)
                || (hub.category == .commands && command.source != .skill)
            return categoryMatches && (term.isEmpty || command.name.localizedCaseInsensitiveContains(term)
                || command.description.localizedCaseInsensitiveContains(term)
                || command.aliases.contains { $0.localizedCaseInsensitiveContains(term) })
        }.sorted { lhs, rhs in
            if (lhs.source == .skill) != (rhs.source == .skill) {
                return lhs.source == .skill
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
    private var matchingSkills: [HermesSkillSummary] {
        guard hub.category == .skills || hub.category == .all,
              let catalog = skills?.catalog, catalog.agentID == agentID else { return [] }
        let commandNames = Set((commands?.commands ?? []).filter { $0.source == .skill }.map(\.name))
        return catalog.skills.filter {
            !commandNames.contains($0.name) && (term.isEmpty || $0.name.localizedCaseInsensitiveContains(term)
                || $0.description.localizedCaseInsensitiveContains(term))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        if let preview = hub.preview {
                            providerPreview(preview)
                        } else if let command = inspectedCommand {
                            commandPreview(command)
                        } else if let skill = inspectedSkill {
                            Text(skill.name).font(.bighelp(.headline))
                            Text(skill.description).font(.bighelp(.body))
                            Text(skill.isEnabled ? "Installed skill" : "Disabled skill").font(.bighelp(.caption))
                            Text("This skill has no discoverable slash invocation. Browsing it does not run or enable it.")
                                .font(.bighelp(.caption)).foregroundStyle(theme.secondaryText)
                            Button("Back to results") { inspectedSkill = nil }.frame(minHeight: 44)
                        } else {
                            resultRows
                        }
                    }
                    .padding(.vertical, BighelpTokens.space8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resultsContentHeight = $0 }
                }
                .dismissesKeyboardOnScroll(false)
                .onChange(of: hub.keyboard.highlightedID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }
            .frame(minHeight: reservesResultsSpace ? min(resultsHeight, 120) : nil, maxHeight: resultsHeight)
        }
        .padding(.horizontal, BighelpTokens.space12)
        .foregroundStyle(theme.primaryText)
        .bighelpNavigationGlass(in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(theme.border, lineWidth: BighelpTokens.hairline) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reference-hub.drawer")
        .task(id: hub.isPresented) {
            guard hub.isPresented else { return }
            // Existing host catalog request only after deliberate slash entry.
            await commands?.loadIfNeeded(for: "/")
        }
        .task(id: hub.category) {
            guard hub.category == .skills, let skills, let agentID,
                  skills.catalog?.agentID != agentID else { return }
            await skills.load(agentID: agentID)
        }
        .onChange(of: hub.draftID) { _, _ in
            inspectedCommand = nil
            inspectedSkill = nil
        }
        .onChange(of: hub.query) { _, _ in
            inspectedCommand = nil
            inspectedSkill = nil
        }
        // The drawer's bottom edge sits on the message box, so its height in
        // the window is the room left above the message box.
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { roomAbove = $0 }
        #if targetEnvironment(macCatalyst)
        .onChange(of: keyboardRows, initial: true) { _, rows in
            hub.keyboard.publish(rows: rows.ids, isInspecting: rows.isInspecting)
        }
        .onChange(of: hub.keyboard.request) { _, request in
            guard let request else { return }
            switch request.kind {
            case .pick: pickHighlightedRow()
            case .back:
                inspectedCommand = nil
                inspectedSkill = nil
                hub.closePreview()
            }
        }
        .onDisappear { hub.keyboard.reset() }
        #endif
    }

    /// One line: the filters, the count, then close. The old title row and filter row took 88 pt.
    private var header: some View {
        HStack(spacing: BighelpTokens.space8) {
            ForEach([ReferenceCategory.skills, .commands], id: \.rawValue) { category in
                Button(category.label) {
                    inspectedCommand = nil
                    inspectedSkill = nil
                    hub.selectCategory(category)
                }
                .font(.bighelp(.subheadline).weight(hub.category == category ? .semibold : .regular))
                .padding(.horizontal, BighelpTokens.space12)
                .frame(minHeight: BighelpTokens.scaled(32))
                .background(hub.category == category ? theme.raisedSurface : theme.surface, in: .capsule)
                .contentShape(.capsule)
                .accessibilityAddTraits(hub.category == category ? .isSelected : [])
                .accessibilityIdentifier("reference-hub.filter.\(category.rawValue)")
            }
            if hub.isLoading || hub.isResolving || commands?.isLoading == true {
                ProgressView().controlSize(.small).accessibilityLabel("Loading skills and commands")
            }
            Spacer(minLength: 0)
            #if targetEnvironment(macCatalyst)
            Text("↑ ↓ to move, Return to choose, Esc to close")
                .font(.bighelp(.caption)).foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .accessibilityHidden(true)
            #else
            let count = hub.results.count + matchingCommands.count + matchingSkills.count
            if count > 0, hub.preview == nil, inspectedCommand == nil, inspectedSkill == nil {
                Text(count == 1 ? "1 match" : "\(count) matches")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.tertiaryText)
            }
            #endif
            Button("Dismiss references", systemImage: "xmark") { hub.dismiss() }
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .accessibilityIdentifier("reference-hub.dismiss")
        }
    }

    /// Up to about eight rows, inside the room between the top bar and the message box
    /// (about five with the keyboard up on iPhone), shrinking to fit a short list.
    private var resultsHeight: CGFloat {
        let row = BighelpTokens.scaled(56)
        let clearance: CGFloat = BighelpPlatform.isMac ? 60 : 110
        let room = max(roomAbove - clearance - BighelpTokens.scaled(48), row * 1.2)
        let cap = min(room, row * 8)
        return min(max(resultsContentHeight, row), cap)
    }

    /// The rows ↑ and ↓ move through, top to bottom; none while a preview shows.
    private var keyboardRows: ReferenceHubKeyboardRows {
        let isInspecting = hub.preview != nil || inspectedCommand != nil || inspectedSkill != nil
        guard !isInspecting else { return ReferenceHubKeyboardRows(ids: [], isInspecting: true) }
        return ReferenceHubKeyboardRows(
            ids: hub.results.map(Self.keyboardID) + matchingCommands.map(Self.keyboardID)
                + matchingSkills.map(Self.keyboardID),
            isInspecting: false)
    }

    private static func keyboardID(_ result: ReferenceHubResult) -> String { "result.\(result.id)" }
    private static func keyboardID(_ command: SlashCommandDescriptor) -> String { "command.\(command.name)" }
    private static func keyboardID(_ skill: HermesSkillSummary) -> String { "skill.\(skill.id)" }

    /// Return on a highlighted row does what clicking it does.
    private func pickHighlightedRow() {
        guard let id = hub.keyboard.highlightedID else { return }
        if let result = hub.results.first(where: { Self.keyboardID($0) == id }) {
            hub.select(result)
        } else if let command = matchingCommands.first(where: { Self.keyboardID($0) == id }) {
            hub.insertCatalogToken(name: command.name)
        } else if let skill = matchingSkills.first(where: { Self.keyboardID($0) == id }) {
            hub.beginLocalInspection()
            inspectedSkill = skill
        }
    }

    @ViewBuilder private var resultRows: some View {
        ForEach(hub.results) { result in
            HStack(spacing: 8) {
                Button { hub.select(result) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title).font(.bighelp(.body).weight(.medium))
                        Text([result.category.label, result.subtitle, result.state, result.isCached ? "Cached" : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.bighelp(.caption)).foregroundStyle(theme.secondaryText)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Insert this reference and continue typing. Does not send.")
                .accessibilityIdentifier("reference-hub.result.\(result.id)")
                Button("Inspect \(result.title)", systemImage: "info.circle") { hub.inspect(result) }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .accessibilityHint("Review content and choose what to include")
                    .accessibilityIdentifier("reference-hub.inspect.\(result.id)")
            }
            .modifier(ReferenceHubRowChrome(id: Self.keyboardID(result), highlightedID: hub.keyboard.highlightedID))
        }
        ForEach(matchingCommands) { command in
            let inspect = {
                hub.beginLocalInspection()
                inspectedCommand = command
            }
            Button { hub.insertCatalogToken(name: command.name) } label: {
                ReferenceHubSuggestionRow(systemImage: command.source == .skill ? "wand.and.stars" : "command",
                                          sigil: "/", name: command.name, detail: command.description,
                                          tag: command.source == .skill ? "Skill" : "Command")
            }
            .buttonStyle(.plain)
            .contextMenu { Button("Details", systemImage: "info.circle", action: inspect) }
            .accessibilityAction(named: "Details", inspect)
            .accessibilityHint("Insert text and continue typing. Does not execute this command.")
            .accessibilityIdentifier("reference-hub.command.\(command.name)")
            .modifier(ReferenceHubRowChrome(id: Self.keyboardID(command), highlightedID: hub.keyboard.highlightedID))
        }
        ForEach(matchingSkills) { skill in
            Button {
                hub.beginLocalInspection()
                inspectedSkill = skill
            } label: {
                ReferenceHubSuggestionRow(systemImage: "wand.and.stars", sigil: "", name: skill.name,
                                          detail: skill.description, tag: "Skill")
            }.buttonStyle(.plain)
            .modifier(ReferenceHubRowChrome(id: Self.keyboardID(skill), highlightedID: hub.keyboard.highlightedID))
        }
        if hub.results.isEmpty && matchingCommands.isEmpty && matchingSkills.isEmpty {
            Text(term.isEmpty ? "Choose a category or type to search available sources." : "No matching references or commands.")
                .font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText)
            if [.repos, .issues, .prs, .wiki].contains(hub.category), !hub.isCategoryConfigured {
                Text("This optional source is not connected.").font(.bighelp(.caption)).foregroundStyle(theme.secondaryText)
                if hub.canConnectCategory {
                    Button("Connect source") { hub.connectCategory() }.frame(minHeight: 44)
                        .accessibilityIdentifier("reference-hub.connect")
                }
            }
        }
        ForEach(hub.providerNotices.keys.sorted(), id: \.self) { key in
            Text(hub.providerNotices[key] ?? "").font(.bighelp(.caption)).foregroundStyle(theme.secondaryText)
        }
        ForEach(hub.providerErrors.keys.sorted(), id: \.self) { key in
            Text(hub.providerErrors[key] ?? "").font(.bighelp(.caption)).foregroundStyle(theme.secondaryText)
            Button("Retry source search") { hub.refreshSearch() }.frame(minHeight: 44)
        }
        if hub.category == .all || hub.category == .commands || hub.category == .skills {
            if let error = commands?.errorMessage {
                Text(error).font(.bighelp(.caption)).foregroundStyle(theme.secondaryText)
                Button("Retry commands") { Task { await commands?.retry() } }.frame(minHeight: 44)
            }
        }
    }

    private func commandPreview(_ command: SlashCommandDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("/\(command.name)").font(.bighelp(.headline))
            Text(command.description).font(.bighelp(.body))
            if !command.argsHint.isEmpty { Text(command.argsHint).font(.bighelp(.caption).monospaced()) }
            Text("Inserts text only. A leading slash command runs only when you explicitly Send; inside prose it remains text.")
                .font(.bighelp(.caption)).foregroundStyle(theme.secondaryText)
            Button("Insert /\(command.name)") {
                if hub.insertCatalogToken(name: command.name) { inspectedCommand = nil }
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("reference-hub.command.insert")
            Button("Back to results") { inspectedCommand = nil }.frame(minHeight: 44)
        }
    }

    private func providerPreview(_ preview: ReferenceHubPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preview.result.title).font(.bighelp(.headline))
            Text(preview.sourceKindLabel).font(.bighelp(.caption))
            Text("Selected content is shared with this conversation, its model provider and paired account key holders. Credentials are never included.")
                .font(.bighelp(.caption)).foregroundStyle(theme.secondaryText)
            ForEach(preview.options) { option in
                VStack(alignment: .leading, spacing: 8) {
                    Text(option.label).font(.bighelp(.subheadline).weight(.semibold))
                    ReferenceSnapshotSource(snapshot: option.snapshot)
                    Button("Insert \(option.label)") { hub.insert(option) }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("reference-hub.insert.\(option.id)")
                }
                Divider()
            }
            Button("Back to results") { hub.closePreview() }.frame(minHeight: 44)
        }
    }
}

/// A command or skill row: an icon, the name after its sigil, one line, and a tag.
private struct ReferenceHubSuggestionRow: View {
    let systemImage: String
    let sigil: String
    let name: String
    let detail: String
    let tag: String

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            Image(systemName: systemImage)
                .font(.bighelp(.body))
                .frame(width: BighelpTokens.scaled(28))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text(sigil).foregroundStyle(theme.action))\(name)")
                    .font(.bighelp(.body).weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            BighelpSuggestionTag(text: tag)
        }
        .frame(minHeight: BighelpTokens.scaled(48))
        .contentShape(.rect)
    }

    @BighelpThemeReader private var theme
}

struct ReferenceHubKeyboardRows: Equatable {
    let ids: [String]
    let isInspecting: Bool
}

/// ↑ ↓ Return and Esc in Skills & commands on the Mac. The message box keeps
/// the keyboard: its container passes ↑ ↓ Esc here (`ReferenceComposerContainer`),
/// the composer's Return asks to pick, and the drawer acts on the request.
@MainActor @Observable
final class ReferenceHubKeyboardNavigation {
    struct Request: Equatable {
        enum Kind: Equatable { case pick, back }
        let kind: Kind
        let serial: Int
    }

    private(set) var highlightedID: String?
    private(set) var request: Request?
    @ObservationIgnored private var rowIDs: [String] = []
    @ObservationIgnored private var isInspecting = false
    @ObservationIgnored private var serial = 0

    var hasRows: Bool { !rowIDs.isEmpty }

    func publish(rows: [String], isInspecting: Bool) {
        rowIDs = rows
        self.isInspecting = isInspecting
        if let highlightedID, !rows.contains(highlightedID) { self.highlightedID = nil }
    }

    /// The first ↓ (or ↑) enters the list from the top (or bottom); the ends stop.
    func move(by step: Int) {
        guard !rowIDs.isEmpty else { return }
        guard let current = highlightedID.flatMap({ rowIDs.firstIndex(of: $0) }) else {
            highlightedID = step > 0 ? rowIDs.first : rowIDs.last
            return
        }
        highlightedID = rowIDs[min(max(current + step, 0), rowIDs.count - 1)]
    }

    /// Return: true when a row is highlighted and will be picked instead of
    /// sending. Without an arrow-key choice, Return keeps its usual meaning.
    func pickHighlighted() -> Bool {
        guard highlightedID != nil, !rowIDs.isEmpty else { return false }
        submit(.pick)
        return true
    }

    /// Esc: back from a preview to the list. False means close the drawer.
    func back() -> Bool {
        guard isInspecting else { return false }
        submit(.back)
        return true
    }

    func reset() {
        rowIDs = []
        isInspecting = false
        if highlightedID != nil { highlightedID = nil }
    }

    private func submit(_ kind: Request.Kind) {
        serial &+= 1
        request = Request(kind: kind, serial: serial)
    }
}

/// Mac rows get a little side room and show the ↑ ↓ highlight. iPhone and iPad rows are unchanged.
private struct ReferenceHubRowChrome: ViewModifier {
    let id: String
    let highlightedID: String?
    @BighelpThemeReader private var theme

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        let isHighlighted = id == highlightedID
        content
            .padding(.horizontal, BighelpTokens.space8)
            .background(isHighlighted ? theme.action.opacity(0.16) : .clear,
                        in: .rect(cornerRadius: BighelpTokens.radius8))
            .accessibilityAddTraits(isHighlighted ? .isSelected : [])
            .id(id)
        #else
        content
        #endif
    }
}

extension ReferenceCategory {
    var label: String {
        switch self {
        case .all: "All"
        case .repos: "Repos"
        case .issues: "Issues"
        case .prs: "PRs"
        case .wiki: "Wiki"
        case .skills: "Skills"
        case .commands: "Commands"
        }
    }
}

/// Inert source text, not a Markdown renderer that could load remote images or
/// run provider links. Every outgoing byte can be selected and inspected.
struct ReferenceSnapshotSource: View {
    let snapshot: ReferenceSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.qualifiedLocation).font(.bighelp(.subheadline))
            Text(snapshot.title).font(.bighelp(.body))
            Text(snapshot.selectedContent.isEmpty ? "Metadata only. Description not included." : snapshot.selectedContent)
                .font(.bighelp(.body).monospaced()).textSelection(.enabled)
            Text("Revision: \(snapshot.sourceRevision)").font(.bighelp(.caption).monospaced())
            if snapshot.isTruncated { Text("This selected snapshot is truncated.").font(.bighelp(.caption).weight(.semibold)) }
        }
        .accessibilityElement(children: .contain)
    }
}

struct ReferenceDraftStrip: View {
    let hub: ReferenceHubStore
    @State private var inspectedID: UUID?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(hub.selected) { value in
                        HStack(spacing: 0) {
                            Button {
                                hub.dismiss()
                                inspectedID = inspectedID == value.id ? nil : value.id
                            } label: {
                                Label(value.snapshot.displayLabel, systemImage: "link")
                                    .font(.bighelp(.subheadline)).lineLimit(1).padding(.horizontal, 8).frame(minHeight: 44)
                            }.accessibilityLabel("Inspect reference \(value.snapshot.displayLabel)")
                            Button("Remove reference", systemImage: "xmark") { hub.remove(value) }
                                .labelStyle(.iconOnly).frame(width: 44, height: 44)
                                .accessibilityLabel("Remove reference \(value.snapshot.displayLabel)")
                                .accessibilityIdentifier("reference-hub.remove.\(value.id)")
                        }.bighelpSurface(.capsuleControl)
                    }
                }
            }
            if let value = hub.selected.first(where: { $0.id == inspectedID }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(value.sourceKindLabel).font(.bighelp(.caption))
                        ReferenceSnapshotSource(snapshot: value.snapshot)
                    }
                }
                    .frame(maxHeight: verticalSizeClass == .compact ? 60 : 160).dismissesKeyboardOnScroll(false)
            }
            if !hub.pendingChanges.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("References changed. Review before sending.").font(.bighelp(.headline))
                        ForEach(hub.pendingChanges) { change in
                            Text("Previously selected").font(.bighelp(.subheadline).weight(.semibold))
                            ReferenceSnapshotSource(snapshot: change.original.snapshot)
                            Text("Current source").font(.bighelp(.subheadline).weight(.semibold))
                            ReferenceSnapshotSource(snapshot: change.current)
                        }
                        Button("Use reviewed updates — send separately") { hub.acceptRevalidationChanges() }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("reference-hub.confirm-changes")
                    }
                }.frame(maxHeight: verticalSizeClass == .compact ? 80 : 200).dismissesKeyboardOnScroll(false)
            }
            if let message = hub.message {
                HStack {
                    Text(message).font(.bighelp(.caption))
                    Button("Dismiss message", systemImage: "xmark") { hub.clearMessage() }
                        .labelStyle(.iconOnly).frame(width: 44, height: 44)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reference-hub.selected")
    }
}
