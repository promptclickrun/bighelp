import Foundation
import os

/// Plain words for one tool call, from its real Hermes tool name and
/// arguments: "Reading notes.md…" while it runs, "Read notes.md" once it
/// ends, and how it counts in a finished folder's summary ("Read 2 files").
///
/// The words only ever name things: a file's base name, a web address's host,
/// a repo's name, a program. They never quote free text from the arguments
/// (queries, messages, code, flags or tokens), because the collapsed line
/// shows on screen, in screenshots and to VoiceOver. Anything that doesn't
/// look like a plain name falls back to general words ("Reading a file…").
struct ChatToolPhrase: Equatable, Sendable {
    /// Present tense for the live folder: "Reading notes.md…".
    let live: String
    /// Past tense for a finished call: "Read notes.md".
    let past: String
    /// Calls with the same key count together in a summary.
    let summaryKey: String
    /// The summary's words for one such call: "Read notes.md".
    let summaryOne: String
    /// The summary's words for several, with `%d` for the count: "Read %d
    /// files". Nil repeats `summaryOne` once ("Ran tests").
    let summaryMany: String?

    init(live: String, past: String, key: String? = nil, one: String? = nil, many: String? = nil) {
        self.live = live
        self.past = past
        summaryKey = key ?? past
        summaryOne = one ?? past
        summaryMany = many
    }

    /// The words for a call to `name` with these (JSON) arguments.
    static func phrase(forTool name: String?, arguments: String?) -> ChatToolPhrase {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tool = name.map { $0.hasPrefix("loopdy_") ? "bighelp_" + $0.dropFirst("loopdy_".count) : $0 }
        let parsed = ChatToolArguments(arguments)
        // `tool_call` only wraps another tool and its arguments.
        if tool == "tool_call" {
            let nested = parsed.string("name").flatMap { ChatToolNames.plainName($0) }
            return nested.map { phrase(forTool: $0, arguments: parsed.json("arguments")) } ?? unknown
        }
        if let tool, let specific = specific(tool, parsed) { return specific }
        let activity = BighelpToolActivityCatalog.activity(forTool: tool)
        if activity == BighelpToolActivityCatalog.fallback {
            if let tool, let service = ChatToolServicePhrase.phrase(forTool: tool) { return service }
            return unknown
        }
        return ChatToolPhrase(live: activity.label, past: activity.doneLabel, key: catalogKeys[activity.doneLabel],
                              many: catalogPlurals[activity.doneLabel])
    }

    /// An unknown tool keeps the catalog's careful words; the summary counts it.
    private static let unknown = ChatToolPhrase(
        live: BighelpToolActivityCatalog.fallback.label, past: BighelpToolActivityCatalog.fallback.doneLabel,
        key: "tool", one: "Called a tool", many: "Called %d tools")

    /// Catalog words that count together with the named versions above.
    private static let catalogKeys: [String: String] = [
        "Read a file": "read", "Wrote a file": "write", "Edited a file": "edit", "Searched files": "search-files",
        "Ran a command": "command", "Read a web page": "web-page",
    ]

    /// Several of the same catalog action, counted.
    private static let catalogPlurals: [String: String] = [
        "Read a file": "Read %d files",
        "Wrote a file": "Wrote %d files",
        "Edited a file": "Edited %d files",
        "Searched files": "Searched files %d times",
        "Ran a command": "Ran %d commands",
        "Ran code": "Ran code %d times",
        "Searched the web": "Searched the web %d times",
        "Read a web page": "Read %d web pages",
        "Searched posts on X": "Searched posts on X %d times",
        "Made an image": "Made %d images",
        "Made a video": "Made %d videos",
        "Looked at an image": "Looked at %d images",
        "Watched a video": "Watched %d videos",
        "Made a voice clip": "Made %d voice clips",
        "Read a skill": "Read %d skills",
        "Asked you a question": "Asked you %d questions",
        "Asked another agent": "Asked %d other agents",
        "Sent a message": "Sent %d messages",
        "Made a card": "Made %d cards",
        "Posted an update": "Posted %d updates",
    ]

