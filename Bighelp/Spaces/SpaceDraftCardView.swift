import SwiftUI

/// Where the draft card's Open Today goes. Set up by the app; does nothing until then. Chat rows
/// take only a few environment values from the chat (`ChatRowLiveValues`), so this can't come
/// through the environment.
@MainActor
enum SpaceDraftCardHost {
    // One home: the shell sets this to select the Today tab once Today is a tab.
    static var openToday: @MainActor () -> Void = {}
}

/// Where a draft card is: reading the draft, waiting for Add, adding, or done.
enum SpaceDraftPhase: Equatable, Sendable {
    case loading
    case ready
    case adding
    case onToday
    /// The bot deleted the draft, or the bot is gone.
    case removed
    case needsPluginUpdate
}

/// A line under the card's details after something didn't go as asked. Add stays.
enum SpaceDraftNotice: Equatable, Sendable {
    /// The bot made a newer draft than the card first showed: its preview is what Add adds now.
    case changed
    case unreachable
    case full
    case schedulesUnavailable
    /// Add found the draft's script gone: the bot has to make it again.
    case scriptMissing
    case failed
}

/// What the card shows about the draft: the bot's words on the card, or the computer's when the
/// bot has changed the draft since.
struct SpaceDraftDetails: Equatable, Sendable {
    let title: String
    let description: String
    let updates: String
    /// False only when nothing says an update uses AI: the card never says "No AI" by guess.
    let usesAI: Bool
}

/// The draft card's rules, kept apart from the view so they can be tested. Every read and Add gets
/// a ticket; an answer counts only for the ticket the card waits on, so a late answer for an older
/// revision (or a read the card gave up on) never changes what it shows.
struct SpaceDraftFlow: Equatable, Sendable {
    struct Ticket: Equatable, Sendable {
        let number: Int
        /// The draft revision the request was made for.
        let revision: Int
    }

    let draft: SpaceDraftCard
    /// The revision Add sends: the card's own, or a newer one the computer showed.
    private(set) var revision: Int
    /// The draft as `spaces/get` read it; nil until then, or when it can't be read.
    private(set) var preview: Space?
    private(set) var phase: SpaceDraftPhase = .loading
    private(set) var notice: SpaceDraftNotice?
    private(set) var size: SpaceSize = .wide
    private(set) var sizeChosen = false
    private(set) var pending: Ticket?
    private var issued = 0

    init(draft: SpaceDraftCard) {
        self.draft = draft
        revision = draft.revision
    }

    var canAdd: Bool { pending == nil && phase == .ready }
    var showsSizes: Bool { phase == .loading || phase == .ready || phase == .adding }

    var details: SpaceDraftDetails {
        guard let preview, preview.revision == revision, revision != draft.revision else {
            // The card's own revision: its words, and AI if either the card or the computer says so.
            let computerSaysAI = preview.map { $0.revision == draft.revision && $0.routine.usesAI } ?? false
            return SpaceDraftDetails(title: draft.title, description: draft.description, updates: draft.updates,
                                     usesAI: draft.usesAI || computerSaysAI)
        }
        // The bot changed the draft: the computer's words for the revision Add sends.
        return SpaceDraftDetails(
            title: preview.title.isEmpty ? draft.title : preview.title,
            description: preview.description.isEmpty ? draft.description : preview.description,
            updates: preview.routine.updates.isEmpty ? draft.updates : preview.routine.updates,
            usesAI: preview.routine.usesAI)
    }

    private mutating func issue() -> Ticket {
        issued += 1
        let ticket = Ticket(number: issued, revision: revision)
        pending = ticket
        return ticket
    }

    /// Reads the draft again (when the card shows, and after the bot changed it).
    mutating func beginLoad() -> Ticket {
        if phase != .onToday && phase != .removed { phase = .loading }
        return issue()
    }

    mutating func loaded(_ result: Result<Space, SpacesError>, ticket: Ticket) {
        guard ticket == pending else { return }
        pending = nil
        switch result {
        case .success(let space):
            preview = space
            if !sizeChosen { size = space.size }
            if space.state == .live && !space.routine.pendingChange {
                phase = .onToday
                notice = nil
                return
            }
            if space.revision != revision {
                revision = space.revision
                notice = .changed
            }
            phase = .ready
        case .failure(.notFound):
            phase = .removed
        case .failure(.needsPluginUpdate):
            phase = .needsPluginUpdate
        case .failure:
            // No preview, or the last one; Add still works.
            if phase == .loading { phase = .ready }
        }
    }

