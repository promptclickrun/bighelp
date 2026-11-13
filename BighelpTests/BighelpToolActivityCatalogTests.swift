import Foundation
import Testing
@testable import Bighelp

struct BighelpToolActivityCatalogTests {
    @Test func realHermesToolsGetFriendlyPresentTenseLabels() {
        let expected: [String: String] = [
            "read_file": "Reading a file…",
            "write_file": "Writing a file…",
            "patch": "Editing a file…",
            "search_files": "Searching files…",
            "terminal": "Running a command…",
            "process": "Checking a running command…",
            "execute_code": "Running code…",
            "web_search": "Searching the web…",
            "web_extract": "Reading a web page…",
            "browser_navigate": "Browsing the web…",
            "browser_click": "Browsing the web…",
            "image_generate": "Making an image…",
            "video_generate": "Making a video…",
            "vision_analyze": "Looking at an image…",
            "memory": "Updating memory…",
            "session_search": "Searching past chats…",
            "skill_view": "Reading a skill…",
            "todo": "Updating the to-do list…",
            "todo_list": "Updating the to-do list…",
            "cronjob": "Scheduling a task…",
            "clarify": "Asking you a question…",
            "delegate_task": "Asking another bot…",
            "send_message": "Sending a message…",
            "text_to_speech": "Making a voice clip…",
            "bighelp_board": "Posting an update…",
            "bighelp_render_card": "Making a card…",
            "kanban_create": "Updating the board…",
            "kanban_list": "Checking the board…",
            "ha_call_service": "Controlling a device…",
            "ha_get_state": "Checking your home…",
        ]
        for (tool, label) in expected {
            #expect(BighelpToolActivityCatalog.activity(forTool: tool).label == label, "\(tool)")
        }
    }

    @Test func everyToolTheAppAlreadyRecognizesHasItsOwnEntry() {
        // Names the chat, the live avatar (`BighelpActivityPose`), generated media,
        // to-do and clarify handling already key on.
        let handled = [
            "terminal", "execute_code", "process", "patch", "web_search", "web_extract", "browser_navigate",
            "vision_analyze", "memory", "session_search", "skill_view", "cronjob", "delegate_task", "read_file",
            "write_file", "search_files", "send_message", "text_to_speech", "bighelp_board", "clarify",
            "image_generate", "video_generate", "todo", "todo_list", "bighelp_request_secure_input",
            "loopdy_render_card",
        ]
        for tool in handled {
            #expect(BighelpToolActivityCatalog.activity(forTool: tool) != BighelpToolActivityCatalog.fallback, "\(tool)")
        }
    }

    @Test func unknownMissingOrOversizedNamesSayUsingTools() {
        for name in [nil, "", "   ", "some_new_plugin_tool", "mcp_github_create_issue", String(repeating: "x", count: 500)] {
            let activity = BighelpToolActivityCatalog.activity(forTool: name)
            #expect(activity == BighelpToolActivityCatalog.fallback)
            #expect(activity.label == "Using tools…")
        }
    }

    @Test func namesMatchWhateverTheirCaseOrSpacing() {
        #expect(BighelpToolActivityCatalog.activity(forTool: "  Read_File\n").label == "Reading a file…")
        #expect(BighelpToolActivityCatalog.activity(forTool: "WEB_SEARCH").label == "Searching the web…")
    }

    @Test func thePluginsOlderLoopdyNamesMatchTheirBighelpNames() {
        #expect(BighelpToolActivityCatalog.activity(forTool: "loopdy_render_card")
                == BighelpToolActivityCatalog.activity(forTool: "bighelp_render_card"))
        #expect(BighelpToolActivityCatalog.activity(forTool: "loopdy_board")
                == BighelpToolActivityCatalog.activity(forTool: "bighelp_board"))
    }

    @Test func savedLoginsAreNotJustBrowsing() {
        #expect(BighelpToolActivityCatalog.activity(forTool: "browser_vault_fill").label == "Using a saved login…")
        #expect(BighelpToolActivityCatalog.activity(forTool: "browser_vault_fill").glyph == .glyph(.key))
    }

    @Test func labelsReadAsLiveWorkAndFinishedSteps() {
        let tools = ["read_file", "write_file", "patch", "terminal", "web_search", "browser_back", "delegate_task",
                     "image_generate", "memory", "cronjob_manage", "kanban_show", "ha_list_entities", "unknown"]
        for tool in tools {
            let activity = BighelpToolActivityCatalog.activity(forTool: tool)
            #expect(activity.label.hasSuffix("…"), "\(tool)")
            #expect(!activity.doneLabel.hasSuffix("…"), "\(tool)")
            #expect(!activity.doneLabel.isEmpty)
        }
        #expect(BighelpToolActivityCatalog.thinking.label == "Thinking")
        #expect(BighelpToolActivityCatalog.thinking.glyph == .thinking)
    }

    @Test func glyphsPreferBighelpsOwnDrawings() {
        #expect(BighelpToolActivityCatalog.activity(forTool: "terminal").glyph == .glyph(.terminal))
        #expect(BighelpToolActivityCatalog.activity(forTool: "read_file").glyph == .glyph(.doc))
        #expect(BighelpToolActivityCatalog.activity(forTool: "delegate_task").glyph == .glyph(.agents))
        #expect(BighelpToolActivityCatalog.fallback.glyph == .glyph(.tools))
        // Where bighelp has no glyph, an SF Symbol stands in.
        #expect(BighelpToolActivityCatalog.activity(forTool: "web_search").glyph == .symbol("magnifyingglass"))
    }
}
