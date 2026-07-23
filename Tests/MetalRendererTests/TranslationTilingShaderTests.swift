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

    @Test
    func fragmentPassesSymmetryFamilyIntoDisplayMapping() throws {
        let source = try normalizedShaderSource()

        #expect(source.contains(
            "const PatternDisplayMapping mapping = patternDisplayMapping( world, frame.tileSize, frame.symmetryFamily, frame.tilingKind );"
        ))
    }

    @Test
    func displayCompositesNeighborsBeforeBilinearFiltering() throws {
        let source = try normalizedShaderSource()

        #expect(source.contains(
            "static float4 patternCompositeLive( float4 settledLive, float4 replayLive, float4 canonical, uint compositeMode, float strokeOpacity, float accumulationLimit, float eraserStrength )"
        ))
        #expect(source.contains(
            "static float4 patternCompositeThenBilinearSample( texture2d<float> canonical, texture2d<float> settledLive, texture2d<float> replayLive, float2 canonicalPixel, uint compositeMode, uint liveVisible, float strokeOpacity, float accumulationLimit, float eraserStrength )"
        ))
        #expect(source.contains(
            "const float4 composite00 = patternCompositeLive( live00, replay00, canonical.read(texel00), compositeMode, strokeOpacity, accumulationLimit, eraserStrength );"
        ))
        #expect(source.contains(
            "float4 result = patternCompositeThenBilinearSample( canonical, live, replayLive, mapping.canonicalPixel, frame.compositeMode, frame.liveVisible, material.strokeOpacity, material.accumulationLimit, material.materialStrength );"
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
