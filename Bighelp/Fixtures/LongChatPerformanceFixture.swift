#if DEBUG
import Foundation
import UIKit

/// `-test-long-chat <turns>`: long chats shaped like real use, for measuring how
/// the chat copes with history (`ChatLoadSpeedUITests`). Each turn is a question,
/// the agent's thinking and tool calls, and a Markdown answer: lists, links,
/// inline code, a code block every third turn, a table every tenth, a quiet
/// note on the way every fifth and a photo from the person every 25th.
/// `-test-long-chat-count <n>` adds more such chats (for opening several in a
/// row). `-test-long-chat-heavy` makes each turn as big as a chat near half a
/// million tokens: tool results of 20 to 200 KB, long thinking, pasted logs and
/// long answers with big code blocks. Made-up vendors, amounts and files.
enum LongChatPerformanceFixture {
    static let turnsArgument = "-test-long-chat"
    static let countArgument = "-test-long-chat-count"
    static let heavyArgument = "-test-long-chat-heavy"
    static let startArgument = "-start-long-chat"

    static func sessionID(_ index: Int) -> String { "demo-long-chat-\(index)" }

    static func turns(in arguments: [String]) -> Int? {
        guard let index = arguments.firstIndex(of: turnsArgument), arguments.indices.contains(index + 1) else {
            return nil
        }
        return Int(arguments[index + 1]).map { min(max($0, 1), 5_000) }
    }

    static func records(arguments: [String]) -> [SessionRecord] {
        guard let turns = turns(in: arguments) else { return [] }
        let photo = photoAttachment()
        let heavy = arguments.contains(heavyArgument)
        return (1...count(in: arguments)).map { record(index: $0, turns: turns, heavy: heavy, photo: photo) }
    }

    static func count(in arguments: [String]) -> Int {
        arguments.firstIndex(of: countArgument)
            .flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
            .map { min(max($0, 1), 8) } ?? 1
    }

    /// The newest answer's last line, for tests waiting on the bottom of the chat.
    static func sentinel(turns: Int) -> String { "Long chat sentinel \(turns)" }

    private static func record(index: Int, turns: Int, heavy: Bool, photo: [ChatAttachment]) -> SessionRecord {
        let sessionID = sessionID(index)
        let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery Park"))
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var items: [TimelineItem] = []
        var activity: [ChatActivityEvent] = []
        var order = 1
        func next() -> Int { defer { order += 1 }; return order }
        for turn in 1...turns {
            let turnID = "\(sessionID)-turn-\(turn)"
            let asked = start.addingTimeInterval(TimeInterval(turn * 300))
            items.append(TimelineItem(
                id: "\(sessionID)-human-\(turn)", role: .human, sender: .user(snapshot: .init(name: "You")),
                content: .message(heavy && turn.isMultiple(of: 4) ? question(turn) + pastedLog(turn) : question(turn)),
                metadata: .init(delivery: "Saved", timestamp: asked, sourceOrder: next()),
                attachments: turn.isMultiple(of: 25) ? photo : []))
            activity.append(ChatActivityEvent(
                eventID: "\(turnID)-thinking", sessionID: sessionID, turnID: turnID, kind: .reasoning,
                lifecycle: .succeeded, title: "Reasoning", summary: nil,
                detail: heavy ? longThinking(turn) : thinking(turn),
                occurredAt: order, durationMilliseconds: 2_400 + (turn % 7) * 300, sourceOrder: next()))
            if turn.isMultiple(of: 5) {
                items.append(TimelineItem(
                    id: "\(sessionID)-note-\(turn)", role: .assistant, sender: agent,
                    content: .message("Looking at week \(turn)'s export first, then the payment calendar."),
                    metadata: .init(delivery: "Saved", timestamp: asked.addingTimeInterval(8), sourceOrder: next())))
            }
            for (step, tool) in (heavy ? heavyTools(turn) : tools(turn)).enumerated() {
                activity.append(ChatActivityEvent(
                    eventID: "\(turnID)-tool-\(step)", sessionID: sessionID, turnID: turnID, kind: .tool,
                    lifecycle: .succeeded, title: tool.name, summary: nil, detail: nil, occurredAt: order,
                    durationMilliseconds: 600 + step * 450, toolCallID: "\(turnID)-call-\(step)",
                    toolName: tool.name, arguments: tool.arguments, result: tool.result, sourceOrder: next()))
            }
            let body = heavy ? heavyAnswer(turn) : self.answer(turn)
            let answer = turn == turns ? body + "\n\n" + sentinel(turns: turns) : body
            items.append(TimelineItem(
                id: "\(sessionID)-answer-\(turn)", role: .assistant, sender: agent, content: .message(answer),
                metadata: .init(delivery: "Saved", timestamp: asked.addingTimeInterval(42), sourceOrder: next(),
                                turnDurationMilliseconds: 42_000)))
        }
        return SessionRecord(id: sessionID, kind: .direct, agentIDs: ["finance"],
                             title: index == 1 ? "Vendor invoices" : "Vendor invoices \(index)",
                             items: items, activityEvents: activity, hasAcceptedMessage: true)
    }

