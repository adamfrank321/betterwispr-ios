import Foundation

/// The text a dictation delivers, with the settings it was written under.
public struct ProcessedDictation: Equatable, Sendable {
    public var text: String
    /// Words respelled by Vocabulary after recognition; add the provider's own fixes for Insights.
    public var vocabularyFixes: Int
    /// The settings after any writing mode, which decide saving, delivery and correction learning.
    public var settings: AppSettings
    public var mode: WritingMode?
}

/// Turns recognized speech into the text a dictation delivers, in the fixed order described in docs/architecture.md:
/// cleanup, trigger words, misheard voice commands, voice commands, spoken numbers and symbols, spoken email layout
/// or the Medium edit, the writing tone, then Vocabulary. Shared by the Mac and iOS apps so both write the same text.
public enum DictationProcessor {
    /// - Parameters:
    ///   - language: nil for automatic detection.
    ///   - mode: the writing mode chosen before recording (from the app or website on the Mac); a spoken trigger word replaces it.
    ///   - style: the kind of app the text is for, which picks the writing tone.
    ///   - context: screen context captured for the starting mode; cancelled here when the effective settings don't share it.
    ///   - onEditing: called with a status line before a Medium edit starts.
    @MainActor
    public static func process(
        _ raw: String, language: String?, settings: AppSettings, vocabulary entries: [VocabularyEntry],
        startedIn mode: WritingMode?, style: StyleContext, context: Task<DictationContext, Never>? = nil,
        onEditing: (@MainActor (String) -> Void)? = nil
    ) async throws -> ProcessedDictation {
        let lightlyCleaned = TranscriptCleaner.clean(raw, language: language)
        let trigger = settings.modes.match(transcript: lightlyCleaned)
        let effectiveMode = trigger?.mode ?? mode
        let writingSettings = settings.applying(effectiveMode)
        let cleanup = writingSettings.cleanup
        let tone = writingSettings.tone(for: style)
        let base = cleanup == .none ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : lightlyCleaned
        let cleaned = trigger.flatMap { [$0.mode].match(transcript: base)?.transcript } ?? base
        let sharesContext = settings.sharesContext(startedIn: mode, trigger: trigger?.mode)
        if !sharesContext { context?.cancel() }
        let heard = VocabularyProcessor.correctedCommands(entries, in: cleaned)
        var spoken = language == nil || language?.hasPrefix("en") == true ? VoiceCommands.apply(heard.text) : heard.text
        let english = TranscriptCleaner.isEnglish(spoken, language: language)
        if english, let email = EmailDictation.compose(spoken) {
            spoken = email
        } else if english, cleanup == .medium, MeetingNotesGenerator.availability(settings: writingSettings) == .available {
            onEditing?("Editing with \(writingSettings.notesModelName)…")
            let polished = await TranscriptPolisher.polish(spoken, settings: writingSettings, vocabulary: VocabularyProcessor.hints(entries),
                                                           context: sharesContext ? await context?.value(within: .seconds(1)) : nil,
                                                           instructions: effectiveMode?.instructions ?? "")
            try Task.checkCancellation()
            spoken = StyleFormatter.apply(tone, to: polished ?? spoken)
        } else if english {
            spoken = StyleFormatter.apply(tone, to: spoken)
        }
        let (text, fixes) = VocabularyProcessor.corrected(entries, in: spoken)
        return ProcessedDictation(text: text, vocabularyFixes: fixes + heard.fixes, settings: writingSettings, mode: effectiveMode)
    }
}
