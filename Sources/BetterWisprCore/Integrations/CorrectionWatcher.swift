#if os(macOS)
import AppKit
import ApplicationServices
import Carbon

/// Watches the field that received a dictation and reports how the user edits the dictated text there.
@MainActor
public final class CorrectionWatcher {
    private var task: Task<Void, Never>?

    public init() {}

    public func watch(_ inserted: String, in app: NSRunningApplication, onEdit: @escaping @MainActor (_ original: String, _ edited: String) -> Void) {
        stop()
        let inserted = Self.comparable(inserted)
        guard AXIsProcessTrusted(), !inserted.isEmpty else { return }
        let pid = app.processIdentifier
        task = Task { [weak self] in
            guard let field = await Self.focusedField(pid: pid) else { return }
            var inserted = inserted
            var baseline: String?
            var settled = SettledText("")
            for _ in 0..<60 {
                guard !Task.isCancelled, !IsSecureEventInputEnabled(), let raw = Self.value(of: field), raw.count <= 100_000 else { break }
                let value = Self.comparable(raw)
                if let base = baseline {
                    if let text = settled.observe(value), text != base, let edited = Self.edit(of: inserted, from: base, to: text) {
                        if edited != inserted { onEdit(inserted, edited) }
                        inserted = edited
                        baseline = text
                    }
                    if value.isEmpty { break }
                } else if value.contains(inserted) {
                    baseline = value
                    settled = SettledText(value)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if self?.task?.isCancelled == false { self?.task = nil }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Returns the inserted text as edited, found between the 16 characters on each side of it; nil unless each side appears exactly once.
    nonisolated static func edit(of inserted: String, from before: String, to after: String) -> String? {
        guard let range = before.range(of: inserted, options: .backwards) else { return nil }
        let left = String(before[..<range.lowerBound].suffix(16)), right = String(before[range.upperBound...].prefix(16))
        var start = after.startIndex, end = after.endIndex
        if !left.isEmpty {
            guard let anchor = uniqueRange(of: left, in: after) else { return nil }
            start = anchor.upperBound
        }
        if !right.isEmpty {
            guard let anchor = uniqueRange(of: right, in: after), anchor.lowerBound >= start else { return nil }
            end = anchor.lowerBound
        }
        return String(after[start..<end])
    }

    private nonisolated static func uniqueRange(of anchor: String, in text: String) -> Range<String.Index>? {
        guard let first = text.range(of: anchor, options: .literal),
              text.range(of: anchor, options: .literal, range: text.index(after: first.lowerBound)..<text.endIndex) == nil else { return nil }
        return first
    }

    /// Evens out the line endings, non-breaking and zero-width spaces and blank lines that web fields expose differently from what was pasted.
    nonisolated static func comparable(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "" : String($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }

    /// Electron apps expose their text fields only after an assistive app sets AXManualAccessibility, which takes a moment.
    private static func focusedField(pid: pid_t) async -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        for attempt in 0..<10 {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return nil }
            if let field = app.element(kAXFocusedUIElementAttribute) {
                if field.isSecureField { return nil }
                if value(of: field) != nil { return field }
            }
            if attempt == 0 { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
        }
        return nil
    }

    private static func value(of field: AXUIElement) -> String? { field.string(kAXValueAttribute) }
}

/// Decides when text in a field polled every half second is final enough to learn from.
struct SettledText {
    private var last: String
    private var polls = 1

    init(_ value: String) { last = value }

    /// Returns text left unchanged for two seconds, or the text that was in the field for at least half a second before it emptied.
    mutating func observe(_ value: String) -> String? {
        if value.isEmpty { return polls >= 2 ? last : nil }
        if value == last { polls += 1 } else { last = value; polls = 1 }
        return polls == 5 ? value : nil
    }
}
#endif
