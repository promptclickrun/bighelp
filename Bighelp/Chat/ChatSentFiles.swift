import SwiftUI
import UIKit

/// The app's note beside a big file it sent (`ChatBigFile.agentNote`), as Hermes keeps it:
/// "[Video attached: Trip.mov (80 MB, 1 min 12 s, 1920×1080)]" or "[File attached: a.zip (120 MB)]".
struct ChatSentFileNote: Equatable {
    let fileName: String
    let details: [String]

    init?(_ line: String) {
        guard line.hasPrefix("[Video attached: ") || line.hasPrefix("[File attached: "),
              let match = line.trimmingCharacters(in: .whitespaces)
                .wholeMatch(of: /\[(?:Video|File) attached: (.+) \(([^()]+)\)\]/) else { return nil }
        fileName = String(match.1)
        details = match.2.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Size and length for the file's line: "80 MB · 1 min 12 s".
    var meta: String { details.prefix(2).joined(separator: " · ") }
}

/// A file the person sent, as the chat shows it: a line on the rail that opens it in Files.
struct ChatSentFile: Equatable, Identifiable {
    /// Where the file is on the agent's computer. Shown only on a long press.
    let path: String
    let name: String
    let meta: String?
    let isVideo: Bool
    var id: String { path }
}

/// Hermes saves a turn the way its model got it: for `@file:` references, the person's text, then
/// "--- Attached Context ---" with a block for each file (for a video: its type, size, where it is
/// on disk and what to do with it), after any "--- Context Warnings ---". That's for the model, never
/// the chat. A reference is relative to the chat's folder when the file is in it, so its block's
/// "available on disk at" path is kept: it's where Files opens the file.
enum HermesAttachedContext {
    private static let markers = ["\n--- Context Warnings ---\n", "\n--- Attached Context ---\n"]

    static func strip(_ raw: String) -> String {
        guard ChatTextMarker.mayContain("--- Attached Context ---", in: raw)
                || ChatTextMarker.mayContain("--- Context Warnings ---", in: raw),
              let cut = markers.compactMap({ raw.range(of: $0)?.lowerBound }).min() else { return raw }
        var places: [String: String] = [:]
        for line in raw[cut...].components(separatedBy: "\n") where line.hasPrefix("📎 @file:") {
            guard let reference = reference(at: line.dropFirst(2)),
                  let disk = line.firstMatch(of: /available on disk at `([^`\n]+)`/) else { continue }
            places[reference] = String(disk.1)
        }
        let body = raw[..<cut].components(separatedBy: "\n").map { line -> String in
            guard let path = places[line.trimmingCharacters(in: .whitespaces)], path.hasPrefix("/") else { return line }
            return "@file:`" + path + "`"
        }
        return body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The `@file:` token a block starts with, quoted (`@file:`a b.mov``) or up to the first space.
    private static func reference(at text: Substring) -> String? {
        guard text.hasPrefix("@file:") else { return nil }
        let value = text.dropFirst(6)
        if let quote = value.first, ["`", "\"", "'"].contains(quote) {
            guard let end = value.dropFirst().firstIndex(of: quote) else { return nil }
            return String(text[..<value.index(after: end)])
        }
        return String(text.prefix { !$0.isWhitespace })
    }
}

enum ChatSentFiles {
    /// The person's words, and the files the message names on `@file:` lines (with the app's note
    /// after a big file's). The note, the lines and Hermes' attached context never show as text.
    static func split(_ raw: String) -> (text: String, files: [ChatSentFile]) {
        let text = HermesAttachedContext.strip(raw)
        guard ChatTextMarker.mayContain("@file:", in: text) || ChatTextMarker.mayContain(" attached: ", in: text)
        else { return (text, []) }
        var kept: [String] = []
        var files: [ChatSentFile] = []
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            // Relative when Hermes used the file where it was, in the chat's folder (no block to say where).
            if line.hasPrefix("@file:"), let path = DirectHermesFileAttachments.referenceValue(String(line.dropFirst(6))),
               !path.isEmpty, !path.split(separator: "/").contains(".."),
               !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
                let note = index < lines.count ? ChatSentFileNote(lines[index]) : nil
                if note != nil { index += 1 }
                let name = note?.fileName ?? URL(fileURLWithPath: path).lastPathComponent
                files.append(ChatSentFile(path: path, name: name, meta: note?.meta,
                                          isVideo: lines[index - 1].hasPrefix("[Video attached: ")
                                            || ["mp4", "m4v", "mov", "webm"].contains(
                                                URL(fileURLWithPath: path).pathExtension.lowercased())))
            } else if ChatSentFileNote(line) == nil {
                kept.append(line)
            }
        }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), files)
    }
}

