#if os(macOS)
import SwiftUI

struct EditorCommandActions {
    let undo: @MainActor () -> Void
    let redo: @MainActor () -> Void
    let clear: @MainActor () -> Void
    let selectDraw: @MainActor () -> Void
    let selectErase: @MainActor () -> Void
    let canUndo: Bool
    let canRedo: Bool
    let canEdit: Bool
}

private struct EditorCommandActionsKey: FocusedValueKey {
    typealias Value = EditorCommandActions
}

extension FocusedValues {
    var editorCommandActions: EditorCommandActions? {
        get { self[EditorCommandActionsKey.self] }
        set { self[EditorCommandActionsKey.self] = newValue }
    }
}

struct EditorFocusedCommands: Commands {
    @FocusedValue(\.editorCommandActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                actions?.undo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(actions?.canUndo != true)

            Button("Redo") {
                actions?.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(actions?.canRedo != true)
        }

        CommandMenu("Canvas") {
            Button("Draw") {
                actions?.selectDraw()
            }
            .keyboardShortcut("b", modifiers: [])
            .disabled(actions?.canEdit != true)

            Button("Erase") {
                actions?.selectErase()
            }
            .keyboardShortcut("e", modifiers: [])
            .disabled(actions?.canEdit != true)

            Divider()

            Button("Clear") {
                actions?.clear()
            }
            .keyboardShortcut("0", modifiers: [])
            .disabled(actions?.canEdit != true)
        }
    }
}
#endif
