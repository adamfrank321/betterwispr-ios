import SwiftUI
import UIKit

/// A dictation keyboard. iOS doesn't give keyboards the microphone, so recording happens in the BetterWispr app:
/// the first tap opens the app to start a session, then the app keeps listening in the background for a few minutes
/// and later taps record without leaving the keyboard. Results come back through the App Group and are inserted here once.
final class KeyboardViewController: UIInputViewController {
    private let bridge = KeyboardBridge()
    private let viewModel = KeyboardViewModel()
    private var stateObserver: DarwinObserver?
    private var host: UIHostingController<KeyboardView>?
    private var watcher = CorrectionTracker()
    private var expiry: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        viewModel.style = bridge.keyboardStyle
        viewModel.needsGlobe = needsInputModeSwitchKey
        viewModel.actions = KeyboardActions(
            dictate: { [weak self] in self?.dictateTapped() },
            cancel: { [weak self] in self?.bridge.send(BridgeCommand(kind: .cancel, style: self?.viewModel.style ?? "other")) },
            insert: { [weak self] text in self?.textDocumentProxy.insertText(text) },
            delete: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            nextKeyboard: { [weak self] in self?.advanceToNextInputMode() },
            setStyle: { [weak self] style in
                self?.bridge.keyboardStyle = style
                self?.viewModel.style = style
            }
        )
        let host = UIHostingController(rootView: KeyboardView(model: viewModel))
        host.view.backgroundColor = .clear
        host.sizingOptions = .intrinsicContentSize
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let height = view.heightAnchor.constraint(equalToConstant: 268)
        height.priority = .init(999)
        height.isActive = true
        host.didMove(toParent: self)
        self.host = host
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        bridge.keyboardLastSeen = .now
        bridge.keyboardHasFullAccess = hasFullAccess
        viewModel.hasFullAccess = hasFullAccess
        stateObserver = DarwinObserver(KeyboardBridge.stateChanged) { [weak self] in self?.refresh() }
        refresh()
        // A warm session ending sends no notification if the app was suspended, so re-check when it should have ended.
        expiry = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        flushCorrection()
        stateObserver = nil
        expiry?.invalidate()
        expiry = nil
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        watcher.observe(before: textDocumentProxy.documentContextBeforeInput, after: textDocumentProxy.documentContextAfterInput)
        if watcher.isExpired { flushCorrection() }
    }

    private func refresh() {
        let state = bridge.state
        viewModel.phase = state.effectivePhase()
        viewModel.message = state.message
        viewModel.level = state.level
        if let result = bridge.takeResult() {
            flushCorrection()
            let before = textDocumentProxy.documentContextBeforeInput ?? ""
            let after = textDocumentProxy.documentContextAfterInput ?? ""
            let spacer = before.isEmpty || before.last?.isWhitespace == true ? "" : " "
            textDocumentProxy.insertText(spacer + result.text)
            if bridge.learnsCorrections {
                watcher.start(inserted: result.text, prefix: before + spacer, suffix: after)
            }
        }
    }

    private func dictateTapped() {
        switch viewModel.phase {
        case .recording:
            bridge.send(BridgeCommand(kind: .stop, style: viewModel.style))
        case .transcribing:
            break
        case .ready:
            bridge.send(BridgeCommand(kind: .start, style: viewModel.style, context: context()))
        case .idle, .failed:
            guard hasFullAccess else {
                viewModel.message = "Turn on Allow Full Access for BetterWispr in Settings > General > Keyboard > Keyboards."
                return
            }
            // Leave the request for the app to pick up when it opens, then open it.
            bridge.send(BridgeCommand(kind: .start, style: viewModel.style, context: context()))
            openApp()
        }
    }

    private func context() -> String? {
        guard bridge.sharesContext else { return nil }
        return textDocumentProxy.documentContextBeforeInput
    }

    private func flushCorrection() {
        if let correction = watcher.finish() { bridge.queue(correction) }
    }

    /// Keyboards can't call UIApplication.open, so walk the responder chain to the application object and call it there.
    private func openApp() {
        let selector = sel_registerName("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector), current !== self {
                typealias Open = @convention(c) (AnyObject, Selector, URL, NSDictionary, ((Bool) -> Void)?) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: Open.self)
                open(current, selector, KeyboardBridge.dictateURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
        viewModel.message = "Open BetterWispr to start dictating, then come back here."
    }
}
