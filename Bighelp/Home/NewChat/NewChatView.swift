import SwiftUI

/// What New chat's To row and people list need from the shell. The chat screen draws them over a new
/// chat that has nothing sent yet: the To row in place of the chat's name, the list over the empty
/// messages. One bot is a chat; two to six a group chat.
@MainActor
struct NewChatContext {
    let session: NewChatSession
    /// Every bot that can be picked: the computer in use's, and other computers' while they show.
    let bots: [SimpleBotsBot]
    /// The computers the bots are on, in order, for the list's headers (shown with two or more).
    let hosts: [FleetHost]
    /// Group chats the person has, at the bottom of the list.
    let groups: [SimpleBotsGroup]
    let rules: NewChatGroupRules
    /// Which bots are working or need you; nil leaves the state lines out.
    var activity: BotChatActivityStore? = nil
    var activitySource: BotChatActivitySource? = nil
    /// This computer's bots aren't read yet: a still placeholder instead of the empty line.
    var isLoading = false
    /// The recipients changed (a pick, a chip's ×): the shell starts the blank chat for one bot.
    let onRecipientsChanged: ([SimpleBotsBot]) -> Void
    let onOpenGroup: (SimpleBotsGroup) -> Void
    /// The empty list's one action; nil when this computer can't make bots.
    var onNewBot: (() -> Void)? = nil
}

/// The To row and the people list stacked, as the chat screen places them over a new chat.
struct NewChatView: View {
    let context: NewChatContext

    var body: some View {
        VStack(spacing: 0) {
            NewChatToRow(context: context)
            NewChatPeopleList(context: context)
        }
    }
}

// MARK: The To row

/// "To:", a chip for each picked bot (its × takes it out), then a field that filters the people list.
/// A refused pick says why in one line under it.
struct NewChatToRow: View {
    let context: NewChatContext
    @FocusState private var isFocused: Bool
    @BighelpThemeReader private var theme

    var body: some View {
        @Bindable var session = context.session
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: BighelpTokens.space8) {
                        Text("To:")
                            .font(.bighelp(.body))
                            .foregroundStyle(theme.secondaryText)
                        ForEach(session.recipients) { bot in
                            chip(bot)
                        }
                        TextField("Add a bot", text: $session.query)
                            .font(.bighelp(.body))
                            .foregroundStyle(theme.primaryText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($isFocused)
                            .frame(minWidth: BighelpTokens.scaled(120))
                            .bighelpMacFieldArea()
                            .onSubmit(pickOnlyMatch)
                            .accessibilityIdentifier("new-chat.to.field")
                            .id("field")
                    }
                    .padding(.horizontal, BighelpTokens.space16)
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
                .scrollIndicators(.hidden)
                // The field stays in view as chips are added.
                .onChange(of: session.recipients.count) { _, _ in proxy.scrollTo("field", anchor: .trailing) }
            }
            if let refusal = session.refusal {
                Text(refusal.message)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, BighelpTokens.space16)
                    .accessibilityIdentifier("new-chat.to.refusal")
            }
            Rectangle().fill(theme.separator).frame(height: BighelpTokens.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("new-chat.to")
    }

    private func chip(_ bot: SimpleBotsBot) -> some View {
        Button {
            context.session.remove(bot)
            context.onRecipientsChanged(context.session.recipients)
        } label: {
            HStack(spacing: BighelpTokens.space4) {
                SimpleBotFace(agentID: bot.profileID, name: bot.name, imageURL: bot.imageURL,
                              size: BighelpTokens.scaled(24))
                    .companionScope(bot.faceScope)
                Text(bot.name)
                    .font(.bighelp(.subheadline).weight(.medium))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.bighelp(.caption2).weight(.bold))
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(.leading, BighelpTokens.space4)
            .padding(.trailing, BighelpTokens.space8)
            .frame(minHeight: BighelpTokens.scaled(34))
            .bighelpSurface(.capsuleControl, isInteractive: true)
            .contentShape(.capsule)
        }
        .bighelpPlainButtonStyle(.capsule)
        .accessibilityLabel(bot.name)
        .accessibilityHint("Takes this bot out of the chat.")
        .accessibilityIdentifier("new-chat.to.chip.\(bot.id)")
    }

    /// Return picks the one bot the field matches, as Messages does.
    private func pickOnlyMatch() {
        let session = context.session
        let matches = context.bots.filter { bot in
            NewChatRecipients.matches(bot, query: session.query) && !session.recipients.contains { $0.id == bot.id }
        }
        guard !session.query.isEmpty, matches.count == 1 else { return }
        if session.toggle(matches[0], rules: context.rules) { context.onRecipientsChanged(session.recipients) }
        isFocused = true
    }
}

// MARK: The people list

