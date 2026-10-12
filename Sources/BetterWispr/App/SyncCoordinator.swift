import AppKit
import BetterWisprCore
import Observation
import OSLog

/// Keeps this Mac's library in step with the sync folder: after saves, at launch, every minute and when the app becomes active.
/// The folder choice is per device, so it lives in UserDefaults rather than the synced workspace.
@MainActor @Observable
final class SyncCoordinator {
    private(set) var folder: URL?
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var devices: [SyncDevice] = []
    private(set) var problem: String?
    private(set) var pendingDownloads = 0

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var activation: (any NSObjectProtocol)?
    @ObservationIgnored private let journalURL: URL
    private static let folderKey = "syncFolderPath"
    private static let logger = Logger(subsystem: "org.betterwispr.app", category: "Sync")

    /// iCloud Drive's local folder on this Mac, when iCloud Drive is turned on.
    static var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    init(model: AppModel, workspace: URL) {
        self.model = model
        journalURL = workspace.appending(path: "sync-journal.json")
        folder = UserDefaults.standard.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func start() {
        guard folder != nil else { return }
        schedule(after: .seconds(2))
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.schedule()
            }
        }
        guard activation == nil else { return }
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
    }

    func choose(_ url: URL) {
        folder = url
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        problem = nil
        start()
        schedule()
    }

    /// Stops syncing on this Mac and removes its files from the folder; everything on this Mac stays.
    func stop() {
        timer?.cancel()
        scheduled?.cancel()
        if let folder {
            let engine = engine(for: folder)
            do { try engine.leave() } catch { Self.logger.error("Leaving the sync folder failed: \(error.localizedDescription, privacy: .public)") }
        }
        folder = nil
        devices = []
        lastSync = nil
        problem = nil
        UserDefaults.standard.removeObject(forKey: Self.folderKey)
    }

    /// Coalesces bursts of saves into one sync.
    func schedule(after delay: Duration = .seconds(1)) {
        guard folder != nil else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard let folder, let model else { return }
        guard !isSyncing else { again = true; return }
        isSyncing = true
        defer {
            isSyncing = false
            if again { again = false; schedule() }
        }
        let snapshot = model.syncLibrary
        let engine = engine(for: folder)
        do {
            let result = try await Task.detached(priority: .utility) { try engine.sync(snapshot) }.value
            // Workspace edits saved while the folder was being read would be overwritten; leave this result uncommitted and try again.
            // Meetings aren't replaced wholesale, so a meeting saved meanwhile (one being recorded) doesn't need a retry.
            guard model.syncLibrary.savedState == snapshot.savedState else { again = true; return }
            try model.adoptSynced(result)
            try engine.commit(result)
            lastSync = .now
            devices = result.devices
            pendingDownloads = result.pendingDownloads
            problem = nil
            if result.pendingDownloads > 0 { schedule(after: .seconds(10)) }
        } catch {
            problem = error.localizedDescription
            Self.logger.error("Sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func engine(for folder: URL) -> SyncEngine {
        SyncEngine(folder: FileSyncFolder(root: folder), journalURL: journalURL,
                   deviceName: Host.current().localizedName ?? "Mac", platform: "macOS")
    }
}