    /// The card reads the draft when it shows: at first, after the bot changed it, and again when
    /// the last read got no answer. A card that has its answer doesn't ask each time it scrolls by.
    var wantsRead: Bool { phase == .loading || (phase == .ready && preview == nil) }

    mutating func choose(_ size: SpaceSize) {
        // Once Add is on its way, the size it sent stays.
        guard phase == .loading || phase == .ready else { return }
        self.size = size
        sizeChosen = true
    }

    /// Add to Today: the ticket to send it with, or nil while the card can't add.
    mutating func beginAdd() -> Ticket? {
        guard canAdd else { return nil }
        notice = nil
        phase = .adding
        return issue()
    }

    /// Add's answer. True when the draft has to be read again (the bot changed it).
    @discardableResult
    mutating func added(_ result: Result<Space, SpacesError>, ticket: Ticket) -> Bool {
        guard ticket == pending else { return false }
        pending = nil
        switch result {
        case .success(let space):
            preview = space
            phase = .onToday
            return false
        case .failure(let error):
            switch error {
            case .draftChanged(let newer):
                if let newer { revision = newer }
                notice = .changed
                phase = .loading
                return true
            case .notDraft:
                phase = .onToday
            case .notFound:
                phase = .removed
            case .needsPluginUpdate:
                phase = .needsPluginUpdate
            case .unreachable:
                phase = .ready
                notice = .unreachable
            case .full:
                phase = .ready
                notice = .full
            case .schedulesUnavailable:
                phase = .ready
                notice = .schedulesUnavailable
            case .scriptMissing:
                phase = .ready
                notice = .scriptMissing
            case .tooSoon, .routineFailed, .other:
                phase = .ready
                notice = .failed
            }
            return false
        }
    }
}

/// Runs the card's reads and its Add. Owned by the card's `@State`: an Add the person started
/// finishes on the computer even if the card scrolls away, but a card that's gone changes nothing.
@MainActor
@Observable
final class SpaceDraftCardModel {
    private(set) var flow: SpaceDraftFlow
    /// Moves when the draft has to be read again; the card's read task follows it.
    private(set) var reloads = 0

    typealias Read = @MainActor (_ agentID: String, _ spaceID: String) async throws(SpacesError) -> Space
    typealias Add = @MainActor (_ agentID: String, _ spaceID: String, _ revision: Int, _ size: SpaceSize,
                                _ preview: Space?) async throws(SpacesError) -> Space

    @ObservationIgnored private let read: Read
    @ObservationIgnored private let addSpace: Add

    init(draft: SpaceDraftCard,
         read: @escaping Read = { (agentID: String, spaceID: String) async throws(SpacesError) -> Space in
             // The chat's computer is the one in use (`SpacesHost.current`).
             guard let api = SpacesHost.current()?.api else { throw .unreachable }
             return try await api.space(agentID: agentID, spaceID: spaceID)
         },
         add: @escaping Add = { (agentID: String, spaceID: String, revision: Int, size: SpaceSize,
                                 preview: Space?) async throws(SpacesError) -> Space in
             try await TodaySpacesModel.shared.add(agentID: agentID, spaceID: spaceID, draftRevision: revision,
                                                   size: size, preview: preview)
         }) {
        flow = SpaceDraftFlow(draft: draft)
        self.read = read
        addSpace = add
    }

    /// The card's `.task`: cancelled when the card goes, and then nothing changes.
    func load(agentID: String) async {
        guard flow.wantsRead else { return }
        let ticket = flow.beginLoad()
        let result: Result<Space, SpacesError>
        do throws(SpacesError) {
            result = .success(try await read(agentID, flow.draft.spaceID))
        } catch {
            result = .failure(error)
        }
        guard !Task.isCancelled else { return }
        flow.loaded(result, ticket: ticket)
    }

    func choose(_ size: SpaceSize) { flow.choose(size) }

