import Foundation
import Testing
@testable import Bighelp

/// A bot page's ⋯ menu (`BotProfileMenu`) and its About rows (`BotProfileAbout`): what each offers,
/// in what order, from what the page's context can do.
struct BotProfileActionsTests {
    /// Everything the shell can hand a page for a bot that isn't the primary one.
    static let everything = BotProfileMenuCapabilities(
        isOnComputerInUse: true, isPrimary: false, offersNewChat: true, offersChats: true,
        offersPinning: true, isPinned: false, canPinAnother: true, offersShortcuts: true,
        offersDuplicate: true, offersEditDetails: true, showsRoutinesToggle: true,
        offersManage: true, offersDelete: true, isDefaultBot: false, isDeleting: false)

    @Test func everythingInOrderWithDeleteLast() {
        #expect(BotProfileMenu.actions(Self.everything) == [
            .message, .newChat, .chats, .makePrimary, .pin, .shortcuts, .duplicate, .editDetails,
            .showRoutines, .manageBots, .delete,
        ])
    }

    @Test func groupsRunBotThenManageThenDelete() {
        let groups = BotProfileMenu.actions(Self.everything).map(\.group)
        #expect(groups == groups.sorted())
        #expect(groups.last == .delete)
    }

    @Test func thePrimaryBotOffersNoMakePrimary() {
        var can = Self.everything
        can.isPrimary = true
        #expect(!BotProfileMenu.actions(can).contains(.makePrimary))
    }

    @Test func aPinnedBotOffersUnpinAndAFullPinListOffersNoPin() {
        var can = Self.everything
        can.isPinned = true
        let pinned = BotProfileMenu.actions(can)
        #expect(pinned.contains(.unpin) && !pinned.contains(.pin))

        can.isPinned = false
        can.canPinAnother = false
        let full = BotProfileMenu.actions(can)
        #expect(!full.contains(.pin) && !full.contains(.unpin))
    }

    @Test func theDefaultBotCantBeDeletedButCanBeManaged() {
        var can = Self.everything
        can.isDefaultBot = true
        let actions = BotProfileMenu.actions(can)
        #expect(!actions.contains(.delete))
        #expect(actions.last == .manageBots)
    }

    @Test func aDeletionUnderWayHidesDelete() {
        var can = Self.everything
        can.isDeleting = true
        #expect(!BotProfileMenu.actions(can).contains(.delete))
    }

    @Test func noCloneClientOffersNoDuplicate() {
        var can = Self.everything
        can.offersDuplicate = false
        #expect(!BotProfileMenu.actions(can).contains(.duplicate))
    }

    @Test func anotherComputersBotOffersNothingUntilItsComputerIsInUse() {
        var can = Self.everything
        can.isOnComputerInUse = false
        #expect(BotProfileMenu.actions(can).isEmpty)
    }

    @Test func aBareContextOffersMessageAndMakePrimaryOnly() {
        #expect(BotProfileMenu.actions(BotProfileMenuCapabilities()) == [.message, .makePrimary])
    }

    @Test func showRoutinesKeepsItsIdentifier() {
        #expect(BotProfileAction.showRoutines.identifier == "simple-bots.profile.show-routines")
        #expect(BotProfileAction.delete.identifier == "simple-bots.profile.more.delete")
    }

    // MARK: About

    @Test func editableRowsShowTheirValues() {
        let rows = BotProfileAbout.rows(name: "Mina", role: "Travel planner", summary: "  ", handle: "mina",
                                        canEdit: true, unavailableReason: "Not on this computer")
        #expect(rows.map(\.kind) == [.field(.name), .field(.role), .field(.summary), .handle])
        #expect(rows.map(\.detail) == ["Mina", "Travel planner", "Not set", "@mina"])
        #expect(rows.map(\.isEditable) == [true, true, true, false])
    }

    @Test func aComputerThatWontTakeEditsSaysWhyOnEachField() {
        let reason = "This host doesn't support that."
        let rows = BotProfileAbout.rows(name: "Mina", role: "Travel planner", summary: "Plans trips", handle: "mina",
                                        canEdit: false, unavailableReason: reason)
        let fields = rows.filter { $0.kind != .handle }
        #expect(fields.allSatisfy { !$0.isEditable && $0.detail == reason })
        // The handle is only ever read, so it keeps its value.
        #expect(rows.last?.detail == "@mina")
    }

    @Test func withoutAReasonTheRowsSayTheComputerWontLetTheAppChangeTheBot() {
        let rows = BotProfileAbout.rows(name: "Mina", role: "", summary: "", handle: "mina",
                                        canEdit: false, unavailableReason: nil)
        #expect(rows.first?.detail == String(localized: "This computer doesn't let the app change this bot."))
    }
}
