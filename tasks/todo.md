# SnapClip — plan

Finish line: `brew install 0xnicholasy/tap/snapclip` installs a working app on this Mac; a real screenshot is auto-copied to clipboard, stays on Desktop, and is trashed by the 5-min / max-5 rules unless moved; Start-at-login toggle works; public repo README shows icon + preview image.

## Decisions (confirmed by user 2026-10-07)
- Display: screenshot file stays on Desktop (macOS default location) + auto-copied to clipboard. No floating widget.
- Distribution: own tap `0xnicholasy/homebrew-tap`, source-build formula (`swift build`), no Apple Developer ID. Reason: Homebrew dropped casks failing Gatekeeper on 2026-09-01.
- Auto-delete: move to Trash (recoverable).
- Name: SnapClip, repo `0xnicholasy/snapclip` (public).
- Icon + README preview made with the `/image` skill.

## Design
- SwiftPM: `SnapClipCore` (logic, testable), `SnapClip` (executable, AppKit menu-bar app, LSUIElement), `SnapClipCoreTests`.
- Watch folder = `defaults read com.apple.screencapture location`, fallback `~/Desktop`. FSEvents on that folder.
- Screenshot detection: xattr `com.apple.metadata:kMDItemIsScreenCapture` (locale independent). Ignore dotfiles / temp files; wait until size stable.
- On new screenshot: write image to NSPasteboard (image data + file URL).
- Tracker persisted as JSON in `~/Library/Application Support/SnapClip/`: path, file resource identifier, added date.
- A file counts as "kept" (never auto-deleted, dropped from tracking) once it is no longer at its original path (moved or renamed) or its identity changed.
- Retention: >5 tracked files -> trash oldest; age >= 5 min -> trash. Check on timer (every 10 s) and on each new screenshot.
- Start at login: in-app toggle writes `~/Library/LaunchAgents/io.github.0xnicholasy.snapclip.plist` pointing to a stable app path (Homebrew `opt/snapclip/SnapClip.app` when running from Cellar, so upgrades don't break it).
- `scripts/build-app.sh`: `swift build -c release`, assemble `SnapClip.app` (Info.plist, icon), ad-hoc `codesign -s -`.

## Steps
- [x] Implement app + tests (7 tests pass; live screenshot copied to clipboard)
- [x] Icon + README preview (/image) — assets/icon-source.png, assets/preview.png
- [x] Wire icon + README (Resources/AppIcon.icns, assets/icon-1024.png, assets/preview.png)
- [x] Verify with real screenshots — max-5, 5-min expiry, move-out, clipboard, restart persistence, login toggle PASS; rename-in-place FAIL (= HIGH 1)
- [x] Fix HIGH 1-2 + MEDIUMs, re-verify rename case live (17 tests pass; renamed file kept)
- Open follow-ups: first screenshot after a fresh rebuild was missed once (suspect Desktop TCC prompt after re-sign, unconfirmed); "Start at Login" first click did nothing once in live test (cause not found).
- [x] Code review — 2 HIGH to fix before tag:
  - AppDelegate `consider`: renamed/moved-in screenshot within 30 s re-tracked and later trashed. Fix: skip known identities, persist "kept" identities, move decision into Core + regression tests.
  - Non-image (.mov recording) or unreadable file tracked and trashed with no clipboard copy. Fix: require public.image UTType, add only after successful copy.
  - MEDIUM: symlinked screenshot folder; single pasteboard item; FSEvents rescan flags; trash/TCC notes.
- [ ] Public repo + tag v0.1.0
- [ ] Tap formula + `brew install` verified
