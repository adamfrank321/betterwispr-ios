import CryptoKit
import Foundation

/// Orders edits across devices: a Lamport counter, then the device ID to break ties. Wall time is kept for display and tombstone expiry only.
public struct SyncStamp: Codable, Hashable, Comparable, Sendable {
    public var counter: UInt64
    public var device: String
    public var time: Date

    public init(counter: UInt64, device: String, time: Date) {
        self.counter = counter
        self.device = device
        self.time = time
    }

    public static func < (lhs: SyncStamp, rhs: SyncStamp) -> Bool {
        lhs.counter != rhs.counter ? lhs.counter < rhs.counter : lhs.device < rhs.device
    }
}

public enum SyncKind: String, Codable, CaseIterable, Sendable {
    case transcript, vocabulary, mode, preferences, meeting
}

/// Settings that follow the user between devices. Speech model, microphone, shortcut, keys and other per-device choices stay local.
public struct SharedPreferences: Codable, Equatable, Sendable {
    public var language: String
    public var cleanup: CleanupLevel
    public var styles: [StyleContext: StyleTone]
    public var learnCorrections: Bool
    public var saveHistory: Bool
    public var theme: AppTheme
    /// The order modes are checked in; modes missing here keep their relative order after these.
    public var modeOrder: [UUID]

    public init(_ settings: AppSettings) {
        language = settings.language
        cleanup = settings.cleanup
        styles = settings.styles
        learnCorrections = settings.learnCorrections
        saveHistory = settings.saveHistory
        theme = settings.theme
        modeOrder = settings.modes.map(\.id)
    }

    public func apply(to settings: inout AppSettings) {
        settings.language = language
        settings.cleanup = cleanup
        settings.styles = styles
        settings.learnCorrections = learnCorrections
        settings.saveHistory = saveHistory
        settings.theme = theme
    }

    /// Unknown values from a newer version fall back to the defaults instead of failing the whole library.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        language = (try? container.decode(String.self, forKey: .language)) ?? defaults.language
        cleanup = (try? container.decode(CleanupLevel.self, forKey: .cleanup)) ?? defaults.cleanup
        styles = (try? container.decode([StyleContext: StyleTone].self, forKey: .styles)) ?? defaults.styles
        learnCorrections = (try? container.decode(Bool.self, forKey: .learnCorrections)) ?? defaults.learnCorrections
        saveHistory = (try? container.decode(Bool.self, forKey: .saveHistory)) ?? defaults.saveHistory
        theme = (try? container.decode(AppTheme.self, forKey: .theme)) ?? defaults.theme
        modeOrder = (try? container.decode([UUID].self, forKey: .modeOrder)) ?? []
    }
}

/// One synced item, or a tombstone when `deleted` is true. Exactly one payload matches `kind` for a live record.
public struct SyncRecord: Codable, Equatable, Sendable {
    public var kind: String
    public var id: String
    public var stamp: SyncStamp
    public var deleted: Bool
    /// SHA-256 of the payload's canonical JSON, so a device can tell an unchanged item from an edit without comparing payloads.
    public var hash: String?
    public var transcript: Transcript?
    public var vocabulary: VocabularyEntry?
    public var mode: WritingMode?
    public var preferences: SharedPreferences?
    public var meeting: Meeting?

    public var key: String { "\(kind)/\(id)" }

    init(kind: SyncKind, id: String, stamp: SyncStamp, item: SyncItem?) {
        self.kind = kind.rawValue
        self.id = id
        self.stamp = stamp
        deleted = item == nil
        hash = item?.hash
        switch item?.payload {
        case .transcript(let value): transcript = value
        case .vocabulary(let value): vocabulary = value
        case .mode(let value): mode = value
        case .preferences(let value): preferences = value
        case .meeting(let value): meeting = value
        case nil: break
        }
    }

