@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation

public enum SpeakerDetectionError: LocalizedError {
    case damaged

    public var errorDescription: String? {
        "The speaker detection model is damaged. Download it again in Models."
    }
}

/// Tells the voices on the other side of a call apart after a meeting, on this Mac, with FluidAudio's offline pyannote pipeline.
public enum SpeakerDetection {
    public static var directory: URL {
        OfflineDiarizerModels.defaultModelsDirectory().appending(path: Repo.diarizer.folderName)
    }

    /// Apple fixed a crash in this pipeline's Core ML path in macOS 15 and iOS 18, released together (FluidAudio issue 878).
    public static var isSupported: Bool {
        #if os(macOS)
        let major = 15
        #else
        let major = 18
        #endif
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0))
    }

    public static var isReady: Bool { isSupported && isInstalled() }

    public static func isInstalled(at directory: URL = directory) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: ".betterwispr-installed").path)
            && ModelNames.OfflineDiarizer.requiredModels.allSatisfy { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
    }

    /// Downloads and verifies the models after an explicit installation action.
    public static func install(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let directory = directory
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await ModelHub.download(.diarizer, to: directory.deletingLastPathComponent(), variant: "offline") {
            progress?(ParakeetProvider.downloadedFraction($0))
        }
        try Task.checkCancellation()
        _ = try loadModels(from: directory)
        try Task.checkCancellation()
        try Data(directory.lastPathComponent.utf8).write(to: directory.appending(path: ".betterwispr-installed"), options: .atomic)
    }

    /// Loads only files already on disk, so a missing or damaged model fails instead of downloading again.
    static func loadModels(from directory: URL) throws -> OfflineDiarizerModels {
        let names = ModelNames.OfflineDiarizer.self
        func model(_ name: String, on units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            configuration.allowLowPrecisionAccumulationOnGPU = true
            return try MLModel(contentsOf: directory.appending(path: name), configuration: configuration)
        }
        return OfflineDiarizerModels(
            segmentationModel: try model(names.segmentationPath, on: .all), fbankModel: try model(names.fbankPath, on: .cpuOnly),
            embeddingModel: try model(names.embeddingPath, on: .all), pldaRhoModel: try model(names.pldaRhoPath, on: .all),
            pldaPsi: try pldaPsi(from: directory.appending(path: names.pldaParameters)), compilationDuration: 0)
    }

    private struct PLDAParameters: Decodable {
        struct Tensors: Decodable { var psi: Tensor }
        struct Tensor: Decodable { var data_base64: String }
        var tensors: Tensors
    }

    /// Adapted from FluidAudio's private `OfflineDiarizerModels.loadPLDAPsi`.
    static func pldaPsi(from url: URL) throws -> [Double] {
        let encoded = try JSONDecoder().decode(PLDAParameters.self, from: Data(contentsOf: url)).tensors.psi.data_base64
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), data.count >= MemoryLayout<Float>.size else {
            throw SpeakerDetectionError.damaged
        }
        var floats = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return floats.map(Double.init)
    }

    /// Splits each segment into the voices heard in it, folding any stretch shorter than `shortest` seconds into a neighbour.
    static func voiceTurns(turns: [TimedSpeakerSegment], placements: [SpeakerRecording.Placement], shortest: TimeInterval = 1) -> [UUID: [VoiceTurn]] {
        let turns = turns.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var result: [UUID: [VoiceTurn]] = [:]
        for placement in placements {
            var runs: [VoiceTurn] = []
            for turn in turns {
                let start = max(placement.start, Double(turn.startTimeSeconds), runs.last?.end ?? 0)
                let end = min(placement.end, Double(turn.endTimeSeconds))
                guard end > start else { continue }
                if runs.last?.voice == turn.speakerId { runs[runs.count - 1].end = end } else { runs.append(VoiceTurn(voice: turn.speakerId, start: start, end: end)) }
            }
            while runs.count > 1, let index = runs.indices.min(by: { runs[$0].length < runs[$1].length }), runs[index].length < shortest {
                let neighbour = index == 0 ? 1 : index == runs.count - 1 || runs[index - 1].length >= runs[index + 1].length ? index - 1 : index + 1
                runs[neighbour].start = min(runs[neighbour].start, runs[index].start)
                runs[neighbour].end = max(runs[neighbour].end, runs[index].end)
                runs.remove(at: index)
                runs = runs.reduce(into: []) { merged, run in
                    if merged.last?.voice == run.voice { merged[merged.count - 1].end = run.end } else { merged.append(run) }
                }
            }
            guard !runs.isEmpty else { continue }
            result[placement.segment] = runs.indices.map { index in
                let start = index == 0 ? placement.start : (runs[index - 1].end + runs[index].start) / 2
                let end = index == runs.count - 1 ? placement.end : (runs[index].end + runs[index + 1].start) / 2
                return VoiceTurn(voice: runs[index].voice, start: start - placement.start, end: end - placement.start)
            }
        }
        return result
    }

    /// Gives each Them segment its voice and transcribes a segment again in pieces when several voices speak in it.
    /// A segment keeps its text and takes its longest voice when a piece can't be transcribed. Voices are numbered 1, 2, 3 by first appearance.
    @MainActor
    public static func label(_ segments: [MeetingSegment], voices: SpeakerRecording,
                             transcribe: (_ audio: URL, _ start: TimeInterval, _ duration: TimeInterval) async throws -> MeetingSegment?) async throws -> [MeetingSegment] {
        try await label(segments, turns: voices.voiceTurns(), audio: { try await voices.audio(of: $0, from: $1.start, to: $1.end) }, transcribe: transcribe)
    }

    @MainActor
    static func label(_ segments: [MeetingSegment], turns: [UUID: [VoiceTurn]], audio: (UUID, VoiceTurn) async throws -> URL,
                      transcribe: (_ audio: URL, _ start: TimeInterval, _ duration: TimeInterval) async throws -> MeetingSegment?) async throws -> [MeetingSegment] {
        var labelled: [(segment: MeetingSegment, voice: String?)] = []
        for segment in segments {
            guard let pieces = turns[segment.id], let longest = pieces.max(by: { $0.length < $1.length }) else {
                labelled.append((segment, nil))
                continue
            }
            var split: [(segment: MeetingSegment, voice: String?)] = []
            for piece in pieces where pieces.count > 1 {
                try Task.checkCancellation()
                do {
                    let url = try await audio(segment.id, piece)
                    defer { try? FileManager.default.removeItem(at: url) }
                    if let transcribed = try await transcribe(url, segment.start + piece.start, piece.length) { split.append((transcribed, piece.voice)) }
                } catch {
                    split = []
                    break
                }
            }
            try Task.checkCancellation()
            labelled += split.isEmpty ? [(segment, longest.voice)] : split
        }
        var numbers: [String: Int] = [:]
        return labelled.map { segment, voice in
            var segment = segment
            if let voice {
                segment.participant = numbers[voice] ?? numbers.count + 1
                numbers[voice] = segment.participant
            }
            return segment
        }
    }
}