    private static func specific(_ tool: String, _ arguments: ChatToolArguments) -> ChatToolPhrase? {
        switch tool {
        case "read_file":
            return file(arguments, live: "Reading", past: "Read", key: "read", many: "Read %d files")
        case "write_file":
            return file(arguments, live: "Writing", past: "Wrote", key: "write", many: "Wrote %d files")
        case "patch":
            return file(arguments, live: "Editing", past: "Edited", key: "edit", many: "Edited %d files")
        case "search_files":
            return ChatToolPhrase(live: "Searching files…", past: "Searched files", key: "search-files",
                                  many: "Searched files %d times")
        case "terminal":
            guard let command = arguments.string("command") else { return nil }
            return ChatCommandPhrase.phrase(for: command)
        case "process", "process_manage":
            switch arguments.string("action")?.lowercased() {
            case "wait": return ChatToolPhrase(live: "Waiting for a command to finish…",
                                               past: "Waited for a command to finish", key: "process")
            case "kill", "stop", "terminate": return ChatToolPhrase(live: "Stopping a command…",
                                                                    past: "Stopped a command")
            case "write", "submit", "send": return ChatToolPhrase(live: "Answering a running command…",
                                                                  past: "Answered a running command")
            default: return nil
            }
        case "web_extract":
            let urls = arguments.strings("urls") + [arguments.string("url")].compactMap { $0 }
            if urls.count > 1 {
                return ChatToolPhrase(live: "Reading \(urls.count) web pages…", past: "Read \(urls.count) web pages",
                                      key: "web-page", one: "Read \(urls.count) web pages", many: "Read %d web pages")
            }
            guard let host = urls.first.flatMap(ChatToolNames.host) else { return nil }
            return ChatToolPhrase(live: "Reading \(host)…", past: "Read \(host)", key: "web-page",
                                  many: "Read %d web pages")
        case "browser_navigate":
            guard let host = arguments.string("url").flatMap(ChatToolNames.host) else { return nil }
            return ChatToolPhrase(live: "Opening \(host)…", past: "Opened \(host)", key: "Browsed the web",
                                  one: "Browsed the web")
        case "skill_view":
            guard let skill = arguments.string("name").flatMap({ ChatToolNames.plainName($0) }) else { return nil }
            return ChatToolPhrase(live: "Reading the \(skill) skill…", past: "Read the \(skill) skill",
                                  key: "Read a skill", many: "Read %d skills")
        default:
            return nil
        }
    }

    private static func file(_ arguments: ChatToolArguments, live: String, past: String, key: String,
                             many: String) -> ChatToolPhrase {
        let path = arguments.string("path") ?? arguments.string("file_path") ?? arguments.string("filename")
            ?? arguments.string("file")
        guard let name = path.flatMap(ChatToolNames.fileName) else {
            return ChatToolPhrase(live: "\(live) a file…", past: "\(past) a file", key: key, many: many)
        }
        return ChatToolPhrase(live: "\(live) \(name)…", past: "\(past) \(name)", key: key, many: many)
    }
}

/// A finished folder's (or turn's) past-tense summary: "Read 2 files, ran
/// tests". Kinds of work keep the order they first happened in.
enum ChatToolSummary {
    /// More kinds than this end with "and more"; the step count beside the
    /// summary still says how many there were.
    static let maximumParts = 3

    static func summary(of phrases: [ChatToolPhrase]) -> String? {
        var order: [String] = []
        var groups: [String: (phrase: ChatToolPhrase, count: Int)] = [:]
        for phrase in phrases {
            if let group = groups[phrase.summaryKey] {
                groups[phrase.summaryKey] = (group.phrase, group.count + 1)
            } else {
                order.append(phrase.summaryKey)
                groups[phrase.summaryKey] = (phrase, 1)
            }
        }
        let parts = order.prefix(maximumParts).compactMap { key -> String? in
            guard let group = groups[key] else { return nil }
            guard group.count > 1, let many = group.phrase.summaryMany else { return group.phrase.summaryOne }
            return many.replacingOccurrences(of: "%d", with: String(group.count))
        }
        guard let first = parts.first else { return nil }
        let rest = parts.dropFirst().map(lowercasingFirst)
        let more = order.count > maximumParts ? ["and more"] : []
        return ([first] + rest + more).joined(separator: ", ")
    }

    /// The steps among `events` (tool calls and helper agents), summarized.
    static func summary(of events: [ChatActivityEvent]) -> String? {
        summary(of: events.filter { $0.kind == .tool || $0.kind == .subagent }.map(\.toolPhrase))
    }

