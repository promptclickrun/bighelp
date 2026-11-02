# Many agent sessions at once

Several agent sessions can work on bighelp at the same time. There are no special roles. One session owns a change
from start to finish: it builds the change, tests it, opens the PR and merges it. Releasing is a separate step that
the maintainer starts.

This keeps three things from happening:
- Two sessions build the same feature in different branches, and their PRs fight over the same files.
- Every session builds, tests and archives at the same time, and the shared Mac runs out of memory.
- A change waits for hours in a queue for another session to look at it.

## One session owns a change

- The session that takes an issue or feature does all of it itself: it writes the change, builds and tests it on the
  Mac, opens the PR, fixes review findings and failed checks, and merges the PR once checks and review pass. It
  does not hand normal work to other sessions.
- Big work can be split. The owning session does the split and stays the owner of the result. It can start
  helper sessions for the parts and review what they send back. The helpers' work is part of the owner's change.
- Changes to chat, transport, sign-in, security or notifications get a second pair of eyes before the merge: the
  maintainer, or an independent review session.
- Merging and releasing are separate. A merge does not start a release.

## One feature, one owner

- Before starting, look at open PRs, open issues and what the other sessions are doing. If another session
  already owns the feature or the same files, don't start a second copy. Tell the maintainer.
- When two sessions turn out to overlap, the maintainer names one owner. The other hands over its branch, its
  findings and anything it was told by the maintainer, then stops work on it.
- Mockups, specs and decisions the maintainer gave one session belong to the feature's owner. Pass them on
  rather than asking the maintainer again or making new ones.

## Done means merged

A change is done when it is merged to `main`, not when the code compiles.

1. Rebase on current `main`. Run `xcodegen generate` if files moved, and commit the project.
2. Build and test what the change touches: the iPhone app and any extension it changes, with `-only-testing` for
   the affected suites.
3. Every change must still build for the Mac and Vision Pro (AGENTS.md › Mac, Vision Pro). Build those platforms
   yourself when the diff touches code for them: `#if os(visionOS)`, `targetEnvironment(macCatalyst)`,
   entitlements, or platform settings in `project.yml`. The release builds prove it for other changes.
4. Open the PR (one issue, squash-merge, closes the issue). Its description has:
   - what changes for the person using bighelp, in plain words
   - the issue it closes
   - what was tested, and where: demo fixtures, a real host or a device
   - any plugin change it needs (the plugin PR or the `/native/context` feature), so the release ships the plugin
     first
   - one proposed release note line in ASD-STE100 plain English, which the release copies into
     `docs/RELEASE_NOTES.md`
   - anything a reviewer must know: risky areas (chat contract, transport, sign-in, notifications), known gaps
5. Merge the PR once checks and review pass. Never merge on red checks. Don't bump versions, edit release notes or
   tag in a feature PR. The release does that.

## Releases

A release is a step the maintainer starts. The session the maintainer asks runs it from start to finish.

1. **Collect what is ready.** List the merged PRs since the last release and check that every finished PR meant
   for this release is merged. If one isn't ready, say so rather than waiting for it.
2. **Prepare the release PR.** Bump `MARKETING_VERSION` (a new one for every upload batch: never add a build to a
   version already uploaded) and every `CURRENT_PROJECT_VERSION` in `project.yml`, regenerate, and add the PRs'
   release note lines to `docs/RELEASE_NOTES.md`. The PR is titled
   `bighelp <version> (<build>): <what changed, in plain words>`. Merge it once checks and review pass.
3. **Verify on `main`.** Run the suites the release touched, on one simulator. Big new screens also get
   `ReleaseScreensWalkthroughUITests` (AGENTS.md › Crashes that only happen on a real iPhone). The PRs were already
   tested. This pass checks that they work together, so don't turn it into a full regression hunt.
4. **Ship every platform, one build at a time.** Release from a checkout pinned to the release commit
   (`git worktree add --detach`), never one that other work switches branches in. The plugin goes first when the
   app needs it. Then:
   - the iPhone and iPad archive, uploaded to internal TestFlight as soon as it is built. iOS tests gate iOS only:
     Mac and visionOS work never delays this upload.
   - the Mac DMG (`Scripts/release-mac.sh`)
   - the visionOS archive and upload

   A release is all three, every time. Uploads may overlap the next compile. Drive each one to a verified finish
   (processed, notes on, groups assigned) before you stop. Exact steps and credentials are in the maintainer's
   private release notes. Public TestFlight goes out only when the maintainer says so.
5. **Report to the maintainer:** the version and build, the PRs and issues in it, what was verified and where,
   and what was held back and why.

Rules for releases:
- Only the session running the release touches versions, release notes, tags, uploads and published builds. Other
  sessions keep merging features. Their PRs go in the next release.
- Don't hold a ready release for one slow PR. Ship what is ready; the slow one goes in the next release.
- If a merge breaks `main`, revert it first, then fix it in the PR that broke it.

## Sharing one Mac

All sessions usually build on the same machine. Treat its CPU, memory and simulators as shared.

- **One heavy build at a time.** Run `xcodebuild` builds, tests and archives through `Scripts/with-build-lock.sh`.
  It waits for whichever build has the lock and says who holds it. During a release archive or upload, other
  sessions should not start new builds.
- **Reuse build folders.** Give each worktree one `-derivedDataPath` and use it for every run in that worktree.
  A fresh folder for each run is a cold build. Delete it when the worktree goes.
- **One simulator per session, at most.** Reuse the one you booted, never run two `xcodebuild test` sessions on one
  simulator, and shut down every simulator you booted when you stop.
- **Build what you changed.** Iterate on one target and the affected tests. Leave multi-platform builds to the
  release, unless the diff touches code for those platforms.
- **Run long builds in the background** and keep working; don't poll in a loop.
- **No Apple workflows.** Sessions build and test on the Mac. They never dispatch, re-run, `ios-ci.yml`, `testflight.yml` or `prepare-signing.yml` (AGENTS.md › Build and test). A PR never lists a
  missing CI run as a blocker.
