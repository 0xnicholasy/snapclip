# SnapClip hardening pass

ultraplan: snapclip-hardening | branch: feat/snapclip-hardening | base: main | tag: pre-snapclip-hardening-main | created: 2026-10-08
Status: ACTIVE
Progress: 4/10 done

## Goal
Close five gaps in SnapClip where failures are silent or past fixes have no regression test:
- Automatic update checks can no longer stall when the clock is skewed.
- An unreadable tracked.json is logged and kept, not silently replaced.
- A screenshot renamed during the stability wait is never trashed.
- The screenshot event pipeline can be tested from SnapClipCore, and its past fixes have tests.
- A timed-out Homebrew upgrade gets SIGINT before SIGTERM, and its failure paths have tests.

## Constraints
Givens
- PR base is main. Never push to main. Land everything through one PR at the end (D1).
- SwiftPM targets: SnapClipCore, SnapClip (executable), SnapClipCoreTests. macOS 14+.
- No emoji in code. Make minimal, surgical edits that follow the module's naming. Use conventional commits grouped by fix area.
- Tests must check intent: every new test must fail when its guard is removed. To check, change the guard by hand, run the filtered test, confirm it fails, undo the change, and confirm `git diff` shows only the intended edit.
- A feature triggered by a system action is verified with the real trigger (Cmd+Shift+3/4 via System Events) and the user's real `defaults`. Never use `screencapture -x` (tasks/lessons.md).
- These must exit 0: `swift build` and `swift test`. Any todo that touches Sources/SnapClip/ must also pass `scripts/build-app.sh`. There is no CI (D3).
- /secreview is required on WS5 changes to process spawning and signals.
- Re-verify first: each todo's first scope line re-reads its cited lines at the branch tip. If the premise no longer holds, mark the todo skipped and log it to tasks/research/STATE.md (D4).
- Line ranges below are at HEAD c7705e0. Once earlier todos land, find the code by symbol name instead.
- Known dependencies: the WS3 pipeline change needs the WS4 extraction. WS2 and WS3 both edit TrackerStore.swift, so `needs` serializes them.
Hard prohibitions
- Never read .env.
- Never deploy. Never add a dependency without flagging it in the PR body.
- The landing PR into main is a hard stop: a human merges it.
- No author may clear their own change. Every todo gets an independent `codex` review (D2).
- WS5: do not switch to posix_spawn or process groups. Never run a real `brew update` or `brew upgrade` from tests.
Required mitigations per workstream
- WS1: the test pins both bounds. Lower bound = SnapClipConstants.updateInitialDelay; upper bound = SnapClipConstants.updateCheckInterval.
- WS2: no log on ENOENT. Rename to the sidecar at most once, using a one-shot `loadFailed` flag, and only before the first save. Skip the rename when the read failed with EPERM. The rename is best-effort (`try?`) and never blocks the save. legacyArrayFormatStillDecodes and seenIdentitiesSurviveReload still pass.
- WS3: call `markSeen` only after the wait, and only when `FileIdentity.at(path:) != identity`. Never call it before the wait, on timeout, or on copy failure, so the retry path still works. `markSeen` is persisted and capped at SnapClipConstants.maxSeen.
- WS4: no behavior change. The extraction and its tests land in the same commit. Each new test fails when its guard is changed. Existing tests are unchanged. Fallback if Swift 6 Sendable/@MainActor plumbing grows too large: extract only `needsRescan(flags)` and the copy-then-add decision, and log the fork to STATE.md.
- WS5: delete the dead fileExists branch. Do not move it ahead of the version check, because that would show a false "Update installed". On timeout, call `interrupt()` (SIGINT), wait about 60 s, then call `terminate()`. Record in tasks/lessons.md that how real brew handles signals cannot be unit-tested.