    /// The payload, or nil for a tombstone, an unknown kind, or a record whose payload a newer version wrote in a shape this one can't read.
    var item: SyncItem? {
        guard !deleted, let kind = SyncKind(rawValue: kind) else { return nil }
        let payload: SyncPayload? = switch kind {
        case .transcript: transcript.map(SyncPayload.transcript)
        case .vocabulary: vocabulary.map(SyncPayload.vocabulary)
        case .mode: mode.map(SyncPayload.mode)
        case .preferences: preferences.map(SyncPayload.preferences)
        case .meeting: meeting.map(SyncPayload.meeting)
        }
        return payload.map { SyncItem(kind: kind, id: id, payload: $0) }
    }

    /// Payload fields that fail to decode leave the record readable as metadata, so one bad item never blocks a device's library.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        id = try container.decode(String.self, forKey: .id)
        stamp = try container.decode(SyncStamp.self, forKey: .stamp)
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        hash = try? container.decodeIfPresent(String.self, forKey: .hash)
        transcript = try? container.decodeIfPresent(Transcript.self, forKey: .transcript)
        vocabulary = try? container.decodeIfPresent(VocabularyEntry.self, forKey: .vocabulary)
        mode = try? container.decodeIfPresent(WritingMode.self, forKey: .mode)
        preferences = try? container.decodeIfPresent(SharedPreferences.self, forKey: .preferences)
        meeting = try? container.decodeIfPresent(Meeting.self, forKey: .meeting)
    }
}

enum SyncPayload: Equatable, Sendable {
    case transcript(Transcript)
    case vocabulary(VocabularyEntry)
    case mode(WritingMode)
    case preferences(SharedPreferences)
    case meeting(Meeting)
}

struct SyncItem: Equatable, Sendable {
    var kind: SyncKind
    var id: String
    var payload: SyncPayload
    var key: String { "\(kind.rawValue)/\(id)" }

    var hash: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data? = switch payload {
        case .transcript(let value): try? encoder.encode(value)
        case .vocabulary(let value): try? encoder.encode(value)
        case .mode(let value): try? encoder.encode(value)
        case .preferences(let value): try? encoder.encode(value)
        case .meeting(let value): try? encoder.encode(value)
        }
        return SyncHash.sha256(data ?? Data())
    }
}

/// Everything one device knows that syncs: its workspace plus its saved meetings.
public struct SyncLibrary: Equatable, Sendable {
    public var settings: AppSettings
    public var history: [Transcript]
    public var vocabulary: [VocabularyEntry]
    public var meetings: [Meeting]
    /// Meeting files this device couldn't read. Sync never treats them as deleted.
    public var unreadableMeetings: Set<UUID>

    public init(settings: AppSettings = AppSettings(), history: [Transcript] = [], vocabulary: [VocabularyEntry] = [],
                meetings: [Meeting] = [], unreadableMeetings: Set<UUID> = []) {
        self.settings = settings
        self.history = history
        self.vocabulary = vocabulary
        self.meetings = meetings
        self.unreadableMeetings = unreadableMeetings
    }

    public init(_ state: SavedState, meetings: [Meeting] = [], unreadableMeetings: Set<UUID> = []) {
        self.init(settings: state.settings, history: state.history, vocabulary: state.vocabulary,
                  meetings: meetings, unreadableMeetings: unreadableMeetings)
    }

    public var savedState: SavedState {
        var state = SavedState()
        state.settings = settings
        state.history = history
        state.vocabulary = vocabulary
        return state
    }

    var items: [SyncItem] {
        history.map { SyncItem(kind: .transcript, id: $0.id.uuidString, payload: .transcript($0)) }
            + vocabulary.map { SyncItem(kind: .vocabulary, id: $0.id.uuidString, payload: .vocabulary($0)) }
            + settings.modes.map { SyncItem(kind: .mode, id: $0.id.uuidString, payload: .mode($0)) }
            + [SyncItem(kind: .preferences, id: "shared", payload: .preferences(SharedPreferences(settings)))]
            + meetings.map { SyncItem(kind: .meeting, id: $0.id.uuidString, payload: .meeting($0)) }
    }
}

/// A device that has written to the sync folder.
public struct SyncDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var platform: String
    public var lastSync: Date

    public init(id: String, name: String, platform: String, lastSync: Date) {
        self.id = id
        self.name = name
        self.platform = platform
        self.lastSync = lastSync
    }
}

enum SyncHash {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
