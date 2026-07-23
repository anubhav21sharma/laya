import CShaderTypes
import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

private func materialRecipe(
    id: String,
    shape: BrushShapeDescriptor = .hardRound,
    grain: BrushGrainDescriptor = .opaque,
    coordinateMode: BrushGrainCoordinateMode = .canonical,
    grainTransform: BrushGrainTransform = .identity,
    material: BrushMaterial = .ink,
    opacity: Float = 1
) throws -> BrushRecipe {
    try BrushRecipe(
        id: BrushRecipeID(id),
        shape: shape,
        grain: grain,
        grainCoordinateMode: coordinateMode,
        grainTransform: grainTransform,
        material: material,
        strokeOpacity: opacity
    )
}

@Test
func footprintSymmetryAccountsForShapeAndGrainFrame() throws {
    let fixtures: [
        (
            shape: BrushShapeDescriptor,
            grain: BrushGrainDescriptor,
            mode: BrushGrainCoordinateMode,
            expected: FootprintCoverageSymmetry
        )
    ] = [
        (.hardRound, .opaque, .brushLocal, .halfTurnInvariant),
        (.softRound, .paper, .canonical, .halfTurnInvariant),
        (.hardRound, .paper, .brushLocal, .oriented),
        (.hardRound, .noise, .brushLocal, .oriented),
        (
            .hardRound,
            .asset("builtin.grain.opaque"),
            .brushLocal,
            .halfTurnInvariant
        ),
        (
            .hardRound,
            .asset("builtin.grain.paper"),
            .brushLocal,
            .oriented
        ),
        (.chisel, .opaque, .canonical, .oriented),
        (
            .asset("builtin.shape.chisel"),
            .opaque,
            .canonical,
            .oriented
        ),
    ]

    for (index, fixture) in fixtures.enumerated() {
        let recipe = try materialRecipe(
            id: "test.symmetry.\(index)",
            shape: fixture.shape,
            grain: fixture.grain,
            coordinateMode: fixture.mode
        )
        #expect(recipe.footprintCoverageSymmetry == fixture.expected)
    }
}

@Test
func materialUniformsPackEverySelectorAndBoundedValue() throws {
    let wash = BrushMaterial(
        family: .boundedWash,
        strength: 0.6,
        wetness: 0.8,
        bleedRadius: 12,
        softenPasses: 2,
        accumulationLimit: 0.7
    )
    let recipe = try materialRecipe(
        id: "test.material.uniforms",
        shape: .chisel,
        grain: .paper,
        coordinateMode: .brushLocal,
        grainTransform: BrushGrainTransform(
            scale: 1,
            rotation: 0.35,
            offset: .zero
        ),
        material: wash,
        opacity: 0.65
    )
    let state = BrushMaterialState(recipe: recipe)
    let uniforms = state.uniforms

    #expect(uniforms.materialFamily == PatternMaterialWireBoundedWash)
    #expect(uniforms.grainCoordinateMode == PatternGrainCoordinateWireBrushLocal)
    #expect(uniforms.strokeOpacity == 0.65)
    #expect(uniforms.materialStrength == 0.6)
    #expect(uniforms.wetness == 0.8)
    #expect(uniforms.bleedRadius == 12)
    #expect(uniforms.softenPasses == 2)
    #expect(uniforms.accumulationLimit == 0.7)
    #expect(uniforms.shapeKind == PatternShapeWireChisel)
    #expect(uniforms.grainKind == PatternGrainWirePaper)
    #expect(uniforms.grainRotation == 0.35)
    #expect(uniforms.padding1 == 0)
}