    func add(agentID: String) {
        guard let ticket = flow.beginAdd() else { return }
        let spaceID = flow.draft.spaceID
        let size = flow.size
        // Shown on Today at once only when it's the draft Add sends.
        let preview = flow.preview.flatMap { $0.revision == ticket.revision ? $0 : nil }
        let addSpace = addSpace
        Task { [weak self] in
            let result: Result<Space, SpacesError>
            do throws(SpacesError) {
                result = .success(try await addSpace(agentID, spaceID, ticket.revision, size, preview))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            if self.flow.added(result, ticket: ticket) { self.reloads += 1 }
        }
    }
}

/// The chat's card for a space the bot drafted (`space_draft`): what it shows, a preview of its
/// panel, how often it updates and whether that uses AI, a size, and Add to Today. Nothing runs on
/// the computer until Add.
@MainActor
struct SpaceDraftCardView: View {
    let draft: SpaceDraftCard
    let onOpenToday: @MainActor () -> Void

    @Environment(\.chatCardInteractions) private var interactions
    @State private var model: SpaceDraftCardModel
    @BighelpThemeReader private var theme

    init(draft: SpaceDraftCard, onOpenToday: @escaping @MainActor () -> Void = { SpaceDraftCardHost.openToday() }) {
        self.draft = draft
        self.onOpenToday = onOpenToday
        _model = State(initialValue: SpaceDraftCardModel(draft: draft))
    }

    /// The bot whose chat this is, on the computer in use; nil while the chat's connection is closed.
    private var agentID: String? {
        guard let scope = interactions?.scope, scope.isUsable else { return nil }
        return scope.profileID
    }

    private struct ReadKey: Equatable {
        let agentID: String?
        let reloads: Int
    }

