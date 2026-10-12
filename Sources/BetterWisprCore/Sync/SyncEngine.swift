import Foundation

/// What this device last agreed with the sync folder, kept in its own local file and never synced.
/// Comparing the library against it is how sync tells a local edit or delete from an item that simply hasn't changed.
public struct SyncJournal: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var stamp: SyncStamp
        public var hash: String?
        public var deleted: Bool
    }

    public var format = 1
    public var device: String
    public var counter: UInt64 = 0
    public var entries: [String: Entry] = [:]

    public init(device: String = UUID().uuidString) {
        self.device = device
    }

    public static func load(from url: URL) throws -> SyncJournal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let journal = try JSONDecoder().decode(SyncJournal.self, from: Data(contentsOf: url))
        guard journal.format == 1 else { throw SyncError.unsupportedJournal(journal.format) }
        return journal
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum SyncError: LocalizedError, Equatable {
    case unsupportedJournal(Int)
    case newerFormat(device: String, format: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedJournal(let format): "This device's sync record uses version \(format). Update BetterWispr."
        case .newerFormat(let device, let format): "\(device) syncs with a newer BetterWispr (format \(format)). Update BetterWispr on this device to keep syncing."
        }
    }
}

/// The outcome of one sync. Persist `library`, then call `SyncEngine.commit(_:)`; until then the next sync merges again from scratch, so nothing is lost if saving fails.
public struct SyncResult: Sendable {
    public var library: SyncLibrary
    /// History, vocabulary, modes or shared preferences changed, so the workspace needs saving.
    public var workspaceChanged: Bool
    /// Meetings another device added or edited; save each of these.
    public var updatedMeetings: [Meeting]
    /// Meetings another device deleted; remove these.
    public var deletedMeetings: Set<UUID>
    /// Files iCloud is still downloading; another sync shortly will pick them up.
    public var pendingDownloads: Int
    public var devices: [SyncDevice]
    public var journal: SyncJournal
}

/// Merges this device's library with every other device's files in a shared folder.
///
/// Layout, under the folder the user picks:
///
///     BetterWispr/v1/devices/<device>/device.json          name, platform, last sync
///     BetterWispr/v1/devices/<device>/library.json         history, vocabulary, modes and shared preferences as records
///     BetterWispr/v1/devices/<device>/meetings/<id>.json   one record per meeting
///
/// Each device writes only inside its own folder, so iCloud never has two devices editing one file.
/// Every record carries a stamp; for each item the highest stamp across all devices wins, and deletions are kept as
/// tombstones so they spread instead of the item reappearing. A device joining for the first time stamps what it
/// already has at counter 0, so an existing library's settings win over a fresh install's defaults.
public struct SyncEngine: Sendable {
    public static let format = 1
    public static let base = "BetterWispr/v1/devices"
    /// Tombstones older than this are dropped. A device offline for longer could bring a deleted item back.
    public static let tombstoneLifetime: TimeInterval = 180 * 24 * 3600

    public let folder: any SyncFolder
    public let journalURL: URL
    public let deviceName: String
    public let platform: String

    public init(folder: any SyncFolder, journalURL: URL, deviceName: String, platform: String) {
        self.folder = folder
        self.journalURL = journalURL
        self.deviceName = deviceName
        self.platform = platform
    }

    private struct LibraryFile: Codable {
        var format: Int
        var device: String
        var counter: UInt64
        var records: [SyncRecord]
    }

