import Foundation
import Testing
@testable import Bighelp

/// Orchestration mode's batch chat: who a message goes to, and what each session reads.
@MainActor
struct CodeBatchRoutingTests {
    private let members = [
        CodeBatchMember(id: "s1", name: "Widget tap", index: 0, branch: "code/fix-widget-tap",
                        title: "Fix the widget tap when the host is asleep"),
        CodeBatchMember(id: "s2", name: "Loading state", index: 1, branch: "code/add-loading-state",
                        title: "Add a loading state to the Usage page"),
        CodeBatchMember(id: "s3", name: "Tests branch", index: 2, branch: "code/write-tests",
                        title: "Write tests for the branch name helper"),
    ]
    private let pulls = [
        StockGitPullRequest(number: 142, branch: "code/fix-widget-tap", title: "Fix the widget tap",
                            url: URL(string: "https://github.com/example/app/pull/142")!, state: "OPEN", isDraft: false),
        StockGitPullRequest(number: 138, branch: "code/widget-agent-name", title: "Widget shows the wrong agent",
                            url: URL(string: "https://github.com/example/app/pull/138")!, state: "OPEN", isDraft: false),
    ]
    private var everyone: [String] { members.map(\.id) }

    @Test func noMentionGoesToTheTargetChip() {
        let all = CodeBatchRouting.route("Keep each change small", members: members, pullRequests: pulls, fallback: everyone)
        let one = CodeBatchRouting.route("Keep each change small", members: members, pullRequests: pulls, fallback: ["s2"])

        #expect(all.sessionIDs == everyone)
        #expect(all.text == "Keep each change small")
        #expect(one.sessionIDs == ["s2"])
    }

    /// A session mention picks it, in any case, and isn't part of what it reads.
    @Test func aSessionMentionPicksThatSessionOnly() {
        let outgoing = CodeBatchRouting.route("#widget tap use the shared host check", members: members,
                                              pullRequests: pulls, fallback: everyone)

        #expect(outgoing.sessionIDs == ["s1"])
        #expect(outgoing.text == "use the shared host check")
    }

    @Test func twoMentionsGoToBothInBatchOrder() {
        let outgoing = CodeBatchRouting.route("#Loading state #Widget tap rebase on main", members: members,
                                              pullRequests: pulls, fallback: everyone)

        #expect(outgoing.sessionIDs == ["s1", "s2"])
        #expect(outgoing.text == "rebase on main")
    }

    /// A pull request goes to the session working on its branch, spelled out so the agent can find it.
    @Test func aPullRequestGoesToTheSessionOnItsBranch() {
        let outgoing = CodeBatchRouting.route("Fix the failing check on #142 and push again", members: members,
                                              pullRequests: pulls, fallback: everyone)

        #expect(outgoing.sessionIDs == ["s1"])
        #expect(outgoing.text == "Fix the failing check on pull request #142 (branch code/fix-widget-tap) and push again")
        #expect(outgoing.pullRequestOwners == [142: "s1"])
    }

    @Test func aPullRequestOutsideTheBatchKeepsTheTargetChip() {
        let outgoing = CodeBatchRouting.route("Look at #138 first", members: members, pullRequests: pulls,
                                              fallback: everyone)

        #expect(outgoing.sessionIDs == everyone)
        #expect(outgoing.text == "Look at pull request #138 (branch code/widget-agent-name) first")
    }

    /// `#` opens the list; "# " is a heading, and a picked mention (with its space) closes it.
    @Test func theMentionBeingTyped() {
        #expect(CodeBatchRouting.mentionQuery(in: "#") == "")
        #expect(CodeBatchRouting.mentionQuery(in: "Keep it small #wid") == "wid")
        #expect(CodeBatchRouting.mentionQuery(in: "# Heading") == nil)
        #expect(CodeBatchRouting.mentionQuery(in: "issue#4") == nil)
        #expect(CodeBatchRouting.mentionQuery(in: "#Widget tap ") == nil)
        #expect(CodeBatchRouting.mentionQuery(in: "#Widget tap use the shared check") == nil, "Typing on closes it.")
        #expect(CodeBatchRouting.mentionQuery(in: "no hash here") == nil)
    }

    @Test func sessionsGetShortNamesThatNeverRepeat() {
        #expect(CodeBatchMember.shortName("Fix the widget tap when the host is asleep") == "Widget tap")
        #expect(CodeBatchMember.shortName("Add a loading state to the Usage page") == "Loading state")
        #expect(CodeBatchMember.shortName("¿¡ !?") == "Session")

        let batch = CodeBatch(id: UUID(), projectID: "app", title: "Twice", createdAt: .now, jobCount: 2,
                              sessionIDs: ["a", "b"], messages: [])
        let sessions = ["a", "b"].map {
            CodeSessionRecord(id: $0, agentID: "default", projectID: "app", projectName: "app",
                              title: "Fix the widget tap", folder: "/repo", branch: nil, placement: .local,
                              startedAt: .now)
        }
        #expect(CodeBatchMember.members(of: batch, sessions: sessions).map(\.name) == ["Widget tap", "Widget tap 2"])
    }

    @Test func aBatchIsNamedByItsFirstJob() {
        let job = { (message: String) in
            CodeStagedJob(id: UUID(), message: message, agentID: "default", projectID: "app", placement: .newWorktree,
                          branch: nil, newBranch: nil, runtime: CodeRuntimeChoice(), mode: .standard)
        }
        #expect(CodeBatch.title(for: [job("Fix the widget tap")]) == "Fix the widget tap")
        #expect(CodeBatch.title(for: [job("Fix the widget tap"), job("Add a loading state"), job("Write tests")])
            == "Fix the widget tap")
    }
}
