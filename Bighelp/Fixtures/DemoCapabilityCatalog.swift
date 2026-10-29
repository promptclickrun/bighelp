#if DEBUG
import Foundation

/// Demo runs: Plugins and the Skills Hub on made-up catalogs, answered the way Hermes' dashboard
/// routes answer, so the storefronts run their real clients without a host. Installs, toggles and
/// removals are remembered for the run. Banners are drawn by the link-preview fixture
/// (`/bighelp-demo-banner/`); some plugins have none, so both looks show.
@MainActor
final class DemoCapabilityCatalogHost: DirectHermesAuthenticatedHTTP {
    /// One per run, so installs and toggles last until the app quits.
    static let shared = DemoCapabilityCatalogHost()

    private struct Plugin {
        let name: String
        var title: String?
        let category: String?
        let tier: String
        let summary: String
        var banner: Bool = false
        var screenshots = 0
        var tools: [String] = []
        var hooks: [String] = []
        var keys: [String] = []
        var version: String?
        var installed = false
        var knownIssues: String?
    }

    private struct Skill {
        let name: String
        let category: String?
        let source: String
        let summary: String
        var trust = "community"
        var policy = "allow"
        var installed = false
    }

    private var plugins: [Plugin] = [
        Plugin(name: "recall", title: "Recall", category: "memory", tier: "official",
               summary: "Long-term memory your agent can search and add to. It keeps what matters from each chat.",
               banner: true, screenshots: 2, tools: ["recall_search", "recall_save", "recall_forget", "recall_list"],
               hooks: ["on_session_end"], keys: ["RECALL_API_KEY"], version: "0.4.2"),
        Plugin(name: "memory-wiki", title: "Memory Wiki", category: "memory", tier: "official",
               summary: "A wiki your agents keep together.", tools: ["wiki_read", "wiki_write"], version: "1.2.0"),
        Plugin(name: "voice-studio", title: "Voice Studio", category: "voice", tier: "official",
               summary: "More voices for spoken replies, made on your computer.", banner: true,
               tools: ["speak"], version: "2.0.1"),
        Plugin(name: "page-reader", title: "Page Reader", category: "web", tier: "official",
               summary: "Reads long web pages and keeps only the article.", tools: ["read_page"]),
        Plugin(name: "scene-builder", title: "Scene Builder", category: "tools", tier: "verified",
               summary: "Builds and renders 3D scenes.", banner: true, tools: ["scene_new", "scene_render"],
               version: "0.9.0", installed: true),
        Plugin(name: "calendar-sync", title: "Calendar Sync", category: "automation", tier: "verified",
               summary: "Keeps a calendar file in step with your agent's plans.", tools: ["calendar_sync"],
               keys: ["CALDAV_URL", "CALDAV_PASSWORD"]),
        Plugin(name: "chat-relay", title: "Chat Relay", category: "platform", tier: "verified",
               summary: "Answers in a team chat app as your agent.", hooks: ["on_message"], keys: ["RELAY_TOKEN"]),
        Plugin(name: "notes-to-tasks", category: "automation", tier: "community",
               summary: "Turns meeting notes into a task list.", banner: true, tools: ["notes_to_tasks"],
               version: "0.3.0", knownIssues: "Long notes can take a minute."),
        Plugin(name: "price-watch", category: "web", tier: "community",
               summary: "Watches a product page and tells you when the price drops.", tools: ["watch_price"]),
        Plugin(name: "local-models", title: "Local Models", category: "models", tier: "community",
               summary: "Runs small open models on this computer.", banner: true, version: "1.0.0"),
        Plugin(name: "model-router", category: "models", tier: "community",
               summary: "Sends each step to the cheapest model that can do it.", hooks: ["before_model_call"]),
        Plugin(name: "photo-sorter", category: "tools", tier: "community",
               summary: "Sorts a folder of photos by date and place.", tools: ["sort_photos"]),
        Plugin(name: "unit-convert", category: "tools", tier: "community",
               summary: "Converts units, currencies and time zones.", tools: ["convert"]),
        Plugin(name: "habit-memory", category: "memory", tier: "community",
               summary: "Remembers the habits you track with your agent.", tools: ["habit_log"]),
        Plugin(name: "desktop-themes", title: "Desktop Themes", category: "desktop", tier: "community",
               summary: "More looks for the Hermes Desktop app.", banner: true),
        Plugin(name: "desktop-clock", category: "desktop", tier: "verified",
               summary: "A clock and timer panel for Hermes Desktop."),
        Plugin(name: "misc-utils", category: nil, tier: "community",
               summary: "Small helpers that don't fit elsewhere.", tools: ["slugify", "word_count"]),
    ]