private struct ChatOpenSentFileKey: EnvironmentKey {
    static let defaultValue: (@MainActor (ChatSentFile) -> Void)? = nil
}

extension EnvironmentValues {
    /// Opens a file the person sent in the agent's Files; nil where the chat can't.
    var chatOpenSentFile: (@MainActor (ChatSentFile) -> Void)? {
        get { self[ChatOpenSentFileKey.self] }
        set { self[ChatOpenSentFileKey.self] = newValue }
    }
}

/// One sent file as a step on the rail, the look the chat uses for tool activity: its mark, its
/// name and its size or length. A tap opens it in Files; a long press shows where it is.
struct ChatSentFileLine: View {
    let file: ChatSentFile
    @Environment(\.chatOpenSentFile) private var open

    var body: some View {
        Button { open?(file) } label: {
            BighelpActivityStepRow(step: BighelpActivityStep(
                id: file.path, glyph: file.isVideo ? .symbol("film") : .glyph(.doc),
                label: file.isVideo ? "Video" : "File", detail: file.name, meta: file.meta))
                .frame(maxWidth: .infinity, minHeight: BighelpPlatform.isMac ? BighelpTokens.scaled(32) : BighelpTokens.hitTarget,
                       alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(open == nil)
        .bighelpActivityRail()
        .contextMenu {
            Section(file.path) {
                Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = file.path }
                if let open { Button("Open in Files", systemImage: "folder") { open(file) } }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([file.name, file.meta].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(open == nil ? "" : "Opens it in Files.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("chat.sent-file")
    }
}

/// A file over 8 MB on its way (Colt's pick, #721): a ring around its mark fills as the pieces
/// arrive and the size counts up; a file that didn't go says why, with Try again.
struct BigFileUploadTile: View {
    let file: ChatBigFile
    private var board: BigFileUploadBoard { .shared }
    @BighelpThemeReader private var theme

    var body: some View {
        let state = board.state(for: file.id)
        VStack(alignment: .trailing, spacing: BighelpTokens.space8) {
            HStack(spacing: BighelpTokens.space12) {
                mark(state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.fileName)
                        .font(.bighelp(.subheadline, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(status(state))
                        .font(.bighelp(.caption))
                        .monospacedDigit()
                        .opacity(0.72)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.outgoingMessageForeground)
            .padding(.horizontal, BighelpTokens.space12)
            .padding(.vertical, BighelpTokens.space8 + 2)
            .frame(minWidth: 210, maxWidth: 320, alignment: .leading)
            .background(theme.outgoingMessageBackground, in: .rect(cornerRadius: 16, style: .continuous))
            if case .failed = state {
                Button("Try again") { board.retry(file.id) }
                    .font(.bighelp(.footnote, weight: .semibold))
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("chat.big-file.retry")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.big-file")
    }

    private func mark(_ state: BigFileUploadBoard.State?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.outgoingMessageForeground.opacity(0.12))
            if case .failed = state {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.danger)
            } else {
                Image(systemName: file.video != nil ? "film" : "doc")
                    .font(.system(size: 16, weight: .semibold))
                Circle()
                    .stroke(theme.outgoingMessageForeground.opacity(0.25), lineWidth: 3)
                    .padding(-3)
                Circle()
                    .trim(from: 0, to: fraction(state))
                    .stroke(theme.outgoingMessageForeground, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(-3)
                    .animation(.easeOut(duration: 0.25), value: fraction(state))
            }
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }

    private func fraction(_ state: BigFileUploadBoard.State?) -> Double {
        guard case .uploading(let sent, let total) = state, total > 0 else { return 0 }
        return Double(sent) / Double(total)
    }

    private func status(_ state: BigFileUploadBoard.State?) -> String {
        switch state {
        case .uploading(let sent, let total):
            BigFileUploadTile.counted(sent, of: total)
        case .failed(let reason):
            reason
        case nil:
            file.sizeAndLength
        }
    }

    /// "34 of 80 MB": both numbers in the larger one's unit.
    static func counted(_ sent: Int, of total: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = total >= 1_000_000_000 ? .useGB : total >= 1_000_000 ? .useMB : .useKB
        formatter.includesUnit = false
        let done = formatter.string(fromByteCount: Int64(sent))
        formatter.includesUnit = true
        return "\(done) of \(formatter.string(fromByteCount: Int64(total)))"
    }
}