/// One voice's stretch of a Them segment, in seconds from the start of that segment's audio.
struct VoiceTurn: Equatable, Sendable {
    var voice: String
    var start: TimeInterval
    var end: TimeInterval

    var length: TimeInterval { end - start }
}

/// Collects the call audio behind each transcribed Them segment into one 16 kHz file, then finds who spoke each one.
public actor SpeakerRecording {
    struct Placement: Sendable {
        var segment: UUID
        var start: TimeInterval
        var end: TimeInterval
    }

    public nonisolated let url: URL
    private var file: AVAudioFile?
    private var placements: [Placement] = []
    private static let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    public init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "betterwispr-meeting-voices-\(UUID().uuidString).caf")
        file = try AVAudioFile(forWriting: url, settings: Self.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    public func append(_ chunk: URL, for segment: UUID) throws {
        guard let file else { return }
        let samples = try AudioConverter().resampleAudioFile(chunk)
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let start = Double(file.length) / Self.format.sampleRate
        try file.write(from: buffer)
        placements.append(Placement(segment: segment, start: start, end: Double(file.length) / Self.format.sampleRate))
    }

    /// Finds the voices behind each Them segment; empty when no call audio was collected.
    func voiceTurns() async throws -> [UUID: [VoiceTurn]] {
        file = nil
        guard !placements.isEmpty else { return [:] }
        let diarizer = OfflineDiarizerManager()
        diarizer.initialize(models: try SpeakerDetection.loadModels(from: SpeakerDetection.directory))
        let result = try await diarizer.process(url)
        return SpeakerDetection.voiceTurns(turns: result.segments, placements: placements)
    }

    /// Writes one stretch of a segment's call audio to its own file, in seconds from the segment's start.
    func audio(of segment: UUID, from start: TimeInterval, to end: TimeInterval) throws -> URL {
        guard file == nil, let placement = placements.first(where: { $0.segment == segment }) else { throw CocoaError(.fileReadUnknown) }
        let source = try AVAudioFile(forReading: url)
        let first = AVAudioFramePosition((placement.start + start) * Self.format.sampleRate)
        let last = AVAudioFramePosition(min(placement.end, placement.start + end) * Self.format.sampleRate)
        guard last > first, let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(last - first)) else {
            throw CocoaError(.fileReadUnknown)
        }
        source.framePosition = first
        try source.read(into: buffer, frameCount: AVAudioFrameCount(last - first))
        let piece = FileManager.default.temporaryDirectory.appending(path: "betterwispr-meeting-\(UUID().uuidString).caf")
        do {
            try AVAudioFile(forWriting: piece, settings: Self.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false).write(from: buffer)
        } catch {
            try? FileManager.default.removeItem(at: piece)
            throw error
        }
        return piece
    }

    public nonisolated func discard() {
        try? FileManager.default.removeItem(at: url)
    }
}