    private static func lowercasingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

extension ChatActivityEvent {
    /// This call's plain words. Remembered per call, so redrawing a long
    /// transcript doesn't parse the same arguments again.
    var toolPhrase: ChatToolPhrase {
        if kind == .subagent {
            return ChatToolPhrase.phrase(forTool: "delegate_task", arguments: nil)
        }
        guard kind == .tool else {
            let activity = presentationActivity
            return ChatToolPhrase(live: activity.label, past: activity.doneLabel)
        }
        let key = ChatToolPhraseCache.Key(id: id, toolName: toolName, argumentsSize: arguments?.utf8.count ?? -1)
        if let cached = ChatToolPhraseCache.phrase(for: key) { return cached }
        // A `tool_call` wrapper is read with its own arguments, which hold the nested call's.
        let name = toolName?.lowercased() == "tool_call" ? "tool_call" : canonicalToolName
        let phrase = ChatToolPhrase.phrase(forTool: name, arguments: arguments)
        ChatToolPhraseCache.store(phrase, for: key)
        return phrase
    }
}

/// Bounded memo of call → words. Arguments arrive once per call and don't
/// change after, so the call's identity and argument size are the key.
enum ChatToolPhraseCache {
    struct Key: Hashable, Sendable {
        let id: String
        let toolName: String?
        let argumentsSize: Int
    }

    private static let limit = 4_096
    private static let storage = OSAllocatedUnfairLock(initialState: [Key: ChatToolPhrase]())

    static func phrase(for key: Key) -> ChatToolPhrase? {
        storage.withLock { $0[key] }
    }

    static func store(_ phrase: ChatToolPhrase, for key: Key) {
        storage.withLock { cache in
            if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
            cache[key] = phrase
        }
    }
}

/// Words for MCP and plugin tools named after the service they reach
/// (`mcp_google_calendar_list_events`, `mcp_github_search_issues`).
enum ChatToolServicePhrase {
    private struct Service {
        let tokens: Set<String>
        /// "your calendars" for looking, "your calendar" for changing it.
        let checking: String
        let changing: String
        /// What sending through it is called, when it sends things.
        var sending: (live: String, past: String)?
    }

    private static let services: [Service] = [
        Service(tokens: ["calendar", "calendars", "gcal"], checking: "your calendars", changing: "your calendar"),
        Service(tokens: ["reminder", "reminders"], checking: "your reminders", changing: "your reminders"),
        Service(tokens: ["github"], checking: "GitHub", changing: "GitHub"),
        Service(tokens: ["gitlab"], checking: "GitLab", changing: "GitLab"),
        Service(tokens: ["gmail", "email", "mail", "inbox", "outlook"], checking: "your email",
                changing: "your email", sending: ("Sending an email…", "Sent an email")),
        Service(tokens: ["slack"], checking: "Slack", changing: "Slack",
                sending: ("Posting to Slack…", "Posted to Slack")),
        Service(tokens: ["discord"], checking: "Discord", changing: "Discord",
                sending: ("Posting to Discord…", "Posted to Discord")),
        Service(tokens: ["notion"], checking: "Notion", changing: "Notion"),
        Service(tokens: ["linear"], checking: "Linear", changing: "Linear"),
        Service(tokens: ["jira"], checking: "Jira", changing: "Jira"),
        Service(tokens: ["drive", "gdrive"], checking: "your Drive", changing: "your Drive"),
        Service(tokens: ["dropbox"], checking: "Dropbox", changing: "Dropbox"),
        Service(tokens: ["contacts"], checking: "your contacts", changing: "your contacts"),
        Service(tokens: ["todoist"], checking: "Todoist", changing: "Todoist"),
        Service(tokens: ["spotify"], checking: "Spotify", changing: "Spotify"),
        Service(tokens: ["weather", "forecast"], checking: "the weather", changing: "the weather"),
    ]

    private static let changingVerbs: Set<String> = [
        "create", "add", "insert", "update", "edit", "patch", "delete", "remove", "move", "write", "set",
        "upload", "schedule", "cancel", "archive", "label", "mark", "comment", "merge", "close", "assign", "modify",
    ]
    private static let sendingVerbs: Set<String> = ["send", "post", "reply", "forward", "draft"]

