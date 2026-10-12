import BetterWisprCore
import Foundation
import Observation

/// Downloads and loads speech models with the same providers as the Mac app. Downloads only happen when the user asks.
@MainActor @Observable
final class ModelManager {
    struct Installation: Equatable {
        var modelID: String
        var progress: Double
        var failure: String?
    }

    private(set) var installation: Installation?
    private(set) var revision = 0
    private(set) var phraseBoosterInstalled = ParakeetProvider.isPhraseBoosterInstalled()

    @ObservationIgnored private var provider: (any SpeechProvider)?
    @ObservationIgnored private var preparedID: String?
    @ObservationIgnored private var installTask: Task<Void, Never>?

    func isInstalled(_ model: SpeechModel) -> Bool {
        _ = revision
        switch model.engine {
        case .apple, .api: return true
        case .parakeet: return ParakeetProvider.isInstalled(model)
        case .whisperKit: return WhisperKitProvider.isInstalled(model)
        }
    }

    /// Models this phone can run. Parakeet and Whisper need a recent iPhone; the large Whisper builds need more memory than most phones have.
    func isSuitable(_ model: SpeechModel) -> Bool {
        let memory = ProcessInfo.processInfo.physicalMemory
        switch model.id {
        case "whisper-turbo": return memory >= 8 * 1_073_741_824
        default: return true
        }
    }

    func install(_ model: SpeechModel, then select: @escaping @MainActor () -> Void) {
        guard installation == nil || installation?.failure != nil else { return }
        installation = Installation(modelID: model.id, progress: 0)
        installTask = Task { [weak self] in
            let provider = model.makeProvider()
            provider.onProgress = { [weak self] value in
                guard let self, self.installation?.modelID == model.id else { return }
                self.installation?.progress = max(self.installation?.progress ?? 0, value)
            }
            do {
                try await provider.prepare(model: model, download: true)
                guard let self, !Task.isCancelled else { return }
                self.installation = nil
                self.revision += 1
                self.phraseBoosterInstalled = ParakeetProvider.isPhraseBoosterInstalled()
                self.provider = provider
                self.preparedID = model.id
                select()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.installation?.failure = error.localizedDescription
            }
        }
    }

    func cancelInstallation() {
        installTask?.cancel()
        installTask = nil
        installation = nil
    }

    func installPhraseBooster() {
        guard installation == nil else { return }
        installation = Installation(modelID: "phrase-booster", progress: 0)
        installTask = Task { [weak self] in
            do {
                try await ParakeetProvider.installPhraseBooster { value in
                    Task { @MainActor in self?.installation?.progress = value }
                }
                self?.installation = nil
                self?.phraseBoosterInstalled = ParakeetProvider.isPhraseBoosterInstalled()
            } catch {
                self?.installation?.failure = error.localizedDescription
            }
        }
    }

    /// Deletes a downloaded model's files to free space.
    func remove(_ model: SpeechModel) {
        let folder: URL = switch model.engine {
        case .parakeet: WhisperKitProvider.defaultModelsDirectory.appending(path: "Parakeet/\(model.modelName)")
        default: WhisperKitProvider.defaultModelsDirectory.appending(path: "models/argmaxinc/whisperkit-coreml/\(model.modelName)")
        }
        try? FileManager.default.removeItem(at: folder)
        if preparedID == model.id { provider = nil; preparedID = nil }
        revision += 1
    }

    /// A loaded provider for `model`, loading it from disk without downloading.
    func provider(for model: SpeechModel, language: String?) async throws -> any SpeechProvider {
        if let provider, preparedID == model.id { return provider }
        let provider = model.makeProvider()
        try await provider.prepare(model: model, download: false)
        self.provider = provider
        preparedID = model.id
        return provider
    }

    /// Loads the selected model ahead of the first dictation so it starts quickly.
    func warmUp(_ model: SpeechModel) {
        guard preparedID != model.id, isInstalled(model), model.engine != .api else { return }
        Task { _ = try? await provider(for: model, language: nil) }
    }

    func release() {
        provider?.cancel()
        provider = nil
        preparedID = nil
    }
}
