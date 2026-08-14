import CShaderTypes
import Testing
@testable import MetalRenderer
@testable import PatternEngine

@Suite("Canvas display output mapping")
struct CanvasDisplayOutputMappingTests {
    @Test
    func periodicFactoryCarriesTheCompilerFoldAndViewportTransform() throws {
        let raster = PixelSize(width: 384, height: 256)
        let configuration = PeriodicSymmetryConfiguration(
            presetID: .halfDrop,
            repeatSize: PatternSize(width: 173.5, height: 219.25),
            orientationRadians: 0
        )
        let strategy = try TilingStrategy(
            configuration: configuration,
            canonicalRasterSize: raster
        )
        let viewport = ViewportTransform(
            drawableSize: PatternSize(width: 800, height: 600),
            worldCenter: WorldPoint(x: -37.25, y: 91.5),
            zoom: 2
        )

        let mapping = try CanvasDisplayOutputMapping.make(
            viewport: viewport,
            strategy: strategy,
            outputPixelSize: PixelSize(width: 640, height: 480)
        )

        guard case let .periodic(periodic) = mapping else {
            Issue.record("periodic canvas must use the compiled periodic fold")
            return
        }
        #expect(periodic.fold == strategy.compiledSymmetry.domain.periodic?.displayFold)
        #expect(periodic.outputToWorldTransform == SparseTileOutputToSourceTransform(
            sourceOffset: SIMD2(-197.25, -28.5),
            sourceStep: SIMD2(repeating: 0.5)
        ))
    }

    @Test
    func finiteAndRadialFactoriesPreserveTheirExistingMappings() throws {
        let outputSize = PixelSize(width: 320, height: 240)
        let viewport = ViewportTransform(
            drawableSize: PatternSize(width: 320, height: 240),
            worldCenter: WorldPoint(x: 160, y: 120),
            zoom: 1
        )
        let plain = try TilingStrategy(
            finiteConfiguration: .plain,
            canvasSize: outputSize
        )
        #expect(try CanvasDisplayOutputMapping.make(
            viewport: viewport,
            strategy: plain,
            outputPixelSize: outputSize
        ) == .affine(.identity))

        let radial = try TilingStrategy(
            finiteConfiguration: .radial(RadialSymmetryConfiguration(
                kind: .mandala,
                rayCount: 6,
                center: WorldPoint(x: 151.5, y: 117.25),
                referenceAngleRadians: 0.2
            )),
            canvasSize: outputSize
        )
        let radialMapping = try CanvasDisplayOutputMapping.make(
            viewport: viewport,
            strategy: radial,
            outputPixelSize: outputSize
        )
        guard case let .finiteRadial(value) = radialMapping else {
            Issue.record("radial canvas mapping regressed")
            return
        }
        #expect(value.strategy == radial)
        #expect(value.outputToWorldTransform == .identity)
    }

    @Test
    func periodicIdentityAndHashIncludeEveryFoldAndOutputScalar() {
        let baseFold = makeFold()
        let base = SparseTilePeriodicOutputMapping(
            fold: baseFold,
            outputToWorldTransform: .init(
                sourceOffset: SIMD2(7.25, -11.5),
                sourceStep: SIMD2(0.75, 0.75)
            )
        )
        let variants = foldVariants(of: baseFold).map {
            SparseTilePeriodicOutputMapping(
                fold: $0,
                outputToWorldTransform: base.outputToWorldTransform
            )
        } + [
            SparseTilePeriodicOutputMapping(
                fold: baseFold,
                outputToWorldTransform: .init(
                    sourceOffset: SIMD2(7.5, -11.5),
                    sourceStep: SIMD2(0.75, 0.75)
                )
            ),
            SparseTilePeriodicOutputMapping(
                fold: baseFold,
                outputToWorldTransform: .init(
                    sourceOffset: SIMD2(7.25, -11.25),
                    sourceStep: SIMD2(0.75, 0.75)
                )
            ),
            SparseTilePeriodicOutputMapping(
                fold: baseFold,
                outputToWorldTransform: .init(
                    sourceOffset: SIMD2(7.25, -11.5),
                    sourceStep: SIMD2(0.5, 0.75)
                )
            ),
            SparseTilePeriodicOutputMapping(
                fold: baseFold,
                outputToWorldTransform: .init(
                    sourceOffset: SIMD2(7.25, -11.5),
                    sourceStep: SIMD2(0.75, 0.5)
                )
            ),
            SparseTilePeriodicOutputMapping(
                fold: baseFold,
                outputToWorldTransform: base.outputToWorldTransform,
                screenPixelOffset: SIMD2(1, 0)
            ),
            SparseTilePeriodicOutputMapping(
                fold: baseFold,
                outputToWorldTransform: base.outputToWorldTransform,
                screenPixelOffset: SIMD2(0, 1)
            ),
        ]

        #expect(variants.allSatisfy { $0 != base })
        #expect(Set([base] + variants).count == variants.count + 1)
        let baseMapping = SparseTileSamplingOutputMapping.periodic(base)
        #expect(baseMapping.kind == .periodic)
        #expect(Set([.affine(.identity), baseMapping]).count == 2)
    }

    @Test
    func phaseProgramsBeyondTheSupportedABICountFailClosed() throws {
        let unsupported = makeFold(phase: PeriodicPhaseProgram(
            indexAxis: .x,
            offsetAxis: .y,
            fractions: [0, 0.25, 0.5]
        ))
        #expect(throws: SparseTileSamplingPlanError.inconsistentAddressing) {
            _ = try PatternPeriodicDisplayFoldUniforms(validating: unsupported)
        }
    }
}

