import Foundation

/// Demo mode's Activities read-outs, one for each kind of work on the demo's busy day. Made-up work only.
extension DemoAgentBoardClient {
    var supportsTodayDetail: Bool { true }

    func todayDetail(agentID: String, item: AgentTodayItem) async throws -> AgentTodayDetail {
        let start = item.startedAt ?? .now
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
        typealias Step = AgentTodayDetail.Step
        let body: AgentTodayDetail.Body
        switch item.id {
        case "delegation:hotels":
            body = .subagent(.init(
                goal: "Compare hotels near Alfama for October: under €180 a night, a quiet room, walking distance to the tram.",
                model: "demo-model", summary: nil, error: nil,
                steps: [
                    Step(id: 0, at: at(0.1), kind: .tool, tool: "web_search", preview: "alfama hotels october quiet room", state: .done),
                    Step(id: 1, at: at(0.8), kind: .tool, tool: "web_extract", preview: "booking.example/alfama", state: .done),
                    Step(id: 2, at: at(1.6), kind: .message, tool: nil,
                         preview: "Six places fit the price. Two are on the tram line and one has rooms facing the courtyard.", state: nil),
                    Step(id: 3, at: at(2.4), kind: .tool, tool: "web_search", preview: "memmo alfama reviews noise", state: .done),
                    Step(id: 4, at: at(3.5), kind: .tool, tool: "read_file", preview: "lisbon-trip.md", state: .running),
                ],
                stepsTruncated: false))
        case "delegation:dinner":
            body = .subagent(.init(
                goal: "Shortlist restaurants for Sam's birthday on the 7th: six people, a table at 8, not too loud.",
                model: "demo-model",
                summary: """
                    Three places have a table for six at 8 on the 7th:

                    1. **Taberna da Rua** · Portuguese, quiet back room, €€
                    2. **Prado** · seasonal plates, can do a cake, €€€
                    3. **O Velho Eurico** · small and loud on weekends, but the 7th is a Tuesday, €

                    Prado is the best fit if you want the cake. I didn't book anything.
                    """,
                error: nil,
                steps: [
                    Step(id: 0, at: at(0.2), kind: .tool, tool: "web_search", preview: "lisbon restaurant table for 6 quiet", state: .done),
                    Step(id: 1, at: at(1.5), kind: .tool, tool: "web_extract", preview: "tabernadarua.example/reservas", state: .done),
                    Step(id: 2, at: at(2.7), kind: .tool, tool: "web_extract", preview: "prado.example/book", state: .failed),
                    Step(id: 3, at: at(3.1), kind: .thinking, tool: nil, preview: "Prado's booking page didn't load. Their menu page lists the phone hours.", state: nil),
                    Step(id: 4, at: at(4.8), kind: .tool, tool: "web_search", preview: "o velho eurico reviews tuesday", state: .done),
                    Step(id: 5, at: at(8.2), kind: .message, tool: nil, preview: "Three places fit. Writing the list.", state: nil),
                ],
                stepsTruncated: false))
        case "process:fares":
            body = .command(.init(
                command: item.title, exitCode: nil,
                output: """
                    [08:00] AUS → LIS  Oct 9–19   $498  (TAP, 1 stop)
                    [08:30] AUS → LIS  Oct 9–19   $481  (TAP, 1 stop)
                    [09:00] AUS → LIS  Oct 9–19   $466  (United + TAP)
                    [09:30] AUS → LIS  Oct 9–19   $437  (TAP, 1 stop)  ↓ new low
                    [10:00] AUS → LIS  Oct 9–19   $412  (TAP, 1 stop)  ↓ new low
                    Watching. Next check in 30 min.
                    """,
                outputTruncated: true))
        case "message:sleep":
            body = .command(.init(
                command: item.title, exitCode: 1,
                output: """
                    Syncing sleep data…
                    Found 7 nights since Oct 1
                    Uploading night 1 of 7… done
                    Uploading night 2 of 7… failed: the sleep service didn't answer (timed out after 30 s)
                    Stopped after 3 tries.
                    """,
                outputTruncated: false))
        case "cron:brief":
            body = .scheduled(.init(
                job: "Morning brief", status: "ok",
                output: """
                    # Cron Job: Morning brief

                    **Schedule:** every day at 8:00

                    ## Prompt

                    Write my morning brief: weather, calendar, and anything new on the Lisbon trip.

                    ## Response

                    **Good morning.** Here's today:

                    - **Weather:** 31° and sunny, a light wind after 4.
                    - **Calendar:** dentist at 10:30, team call at 2.
                    - **Lisbon:** fares dropped again, now $412 for Oct 9–19.

                    Nothing needs you before 10.
                    """,
                error: nil))
        default:
            body = .none
        }
        return AgentTodayDetail(item: item, body: body)
    }
}
