import Foundation
import QuartzCore
import UIKit
import os

/// Main-thread costs of the chat, for the long-chat speed checks
/// (`ChatLoadSpeedUITests`). Only DEBUG builds launched with
/// `-test-chat-performance-probe` record anything; everywhere else each call
/// just runs its body.
@MainActor
enum ChatPerformanceProbe {
    @inline(__always)
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        #if DEBUG
        guard let recorder = ChatPerformanceRecorder.shared else { return try body() }
        let start = CACurrentMediaTime()
        defer { recorder.record(name, milliseconds: (CACurrentMediaTime() - start) * 1_000) }
        return try body()
        #else
        return try body()
        #endif
    }

    @inline(__always)
    static func count(_ name: StaticString) {
        #if DEBUG
        ChatPerformanceRecorder.shared?.record(name, milliseconds: nil)
        #endif
    }

    /// Objects alive right now (rows, parsed messages, chat models), for finding
    /// what a long chat keeps after it closes. Safe from `deinit`.
    @inline(__always)
    nonisolated static func live(_ name: StaticString, _ delta: Int) {
        #if DEBUG
        guard ChatPerformanceRecorder.isEnabled else { return }
        ChatPerformanceRecorder.liveCounts.withLock { $0["\(name)", default: 0] += delta }
        #endif
    }
}

#if DEBUG
/// XCTest resets and reads the recorder with Darwin notifications, so it never
/// polls the accessibility tree while a phase is measured. Each reading is
/// written to Documents as `chat-performance-<BIGHELP_PERF_LABEL>-<n>.json`.
@MainActor
final class ChatPerformanceRecorder: NSObject {
    nonisolated static let launchArgument = "-test-chat-performance-probe"
    nonisolated static let resetNotification = "app.loopdy.fixture.chat-performance.reset"
    nonisolated static let readNotification = "app.loopdy.fixture.chat-performance.read"
    nonisolated static let isEnabled = ProcessInfo.processInfo.arguments.contains(launchArgument)
    nonisolated static let liveCounts = OSAllocatedUnfairLock(initialState: [String: Int]())
    static let shared: ChatPerformanceRecorder? = isEnabled ? ChatPerformanceRecorder() : nil

    private struct Stat { var count = 0; var total = 0.0; var max = 0.0 }
    private var stats: [String: Stat] = [:]
    private var queueGaps: [Double] = []
    private var frameGaps: [Double] = []
    private var lastTick: CFTimeInterval?
    private var lastFrame: CFTimeInterval?
    private var phaseStart = CACurrentMediaTime()
    private var readings = 0
    private var timer: DispatchSourceTimer?
    private var link: CADisplayLink?
    /// The phase between a reset and a reading, for lining up an Instruments trace.
    private let signposter = OSSignposter(subsystem: "app.loopdy.mobile.performance", category: .pointsOfInterest)
    private var phase: OSSignpostIntervalState?