## Decisions
- D1: Land once at the end through one PR into main. A human merges it. (owner, 2026-10-08)
- D2: The `codex` subagent reviews each todo independently. No author may clear their own change. (owner, 2026-10-08)
- D3: There is no CI. Verify locally with `swift build` and `swift test`, plus `scripts/build-app.sh` for any todo touching Sources/SnapClip/. (owner, 2026-10-08)
- D4: Log forks to tasks/research/STATE.md. (owner)
- D5: WS5 runs extraction before the signal change. T07 moves the runner into Core and adds tests for its current failure paths, still sending SIGTERM. T08 then adds SIGINT plus the grace period, so the new interrupt-order tests fail against the T07 runner. This reverses the spec's stage 2/3 order. (assumed, confirm by T07)
- D6: The sidecar is named `tracked.json.unreadable-<yyyyMMdd'T'HHmmss'Z'>`, built from the store's injected `now()`. This is ISO 8601 basic format: it sorts correctly, has no colons, and two failures on the same day get different names. (confirmed by T02, 2026-10-08)
- D7: `CocoaError.fileReadNoSuchFile` counts as ENOENT: no log, no flag. `CocoaError.fileReadNoPermission` counts as EPERM: log it, but do not set the flag. Any other read error, or a decode failure after both the State and legacy attempts, logs the error and sets the flag. (confirmed by T02, 2026-10-08)
- D8: The runner lives in Sources/SnapClipCore/UpgradeRunner.swift.
  - It defines the protocols `UpgradeProcess` and `UpgradeProcessLauncher`.
  - `SystemUpgradeProcessLauncher` is the only code that creates a Foundation `Process`.
  - `isExecutable`, `timeout`, and `grace` are injected, so tests need no real executable and no real waits.
  (assumed, confirm by T07)
- D9: tasks/research/STATE.md does not exist at HEAD and nothing gitignores it. The first todo that logs a fork creates it and commits it alongside TODO.md; later todos append to it in their own PR. (assumed, confirm by T01)
- D10: `ScreenshotPipeline.handle` returns the Tasks it spawns (`@discardableResult`), so tests can await them instead of sleeping. (confirmed by T03, 2026-10-08)

## Todos

