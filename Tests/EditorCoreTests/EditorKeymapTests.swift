import EditorCore
import Testing

private func shortcut(
    _ rawValue: String,
    modifiers: EditorKeyModifiers = [],
    phase: EditorKeyPhase = .down
) -> EditorShortcut? {
    EditorKeymap.resolve(
        EditorKey(rawValue: rawValue),
        modifiers: modifiers,
        phase: phase
    )
}

@Test
func plainEditorKeysResolveExactly() {
    #expect(shortcut("b") == .selectTool(.draw))
    #expect(shortcut("E") == .selectTool(.erase))
    #expect(shortcut("0") == .clear)
    #expect(shortcut("+") == .stepBrush(larger: true))
    #expect(shortcut("=") == .stepBrush(larger: true))
    #expect(shortcut("-") == .stepBrush(larger: false))
    #expect(shortcut(">") == .stepTile(larger: true))
    #expect(shortcut("<") == .stepTile(larger: false))
    #expect(shortcut("G") == .toggleGrid)
    #expect(shortcut("1") == .selectTiling(index1: 1))
    #expect(shortcut("7") == .selectTiling(index1: 7))
    #expect(shortcut("\u{1B}") == .cancel)
    #expect(shortcut(" ", phase: .down) == .spaceChanged(true))
    #expect(shortcut(" ", phase: .up) == .spaceChanged(false))
}

@Test
func tilingKeysCoverOneThroughSevenOnly() {
    for index in 1...7 {
        #expect(
            shortcut(String(index)) == .selectTiling(index1: index)
        )
    }
    #expect(shortcut("8") == nil)
    #expect(shortcut("9") == nil)
}

@Test
func commandModifiersRouteBeforePlainKeys() {
    #expect(shortcut("z", modifiers: .command) == .undo)
    #expect(
        shortcut("Z", modifiers: [.command, .shift]) == .redo
    )
    #expect(shortcut("b", modifiers: .command) == nil)
    #expect(shortcut("0", modifiers: .command) == nil)
}

@Test
func reservedSliceSevenKeysRemainUnconsumed() {
    #expect(shortcut("s") == nil)
    #expect(shortcut("T") == nil)
    #expect(shortcut("\r") == nil)
    #expect(shortcut("\n") == nil)
}

@Test
func repeatsAndUnrelatedKeyUpEventsDoNotRepeatTransitions() {
    #expect(shortcut(" ", phase: .repeat) == nil)
    #expect(shortcut("b", phase: .repeat) == nil)
    #expect(shortcut("b", phase: .up) == nil)
}
