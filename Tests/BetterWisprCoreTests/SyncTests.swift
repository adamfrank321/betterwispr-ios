import Foundation
import Testing
@testable import BetterWisprCore

/// One simulated device: its library, saved after every sync like the apps do.
private struct Device {
    let engine: SyncEngine
    var library = SyncLibrary()
    var last: SyncResult?

    init(_ name: String, folder: MemorySyncFolder, journals: URL) {
        engine = SyncEngine(folder: folder, journalURL: journals.appending(path: "\(name).json"), deviceName: name, platform: "test")
    }

    mutating func sync(commit: Bool = true, now: Date = .now) throws {
        let result = try engine.sync(library, now: now)
        library = result.library
        last = result
        if commit { try engine.commit(result) }
    }
}

private func transcript(_ text: String, at seconds: TimeInterval = 0) -> Transcript {
    Transcript(createdAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds), text: text, rawText: text,
               duration: 1, modelName: "Test", language: "en")
}

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "sync-\(UUID().uuidString)")
}

@Test func historyAndVocabularyMergeBothWays() throws {
    let folder = MemorySyncFolder(), journals = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: journals) }
    var mac = Device("mac", folder: folder, journals: journals)
    var phone = Device("phone", folder: folder, journals: journals)
    mac.library.history = [transcript("From the Mac", at: 1)]
    mac.library.vocabulary = [VocabularyEntry(phrase: "post hog", replacement: "PostHog", learned: true)]
    try mac.sync()
    try phone.sync()
    #expect(phone.library.history.map(\.text) == ["From the Mac"])
    #expect(phone.library.vocabulary.map(\.replacement) == ["PostHog"])
    #expect(phone.last?.workspaceChanged == true)

    phone.library.history.insert(transcript("From the phone", at: 2), at: 0)
    try phone.sync()
    try mac.sync()
    #expect(mac.library.history.map(\.text) == ["From the phone", "From the Mac"])

    try mac.sync()
    #expect(mac.last?.workspaceChanged == false)
}

@Test func deletionsSpreadAndDoNotComeBack() throws {
    let folder = MemorySyncFolder(), journals = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: journals) }
    var mac = Device("mac", folder: folder, journals: journals)
    var phone = Device("phone", folder: folder, journals: journals)
    mac.library.history = [transcript("Keep", at: 1), transcript("Delete me", at: 2)]
    try mac.sync()
    try phone.sync()
    phone.library.history.removeAll { $0.text == "Delete me" }
    try phone.sync()
    try mac.sync()
    #expect(mac.library.history.map(\.text) == ["Keep"])
    try phone.sync()
    try mac.sync()
    #expect(phone.library.history.map(\.text) == ["Keep"])
    #expect(mac.library.history.map(\.text) == ["Keep"])
}

@Test func aJoiningDeviceTakesTheExistingSettingsInsteadOfItsDefaults() throws {
    let folder = MemorySyncFolder(), journals = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: journals) }
    var mac = Device("mac", folder: folder, journals: journals)
    var phone = Device("phone", folder: folder, journals: journals)
    mac.library.settings.cleanup = .medium
    mac.library.settings.styles = [.work: .casual]
    mac.library.settings.language = "de"
    try mac.sync()
    try mac.sync()
    try phone.sync()
    #expect(phone.library.settings.cleanup == .medium)
    #expect(phone.library.settings.styles == [.work: .casual])
    #expect(phone.library.settings.language == "de")
    try mac.sync()
    #expect(mac.library.settings.cleanup == .medium)
}

@Test func perDeviceSettingsStayLocal() throws {
    let folder = MemorySyncFolder(), journals = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: journals) }
    var mac = Device("mac", folder: folder, journals: journals)
    var phone = Device("phone", folder: folder, journals: journals)
    mac.library.settings.selectedModelID = "parakeet-ultra"
    mac.library.settings.launchAtLogin = true
    try mac.sync()
    phone.library.settings.selectedModelID = "apple"
    try phone.sync()
    #expect(phone.library.settings.selectedModelID == "apple")
    #expect(phone.library.settings.launchAtLogin == false)
}

@Test func theLaterEditOfTheSameItemWinsOnEveryDevice() throws {
    let folder = MemorySyncFolder(), journals = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: journals) }
    var mac = Device("mac", folder: folder, journals: journals)
    var phone = Device("phone", folder: folder, journals: journals)
    let entry = VocabularyEntry(phrase: "cloud", replacement: "Claude")
    mac.library.vocabulary = [entry]
    try mac.sync()
    try phone.sync()
    // Concurrent edits: either may win, but both devices end up with the same one.
    phone.library.vocabulary[0].replacement = "Claude Code"
    try phone.sync()
    mac.library.vocabulary[0].replacement = "Claude AI"
    try mac.sync()
    try phone.sync()
    try mac.sync()
    #expect(mac.library.vocabulary == phone.library.vocabulary)
    #expect(mac.library.vocabulary.count == 1)
    // An edit made after seeing the other device's version always wins.
    mac.library.vocabulary[0].replacement = "Claude"
    try mac.sync()
    try phone.sync()
    #expect(phone.library.vocabulary.first?.replacement == "Claude")
}

