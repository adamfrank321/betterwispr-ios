import Foundation

/// What the app is doing for the keyboard, shown on the keyboard's dictate button.
enum BridgePhase: String, Codable, Sendable {
    /// No session: the keyboard has to open the app to start one.
    case idle
    /// The app holds the microphone session open in the background, so a tap starts recording without leaving the keyboard.
    case ready
    case recording
    case transcribing
    case failed
}

/// The app's state as the keyboard sees it. Results carry an ID so the keyboard inserts each one exactly once.
struct BridgeState: Codable, Equatable, Sendable {
    var phase: BridgePhase = .idle
    /// When the warm session ends; after this the keyboard treats the app as idle even if the app was suspended before saying so.
    var sessionEnds: Date?
    var resultID: UUID?
    var result: String?
    var message: String?
    var level: Float = 0
    var updated = Date.distantPast

    /// The phase, treating a warm session that ran out as idle.
    func effectivePhase(at now: Date = .now) -> BridgePhase {
        if phase == .ready, let sessionEnds, sessionEnds < now { return .idle }
        return phase
    }
}

enum BridgeCommandKind: String, Codable, Sendable {
    case start, stop, cancel
}

/// A request from the keyboard. `style` is the kind of app the user is typing in, chosen on the keyboard, since iOS doesn't say.
struct BridgeCommand: Codable, Equatable, Sendable {
    var id = UUID()
    var kind: BridgeCommandKind
    var style: String
    /// Text before the cursor, used as context for Medium cleanup when the user allows it.
    var context: String?
    var sent = Date.now
}

/// A fix the user made to dictated text in the keyboard's text field, for the app to learn from.
struct BridgeCorrection: Codable, Equatable, Sendable {
    var original: String
    var edited: String
    var date = Date.now
}

/// The app and keyboard talk through the shared App Group: state and queues in shared defaults, nudges as Darwin notifications.
/// Darwin notifications carry no data, so each side re-reads the defaults when nudged.
struct KeyboardBridge: Sendable {
    static let stateChanged = "org.betterwispr.bridge.state"
    static let commandSent = "org.betterwispr.bridge.command"
    static let dictateURL = URL(string: "betterwispr://dictate")!

    let suiteName: String?

    init(suiteName: String? = Bundle.main.object(forInfoDictionaryKey: "BetterWisprAppGroup") as? String) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    /// A folder both sides can read; nil when the App Group isn't provisioned (unsigned simulator builds).
    var sharedFolder: URL? {
        suiteName.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    // MARK: State, written by the app

    var state: BridgeState {
        get { read(BridgeState.self, key: "state") ?? BridgeState() }
        nonmutating set {
            var value = newValue
            value.updated = .now
            write(value, key: "state")
            DarwinNotification.post(Self.stateChanged)
        }
    }

    func update(_ change: (inout BridgeState) -> Void) {
        var value = state
        change(&value)
        state = value
    }

    // MARK: Commands, written by the keyboard

    func send(_ command: BridgeCommand) {
        write(command, key: "command")
        DarwinNotification.post(Self.commandSent)
    }

    /// The newest command if the app hasn't handled it yet and it isn't stale.
    func pendingCommand(maxAge: TimeInterval = 30, now: Date = .now) -> BridgeCommand? {
        guard let command = read(BridgeCommand.self, key: "command"),
              command.id.uuidString != defaults.string(forKey: "handledCommand"),
              now.timeIntervalSince(command.sent) <= maxAge else { return nil }
        return command
    }

    func markHandled(_ command: BridgeCommand) {
        defaults.set(command.id.uuidString, forKey: "handledCommand")
    }

    // MARK: Results, consumed by the keyboard

    /// The result to insert, once: returns nil after the keyboard has taken it.
    func takeResult() -> (id: UUID, text: String)? {
        let value = state
        guard let id = value.resultID, let text = value.result, !text.isEmpty,
              id.uuidString != defaults.string(forKey: "insertedResult") else { return nil }
        defaults.set(id.uuidString, forKey: "insertedResult")
        return (id, text)
    }

    // MARK: Corrections, queued by the keyboard

    func queue(_ correction: BridgeCorrection) {
        var list = read([BridgeCorrection].self, key: "corrections") ?? []
        list.append(correction)
        write(Array(list.suffix(50)), key: "corrections")
    }

    func takeCorrections() -> [BridgeCorrection] {
        let list = read([BridgeCorrection].self, key: "corrections") ?? []
        if !list.isEmpty { defaults.removeObject(forKey: "corrections") }
        return list
    }

    // MARK: Keyboard preferences

    var keyboardStyle: String {
        get { defaults.string(forKey: "keyboardStyle") ?? "other" }
        nonmutating set { defaults.set(newValue, forKey: "keyboardStyle") }
    }

    /// Set by the app from the Use screen context setting, so the keyboard only reads text when allowed.
    var sharesContext: Bool {
        get { defaults.bool(forKey: "sharesContext") }
        nonmutating set { defaults.set(newValue, forKey: "sharesContext") }
    }

    var learnsCorrections: Bool {
        get { defaults.object(forKey: "learnsCorrections") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "learnsCorrections") }
    }

    /// Set by the keyboard each time it appears, so the app can show that setup is finished.
    var keyboardLastSeen: Date? {
        get { defaults.object(forKey: "keyboardLastSeen") as? Date }
        nonmutating set { defaults.set(newValue, forKey: "keyboardLastSeen") }
    }

    var keyboardHasFullAccess: Bool {
        get { defaults.bool(forKey: "keyboardHasFullAccess") }
        nonmutating set { defaults.set(newValue, forKey: "keyboardHasFullAccess") }
    }

    private func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func write<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

/// Cross-process nudges between the app and its keyboard.
enum DarwinNotification {
    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }
}

/// Calls `handler` on the main queue whenever the named Darwin notification is posted, until released.
final class DarwinObserver: @unchecked Sendable {
    // Unchecked: the handler is immutable and only ever called on the main queue.
    private let name: String
    private let handler: @MainActor () -> Void

    init(_ name: String, handler: @escaping @MainActor () -> Void) {
        self.name = name
        self.handler = handler
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
                                        { _, observer, _, _, _ in
                                            guard let observer else { return }
                                            let box = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                                            DispatchQueue.main.async { MainActor.assumeIsolated { box.handler() } }
                                        },
                                        name as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
                                           CFNotificationName(name as CFString), nil)
    }
}