    static func phrase(forTool name: String) -> ChatToolPhrase? {
        let tokens = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard let service = services.first(where: { !$0.tokens.isDisjoint(with: tokens) }) else { return nil }
        if let sending = service.sending, tokens.contains(where: sendingVerbs.contains) {
            return ChatToolPhrase(live: sending.live, past: sending.past)
        }
        if tokens.contains(where: changingVerbs.contains) {
            return ChatToolPhrase(live: "Updating \(service.changing)…", past: "Updated \(service.changing)")
        }
        return ChatToolPhrase(live: "Checking \(service.checking)…", past: "Checked \(service.checking)")
    }
}

/// Plain words for a terminal command: what it does ("Running tests…"), from
/// its program and subcommand, never the rest of what was typed.
enum ChatCommandPhrase {
    /// Steps that only set up the real command (`cd app && npm test`).
    private static let setup: Set<String> = [
        "cd", "pushd", "popd", "export", "source", ".", "set", "unset", "echo", "printf", "true", "false",
        "sleep", "clear", "alias", "trap", "[", "test", "wait", "exit", "local", "shopt",
    ]
    /// Prefixes that run the word after them (and their own flags).
    private static let runners: Set<String> = [
        "sudo", "env", "time", "nohup", "exec", "command", "npx", "bunx", "pnpx", "uvx", "caffeinate", "nice",
        "timeout",
    ]

    static func phrase(for command: String) -> ChatToolPhrase {
        for line in command.split(whereSeparator: \.isNewline).prefix(8) {
            for segment in segments(of: String(line)) {
                if let phrase = phrase(forSegment: segment) { return phrase }
            }
        }
        return generic
    }

    private static let generic = ChatToolPhrase(live: "Running a command…", past: "Ran a command", key: "command",
                                                many: "Ran %d commands")

    /// The program the words describe (`npm` in `cd app && npm test`), if it's a plain name.
    static func program(for command: String) -> String? {
        for line in command.split(whereSeparator: \.isNewline).prefix(8) {
            for segment in segments(of: String(line)) {
                guard let program = mainProgram(of: segment) else { continue }
                return ChatToolNames.plainName(program)
            }
        }
        return nil
    }

    static func isSetup(_ program: String) -> Bool { setup.contains(program.lowercased()) }

    /// The line's commands, split on `&&`, `||`, `;` and `|`, as words.
    private static func segments(of line: String) -> [[String]] {
        var segments: [[String]] = [[]]
        var word = ""
        func endWord() {
            if !word.isEmpty { segments[segments.count - 1].append(word) }
            word = ""
        }
        for character in line {
            if character == ";" || character == "|" || character == "&" {
                endWord()
                if segments.last?.isEmpty == false { segments.append([]) }
            } else if character.isWhitespace {
                endWord()
            } else {
                word.append(character)
            }
        }
        endWord()
        return segments.filter { !$0.isEmpty }
    }

    /// Nil for a segment that only sets up (`cd app`).
    private static func phrase(forSegment raw: [String]) -> ChatToolPhrase? {
        guard let tokens = programAndArguments(of: raw) else { return nil }
        return phrase(program: basename(tokens[0]).lowercased(), arguments: Array(tokens.dropFirst()))
    }

    private static func mainProgram(of raw: [String]) -> String? {
        programAndArguments(of: raw).map { basename($0[0]).lowercased() }
    }

    /// The segment from its program on, or nil when it only sets up.
    private static func programAndArguments(of raw: [String]) -> [String]? {
        var tokens = raw.map(unquoted)
        // Leading assignments and runners with their flags (`FOO=1 sudo -E make`, `timeout 60 npm test`).
        while let first = tokens.first {
            if isAssignment(first) {
                tokens.removeFirst()
            } else if runners.contains(basename(first)) {
                tokens.removeFirst()
                while let next = tokens.first, next.hasPrefix("-") || next.allSatisfy(\.isNumber) {
                    tokens.removeFirst()
                }
            } else {
                break
            }
        }
        guard let first = tokens.first else { return nil }
        let program = basename(first).lowercased()
        guard !setup.contains(program), !program.hasPrefix("#") else { return nil }
        return tokens
    }

    private static let tests = ChatToolPhrase(live: "Running tests…", past: "Ran tests")
    private static let build = ChatToolPhrase(live: "Building the project…", past: "Built the project")
    private static let install = ChatToolPhrase(live: "Installing packages…", past: "Installed packages")

