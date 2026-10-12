# BetterWispr iOS: handoff

Read this first. It says what exists, what was decided and why, and what to do next. The task list is in TASKS.md next to this file. Keep both current with every push.

## Goal

An iOS companion to the BetterWispr Mac app (upstream: github.com/opennookorg/betterwispr, Apache 2.0) that:

1. Shares as much desktop behaviour as possible by reusing the desktop's `BetterWisprCore` library instead of rewriting it.
2. Keeps the user's library in sync between Mac and iPhone: dictation history, vocabulary, writing modes, style settings and meeting notes.

## Repo layout

This repo is a fork of the desktop repo, so both apps build from one source tree.

- `Sources/BetterWisprCore` shared library (desktop code, being made to build for iOS as well)
- `Sources/BetterWisprCore/Sync` folder sync engine shared by both apps (planned)
- `Sources/BetterWispr` the Mac app (gets a sync setting)
- `iOS/` the iOS app, keyboard extension and widgets, generated with XcodeGen from `iOS/project.yml` (planned)
- `docs/ios/` this handoff, the task list and the sync spec
- `.github/workflows/ci.yml` builds everything on GitHub's macOS runners

## How to build

There is no Mac in the agent sandbox. All compiling happens in GitHub Actions (`.github/workflows/ci.yml`), which runs on pushes to `main` and `agent/**`:

- `macos`: `swift build` and `swift test` for the desktop package
- `core-ios`: builds `BetterWisprCore` for the iOS Simulator
- `ios-app`: `xcodegen generate` in `iOS/`, then builds and tests the iOS app (skipped until `iOS/project.yml` exists)

Check results with `gh run list -R adamfrank321/betterwispr-ios` and `gh run view <id> -R adamfrank321/betterwispr-ios --log-failed`.

On a Mac: `swift build && swift test` at the root, and `cd iOS && xcodegen generate && open BetterWisprMobile.xcodeproj`.

## Decisions

Sync through a folder the user picks, not CloudKit. The Mac app ships as a Developer ID download, not through the App Store, and an open source build can't rely on a shared CloudKit container or team ID. A folder in iCloud Drive works with no entitlements on the Mac and a security-scoped bookmark on iOS. It also works with any other synced folder.

Each device writes only its own files in the sync folder. Every device reads everyone's files and merges, then rewrites only its own. Two devices never edit the same file, so iCloud never produces conflict copies.

Merge rule: each record (one dictation, one vocabulary entry, one mode, one meeting, the shared preferences) carries a stamp of (counter, device). The highest stamp wins. Deletions are kept as tombstones so they spread instead of the record coming back. The counter is a Lamport clock, so a phone with a wrong clock can't win every conflict.

The desktop's saved file format (`workspace.json`, version 1, and per-meeting files) is not changed. Sync state lives in a separate local journal file, so the upstream app and this fork can read each other's workspace.

What syncs: history, vocabulary (including learned words), writing modes, style tones, cleanup level, spoken language, learn-from-corrections, save-history, theme, meetings.
What does not sync: API keys (stay in Keychain on each device), the chosen speech model, microphone, shortcut, login and Dock settings, onboarding state, notes CLI choices.

The keyboard can't record. iOS doesn't give keyboard extensions the microphone. The keyboard's dictate button opens the app, which records with background audio, then the user returns to their app and the keyboard inserts the text from the shared App Group. This is the same approach Wispr Flow uses on iPhone. A session stays warm for a few minutes so later dictations don't need the jump.

## Feature parity

| Desktop feature | iOS | Notes |
| --- | --- | --- |
| Local speech models (Apple, Parakeet, Whisper) | Yes | Same providers from Core; models download on the phone |
| API speech connections | Yes | Keys in iOS Keychain, not synced |
| Light cleanup, voice commands, spoken numbers and symbols, email layout | Yes | Shared code |
| Medium cleanup | Partly | Apple Intelligence (iOS 26) and API connections; Ollama only at a reachable network address; no Claude Code or Codex CLIs |
| Writing tones per app category | Partly | iOS can't tell which app you're typing in; the keyboard lets you pick the context |
| Writing modes | Partly | Trigger words work; app and website matching can't on iOS |
| Screen context | Partly | Only the text around the cursor that the keyboard can see |
| Vocabulary and phrase booster | Yes | Synced |
| Learn from corrections | Yes | In History, and in the keyboard for edits right after insertion |
| History, Use Original, export | Yes | Synced |
| Insights and streaks | Yes | Computed from synced history |
| Meeting notes | Partly | Microphone only; iOS can't capture other apps' audio. Speaker detection separates people in the room |
| Global shortcut, paste into focused app | Replaced | Keyboard extension, Shortcuts action, Action Button, Control Center control |
| Meeting detection, Dock, launch at login, Sparkle updates | No | Not applicable on iOS |

## State at last update

See TASKS.md for the live list. In short: CI is set up and the unchanged desktop app builds and passes its tests on it. The shared library does not yet build for iOS. Sync engine, iOS app and desktop sync are not written yet.

Parallel helper agents were planned (Opus for porting and the keyboard bridge, Sonnet for iOS screens) but their launch was declined in the session, so work is proceeding in a single session for now.
