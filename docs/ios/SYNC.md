# How sync works

Code: `Sources/BetterWisprCore/Sync/`. Tests: `Tests/BetterWisprCoreTests/SyncTests.swift`.

## Folder layout

Inside the folder the user picks (usually iCloud Drive itself):

    BetterWispr/v1/devices/<device id>/device.json          name, platform, last sync time
    BetterWispr/v1/devices/<device id>/library.json         history, vocabulary, modes, shared preferences
    BetterWispr/v1/devices/<device id>/meetings/<id>.json   one file per meeting

A device writes only inside its own `<device id>` folder and reads everyone's. Two devices never write the same file, so iCloud never makes conflict copies.

## Records and stamps

Every item is a record: `kind` (transcript, vocabulary, mode, preferences, meeting), `id`, a payload, and a stamp of (counter, device id, time). Deleted items stay as records with `deleted: true` (tombstones) for 180 days so the deletion reaches every device.

For each item, the record with the highest stamp across all devices wins. Stamps compare by counter, then device id. The counter is a Lamport clock: each local edit takes one more than the highest counter the device has seen, so an edit made after seeing another device's version always wins, and phone clocks don't matter.

## One sync

1. Compare the local library with the local journal (`sync-journal.json` next to the workspace, never synced). New or changed items get a new stamp; items gone from the library get a tombstone.
2. Read every other device's files and keep the highest stamp per item.
3. Apply other devices' winning changes to the library.
4. Write this device's own files with every winning record.
5. The app saves the library, then commits the new journal. If saving fails, nothing is committed and the next sync merges again from scratch, so nothing is lost.

## Rules that matter

- A device's first sync yields to existing records on equal stamps, so a fresh install's default settings don't replace the Mac's.
- Meeting files a device can't read are never treated as deleted.
- A record a device can't decode (from a newer version) never overwrites a readable one.
- A device refuses to sync with files in a newer format and says to update.
- Files iCloud hasn't downloaded yet are requested and counted as pending; another sync follows shortly.
- The apps retry when the library changed while sync was reading the folder, rather than overwrite the user's new edit.
- Apps must not silently rewrite synced settings (for example resetting a language the local model lacks), or devices will keep correcting each other.

## What syncs

History, vocabulary (including learned words), writing modes, and these settings: spoken language, cleanup level, writing tones, learn from corrections, save history, theme, and mode order. Meetings sync too.

Not synced: API keys, chosen speech model, microphone, shortcut, launch and Dock settings, onboarding state, keyboard settings, notes CLI choice.

## Known limits

- A device offline for more than 180 days can bring back items deleted meanwhile.
- Every sync reads every meeting file from every device. Fine for hundreds of meetings; add a modification-date cache if it gets slow.
- The Mac and iPhone each need the folder picked once.