    private var skills: [Skill] = [
        Skill(name: "computer-use", category: "productivity", source: "official",
              summary: "Use apps on a computer by looking at the screen.", trust: "builtin"),
        Skill(name: "password-vault", category: "security", source: "official",
              summary: "Reads logins from your password manager when you ask.", trust: "builtin"),
        Skill(name: "pdf", category: "documents", source: "official",
              summary: "Reads, fills and merges PDF files.", trust: "builtin"),
        Skill(name: "three-statement-model", category: "finance", source: "official",
              summary: "Builds a linked income, balance and cash flow model.", trust: "builtin"),
        Skill(name: "meeting-notes", category: "productivity", source: "official",
              summary: "Turns a recording into notes and next steps.", trust: "builtin", installed: true),
        Skill(name: "paper-summary", category: "research", source: "official",
              summary: "Summarizes a research paper section by section.", trust: "builtin"),
        Skill(name: "web-research", category: "research", source: "official",
              summary: "Searches several sources and cites each claim.", trust: "builtin"),
        Skill(name: "storyboard", category: "creative", source: "official",
              summary: "Plans a short video shot by shot.", trust: "builtin"),
        Skill(name: "log-triage", category: "devops", source: "official",
              summary: "Finds the first error in a long log.", trust: "builtin"),
        Skill(name: "csv-explorer", category: "data-science", source: "official",
              summary: "Answers questions about a spreadsheet.", trust: "builtin"),
        Skill(name: "chart-maker", category: "data-science", source: "official",
              summary: "Draws a chart from a table.", trust: "builtin"),
        Skill(name: "docx-writer", category: "documents", source: "official",
              summary: "Writes Word documents with headings and tables.", trust: "builtin"),
        Skill(name: "budget-planner", category: "finance", source: "official",
              summary: "Plans a monthly budget from your spending.", trust: "builtin"),
        Skill(name: "inbox-zero", category: nil, source: "skills-sh",
              summary: "Sorts an inbox into reply, read and archive."),
        Skill(name: "recipe-scaler", category: nil, source: "skills-sh",
              summary: "Scales a recipe and converts its units."),
        Skill(name: "trip-planner", category: nil, source: "clawhub",
              summary: "Plans a trip day by day.", policy: "ask"),
        Skill(name: "shell-anything", category: nil, source: "clawhub",
              summary: "Runs any shell command it's given.", policy: "block"),
        Skill(name: "readme-writer", category: nil, source: "github",
              summary: "Writes a README from a project's code."),
    ]

    private var mySkills: [(name: String, category: String?, summary: String, enabled: Bool, provenance: String)] = [
        ("meeting-notes", "productivity", "Turns a recording into notes and next steps.", true, "hub"),
        ("notes", "productivity", "Keeps your notes in one place.", true, "bundled"),
        ("weather", nil, "Tells the weather where you are.", true, "bundled"),
        ("email-drafts", "communication", "Drafts replies in your voice.", true, "agent"),
        ("plan-week", "productivity", "Plans the week from your goals.", false, "agent"),
    ]

