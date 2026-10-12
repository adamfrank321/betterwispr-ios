import Foundation

/// The shared folder sync reads and writes, addressed by slash-separated paths relative to its root.
public protocol SyncFolder: Sendable {
    /// Names of the entries directly inside `path`; empty when it doesn't exist.
    func list(_ path: String) throws -> [String]
    /// The file's contents, or nil when it doesn't exist or hasn't downloaded to this device yet.
    func read(_ path: String) throws -> Data?
    /// Writes atomically, creating parent folders.
    func write(_ data: Data, to path: String) throws
    func remove(_ path: String) throws
}

/// A folder on disk, usually in iCloud Drive. Reads and writes go through file coordination so iCloud sees consistent files,
/// and files iCloud hasn't downloaded yet are requested and reported as missing until they arrive.
public struct FileSyncFolder: SyncFolder {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    private func url(_ path: String) -> URL {
        path.isEmpty ? root : root.appending(path: path)
    }

    public func list(_ path: String) throws -> [String] {
        let directory = url(path)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var names: [String] = []
        var failure: (any Error)?
        try coordinate { coordinator, error in
            coordinator.coordinate(readingItemAt: directory, options: [], error: error) { url in
                do { names = try FileManager.default.contentsOfDirectory(atPath: url.path) } catch { failure = error }
            }
        }
        if let failure { throw failure }
        // iCloud shows a file it hasn't downloaded as ".name.icloud"; report it under its real name so reads can request it.
        return Set(names.compactMap { name -> String? in
            if name.hasPrefix("."), name.hasSuffix(".icloud") { return String(name.dropFirst().dropLast(7)) }
            return name.hasPrefix(".") ? nil : name
        }).sorted()
    }

    public func read(_ path: String) throws -> Data? {
        let file = url(path)
        let placeholder = file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).icloud")
        if !FileManager.default.fileExists(atPath: file.path) {
            if FileManager.default.fileExists(atPath: placeholder.path) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            }
            return nil
        }
        var data: Data?
        var failure: (any Error)?
        try coordinate { coordinator, error in
            coordinator.coordinate(readingItemAt: file, options: [], error: error) { url in
                do { data = try Data(contentsOf: url) } catch { failure = error }
            }
        }
        if let failure { throw failure }
        return data
    }

    public func write(_ data: Data, to path: String) throws {
        let file = url(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var failure: (any Error)?
        try coordinate { coordinator, error in
            coordinator.coordinate(writingItemAt: file, options: .forReplacing, error: error) { url in
                do { try data.write(to: url, options: .atomic) } catch { failure = error }
            }
        }
        if let failure { throw failure }
    }

    public func remove(_ path: String) throws {
        let file = url(path)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var failure: (any Error)?
        try coordinate { coordinator, error in
            coordinator.coordinate(writingItemAt: file, options: .forDeleting, error: error) { url in
                do { try FileManager.default.removeItem(at: url) } catch { failure = error }
            }
        }
        if let failure { throw failure }
    }

    private func coordinate(_ body: (NSFileCoordinator, NSErrorPointer) -> Void) throws {
        var error: NSError?
        body(NSFileCoordinator(filePresenter: nil), &error)
        if let error { throw error }
    }
}

/// An in-memory folder for tests and previews.
public final class MemorySyncFolder: SyncFolder, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]

    public init() {}

    public func list(_ path: String) throws -> [String] {
        lock.withLock {
            let prefix = path.isEmpty ? "" : path + "/"
            return Set(files.keys.filter { $0.hasPrefix(prefix) }.compactMap {
                $0.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
            }).sorted()
        }
    }

    public func read(_ path: String) throws -> Data? { lock.withLock { files[path] } }
    public func write(_ data: Data, to path: String) throws { lock.withLock { files[path] = data } }
    public func remove(_ path: String) throws { lock.withLock { files[path] = nil } }
    public var paths: [String] { lock.withLock { files.keys.sorted() } }
}
