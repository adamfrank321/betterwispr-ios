import BetterWisprCore
import Foundation
import Observation

/// The phone's library and settings. Uses the same workspace format and stores as the Mac app, so sync and any
/// future tools read both the same way.
@MainActor @Observable
final class MobileModel {
    var settings = AppSettings()
    var history: [Transcript] = []
    var vocabulary: [VocabularyEntry] = []
    var meetings: [Meeting] = []
    private(set) var unreadableMeetings: Set<UUID> = []
    /// A short message for the toast at the bottom of the screen.
    var toast: Toast?
    private(set) var storageProblem: String?

    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let meetingStore: MeetingStore
    @ObservationIgnored let bridge = KeyboardBridge()
    @ObservationIgnored var onSaved: (@MainActor () -> Void)?
    @ObservationIgnored private var storageIsReadable = true

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        var title: String
        var message: String?
        var undo: (@MainActor () -> Void)?

        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }

    init(directory: URL? = nil) {
        store = LocalStore(directory: directory)
        meetingStore = MeetingStore(directory: store.directory.appending(path: "Meetings"))
        do {
            let state = try store.load()
            settings = state.settings
            history = state.history
            vocabulary = state.vocabulary
        } catch {
            storageIsReadable = false
            storageProblem = "Your saved library couldn't be read and was left untouched: \(error.localizedDescription)"
        }
        let loaded = meetingStore.load()
        meetings = loaded.meetings
        unreadableMeetings = Set(loaded.unreadable.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
        if !models.contains(where: { $0.id == settings.selectedModelID }) { settings.selectedModelID = "apple" }
        shareKeyboardSettings()
    }

    var models: [SpeechModel] { SpeechModel.catalog + settings.speechConnections.map(\.speechModel) }
    var selectedModel: SpeechModel { models.first { $0.id == settings.selectedModelID } ?? models[0] }

    // MARK: Saving

    func save() {
        do {
            try persist()
        } catch {
            toast = Toast(title: "Couldn't save", message: error.localizedDescription)
        }
    }

    private func persist(notifies: Bool = true) throws {
        guard storageIsReadable else {
            throw NSError(domain: "BetterWispr", code: 1, userInfo: [NSLocalizedDescriptionKey: "The saved library couldn't be read, so it won't be overwritten."])
        }
        var state = SavedState()
        state.settings = settings
        state.history = history
        state.vocabulary = vocabulary
        try store.save(state)
        shareKeyboardSettings()
        if notifies { onSaved?() }
    }

    private func shareKeyboardSettings() {
        bridge.sharesContext = settings.useScreenContext
        bridge.learnsCorrections = settings.learnCorrections
    }

    // MARK: History

    func add(_ transcript: Transcript) {
        guard settings.saveHistory else { return }
        history.insert(transcript, at: 0)
        save()
    }

    func updateTranscript(_ transcript: Transcript, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != transcript.text, let index = history.firstIndex(where: { $0.id == transcript.id }) else { return }
        history[index].text = text
        save()
        if settings.learnCorrections { learn(from: transcript.text, to: text) }
    }

    func restoreOriginal(_ transcript: Transcript) {
        let original = transcript.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, let index = history.firstIndex(where: { $0.id == transcript.id }) else { return }
        history[index].text = original
        save()
    }

    func delete(_ transcript: Transcript) {
        history.removeAll { $0.id == transcript.id }
        save()
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    // MARK: Vocabulary

    @discardableResult
    func addVocabulary(phrase: String, replacement: String) -> String? {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, phrase.count <= 100, replacement.count <= 100 else { return "Use a phrase and spelling of at most 100 characters." }
        guard vocabulary.count < 200 else { return "Keep your vocabulary to 200 entries for focused hints." }
        guard !vocabulary.contains(where: { $0.phrase.caseInsensitiveCompare(phrase) == .orderedSame }) else { return "That phrase is already in your vocabulary." }
        vocabulary.append(VocabularyEntry(phrase: phrase, replacement: replacement))
        save()
        return nil
    }

    func deleteVocabulary(_ entry: VocabularyEntry) {
        vocabulary.removeAll { $0.id == entry.id }
        save()
    }

    // MARK: Learning from corrections, as on the Mac

    func learn(from original: String, to edited: String) {
        let candidates = CorrectionLearner.corrections(from: original, to: edited)
        guard !candidates.isEmpty else { return }
        let settings = settings
        Task { [weak self] in
            let reviewed = await CorrectionReviewer.review(candidates, from: original, to: edited, settings: settings)
            self?.learn(reviewed ?? candidates.map { .replacementAndVocabulary(heard: $0.heard, corrected: $0.corrected) })
        }
    }

    private func learn(_ decisions: [CorrectionDecision]) {
        guard settings.learnCorrections else { return }
        let added = CorrectionDecision.entries(for: decisions, in: vocabulary)
        guard !added.isEmpty else { return }
        vocabulary += added
        save()
        let ids = Set(added.map(\.id))
        toast = Toast(title: "Learned " + added.map { "“\($0.replacement.isEmpty ? $0.phrase : $0.replacement)”" }.joined(separator: ", "),
                      message: "BetterWispr will spell it this way next time.") { [weak self] in
            self?.vocabulary.removeAll { ids.contains($0.id) }
            self?.save()
        }
    }

    /// Learns from fixes the user made in the keyboard's text field.
    func learnKeyboardCorrections() {
        for correction in bridge.takeCorrections() where settings.learnCorrections {
            learn(from: correction.original, to: correction.edited)
        }
    }

    // MARK: Meetings

    func save(_ meeting: Meeting) {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[index] = meeting } else { meetings.insert(meeting, at: 0) }
        do {
            try meetingStore.save(meeting)
            onSaved?()
        } catch {
            toast = Toast(title: "Couldn't save the meeting", message: error.localizedDescription)
        }
    }

    func delete(_ meeting: Meeting) {
        do {
            try meetingStore.delete(id: meeting.id)
            meetings.removeAll { $0.id == meeting.id }
            onSaved?()
        } catch {
            toast = Toast(title: "Couldn't delete the meeting", message: error.localizedDescription)
        }
    }

    // MARK: Sync

    var syncLibrary: SyncLibrary {
        SyncLibrary(settings: settings, history: history, vocabulary: vocabulary, meetings: meetings, unreadableMeetings: unreadableMeetings)
    }

    /// Takes in what other devices changed; throws when saving fails so the sync isn't recorded as done.
    func adoptSynced(_ result: SyncResult, skipping activeMeeting: UUID? = nil) throws {
        if result.workspaceChanged {
            let previous = (settings, history, vocabulary)
            settings = result.library.settings
            history = result.library.history
            vocabulary = result.library.vocabulary
            do { try persist(notifies: false) } catch {
                (settings, history, vocabulary) = previous
                throw error
            }
        }
        for meeting in result.updatedMeetings where meeting.id != activeMeeting {
            try meetingStore.save(meeting)
            if let index = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[index] = meeting } else { meetings.append(meeting) }
        }
        for id in result.deletedMeetings where id != activeMeeting {
            try meetingStore.delete(id: id)
            meetings.removeAll { $0.id == id }
        }
        meetings.sort { $0.createdAt > $1.createdAt }
    }
}
