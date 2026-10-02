import Foundation

enum MentionTarget: Equatable, Sendable {
    case everyone
    case human
    case member(String)
}

enum MentionError: Error, Equatable {
    case unknown(String)
    case ambiguous(String)
}

enum MentionParser {
    private static let normalizationLocale = Locale(identifier: "en_US_POSIX")
    private static let handleCharacterSet = CharacterSet.alphanumerics.union(.nonBaseCharacters)

    static func isHandleCharacter(_ character: Character) -> Bool {
        !character.unicodeScalars.isEmpty && character.unicodeScalars.allSatisfy(isHandleScalar)
    }

    static func normalizedForMatching(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .lowercased(with: normalizationLocale)
            .precomposedStringWithCanonicalMapping
    }

    static func targets(in text: String, room: BotModeRoom) throws -> [String] {
        try agentTargets(from: mentionTargets(in: text, room: room), room: room)
    }

    static func mentionTargets(in text: String, room: BotModeRoom) throws -> [MentionTarget] {
        let mentions = try parsedMentions(in: text)
        guard !mentions.isEmpty else { return [.everyone] }
        var handles: [String: String] = [:]
        for member in room.members {
            let handle = normalizedForMatching(member.handle)
            guard handles[handle] == nil else { throw MentionError.ambiguous(handle) }
            handles[handle] = member.profileID
        }
        var selected = Set<String>()
        var hasAgentTarget = false
        var hasHumanTarget = false
        for mention in mentions {
            switch mention {
            case "everyone", "all":
                hasAgentTarget = true
                selected.formUnion(room.memberIDs)
            case "user":
                hasHumanTarget = true
            default:
                guard let memberID = handles[mention] else { throw MentionError.unknown(mention) }
                hasAgentTarget = true
                selected.insert(memberID)
            }
        }
        var targets: [MentionTarget] = []
        if hasHumanTarget { targets.append(.human) }
        if hasAgentTarget {
            if selected.count == room.memberIDs.count {
                targets.append(.everyone)
            } else {
                targets.append(contentsOf: room.memberIDs.filter(selected.contains).map(MentionTarget.member))
            }
        }
        return targets
    }

    private static func agentTargets(from targets: [MentionTarget], room: BotModeRoom) -> [String] {
        var selected = Set<String>()
        for target in targets {
            switch target {
            case .everyone: selected.formUnion(room.memberIDs)
            case .member(let memberID): selected.insert(memberID)
            case .human: continue
            }
        }
        return room.memberIDs.filter(selected.contains)
    }

    struct Token {
        let handle: String
        let range: NSRange
    }

    private static func parsedMentions(in text: String) throws -> [String] {
        try tokens(in: text).map(\.handle)
    }

    /// Keep ranges in the original UTF-16 text, including decomposed names.
    static func tokens(in text: String, rejectingInvalid: Bool = true) throws -> [Token] {
        let scalars = Array(text.unicodeScalars)
        var offsets = [0]
        var utf16Offset = 0
        for scalar in scalars {
            utf16Offset += scalar.utf16.count
            offsets.append(utf16Offset)
        }
        var ignored = Set<Int>()
        var index = 0
        while index < scalars.count {
            if starts(scalars, at: index, with: "```") {
                let end = nextFence(in: scalars, after: index + 3) ?? scalars.count
                ignored.formUnion(index..<min(end + 3, scalars.count))
                index = end + 3
            } else if scalars[index] == "`" {
                let end = scalars[(index + 1)...].firstIndex(of: "`") ?? scalars.count
                ignored.formUnion(index..<min(end + 1, scalars.count))
                index = end + 1
            } else {
                index += 1
            }
        }

        var mentions: [Token] = []
        index = 0
        while index < scalars.count {
            guard scalars[index] == "@", !ignored.contains(index), isMentionStart(scalars, at: index) else {
                index += 1
                continue
            }
            let start = index + 1
            guard start < scalars.count, !isMentionEnd(scalars, at: start) else {
                index += 1
                continue
            }
            var end = start
            while end < scalars.count, isHandleScalar(scalars[end]) { end += 1 }
            guard end > start, isMentionEnd(scalars, at: end) else {
                if rejectingInvalid {
                    throw MentionError.unknown(unresolvedToken(in: scalars, after: index))
                }
                index = max(end, index + 1)
                continue
            }
            mentions.append(Token(
                handle: normalizedForMatching(String(String.UnicodeScalarView(scalars[start..<end]))),
                range: NSRange(location: offsets[index], length: offsets[end] - offsets[index])
            ))
            index = end
        }
        return mentions
    }

    private static func starts(_ scalars: [UnicodeScalar], at index: Int, with value: String) -> Bool {
        let needle = Array(value.unicodeScalars)
        return index + needle.count <= scalars.count && Array(scalars[index..<(index + needle.count)]) == needle
    }

    private static func nextFence(in scalars: [UnicodeScalar], after index: Int) -> Int? {
        var cursor = index
        while cursor < scalars.count {
            if starts(scalars, at: cursor, with: "```") { return cursor }
            cursor += 1
        }
        return nil
    }

    private static func isMentionStart(_ scalars: [UnicodeScalar], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = scalars[index - 1]
        return CharacterSet.whitespacesAndNewlines.contains(previous) || "([{'\"".unicodeScalars.contains(previous)
    }

    private static func isMentionEnd(_ scalars: [UnicodeScalar], at index: Int) -> Bool {
        guard index < scalars.count else { return true }
        let next = scalars[index]
        return CharacterSet.whitespacesAndNewlines.contains(next) || ".,;:!?)]}\"'".unicodeScalars.contains(next)
    }

    private static func isHandleScalar(_ scalar: UnicodeScalar) -> Bool {
        handleCharacterSet.contains(scalar) || scalar == "-" || scalar == "_"
    }

    private static func unresolvedToken(in scalars: [UnicodeScalar], after mentionIndex: Int) -> String {
        let start = mentionIndex + 1
        var end = start
        while end < scalars.count, !isMentionEnd(scalars, at: end) { end += 1 }
        return normalizedForMatching(String(String.UnicodeScalarView(scalars[start..<end])))
    }
}