@Test
func coverageOracleDistinguishesHardSoftAndDirectionalShapes() {
    let center = SIMD2<Float>(0, 0)
    let nearEdge = SIMD2<Float>(0.8, 0)
    let chiselOutside = SIMD2<Float>(0.7, -0.7)

    #expect(
        BrushCoverageOracle.shapeCoverage(
            .hardRound,
            brushLocal: nearEdge,
            hardness: 1,
            radius: 10
        ) == 1
    )
    let soft = BrushCoverageOracle.shapeCoverage(
        .softRound,
        brushLocal: nearEdge,
        hardness: 1,
        radius: 10
    )
    #expect(soft > 0 && soft < 0.25)
    #expect(
        BrushCoverageOracle.shapeCoverage(
            .chisel,
            brushLocal: center,
            hardness: 1,
            radius: 10
        ) > 0
    )
    #expect(
        BrushCoverageOracle.shapeCoverage(
            .chisel,
            brushLocal: chiselOutside,
            hardness: 1,
            radius: 10
        ) == 0
    )
}

@Test
func coverageOracleResolvesEverySupportedAssetLikeItsNamedDescriptor() {
    let shapePairs: [(BrushShapeDescriptor, BrushShapeDescriptor)] = [
        (.hardRound, .asset(BrushTextureIdentity.hardRoundShape.rawValue)),
        (.softRound, .asset(BrushTextureIdentity.softRoundShape.rawValue)),
        (.chisel, .asset(BrushTextureIdentity.chiselShape.rawValue)),
    ]
    let probes = [SIMD2<Float>(0, 0), SIMD2(0.31, -0.2), SIMD2(0.8, 0)]
    for (named, asset) in shapePairs {
        for probe in probes {
            for hardness: Float in [0.35, 1] {
                let namedCoverage = BrushCoverageOracle.shapeCoverage(
                    named,
                    brushLocal: probe,
                    hardness: hardness,
                    radius: 12
                )
                let assetCoverage = BrushCoverageOracle.shapeCoverage(
                    asset,
                    brushLocal: probe,
                    hardness: hardness,
                    radius: 12
                )
                #expect(abs(namedCoverage - assetCoverage) < 0.000_001)
            }
        }
    }

    let grainPairs: [(BrushGrainDescriptor, BrushGrainDescriptor)] = [
        (.opaque, .asset(BrushTextureIdentity.opaqueGrain.rawValue)),
        (.paper, .asset(BrushTextureIdentity.paperGrain.rawValue)),
        (.noise, .asset(BrushTextureIdentity.noiseGrain.rawValue)),
    ]
    for (named, asset) in grainPairs {
        let coordinate = SIMD2<Float>(0.173, -1.294)
        #expect(abs(
            BrushCoverageOracle.grainCoverage(named, coordinate: coordinate)
                - BrushCoverageOracle.grainCoverage(asset, coordinate: coordinate)
        ) < 0.000_001)
    }
}

@Test
func hardRoundOracleMatchesShaderSoftnessAndPixelAntialiasing() {
    let softened = BrushCoverageOracle.shapeCoverage(
        .hardRound,
        brushLocal: SIMD2<Float>(0.9, 0),
        hardness: 0.5,
        radius: 10
    )
    let antialiasedEdge = BrushCoverageOracle.shapeCoverage(
        .hardRound,
        brushLocal: SIMD2<Float>(1.02, 0),
        hardness: 1,
        radius: 10
    )

    #expect(abs(softened - 0.5) < 0.000_001)
    #expect(abs(antialiasedEdge - 0.3) < 0.000_01)
}

@Test
func grainOracleUsesShaderEquivalentLinearRepeatSampling() {
    let size = BrushTextureFactory.textureSize
    let x = 10
    let y = 7
    let coordinate = SIMD2<Float>(
        Float(x + 1) / Float(size),
        (Float(y) + 0.5) / Float(size)
    )
    let left = Float(BrushTextureFactory.referenceTexel(
        identity: .paperGrain,
        x: x,
        y: y
    )) / 255
    let right = Float(BrushTextureFactory.referenceTexel(
        identity: .paperGrain,
        x: x + 1,
        y: y
    )) / 255

    let sampled = BrushCoverageOracle.grainCoverage(
        .paper,
        coordinate: coordinate
    )

    #expect(abs(sampled - (left + right) * 0.5) < 0.000_001)
}