### T01 Clamp the automatic update-check delay to the check interval
- status: done (#2, 2026-10-08)
- needs: none
- size: S
- scope:
  - Re-verify that UpdateChecker.swift:117-121 still returns `max(updateInitialDelay, remaining)` with no upper bound, and that UpdateController.swift:100 is the only writer of `lastUpdateCheck`. If not, mark skipped and log to STATE.md.
  - Change line 120 to `return min(SnapClipConstants.updateCheckInterval, max(SnapClipConstants.updateInitialDelay, remaining))`.
  - In `nextCheckIsDelayedUntil24HoursAfterLast`, add an assertion with lastCheck = now + 10 days that expects `SnapClipConstants.updateCheckInterval` (upper bound). Keep the existing -90_000 -> 5 assertion as the lower-bound pin.
- files: Sources/SnapClipCore/UpdateChecker.swift:115-122; Tests/SnapClipCoreTests/SnapClipCoreTests.swift:339-344
- done when: `swift test` passes. With the `min(...)` removed, `nextCheckIsDelayedUntil24HoursAfterLast` fails (it gets 950_400, not 86_400). The codex review has no open findings.
- verify: `swift build`; `swift test --filter nextCheckIsDelayedUntil24HoursAfterLast`; mutation run (remove the clamp, run the filter, expect a failure, restore); `swift test`; codex review of the todo diff (D2)

### T02 Log and preserve an unreadable tracked.json
- status: done (#3, 2026-10-08)
- needs: none
- size: M
- scope:
  - Re-verify that TrackerStore.swift:124-132 returns `empty` without logging on read or decode failure, that :142 overwrites the file atomically, and that :103 only saves when `dirty` is set. If not, mark skipped and log.
  - Change `load(from:)` to return the state plus whether the file existed but could not be used. NSLog each failure branch per D7, including the error description.
  - Add the one-shot `loadFailed` flag. When it is set, `save()` calls `try? FileManager.default.moveItem` to rename storeURL to the D6 sidecar, clears the flag, then writes. A failed rename never blocks the write.
  - Add tests to PersistenceTests:
    - Garbage bytes at the store URL: after init, items and seen are empty. After one add, exactly one `tracked.json.unreadable-*` sidecar exists and holds the garbage bytes, and tracked.json decodes.
    - A second add creates no second sidecar.
    - A fresh Fixture add creates no sidecar.
    - A store file set to chmod 000 (EPERM) gets no sidecar after an add.
- files: Sources/SnapClipCore/TrackerStore.swift:29-59, 122-146; Tests/SnapClipCoreTests/SnapClipCoreTests.swift:202-239
- done when:
  - The new tests pass.
  - Removing the rename makes the sidecar test fail.
  - Removing the flag reset makes the exactly-one-sidecar assertion fail.
  - Removing the EPERM skip makes the chmod 000 test fail.
  - legacyArrayFormatStillDecodes, seenIdentitiesSurviveReload, and sweepWithoutChangeDoesNotRewriteFile pass without edits.
  - The codex review has no open findings.
- verify: `swift build`; `swift test --filter PersistenceTests`; the three mutation runs above; `swift test`; codex review (D2)

### T03 Extract the screenshot event pipeline into SnapClipCore with guard-locking tests
- status: done (#4, 2026-10-08)
- needs: none
- size: M
- scope:
  - Re-verify that AppDelegate.swift:73-111 still contains private `handle`/`rescanWatchedFolder`/`consider` with the three untested fixes: add only after a successful copy (:107-109), the rescan flags (:78-83), and the inFlight dedup (:97, :103, :106). Read tasks/todo.md:32-33. If not, mark skipped and log.
  - Add a new `@MainActor final class ScreenshotPipeline` in Core.
    - It owns `inFlight`, the store, and a settable `watchedFolder` (AppDelegate reassigns it at :29).
    - Injected: `waitUntilStable: (String) async -> Bool`, `copy: (URL) -> Bool`, `listFolder: (URL) -> [String]`, `identityOf`, and `now`.
    - Add a public `EventFlags: OptionSet`, mapped from FSEventStreamEventFlags in FolderWatcher.
    - `handle` returns its Tasks (D10).
  - AppDelegate keeps `copyToClipboard` and becomes an adapter. The logic moves verbatim, with no behavior change.
  - Add a ScreenshotPipelineTests suite with four tests:
    - copy returns false -> file not tracked.
    - MustScanSubDirs and KernelDropped events -> listFolder is called and its recent screenshots are considered.
    - Two events for the same path while it is in flight -> copy runs once.
    - Identity changes during the wait -> file not added.
  - Fallback if the Swift 6 Sendable/@MainActor plumbing grows too large: extract only `needsRescan(flags)` and the copy-then-add decision as pure functions, test the four behaviors where they can be expressed, and log the fork to STATE.md.
- files: new Sources/SnapClipCore/ScreenshotPipeline.swift; Sources/SnapClip/AppDelegate.swift:7-16, 25-40, 73-111; Sources/SnapClip/FolderWatcher.swift:7-10, 28-37; Tests/SnapClipCoreTests/SnapClipCoreTests.swift (new suite; reuse `setScreenCaptureXattr` :38-42 and the eligible-file setup in PolicyTests :129-200)
- done when:
  - The four new tests pass.
  - Each one fails when its guard is changed by hand: remove the copy check, the rescan branch, the inFlight check, or the identity re-check.
  - All existing tests pass, and no existing test body is edited.
  - The app built by `scripts/build-app.sh` copies a real Cmd+Shift+4 screenshot to the clipboard and lists it in the menu.
  - The codex review has no open findings.
- verify: `swift build`; `swift test --filter ScreenshotPipelineTests`; the four mutation runs; `swift test`; `scripts/build-app.sh`, then launch the built app, trigger Cmd+Shift+4 via System Events with the real `defaults`, and paste to confirm the clipboard; codex review (D2)

### T04 Add a persisted TrackerStore.markSeen
- status: done (#5, 2026-10-08)
- needs: T02
- size: S
- scope:
  - Re-verify that identities enter `seen` only in `add` (TrackerStore.swift:73-74), and that ScreenshotPolicy.swift:18-20 accepts an unseen file whose screencapture xattr is at most 30 s old. If not, mark skipped and log.
  - Add `public func markSeen(_ identity: FileIdentity)`:
    - Append the identity if absent and cap the list at SnapClipConstants.maxSeen. Share one private helper with `add` for this.
    - Persist via `save()`, so T02's sidecar rename still runs first.
    - Do not touch `items`, and do not call `sweep`.
  - Tests:
    - An eligible screenshot gets shouldTrack true. After markSeen(identity) and a rename, shouldTrack(newPath) is false.
    - Extend seenIdentitiesSurviveReload so an identity that was marked but never added survives a reload.
- files: Sources/SnapClipCore/TrackerStore.swift:61-81; Tests/SnapClipCoreTests/SnapClipCoreTests.swift:129-200 (PolicyTests), 202-213 (PersistenceTests)
- done when: the new and extended tests pass. Turning `markSeen` into a no-op makes both fail. Every other existing test passes. The codex review has no open findings.
- verify: `swift build`; `swift test --filter PolicyTests`; `swift test --filter PersistenceTests`; mutation run (no-op `markSeen`); `swift test`; codex review (D2)

### T05 Mark a screenshot seen when it is renamed during the stability wait
- status: todo
- needs: T03, T04
- size: S
- scope:
  - Re-verify that T03's pipeline still removes the identity from inFlight after the wait and returns without marking it when `identityOf(path) != identity`. If not, mark skipped and log.
  - In ScreenshotPipeline, after the wait: remove the identity from inFlight. If `identityOf(path) != identity`, call `store.markSeen(identity)` and return. Otherwise keep `guard stable, copy(url) else { return }`, then add. Never mark before the wait, on timeout, or on copy failure. This is WS4 stage 3.
  - Tests:
    - Rename: extend T03's identity-changed test to rename the file during the injected wait. Assert no add, the identity is in seenIdentities, and a later event for the new path does not call copy.
    - Timeout: the wait returns false and the identity is unchanged. Assert the identity is not seen, and a second event for the same path calls copy.
  - If T03 took the fallback, put the mark decision in the extracted decision function and test it there.
- files: Sources/SnapClipCore/ScreenshotPipeline.swift; Tests/SnapClipCoreTests/SnapClipCoreTests.swift (ScreenshotPipelineTests)
- done when:
  - The tests pass.
  - Removing the `markSeen` call makes the rename test fail.
  - Moving `markSeen` before the wait makes the timeout test fail.
  - Manual check: a script renames the file within 0.3 s of a real Cmd+Shift+4 screenshot. The SnapClip menu never lists it, and the renamed file still exists after 5 min.
  - The codex review has no open findings.
- verify: `swift build`; `swift test --filter ScreenshotPipelineTests`; both mutation runs; `swift test`; `scripts/build-app.sh`, then the manual check above (Cmd+Shift+4 via System Events, real `defaults`); codex review (D2)

### T06 Delete the unreachable "Update installed" branch in finishUpgrade
- status: todo
- needs: none
- size: S
- scope:
  - Re-verify that UpdateController.swift:219-225 calls presentFailure and returns whenever the Info.plist at stableAppPath is missing or unreadable. That makes the fileExists guard at :226-233 unreachable. If not, mark skipped and log.
  - Delete lines 226-233 only. finishUpgrade becomes the version check followed by `relaunch(from:)`.
  - Do not move the guard ahead of the version check. That would show a false "Update installed".
- files: Sources/SnapClip/UpdateController.swift:219-235
- done when: `grep -n '"Update installed"' Sources/SnapClip/UpdateController.swift` returns nothing. A version mismatch still calls presentFailure. `swift build`, `swift test`, and `scripts/build-app.sh` exit 0. The codex review has no open findings.
- verify: `swift build`; `swift test`; `scripts/build-app.sh`; the grep above; codex review (D2)

### T07 Move the Homebrew upgrade runner into SnapClipCore behind a fake-able process seam
- status: todo
- needs: T06
- size: M
- scope:
  - Re-verify that UpdateController.swift:176-217 `runUpgrade` returns `.failed` at :182, :185, :208, :210, and :215, that the watchdog at :200-207 calls `process.terminate()`, and that no test covers it. If not, mark skipped and log.
  - Create Sources/SnapClipCore/UpgradeRunner.swift (D8).
    - Make `UpgradeOutcome` and `TimeoutFlag` public.
    - Add the `UpgradeProcess` protocol (run, waitUntilExit, interrupt, terminate, isRunning, terminationStatus), the `UpgradeProcessLauncher` protocol, and `SystemUpgradeProcessLauncher`.
    - Move the body verbatim. It still sends SIGTERM on timeout, and the `.failed` strings and `$ brew ...` log headers stay identical.
    - UpdateController keeps `upgradeTimeout` and calls the runner from :164.
    - No posix_spawn, no process groups.
  - Add UpgradeRunnerTests, using only the fake launcher (never real brew):
    - brew missing -> `.failed("Homebrew was not found at ...")`, and the launcher is never called.
    - Log dir not writable (read-only temp parent) -> `.failed("Could not create ...")`, and the launcher is never called.
    - `update` exits 1 -> "brew update exited with status 1", and `upgrade` is never launched.
    - `update` exits 0 and `upgrade` exits 1 -> "brew upgrade exited with status 1".
    - A fake that never exits, with a 50 ms timeout -> `.failed("Update timed out")`, and terminate is recorded.
- files: new Sources/SnapClipCore/UpgradeRunner.swift; Sources/SnapClip/UpdateController.swift:11-23, 158-173, 175-217; Tests/SnapClipCoreTests/SnapClipCoreTests.swift (new suite after HomebrewInstallTests, :347+)
- done when:
  - The five new tests pass, and each fails when its guard is removed.
  - `grep -rn 'Process()' Tests/` and `grep -rn 'SystemUpgradeProcessLauncher' Tests/` return nothing.
  - /secreview has no unresolved HIGH/CRITICAL findings.
  - The codex review has no open findings.
- verify: `swift build`; `swift test --filter UpgradeRunnerTests`; the five mutation runs; `swift test`; `scripts/build-app.sh`; the two greps above; `/secreview` on the todo diff; codex review (D2)

### T08 Interrupt a timed-out brew with SIGINT before SIGTERM
- status: todo
- needs: T07
- size: S
- scope:
  - Re-verify that UpgradeRunner's watchdog still calls `terminate()` directly on timeout. If not, mark skipped and log.
  - On timeout:
    - Set the flag and call `interrupt()` (SIGINT; Homebrew delays it until any critical section finishes).
    - Schedule `terminate()` after `grace`, and only if `isRunning`.
    - Cancel both work items after `waitUntilExit`.
    - `grace` is injected. UpdateController passes 60 s through a new `private nonisolated static let upgradeInterruptGrace` next to `upgradeTimeout` at :16.
    - No posix_spawn, no process groups.
  - Replace T07's timeout test with two tests:
    - A fake that ignores SIGINT records [interrupt, terminate] and returns `.failed("Update timed out")`.
    - A fake that exits on SIGINT records [interrupt] only.
- files: Sources/SnapClipCore/UpgradeRunner.swift; Sources/SnapClip/UpdateController.swift:16 and the runner call site; Tests/SnapClipCoreTests/SnapClipCoreTests.swift (UpgradeRunnerTests)
- done when: both tests pass, and both fail against the T07 runner (terminate only). /secreview has no unresolved HIGH/CRITICAL findings. The codex review has no open findings.
- verify: `swift build`; `swift test --filter UpgradeRunnerTests`; mutation run (restore the direct `terminate()`, expect both tests to fail); `swift test`; `scripts/build-app.sh`; `/secreview` on the todo diff; codex review (D2)

### T09 Verify the SIGINT path against real Homebrew and record the lesson
- status: todo
- needs: T08
- size: S
- scope:
  - Re-verify that T08's interrupt-then-terminate is on the branch tip. If not, mark skipped and log.
  - Precondition: SnapClip runs from a Homebrew Cellar bundle with a newer release published. Otherwise `HomebrewInstall(bundlePath:)` returns nil and Install Update only opens the release page. If this cannot be set up, log a blocked fork to STATE.md and ask the owner.
  - In a debug build only (never committed), set `upgradeTimeout = 5` s and click Install Update. Then read ~/Library/Logs/SnapClip/update.log for Homebrew's interrupt and cleanup output, and run `brew list --versions snapclip`.
  - Add a tasks/lessons.md entry: how real brew handles signals cannot be unit-tested. The fake-runner tests cover only the signal order; the manual 5 s timeout run covers Homebrew's response.
- files: tasks/lessons.md; Sources/SnapClip/UpdateController.swift:16 (temporary edit only, reverted)
- done when:
  - update.log shows brew handling the interrupt and cleaning up.
  - `brew list --versions snapclip` prints exactly one version.
  - `grep -n 'upgradeTimeout: TimeInterval = 15 \* 60' Sources/SnapClip/UpdateController.swift` matches.
  - The only file this todo commits is tasks/lessons.md.
  - The codex review has no open findings.
- verify: `scripts/build-app.sh` (with the temporary timeout); the manual Install Update run; `brew list --versions snapclip`; revert the timeout, then `git diff --stat`, `swift build`, `swift test`, and `scripts/build-app.sh`; codex review (D2)

### TZZ Cleanup and land
- status: todo
- needs: every other todo
- scope: run `/implement cleanup`
- done when: skill removed from the branch, TODO.md archived, landing PR into main open and approved by the owner

## Backlog
- If tracked.json is unreadable with EPERM, the spec skips the rename, but the atomic save still replaces the file when the directory is writable. Decide whether saves should be blocked in that case.
- SIGINT goes only to brew's pid. Child processes in other process groups may not receive it. Process groups are out of scope for this pass.
- `tracked.json.unreadable-*` sidecars pile up with nothing to clean them up.
- Sidecar names have one-second resolution. Two unusable loads in the same UTC second collide, the try? rename fails silently, and the save overwrites the file. Consider a unique suffix and logging the rename failure.
- ScreenshotPipelineTests cover 2 of the 4 rescan flags (UserDropped and RootChanged untested) and have no negative case showing a plain itemCreated event does not list the folder.

## Log
- 2026-10-08: Plan created at HEAD c7705e0.
  - These cited lines match: UpdateChecker.swift:117-121; UpdateController.swift:100, 176-235; TrackerStore.swift:73-74, 103, 124-132, 142; AppDelegate.swift:73-111.
  - Not yet re-checked: ScreenshotPolicy.swift:18-20 (T04) and tasks/todo.md:32-33 (T03).
  - HEAD has 32 `@Test` cases; the spec says 30.
  - tasks/research/STATE.md is absent (D9).
- 2026-10-08: T01 done. Update-check delay clamped to updateCheckInterval; upper-bound assertion added. (#2)
- 2026-10-08: T02 done. Unreadable tracked.json is logged and renamed to a tracked.json.unreadable-<timestamp> sidecar once before the first save; ENOENT silent, EPERM logged without rename. (#3)
- 2026-10-08: T03 done. Screenshot event pipeline extracted to SnapClipCore.ScreenshotPipeline; copy-before-add, rescan flags, inFlight dedup and identity re-check now have guard-locking tests. (#4)
- 2026-10-08: T04 done. TrackerStore.markSeen records an identity as seen (persisted, capped at maxSeen) without tracking it.
