import Foundation

/// Something another app shared with bighelp (#922), kept on the device until the person sends it
/// from a chat's message box or deletes it.
///
/// The share sheet only saves. It has no sign-in and no network: iOS doesn't let a share extension
/// open its app (`NSExtensionContext.open` works only for Today and iMessage extensions), so the
/// person opens bighelp, picks the agent and chat there, and the shared things go into that chat's
/// message box. Send then works as for anything typed or attached there: the AI data agreement,
/// the chat's own computer and agent, and the usual attachment limits all apply. Foundation only,
/// so the app, the extension and the Linux test run share it.
struct PendingShare: Codable, Equatable, Identifiable, Sendable {
    struct File: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case image, file }

        /// The name the message box shows and sends ("Sunset.heic").
        let name: String
        let kind: Kind
        /// The uniform type it was shared as (`public.heic`), so the app reads it as what it is.
        let typeIdentifier: String
        let mimeType: String
        let byteCount: Int
        /// Its file in the share's folder (`files/<index>`), never taken from `name`.
        let storedName: String
    }

    static let currentVersion = 1

    let version: Int
    let id: String
    let createdAt: Date
    /// The text the other app shared, exactly as it came. Longer text travels as a file instead.
    let text: String
    /// Web links, in the order they came.
    let links: [String]
    /// What the person typed in the share sheet, if anything.
    let note: String
    let files: [File]

    var byteCount: Int { files.reduce(0) { $0 + $1.byteCount } }

    /// The words the message box takes: the person's note, then what was shared, then any link the
    /// text doesn't already hold (Safari shares a page's link beside its title).
    var composerText: String {
        var parts: [String] = []
        if Self.hasWords(note) { parts.append(note) }
        if Self.hasWords(text) { parts.append(text) }
        for link in links where !text.contains(link) { parts.append(link) }
        return parts.joined(separator: "\n\n")
    }

    /// The draft with this share's words added below what's there, the way a board's Ask does.
    /// Nil when there is nothing to add, or when the draft already holds them: a chat whose draft
    /// came back after a relaunch must not get the same words twice.
    static func draft(_ draft: String, adding block: String) -> String? {
        guard hasWords(block), !draft.contains(block) else { return nil }
        return draft.isEmpty ? block : draft + "\n\n" + block
    }

    /// Whether a message leaving the box still holds any of this share: one of the files it became
    /// there (`landedIDs`), or a line of its words. One that holds none was taken out by the person.
    func isCarried(byText message: String, attachmentIDs: Set<String>, landedIDs: Set<String>) -> Bool {
        if !landedIDs.isDisjoint(with: attachmentIDs) { return true }
        return composerText.split(whereSeparator: \.isNewline).contains { line in
            let words = line.trimmingCharacters(in: .whitespaces)
            return !words.isEmpty && message.contains(words)
        }
    }

    static func hasWords(_ text: String) -> Bool {
        text.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func newID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// Where the person chose to send a share, so a share they put in a chat and didn't send says so
/// when bighelp opens again.
struct PendingSharePlacement: Codable, Equatable, Sendable {
    /// What bighelp can say about it after a relaunch.
    enum Recovery: Equatable, Sendable {
        /// Never handed to Hermes: still in a message box, or waiting in a chat in memory.
        case notSent
        /// Handed to Hermes in a message whose answer never came: check that chat before sending again.
        case maybeSent
    }

    var destination: PendingShareDestination
    /// The agent's name when it was chosen, for "You put this in a chat with Juno".
    let agentName: String
    let placedAt: Date
    /// The message it left its message box in, until Hermes takes that message.
    var submission: PendingShareSubmission? = nil

    var recovery: Recovery {
        switch submission?.state {
        case nil, .staged?: .notSent
        case .sending?, .unconfirmed?, .accepted?: .maybeSent
        }
    }
}

/// The message carrying a share: its own id, made when it left the message box and never reused,
/// and its row in the chat.
struct PendingShareSubmission: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// Waiting in the chat (for its connection, or to try its files again). Such messages live
        /// only in memory, so after a relaunch it was never sent.
        case staged
        /// Handed to Hermes; its answer hasn't come. Saved before the message goes.
        case sending
        /// Its send ended without Hermes confirming it either way.
        case unconfirmed
        /// Hermes took it. The share is spent: never listed again, and deleted as soon as it can be.
        case accepted
    }

    let id: UUID
    let conversationID: String
    let messageID: String
    let state: State
    let at: Date

    func with(_ state: State, at date: Date) -> PendingShareSubmission {
        PendingShareSubmission(id: id, conversationID: conversationID, messageID: messageID, state: state, at: date)
    }
}

/// A chat on one computer: its agent, and the chat or a new one.
struct PendingShareDestination: Codable, Equatable, Hashable, Sendable {
    enum Problem: Equatable, Sendable {
        /// Another computer, or none, is in use now.
        case computerChanged
        case agentGone
        case chatGone
    }

    /// The computer's cache scope (`WorkspaceOwner.cacheScopeID`), never its address.
    let scope: String
    let agentID: String
    /// Nil for a new chat until Hermes has made it (`bound(to:)`).
    let sessionID: String?

    static let localCanvasPrefix = "local-draft:"

    /// Only the chat it names takes it: a new chat once Hermes has made it, never the local canvas a
    /// new chat shows first, which passes on only its text.
    func isTaken(by conversationID: String) -> Bool {
        guard let sessionID, !conversationID.hasPrefix(Self.localCanvasPrefix) else { return false }
        return sessionID == conversationID
    }

