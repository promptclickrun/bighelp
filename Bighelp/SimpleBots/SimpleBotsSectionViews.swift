import SwiftUI

/// A group chat's face: up to `limit` of its members' faces, overlapping. Rows show two, the top three.
struct SimpleBotsGroupFace: View {
    let members: [SimpleBotsBot]
    let size: CGFloat
    var limit = 2
    @BighelpThemeReader private var theme

    var body: some View {
        let shown = Array(members.prefix(limit))
        ZStack {
            switch shown.count {
            case 0:
                Image(systemName: "person.3.fill")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: size, height: size)
                    .background(theme.surface, in: .circle)
            case 1:
                face(shown[0], size: size * 0.8)
            case 2:
                face(shown[0], size: size * 0.68).offset(x: -size * 0.16, y: -size * 0.14)
                face(shown[1], size: size * 0.68).offset(x: size * 0.16, y: size * 0.14)
            default:
                face(shown[0], size: size * 0.56).offset(x: -size * 0.27, y: size * 0.1)
                face(shown[2], size: size * 0.56).offset(x: size * 0.27, y: size * 0.1)
                face(shown[1], size: size * 0.56).offset(y: -size * 0.14)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// A ring in the page's color keeps overlapping faces apart.
    private func face(_ bot: SimpleBotsBot, size: CGFloat) -> some View {
        SimpleBotFace(agentID: bot.profileID, name: bot.name, imageURL: bot.imageURL, size: size)
            .companionScope(bot.faceScope)
            .background(Circle().fill(theme.canvas).padding(-max(1.5, size * 0.04)))
    }
}

/// A section's faces, like a Home Screen folder: up to four members in a 2 × 2 grid, a group chat as
/// its members' faces together. A folder's faces hold still.
struct SimpleBotsFolderFaces: View {
    let members: [SimpleBotsItem]
    let cell: CGFloat
    @BighelpThemeReader private var theme

    var body: some View {
        let spacing = cell * 0.2
        VStack(spacing: spacing) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<2, id: \.self) { column in
                        let index = row * 2 + column
                        if members.indices.contains(index) {
                            face(members[index])
                        } else {
                            Circle().fill(theme.separator.opacity(0.6)).frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
        .environment(\.bighelpLoaderMotionOverride, BighelpLoaderMotionOverride(sceneInactive: true))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func face(_ item: SimpleBotsItem) -> some View {
        switch item.kind {
        case .bot(let bot):
            SimpleBotFace(agentID: bot.profileID, name: bot.name, imageURL: bot.imageURL, size: cell)
                .companionScope(bot.faceScope)
        case .group(let group):
            SimpleBotsGroupFace(members: group.members, size: cell)
        }
    }
}

/// A section's card on the home: its faces, its name and how many are in it, and a dot while one of
/// them is unread.
struct SimpleBotsSectionCardView: View {
    let card: SimpleBotsSectionCard
    let isUnread: Bool
    @ScaledMetric(relativeTo: .body) private var cell: CGFloat = 40
    @BighelpThemeReader private var theme

    static let cornerRadius: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            SimpleBotsFolderFaces(members: card.members, cell: min(cell, 56))
            VStack(alignment: .leading, spacing: 2) {
                Text(card.section.name)
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(card.countText)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(BighelpTokens.space16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: .rect(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if isUnread {
                Circle().fill(theme.information).frame(width: 10, height: 10)
                    .padding(BighelpTokens.space16)
            }
        }
        .contentShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
    }
}

/// The home's Sections: a caption, then a card for each section, two across (one at the largest
/// text sizes). Touch and hold (right-click on the Mac) a card for its actions.
struct SimpleBotsSectionGrid: View {
    let cards: [SimpleBotsSectionCard]
    let isUnread: (SimpleBotsSectionCard) -> Bool
    let open: (FleetSection) -> Void
    let prompt: (SimpleBotsSectionPrompt) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: BighelpTokens.space12, alignment: .top),
                            count: typeSize.isAccessibilitySize ? 1 : 2)
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            AgentsSectionCaption(title: String(localized: "Sections"))
                .padding(.horizontal, BighelpTokens.space4)
            LazyVGrid(columns: columns, spacing: BighelpTokens.space12) {
                ForEach(cards) { card in
                    let unread = isUnread(card)
                    Button { open(card.section) } label: {
                        SimpleBotsSectionCardView(card: card, isUnread: unread)
                    }
                    .bighelpPlainButtonStyle(.rounded(SimpleBotsSectionCardView.cornerRadius))
                    .contextMenu { SimpleBotsSectionMenu(section: card.section, open: open, prompt: prompt) }
                    .accessibilityLabel(unread ? "\(card.section.name), \(card.countText), unread"
                                        : "\(card.section.name), \(card.countText)")
                    .accessibilityHint("Opens the section")
                    .accessibilityIdentifier("simple-bots.section.\(card.section.name)")
                }
            }
        }
        .padding(.horizontal, BighelpTokens.space20)
        .padding(.bottom, BighelpTokens.space20)
    }
}

/// A section card's actions: Open, Rename, Edit Members, Edit Sections, then Delete Section.
struct SimpleBotsSectionMenu: View {
    let section: FleetSection
    var open: ((FleetSection) -> Void)?
    let prompt: (SimpleBotsSectionPrompt) -> Void