    /// "Running ffmpeg…": a program with nothing more specific to say.
    private static func named(_ program: String) -> ChatToolPhrase {
        guard let name = ChatToolNames.plainName(program) else { return generic }
        return ChatToolPhrase(live: "Running \(name)…", past: "Ran \(name)", key: "command", many: "Ran %d commands")
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func phrase(program: String, arguments: [String]) -> ChatToolPhrase {
        let words = positional(arguments)
        switch program {
        case "git":
            return git(words)
        case "gh":
            switch (words.first, words.dropFirst().first) {
            case ("pr", "create"): return ChatToolPhrase(live: "Opening a pull request…", past: "Opened a pull request")
            case ("pr", "merge"): return ChatToolPhrase(live: "Merging a pull request…", past: "Merged a pull request")
            case ("issue", "create"): return ChatToolPhrase(live: "Filing an issue…", past: "Filed an issue")
            case ("repo", "clone"): return clone(words.dropFirst(2).first)
            default: return ChatToolPhrase(live: "Checking GitHub…", past: "Checked GitHub")
            }
        case "npm", "pnpm", "yarn", "bun":
            switch words.first {
            case nil: return program == "yarn" ? install : named(program)
            case "install", "i", "add", "ci": return install
            case "test", "t": return tests
            case "build": return build
            case "run", "run-script":
                guard let script = words.dropFirst().first?.lowercased() else { return named(program) }
                if script.hasPrefix("test") { return tests }
                if script.hasPrefix("build") { return build }
                guard let name = ChatToolNames.plainName(script) else { return named(program) }
                return ChatToolPhrase(live: "Running the \(name) script…", past: "Ran the \(name) script",
                                      key: "command", many: "Ran %d commands")
            default: return named(program)
            }
        case "pip", "pip3", "poetry", "brew", "apt", "apt-get", "gem", "composer", "pod":
            let installs: Set<String> = ["install", "add", "upgrade", "update", "require"]
            return words.first.map(installs.contains) == true ? install : named(program)
        case "uv":
            if words.first == "run", let rest = arguments.firstIndex(of: "run") {
                return phrase(forSegment: Array(arguments[(rest + 1)...])) ?? named(program)
            }
            return ["pip", "add", "sync"].contains(words.first ?? "") ? install : named(program)
        case "pytest", "jest", "vitest", "mocha", "rspec", "phpunit", "ava":
            return tests
        case "swift", "cargo", "go", "dotnet", "mix":
            switch words.first {
            case "test": return tests
            case "build": return build
            case "add", "get", "install": return install
            default: return named(program)
            }
        case "xcodebuild":
            return words.contains("test") || words.contains("test-without-building") ? tests : build
        case "make", "gmake", "ninja", "cmake", "gradle", "gradlew", "mvn", "tsc", "webpack", "bazel":
            return words.contains("test") || words.contains("check") ? tests : build
        case "python", "python3", "node", "ruby", "perl", "php", "bash", "sh", "zsh", "deno":
            return script(program: program, arguments: arguments, words: words)
        case "ls", "tree", "find", "fd", "du", "stat", "pwd", "file", "exa", "eza":
            return ChatToolPhrase(live: "Looking through files…", past: "Looked through files")
        case "cat", "head", "tail", "less", "more", "bat", "wc", "nl":
            let name = words.last.flatMap(ChatToolNames.fileName)
            return ChatToolPhrase(live: name.map { "Reading \($0)…" } ?? "Reading a file…",
                                  past: name.map { "Read \($0)" } ?? "Read a file", key: "read", many: "Read %d files")
        case "grep", "rg", "ag", "ack", "egrep", "fgrep":
            return ChatToolPhrase(live: "Searching files…", past: "Searched files", key: "search-files",
                                  many: "Searched files %d times")
        case "curl", "wget", "http", "https", "xh":
            let host = arguments.lazy.compactMap(ChatToolNames.host).first
            return ChatToolPhrase(live: host.map { "Fetching \($0)…" } ?? "Fetching a web address…",
                                  past: host.map { "Fetched \($0)" } ?? "Fetched a web address", key: "fetch",
                                  many: "Fetched %d web addresses")
        case "mkdir":
            return ChatToolPhrase(live: "Making a folder…", past: "Made a folder", many: "Made %d folders")
        case "rm", "rmdir", "trash", "unlink":
            return ChatToolPhrase(live: "Deleting files…", past: "Deleted files")
        case "cp", "rsync", "scp", "ditto":
            return ChatToolPhrase(live: "Copying files…", past: "Copied files")
        case "mv":
            return ChatToolPhrase(live: "Moving files…", past: "Moved files")
        case "touch":
            return ChatToolPhrase(live: "Creating a file…", past: "Created a file", many: "Created %d files")
        case "chmod", "chown":
            return ChatToolPhrase(live: "Changing file permissions…", past: "Changed file permissions")
        case "docker", "podman", "docker-compose":
            return ChatToolPhrase(live: "Using Docker…", past: "Used Docker")
        case "kubectl", "helm":
            return ChatToolPhrase(live: "Checking Kubernetes…", past: "Checked Kubernetes")
        case "ssh", "mosh":
            return ChatToolPhrase(live: "Connecting to a server…", past: "Connected to a server")
        case "ps", "top", "lsof", "pgrep", "htop":
            return ChatToolPhrase(live: "Checking running programs…", past: "Checked running programs")
        case "kill", "pkill", "killall":
            return ChatToolPhrase(live: "Stopping a program…", past: "Stopped a program")
        case "hermes":
            return ChatToolPhrase(live: "Using Hermes…", past: "Used Hermes")
        default:
            return named(program)
        }
    }

    /// `python3 tools/report.py` runs report.py; `python3 -m pytest` runs tests.
    private static func script(program: String, arguments: [String], words: [String]) -> ChatToolPhrase {
        if arguments.first == "-m", let module = arguments.dropFirst().first {
            switch module {
            case "pytest", "unittest": return tests
            case "pip": return install
            default: return named(module)
            }
        }
        if let file = words.first, file.contains("."), let name = ChatToolNames.fileName(file) {
            return ChatToolPhrase(live: "Running \(name)…", past: "Ran \(name)", key: "command",
                                  many: "Ran %d commands")
        }
        let language = ["python": "Python", "python3": "Python", "node": "JavaScript", "deno": "JavaScript",
                        "ruby": "Ruby", "perl": "Perl", "php": "PHP"][program] ?? "a shell script"
        return ChatToolPhrase(live: "Running \(language)…", past: "Ran \(language)", key: "command",
                              many: "Ran %d commands")
    }

    private static func git(_ words: [String]) -> ChatToolPhrase {
        switch words.first {
        case "clone": return clone(words.dropFirst().first)
        case "status", "diff", "log", "show", "branch", "blame", "rev-parse", "ls-files", "remote", "describe",
             "shortlog", "reflog", "tag":
            return ChatToolPhrase(live: "Checking the repo…", past: "Checked the repo")
        case "commit": return ChatToolPhrase(live: "Committing changes…", past: "Committed changes")
        case "push": return ChatToolPhrase(live: "Pushing changes…", past: "Pushed changes")
        case "pull", "fetch": return ChatToolPhrase(live: "Pulling changes…", past: "Pulled changes")
        case "checkout", "switch": return ChatToolPhrase(live: "Switching branches…", past: "Switched branches")
        case "add", "rm", "mv", "restore", "reset": return ChatToolPhrase(live: "Staging changes…", past: "Staged changes")
        case "merge", "rebase", "cherry-pick": return ChatToolPhrase(live: "Merging changes…", past: "Merged changes")
        case "stash": return ChatToolPhrase(live: "Setting changes aside…", past: "Set changes aside")
        case "init": return ChatToolPhrase(live: "Starting a repo…", past: "Started a repo")
        default: return ChatToolPhrase(live: "Using git…", past: "Used git")
        }
    }

    private static func clone(_ source: String?) -> ChatToolPhrase {
        let name = source.flatMap(ChatToolNames.repositoryName)
        return ChatToolPhrase(live: name.map { "Cloning \($0)…" } ?? "Cloning a repo…",
                              past: name.map { "Cloned \($0)" } ?? "Cloned a repo", key: "clone",
                              many: "Cloned %d repos")
    }

    /// Words that aren't options. Options known to take a value (`git -C
    /// dir`, `python -c code`) are skipped with it.
    private static func positional(_ arguments: [String]) -> [String] {
        let takesValue: Set<String> = ["-C", "-c", "-e", "--git-dir", "--work-tree", "-f", "--file", "--prefix",
                                       "--cwd", "-w", "--workspace", "-o", "--output", "-m", "--message"]
        var result: [String] = []
        var skipsNext = false
        for argument in arguments {
            if skipsNext { skipsNext = false; continue }
            if argument.hasPrefix("-") {
                skipsNext = takesValue.contains(argument)
                continue
            }
            result.append(argument)
        }
        return result
    }

    private static func isAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return false }
        let name = token[..<equals]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func unquoted(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: "'\"`()"))
    }

    private static func basename(_ token: String) -> String {
        token.split(separator: "/").last.map(String.init) ?? token
    }
}

