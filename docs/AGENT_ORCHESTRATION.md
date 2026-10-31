# Many agent sessions at once: the factory and the release captain

When several agent sessions work on bighelp at the same time, one of them is the **release captain**. The others
are **factory sessions**. Factory sessions turn issues into pull requests. The captain merges those pull requests,
builds once and ships them as one release.

This keeps three things from happening again:
- Two sessions build the same feature in different branches, and their PRs fight over the same files.
- Every session builds, tests and archives at the same time, and the shared Mac runs out of memory.
- Several sessions merge and bump versions on their own, so `main` changes under every open branch and
  each release covers whatever happened to land.

With no captain named, the usual rules apply: the maintainer merges and starts releases (AGENTS.md › Git,
commits and releases).

## Roles

| Role | Owns | Never does |
|---|---|---|
| Maintainer | Names the captain. Decides what ships and when public TestFlight goes out. Product calls. | |
| Release captain (one session) | The release queue, every merge to `main`, version bumps, `docs/RELEASE_NOTES.md`, the release PR, builds, uploads, the Mac DMG, the plugin release | Starts feature work of its own while a release is in flight |
| Factory session | One issue or feature: its branch, worktree, tests and PR | Merges, bumps versions, edits release notes, uploads, publishes |

Subagents a session starts are part of that session's work. They hand their results to their parent, never to the
captain directly.

## Naming the captain

- The maintainer names it, in that session: "You're the release captain." The maintainer's go-ahead to merge and
  ship (internal TestFlight, a public build, the Mac DMG) is said there too, and the captain stays inside it.
- Pick the session closest to shipping, or start one for the job. Don't pick the session with the biggest open
  feature: a captain waiting on its own work holds everyone else's.
- The captain tells each factory session it exists, with its thread or session link, so they know where to hand
  PRs.
- There is one captain at a time. To hand over, the old captain writes down the queue, what is merged, what is
  building and anything uploaded but not yet released, gives that to the new captain, and stops merging.

## One feature, one owner

- Before starting, look at open PRs, open issues and what the other sessions are doing. If another session
  already owns the feature or the same files, don't start a second copy. Tell the captain.
- When two sessions turn out to overlap, the captain names one owner. The other hands over its branch, its
  findings and anything it was told by the maintainer, then stops work on it.
- Mockups, specs and decisions the maintainer gave one session belong to the feature's owner. Pass them on
  rather than asking the maintainer again or making new ones.

## Factory session: done means handed off

A factory session's work is done when its PR is with the captain, not when the code compiles.

1. Rebase on current `main`. Run `xcodegen generate` if files moved, and commit the project.
2. Build and test only what the change touches: the iPhone app and any extension it changes, with
   `-only-testing` for the affected suites.
3. Every change must still build for the Mac and Vision Pro (AGENTS.md › Mac, Vision Pro). The captain's release
   builds prove that for most changes. Build those platforms yourself only when the diff touches code for them:
   `#if os(visionOS)`, `targetEnvironment(macCatalyst)`, entitlements, or platform settings in `project.yml`.
4. Open the PR (one issue, squash-merge, closes the issue). Its description has:
   - what changes for the person using bighelp, in plain words
   - the issue it closes
   - what was tested, and where: demo fixtures, a real host or a device
   - any plugin change it needs (the plugin PR or the `/native/context` feature), so the captain releases the plugin
     first
   - one proposed release note line in ASD-STE100 plain English, which the captain copies into
     `docs/RELEASE_NOTES.md`
   - anything the captain must know: risky areas (chat contract, transport, sign-in, notifications), known gaps
5. Send the PR link to the captain. Then either stop or take the next issue.
6. When the captain asks (rebase, fix a review finding, a failed check), that comes first.

## Release captain: the release train

1. **Keep the queue.** Every handed-off PR, its owner, its state. Fixes go before features, small before large. A
   PR that needs an unreleased plugin feature waits for the plugin release.
2. **Review each PR before merging it.** The diff matches the issue, the evidence is real, and checks are green.
   Chat, transport, sign-in, security or notification changes get an independent review from another session
   first.
3. **Merge one at a time** (squash). After each merge, tell the owners of the PRs still waiting to rebase, or
   rebase a trivial one yourself. Never merge on red checks, and never merge your own feature work.
4. **Cut the release** when the train is ready. Before cutting, check that every finished PR meant for this
   release is merged; if one isn't ready, say so rather than starting the build without it. Bump
   `MARKETING_VERSION` (a new one for every upload batch: never add a build to a version already uploaded) and
   every `CURRENT_PROJECT_VERSION` in `project.yml`, regenerate, and add the PRs' release note lines to
   `docs/RELEASE_NOTES.md`. That is the release PR, titled
   `bighelp <version> (<build>): <what changed, in plain words>`.
5. **Verify on `main`.** Run the suites the train touched, on one simulator. Big new screens also get
   `ReleaseScreensWalkthroughUITests` (AGENTS.md › Crashes that only happen on a real iPhone). Factory sessions
   already tested their pieces. This pass checks that they work together, so don't turn it into a full
   regression hunt.
6. **Ship every platform, one build at a time.** Release from a checkout pinned to the release commit
   (`git worktree add --detach`), never one that other work switches branches in. The plugin goes first when the
   app needs it. Then:
   - the iPhone and iPad archive, uploaded to internal TestFlight as soon as it is built. iOS tests gate iOS only:
     Mac and visionOS work never delays this upload.
   - the Mac DMG (`Scripts/release-mac.sh`)
   - the visionOS archive and upload

   A release is all three, every time. Uploads may overlap the next compile. Drive each one to a verified finish
   (processed, notes on, groups assigned) before you stop. Exact steps and credentials are in the maintainer's
   private release notes. Public TestFlight goes out only when the maintainer says so.
7. **Report to the maintainer:** the version and build, the PRs and issues in it, what was verified and where,
   and what was held back and why.

Rules for the train:
- Don't hold a ready release for one slow PR. Ship what is ready; the slow one goes on the next train.
- If a merge breaks `main`, revert it first, then send the fix to its factory session.
- The captain is the only session that touches the release: versions, notes, uploads, tags, published builds.

## Sharing one Mac

All sessions usually build on the same machine. Treat its CPU, memory and simulators as shared.

- **One heavy build at a time.** Run `xcodebuild` builds, tests and archives through `Scripts/with-build-lock.sh`.
  It waits for whichever build has the lock and says who holds it. During an archive or upload, the captain
  can ask factory sessions not to start new builds.
- **Reuse build folders.** Give each worktree one `-derivedDataPath` and use it for every run in that worktree.
  A fresh folder for each run is a cold build. Delete it when the worktree goes.
- **One simulator per session, at most.** Reuse the one you booted, never run two `xcodebuild test` sessions on one
  simulator, and shut down every simulator you booted when you stop.
- **Build what you changed.** Iterate on one target and the affected tests. Leave multi-platform builds to the
  captain's release, unless the diff touches code for those platforms.
- **Run long builds in the background** and keep working; don't poll in a loop.