    /// The new chat Hermes made for it.
    func bound(to sessionID: String) -> PendingShareDestination {
        PendingShareDestination(scope: scope, agentID: agentID, sessionID: sessionID)
    }

    /// Why it can't be used as it is now. A share never moves to another computer, agent or chat by
    /// itself: the person picks again.
    func problem(currentScope: String?, agentIDs: Set<String>, sessionIDs: Set<String>) -> Problem? {
        guard currentScope == scope else { return .computerChanged }
        guard agentIDs.contains(agentID) else { return .agentGone }
        if let sessionID, !sessionIDs.contains(sessionID) { return .chatGone }
        return nil
    }
}

/// How much a share and the inbox may hold. A share that doesn't fit is refused whole, with why;
/// nothing is ever half saved or dropped without saying.
struct PendingShareLimits: Equatable, Sendable {
    /// The message box takes up to 10 photos and files (`ComposerAttachmentDrop.maximumItems`).
    var files = 10
    /// The most a photo can be before it's prepared (`ImageAttachmentPreparer.maximumInputBytes`).
    var imageBytes = 64 * 1_024 * 1_024
    /// The most a file can be (`BigFileUploads.maximumBytes`, the plugin's own limit).
    var fileBytes = 256 * 1_024 * 1_024
    var shareBytes = 512 * 1_024 * 1_024
    /// Shared text over this goes as "Shared text.txt", so a long article isn't pasted in whole.
    var inlineTextBytes = 32 * 1_024
    /// All the text in one share, held in memory while it's saved.
    var textBytes = 4 * 1_024 * 1_024
    var noteBytes = 8 * 1_024
    var links = 4
    var linkBytes = 4 * 1_024
    /// Shares waiting at once, and what they may hold between them. A full inbox refuses the next
    /// share; it never makes room by deleting one.
    var shares = 16
    var inboxBytes = 1_024 * 1_024 * 1_024
    var manifestBytes = 128 * 1_024

    static let standard = PendingShareLimits()

    func maximumBytes(for kind: PendingShare.File.Kind) -> Int {
        kind == .image ? imageBytes : fileBytes
    }
}

enum PendingShareError: Error, Equatable, Sendable {
    case nothingToShare
    case tooManyFiles(limit: Int)
    case fileTooLarge(name: String, limit: Int)
    case shareTooLarge(limit: Int)
    case textTooLong(limit: Int)
    case noteTooLong(limit: Int)
    case tooManyLinks(limit: Int)
    case unreadable(name: String)
    case emptyFile(name: String)
    /// `shares` are waiting already.
    case inboxFull(shares: Int)
    case storageUnavailable
    case cancelled
    /// Sent, deleted or never saved.
    case gone
    /// The draft was saved or thrown away already.
    case finished
}

extension PendingShare {
    static let textFileName = "Shared text"

    /// A name the message box and the computer both take: the shared name's last part with no
    /// control characters, separators or leading dots, at most 180 characters with its extension,
    /// the type's extension when it has none, and a number when the share has that name already.
    static func fileName(suggested: String?, kind: File.Kind, preferredExtension: String?,
                         taken: Set<String>) -> String {
        var name = (suggested ?? "").split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        name = String(String.UnicodeScalarView(name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        }))
        name = name.replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        var stem = name
        var ext = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let candidate = String(name[name.index(after: dot)...])
            if (1...16).contains(candidate.count), candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                stem = String(name[..<dot]).trimmingCharacters(in: .whitespacesAndNewlines)
                ext = candidate
            }
        }
        if ext.isEmpty, let preferred = preferredExtension, (1...16).contains(preferred.count),
           preferred.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            ext = preferred
        }
        if stem.isEmpty { stem = kind == .image ? "Shared picture" : "Shared file" }

        let suffix = ext.isEmpty ? "" : "." + ext
        // The number and the extension keep their room; only the stem is shortened, so each number
        // gives a name of its own and the search ends.
        func named(_ number: Int?) -> String {
            let tail = (number.map { " \($0)" } ?? "") + suffix
            let room = max(1, 180 - tail.count)
            let kept = stem.count > room ? String(stem.prefix(room)).trimmingCharacters(in: .whitespaces) : stem
            return (kept.isEmpty ? "Shared" : kept) + tail
        }
        let lowered = Set(taken.map { $0.lowercased() })
        var candidate = named(nil)
        var number = 2
        while lowered.contains(candidate.lowercased()) {
            candidate = named(number)
            number += 1
        }
        return candidate
    }

    /// The rules `ChatAttachment` and `BigFileStore.validate` apply to a name.
    static func isValidFileName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...180).contains(name.count) && trimmed == name && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\\") && name != ".."
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func isValidMIMEType(_ mime: String) -> Bool {
        (3...120).contains(mime.count) && mime.contains("/")
            && mime.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "!#$&^_.+-/".contains($0)) }
    }

    static func isValidTypeIdentifier(_ identifier: String) -> Bool {
        (1...200).contains(identifier.utf8.count)
            && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
    }

    /// An `http` or `https` link with a host, no longer than the limit.
    static func webLink(_ text: String, limits: PendingShareLimits) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...limits.linkBytes).contains(trimmed.utf8.count),
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        return trimmed
    }
}
