import Foundation
import SwiftUI
import UIKit
import Testing
@testable import Bighelp

@MainActor
struct SessionReopenReplayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BIGHELP_DEVICE_SESSION_REPLAY_FILE"] != nil))
    func phoneCacheAndHistoryTransitionsRenderThroughTheActualNativeCanvas() async throws {
        let cachePath = try #require(ProcessInfo.processInfo.environment["BIGHELP_DEVICE_SESSION_REPLAY_FILE"])
        let historyPath = try #require(ProcessInfo.processInfo.environment["BIGHELP_SESSION_REPLAY_FILE"])
        let initial = try JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: URL(fileURLWithPath: cachePath)))
        let values = try JSONDecoder().decode([BighelpJSONValue].self, from: Data(contentsOf: URL(fileURLWithPath: historyPath)))
        let storedID = try #require(initial.remoteStoredID)
        let decoded = try values.map { try DirectHermesHistoryRow($0, sessionID: storedID) }
        let client = ReplayCoverageClient()
        let catalog = SessionCatalogStore(client: client, records: [initial])
        let model = ChatModel(conversationID: initial.id, client: NativeWorkspaceUnavailableClient(),
            agentID: "default", initialItems: initial.items, initialDraft: "Unsent replay draft",
            initialActivityEvents: initial.activityEvents, initialActivityVisibility: initial.activityVisibility, sourceSession: initial)
        let host = UIHostingController(rootView: ChatView(model: model, foldCompletedTurns: true)
            .environment(\.bighelpUIV3Enabled, true))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        func table(in view: UIView) -> ChatTimelineTableView? {
            if let table = view as? ChatTimelineTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        for (size, running) in [(min(320, decoded.count), false), (decoded.count, true), (min(320, decoded.count), true), (decoded.count, false)] {
            let rows = Array(decoded.suffix(size))
            let projection = try DirectHermesHistoryProjection(rows: rows, appID: initial.id,
                profileID: "default", source: "ios", sourceOrderBase: -rows.count)
            var incoming = initial
            incoming.items = projection.messages
            incoming.activityEvents = projection.activityEvents(sessionID: initial.id)
            incoming.isActive = running
            client.covered = Set(projection.tools.compactMap(\.toolCallID))
            let prior = try #require(catalog.session(id: initial.id))
            model.beginHistoryHydration(from: incoming)
            let hydrated = try catalog.installSessionStateSnapshot(.init(record: incoming, nextOffset: nil), source: prior)
            model.reconcileHydratedSession(hydrated)
            try await Task.sleep(for: .milliseconds(400))
            host.view.layoutIfNeeded()
            let canvas = try #require(table(in: host.view))
            let dataSource = try #require(canvas.dataSource as? UITableViewDiffableDataSource<Int, String>)
            let installed = dataSource.snapshot().itemIdentifiers
            let display = ChatCompletedTurnProjection.rows(from: model.transcriptEntries, isSending: model.isSending,
                enabled: true, activityEvents: model.activityLedger.allEvents)
            var expected = ChatCanvasTranscriptProjection.rows(from: display, disclosures: model.activityDisclosures,
                                                               isSending: model.isSending).map(\.id)
            // A tool folder at the live tail stands in for the waiting bubble.
            let tailIsWorkFolder: Bool = {
                guard case .activity(let turn)? = model.transcriptEntries.last else { return false }
                if turn.events.contains(where: { $0.lifecycle == .running }) { return true }
                guard model.activityVisibility.showToolCalls,
                      case .workTrail? = ChatActivityTurnPresentation(turn: turn).segments.last else { return false }
                return true
            }()
            if model.isSending && !tailIsWorkFolder { expected.append("chat-pending") }
            expected.append("chat-bottom")
            #expect(installed == expected)
            #expect(model.draft == "Unsent replay draft")
            #expect(!installed.isEmpty)
            model.finishHistoryHydration()
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BIGHELP_SESSION_REPLAY_FILE"] != nil))
    func capturedActivitySessionKeepsUniqueCanvasIdentityThroughRehydration() throws {
        let path = try #require(ProcessInfo.processInfo.environment["BIGHELP_SESSION_REPLAY_FILE"])
        let values = try JSONDecoder().decode([BighelpJSONValue].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let sessionID = try #require(values.first?.object?["session_id"]?.string)
        let decoded = try values.map { try DirectHermesHistoryRow($0, sessionID: sessionID) }
        var initial = SessionRecord(id: "replay-session", kind: .direct, agentIDs: ["default"],
            title: "Captured activity session", remoteStoredID: sessionID, remoteSource: "ios")
        if let cache = ProcessInfo.processInfo.environment["BIGHELP_DEVICE_SESSION_REPLAY_FILE"] {
            initial = try JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: URL(fileURLWithPath: cache)))
            #expect(initial.remoteStoredID == sessionID)
        }
        let client = ReplayCoverageClient()
        let catalog = SessionCatalogStore(client: client, records: [initial])
        let model = ChatModel(conversationID: initial.id, client: NativeWorkspaceUnavailableClient(),
            agentID: "default", initialItems: initial.items, initialActivityEvents: initial.activityEvents,
            initialActivityVisibility: initial.activityVisibility, sourceSession: initial)
        print("DEVICE_REPLAY items=\(initial.items.count) activities=\(initial.activityEvents.count)")
        for size in [decoded.count, min(320, decoded.count), decoded.count] {
            let window = Array(decoded.suffix(size))
            let projected = try DirectHermesHistoryProjection(rows: window, appID: initial.id,
                profileID: "default", source: "ios", sourceOrderBase: -window.count)
            var record = initial
            record.items = projected.messages
            record.activityEvents = projected.activityEvents(sessionID: initial.id)
            for running in [false, true] {
                record.isActive = running
                model.beginHistoryHydration(from: record)
                client.covered = Set(projected.tools.compactMap(\.toolCallID))
                let prior = try #require(catalog.session(id: initial.id))
                let hydrated = try catalog.installSessionStateSnapshot(.init(record: record, nextOffset: nil), source: prior)
                model.reconcileHydratedSession(hydrated)
                for folded in [false, true] {
                    let display = ChatCompletedTurnProjection.rows(from: model.transcriptEntries,
                        isSending: running, enabled: folded, activityEvents: model.activityLedger.allEvents)
                    for expanded in [false, true] {
                        let disclosures = ChatActivityDisclosureStore()
                        for entry in model.transcriptEntries {
                            if case .activity(let turn) = entry {
                                for segment in ChatActivityTurnPresentation(turn: turn).segments {
                                    if case .workTrail(let trail) = segment { disclosures.setExpanded(expanded, for: trail) }
                                }
                            }
                        }
                        for row in display {
                            if case .completed(let turn) = row { disclosures.setCompletedTurnExpanded(expanded, id: turn.id) }
                        }
                        let canvas = ChatCanvasTranscriptProjection.rows(from: display, disclosures: disclosures)
                        let duplicates = Dictionary(grouping: canvas.map(\.id), by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
                        #expect(duplicates.isEmpty, "Duplicate canvas IDs in captured history: \(duplicates)")
                        print("ACTIVITY_REPLAY rows=\(size) active=\(running) folded=\(folded) expanded=\(expanded) canvas=\(canvas.count) duplicateIDs=\(duplicates.count)")
                    }
                }
                model.finishHistoryHydration()
            }
        }
    }
}

@MainActor
private final class ReplayCoverageClient: SessionCatalogClient {
    var covered: Set<String> = []
    var canDeleteConversation: Bool { false }
    func canonicalToolCallIDs(for record: SessionRecord) -> Set<String> { covered }
    func list() async throws -> [SessionRecord] { [] }
    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord { throw CancellationError() }
}
