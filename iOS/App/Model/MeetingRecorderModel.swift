import BetterWisprCore
import Foundation
import Observation

/// Records a meeting through the phone's microphone, transcribes it in short pieces while it runs, then (when the
/// speaker detection models are installed) tells the voices apart and writes notes with the chosen notes model.
/// iOS can't record other apps' audio, so everything is room audio: lines are labelled Speaker 1, 2… once voices are found.
@MainActor @Observable
final class MeetingRecorderModel {
    enum Activity: Equatable {
        case idle
        case recording(UUID)
        case finishing(UUID)
        case findingSpeakers(UUID)
        case writingNotes(UUID)
    }

    private(set) var activity: Activity = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Float = 0
    private(set) var pendingPieces = 0
    var message: String?
    private(set) var speakerDetectionInstalled = SpeakerDetection.isInstalled()
    private(set) var installingSpeakerDetection: Double?

    @ObservationIgnored private let model: MobileModel
    @ObservationIgnored private let models: ModelManager
    @ObservationIgnored private let capture = AudioCapture()
    @ObservationIgnored private var provider: (any SpeechProvider)?
    @ObservationIgnored private var voices: SpeakerRecording?
    @ObservationIgnored private var queue: [(url: URL, start: TimeInterval, duration: TimeInterval)] = []
    @ObservationIgnored private var drain: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var pieceStart: TimeInterval = 0
    @ObservationIgnored private var quietSince: TimeInterval?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var language: String?
    @ObservationIgnored private var vocabulary: [VocabularyEntry] = []

    /// Pieces end at a pause after `minimum` seconds, or at `maximum`, like the Mac notetaker's 3 to 20 second chunks.
    private let policy = ChunkPolicy(minimum: 4, maximum: 20, pause: 0.6)

    init(model: MobileModel, models: ModelManager) {
        self.model = model
        self.models = models
        capture.onLevel = { [weak self] level in self?.receive(level) }
        capture.onInterrupted = { [weak self] in
            self?.message = "Recording stopped because another app or a call took the microphone."
            self?.stop()
        }
    }

    var activeMeetingID: UUID? {
        switch activity {
        case .idle: nil
        case .recording(let id), .finishing(let id), .findingSpeakers(let id), .writingNotes(let id): id
        }
    }

    var isRecording: Bool { if case .recording = activity { true } else { false } }