    private var bundledPlugins: [(name: String, source: String, enabled: Bool)] = [
        ("disk-tools", "bundled", true), ("loopdy", "user", true),
    ]

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        let path = request.path
        let query = Dictionary(request.query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        switch path {
        case "/api/dashboard/plugins/hub":
            return .object(["plugins": .array(hubRows())])
        case "/api/dashboard/plugins/catalog":
            return .object([
                // One row a host could send that the app can't install (no pinned commit): it's skipped.
                "entries": .array(plugins.map(catalogRow) + [.object(["name": .string("unpinned"), "sha": .string("main")])]),
                "removed": .array([]),
            ])
        case "/api/dashboard/plugins/rescan":
            return .object(["ok": .boolean(true), "count": .integer(hubRows().count)])
        case "/api/dashboard/agent-plugins/install":
            guard let name = request.body?["catalog_name"]?.string,
                  let index = plugins.firstIndex(where: { $0.name == name }) else { throw WorkspaceClientError.invalidRequest }
            plugins[index].installed = true
            return .object(["ok": .boolean(true)])
        case "/api/skills/hub/sources":
            return .object([
                "sources": .array([
                    source("official", "Official"), source("skills-sh", "skills.sh"), source("clawhub", "ClawHub"),
                    source("github", "GitHub repositories"), source("lobehub", "LobeHub", rateLimited: true),
                ]),
                "index_available": .boolean(true),
                "featured": .array([]),
                "installed": .object(Dictionary(uniqueKeysWithValues: skills.filter(\.installed).map {
                    (identifier($0), BighelpJSONValue.object([:]))
                })),
            ])
        case "/api/skills/hub/official":
            return .object(["skills": .array(skills.filter { $0.source == "official" }.map(skillRow))])
        case "/api/skills":
            return .array(mySkills.filter(\.enabled).map { skill in
                .object(["name": .string(skill.name), "description": .string(skill.summary),
                         "category": skill.category.map(BighelpJSONValue.string) ?? .null,
                         "enabled": .boolean(true), "usage": .integer(3), "provenance": .string(skill.provenance)])
            })
        case "/api/skills/toggle":
            guard let name = request.body?["name"]?.string, let enabled = request.body?["enabled"]?.boolean,
                  let index = mySkills.firstIndex(where: { $0.name == name }) else { throw WorkspaceClientError.invalidRequest }
            mySkills[index].enabled = enabled
            return .object(["ok": .boolean(true), "name": .string(name), "enabled": .boolean(enabled)])
        case "/api/skills/hub/search":
            let words = (query["q"] ?? "").lowercased()
            let source = query["source"] ?? "all"
            let found = skills.filter {
                (source == "all" || $0.source == source)
                    && ($0.name.contains(words) || $0.summary.lowercased().contains(words))
            }
            return .object([
                "results": .array(found.map(skillRow)),
                "source_counts": .object(Dictionary(grouping: found, by: \.source).mapValues { .integer($0.count) }),
                "timed_out": .array(source == "all" ? [.string("lobehub")] : []),
                "installed": .object([:]),
            ])
        case "/api/skills/hub/preview":
            guard let skill = skill(query["identifier"]) else { throw WorkspaceClientError.invalidRequest }
            guard case .object(var row) = skillRow(skill) else { throw WorkspaceClientError.invalidRequest }
            row["skill_md"] = .string("---\nname: \(skill.name)\ndescription: \(skill.summary)\n---\n\n# \(skill.name)\n\n\(skill.summary)\n\n## Steps\n\n1. Read what the person asked for.\n2. Do it, then say what changed.\n")
            row["files"] = .array([.string("SKILL.md")] + (skill.policy == "allow" ? [] : [.string("scripts/run.sh")]))
            return .object(row)
        case "/api/skills/hub/scan":
            guard let skill = skill(query["identifier"]) else { throw WorkspaceClientError.invalidRequest }
            let findings: [BighelpJSONValue] = skill.policy == "allow" ? [] : [.object([
                "severity": .string(skill.policy == "block" ? "critical" : "medium"),
                "category": .string(skill.policy == "block" ? "command-execution" : "network"),
                "file": .string("scripts/run.sh"), "line": .integer(12),
                "description": .string(skill.policy == "block" ? "Runs commands it receives without checking them."
                                                                : "Downloads a file from the web."),
            ])]
            return .object([
                "identifier": .string(identifier(skill)), "name": .string(skill.name), "source": .string(skill.source),
                "trust_level": .string(skill.trust),
                "verdict": .string(["allow": "safe", "ask": "caution", "block": "dangerous"][skill.policy] ?? "safe"),
                "summary": .string(skill.policy == "allow" ? "No problems found." : "\(findings.count) finding."),
                "policy": .string(skill.policy),
                "policy_reason": .string(skill.policy == "block" ? "Critical findings block installation." : ""),
                "findings": .array(findings),
                "severity_counts": .object([:]),
            ])
        case "/api/skills/hub/install":
            guard let index = skills.firstIndex(where: { identifier($0) == request.body?["identifier"]?.string }),
                  skills[index].policy != "block" else { throw WorkspaceClientError.invalidRequest }
            skills[index].installed = true
            mySkills.append((skills[index].name, skills[index].category, skills[index].summary, true, "hub"))
            return .object(["ok": .boolean(true), "action": .string("skills-install")])
        case "/api/skills/hub/uninstall":
            guard let name = request.body?["name"]?.string,
                  let index = skills.firstIndex(where: { $0.name == name }) else { throw WorkspaceClientError.invalidRequest }
            skills[index].installed = false
            mySkills.removeAll { $0.name == name }
            return .object(["ok": .boolean(true), "action": .string("skills-uninstall")])
        case "/api/skills/hub/update":
            return .object(["ok": .boolean(true), "action": .string("skills-update")])
        default:
            if path.hasPrefix("/api/dashboard/agent-plugins/") {
                return try pluginAction(path)
            }
            throw WorkspaceClientError.invalidRequest
        }
    }

