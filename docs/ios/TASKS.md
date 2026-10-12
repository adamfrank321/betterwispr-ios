# Task list

Status: [x] done, [~] in progress, [ ] not started. Update on every push.

1. [x] Read desktop changelog and source; map storage and features
2. [x] Fork into adamfrank321/betterwispr-ios with full upstream history
3. [x] CI on GitHub macOS runners (desktop build and tests pass on unchanged code)
4. [~] Make BetterWisprCore build for iOS (add iOS platform, guard macOS-only code without changing the saved file format)
5. [ ] Sync engine in Core (per-device files, Lamport stamps, tombstones) with unit tests
6. [ ] Move the dictation cleanup steps from the Mac AppModel into a shared DictationProcessor, Mac app uses it unchanged
7. [ ] Mac app: sync folder setting, sync on launch, after saves and on a timer, merge incoming changes
8. [ ] iOS app shell (XcodeGen project, App Group, onboarding, Home)
9. [ ] iOS dictation (recording, model download and selection, shared processing, copy and share)
10. [ ] iOS screens: History, Vocabulary, Style and modes, Models, Insights, Settings, Sync
11. [ ] Keyboard extension and app handoff for recording
12. [ ] iOS meetings (record, transcribe, speaker detection, notes)
13. [ ] Shortcuts action, Action Button and Control Center control
14. [ ] Independent review and docs check

## Open questions for Adam

- Bundle ID and Apple team for signing (placeholders used until then)
- App Store or personal install only (affects keyboard handoff approach and review risk)
