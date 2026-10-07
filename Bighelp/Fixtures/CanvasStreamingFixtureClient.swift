#if DEBUG
import Foundation
import UIKit
import CoreFoundation

/// Deterministic presentation-only stream through the real ChatModel draft path.
@MainActor
final class CanvasStreamingFixtureClient: ConversationFixtureClient, StreamingConversationClient, MidSessionConversationClient {
    let senderID: String
    weak var model: ChatModel?
    weak var featureStore: ShellFeatureStore?
    weak var catalog: SessionCatalogStore?
    private let toolStress = ProcessInfo.processInfo.arguments.contains("-test-tool-stream")
    private let silentReply = ProcessInfo.processInfo.arguments.contains("-test-silent-reply")
    private let tableReply = ProcessInfo.processInfo.arguments.contains("-test-table-reply")
    private let voiceSteps = ProcessInfo.processInfo.arguments.contains("-test-voice-steps")

    /// A turn with a few slow steps, the way Hermes reports them: the agent's own
    /// tools, and a helper whose own tool must stay inside its folder.
    private func runVoiceSteps(onDraft: @escaping (TimelineItem) -> Void) async throws -> ConversationResponse {
        guard let model else { throw CancellationError() }
        let sessionID = model.conversationID
        let turnID = "voice-steps-\(UUID().uuidString)"
        let steps: [(name: String, arguments: String?, kind: ChatActivityKind)] = [
            ("mcp_google_calendar_list_events", #"{"day":"tomorrow"}"#, .tool),
            ("delegate_task", nil, .subagent),
            ("terminal", #"{"command":"git clone https://github.com/example/weather-app"}"#, .tool),
            ("get_weather_forecast", #"{"when":"tomorrow"}"#, .tool),
        ]
        for (index, step) in steps.enumerated() {
            let event = ChatActivityEvent(eventID: "\(turnID)-\(index)", sessionID: sessionID, turnID: turnID,
                kind: step.kind, lifecycle: .running, title: step.kind == .subagent ? "Compare routes" : step.name,
                summary: nil, detail: nil, occurredAt: index * 2,
                toolCallID: step.kind == .tool ? "\(turnID)-call-\(index)" : nil, toolName: step.name,
                arguments: step.arguments, subagentID: step.kind == .subagent ? "\(turnID)-helper" : nil)
            _ = model.acceptActivity(event)
            if step.kind == .subagent {
                try await Task.sleep(for: .milliseconds(300))
                _ = model.acceptActivity(ChatActivityEvent(eventID: "\(turnID)-helper-read", sessionID: sessionID,
                    turnID: turnID, kind: .tool, lifecycle: .running, title: "read_file", summary: nil, detail: nil,
                    occurredAt: index * 2, toolCallID: "\(turnID)-helper-call", toolName: "read_file",
                    arguments: #"{"path":"routes.md"}"#, subagentID: "\(turnID)-helper"))
            }
            try await Task.sleep(for: .milliseconds(2_600))
            _ = model.acceptActivity(event.updating(lifecycle: .succeeded, summary: nil, detail: nil,
                                                    occurredAt: index * 2 + 1))
        }
        let id = "\(turnID)-reply"
        // Long enough to scroll on a phone, so voice mode shows a reply in full.
        let text = "Tomorrow looks sunny with a high of 72. You have two meetings in the morning: the design "
            + "review at 9 and a call with the print shop at 11. The afternoon is open, so it's a good time for "
            + "the bike ride you wanted. I cloned the weather app and its forecast agrees: light wind, no rain "
            + "until Thursday. On Thursday, take a jacket; showers start around four and last into the evening. "
            + "Your calendar also has a reminder to water the plants on Friday, and the library books are due "
            + "on Saturday. Want me to move the print shop call so the morning is free?"
        func reply(_ text: String, delivery: String) -> TimelineItem {
            TimelineItem(id: id, role: .assistant, sender: .agent(id: senderID, snapshot: .init(name: "Canvas fixture")),
                         content: .message(text), metadata: .init(source: "UI fixture", delivery: delivery))
        }
        let words = text.split(separator: " ")
        for count in stride(from: 3, through: words.count, by: 3) {
            try await Task.sleep(for: .milliseconds(150))
            onDraft(reply(words.prefix(count).joined(separator: " "), delivery: "Streaming"))
        }
        return ConversationResponse(items: [reply(text, delivery: "Delivered")])
    }

    /// A reply with a pipe table, a divider and a checklist, streamed in pieces.
    private func runTableReply(onDraft: @escaping (TimelineItem) -> Void) async throws -> ConversationResponse {
        let id = "table-reply-\(UUID().uuidString)"
        let text = """
        You're most likely looking at about **$320**. These are the flat rates on [poorjohns.com/prices.html](https://example.com/prices):

        | Likely cause | Labor | Materials | Total |
        |---|---:|---:|---:|
        | **Tank bolt / gasket** (most likely) | $300 | $20 | **$320** |
        | Fill valve, if the leak is at the supply hookup | $250 | $20 | $270 |
        | Supply line, if it's the hose | $215 | $20 | $235 |
        | Shutoff valve, if yours doesn't fully close | $300 | $20 | $320 |
        | **Cracked tank → toilet replacement** (worst case) | $400 | toilet cost | $400 + toilet |

        ---

        - [x] Photo of the leak
        - [ ] Book the visit
        """
        func reply(_ text: String, delivery: String) -> TimelineItem {
            TimelineItem(id: id, role: .assistant, sender: .agent(id: senderID, snapshot: .init(name: "Canvas fixture")),
                         content: .message(text), metadata: .init(source: "UI fixture", delivery: delivery))
        }
        let lines = text.components(separatedBy: "\n")
        for count in stride(from: 2, through: lines.count, by: 3) {
            try await Task.sleep(for: .milliseconds(120))
            onDraft(reply(lines.prefix(count).joined(separator: "\n"), delivery: "Streaming"))
        }
        return ConversationResponse(items: [reply(text, delivery: "Delivered")])
    }
    private var toolRun = 0

    /// Streams a bare marker the way Hermes does ("NO" on the way to "NO_REPLY").
    private func runSilentReply(onDraft: @escaping (TimelineItem) -> Void) async throws -> ConversationResponse {
        let id = "silent-reply-\(UUID().uuidString)"
        func reply(_ text: String, delivery: String) -> TimelineItem {
            TimelineItem(id: id, role: .assistant, sender: .agent(id: senderID, snapshot: .init(name: "Canvas fixture")),
                         content: .message(text), metadata: .init(source: "UI fixture", delivery: delivery))
        }
        for partial in ["NO", "NO_REP", "NO_REPLY"] {
            try await Task.sleep(for: .milliseconds(150))
            onDraft(reply(partial, delivery: "Streaming"))
        }
        return ConversationResponse(items: [reply("NO_REPLY", delivery: "Delivered")])
    }

    private func runToolStream(onDraft: @escaping (TimelineItem) -> Void) async throws -> ConversationResponse {
        guard let model else { throw CancellationError() }
        let sessionID = model.conversationID
        let args = ProcessInfo.processInfo.arguments
        toolRun += 1
        let prefix = "tool-stream-\(toolRun)"
        let twoTurns = args.contains("-test-tool-stream-two-turns")
        let consecutiveTools = args.contains("-test-tool-stream-consecutive")
        let count = twoTurns ? 2 : args.contains("-test-tool-stream-long") ? 100 : 5
        let background = args.contains("-test-two-chat-stream") ? try await prepareBackgroundChat() : nil
        let monitor = ToolStreamFrameProbe()
        monitor.start()
        defer { monitor.cancel() }
        var completed: [TimelineItem] = []
        for index in 0..<count {
            try Task.checkCancellation()
            if let background { updateBackgroundChat(background, index: index) }
            let item = TimelineItem(id: "\(prefix)-prose-\(index)", role: .assistant,
                sender: .agent(id: senderID, snapshot: .init(name: "Canvas fixture")),
                content: .message("### Investigation step \(index)\n" + String(repeating: "Checking **the current source** and `stable identifiers` before proceeding.\n", count: 8)),
                metadata: .init(source: "UI fixture", delivery: "Streaming"))
            if !consecutiveTools {
                onDraft(item)
                completed.append(item)
            }
            let event = ChatActivityEvent(eventID: "\(prefix)-event-\(index)", sessionID: sessionID,
                turnID: prefix, kind: .tool, lifecycle: .running, title: "Inspect source",
                summary: nil, detail: nil, occurredAt: index * 2, toolCallID: "\(prefix)-call-\(index)",
                toolName: "read_file", arguments: "{\"path\":\"source.swift\"}")
            _ = model.acceptActivity(event)
            if args.contains("-test-tool-stream-expanded"),
               case .activity(let turn) = model.transcriptEntries.last {
                model.activityDisclosures.setExpanded(true, for: turn)
                model.activityDisclosures.setExpanded(true, for: event)
            }
            try await Task.sleep(for: .milliseconds(60))
            let resultRows = args.contains("-test-tool-reader") ? 32 : 600
            let result = consecutiveTools
                ? "{\"files\":[" + (0..<resultRows).map { "{\"path\":\"source/feature-\(index)/file-\($0).swift\",\"result\":\"Verified canonical row and stable identity\"}" }.joined(separator: ",") + "],\"zz_end\":\"END OF COMPLETE TOOL RESULT \(index)\"}"
                : nil
            _ = model.acceptActivity(event.updating(lifecycle: .succeeded, summary: "Source inspected", detail: result, occurredAt: index * 2 + 1))
        }
        var tail = "LIVE TOOL STREAM TAIL\n"
        monitor.beginAnswerUpdates()
        let tailID = "\(prefix)-tail"
        for index in 0..<(twoTurns ? 10 : 40) {
            try await Task.sleep(for: .milliseconds(80))
            tail += "Tail update \(index): **stable streaming** with accumulated work.\n"
            onDraft(TimelineItem(id: tailID, role: .assistant,
                sender: .agent(id: senderID, snapshot: .init(name: "Canvas fixture")),
                content: .message(tail), metadata: .init(source: "UI fixture", delivery: "Streaming")))
        }
        if let background {
            background.acceptAuthoritativeTerminalForExternallyOwnedTurn([
                backgroundMessage(id: "background-live", text: "BACKGROUND CHAT COMPLETE", delivery: "Delivered")
            ])
            featureStore?.flushChatPersistence()
        }
        let metrics = monitor.stop(label: "tool-stream-\(count)-\(args.contains("-test-tool-stream-expanded") ? "expanded" : "collapsed")")
            + " BACKGROUND_CHAT_UPDATES=\(background == nil ? 0 : count)"
        if let notification = ProcessInfo.processInfo.environment["BIGHELP_TOOL_STREAM_COMPLETION_NOTIFICATION"] {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(notification as CFString), nil, nil, true)
        }
        let final = TimelineItem(id: tailID, role: .assistant,
            sender: .agent(id: senderID, snapshot: .init(name: "Canvas fixture")),
            content: .message(tail + "TOOL STREAM COMPLETE \(toolRun)\n" + metrics), metadata: .init(source: "UI fixture", delivery: "Delivered"))
        return ConversationResponse(items: completed + [final])
    }

    private func prepareBackgroundChat() async throws -> ChatModel {
        guard let catalog, let featureStore else { throw CancellationError() }
        let session = try await catalog.createDirect(agentID: senderID)
        catalog.replaceItems((0..<1_000).map { index in
            backgroundMessage(id: "background-history-\(index)",
                text: String(repeating: "Retained background chat history. ", count: 80), delivery: "Delivered")
        }, for: session.id)
        let route = AppRoute.chat(conversationID: session.id)
        guard featureStore.prepare(route), case .chat(let background)? = featureStore.preparedModel(for: route)
        else { throw CancellationError() }
        background.beginExternallyOwnedTurn(with: TimelineItem(id: "background-human", role: .human,
            sender: .user(snapshot: .init(name: "You")), content: .message("Keep working in this chat"),
            metadata: .init(delivery: "Sent")))
        return background
    }

    private func updateBackgroundChat(_ background: ChatModel, index: Int) {
        let id = background.conversationID
        featureStore?.acceptSessionContext(.init(sessionId: id, model: "hermes", contextUsed: index,
            contextMax: 100, contextPercent: index, compressions: 0, isCompacting: false, updatedAt: index))
        featureStore?.acceptExternalActivity(.init(eventID: "background-tool-\(index)", sessionID: id,
            turnID: "background-turn", kind: .tool, lifecycle: .succeeded, title: "Read source",
            summary: "Complete", detail: String(repeating: "Exact tool result. ", count: 100),
            occurredAt: index, toolCallID: "background-call-\(index)", toolName: "read_file"))
        featureStore?.acceptExternal([backgroundMessage(id: "background-live",
            text: String(repeating: "Background update \(index). ", count: index + 1), delivery: "Streaming")],
            conversationID: id, isLiveAssistantText: true)
    }

    private func backgroundMessage(id: String, text: String, delivery: String) -> TimelineItem {
        .init(id: id, role: .assistant, sender: .agent(id: senderID, snapshot: .init(name: "Background agent")),
              content: .message(text), metadata: .init(source: "UI fixture", delivery: delivery))
    }
    init(senderID: String) {
        self.senderID = senderID
        super.init(canonicalAgentID: senderID)
    }

    func sendMidSession(message: String, attachments: [ChatAttachment], conversationID: String,
                        behavior: MidSessionChatBehavior,
                        onDraft: @escaping (TimelineItem) -> Void) async throws -> MidSessionSubmissionOutcome {
        // Match the real Hermes client's capability so the stress fixture can
        // exercise an editable composer while its primary turn is running.
        .accepted
    }

    func send(message: String, conversationID: String, onDraft: @escaping (TimelineItem) -> Void) async throws -> ConversationResponse {
        if toolStress { return try await runToolStream(onDraft: onDraft) }
        if silentReply { return try await runSilentReply(onDraft: onDraft) }
        if tableReply { return try await runTableReply(onDraft: onDraft) }
        if voiceSteps { return try await runVoiceSteps(onDraft: onDraft) }
        var text = "CANVAS STREAM START\n"
        var item = TimelineItem(id: "canvas-stream-\(UUID().uuidString)", role: .assistant,
                                sender: .agent(id: senderID, snapshot: TimelineSenderSnapshot(name: "Canvas fixture")),
                                content: .message(text), metadata: TimelineMetadata(source: "UI fixture", delivery: "Streaming"))
        for index in 1...100 {
            try await Task.sleep(for: .milliseconds(120))
            text += "Stream line \(index): a stable growing response.\n"
            item = TimelineItem(id: item.id, role: item.role, sender: item.sender,
                                content: .message(text), metadata: item.metadata)
            onDraft(item)
            let samplesEachBatch = ProcessInfo.processInfo.environment["BIGHELP_CANVAS_SAMPLE_EACH_BATCH"] == "YES"
            if (samplesEachBatch ? index.isMultiple(of: 5) : index == 30 || index == 40),
               let signal = ProcessInfo.processInfo.environment["BIGHELP_CANVAS_RESUME_NOTIFICATION"] {
                try await CanvasStreamResumeSignal.wait(named: signal)
            }
        }
        // Keep the sending state deterministic while XCTest samples geometry.
        // App termination/cancellation owns the end of this test-only stream.
        while ProcessInfo.processInfo.arguments.contains("-test-canvas-hold-open") {
            try await Task.sleep(for: .seconds(1))
        }
        let final = TimelineItem(id: item.id, role: item.role, sender: item.sender,
                                 content: item.content, metadata: TimelineMetadata(source: "UI fixture", delivery: "Delivered"))
        return ConversationResponse(items: [final])
    }
}

/// Pauses a fixture at known content boundaries while XCTest performs gestures.
/// The test explicitly releases another batch, proving growth without relying
/// on how long XCTest waits for UIKit's animation/scroll quiescence.
private enum CanvasStreamResumeSignal {
    private final class Observer {
        let continuation: AsyncStream<Void>.Continuation
        init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
    }

    static func wait(named name: String) async throws {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = Unmanaged.passRetained(Observer(continuation)).toOpaque()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, observer, { _, pointer, _, _, _ in
            guard let pointer else { return }
            Unmanaged<Observer>.fromOpaque(pointer).takeUnretainedValue().continuation.yield(())
        }, name as CFString, nil, .deliverImmediately)
        defer {
            CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(name as CFString), nil)
            continuation.finish()
            Unmanaged<Observer>.fromOpaque(observer).release()
        }
        for await _ in stream { try Task.checkCancellation(); return }
        throw CancellationError()
    }
}

/// Reopens Home with a completed catalog and queued historical delivery. No
/// agent turn is started. The shape mirrors the incident, using synthetic data.
@MainActor
enum IdleReplayAcceptanceFixture {
    static var records: [SessionRecord] {
        (0..<62).map { index in
            let id = "idle-\(index)"
            return SessionRecord(id: id, kind: .direct, agentIDs: ["finance"], title: "Completed chat \(index)",
                items: (0..<(index == 0 ? 96 : 1)).map { message(id: "\(id)-answer-\($0)") },
                activityEvents: index == 0 ? (0..<3_000).map { event in
                    ChatActivityEvent(eventID: "retained-\(event)", sessionID: id, turnID: "old-turn-\(event / 100)",
                        kind: .tool, lifecycle: .succeeded, title: "Read source", summary: "Complete",
                        detail: String(repeating: "Synthetic retained tool result. ", count: 60), occurredAt: event,
                        toolCallID: "retained-call-\(event)", toolName: "read_file")
                } : [], hasAcceptedMessage: true)
        }
    }

    private static func message(id: String) -> TimelineItem {
        .init(id: id, role: .assistant, sender: .agent(id: "finance", snapshot: .init(name: "Fixture agent")),
              content: .message("Completed historical answer"), metadata: .init(delivery: "Delivered"))
    }

    private static func footprintMiB() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint / 1_048_576 : 0
    }

    static func start(features: ShellFeatureStore, catalog: SessionCatalogStore) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let monitor = ToolStreamFrameProbe()
            monitor.start()
            let before = catalog.repositorySaveCount
            let startMemory = footprintMiB()
            var peakMemory = startMemory
            features.setChatPresentationDeferred(true)
            for index in 0..<120 {
                features.acceptExternal([message(id: "queued-\(index)")], conversationID: "idle-0")
                let child = SessionSubagentSnapshot(id: "worker-\(index)", sessionID: "child-\(index)",
                    parentID: "idle-0", role: "worker", goal: "Completed historical task", startedAt: index * 2)
                features.acceptSessionSubagents(.init(sessionID: "idle-0", subagents: [child], updatedAt: index * 2))
                features.acceptSessionSubagents(.init(sessionID: "idle-0", subagents: [], updatedAt: index * 2 + 1))
                peakMemory = max(peakMemory, footprintMiB())
                try? await Task.sleep(for: .milliseconds(2))
            }
            features.setChatPresentationDeferred(false)
            try? await Task.sleep(for: .seconds(3))
            let report = monitor.stop(label: "idle-replay")
                + " CATALOG_WRITES=\(catalog.repositorySaveCount - before) ACTIVE_SESSIONS=\(catalog.records.filter(\.hasActiveWork).count)"
                + " MEMORY_START_MIB=\(startMemory) MEMORY_PEAK_MIB=\(peakMemory) MEMORY_END_MIB=\(footprintMiB())"
            print("IDLE_REPLAY \(report)")
            // Test-only readout, outside the measured interval and view graph.
            let label = UILabel(frame: CGRect(x: 8, y: 130, width: 360, height: 100))
            label.text = report
            label.numberOfLines = 0
            label.font = .systemFont(ofSize: 9)
            label.accessibilityIdentifier = "fixture.idle-replay-metrics"
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first(where: \.isKeyWindow)?.addSubview(label)
            if let signal = ProcessInfo.processInfo.environment["BIGHELP_IDLE_REPLAY_COMPLETION_NOTIFICATION"] {
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName(signal as CFString), nil, nil, true)
            }
        }
    }
}