    // MARK: Plugins

    private func hubRows() -> [BighelpJSONValue] {
        let installed = plugins.filter(\.installed).map { ($0.name, "git", true) }
        return (bundledPlugins.map { ($0.name, $0.source, $0.enabled) } + installed).map { name, source, enabled in
            .object([
                "name": .string(name), "version": .string("1.0.0"), "description": .string(""),
                "source": .string(source), "runtime_status": .string(enabled ? "enabled" : "disabled"),
                "can_remove": .boolean(source == "git"), "can_update_git": .boolean(source == "git"),
                "auth_required": .boolean(false), "auth_command": .string(""), "removed_reason": .null,
            ])
        }
    }

    private func catalogRow(_ plugin: Plugin) -> BighelpJSONValue {
        var row: [String: BighelpJSONValue] = [
            "name": .string(plugin.name), "repo": .string("https://example.com/plugins/\(plugin.name)"),
            "sha": .string(Self.sha(plugin.name)), "description": .string(plugin.summary),
            "maintainer": .string("Example Plugins"), "tier": .string(plugin.tier),
            "docs_url": .string("https://example.com/plugins/\(plugin.name)#readme"), "requires_hermes": .string(">=0.22"),
            "platforms": .array([.string("macos"), .string("linux")]),
            "capabilities": .object([
                "provides_tools": .array(plugin.tools.map(BighelpJSONValue.string)),
                "provides_hooks": .array(plugin.hooks.map(BighelpJSONValue.string)),
                "provides_middleware": .array([]),
                "requires_env": .array(plugin.keys.map(BighelpJSONValue.string)),
            ]),
            "installed": .boolean(plugin.installed), "update_available": .boolean(false),
            "runtime_status": plugin.installed ? .string("enabled") : .null,
            "installed_sha": plugin.installed ? .string(Self.sha(plugin.name)) : .null,
        ]
        if let category = plugin.category { row["category"] = .string(category) }
        if let title = plugin.title { row["title"] = .string(title) }
        if let version = plugin.version { row["version"] = .string(version) }
        if let issues = plugin.knownIssues { row["known_issues"] = .string(issues) }
        if plugin.banner { row["image"] = .string(Self.banner(plugin.name)) }
        if plugin.screenshots > 0 {
            row["screenshots"] = .array((1...plugin.screenshots).map { .string(Self.banner("\(plugin.name)-shot-\($0)")) })
        }
        return .object(row)
    }

    private func pluginAction(_ path: String) throws -> BighelpJSONValue {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 4 else { throw WorkspaceClientError.invalidRequest }
        let name = parts[3]
        let action = parts.count > 4 ? parts[4] : "remove"
        if let index = bundledPlugins.firstIndex(where: { $0.name == name }), action != "remove" {
            bundledPlugins[index].enabled = action == "enable"
        } else if let index = plugins.firstIndex(where: { $0.name == name }), action == "remove" {
            plugins[index].installed = false
        }
        return .object(["ok": .boolean(true)])
    }

    private static func sha(_ name: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        let hex = String(hash, radix: 16)
        return String((String(repeating: "0", count: 16 - hex.count) + hex).cycled(to: 40))
    }

    static func banner(_ name: String) -> String { "https://example.com/bighelp-demo-banner/\(name).png" }

    // MARK: Skills

    private func identifier(_ skill: Skill) -> String {
        skill.source == "official" ? "official/\(skill.category ?? "general")/\(skill.name)" : "\(skill.source)/\(skill.name)"
    }

    private func skill(_ identifier: String?) -> Skill? {
        skills.first { self.identifier($0) == identifier }
    }

    private func skillRow(_ skill: Skill) -> BighelpJSONValue {
        .object([
            "name": .string(skill.name), "description": .string(skill.summary), "source": .string(skill.source),
            "identifier": .string(identifier(skill)), "trust_level": .string(skill.trust),
            "repo": .string("example/\(skill.source)-skills"), "tags": .array([]),
            "category": skill.category.map(BighelpJSONValue.string) ?? .null,
            "installed": .boolean(skill.installed),
        ])
    }

    private func source(_ id: String, _ label: String, rateLimited: Bool = false) -> BighelpJSONValue {
        .object(["id": .string(id), "label": .string(label), "available": .boolean(true),
                 "searchable": .boolean(true), "rate_limited": .boolean(rateLimited)])
    }
}

private extension String {
    func cycled(to length: Int) -> String {
        String((0..<length).map { Array(self)[$0 % count] })
    }
}
#endif
