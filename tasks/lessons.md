# Lessons

## 2026-10-07: verify with the user's real input path, not a CLI stand-in
- All live tests used `screencapture -x`, which writes the file instantly. The real Cmd+Shift+3/4 flow with the floating thumbnail on (`show-thumbnail = 1`) writes the file only after the thumbnail closes (~10 s), so the clipboard copy looked broken to the user.
- The user's Desktop icons were hidden (`com.apple.WindowManager HideDesktop = 1`), so "file stays on Desktop" was invisible.
- Rule: for features triggered by a system action, test the real trigger (hotkey via System Events) with the user's actual system settings, and read the relevant `defaults` domains first.

## 2026-10-07: instant copy fix verified on the real hotkey
- Cmd+Shift+3 via System Events with thumbnail on: file + clipboard ready after 8.1 s. With `show-thumbnail` false (set by the menu toggle through `UserDefaults(suiteName: "com.apple.screencapture")`): 2.4-2.5 s, no `killall SystemUIServer` needed.
- `osascript -e 'clipboard info'` prints `«class PNGf», <bytes>`; match on that exact form when polling.

## 2026-10-08: a real-trigger rename test cannot be shown from outside to land inside the stability wait
- The live T05 check renamed the screenshot 0.2 ms and 250 ms after it appeared. Both renames landed before SnapClip began its 400 ms stability wait (FSEvents latency 0.2 s plus 200 ms polls), so the post-wait markSeen branch never ran.
- "File not tracked" passes even if the wait was never entered, so it does not show the branch was exercised.
- Rule: before claiming a branch was exercised live, check that the inode appears in tracked.json `seen`, or add a log line in the branch.

## 2026-10-09: real Homebrew's reaction to SIGINT/SIGTERM is unverified
- How real brew reacts to SIGINT or SIGTERM mid-upgrade cannot be unit-tested. UpgradeRunnerTests use a fake process and lock only the signal order: interrupt, ~60 s grace, then terminate.
- The manual check (debug build with `upgradeTimeout = 5`, Install Update from a Cellar install, read update.log, `brew list --versions snapclip`) was skipped on 2026-10-09 because no release newer than 0.1.2 existed. Homebrew's actual cleanup on interrupt is UNVERIFIED.
- Rule: run that check at the next release (v0.1.3+) before treating the interrupt path as proven.
