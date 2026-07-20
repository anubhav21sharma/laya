import Foundation
import Testing

@Suite("Translation tiling shader")
struct TranslationTilingShaderTests {
    @Test
    func halfDropAndBrickUseApprovedPhaseSigns() throws {
        let source = try normalizedShaderSource()

        #expect(source.contains(
            "case PatternTilingWireHalfDrop: { const int column = int(floor(world.x / tileSize.x)); const float phaseY = (column & 1) * tileSize.y * 0.5; const float2 folded = patternPositiveFold( float2(world.x, world.y - phaseY), tileSize );"
        ))
        #expect(source.contains(
            "case PatternTilingWireBrick: { const int row = int(floor(world.y / tileSize.y)); const float phaseX = (row & 1) * tileSize.x * 0.5; const float2 folded = patternPositiveFold( float2(world.x - phaseX, world.y), tileSize );"
        ))
    }

    @Test
    func gridLinesUseTheSelectedCellsPhasedLocalCoordinates() throws {
        let source = try normalizedShaderSource()

        #expect(source.contains("mapping.phasedCellLocal"))
        #expect(source.contains(
            "const float2 edgeDistance = min( mapping.phasedCellLocal, frame.tileSize - mapping.phasedCellLocal ) * frame.zoom;"
        ))
    }

    private func normalizedShaderSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/MetalRenderer/Shaders.metal"),
            encoding: .utf8
        ).replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
    }
}