@Test
func coverageOracleAppliesResolvedFallbackTextureWithoutLosingSelectorSemantics() throws {
    let recipe = try materialRecipe(
        id: "test.material.resolved-fallback",
        shape: .asset(BrushTextureIdentity.softRoundShape.rawValue)
    )
    let local = SIMD2<Float>(0.76, 0.12)

    let requestedCoverage = BrushCoverageOracle.coverage(
        recipe: recipe,
        brushLocal: local,
        canonical: .zero,
        hardness: 1,
        radius: 12,
        grainScale: 1,
        grainOffset: .zero
    )
    let fallbackCoverage = BrushCoverageOracle.coverage(
        recipe: recipe,
        brushLocal: local,
        canonical: .zero,
        hardness: 1,
        radius: 12,
        grainScale: 1,
        grainOffset: .zero,
        resolvedShapeIdentity: .hardRoundShape
    )
    let expectedFallback = BrushCoverageOracle.shapeCoverage(
        .softRound,
        brushLocal: local,
        hardness: 1,
        radius: 12,
        resolvedTextureIdentity: .hardRoundShape
    )

    #expect(fallbackCoverage == expectedFallback)
    #expect(fallbackCoverage != requestedCoverage)
}

@Test
func boundedWashOracleMatchesShaderCoverageModifiers() throws {
    let material = BrushMaterial(
        family: .boundedWash,
        strength: 0.7,
        wetness: 0.8,
        bleedRadius: 8,
        softenPasses: 1,
        accumulationLimit: 0.7
    )
    let recipe = try materialRecipe(
        id: "test.material.wash-oracle",
        shape: .softRound,
        grain: .paper,
        material: material
    )
    let brushLocal = SIMD2<Float>(0.44, -0.2)
    let canonical = SIMD2<Float>(21.25, 9.75)
    let shape = BrushCoverageOracle.shapeCoverage(
        .softRound,
        brushLocal: brushLocal,
        hardness: 0.8,
        radius: 16
    )
    let grain = BrushCoverageOracle.grainCoverage(
        .paper,
        coordinate: canonical / Float(BrushTextureFactory.textureSize)
    )
    let expected = pow(shape, 0.72) * (grain + (1 - grain) * 0.36)

    let actual = BrushCoverageOracle.coverage(
        recipe: recipe,
        brushLocal: brushLocal,
        canonical: canonical,
        hardness: 0.8,
        radius: 16,
        grainScale: 1,
        grainOffset: .zero
    )

    #expect(abs(actual - expected) < 0.000_001)
}

@Test
func grainOracleIsDeterministicAndCoordinateModesAreContinuous() throws {
    let canonicalRecipe = try materialRecipe(
        id: "test.material.canonical",
        grain: .paper,
        coordinateMode: .canonical
    )
    let localRecipe = try materialRecipe(
        id: "test.material.local",
        grain: .noise,
        coordinateMode: .brushLocal
    )
    let canonical = SIMD2<Float>(81.25, 39.5)
    let local = SIMD2<Float>(0.2, -0.4)

    let canonicalFirst = BrushCoverageOracle.coverage(
        recipe: canonicalRecipe,
        brushLocal: local,
        canonical: canonical,
        hardness: 1,
        radius: 10,
        grainScale: 1.5,
        grainOffset: SIMD2(0.1, 0.2)
    )
    let canonicalSecond = BrushCoverageOracle.coverage(
        recipe: canonicalRecipe,
        brushLocal: SIMD2(-0.3, 0.1),
        canonical: canonical,
        hardness: 1,
        radius: 10,
        grainScale: 1.5,
        grainOffset: SIMD2(0.1, 0.2)
    )
    #expect(canonicalFirst == canonicalSecond)

    let localFirst = BrushCoverageOracle.coverage(
        recipe: localRecipe,
        brushLocal: local,
        canonical: canonical,
        hardness: 1,
        radius: 10,
        grainScale: 0.75,
        grainOffset: .zero
    )
    let localSecond = BrushCoverageOracle.coverage(
        recipe: localRecipe,
        brushLocal: local,
        canonical: canonical + SIMD2(256, -128),
        hardness: 1,
        radius: 10,
        grainScale: 0.75,
        grainOffset: .zero
    )
    #expect(localFirst == localSecond)
    #expect(localFirst != canonicalFirst)
}

