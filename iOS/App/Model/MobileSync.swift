import BetterWisprCore
import Foundation
import Observation
import OSLog
import UIKit

/// Syncs the phone's library through a folder the user picks in Files, usually the same iCloud Drive folder the Mac uses.
/// iOS only grants access to a picked folder through a security-scoped bookmark, kept in UserDefaults on this device.
@MainActor @Observable
final class MobileSync {
    private(set) var folderName: String?
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var devices: [SyncDevice] = []
    private(set) var problem: String?
    private(set) var pendingDownloads = 0

    @ObservationIgnored private let model: MobileModel
    @ObservationIgnored private var activeMeeting: @MainActor () -> UUID? = { nil }
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private let journalURL: URL
    private static let bookmarkKey = "syncFolderBookmark"
    private static let logger = Logger(subsystem: "org.betterwispr.mobile", category: "Sync")

    init(model: MobileModel, activeMeeting: @escaping @MainActor () -> UUID? = { nil }) {
        self.model = model
        self.activeMeeting = activeMeeting
        journalURL = model.store.directory.appending(path: "sync-journal.json")
        folderName = resolveFolder()?.lastPathComponent
        model.onSaved = { [weak self] in self?.schedule(after: .seconds(2)) }
    }

    var isOn: Bool { folderName != nil }

    func choose(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            folderName = url.lastPathComponent
            problem = nil
            schedule(after: .zero)
        } catch {
            problem = "BetterWispr couldn't keep access to that folder: \(error.localizedDescription)"
        }
    }

    func stop() {
        scheduled?.cancel()
        if let folder = resolveFolder() {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            try? engine(for: folder).leave()
        }
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        folderName = nil
        devices = []
        lastSync = nil
        problem = nil
    }

    func schedule(after delay: Duration = .seconds(1)) {
        guard isOn else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard let folder = resolveFolder() else { return }
        guard !isSyncing else { again = true; return }
        isSyncing = true
        defer {
            isSyncing = false
            if again { again = false; schedule() }
        }
        let snapshot = model.syncLibrary
        let engine = engine(for: folder)
        // Keep running briefly if the user leaves the app mid-sync, so files aren't left half written.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Sync")
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        do {
            let result = try await Task.detached(priority: .utility) {
                let scoped = folder.startAccessingSecurityScopedResource()
                defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                return try engine.sync(snapshot)
            }.value
            guard model.syncLibrary.savedState == snapshot.savedState else { again = true; return }
            try model.adoptSynced(result, skipping: activeMeeting())
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

    private func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            if let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
            }
        }
        return url
    }

    private func engine(for folder: URL) -> SyncEngine {
        SyncEngine(folder: FileSyncFolder(root: folder), journalURL: journalURL,
                   deviceName: UIDevice.current.name, platform: "iOS")
    }
}
