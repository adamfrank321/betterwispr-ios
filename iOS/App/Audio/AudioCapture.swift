@preconcurrency import AVFoundation
import BetterWisprCore
import Foundation

enum CaptureError: LocalizedError {
    case permissionDenied
    case unavailable
    case notRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Allow Microphone access for BetterWispr in Settings."
        case .unavailable: "The microphone isn't available. Another app may be using it."
        case .notRecording: "No recording is running."
        }
    }
}

/// The phone's microphone. The engine can stay running between dictations (the warm session the keyboard relies on),
/// and audio is written to a file only while a recording is open.
@MainActor
final class AudioCapture {
    /// 0...1 loudness for waveforms, about 20 times a second.
    var onLevel: (@MainActor (Float) -> Void)?
    private(set) var isRunning = false
    private(set) var isRecording = false

    private let engine = AVAudioEngine()
    private let writer = CaptureWriter()
    private var meter = VoiceLevelMeter()

    static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    /// Activates the audio session and starts the microphone without recording yet.
    func startEngine() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.unavailable }
        input.removeTap(onBus: 0)
        let report: @Sendable (Float, TimeInterval) -> Void = { [weak self] rms, duration in
            Task { @MainActor in self?.report(rms: rms, duration: duration) }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(writer: writer, report: report))
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stopEngine() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        _ = writer.close()
        isRecording = false
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func beginRecording() throws {
        if !isRunning { try startEngine() }
        let url = FileManager.default.temporaryDirectory.appending(path: "betterwispr-dictation-\(UUID().uuidString).caf")
        try writer.open(url, format: engine.inputNode.outputFormat(forBus: 0))
        meter = VoiceLevelMeter()
        isRecording = true
    }

    /// Closes the file; the caller owns it and deletes it after transcription.
    func finishRecording() throws -> (url: URL, duration: TimeInterval, hasSpeech: Bool) {
        guard isRecording, let result = writer.close() else { throw CaptureError.notRecording }
        isRecording = false
        return result
    }

    func discardRecording() {
        if let result = writer.close() { try? FileManager.default.removeItem(at: result.url) }
        isRecording = false
    }

    /// Built outside the main actor: the engine calls taps on its own audio thread.
    private nonisolated static func tap(writer: CaptureWriter, report: @escaping @Sendable (Float, TimeInterval) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            let rms = writer.write(buffer)
            report(rms, Double(buffer.frameLength) / buffer.format.sampleRate)
        }
    }

    private func report(rms: Float, duration: TimeInterval) {
        onLevel?(isRecording ? meter.update(rms: rms, over: duration) : 0)
    }
}

/// Writes capture buffers on the audio thread. Unchecked Sendable: a lock guards the file and counters.
final class CaptureWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var url: URL?
    private var frames: AVAudioFramePosition = 0
    private var loudFrames: AVAudioFramePosition = 0
    private var sampleRate: Double = 16_000
    /// The same quiet-room threshold the Mac app uses by default.
    private let threshold: Float = 0.002

    func open(_ url: URL, format: AVAudioFormat) throws {
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        lock.withLock {
            self.file = file
            self.url = url
            frames = 0
            loudFrames = 0
            sampleRate = format.sampleRate
        }
    }

    /// Writes when a recording is open and returns the buffer's loudness either way.
    func write(_ buffer: AVAudioPCMBuffer) -> Float {
        let rms = Self.rms(buffer)
        lock.withLock {
            guard let file else { return }
            do {
                try file.write(from: buffer)
                frames += AVAudioFramePosition(buffer.frameLength)
                if rms >= threshold { loudFrames += AVAudioFramePosition(buffer.frameLength) }
            } catch {
                self.file = nil
            }
        }
        return rms
    }

    func close() -> (url: URL, duration: TimeInterval, hasSpeech: Bool)? {
        lock.withLock {
            defer { file = nil; url = nil }
            guard let url, file != nil else { return nil }
            return (url, Double(frames) / sampleRate, Double(loudFrames) / sampleRate >= 0.12)
        }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { sum += data[0][index] * data[0][index] }
        return (sum / Float(count)).squareRoot()
    }
}
