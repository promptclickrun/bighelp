import Foundation
import Testing
@testable import Bighelp

struct MentionParserTests {
    @Test func displayRangesPreserveOriginalUnicodeAndIgnoreMalformedTokens() throws {
        let source = "👋🏽 @cafe\u{301}, @missing/path then @all!"
        let tokens = try MentionParser.tokens(in: source, rejectingInvalid: false)
        #expect(tokens.map(\.handle) == ["café", "all"])
        #expect(tokens.map { (source as NSString).substring(with: $0.range) } == ["@cafe\u{301}", "@all"])
        #expect(throws: MentionError.unknown("missing/path")) {
            try MentionParser.tokens(in: source)
        }
    }

    @Test func noMentionTargetsAllButUnknownMentionRejects() throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research"])

        #expect(try MentionParser.targets(in: "Give me an update", room: room) == ["finance", "research"])
        #expect(throws: MentionError.unknown("missing")) {
            try MentionParser.targets(in: "Ask @missing", room: room)
        }
    }

    @Test func sharedLexerAcceptsUnderscoreHandleAndDispatchResolvesIt() throws {
        let room = try BotModeRoom(
            id: "underscore-room",
            members: [
                BotModeMember(profileID: "foo", handle: "foo_bar", sessionID: "hidden-foo"),
                BotModeMember(profileID: "research", handle: "research", sessionID: "hidden-research")
            ]
        )

        #expect(MentionParser.isHandleCharacter("_"))
        #expect(try MentionParser.targets(in: "Ask @foo_bar privately", room: room) == ["foo"])
    }

    @Test func decomposedMentionMatchesPrecomposedHandle() throws {
        let room = try BotModeRoom(
            id: "unicode-room",
            members: [
                BotModeMember(profileID: "cafe", handle: "café", sessionID: "hidden-cafe")
            ]
        )

        #expect(try MentionParser.targets(in: "Ask @cafe\u{301}", room: room) == ["cafe"])
    }

    @Test func explicitInvalidTokenRejectsInsteadOfBroadcasting() throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research"])

        #expect(throws: MentionError.unknown("missing/name")) {
            try MentionParser.targets(in: "Ask @missing/name", room: room)
        }
    }

    @Test func handlesAreCaseInsensitiveDeduplicatedAndOrderedByRoster() throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research", "travel"])

        #expect(
            try MentionParser.targets(
                in: "Ask @TRAVEL, then @finance and @travel again.",
                room: room
            ) == ["finance", "travel"]
        )
    }

    @Test func specialMentionsResolveEveryoneAndUserOnlyTargetsNoAgent() throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research"])

        #expect(try MentionParser.targets(in: "@all status", room: room) == ["finance", "research"])
        #expect(try MentionParser.targets(in: "@everyone status", room: room) == ["finance", "research"])
        #expect(try MentionParser.targets(in: "@user decide", room: room).isEmpty)
    }

    @Test func mixedUserAndAgentMentionsRetainTheHumanTarget() throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research"])

        #expect(try MentionParser.mentionTargets(in: "@user ask @finance", room: room) == [.human, .member("finance")])
        #expect(try MentionParser.mentionTargets(in: "@user ask @all", room: room) == [.human, .everyone])
        #expect(try MentionParser.targets(in: "@user ask @finance", room: room) == ["finance"])
    }

    @Test func codeURLsAndEmailMentionsAreInertAndPunctuationTerminatesHandles() throws {
        let room = BotModeRoom.fixture(memberIDs: ["finance", "research"])

        #expect(try MentionParser.targets(in: "`@missing` https://example.test/@missing user@missing.test @research!", room: room) == ["research"])
        #expect(try MentionParser.targets(in: "```\n@missing\n```\n@finance)", room: room) == ["finance"])
        #expect(try MentionParser.targets(in: "Email finance@example.test", room: room) == ["finance", "research"])
    }
}
