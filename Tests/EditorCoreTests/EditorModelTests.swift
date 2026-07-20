import EditorCore
import PatternEngine
import Testing

@MainActor
@Test
func editorModelDefaultsToGrid() {
    let model = EditorModel()

    #expect(model.tiling == .grid)
}

@MainActor
@Test
func editorModelChangesOnlyAfterTilingConfirmation() {
    let model = EditorModel(tiling: .halfDrop)

    #expect(model.tiling == .halfDrop)

    model.confirmTiling(.mirrorXY)

    #expect(model.tiling == .mirrorXY)
}