@Test
func grainTransformRotationChangesTheSampledCoordinateDeterministically() throws {
    let unrotated = try materialRecipe(
        id: "test.material.grain-unrotated",
        grain: .paper
    )
    let rotated = try materialRecipe(
        id: "test.material.grain-rotated",
        grain: .paper,
        grainTransform: BrushGrainTransform(
            scale: 1,
            rotation: .pi / 2,
            offset: .zero
        )
    )
    let brushLocal = SIMD2<Float>(0.1, -0.2)
    let canonical = SIMD2<Float>(81.25, 39.5)

    let first = BrushCoverageOracle.coverage(
        recipe: rotated,
        brushLocal: brushLocal,
        canonical: canonical,
        hardness: 1,
        radius: 10,
        grainScale: 1,
        grainOffset: .zero
    )
    let second = BrushCoverageOracle.coverage(
        recipe: rotated,
        brushLocal: brushLocal,
        canonical: canonical,
        hardness: 1,
        radius: 10,
        grainScale: 1,
        grainOffset: .zero
    )
    let control = BrushCoverageOracle.coverage(
        recipe: unrotated,
        brushLocal: brushLocal,
        canonical: canonical,
        hardness: 1,
        radius: 10,
        grainScale: 1,
        grainOffset: .zero
    )

    #expect(first == second)
    #expect(first != control)
}

@Test
@MainActor
func inkAndDryRecipesProduceDistinctDeterministicPixels() throws {
    guard let firstInk = try renderMaterialRecipe(.legacyEquivalent),
          let secondInk = try renderMaterialRecipe(.legacyEquivalent)
    else { return }
    let dry = try materialRecipe(
        id: "test.material.dry-render",
        grain: .paper,
        material: BrushMaterial(
            family: .dry,
            strength: 0.85,
            wetness: 0,
            bleedRadius: 0,
            softenPasses: 0,
            accumulationLimit: 1
        )
    )
    let dryBytes = try #require(try renderMaterialRecipe(dry))

    #expect(firstInk == secondInk)
    #expect(firstInk != dryBytes)
    #expect(firstInk.contains { $0 != 0 })
    #expect(dryBytes.contains { $0 != 0 })
}

@Test
func strokeOpacityScalesTheAccumulatedPremultipliedLayerExactlyOnce() {
    let redDab = SIMD4<Float>(0.2, 0, 0, 0.2)
    let accumulated = BrushLayerCompositor.sourceOver(redDab, redDab)
    let white = SIMD4<Float>(1, 1, 1, 1)
    let correct = BrushLayerCompositor.composite(
        livePremultiplied: accumulated,
        canonicalPremultiplied: white,
        strokeOpacity: 0.5,
        compositeMode: .draw
    )

    let prematurelyScaled = redDab * 0.5
    let negativeControlLayer = BrushLayerCompositor.sourceOver(
        prematurelyScaled,
        prematurelyScaled
    )
    let negativeControl = BrushLayerCompositor.composite(
        livePremultiplied: negativeControlLayer,
        canonicalPremultiplied: white,
        strokeOpacity: 1,
        compositeMode: .draw
    )

    #expect(correct != negativeControl)
    #expect(abs(correct.w - 1) < 0.0001)
    #expect(correct.y > negativeControl.y)
}

