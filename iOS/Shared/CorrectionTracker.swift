import Foundation

/// Follows the field after a dictation is inserted and reports the user's fix once they stop editing it.
struct CorrectionTracker {
    private var inserted: String?
    private var prefix = ""
    private var suffix = ""
    private var latest: String?
    private var started = Date.distantPast
    static let window: TimeInterval = 30

    var isExpired: Bool { inserted != nil && Date.now.timeIntervalSince(started) > Self.window }

    mutating func start(inserted text: String, prefix: String, suffix: String) {
        inserted = text
        self.prefix = prefix
        self.suffix = suffix
        latest = nil
        started = .now
    }

    /// Reads the dictated span back out of the text around the cursor, when the text before and after it is unchanged.
    mutating func observe(before: String?, after: String?) {
        guard inserted != nil, !isExpired else { return }
        let whole = (before ?? "") + (after ?? "")
        // The keyboard sees only a window of text around the cursor; match on what fits in it.
        let head = String(prefix.suffix(200)), tail = String(suffix.prefix(200))
        guard let start = whole.range(of: head, options: .backwards)?.upperBound ?? (head.isEmpty ? whole.startIndex : nil) else { return }
        let rest = whole[start...]
        guard tail.isEmpty || rest.hasSuffix(tail) else { return }
        let span = rest.dropLast(tail.count).trimmingCharacters(in: .whitespacesAndNewlines)
        latest = span.isEmpty ? nil : span
    }

    /// The correction to learn, if the user changed the dictated text; stops tracking either way.
    mutating func finish() -> BridgeCorrection? {
        defer { inserted = nil; latest = nil }
        guard let inserted, let latest, latest != inserted.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // A rewrite much longer or shorter than the dictation is new writing, not a fix.
        guard latest.count <= inserted.count * 2 + 20, latest.count * 2 + 20 >= inserted.count else { return nil }
        return BridgeCorrection(original: inserted, edited: latest)
    }
}