    private override init() {
        super.init()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in [Self.resetNotification, Self.readNotification] + ChatPerformanceAutopilot.notifications {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let name = name?.rawValue as String? else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { ChatPerformanceRecorder.shared?.handle(name) }
                }
            }, name as CFString, nil, .deliverImmediately)
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = CACurrentMediaTime()
            if let lastTick = self.lastTick { self.queueGaps.append((now - lastTick) * 1_000) }
            self.lastTick = now
        }
        timer.resume()
        self.timer = timer
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private let autopilot = ChatPerformanceAutopilot()

    private func handle(_ name: String) {
        switch name {
        case Self.resetNotification: reset()
        case Self.readNotification: read()
        default: autopilot.run(name, recorder: self)
        }
    }

    @objc private func frame() {
        let now = CACurrentMediaTime()
        if let lastFrame { frameGaps.append((now - lastFrame) * 1_000) }
        lastFrame = now
    }

    func record(_ name: StaticString, milliseconds: Double?) {
        let key = "\(name)"
        var stat = stats[key, default: Stat()]
        stat.count += 1
        if let milliseconds {
            stat.total += milliseconds
            stat.max = Swift.max(stat.max, milliseconds)
        }
        stats[key] = stat
    }

    func reset() {
        if let phase { signposter.endInterval("Measured phase", phase) }
        phase = signposter.beginInterval("Measured phase")
        stats.removeAll()
        queueGaps.removeAll()
        frameGaps.removeAll()
        lastTick = nil
        lastFrame = nil
        phaseStart = CACurrentMediaTime()
    }

    func read() {
        if let phase { signposter.endInterval("Measured phase", phase) }
        phase = nil
        readings += 1
        func summary(_ gaps: [Double]) -> [String: Any] {
            let sorted = gaps.sorted()
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            return ["count": gaps.count, "max": sorted.last ?? 0, "p95": p95,
                    "over_34ms": gaps.filter { $0 > 34 }.count, "over_100ms": gaps.filter { $0 > 100 }.count]
        }
        let label = ProcessInfo.processInfo.environment["BIGHELP_PERF_LABEL"] ?? "run"
        let report: [String: Any] = [
            "label": label, "reading": readings,
            "seconds": CACurrentMediaTime() - phaseStart,
            "stats": stats.mapValues { ["count": $0.count, "total_ms": $0.total, "max_ms": $0.max] },
            "main_queue_gaps_ms": summary(queueGaps),
            "frame_gaps_ms": summary(frameGaps),
            "footprint_mib": Double(Self.footprintBytes()) / 1_048_576,
            "live": Self.liveCounts.withLock { $0 },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
        try? data.write(to: URL.documentsDirectory.appending(path: "chat-performance-\(label)-\(readings).json"))
        NSLog("CHAT_PERFORMANCE %@", String(decoding: data, as: UTF8.self))
    }

    private static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

/// Drives the open chat the same way every run, without XCTest: its accessibility
/// snapshots of a long chat build every row and stall the app for seconds, which
/// would swamp what's measured. Darwin notifications `…chat-performance.scroll`,
/// `.type` and `.send` scroll through history and back, type in the message box,
/// and send; each phase is reset before and read after.
@MainActor
final class ChatPerformanceAutopilot: NSObject {
    nonisolated static let scrollNotification = "app.loopdy.fixture.chat-performance.scroll"
    nonisolated static let typeNotification = "app.loopdy.fixture.chat-performance.type"
    nonisolated static let sendNotification = "app.loopdy.fixture.chat-performance.send"
    nonisolated static let openNotification = "app.loopdy.fixture.chat-performance.open"
    nonisolated static let listNotification = "app.loopdy.fixture.chat-performance.list"
    nonisolated static let notifications = [scrollNotification, typeNotification, sendNotification, openNotification,
                                            listNotification]

    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    private var tick: ((CFTimeInterval) -> Bool)?
    private var opened = 0

    func run(_ name: String, recorder: ChatPerformanceRecorder) {
        switch name {
        case Self.scrollNotification: scroll(recorder)
        case Self.typeNotification: type(recorder)
        case Self.sendNotification: send(recorder)
        case Self.openNotification:
            // The way a widget or Shortcut opens a chat; reads once it has had time to settle.
            // Each open takes the next long chat (`-test-long-chat-count`), then starts over.
            recorder.reset()
            opened = opened % LongChatPerformanceFixture.count(in: ProcessInfo.processInfo.arguments) + 1
            BighelpIncomingLinkCenter.shared.open(BighelpShortcutLinks.chat(LongChatPerformanceFixture.sessionID(opened)))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                recorder.read()
            }
        case Self.listNotification:
            // Back to the chat list, the way a link to it goes.
            BighelpIncomingLinkCenter.shared.open(URL(string: "loopdy://sessions")!)
        default: break
        }
    }

    /// Up through history at a fling's speed for four seconds (one reading), then
    /// back down to the newest message (another). `BIGHELP_PERF_SCROLL_SPEED` (points a
    /// second) goes faster: a heavy chat's answers are so tall that 3,000 passes few rows.
    private func scroll(_ recorder: ChatPerformanceRecorder) {
        guard let table = Self.view(ChatTimelineTableView.self, where: { _ in true }) else { return }
        table.followsTail = false
        recorder.reset()
        let speed = CGFloat(Double(ProcessInfo.processInfo.environment["BIGHELP_PERF_SCROLL_SPEED"] ?? "") ?? 3_000)
        var elapsed: CFTimeInterval = 0
        var goingUp = true
        animate { dt in
            elapsed += dt
            if goingUp {
                let top = -table.adjustedContentInset.top
                table.contentOffset.y = max(top, table.contentOffset.y - speed * dt)
                if elapsed >= 4 || table.contentOffset.y <= top {
                    goingUp = false
                    recorder.read()
                    recorder.reset()
                }
                return true
            }
            let bottom = table.bottomOffset
            table.contentOffset.y = min(bottom, table.contentOffset.y + speed * dt)
            guard table.contentOffset.y >= bottom - 0.5 else { return true }
            table.followsTail = true
            recorder.read()
            return false
        }
    }

    /// 60 characters at 15 a second, the way the keyboard puts them in.
    private func type(_ recorder: ChatPerformanceRecorder) {
        guard let editor = Self.view(UITextView.self, where: { $0.accessibilityIdentifier == "chat.composer.text" })
        else { return }
        _ = editor.becomeFirstResponder()
        let text = Array("Could you check the vendor invoices for this week, please?! ")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            recorder.reset()
            for character in text {
                editor.insertText(String(character))
                try? await Task.sleep(for: .milliseconds(66))
            }
            try? await Task.sleep(for: .milliseconds(500))
            recorder.read()
        }
    }

    /// Sends the draft (or a short request) and reads once the turn ends.
    private func send(_ recorder: ChatPerformanceRecorder) {
        guard let model = BighelpVisibleChats.shared.models.first else { return }
        if model.draft.isEmpty { model.draft = "Run the weekly checks" }
        recorder.reset()
        Task { @MainActor in
            await model.send()
            while model.isSending { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(500))
            recorder.read()
        }
    }

    private func animate(_ step: @escaping (CFTimeInterval) -> Bool) {
        link?.invalidate()
        tick = step
        lastFrame = nil
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastFrame = now }
        guard let lastFrame, let tick else { return }
        // A stalled frame moves the list as far as the time it took, like a finger would.
        if !tick(now - lastFrame) {
            link.invalidate()
            self.link = nil
            self.tick = nil
        }
    }

    private static func view<T: UIView>(_ type: T.Type, where matches: (T) -> Bool) -> T? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        func search(_ view: UIView) -> T? {
            if let match = view as? T, matches(match) { return match }
            for child in view.subviews { if let match = search(child) { return match } }
            return nil
        }
        for window in windows { if let match = search(window) { return match } }
        return nil
    }
}
#endif