@Test
func eraserStrengthAndStrokeOpacityRemainIndependent() {
    let canonical = SIMD4<Float>(0.3, 0.2, 0.1, 0.5)
    let eraserLayer = SIMD4<Float>(0, 0, 0, 0.4)
    let half = BrushLayerCompositor.composite(
        livePremultiplied: eraserLayer,
        canonicalPremultiplied: canonical,
        strokeOpacity: 0.25,
        compositeMode: .erase,
        eraserStrength: 0.5
    )
    let full = BrushLayerCompositor.composite(
        livePremultiplied: eraserLayer,
        canonicalPremultiplied: canonical,
        strokeOpacity: 0.25,
        compositeMode: .erase,
        eraserStrength: 1
    )
    #expect(half == canonical * 0.8)
    #expect(full == canonical * 0.6)
}

@Test
func accumulationLimitClampsCombinedLiveLayerBeforeCompositing() {
    let settled = SIMD4<Float>(0.6, 0, 0, 0.6)
    let replay = SIMD4<Float>(0.6, 0, 0, 0.6)
    let combined = BrushLayerCompositor.sourceOver(replay, settled)

    let result = BrushLayerCompositor.composite(
        livePremultiplied: combined,
        canonicalPremultiplied: .zero,
        strokeOpacity: 1,
        compositeMode: .draw,
        accumulationLimit: 0.7
    )

    #expect(abs(combined.w - 0.84) < 0.0001)
    #expect(abs(result.w - 0.7) < 0.0001)
    #expect(abs(result.x - 0.7) < 0.0001)
}

@Test
func eraserStrengthAppliesOnceAfterDabCoverageHasAccumulated() {
    let canonical = SIMD4<Float>(0.3, 0.2, 0.1, 0.5)
    let fullyCoveredLiveLayer = SIMD4<Float>(0, 0, 0, 1)

    let result = BrushLayerCompositor.composite(
        livePremultiplied: fullyCoveredLiveLayer,
        canonicalPremultiplied: canonical,
        strokeOpacity: 0.1,
        compositeMode: .erase,
        eraserStrength: 0.5
    )

    #expect(result == canonical * 0.5)
}

@MainActor
private func renderMaterialRecipe(
    _ recipe: BrushRecipe
) throws -> [UInt8]? {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let shader = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/MetalRenderer/Shaders.metal"
        ),
        encoding: .utf8
    )
    let header = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/CShaderTypes/include/ShaderTypes.h"
        ),
        encoding: .utf8
    )
    let library = try device.makeLibrary(
        source: shader.replacingOccurrences(
            of: "#include \"ShaderTypes.h\"",
            with: header
        ),
        options: nil
    )
    let renderer = try GridRenderer(
        device: device,
        library: library,
        drawableSize: PatternSize(width: 64, height: 64),
        configuration: TilingCanvasConfiguration(
            pixelSize: PixelSize(width: 64, height: 64),
            tiling: .grid
        )
    )
    let token = RendererOperationToken(rawValue: 91)
    try renderer.beginStroke(
        token: token,
        sample: .mouse(
            position: ScreenPoint(x: 32, y: 32),
            timestamp: 0,
            phase: .began
        ),
        style: StrokeRenderStyle(
            color: .black,
            diameter: 24,
            compositeMode: .draw,
            eraserStrength: 1,
            recipe: recipe,
            seed: 77
        )
    )
    _ = try renderer.flushPendingLiveForHarness()
    let display = try renderer.renderOffscreenDisplayForHarness(
        width: 64,
        height: 64,
        showGridLines: false
    )
    let bytes = materialTextureBytes(display.texture)
    try renderer.cancelStroke(token: token)
    return bytes
}

private func materialTextureBytes(_ texture: any MTLTexture) -> [UInt8] {
    let bytesPerRow = texture.width * 4
    var bytes = [UInt8](
        repeating: 0,
        count: bytesPerRow * texture.height
    )
    bytes.withUnsafeMutableBytes { storage in
        texture.getBytes(
            storage.baseAddress!,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
    }
    return bytes
}
