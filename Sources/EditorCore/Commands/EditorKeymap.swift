public enum EditorKeymap {
    public static func resolve(
        _ key: EditorKey,
        modifiers: EditorKeyModifiers = [],
        phase: EditorKeyPhase = .down
    ) -> EditorShortcut? {
        let normalized = key.rawValue.lowercased()

        if modifiers.contains(.command) {
            guard phase == .down, normalized == "z" else { return nil }
            return modifiers.contains(.shift) ? .redo : .undo
        }

        if normalized == " " {
            switch phase {
            case .down:
                return .spaceChanged(true)
            case .up:
                return .spaceChanged(false)
            case .repeat:
                return nil
            }
        }

        guard phase == .down else { return nil }

        switch normalized {
        case "b":
            return .selectTool(.draw)
        case "e":
            return .selectTool(.erase)
        case "0":
            return .clear
        case "+", "=":
            return .stepBrush(larger: true)
        case "-":
            return .stepBrush(larger: false)
        case ">":
            return .stepTile(larger: true)
        case "<":
            return .stepTile(larger: false)
        case "g":
            return .toggleGrid
        case "1", "2", "3", "4", "5", "6", "7":
            return Int(normalized).map {
                .selectTiling(index1: $0)
            }
        case "\u{1B}":
            return .cancel
        default:
            return nil
        }
    }

    public static func resolve(
        key: EditorKey,
        modifiers: EditorKeyModifiers = [],
        phase: EditorKeyPhase = .down
    ) -> EditorShortcut? {
        resolve(key, modifiers: modifiers, phase: phase)
    }
}