@MainActor
private final class ToolStreamFrameProbe: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var gaps: [Double] = []
    private var started = CACurrentMediaTime()
    private var responsivenessTimer: DispatchSourceTimer?
    private var lastTimerTick: CFTimeInterval?
    private var timerGaps: [Double] = []
    private var answerTimerStart = 0

    func beginAnswerUpdates() { answerTimerStart = timerGaps.count }

    func start() {
        started = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // Request a fixed sampling cadence; the default adaptive refresh rate
        // can intentionally skip callbacks when the simulated display is idle.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = CACurrentMediaTime()
            if let lastTimerTick { timerGaps.append((now - lastTimerTick) * 1000) }
            lastTimerTick = now
        }
        timer.resume()
        responsivenessTimer = timer
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        if let last { gaps.append((now - last) * 1000) }
        last = now
    }

    func cancel() {
        link?.invalidate()
        link = nil
        responsivenessTimer?.cancel()
        responsivenessTimer = nil
    }

    func stop(label: String) -> String {
        cancel()
        let elapsed = CACurrentMediaTime() - started
        let maxGap = gaps.max() ?? 0
        let sortedGaps = gaps.sorted()
        let p95Gap = sortedGaps.isEmpty ? 0 : sortedGaps[min(sortedGaps.count - 1, Int(Double(sortedGaps.count) * 0.95))]
        let answerGaps = Array(timerGaps.dropFirst(answerTimerStart + 1)).sorted()
        let answerP95 = answerGaps.isEmpty ? 0 : answerGaps[min(answerGaps.count - 1, Int(Double(answerGaps.count) * 0.95))]
        let report: [String: Any] = ["label": label, "elapsed_seconds": elapsed,
                                   "max_frame_gap_ms": maxGap, "gaps_ms": gaps,
                                   "main_queue_gaps_ms": timerGaps,
                                   "answer_main_queue_gaps_ms": Array(timerGaps.dropFirst(answerTimerStart + 1))]
        if let data = try? JSONSerialization.data(withJSONObject: report) {
            try? data.write(to: URL.documentsDirectory.appending(path: label + ".json"))
        }
        return "FRAME_GAP_MS=\(Int(maxGap)) ELAPSED_SECONDS=\(Int(elapsed)) FRAME_COUNT=\(gaps.count) FRAME_GAP_P95_MS=\(Int(p95Gap)) MAIN_QUEUE_MAX_MS=\(Int(timerGaps.max() ?? 0)) ANSWER_QUEUE_P95_MS=\(Int(answerP95)) ANSWER_QUEUE_COUNT=\(answerGaps.count)"
    }
}
#endif