@Test func anUnsavedSyncLosesNothing() throws {
    let folder = MemorySyncFolder(), journals = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: journals) }
    var mac = Device("mac", folder: folder, journals: journals)
    var phone = Device("phone", folder: folder, journals: journals)
    mac.library.history = [transcript("Hello", at: 1)]
    try mac.sync()
    try phone.sync()
    mac.library.history[0].text = "Hello, edited"
    try mac.sync()
    // The phone merges but fails to save, so it neither keeps the result nor commits.
    let before = phone.library
    _ = try phone.engine.sync(before)
    phone.library = before
    try phone.sync()
    #expect(phone.library.history.map(\.text) == ["Hello, edited"])
    try mac.sync()
    #expect(mac.library.history.map(\.text) == ["Hello, edited"])
}

@Test func meetingsSyncAndUnreadableOnesAreNeverDeleted() throws {
    let folder = MemorySyncFolder(), journals = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: journals) }
    var mac = Device("mac", folder: folder, journals: journals)
    var phone = Device("phone", folder: folder, journals: journals)
    let first = Meeting(title: "Standup")
    let second = Meeting(title: "Design review")
    mac.library.meetings = [first, second]
    try mac.sync()
    try phone.sync()
    #expect(Set(phone.last?.updatedMeetings.map(\.id) ?? []) == [first.id, second.id])

    // The Mac can no longer read one meeting file; that must not delete it anywhere.
    mac.library.meetings = [second]
    mac.library.unreadableMeetings = [first.id]
    try mac.sync()
    try phone.sync()
    #expect(phone.library.meetings.count == 2)

    phone.library.meetings.removeAll { $0.id == second.id }
    try phone.sync()
    try mac.sync()
    #expect(mac.last?.deletedMeetings == [second.id])
    #expect(mac.library.meetings.isEmpty)
}

@Test func modeOrderFollowsTheLatestEdit() throws {
    let folder = MemorySyncFolder(), journals = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: journals) }
    var mac = Device("mac", folder: folder, journals: journals)
    var phone = Device("phone", folder: folder, journals: journals)
    let casual = WritingMode(name: "Casual", triggerWords: ["casual mode"], tone: .casual)
    let british = WritingMode(name: "British", cleanup: .medium, instructions: "Use British spelling.")
    mac.library.settings.modes = [casual, british]
    try mac.sync()
    try phone.sync()
    #expect(phone.library.settings.modes.map(\.name) == ["Casual", "British"])
    phone.library.settings.modes.reverse()
    try phone.sync()
    try mac.sync()
    #expect(mac.library.settings.modes.map(\.name) == ["British", "Casual"])
}

@Test func eachDeviceWritesOnlyItsOwnFiles() throws {
    let folder = MemorySyncFolder(), journals = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: journals) }
    var mac = Device("mac", folder: folder, journals: journals)
    var phone = Device("phone", folder: folder, journals: journals)
    mac.library.meetings = [Meeting(title: "Call")]
    try mac.sync()
    let macFiles = Set(folder.paths)
    try phone.sync()
    let phoneID = try phone.engine.deviceID()
    let added = Set(folder.paths).subtracting(macFiles)
    #expect(!added.isEmpty)
    #expect(added.allSatisfy { $0.hasPrefix("\(SyncEngine.base)/\(phoneID)/") })
    #expect(phone.last?.devices.map(\.name) == ["mac"])
}

@Test func oldTombstonesExpire() throws {
    let folder = MemorySyncFolder(), journals = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: journals) }
    var mac = Device("mac", folder: folder, journals: journals)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    mac.library.history = [transcript("Gone")]
    try mac.sync(now: start)
    mac.library.history = []
    try mac.sync(now: start)
    let id = try mac.engine.deviceID()
    let early = try #require(try folder.read("\(SyncEngine.base)/\(id)/library.json"))
    #expect(String(decoding: early, as: UTF8.self).contains("\"deleted\":true"))
    try mac.sync(now: start.addingTimeInterval(SyncEngine.tombstoneLifetime + 60))
    let late = try #require(try folder.read("\(SyncEngine.base)/\(id)/library.json"))
    #expect(!String(decoding: late, as: UTF8.self).contains("\"deleted\":true"))
}