    func start() async {
        guard activity == .idle else { return }
        guard await AudioCapture.requestPermission() else {
            message = "Allow Microphone access for BetterWispr in Settings."
            return
        }
        let selected = model.selectedModel
        language = model.settings.language == "auto" ? nil : model.settings.language
        vocabulary = model.vocabulary
        let meeting = Meeting(modelName: selected.name, language: language ?? "auto")
        model.save(meeting)
        voices?.discard()
        voices = SpeakerDetection.isReady ? try? SpeakerRecording() : nil
        do {
            try capture.beginRecording()
        } catch {
            message = error.localizedDescription
            return
        }
        activity = .recording(meeting.id)
        startedAt = .now
        elapsed = 0
        pieceStart = 0
        quietSince = nil
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        }
        // Recording starts first so no words are lost while the model loads; pieces wait in the queue until it's ready.
        let models = models, language = language
        Task { [weak self] in
            do {
                let provider = try await models.provider(for: selected, language: language)
                self?.provider = provider
                self?.drainQueue(meeting.id)
            } catch {
                self?.message = "The speech model couldn't load: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        guard case .recording(let id) = activity else { return }
        ticker?.cancel()
        rotate(final: true)
        capture.stopEngine()
        level = 0
        activity = .finishing(id)
        Task { [weak self] in
            await self?.drain?.value
            guard let self else { return }
            if let voices = self.voices, let provider = self.provider {
                self.voices = nil
                await self.findSpeakers(in: id, voices: voices, provider: provider)
            }
            if let meeting = self.model.meetings.first(where: { $0.id == id }) {
                var finished = meeting
                finished.duration = self.elapsed
                self.model.save(finished)
                if MeetingNotesGenerator.availability(settings: self.model.settings) == .available, finished.hasContent {
                    await self.writeNotes(for: id)
                }
            }
            self.activity = .idle
        }
    }

    func writeNotes(for id: UUID) async {
        guard let meeting = model.meetings.first(where: { $0.id == id }) else { return }
        let previous = activity
        activity = .writingNotes(id)
        defer { activity = previous == .writingNotes(id) ? .idle : previous }
        do {
            let notes = try await MeetingNotesGenerator.generate(segments: meeting.segments, names: meeting.participantNames,
                                                                 userNotes: meeting.notes, settings: model.settings) { _, _ in }
            guard var latest = model.meetings.first(where: { $0.id == id }) else { return }
            latest.summary = notes.summary
            if latest.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { latest.title = notes.title }
            model.save(latest)
        } catch {
            message = error.localizedDescription
        }
    }

    func installSpeakerDetection() {
        guard installingSpeakerDetection == nil else { return }
        installingSpeakerDetection = 0
        Task { [weak self] in
            do {
                try await SpeakerDetection.install { value in
                    Task { @MainActor in self?.installingSpeakerDetection = value }
                }
                self?.speakerDetectionInstalled = SpeakerDetection.isInstalled()
            } catch {
                self?.message = error.localizedDescription
            }
            self?.installingSpeakerDetection = nil
        }
    }

    // MARK: Pieces

    private func tick() {
        guard isRecording else { return }
        elapsed = Date.now.timeIntervalSince(startedAt)
        let duration = elapsed - pieceStart
        let silence = quietSince.map { elapsed - $0 } ?? 0
        if policy.shouldRotate(duration: duration, trailingSilence: silence) { rotate(final: false) }
    }

    private func receive(_ level: Float) {
        self.level = level
        guard isRecording else { return }
        if level < 0.05 { quietSince = quietSince ?? elapsed } else { quietSince = nil }
    }

    private func rotate(final: Bool) {
        guard case .recording(let id) = activity, let piece = try? capture.finishRecording() else { return }
        let start = pieceStart
        pieceStart = elapsed
        quietSince = nil
        if !final {
            do { try capture.beginRecording() } catch { message = "Recording stopped: \(error.localizedDescription)" }
        }
        guard piece.hasSpeech else {
            try? FileManager.default.removeItem(at: piece.url)
            return
        }
        queue.append((piece.url, start, piece.duration))
        pendingPieces = queue.count
        drainQueue(id)
    }

    private func drainQueue(_ id: UUID) {
        guard drain == nil, let provider else { return }
        drain = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let piece = self.queue.removeFirst()
                defer { self.pendingPieces = self.queue.count }
                do {
                    let raw = try await provider.transcribe(audioURL: piece.url, language: self.language,
                                                            vocabulary: VocabularyProcessor.hints(self.vocabulary))
                    let text = VocabularyProcessor.apply(self.vocabulary, to: TranscriptCleaner.clean(raw, language: self.language))
                    if !text.isEmpty, var meeting = self.model.meetings.first(where: { $0.id == id }) {
                        let segment = MeetingSegment(speaker: .them, start: piece.start, duration: piece.duration, text: text, rawText: raw)
                        meeting.insert(segment)
                        self.model.save(meeting)
                        if let voices = self.voices { try? await voices.append(piece.url, for: segment.id) }
                    }
                } catch {
                    self.message = "A few seconds couldn't be transcribed. \(error.localizedDescription)"
                }
                try? FileManager.default.removeItem(at: piece.url)
            }
            self?.drain = nil
        }
    }

    private func findSpeakers(in id: UUID, voices: SpeakerRecording, provider: any SpeechProvider) async {
        defer { voices.discard() }
        activity = .findingSpeakers(id)
        guard let meeting = model.meetings.first(where: { $0.id == id }) else { return }
        let language = language, vocabulary = vocabulary
        do {
            let labelled = try await SpeakerDetection.label(meeting.segments, voices: voices) { audio, start, duration in
                let raw = try await provider.transcribe(audioURL: audio, language: language, vocabulary: VocabularyProcessor.hints(vocabulary))
                let text = VocabularyProcessor.apply(vocabulary, to: TranscriptCleaner.clean(raw, language: language))
                return text.isEmpty ? nil : MeetingSegment(speaker: .them, start: start, duration: duration, text: text, rawText: raw)
            }
            guard var latest = model.meetings.first(where: { $0.id == id }) else { return }
            latest.segments = labelled
            model.save(latest)
        } catch {
            message = "Couldn't tell the speakers apart. \(error.localizedDescription)"
        }
    }
}
