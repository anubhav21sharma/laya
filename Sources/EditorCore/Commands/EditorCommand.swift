public enum EditorTool: UInt8, Equatable, Sendable {
    case draw
    case erase
    case select
    case transform
}

public enum StrokeTool: UInt8, Equatable, Sendable {
    case draw
    case erase
}

public enum EditorCommand: UInt8, Equatable, Sendable {
    case undo
    case redo
    case clear
}

public enum EditorShortcut: Equatable, Sendable {
    case selectTool(EditorTool)
    case clear
    case undo
    case redo
    case stepBrush(larger: Bool)
    case stepTile(larger: Bool)
    case toggleGrid
    case selectTiling(index1: Int)
    case cancel
    case spaceChanged(Bool)
}

public struct EditorKey: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public static let escape = EditorKey(rawValue: "\u{1B}")
    public static let space = EditorKey(rawValue: " ")
    public static let returnKey = EditorKey(rawValue: "\r")
    public static let `return` = returnKey

    public static func character(_ value: String) -> EditorKey {
        EditorKey(rawValue: value)
    }
}

public struct EditorKeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = EditorKeyModifiers(rawValue: 1 << 0)
    public static let shift = EditorKeyModifiers(rawValue: 1 << 1)
    public static let option = EditorKeyModifiers(rawValue: 1 << 2)
    public static let control = EditorKeyModifiers(rawValue: 1 << 3)
}

public enum EditorKeyPhase: UInt8, Equatable, Sendable {
    case down
    case `repeat`
    case up
}
