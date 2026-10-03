import Foundation
import Testing
@testable import Bighelp

/// Plain words for tool calls, from the real tool name and arguments: what a
/// live folder shimmers ("Reading notes.md…") and what a finished one says
/// it did ("Read 2 files, ran tests").
struct ChatToolPhraseTests {
    private func phrase(_ name: String?, _ arguments: String? = nil) -> ChatToolPhrase {
        ChatToolPhrase.phrase(forTool: name, arguments: arguments)
    }

    private func command(_ command: String) -> ChatToolPhrase {
        let json = try! JSONSerialization.data(withJSONObject: ["command": command])
        return phrase("terminal", String(decoding: json, as: UTF8.self))
    }

    @Test func filesAreNamedByTheirBaseName() {
        let read = phrase("read_file", #"{"path":"/Users/demo/projects/app/notes.md","offset":1}"#)
        #expect(read.live == "Reading notes.md…")
        #expect(read.past == "Read notes.md")
        #expect(phrase("write_file", #"{"path":"reports/Kyoto plan.md","content":"Plan"}"#).live
                == "Writing Kyoto plan.md…")
        #expect(phrase("patch", #"{"path":"Sources/App.swift","old_string":"a","new_string":"b"}"#).past
                == "Edited App.swift")
        // Without a usable name the words stay general, never empty.
        #expect(phrase("read_file").live == "Reading a file…")
        #expect(phrase("read_file", #"{"path":"/"}"#).past == "Read a file")
        #expect(phrase("read_file", "not json").past == "Read a file")
    }

    @Test func commandsSayWhatTheyDoNotWhatTheyType() {
        #expect(command("git clone https://github.com/example/weather-app.git").live == "Cloning weather-app…")
        #expect(command("git clone https://github.com/example/weather-app.git").past == "Cloned weather-app")
        #expect(command("cd ~/code/app && git status --short").live == "Checking the repo…")
        #expect(command("git -C ~/code/app log --oneline -5").past == "Checked the repo")
        #expect(command("git commit -m 'Fix the thing'").live == "Committing changes…")
        #expect(command("git push origin main").past == "Pushed changes")
        #expect(command("gh pr list --state open").live == "Checking GitHub…")
        #expect(command("gh pr create --title Fix --body Done").past == "Opened a pull request")
        #expect(command("npm install").live == "Installing packages…")
        #expect(command("pip install -r requirements.txt").past == "Installed packages")
        #expect(command("npm test").live == "Running tests…")
        #expect(command("cd app; swift test --filter ChatModelTests").past == "Ran tests")
        #expect(command("python3 -m pytest -q").live == "Running tests…")
        #expect(command("npx jest --watch=false").live == "Running tests…")
        #expect(command("swift build").live == "Building the project…")
        #expect(command("cat README.md | head -20").live == "Reading README.md…")
        #expect(command("rg TODO src").live == "Searching files…")
        #expect(command("ls -la ~/Documents").live == "Looking through files…")
        #expect(command("curl -s https://api.example.com/v1/forecast?q=kyoto").live == "Fetching api.example.com…")
        #expect(command("python3 scripts/export_report.py --month 9").live == "Running export_report.py…")
        #expect(command("FOO=1 sudo -E make").live == "Building the project…")
        #expect(command("echo start\nmkdir -p out").live == "Making a folder…")
        // Anything else names only its program.
        #expect(command("ffmpeg -i in.mov out.mp4").live == "Running ffmpeg…")
        #expect(command("ffmpeg -i in.mov out.mp4").past == "Ran ffmpeg")
        #expect(command("").live == "Running a command…")
    }

    /// The words are built from names, never the arguments' free text:
    /// tokens, queries, messages and code stay out of the collapsed line.
    @Test func secretsInArgumentsNeverReachThePhrase() {
        let words: [ChatToolPhrase] = [
            command("/usr/local/bin/swift test --filter ChatModelTests --token super-secret"),
            command("curl -H 'Authorization: Bearer super-secret' https://user:super-secret@api.example.com/x"),
            command("git clone https://super-secret@github.com/example/private-repo.git"),
            command("export TOKEN=super-secret && ./deploy.sh"),
            phrase("web_search", #"{"query":"super-secret medical question"}"#),
            phrase("execute_code", #"{"code":"api_key = 'super-secret'"}"#),
            phrase("send_message", #"{"message":"super-secret"}"#),
            phrase("read_file", #"{"path":"/tmp/super-secret$(rm -rf).txt"}"#),
            phrase("tool_call", #"{"name":"web_search","arguments":{"query":"super-secret"}}"#),
        ]
        for phrase in words {
            for text in [phrase.live, phrase.past, phrase.summaryOne] {
                #expect(!text.contains("super-secret"), "\(text)")
                #expect(!text.contains("Bearer"), "\(text)")
            }
        }
        #expect(command("git clone https://super-secret@github.com/example/private-repo.git").live
                == "Cloning private-repo…")
        #expect(command("curl -H 'Authorization: Bearer super-secret' https://user:super-secret@api.example.com/x").live
                == "Fetching api.example.com…")
    }

    @Test func webAndServiceToolsUsePlainWords() {
        #expect(phrase("web_search", #"{"query":"ryokan near Gion"}"#).live == "Searching the web…")
        #expect(phrase("web_extract", #"{"urls":["https://www.example.com/guide"]}"#).live == "Reading example.com…")
        #expect(phrase("web_extract", #"{"urls":["https://a.example/1","https://b.example/2"]}"#).live
                == "Reading 2 web pages…")
        #expect(phrase("browser_navigate", #"{"url":"https://stays.example/gion"}"#).live == "Opening stays.example…")
        #expect(phrase("browser_click", #"{"ref":"@e3"}"#).live == "Browsing the web…")
        // MCP and plugin tools are named by the service they reach.
        #expect(phrase("mcp_google_calendar_list_events").live == "Checking your calendars…")
        #expect(phrase("mcp_google_calendar_create_event").past == "Updated your calendar")
        #expect(phrase("mcp_github_search_issues").live == "Checking GitHub…")
        #expect(phrase("mcp_gmail_send_email").live == "Sending an email…")
        #expect(phrase("mcp_slack_list_channels").past == "Checked Slack")
        #expect(phrase("process", #"{"action":"wait","session_id":"proc_1"}"#).live
                == "Waiting for a command to finish…")
        #expect(phrase("process", #"{"action":"poll"}"#).live == "Checking a running command…")
        #expect(phrase("skill_view", #"{"name":"github-pr-workflow"}"#).live == "Reading the github-pr-workflow skill…")
        // Unknown tools keep the catalog's careful words.
        #expect(phrase("acme_sync_ledger").live == "Using tools…")
        #expect(phrase(nil).live == "Using tools…")
        #expect(phrase("tool_call", #"{"name":"web_search","arguments":{"query":"x"}}"#).live == "Searching the web…")
    }

    @Test func aFinishedFolderSaysWhatItDidInThePastTense() {
        func summary(_ phrases: [ChatToolPhrase]) -> String? { ChatToolSummary.summary(of: phrases) }
        #expect(summary([]) == nil)
        #expect(summary([phrase("web_search")]) == "Searched the web")
        #expect(summary([
            phrase("read_file", #"{"path":"a.md"}"#), command("ls"), phrase("read_file", #"{"path":"b.md"}"#),
        ]) == "Read 2 files, looked through files")
        #expect(summary([phrase("read_file", #"{"path":"a.md"}"#), command("npm test")]) == "Read a.md, ran tests")
        #expect(summary([phrase("acme_one"), phrase("acme_two"), phrase("acme_three"), phrase("web_search")])
                == "Called 3 tools, searched the web")
        #expect(summary([command("ffmpeg -i a b"), command("convert x y")]) == "Ran 2 commands")
        #expect(summary([phrase("web_search"), phrase("web_search")]) == "Searched the web 2 times")
        // A long run names its first three kinds of work, then says there was more.
        #expect(summary([
            phrase("web_search"), phrase("read_file"), command("npm test"), command("git push"), phrase("memory"),
        ]) == "Searched the web, read a file, ran tests, and more")
        // Commands that read files count with the reads.
        #expect(summary([command("cat a.txt"), phrase("read_file", #"{"path":"b.txt"}"#)]) == "Read 2 files")
    }

    @MainActor
    @Test func eventsCarryTheirPhraseAndSubagentsAskForHelp() {
        let event = ChatActivityEvent(eventID: "e", sessionID: "s", turnID: "t", kind: .tool, lifecycle: .running,
                                      title: "Tool", summary: nil, detail: nil, occurredAt: 1, toolCallID: "c",
                                      toolName: "read_file", arguments: #"{"path":"notes.md"}"#)
        #expect(event.toolPhrase.live == "Reading notes.md…")
        let helper = ChatActivityEvent(eventID: "h", sessionID: "s", turnID: "t", kind: .subagent,
                                       lifecycle: .running, title: "Research ryokans", summary: nil, detail: nil,
                                       occurredAt: 1, subagentID: "sub-1")
        #expect(helper.toolPhrase.live == "Asking another agent…")
        // The step line names the program that does the work, not the `cd` before it.
        let tests = ChatActivityEvent(eventID: "n", sessionID: "s", turnID: "t", kind: .tool, lifecycle: .succeeded,
                                      title: "Tool", summary: nil, detail: nil, occurredAt: 1, toolCallID: "n",
                                      toolName: "terminal", arguments: #"{"command":"cd app && npm test"}"#)
        #expect(ChatActivityPresentation.step(for: tests).label == "Ran tests")
        #expect(ChatActivityPresentation.step(for: tests).detail == "npm")
        #expect(ChatToolSummary.summary(of: [helper, helper.updating(lifecycle: .succeeded, summary: nil,
                                                                      detail: nil, occurredAt: 2)])
                == "Asked 2 other agents")
    }
}
