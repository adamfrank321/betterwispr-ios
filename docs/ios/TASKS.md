# Task list

Status: [x] done, [~] in progress, [ ] not started. Update on every push.
"Built" means it compiles in CI. "Device-tested" means someone ran it on a real iPhone or Mac; nothing is device-tested yet.

1. [x] Read desktop changelog and source; map storage and features
2. [x] Fork into adamfrank321/betterwispr-ios with full upstream history
3. [x] CI on GitHub macOS runners; errors appear as check annotations (`gh api repos/adamfrank321/betterwispr-ios/check-runs/<job id>/annotations`) because raw logs can't be downloaded from the agent sandbox
4. [x] BetterWisprCore builds for iOS 17 (macOS-only capture, Accessibility, paste, website and CLI code guarded; saved formats unchanged)
5. [x] Sync engine with 11 tests, all passing (see SYNC.md)
6. [x] Shared DictationProcessor; the Mac app uses it with unchanged behaviour
7. [x] Mac app: Sync card in Settings, sync on launch, after saves, every minute and on activation (built, not device-tested)
8. [x] iOS app, keyboard, meetings, settings, sync: built in CI on branch `agent/ios-app`
9. [x] iOS unit tests in the simulator (5 passing)
10. [x] Merged `agent/ios-app` into main
11. [x] App icon drawn from the desktop mark
12. [~] Dictate shortcut for Siri, Shortcuts and the Action Button done; Control Center control (needs a widget extension) not started
13. [ ] Live Activity while the keyboard session or a meeting is recording
14. [x] Notes API connections can be added on iOS (connections are per device, like the Mac's; keys stay in each keychain)
15. [ ] Device testing: keyboard handoff, background warm session, model downloads on cellular, sync with the Mac through iCloud Drive
16. [~] Review: self-review done (damaged-file handling, audio interruptions, stale keyboard results fixed); an independent reviewer should still go over it

## Open questions for Adam

- Bundle ID and Apple team for signing (placeholders `org.betterwispr.mobile` and group `group.org.betterwispr.shared` until then)
- App Store or personal install only. The keyboard opens the app through the responder chain, which App Review has accepted for other apps but is not an official API.
- Whether to upstream the sync and iOS-portability changes to opennookorg/betterwispr as a pull request

## Known gaps versus the Mac

- iOS can't see which app or website you're in: tone is picked on the keyboard, modes switch by trigger word only, screen context is just the text around the cursor.
- Meetings record the phone's microphone only; lines read "Them" until speaker detection labels them Speaker 1, 2…
- No Claude Code or Codex notes on iPhone; Ollama only if added as an API connection reachable from the phone.
- User-facing strings inside the shared library still say "Mac" in a few error messages.