/// The bots, by computer when two or more show, then the group chats. Picked bots carry a check;
/// a bot that can't join the pick shows dimmed, and a tap on it says why. The field filters both.
struct NewChatPeopleList: View {
    let context: NewChatContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @BighelpThemeReader private var theme

    var body: some View {
        let session = context.session
        let query = session.query
        let sections = NewChatRecipients.sections(context.bots.filter { NewChatRecipients.matches($0, query: query) },
                                                  hosts: context.hosts, rules: context.rules)
        let groups = context.groups.filter { NewChatRecipients.matches($0, query: query) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if context.bots.isEmpty {
                    if context.isLoading { placeholder } else { empty }
                } else if sections.isEmpty && groups.isEmpty {
                    note("No bots or group chats match.")
                }
                ForEach(sections) { section in
                    if sections.count > 1 { header(section.host?.name ?? String(localized: "Other bots")) }
                    ForEach(section.bots) { bot in
                        NewChatBotRow(bot: bot, isPicked: session.recipients.contains { $0.id == bot.id },
                                      canJoin: NewChatRecipients.canJoin(bot, picked: session.recipients,
                                                                         rules: context.rules),
                                      activity: context.activity) {
                            if session.toggle(bot, rules: context.rules) {
                                context.onRecipientsChanged(session.recipients)
                            }
                        }
                    }
                }
                if !groups.isEmpty {
                    header(String(localized: "Group chats"))
                    ForEach(groups) { group in groupRow(group) }
                }
            }
            .padding(.vertical, BighelpTokens.space8)
            .frame(maxWidth: horizontalSizeClass == .regular ? ChatCanvasLayout.regularLaneMaximumWidth : .infinity)
            .frame(maxWidth: .infinity)
        }
        .dismissesKeyboardOnScroll(true)
        .botChatActivityUpdates(context.activity, source: context.activitySource, isActive: scenePhase == .active)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("new-chat.people")
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.bighelp(.subheadline).weight(.semibold))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.top, BighelpTokens.space16)
            .padding(.bottom, BighelpTokens.space4)
            .accessibilityAddTraits(.isHeader)
    }

    private func groupRow(_ group: SimpleBotsGroup) -> some View {
        Button { context.onOpenGroup(group) } label: {
            SimpleBotsRowLabel(face: AnyView(SimpleBotsGroupFace(members: group.members, size: 56)),
                               title: group.title,
                               preview: group.members.isEmpty ? nil
                                   : ListFormatter.localizedString(byJoining: group.members.map(\.name)),
                               date: group.updatedAt, isUnread: false, isPinned: false)
        }
        .bighelpPlainButtonStyle()
        .accessibilityIdentifier("new-chat.group.\(group.id)")
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            note("No bots on this computer yet.")
            if let onNewBot = context.onNewBot {
                Button("New bot", systemImage: "plus", action: onNewBot)
                    .font(.bighelp(.body).weight(.semibold))
                    .foregroundStyle(theme.action)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .padding(.horizontal, BighelpTokens.space20)
                    .bighelpPlainButtonStyle()
                    .accessibilityIdentifier("new-chat.new-bot")
            }
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.bighelp(.body))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.vertical, BighelpTokens.space12)
    }

    /// Still rows while this computer's bots load: nothing moves.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: BighelpTokens.space16) {
                    Circle().fill(theme.separator.opacity(0.6)).frame(width: 56, height: 56)
                    Capsule().fill(theme.separator.opacity(0.6)).frame(width: 140, height: 14)
                }
                .padding(.horizontal, BighelpTokens.space20)
                .padding(.vertical, BighelpTokens.space12)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A bot in the people list: the Bots view's row (face, name, its state line or role), with a check
/// when picked. Its state is read here, so only this row redraws when it changes.
private struct NewChatBotRow: View {
    let bot: SimpleBotsBot
    let isPicked: Bool
    let canJoin: Bool
    let activity: BotChatActivityStore?
    let onTap: () -> Void
    @BighelpThemeReader private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                SimpleBotsRowLabel(face: AnyView(SimpleBotLiveFace(bot: bot, size: 56, activity: activity)),
                                   title: bot.name, preview: bot.role.isEmpty ? nil : bot.role,
                                   date: nil, isUnread: false, isPinned: false,
                                   activityKey: bot.activityKey, activity: activity)
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.bighelp(.title3))
                    .foregroundStyle(isPicked ? theme.action : theme.tertiaryText)
                    .padding(.trailing, BighelpTokens.space20)
                    .accessibilityHidden(true)
            }
            .opacity(isPicked || canJoin ? 1 : 0.4)
            .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .accessibilityValue(value)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityIdentifier("new-chat.bot.\(bot.id)")
    }

    private var value: String {
        let state = activity?.activity(bot.activityKey)?.accessibilityLabel
        let picked = isPicked ? String(localized: "Selected") : String(localized: "Not selected")
        return [picked, state].compactMap { $0 }.joined(separator: ", ")
    }
}
