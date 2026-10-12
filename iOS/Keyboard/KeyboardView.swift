import SwiftUI

@MainActor
struct KeyboardActions {
    var dictate: @MainActor () -> Void = {}
    var cancel: @MainActor () -> Void = {}
    var insert: @MainActor (String) -> Void = { _ in }
    var delete: @MainActor () -> Void = {}
    var nextKeyboard: @MainActor () -> Void = {}
    var setStyle: @MainActor (String) -> Void = { _ in }
}

@MainActor @Observable
final class KeyboardViewModel {
    var phase: BridgePhase = .idle
    var message: String?
    var level: Float = 0
    var style = "other"
    var hasFullAccess = false
    var needsGlobe = true
    @ObservationIgnored var actions = KeyboardActions()
}

/// The kinds of app a writing tone can be set for, matching StyleContext in the shared library.
private let styles: [(id: String, name: String)] = [("personal", "Personal"), ("work", "Work"), ("email", "Email"), ("other", "Other")]

struct KeyboardView: View {
    let model: KeyboardViewModel

    var body: some View {
        VStack(spacing: 10) {
            Picker("Writing for", selection: Binding(get: { model.style }, set: { model.actions.setStyle($0) })) {
                ForEach(styles, id: \.id) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .accessibilityHint("Picks the writing tone for this dictation")

            Text(status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(minHeight: 32)
                .padding(.horizontal, 16)

            HStack(spacing: 16) {
                if model.phase == .recording || model.phase == .transcribing {
                    KeyButton(systemImage: "xmark", label: "Cancel", action: model.actions.cancel)
                } else {
                    KeyButton(text: ",", label: "Comma") { model.actions.insert(",") }
                }
                DictateButton(phase: model.phase, level: model.level, action: model.actions.dictate)
                KeyButton(text: ".", label: "Period") { model.actions.insert(".") }
            }

            HStack(spacing: 6) {
                if model.needsGlobe {
                    KeyButton(systemImage: "globe", label: "Next keyboard", action: model.actions.nextKeyboard)
                }
                KeyButton(text: "?", label: "Question mark") { model.actions.insert("?") }
                KeyButton(text: "space", label: "Space", wide: true) { model.actions.insert(" ") }
                KeyButton(systemImage: "delete.left", label: "Delete", action: model.actions.delete)
                KeyButton(systemImage: "return", label: "Return") { model.actions.insert("\n") }
            }
            .padding(.horizontal, 6)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private var status: String {
        if let message = model.message, model.phase == .failed || !model.hasFullAccess { return message }
        switch model.phase {
        case .idle: return model.hasFullAccess ? "Tap to dictate. BetterWispr opens to start listening, then swipe back here." : (model.message ?? "Allow Full Access to dictate.")
        case .ready: return "Tap to dictate."
        case .recording: return "Listening. Tap to finish."
        case .transcribing: return "Writing it out…"
        case .failed: return model.message ?? "Something went wrong. Tap to try again."
        }
    }
}

private struct DictateButton: View {
    let phase: BridgePhase
    let level: Float
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(phase == .recording ? Color.red : Color.accentColor)
                    .frame(width: 76, height: 76)
                    .scaleEffect(phase == .recording ? 1 + CGFloat(min(max(level, 0), 1)) * 0.12 : 1)
                    .animation(.easeOut(duration: 0.12), value: level)
                if phase == .transcribing {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(phase == .transcribing)
        .accessibilityLabel(phase == .recording ? "Stop dictating" : "Dictate")
    }
}

private struct KeyButton: View {
    var text: String?
    var systemImage: String?
    let label: String
    var wide = false
    let action: () -> Void

    init(text: String, label: String, wide: Bool = false, action: @escaping () -> Void) {
        self.text = text
        self.label = label
        self.wide = wide
        self.action = action
    }

    init(systemImage: String, label: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage { Image(systemName: systemImage) } else { Text(text ?? "") }
            }
            .font(.system(size: 18))
            .frame(maxWidth: wide ? .infinity : 44, minHeight: 42)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(uiColor: .secondarySystemBackground)))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
