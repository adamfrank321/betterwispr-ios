import Foundation
import Testing
@testable import BetterWisprMobile

@Test func aWarmSessionThatRanOutReadsAsIdle() {
    var state = BridgeState(phase: .ready, sessionEnds: Date.now.addingTimeInterval(-1))
    #expect(state.effectivePhase() == .idle)
    state.sessionEnds = Date.now.addingTimeInterval(60)
    #expect(state.effectivePhase() == .ready)
    state.phase = .recording
    #expect(state.effectivePhase() == .recording)
}

@Test func resultsAndCommandsAreTakenOnce() {
    let bridge = KeyboardBridge(suiteName: "test.\(UUID().uuidString)")
    bridge.update { $0.resultID = UUID(); $0.result = "Hello" }
    #expect(bridge.takeResult()?.text == "Hello")
    #expect(bridge.takeResult() == nil)

    let command = BridgeCommand(kind: .start, style: "work")
    bridge.send(command)
    #expect(bridge.pendingCommand() == command)
    bridge.markHandled(command)
    #expect(bridge.pendingCommand() == nil)

    let old = BridgeCommand(kind: .stop, style: "work", sent: Date.now.addingTimeInterval(-120))
    bridge.send(old)
    #expect(bridge.pendingCommand() == nil)
}

@Test func correctionsQueueUntilTheAppTakesThem() {
    let bridge = KeyboardBridge(suiteName: "test.\(UUID().uuidString)")
    bridge.queue(BridgeCorrection(original: "meet post hog", edited: "meet PostHog"))
    #expect(bridge.takeCorrections().map(\.edited) == ["meet PostHog"])
    #expect(bridge.takeCorrections().isEmpty)
}

@Test func trackerReadsAFixBackOutOfTheField() {
    var tracker = CorrectionTracker()
    tracker.start(inserted: "Ask post hog about it.", prefix: "Hi team. ", suffix: "")
    tracker.observe(before: "Hi team. Ask PostHog about it.", after: "")
    let correction = tracker.finish()
    #expect(correction?.original == "Ask post hog about it.")
    #expect(correction?.edited == "Ask PostHog about it.")
}

@Test func trackerIgnoresUnchangedTextAndRewrites() {
    var tracker = CorrectionTracker()
    tracker.start(inserted: "Short note.", prefix: "", suffix: "")
    tracker.observe(before: "Short note.", after: "")
    #expect(tracker.finish() == nil)
    tracker.start(inserted: "Short note.", prefix: "", suffix: "")
    tracker.observe(before: "A completely different and much much longer paragraph that the user typed instead of fixing.", after: "")
    #expect(tracker.finish() == nil)
}
