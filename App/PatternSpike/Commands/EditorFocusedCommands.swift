#if os(macOS)
import SwiftUI

struct EditorCommandActions {
    let undo: @MainActor () -> Void
    let redo: @MainActor () -> Void
    let clear: @MainActor () -> Void
    let selectDraw: @MainActor () -> Void
    let selectErase: @MainActor () -> Void
    let openProject: @MainActor () -> Void
    let saveProject: @MainActor () -> Void
    let canUndo: Bool
    let canRedo: Bool
    let canEdit: Bool
    let canUseFileCommands: Bool
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
        CommandGroup(after: .newItem) {
            Button("Open…") {
                actions?.openProject()
            }
            .keyboardShortcut("o")
            .disabled(actions?.canUseFileCommands != true)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save As…") {
                actions?.saveProject()
            }
            .keyboardShortcut("s")
            .disabled(actions?.canUseFileCommands != true)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                actions?.undo()
            }
            .disabled(actions?.canUndo != true)

            Button("Redo") {
                actions?.redo()
            }
            .disabled(actions?.canRedo != true)
        }

        CommandMenu("Canvas") {
            Button("Draw") {
                actions?.selectDraw()
            }
            .disabled(actions?.canEdit != true)

            Button("Erase") {
                actions?.selectErase()
            }
            .disabled(actions?.canEdit != true)

            Divider()

            Button("Clear") {
                actions?.clear()
            }
            .disabled(actions?.canEdit != true)
        }
    }
}
#endif