    private static let vendors = ["Northwind Supplies", "Blue Harbor Print", "Cedar & Pine Catering",
                                  "Lumen Office Co.", "Quarry Street Movers", "Parcel Bay"]

    private static func question(_ turn: Int) -> String {
        switch turn % 4 {
        case 0: "Can you check week \(turn)'s vendor invoices and tell me what's unusual?"
        case 1: "What did \(vendors[turn % vendors.count]) bill us in week \(turn)? Anything late?"
        case 2: "Draft a short note to the team about week \(turn)'s payments.\nKeep it friendly and under 100 words."
        default: "Compare week \(turn) with the week before. Where did the money go?"
        }
    }

    private static func thinking(_ turn: Int) -> String {
        "The person wants week \(turn)'s invoices. I'll read the export, total it by vendor, and check the "
            + "payment calendar for anything due before Friday. Missing PO numbers are worth calling out."
    }

    private static func tools(_ turn: Int) -> [(name: String, arguments: String, result: String)] {
        let rows = (0..<6).map { row in
            #"{"vendor":"\#(vendors[(turn + row) % vendors.count])","amount":\#(120 + (turn * 37 + row * 91) % 1_800).00,"po":"PO-\#(turn)\#(row)"}"#
        }.joined(separator: ",")
        var tools = [
            (name: "read_file", arguments: #"{"path":"finance/vendors/2026-w\#(turn).csv"}"#,
             result: #"{"rows":[\#(rows)],"total_rows":6}"#),
            (name: "terminal", arguments: #"{"command":"python3 totals.py --week \#(turn)"}"#,
             result: #"{"output":"6 invoices, 2 without a PO number","exit_code":0}"#),
        ]
        if turn.isMultiple(of: 3) {
            tools.append((name: "web_search", arguments: #"{"query":"\#(vendors[turn % vendors.count]) payment terms"}"#,
                          result: #"{"results":[{"title":"Payment terms","url":"https://example.com/terms"}]}"#))
        }
        return tools
    }

    private static func answer(_ turn: Int) -> String {
        let vendor = vendors[turn % vendors.count]
        let amount = 900 + (turn * 137) % 2_400
        var text = """
        ### Week \(turn) at a glance

        I read **6 invoices** from `finance/vendors/2026-w\(turn).csv`. Here's what stands out:

        - \(vendor) billed **$\(amount).00**, up \(turn % 9 + 1)% on the week before.
        - Two invoices have no PO number: `INV-\(turn)01` and `INV-\(turn)07`.
        - The [payment calendar](https://example.com/payments/week-\(turn)) has the next run on *Friday*.
        """
        if turn.isMultiple(of: 3) {
            text += """


            Here's the check I ran, if you want to run it yourself:

            ```python
            import csv

            def totals(path):
                by_vendor = {}
                with open(path) as file:
                    for row in csv.DictReader(file):
                        amount = float(row["amount"])
                        by_vendor[row["vendor"]] = by_vendor.get(row["vendor"], 0) + amount
                return sorted(by_vendor.items(), key=lambda pair: -pair[1])

            print(totals("2026-w\(turn).csv"))
            ```
            """
        }
        if turn.isMultiple(of: 10) {
            text += """


            | Vendor | Amount | Due |
            |---|---:|---|
            | \(vendors[(turn + 1) % vendors.count]) | $\(amount - 200).00 | Friday |
            | \(vendors[(turn + 2) % vendors.count]) | $\(amount / 2).00 | Monday |
            | \(vendors[(turn + 3) % vendors.count]) | $\(amount / 3).00 | Next week |
            """
        }
        text += "\n\n> Nothing here is overdue yet.\n\nWant me to email \(vendor) about the missing PO numbers?"
        return text
    }

    // MARK: Heavy turns

    /// About 3 KB of thinking.
    private static func longThinking(_ turn: Int) -> String {
        (0..<8).map { step in
            "Step \(step + 1) for week \(turn): the export has \(40 + (turn + step) % 60) rows. "
                + "\(vendors[(turn + step) % vendors.count]) shows up \(step + 2) times; I should check whether "
                + "the PO numbers match the purchase log, whether any amount is above the approval limit of "
                + "$\(1_000 + step * 250).00, and whether the due dates fall before the next payment run."
        }.joined(separator: "\n\n")
    }

    /// A log of about 4 KB the person pasted under the question.
    private static func pastedLog(_ turn: Int) -> String {
        "\n\n```\n" + (0..<48).map { line in
            "2026-09-\(10 + line % 18)T0\(line % 10):\(10 + line % 50):00Z sync[\(4_000 + turn)] "
                + "invoice INV-\(turn)\(line) \(line.isMultiple(of: 7) ? "WARN missing PO" : "ok")"
        }.joined(separator: "\n") + "\n```"
    }

    /// One read of 20 to 200 KB, a terminal run of a few KB, and every third turn a search.
    private static func heavyTools(_ turn: Int) -> [(name: String, arguments: String, result: String)] {
        let size = 20_000 + (turn * 7_919) % 180_000
        var csv = "invoice,vendor,amount,po,due,notes\n"
        csv.reserveCapacity(size + 200)
        var line = 0
        while csv.utf8.count < size {
            csv += "INV-\(turn)-\(line),\(vendors[(turn + line) % vendors.count]),"
                + "\(100 + (turn * 37 + line * 91) % 4_800).\(line % 100),PO-\(turn)\(line),2026-10-\(1 + line % 28),"
                + "\(line.isMultiple(of: 11) ? "needs review" : "matched")\n"
            line += 1
        }
        let log = (0..<120).map { step in
            "[\(step)] checked INV-\(turn)-\(step * 3): \(step.isMultiple(of: 9) ? "no PO number" : "ok") "
                + "total so far $\(1_000 + step * 37).00"
        }.joined(separator: "\n")
        var tools = [
            (name: "read_file", arguments: #"{"path":"finance/vendors/2026-w\#(turn)-full.csv"}"#,
             result: #"{"content":"\#(csv.replacingOccurrences(of: "\n", with: "\\n"))","total_lines":\#(line)}"#),
            (name: "terminal", arguments: #"{"command":"python3 totals.py --week \#(turn) --verbose"}"#,
             result: #"{"output":"\#(log.replacingOccurrences(of: "\n", with: "\\n"))","exit_code":0}"#),
        ]
        if turn.isMultiple(of: 3) {
            tools.append((name: "web_search", arguments: #"{"query":"\#(vendors[turn % vendors.count]) payment terms"}"#,
                          result: #"{"results":[{"title":"Payment terms","url":"https://example.com/terms"}]}"#))
        }
        return tools
    }

    /// The usual answer, then more sections, and every other turn a long code block.
    private static func heavyAnswer(_ turn: Int) -> String {
        var text = answer(turn)
        text += "\n\n" + (1...4).map { section in
            """
            #### Part \(section): \(vendors[(turn + section) % vendors.count])

            The \(section == 1 ? "largest" : "next") vendor this week sent \(section + 2) invoices. Two of them \
            arrived after the cut-off, so they move to the next run unless you approve them by **Thursday**. \
            The totals match the purchase log to the cent, and the [statement](https://example.com/s/\(turn)-\(section)) \
            agrees with the export. See `INV-\(turn)-\(section * 3)` for the one with a changed bank account.
            """
        }.joined(separator: "\n\n")
        if turn.isMultiple(of: 2) {
            let lines = 120 + (turn * 13) % 280
            text += "\n\nThe full script:\n\n```python\n" + (0..<lines).map { line in
                switch line % 6 {
                case 0: "def check_\(line)(rows):  # week \(turn)"
                case 1: "    flagged = [row for row in rows if not row.get(\"po\") or float(row[\"amount\"]) > \(line * 10)]"
                case 2: "    totals = {row[\"vendor\"]: 0.0 for row in rows}"
                case 3: "    for row in rows: totals[row[\"vendor\"]] += float(row[\"amount\"])"
                case 4: "    print(f\"{len(flagged)} flagged, {sum(totals.values()):.2f} total\")"
                default: "    return flagged, totals\n"
                }
            }.joined(separator: "\n") + "\n```"
        }
        return text
    }

    /// A made-up photo the person sent; one copy shared by every turn that has it.
    private static func photoAttachment() -> [ChatAttachment] {
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).pngData { context in
            let colors = [UIColor(red: 0.55, green: 0.78, blue: 0.95, alpha: 1).cgColor,
                          UIColor(red: 0.20, green: 0.32, blue: 0.62, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 600), options: [])
            }
            UIColor.white.withAlphaComponent(0.8).setFill()
            context.cgContext.fill(CGRect(x: 120, y: 140, width: 560, height: 320))
        }
        return (try? ChatAttachment(id: "long-chat-receipt-photo", fileName: "receipt.png",
                                    mimeType: "image/png", data: photo)).map { [$0] } ?? []
    }
}
#endif
