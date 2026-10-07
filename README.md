<p align="center"><img src="assets/icon-1024.png" width="128" alt="SnapClip icon"></p>

# SnapClip

A macOS menu-bar app that copies every screenshot to the clipboard and cleans up after itself.

## What it solves

macOS saves screenshots to the Desktop, so it fills up, and you must paste or drag each one by hand. SnapClip copies each new screenshot to the clipboard and keeps the Desktop tidy, without ever deleting a screenshot you chose to keep.

![SnapClip menu showing tracked screenshots with time left](assets/preview.png)

## Features

- Copies each new screenshot (Cmd+Shift+3, 4 or 5) to the clipboard as an image and file URL.
- The file stays in your screenshot folder.
- Keeps at most 5 tracked screenshots; a 6th moves the oldest to the Trash.
- Moves each tracked screenshot to the Trash 5 minutes after it appeared.
- Never touches a file you moved or renamed.
- Menu bar list with time left per screenshot, a Copy action for each, Instant Copy, Start at Login, Open Screenshot Folder, Quit.

## Install

```sh
brew install 0xnicholasy/tap/snapclip
ln -sf "$(brew --prefix)/opt/snapclip/SnapClip.app" /Applications/SnapClip.app
open /Applications/SnapClip.app
```

First run: macOS asks whether SnapClip may access your Desktop folder (or whichever folder holds your screenshots). Allow it, or screenshots cannot be detected.

## Why is there a delay?

When macOS shows the floating screenshot thumbnail in the corner of the screen, it saves the file only after the thumbnail closes (about 10 seconds). SnapClip copies the file as soon as it exists, so the copy arrives late.

Turn on **Instant Copy (no floating thumbnail)** in the SnapClip menu. This sets `show-thumbnail` to false in the `com.apple.screencapture` defaults domain, so macOS saves each screenshot immediately. Untick it to get the thumbnail back. On first launch SnapClip asks whether to turn the thumbnail off.

## Desktop icons are hidden

If macOS hides your Desktop icons (System Settings > Desktop & Dock > Show Items on Desktop), screenshots still land in the folder but you cannot see them on the Desktop. SnapClip shows "Desktop icons are hidden by macOS" in its menu with a "Show Desktop Icons..." shortcut to that settings pane. It never changes the setting itself.

## Build from source

Requires macOS 14+ and the Swift toolchain (Xcode).

```sh
swift test
scripts/build-app.sh      # produces build/SnapClip.app, ad-hoc signed
open build/SnapClip.app
```

## How the rules work

- Watch folder: the `location` key of the `com.apple.screencapture` defaults domain, or `~/Desktop` if unset. It is re-read each time the app starts.
- Detection: a file counts as a screenshot only if it has the extended attribute `com.apple.metadata:kMDItemIsScreenCapture`. Dotfiles are ignored. SnapClip waits for the file size to stop changing before copying. Files that already existed at launch are never copied or tracked.
- Tracking: each screenshot is stored in `~/Library/Application Support/SnapClip/tracked.json` with its path, inode, device and time added.
- Still in place: a file is only SnapClip's to delete while a file at the original path has the same inode and device. If it was moved, renamed or replaced, SnapClip stops tracking it and never touches it.
- Sweep: every 10 seconds and after each new screenshot: drop files no longer in place, trash files tracked for 300 seconds or more, then trash the oldest while more than 5 are tracked. Trashing uses `FileManager.trashItem`, so files are recoverable.
- Start at Login: writes `~/Library/LaunchAgents/io.github.0xnicholasy.snapclip.plist` (runs `/usr/bin/open -a <app>` at login). Under Homebrew the path is rewritten to `<prefix>/opt/snapclip/...` so upgrades keep working. The toggle is checked when the plist exists; changes apply at next login.

## License

MIT
