import EditorCore
import PatternEngine
import Testing

@Test
func brushConfigurationUsesExactDefaultsAndTileDependentMaximum() {
    #expect(EditorConfiguration.defaultBrushDiameter == 20)
    #expect(EditorConfiguration.minimumBrushDiameter == 2)
    #expect(EditorConfiguration.maximumBrushDiameter == 2_000)
    #expect(
        EditorConfiguration.brushMaximum(
            for: PixelSize(width: 64, height: 512)
        ) == 512
    )
    #expect(
        EditorConfiguration.brushMaximum(
            for: PixelSize(width: 512, height: 512)
        ) == 2_000
    )
}

@Test
func brushStepsRoundGeometricallyAndClamp() {
    let smallTile = PixelSize(width: 64, height: 128)

    #expect(
        EditorConfiguration.stepBrush(
            20,
            larger: true,
            pixelSize: smallTile
        ) == 25
    )
    #expect(
        EditorConfiguration.stepBrush(
            20,
            larger: false,
            pixelSize: smallTile
        ) == 16
    )
    #expect(
        EditorConfiguration.stepBrush(
            500,
            larger: true,
            pixelSize: smallTile
        ) == 512
    )
    #expect(
        EditorConfiguration.stepBrush(
            2,
            larger: false,
            pixelSize: smallTile
        ) == 2
    )
}

@Test
func tileStepsPreserveRectangularDifferenceAndClampEachDimension() {
    #expect(
        EditorConfiguration.stepTile(
            PixelSize(width: 256, height: 320),
            larger: true
        ) == PixelSize(width: 288, height: 352)
    )
    #expect(
        EditorConfiguration.stepTile(
            PixelSize(width: 64, height: 4_096),
            larger: false
        ) == PixelSize(width: 64, height: 4_064)
    )
    #expect(
        EditorConfiguration.stepTile(
            PixelSize(width: 64, height: 4_096),
            larger: true
        ) == PixelSize(width: 96, height: 4_096)
    )
}