    public func sync(_ local: SyncLibrary, now: Date = .now) throws -> SyncResult {
        let existing = try SyncJournal.load(from: journalURL)
        var journal = existing ?? SyncJournal()
        let me = journal.device

        // 1. Stamp local edits and deletions against the journal.
        let joining = existing == nil
        var counter = journal.counter
        var mine: [String: SyncRecord] = [:]
        let localItems = Dictionary(local.items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, item) in localItems {
            let hash = item.hash
            if let entry = journal.entries[key], !entry.deleted, entry.hash == hash {
                mine[key] = SyncRecord(kind: item.kind, id: item.id, stamp: entry.stamp, item: item)
            } else {
                if !joining { counter += 1 }
                mine[key] = SyncRecord(kind: item.kind, id: item.id, stamp: SyncStamp(counter: joining ? 0 : counter, device: me, time: now), item: item)
            }
        }
        let unreadable = Set(local.unreadableMeetings.map { "\(SyncKind.meeting.rawValue)/\($0.uuidString)" })
        for (key, entry) in journal.entries where localItems[key] == nil && !unreadable.contains(key) {
            guard let slash = key.firstIndex(of: "/"), let kind = SyncKind(rawValue: String(key[..<slash])) else { continue }
            let id = String(key[key.index(after: slash)...])
            if entry.deleted {
                mine[key] = SyncRecord(kind: kind, id: id, stamp: entry.stamp, item: nil)
            } else {
                counter += 1
                mine[key] = SyncRecord(kind: kind, id: id, stamp: SyncStamp(counter: counter, device: me, time: now), item: nil)
            }
        }

        // 2. Read every other device and keep the highest stamp per item.
        var winners = mine
        var devices: [SyncDevice] = []
        var pending = 0
        for device in try folder.list(Self.base) where device != me {
            let path = "\(Self.base)/\(device)"
            if let data = try folder.read("\(path)/device.json"), let info = try? JSONDecoder().decode(SyncDevice.self, from: data) {
                devices.append(info)
            }
            var records: [SyncRecord] = []
            if let data = try folder.read("\(path)/library.json") {
                let file = try JSONDecoder().decode(LibraryFile.self, from: data)
                guard file.format <= Self.format else { throw SyncError.newerFormat(device: devices.last?.name ?? device, format: file.format) }
                records += file.records
                counter = max(counter, file.counter)
            } else if try folder.list(path).contains("library.json") {
                pending += 1
            }
            for name in try folder.list("\(path)/meetings") where name.hasSuffix(".json") {
                if let data = try folder.read("\(path)/meetings/\(name)") {
                    if let record = try? JSONDecoder().decode(SyncRecord.self, from: data) { records.append(record) }
                } else {
                    pending += 1
                }
            }
            for record in records {
                counter = max(counter, record.stamp.counter)
                // A record this version can't read must not overwrite a readable one; it waits for this device to update.
                if !record.deleted, record.item == nil { continue }
                if let current = winners[record.key], current.stamp >= record.stamp {
                    // On its first sync this device yields everything it shares a key with, such as preferences,
                    // so an existing library's settings beat a fresh install's defaults even at equal counters.
                    guard joining, current.stamp.device == me else { continue }
                }
                winners[record.key] = record
            }
        }

        // 3. Apply what other devices changed.
        var library = local
        var workspaceChanged = false
        var updatedMeetings: [Meeting] = []
        var deletedMeetings: Set<UUID> = []
        var history = Dictionary(local.history.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        var vocabulary = Dictionary(local.vocabulary.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        var modes = Dictionary(local.settings.modes.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        var meetings = Dictionary(local.meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var preferences: SharedPreferences?
        for (key, record) in winners where record != mine[key] {
            let incoming = record.item
            guard incoming != localItems[key], let kind = SyncKind(rawValue: record.kind) else { continue }
            switch kind {
            case .transcript:
                history[record.id] = incoming == nil ? nil : record.transcript
                workspaceChanged = true
            case .vocabulary:
                vocabulary[record.id] = incoming == nil ? nil : record.vocabulary
                workspaceChanged = true
            case .mode:
                modes[record.id] = incoming == nil ? nil : record.mode
                workspaceChanged = true
            case .preferences:
                if incoming != nil { preferences = record.preferences }
            case .meeting:
                guard let id = UUID(uuidString: record.id), !local.unreadableMeetings.contains(id) else { continue }
                if incoming != nil, let value = record.meeting {
                    meetings[id] = value
                    updatedMeetings.append(value)
                } else if meetings.removeValue(forKey: id) != nil {
                    deletedMeetings.insert(id)
                }
            }
        }
        if workspaceChanged {
            library.history = history.values.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString < $1.id.uuidString }
            // Keep local order for entries this device already had; new ones follow in a stable order.
            let known = Set(local.vocabulary.map(\.id))
            library.vocabulary = local.vocabulary.compactMap { vocabulary[$0.id.uuidString] }
                + vocabulary.values.filter { !known.contains($0.id) }.sorted { $0.phrase.localizedCaseInsensitiveCompare($1.phrase) == .orderedAscending }
        }
        library.meetings = meetings.values.sorted { $0.createdAt > $1.createdAt }
        if let preferences, preferences != SharedPreferences(local.settings) {
            preferences.apply(to: &library.settings)
            workspaceChanged = true
        }
        let order = preferences?.modeOrder ?? local.settings.modes.map(\.id)
        let orderedModes = Self.ordered(Array(modes.values), by: order, previous: local.settings.modes)
        if orderedModes != local.settings.modes {
            library.settings.modes = orderedModes
            workspaceChanged = true
        }

        // 4. Write this device's view: every winning record, including tombstones still within their lifetime.
        let cutoff = now.addingTimeInterval(-Self.tombstoneLifetime)
        let kept = winners.values.filter { !$0.deleted || $0.stamp.time > cutoff }
        let base = "\(Self.base)/\(me)"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let libraryRecords = kept.filter { $0.kind != SyncKind.meeting.rawValue }.sorted { $0.key < $1.key }
        try writeIfChanged(encoder.encode(LibraryFile(format: Self.format, device: me, counter: counter, records: libraryRecords)),
                           to: "\(base)/library.json")
        let meetingRecords = kept.filter { $0.kind == SyncKind.meeting.rawValue }
        let meetingNames = Set(meetingRecords.map { "\($0.id).json" })
        for record in meetingRecords {
            try writeIfChanged(encoder.encode(record), to: "\(base)/meetings/\(record.id).json")
        }
        for name in try folder.list("\(base)/meetings") where !meetingNames.contains(name) {
            try folder.remove("\(base)/meetings/\(name)")
        }
        let info = SyncDevice(id: me, name: deviceName, platform: platform, lastSync: now)
        try folder.write(encoder.encode(info), to: "\(base)/device.json")

        journal.counter = counter
        // Hash payloads here rather than trusting the writer's hash, so the next comparison uses this device's own encoding.
        journal.entries = Dictionary(kept.map { ($0.key, SyncJournal.Entry(stamp: $0.stamp, hash: $0.item?.hash, deleted: $0.deleted)) },
                                     uniquingKeysWith: { first, _ in first })
        return SyncResult(library: library, workspaceChanged: workspaceChanged, updatedMeetings: updatedMeetings,
                          deletedMeetings: deletedMeetings, pendingDownloads: pending,
                          devices: devices.sorted { $0.lastSync > $1.lastSync }, journal: journal)
    }

    /// Records that the library in `result` is saved, so the next sync compares against it.
    public func commit(_ result: SyncResult) throws {
        try result.journal.save(to: journalURL)
    }

    /// The device ID this engine writes under, creating the journal's identity on first use.
    public func deviceID() throws -> String {
        if let journal = try SyncJournal.load(from: journalURL) { return journal.device }
        let journal = SyncJournal()
        try journal.save(to: journalURL)
        return journal.device
    }

    /// Removes this device's files from the folder, for "Stop syncing and remove this device". Local data is untouched.
    public func leave() throws {
        guard let journal = try SyncJournal.load(from: journalURL) else { return }
        let base = "\(Self.base)/\(journal.device)"
        for name in try folder.list("\(base)/meetings") { try folder.remove("\(base)/meetings/\(name)") }
        for name in ["library.json", "device.json"] { try folder.remove("\(base)/\(name)") }
        try? FileManager.default.removeItem(at: journalURL)
    }

    private func writeIfChanged(_ data: Data, to path: String) throws {
        if try folder.read(path) == data { return }
        try folder.write(data, to: path)
    }

    /// Orders modes by the synced order; modes it doesn't mention keep their previous relative order at the end.
    static func ordered(_ modes: [WritingMode], by order: [UUID], previous: [WritingMode]) -> [WritingMode] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let previousRank = Dictionary(previous.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return modes.sorted { lhs, rhs in
            switch (rank[lhs.id], rank[rhs.id]) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                let l = previousRank[lhs.id] ?? .max, r = previousRank[rhs.id] ?? .max
                return l != r ? l < r : lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }
}