/// Reads tool arguments once, bounded: a huge `write_file` body isn't parsed
/// just to learn its path.
struct ChatToolArguments {
    private let object: [String: Any]

    init(_ raw: String?) {
        guard let raw, !raw.isEmpty else { object = [:]; return }
        if raw.utf8.count <= 16_384, let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            self.object = object
        } else {
            object = Self.leadingStrings(of: raw)
        }
    }

    func string(_ key: String) -> String? {
        guard let value = object[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func strings(_ key: String) -> [String] {
        (object[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// A nested object as JSON text (a `tool_call` wrapper's arguments).
    func json(_ key: String) -> String? {
        switch object[key] {
        case let text as String: return text
        case let value? where JSONSerialization.isValidJSONObject(value):
            return (try? JSONSerialization.data(withJSONObject: value)).map { String(decoding: $0, as: UTF8.self) }
        default: return nil
        }
    }

    /// Short `"key": "value"` pairs from the start of a large JSON object,
    /// where models put the path or command before the long content.
    private static func leadingStrings(of raw: String) -> [String: Any] {
        let prefix = String(raw.utf8.prefix(2_048)) ?? ""
        var result: [String: Any] = [:]
        let pattern = #""([A-Za-z_]{1,32})"\s*:\s*"([^"\\]{1,512})""#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return result }
        let range = NSRange(prefix.startIndex..., in: prefix)
        for match in expression.matches(in: prefix, range: range) {
            guard let key = Range(match.range(at: 1), in: prefix), let value = Range(match.range(at: 2), in: prefix)
            else { continue }
            result[String(prefix[key])] = String(prefix[value])
        }
        return result
    }
}

/// The only things a phrase may name, each checked to be a plain name.
enum ChatToolNames {
    private static let maximumLength = 64

    /// A file's base name ("notes.md"), or nil if it isn't a plain file name.
    static func fileName(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("://") else { return nil }
        guard let last = trimmed.split(separator: "/").last.map(String.init) else { return nil }
        return plainName(last, allowsSpaces: true)
    }

    /// A web address's host without "www." ("example.com").
    static func host(_ address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: CharacterSet(charactersIn: " '\"<>()"))
        guard trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://"),
              let host = URLComponents(string: trimmed)?.host?.lowercased(), host.count <= 80 else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard bare.contains("."), bare.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { return nil }
        return bare
    }

    /// A repo's name from a clone address or path ("weather-app").
    static func repositoryName(_ source: String) -> String? {
        var path = source.trimmingCharacters(in: CharacterSet(charactersIn: " '\"/"))
        if let components = URLComponents(string: path), components.scheme != nil {
            path = components.path  // Never the user or token before the host.
        } else if let colon = path.lastIndex(of: ":") {
            path = String(path[path.index(after: colon)...])  // git@host:owner/repo.git
        }
        guard var name = path.split(separator: "/").last.map(String.init) else { return nil }
        if name.hasSuffix(".git") { name.removeLast(4) }
        return plainName(name)
    }

    /// A name made of letters, digits and simple punctuation, never a path,
    /// an assignment, a flag or anything a shell would expand.
    static func plainName(_ value: String, allowsSpaces: Bool = false) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength, !trimmed.hasPrefix("-"), trimmed != ".",
              trimmed != "..", !trimmed.contains("=") else { return nil }
        let allowed = allowsSpaces ? "_-.@+()&,' " : "_-.@+:"
        guard trimmed.unicodeScalars.allSatisfy({ scalar in
            CharacterSet.alphanumerics.contains(scalar) || allowed.unicodeScalars.contains(scalar)
        }) else { return nil }
        return trimmed
    }
}
