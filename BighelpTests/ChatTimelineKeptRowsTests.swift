import Testing
import SwiftUI
import UIKit
@testable import Bighelp

/// The chat keeps rows it has built: scrolling back to a message shows the views it built,
/// and a kept row is drawn again only when it, or its place in a group, changed.
@Suite(.serialized) @MainActor
struct ChatTimelineKeptRowsTests {
    private static let agent = TimelineSender.agent(id: "default", snapshot: .init(name: "Juno"))

    private static func message(_ id: String, _ role: TimelineRole, _ text: String) -> TimelineItem {
        TimelineItem(id: id, role: role, sender: role == .human ? .user(snapshot: .init(name: "You")) : agent,
                     content: .message(text), metadata: .init(delivery: "Delivered"))
    }

    @MainActor private final class Host {
        let window: UIWindow
        let table: ChatTimelineTableView

        init(_ model: ChatModel) async throws {
            let host = UIHostingController(rootView: ChatView(model: model).environment(\.bighelpUIV3Enabled, true))
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(400))
            table = try #require(Self.descendants(host.view, of: ChatTimelineTableView.self).first)
        }

        /// In the rows the table shows (built rows off screen wait hidden in the table).
        func textView(containing text: String) -> UITextView? {
            table.visibleCells.lazy.flatMap { Self.descendants($0, of: UITextView.self) }
                .first { $0.text.contains(text) }
        }

        func cell(containing text: String) -> UITableViewCell? {
            var view: UIView? = textView(containing: text)
            while let current = view, !(current is UITableViewCell) { view = current.superview }
            return view as? UITableViewCell
        }

        func settle() async throws {
            table.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            table.layoutIfNeeded()
        }