    var body: some View {
        if let open { Button("Open", systemImage: "folder") { open(section) } }
        Button("Rename", systemImage: "pencil") { prompt(.rename(section)) }
        Button("Edit Members", systemImage: "person.2") { prompt(.members(section)) }
        if open != nil { Button("Edit Sections", systemImage: "list.bullet") { prompt(.editSections) } }
        Divider()
        Button("Delete Section", systemImage: "trash", role: .destructive) { prompt(.delete(section)) }
    }
}

/// A question or sheet about sections, from wherever sections change.
enum SimpleBotsSectionPrompt: Equatable {
    /// New Section, with these members (row IDs) picked already.
    case new(picked: Set<String>)
    case members(FleetSection)
    case rename(FleetSection)
    case delete(FleetSection)
    case editSections
}

/// The sheets of `SimpleBotsSectionPrompt`.
private enum SimpleBotsSectionSheet: Identifiable {
    case new(Set<String>)
    case members(FleetSection)
    case editSections

    var id: String {
        switch self {
        case .new: "new"
        case .members(let section): "members." + section.id
        case .editSections: "edit"
        }
    }
}

/// What the sections sheets work on: the sections, every bot and group chat that can go in one, and
/// how to change them.
@MainActor
struct SimpleBotsSectionsModel {
    let editor: SimpleBotsSectionEditor
    /// Bots and group chats that can go in a section here (not hidden), in the home's order.
    let candidates: [SimpleBotsItem]
    /// Every computer shown: each computer's name, so the members sheet lists them by computer.
    var hostNames: [UUID: String]? = nil

    var sections: [FleetSection] { editor.fleet.sections }
    var sectioning: SimpleBotsSectioning { editor.sectioning }

    func members(of sectionID: String) -> [SimpleBotsItem] {
        let sectioning = sectioning
        return candidates.filter { sectioning.section(of: $0.kind)?.id == sectionID }
    }

    func countText(of sectionID: String) -> String {
        let members = members(of: sectionID)
        let bots = members.count(where: { if case .bot = $0.kind { true } else { false } })
        return SimpleBotsSectionCard.countText(bots: bots, groups: members.count - bots)
    }

    /// Delete's question: what stays, by name for a few.
    func deleteMessage(_ sectionID: String) -> String {
        let names = members(of: sectionID).map(\.name)
        switch names.count {
        case 0: return String(localized: "It has no bots or group chats.")
        case 1: return String(localized: "\(names[0]) stays. It moves to No section.")
        case 2...3: return String(localized: "\(ListFormatter.localizedString(byJoining: names)) stay. They move to No section.")
        default: return String(localized: "Its \(names.count) bots and group chats stay. They move to No section.")
        }
    }
}

/// The sheets and questions sections need, for the view that changes them.
struct SimpleBotsSectionPrompts: ViewModifier {
    @Binding var prompt: SimpleBotsSectionPrompt?
    let model: SimpleBotsSectionsModel?
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .bighelpSheet(item: sheet) { sheet in
                if let model {
                    switch sheet {
                    case .new(let picked):
                        SimpleBotsSectionMembersSheet(model: model, section: nil, picked: picked)
                            .bighelpSheetSize(.large)
                    case .members(let section):
                        SimpleBotsSectionMembersSheet(model: model, section: section)
                            .bighelpSheetSize(.large)
                    case .editSections:
                        SimpleBotsEditSectionsSheet(model: model)
                            .bighelpSheetSize(.standard)
                    }
                }
            }
            .onChange(of: prompt) { _, prompt in
                if case .rename(let section)? = prompt { name = section.name }
            }
            .alert("Rename Section", isPresented: isPrompting { if case .rename = $0 { true } else { false } }) {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("simple-bots.section.rename.field")
                Button("Cancel", role: .cancel) { prompt = nil }
                Button("Rename") {
                    if case .rename(let section)? = prompt, let model {
                        let name = name
                        Task { await model.editor.rename(section.id, to: name) }
                    }
                    prompt = nil
                }
                .disabled(FleetSection.cleanName(name) == nil)
            }
            .alert(deleteTitle, isPresented: isPrompting { if case .delete = $0 { true } else { false } }) {
                Button("Delete Section", role: .destructive) {
                    if case .delete(let section)? = prompt, let model {
                        Task { await model.editor.delete(section.id) }
                    }
                    prompt = nil
                }
                .accessibilityIdentifier("simple-bots.section.delete.confirm")
                Button("Cancel", role: .cancel) { prompt = nil }
            } message: {
                if case .delete(let section)? = prompt, let model { Text(model.deleteMessage(section.id)) }
            }
    }

    private var deleteTitle: String {
        guard case .delete(let section)? = prompt else { return "" }
        return String(localized: "Delete “\(section.name)”?")
    }

    private func isPrompting(_ matches: @escaping (SimpleBotsSectionPrompt) -> Bool) -> Binding<Bool> {
        Binding(get: { prompt.map(matches) ?? false }, set: { if !$0, prompt.map(matches) == true { prompt = nil } })
    }

    private var sheet: Binding<SimpleBotsSectionSheet?> {
        Binding(get: {
            switch prompt {
            case .new(let picked)?: .new(picked)
            case .members(let section)?: .members(section)
            case .editSections?: .editSections
            default: nil
            }
        }, set: { if $0 == nil, sheetShowing { prompt = nil } })
    }

    private var sheetShowing: Bool {
        switch prompt {
        case .new?, .members?, .editSections?: true
        default: false
        }
    }
}

extension View {
    /// A bot on another gateway draws its characters and marks from that gateway's.
    @ViewBuilder
    func companionScope(_ scope: String?) -> some View {
        if let scope { environment(\.companionAgentScope, scope) } else { self }
    }
}
