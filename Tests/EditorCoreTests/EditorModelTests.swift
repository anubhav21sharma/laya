import EditorCore
import PatternEngine
import Testing

@MainActor
@Test
func editorModelDefaultsToGrid() {
    let model = EditorModel()

    #expect(model.tool == .draw)
    #expect(model.inkColor == .black)
    #expect(model.brushDiameter == 20)
    #expect(model.eraserStrength == 1)
    #expect(model.showGrid == false)
    #expect(model.tiling == .grid)
    #expect(model.pixelSize == PixelSize(width: 256, height: 256))
    #expect(model.canUndo == false)
    #expect(model.canRedo == false)
    #expect(model.isBusy == false)
}

@MainActor
@Test
func editorModelChangesOnlyAfterTilingConfirmation() {
    let model = EditorModel(tiling: .halfDrop)

    #expect(model.tiling == .halfDrop)

    model.confirmTiling(.mirrorXY)

    #expect(model.tiling == .mirrorXY)
}

@MainActor
@Test
func editorModelChangesCommittedReadStateOnlyThroughConfirmations() {
    let model = EditorModel()
    let color = InkColor(
        red: 0.2,
        green: 0.4,
        blue: 0.6,
        alpha: 0.8
    )!
    let size = PixelSize(width: 512, height: 384)

    model.confirmTool(.erase)
    model.confirmInkColor(color)
    model.confirmBrushDiameter(48)
    model.confirmGridVisibility(true)
    model.confirmTiling(.rotational)
    model.confirmPixelSize(size)
    model.confirmHistoryAvailability(canUndo: true, canRedo: false)
    model.confirmBusy(true)

    #expect(model.tool == .erase)
    #expect(model.inkColor == color)
    #expect(model.brushDiameter == 48)
    #expect(model.eraserStrength == 1)
    #expect(model.showGrid)
    #expect(model.tiling == .rotational)
    #expect(model.pixelSize == size)
    #expect(model.canUndo)
    #expect(!model.canRedo)
    #expect(model.isBusy)
}