        static func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
        }
    }

    @Test func aMessageScrolledAwayAndBackKeepsTheViewsItBuilt() async throws {
        let filler = String(repeating: "Some words to make the message a few lines tall. ", count: 6)
        let items = (0..<40).map { index in
            Self.message("kept-\(index)", index.isMultiple(of: 2) ? .human : .assistant, "Message \(index). \(filler)")
        }
        let model = ChatModel(conversationID: "kept-rows", client: ConversationFixtureClient(), initialItems: items)
        let host = try await Host(model)
        defer { host.window.isHidden = true }
        let latest = try #require(host.textView(containing: "Message 39."))

        host.table.followsTail = false
        host.table.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
        try await host.settle()
        #expect(host.textView(containing: "Message 39.") == nil, "The newest message must be off screen.")
        host.table.scrollToRow(at: IndexPath(row: host.table.numberOfRows(inSection: 0) - 1, section: 0),
                               at: .bottom, animated: false)
        try await host.settle()

        let again = try #require(host.textView(containing: "Message 39."))
        #expect(again === latest, "Coming back must show the text view built before, not build the message again.")
    }

    @Test func aRowBuiltAheadShowsTheViewsItWasBuiltWith() async throws {
        let filler = String(repeating: "Some words to make the message a few lines tall. ", count: 6)
        let items = (0..<40).map { index in
            Self.message("ahead-\(index)", index.isMultiple(of: 2) ? .human : .assistant, "Message \(index). \(filler)")
        }
        let model = ChatModel(conversationID: "rows-ahead", client: ConversationFixtureClient(), initialItems: items)
        let host = try await Host(model)
        defer { host.window.isHidden = true }
        // The chat is still: the rows above are built one at a time.
        try await Task.sleep(for: .seconds(1))
        let visible = Set(host.table.visibleCells.map(ObjectIdentifier.init))
        let ahead = Host.descendants(host.table, of: UITableViewCell.self).filter { !visible.contains(ObjectIdentifier($0)) }
        let built = try #require(ahead.lazy.flatMap { Host.descendants($0, of: UITextView.self) }
            .first { $0.text.contains("Message 30.") }, "Message 30 must be built before it's on screen.")
        #expect(built.bounds.width > 0, "A row built ahead is laid out at the table's width.")

        host.table.followsTail = false
        var shown: UITextView?
        for target in stride(from: host.table.numberOfRows(inSection: 0) - 1, through: 0, by: -1) {
            host.table.scrollToRow(at: IndexPath(row: target, section: 0), at: .top, animated: false)
            try await host.settle()
            if let match = host.textView(containing: "Message 30.") { shown = match; break }
        }
        #expect(try #require(shown) === built, "Showing a row built ahead must not build it again.")
    }

    @Test func aTimelineRowBuiltAheadKeepsItsViewsWhenShown() async throws {
        let owner = NSObject()
        let rows = (0..<40).map { ChatCanvasRow.divider("Row \($0)") }
        let root = UIHostingController(rootView: NativeChatTimeline(
            conversationID: "ahead-plain", ownerID: ObjectIdentifier(owner), rows: rows,
            controller: ChatTimelineController(), entryCount: rows.count) { row in
                ProbeTitle(title: row.id).frame(height: 100)
            })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(1))
        let table = try #require(Host.descendants(root.view, of: ChatTimelineTableView.self).first)
        func button() -> UIButton? {
            Host.descendants(table, of: UIButton.self).first { $0.title(for: .normal) == "divider:Row 25" }
        }
        let ahead = try #require(button(), "Row 25 must be built before it's on screen.")
        #expect(!table.visibleCells.contains { Host.descendants($0, of: UIButton.self).contains(ahead) })
        table.followsTail = false
        table.scrollToRow(at: IndexPath(row: 25, section: 0), at: .top, animated: false)
        try await Task.sleep(for: .milliseconds(300))
        let shown = try #require(table.visibleCells.lazy.flatMap { Host.descendants($0, of: UIButton.self) }
            .first { $0.title(for: .normal) == "divider:Row 25" })
        #expect(shown === ahead)
    }

    @Test func aKeptRowOffScreenHoldsItsLoadersStill() async throws {
        let owner = NSObject()
        let rows = (0..<30).map { ChatCanvasRow.divider("Row \($0)") }
        let root = UIHostingController(rootView: NativeChatTimeline(
            conversationID: "kept-loaders", ownerID: ObjectIdentifier(owner), rows: rows,
            controller: ChatTimelineController(), entryCount: rows.count) { row in
                LoaderMotionProbe(id: row.id).frame(height: 100)
            })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        let table = try #require(Host.descendants(root.view, of: ChatTimelineTableView.self).first)
        func probe() -> String? {
            Host.descendants(table, of: UIButton.self).lazy.compactMap { $0.title(for: .normal) }
                .first { $0.hasPrefix("divider:Row 29 ") }
        }
        #expect(probe() == "divider:Row 29 moving")

        table.followsTail = false
        table.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(probe() == "divider:Row 29 still", "A row kept off screen must not keep its loaders moving.")

        table.scrollToRow(at: IndexPath(row: rows.count - 1, section: 0), at: .bottom, animated: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(probe() == "divider:Row 29 moving")
    }

    @Test func aMessageThatGainsAFollowerInItsGroupClosesUpToIt() async throws {
        let model = ChatModel(conversationID: "regrouped-rows", client: ConversationFixtureClient(), initialItems: [
            Self.message("question", .human, "What changed in the build?"),
            Self.message("first-answer", .assistant, "The first part of the answer."),
        ])
        let host = try await Host(model)
        defer { host.window.isHidden = true }
        let before = try #require(host.cell(containing: "The first part of the answer.")).bounds.height

        model.acceptExternal([Self.message("second-answer", .assistant, "And the second part, from the same agent.")])
        try await host.settle()

        let after = try #require(host.cell(containing: "The first part of the answer.")).bounds.height
        #expect(after < before, "A message followed by another of its group sits closer to it (\(before) → \(after)).")
    }
}

/// Says whether its row's loaders may move.
private struct LoaderMotionProbe: View {
    let id: String
    @Environment(\.bighelpLoaderMotionOverride) private var override

    var body: some View { ProbeTitle(title: "\(id) \(override.sceneInactive ? "still" : "moving")") }
}

private struct ProbeTitle: UIViewRepresentable {
    let title: String
    func makeUIView(context: Context) -> UIButton { UIButton(type: .system) }
    func updateUIView(_ button: UIButton, context: Context) { button.setTitle(title, for: .normal) }
}
