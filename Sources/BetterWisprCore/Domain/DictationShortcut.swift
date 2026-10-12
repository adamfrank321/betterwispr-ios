#if canImport(Carbon)
import Carbon.HIToolbox
#else
// Carbon's virtual key codes, so saved shortcuts decode identically where Carbon is unavailable (iOS).
private let kVK_F1 = 0x7A, kVK_F2 = 0x78, kVK_F3 = 0x63, kVK_F4 = 0x76, kVK_F5 = 0x60, kVK_F6 = 0x61, kVK_F7 = 0x62
private let kVK_F8 = 0x64, kVK_F9 = 0x65, kVK_F10 = 0x6D, kVK_F11 = 0x67, kVK_F12 = 0x6F, kVK_F13 = 0x69, kVK_F14 = 0x6B
private let kVK_F15 = 0x71, kVK_F16 = 0x6A, kVK_F17 = 0x40, kVK_F18 = 0x4F, kVK_F19 = 0x50, kVK_F20 = 0x5A
private let kVK_Command = 0x37, kVK_Shift = 0x38, kVK_Option = 0x3A, kVK_Control = 0x3B
private let kVK_RightCommand = 0x36, kVK_RightShift = 0x3C, kVK_RightOption = 0x3D, kVK_RightControl = 0x3E
#endif
import Foundation

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let command = ShortcutModifiers(rawValue: 1 << 8)
    public static let shift = ShortcutModifiers(rawValue: 1 << 9)
    public static let option = ShortcutModifiers(rawValue: 1 << 11)
    public static let control = ShortcutModifiers(rawValue: 1 << 12)

    fileprivate static let names: [(modifier: ShortcutModifiers, symbol: String, spoken: String)] = [
        (.control, "⌃", "Control"), (.option, "⌥", "Option"), (.shift, "⇧", "Shift"), (.command, "⌘", "Command")
    ]

    fileprivate var activeNames: [(modifier: ShortcutModifiers, symbol: String, spoken: String)] {
        Self.names.filter { contains($0.modifier) }
    }

    public var symbols: String { activeNames.map(\.symbol).joined() }
}

public struct DictationShortcut: Codable, Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: ShortcutModifiers
    public let key: String

    public static let optionSpace = DictationShortcut(validKeyCode: 49, modifiers: .option, key: "Space")
    private static let functionKeyCodes = Set([kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                               kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
                                               kVK_F20].map(UInt32.init))

    public init?(keyCode: UInt32, modifiers: ShortcutModifiers, key: String) {
        guard !key.isEmpty else { return nil }
        if Self.modifier(for: keyCode) != nil {
            guard modifiers.isEmpty else { return nil }
        } else {
            guard Self.functionKeyCodes.contains(keyCode) || !modifiers.isDisjoint(with: [.control, .option, .command]) else { return nil }
        }
        self.init(validKeyCode: keyCode, modifiers: modifiers, key: key)
    }

    public static func modifier(for keyCode: UInt32) -> ShortcutModifiers? {
        switch Int(keyCode) {
        case kVK_Control, kVK_RightControl: .control
        case kVK_Option, kVK_RightOption: .option
        case kVK_Shift, kVK_RightShift: .shift
        case kVK_Command, kVK_RightCommand: .command
        default: nil
        }
    }

    public var isModifierOnly: Bool { modifiers.isEmpty && Self.modifier(for: keyCode) != nil }

    private init(validKeyCode keyCode: UInt32, modifiers: ShortcutModifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let shortcut = DictationShortcut(keyCode: try container.decode(UInt32.self, forKey: .keyCode),
                                               modifiers: try container.decode(ShortcutModifiers.self, forKey: .modifiers),
                                               key: try container.decode(String.self, forKey: .key)) else {
            throw DecodingError.dataCorruptedError(forKey: .modifiers, in: container,
                                                   debugDescription: "A shortcut needs a modifier key alone, Control, Option or Command with a key, or a function key.")
        }
        self = shortcut
    }

    public var displayName: String { modifiers.isEmpty ? key : modifiers.symbols + " " + key }
    public var spokenName: String { (modifiers.activeNames.map(\.spoken) + [key]).joined(separator: " ") }
}
