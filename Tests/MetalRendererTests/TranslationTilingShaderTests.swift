import Foundation
import Testing

@Suite("Translation tiling shader")
struct TranslationTilingShaderTests {
    @Test
    func halfDropAndBrickUseApprovedPhaseSigns() throws {
        let source = try normalizedShaderSource()

        #expect(source.contains(
            "if (all(repeatSize == tileSize)) { const int column = int(floor(world.x / tileSize.x)); const float phaseY = (column & 1) * tileSize.y * 0.5; const float2 folded = patternPositiveFold( float2(world.x, world.y - phaseY), tileSize );"
        ))
        #expect(source.contains(
            "if (all(repeatSize == tileSize)) { const int row = int(floor(world.y / tileSize.y)); const float phaseX = (row & 1) * tileSize.x * 0.5; const float2 folded = patternPositiveFold( float2(world.x - phaseX, world.y), tileSize );"
        ))
        #expect(source.contains(
            "const int column = int(floor(lattice.x)); const float phaseY = (column & 1) * 0.5; const float2 foldedUnit = patternPositiveFold( float2(lattice.x, lattice.y - phaseY), float2(1.0) );"
        ))
        #expect(source.contains(
            "const int row = int(floor(lattice.y)); const float phaseX = (row & 1) * 0.5; const float2 foldedUnit = patternPositiveFold( float2(lattice.x - phaseX, lattice.y), float2(1.0) );"
        ))
    }

    @Test
    func legacyRasterSizedRepeatsRetainTheOriginalDisplayArithmetic() throws {
        let source = try normalizedShaderSource()

        #expect(
            source.components(
                separatedBy: "if (all(repeatSize == tileSize))"
            ).count == 5
        )
        #expect(source.contains(
            "const float2 folded = patternPositiveFold(world, tileSize); return {folded, folded, true};"
        ))
        #expect(source.contains(
            "patternPositiveFold( tileSize.x - local.x, tileSize.x )"
        ))
        #expect(source.contains(
            "patternPositiveFold( tileSize.y - local.y, tileSize.y )"
        ))
    }

    @Test
    func gridLinesUseTheSelectedCellsPhasedLocalCoordinates() throws {
        let source = try normalizedShaderSource()

        #expect(source.contains("mapping.phasedCellLocal"))
        #expect(source.contains(
            "const float2 edgeDistance = min( mapping.phasedCellLocal, frame.repeatSize - mapping.phasedCellLocal );"
        ))
    }

    @Test
    func fragmentPassesSymmetryFamilyIntoDisplayMapping() throws {
        let source = try normalizedShaderSource()

        #expect(source.contains(
            "const PatternDisplayMapping mapping = patternDisplayMapping( world, frame.tileSize, frame.repeatSize, frame.latticeXAxis, frame.latticeYAxis, frame.latticeTranslation, frame.symmetryFamily, frame.tilingKind );"
        ))
    }

    @Test
    func squareDisplayUsesCompiledLatticeAndDedicatedGuides() throws {
        let source = try normalizedShaderSource()

        #expect(source.contains(
            "const float2 lattice = latticeXAxis * world.x + latticeYAxis * world.y + latticeTranslation;"
        ))
        #expect(source.contains("case PatternTilingWireSquareRotation:"))
        #expect(source.contains("case PatternTilingWireSquareKaleidoscope:"))
        #expect(source.contains(
            "frame.guideKind == PatternGuideWireSquareRotation"
        ))
        #expect(source.contains(
            "frame.guideKind == PatternGuideWireSquareKaleidoscope"
        ))
        #expect(source.contains("const float cornerRingDistance"))
        #expect(source.contains("const float centerRingDistance"))
        #expect(source.contains("const float edgeCenterRingDistance"))
        #expect(source.contains(
            "abs(centerRelative.x - centerRelative.y)"
        ))
        #expect(source.contains(
            "abs(centerRelative.x + centerRelative.y)"
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