private func makeFold(
    family: SymmetryKernelFamily = .rectangular,
    coordinateSpace: CompiledPeriodicFoldCoordinateSpace = .axisAlignedRepeat,
    worldToLattice: Affine2D = Affine2D(
        xAxis: SIMD2(0.75, 0.125),
        yAxis: SIMD2(-0.25, 1.25),
        translation: SIMD2(3.5, -7.25)
    ),
    canonicalSize: PatternSize = PatternSize(width: 512, height: 384),
    repeatSize: PatternSize = PatternSize(width: 173.5, height: 219.25),
    phase: PeriodicPhaseProgram? = PeriodicPhaseProgram(
        indexAxis: .x,
        offsetAxis: .y,
        fractions: [0.125, 0.625]
    ),
    reflections: SymmetryReflectionAxes = [.x, .y]
) -> CompiledPeriodicDisplayFold {
    CompiledPeriodicDisplayFold(
        family: family,
        coordinateSpace: coordinateSpace,
        worldToLattice: worldToLattice,
        canonicalSize: canonicalSize,
        repeatSize: repeatSize,
        phase: phase,
        alternatingReflections: reflections
    )
}

private func foldVariants(
    of fold: CompiledPeriodicDisplayFold
) -> [CompiledPeriodicDisplayFold] {
    let phase = fold.phase!
    return [
        makeFold(family: .triangular),
        makeFold(coordinateSpace: .unitLattice),
        makeFold(worldToLattice: Affine2D(
            xAxis: SIMD2(0.5, fold.worldToLattice.xAxis.y),
            yAxis: fold.worldToLattice.yAxis,
            translation: fold.worldToLattice.translation
        )),
        makeFold(worldToLattice: Affine2D(
            xAxis: SIMD2(fold.worldToLattice.xAxis.x, 0.25),
            yAxis: fold.worldToLattice.yAxis,
            translation: fold.worldToLattice.translation
        )),
        makeFold(worldToLattice: Affine2D(
            xAxis: fold.worldToLattice.xAxis,
            yAxis: SIMD2(-0.5, fold.worldToLattice.yAxis.y),
            translation: fold.worldToLattice.translation
        )),
        makeFold(worldToLattice: Affine2D(
            xAxis: fold.worldToLattice.xAxis,
            yAxis: SIMD2(fold.worldToLattice.yAxis.x, 1.5),
            translation: fold.worldToLattice.translation
        )),
        makeFold(worldToLattice: Affine2D(
            xAxis: fold.worldToLattice.xAxis,
            yAxis: fold.worldToLattice.yAxis,
            translation: SIMD2(3.75, fold.worldToLattice.translation.y)
        )),
        makeFold(worldToLattice: Affine2D(
            xAxis: fold.worldToLattice.xAxis,
            yAxis: fold.worldToLattice.yAxis,
            translation: SIMD2(fold.worldToLattice.translation.x, -7)
        )),
        makeFold(canonicalSize: PatternSize(width: 640, height: 384)),
        makeFold(canonicalSize: PatternSize(width: 512, height: 448)),
        makeFold(repeatSize: PatternSize(width: 181, height: 219.25)),
        makeFold(repeatSize: PatternSize(width: 173.5, height: 227)),
        makeFold(phase: nil),
        makeFold(phase: PeriodicPhaseProgram(
            indexAxis: .y,
            offsetAxis: phase.offsetAxis,
            fractions: phase.fractions
        )),
        makeFold(phase: PeriodicPhaseProgram(
            indexAxis: phase.indexAxis,
            offsetAxis: .x,
            fractions: phase.fractions
        )),
        makeFold(phase: PeriodicPhaseProgram(
            indexAxis: phase.indexAxis,
            offsetAxis: phase.offsetAxis,
            fractions: [0.25, phase.fractions[1]]
        )),
        makeFold(phase: PeriodicPhaseProgram(
            indexAxis: phase.indexAxis,
            offsetAxis: phase.offsetAxis,
            fractions: [phase.fractions[0], 0.75]
        )),
        makeFold(reflections: [.x]),
    ]
}
