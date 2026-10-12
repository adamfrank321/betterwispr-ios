import BetterWisprCore
import Foundation
import Observation
import UIKit

/// Records, recognizes and cleans up one dictation at a time, for the app's own dictate button and for the keyboard.
///
/// Keyboard dictations run in a warm session: the microphone stays open in the background for a few minutes after
/// the keyboard last asked for it, so the keyboard can start and stop recordings without bringing the app forward.
@MainActor @Observable
final class DictationSession {
    enum Phase: Equatable {
        case idle, recording, transcribing
        case done(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var level: Float = 0
    private(set) var status = ""
    private(set) var sessionEnds: Date?
    private(set) var fromKeyboard = false

    /// How long the microphone stays open for the keyboard after its last dictation.
    static let warmDuration: TimeInterval = 5 * 60

    @ObservationIgnored private let model: MobileModel
    @ObservationIgnored private let models: ModelManager
    @ObservationIgnored private let capture = AudioCapture()
    @ObservationIgnored private let bridge = KeyboardBridge()
    @ObservationIgnored private var commandObserver: DarwinObserver?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var warmTimer: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var style: StyleContext = .other
    @ObservationIgnored private var keyboardContext: String?
    @ObservationIgnored private var levelSharedAt = Date.distantPast

    init(model: MobileModel, models: ModelManager) {
        self.model = model
        self.models = models
        capture.onLevel = { [weak self] level in self?.receive(level) }
        // Transcribe what was said before a call or another app took the microphone.
        capture.onInterrupted = { [weak self] in
            self?.stop()
            self?.sessionEnds = nil
        }
        commandObserver = DarwinObserver(KeyboardBridge.commandSent) { [weak self] in self?.handleKeyboardCommand() }
        // A session from before the app was last closed is gone; tell the keyboard.
        bridge.update { $0.phase = .idle; $0.sessionEnds = nil; $0.level = 0 }
    }

    var isBusy: Bool { phase == .recording || phase == .transcribing }
    var isWarm: Bool { sessionEnds.map { $0 > .now } ?? false }

    // MARK: Keyboard

    /// Picks up the keyboard's latest request; called when the keyboard nudges and when the app opens from its link.
    func handleKeyboardCommand() {
        guard let command = bridge.pendingCommand() else { return }
        bridge.markHandled(command)
        let style = StyleContext(rawValue: command.style) ?? .other
        switch command.kind {
        case .start: start(fromKeyboard: true, style: style, context: command.context)
        case .stop: stop()
        case .cancel: cancel()
        }
    }

    // MARK: Dictation

    func start(fromKeyboard: Bool = false, style: StyleContext = .other, context: String? = nil) {
        guard !isBusy else { return }
        generation = UUID()
        let token = generation
        self.fromKeyboard = fromKeyboard
        self.style = style
        keyboardContext = context
        phase = .recording
        status = "Listening…"
        operation = Task { [weak self] in
            guard await AudioCapture.requestPermission() else {
                self?.fail("Allow Microphone access for BetterWispr in Settings.", token: token)
                return
            }
            guard let self, self.generation == token else { return }
            do {
                try self.capture.beginRecording()
                if fromKeyboard { self.extendWarmSession() }
                self.bridge.update { $0.phase = .recording; $0.message = nil; $0.sessionEnds = self.sessionEnds }
                self.models.warmUp(self.model.selectedModel)
            } catch {
                self.fail(error.localizedDescription, token: token)
            }
        }
    }

    func toggle() {
        if phase == .recording { stop() } else if !isBusy { start() }
    }

    func stop() {
        guard phase == .recording, capture.isRecording else { return }
        let token = generation
        do {
            let audio = try capture.finishRecording()
            if !fromKeyboard && !isWarm { capture.stopEngine() }
            transcribe(audio, token: token)
        } catch {
            fail(error.localizedDescription, token: token)
        }
    }

    func cancel() {
        generation = UUID()
        operation?.cancel()
        capture.discardRecording()
        if !isWarm { capture.stopEngine() }
        phase = .idle
        status = ""
        level = 0
        bridge.update { $0.phase = isWarm ? .ready : .idle; $0.level = 0; $0.message = nil }
    }

    /// Ends the warm session now, closing the microphone.
    func endSession() {
        warmTimer?.cancel()
        sessionEnds = nil
        if !isBusy { capture.stopEngine() }
        bridge.update { $0.phase = .idle; $0.sessionEnds = nil; $0.level = 0 }
    }

    private func transcribe(_ audio: (url: URL, duration: TimeInterval, hasSpeech: Bool), token: UUID) {
        phase = .transcribing
        level = 0
        let selected = model.selectedModel
        status = selected.engine == .api ? "Transcribing with \(selected.name)…" : "Transcribing on this iPhone…"
        bridge.update { $0.phase = .transcribing; $0.level = 0 }
        let settings = model.settings
        let entries = model.vocabulary
        let language = settings.language == "auto" ? nil : settings.language
        let style = style
        let fromKeyboard = fromKeyboard
        let context: Task<DictationContext, Never>? = fromKeyboard && settings.useScreenContext
            ? keyboardContext.map { text in Task { DictationContext(window: text) } } : nil
        operation = Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: audio.url) }
            guard let self else { return }
            guard audio.hasSpeech else { self.fail("No speech heard. Move closer to the microphone and try again.", token: token); return }
            do {
                let provider = try await self.models.provider(for: selected, language: language)
                guard self.generation == token else { return }
                let raw = try await provider.transcribe(audioURL: audio.url, language: language, vocabulary: VocabularyProcessor.hints(entries))
                guard self.generation == token else { return }
                let processed = try await DictationProcessor.process(
                    raw, language: language, settings: settings, vocabulary: entries, startedIn: nil, style: style,
                    context: context, onEditing: { [weak self] in self?.status = $0 })
                guard self.generation == token else { return }
                guard !processed.text.isEmpty else { self.fail("No speech heard. Move closer to the microphone and try again.", token: token); return }
                let transcript = Transcript(text: processed.text, rawText: raw, duration: audio.duration, modelName: selected.name,
                                            language: language ?? "auto", vocabularyFixes: processed.vocabularyFixes + provider.vocabularyFixes)
                if processed.settings.saveHistory { self.model.add(transcript) }
                self.finish(processed.text, fromKeyboard: fromKeyboard)
            } catch {
                guard self.generation == token else { return }
                self.fail(error.localizedDescription, token: token)
            }
        }
    }

    private func finish(_ text: String, fromKeyboard: Bool) {
        phase = .done(text)
        status = ""
        if fromKeyboard {
            extendWarmSession()
            bridge.update {
                $0.phase = .ready
                $0.resultID = UUID()
                $0.result = text
                $0.resultAt = .now
                $0.message = nil
                $0.sessionEnds = sessionEnds
            }
        } else {
            UIPasteboard.general.string = text
        }
    }

    private func fail(_ message: String, token: UUID) {
        guard generation == token else { return }
        capture.discardRecording()
        if !isWarm { capture.stopEngine() }
        phase = .failed(message)
        status = ""
        level = 0
        bridge.update { $0.phase = .failed; $0.message = message; $0.level = 0 }
    }

    private func extendWarmSession() {
        sessionEnds = Date.now.addingTimeInterval(Self.warmDuration)
        warmTimer?.cancel()
        warmTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.warmDuration))
            guard let self, !Task.isCancelled else { return }
            if self.isBusy { self.extendWarmSession() } else { self.endSession() }
        }
    }

    private func receive(_ level: Float) {
        guard phase == .recording else { return }
        self.level = level
        // The keyboard redraws its button from shared defaults; a few updates a second is plenty.
        if fromKeyboard, Date.now.timeIntervalSince(levelSharedAt) > 0.2 {
            levelSharedAt = .now
            bridge.update { $0.level = level }
        }
    }
}