    var body: some View {
        let flow = model.flow
        let details = flow.details
        VStack(alignment: .leading, spacing: 14) {
            SpaceDraftHeader(details: details)
            SpaceDraftPreview(flow: flow)
            SpaceDraftUpdatesLine(details: details)
            if flow.showsSizes {
                SpaceDraftSizeChips(selection: flow.size, choose: { model.choose($0) })
            }
            if let notice = flow.notice { SpaceDraftNoticeLine(notice: notice) }
            SpaceDraftAction(phase: flow.phase, canAdd: flow.canAdd && agentID != nil,
                             add: { if let agentID { model.add(agentID: agentID) } }, openToday: onOpenToday)
        }
        .padding(BighelpTokens.space16)
        .frame(maxWidth: 420, alignment: .leading)
        .background(theme.surface, in: .rect(cornerRadius: BighelpCardDesignTokens.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpCardDesignTokens.cornerRadius, style: .continuous)
                .stroke(theme.border, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space-draft.card")
        .task(id: ReadKey(agentID: agentID, reloads: model.reloads)) {
            guard let agentID else { return }
            await model.load(agentID: agentID)
        }
    }
}

private struct SpaceDraftHeader: View {
    let details: SpaceDraftDetails
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: "square.grid.2x2")
                .font(.bighelp(.title3, weight: .semibold))
                .foregroundStyle(theme.actionForeground)
                .frame(width: 44, height: 44)
                .background(theme.action, in: .rect(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: details.title)
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                Text(verbatim: details.description)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(4)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The panel as Today will draw it, at the chosen size. Still while it loads; left out when the
/// draft can't be read.
private struct SpaceDraftPreview: View {
    let flow: SpaceDraftFlow
    @BighelpThemeReader private var theme

    var body: some View {
        if let preview = flow.preview {
            framed(SpacePanelView(space: preview, size: flow.size))
        } else if flow.phase == .loading {
            framed(SpacePanelPlaceholder().frame(height: SpacePanelView.cardHeight(flow.size)))
        }
    }

    private func framed(_ panel: some View) -> some View {
        panel
            .padding(BighelpTokens.space12)
            .frame(maxWidth: flow.size == .small ? 200 : .infinity, alignment: .topLeading)
            .background(theme.canvas, in: .rect(cornerRadius: BighelpTokens.radius16, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("space-draft.preview")
    }
}

/// "Every 15 minutes" and, beside it, what an update costs. Wraps at large text.
private struct SpaceDraftUpdatesLine: View {
    let details: SpaceDraftDetails
    @BighelpThemeReader private var theme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: BighelpTokens.space8) { updates; cost }
            VStack(alignment: .leading, spacing: BighelpTokens.space4) { updates; cost }
        }
    }

    private var updates: some View {
        Label { Text(verbatim: details.updates) } icon: { Image(systemName: "clock.arrow.circlepath") }
            .font(.bighelp(.footnote, weight: .medium))
            .foregroundStyle(theme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("space-draft.updates")
    }

    private var cost: some View {
        Group {
            if details.usesAI { Text("Uses AI each update") } else { Text("No AI") }
        }
        .font(.bighelp(.footnote, weight: .medium))
        .foregroundStyle(theme.primaryText.opacity(0.8))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(theme.canvas, in: .capsule)
        .overlay { Capsule().stroke(theme.border, lineWidth: 0.5) }
        .accessibilityIdentifier("space-draft.ai")
    }
}

/// Small, Wide and Tall in one row that scrolls sideways.
private struct SpaceDraftSizeChips: View {
    let selection: SpaceSize
    let choose: (SpaceSize) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: BighelpTokens.space8) {
                ForEach(SpaceSize.allCases, id: \.self) { size in
                    SpacesChip(title: Text(TodayPanelSize(size).title), isOn: size == selection,
                               identifier: "space-draft.size.\(size.rawValue)") { choose(size) }
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Size")
    }
}

private struct SpaceDraftNoticeLine: View {
    let notice: SpaceDraftNotice
    @BighelpThemeReader private var theme

    var body: some View {
        text
            .font(.bighelp(.footnote))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("space-draft.notice")
    }

    private var text: Text {
        switch notice {
        case .changed: Text("The bot changed this space. Check it, then add it.")
        case .unreachable: Text("Could not reach your computer. Try again.")
        case .full: Text("This bot has as many spaces as it can keep. Delete one on Today first.")
        case .schedulesUnavailable: Text("Your computer can't run scheduled tasks right now.")
        case .scriptMissing: Text("This space's script is missing. Ask the bot to make it again.")
        case .failed: Text("Could not add this space. Try again.")
        }
    }
}

private struct SpaceDraftAction: View {
    let phase: SpaceDraftPhase
    let canAdd: Bool
    let add: () -> Void
    let openToday: @MainActor () -> Void
    @BighelpThemeReader private var theme

    var body: some View {
        switch phase {
        case .loading, .ready, .adding:
            Button(action: add) {
                Group {
                    if phase == .adding { Text("Adding…") } else { Text("Add to Today") }
                }
                .font(.bighelp(.body, weight: .semibold))
                .foregroundStyle(theme.actionForeground)
                .frame(maxWidth: .infinity, minHeight: max(46, BighelpTokens.hitTarget))
                .background(theme.action.opacity(canAdd ? 1 : 0.5),
                            in: .rect(cornerRadius: 14, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .accessibilityIdentifier("space-draft.add")
        case .onToday:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: BighelpTokens.space12) { onToday; Spacer(minLength: 0); openButton }
                VStack(alignment: .leading, spacing: BighelpTokens.space8) { onToday; openButton }
            }
        case .removed:
            line(Text("Removed"), symbol: "trash")
                .accessibilityIdentifier("space-draft.removed")
        case .needsPluginUpdate:
            line(Text("Update the plugin on your computer to add this."), symbol: "arrow.down.circle")
                .accessibilityIdentifier("space-draft.update-plugin")
        }
    }

    private var onToday: some View {
        Label("On Today", systemImage: "checkmark")
            .font(.bighelp(.subheadline, weight: .semibold))
            .foregroundStyle(theme.primaryText)
            .accessibilityIdentifier("space-draft.on-today")
    }

    private var openButton: some View {
        Button {
            openToday()
        } label: {
            Text("Open Today")
                .font(.bighelp(.subheadline, weight: .semibold))
                .foregroundStyle(theme.action)
                .padding(.horizontal, BighelpTokens.space12)
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .accessibilityIdentifier("space-draft.open-today")
    }

    private func line(_ text: Text, symbol: String) -> some View {
        Label { text } icon: { Image(systemName: symbol) }
            .font(.bighelp(.subheadline, weight: .medium))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
