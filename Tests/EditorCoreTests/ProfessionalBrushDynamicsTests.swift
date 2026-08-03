import EditorCore
import Foundation
import PatternEngine
import Testing

@Test
func technicalInkPressureChangesCompiledLogicalDabSizeAndFlow() {
    let light = technicalInkDab(pressure: 0.2, capabilities: [.pressure])
    let heavy = technicalInkDab(pressure: 1, capabilities: [.pressure])

    #expect(abs(light.diameter - 13.76) < 0.000_01)
    #expect(heavy.diameter == 40)
    #expect(abs(light.flow - 0.648) < 0.000_01)
    #expect(heavy.flow == 0.9)
}

@Test
func technicalInkLogicalDabsFollowDirectionWithoutScatter() {
    let horizontal = technicalInkDab(direction: 0)
    let vertical = technicalInkDab(direction: .pi / 2)

    #expect(abs((vertical.rotation - horizontal.rotation) - .pi / 2) < 0.000_01)
    #expect(horizontal.scatter == .zero)
    #expect(vertical.scatter == .zero)
    #expect(horizontal.position == WorldPoint(x: 10, y: 20))
    #expect(vertical.position == WorldPoint(x: 10, y: 20))
}

@Test
func technicalInkMouseFallbackEmitsFiniteUsefulDab() {
    let dab = technicalInkDab(pressure: 0, capabilities: [])

    #expect(dab.diameter == 40)
    #expect(dab.flow == 0.9)
    #expect(dab.diameter.isFinite)
    #expect(dab.flow.isFinite)
    #expect(dab.spacing.isFinite)
}

@Test
func technicalInkReplayIsDeterministicAndDoesNotRequestInteraction() throws {
    let program = ProfessionalBrushCatalog.technicalInk.program
    let trace = StrokeTraceFixtures.professionalPressureRamp
    let first = try ProfessionalBrushCharacterizer.record(
        family: "Ink",
        definitionSemanticHash: String(repeating: "a", count: 64),
        trace: trace,
        program: program
    )
    let repeated = try ProfessionalBrushCharacterizer.record(
        family: "Ink",
        definitionSemanticHash: String(repeating: "a", count: 64),
        trace: trace,
        program: program
    )

    #expect(first == repeated)
    #expect(first.minimumDiameter < first.maximumDiameter)
    #expect(first.minimumFlow < first.maximumFlow)
    #expect(first.maximumScatterMagnitude == 0)
    #expect(program.requestedBackend == .deposition)
}

@Test
func technicalInkCapLeavesCompletedStrokeBodyUnchanged() throws {
    let program = ProfessionalBrushCatalog.technicalInk.program
    var input = BrushInputDeriver()
    var generator = BrushStrokeGenerator(
        program: program,
        nominalDiameter: 40,
        color: .black,
        seed: 91
    )
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 2, height: 2),
        worldCenter: WorldPoint(x: 0, y: 0)
    )
    let began = input.derive(
        technicalInkStrokeSample(x: 0, timestamp: 0, phase: .began),
        viewport: viewport
    )
    let ended = input.derive(
        technicalInkStrokeSample(x: 20, timestamp: 1, phase: .ended),
        viewport: viewport
    )
    let leading = try generator.beginBatch(began)
    let authoritativeTail = try generator.finishBatch(ended)
    let emitted = leading.dabs + authoritativeTail.dabs
    let totalDistance = try #require(emitted.last?.sourceDistance)
    let retapered: [LogicalDab] = emitted.map { dab in
        BrushDynamicsEngine().applyingLegacySchemaV1EndTaper(
            dab,
            totalDistance: totalDistance,
            nominalDiameter: 40,
            program: program
        )
    }
    #expect(program.termination == .cap)
    #expect(program.replayContract.mode == .appendOnly)
    #expect(program.replayContract.limits == nil)
    #expect(authoritativeTail.dabs.last?.sourceDistance == totalDistance)
    #expect(retapered == emitted)
}

@Test
func graphitePressureChangesCompiledLogicalDabSizeFlowAndOpacity() {
    let light = graphitePencilDab(pressure: 0.2, capabilities: [.pressure])
    let heavy = graphitePencilDab(pressure: 1, capabilities: [.pressure])

    #expect(abs(light.diameter - 16) < 0.000_01)
    #expect(abs(light.flow - 0.0784) < 0.000_01)
    #expect(abs(light.strokeOpacity - 0.3168) < 0.000_01)
    #expect(heavy.diameter == 40)
    #expect(heavy.flow == 0.28)
    #expect(heavy.strokeOpacity == 0.88)
}

@Test
func graphiteCompiledDabsMapLowMidAndHighSpeedSpacingAndDirection() {
    let slow = graphitePencilDab(direction: -.pi, velocity: 0)
    let middle = graphitePencilDab(direction: 0, velocity: 50_000)
    let fast = graphitePencilDab(direction: .pi / 2, velocity: 100_000)

    #expect(abs(slow.spacing - 1.87) < 0.000_01)
    #expect(abs(middle.spacing - 2.2) < 0.000_01)
    #expect(abs(fast.spacing - 2.53) < 0.000_01)
    #expect(abs(slow.rotation - 0) < 0.000_01)
    #expect(abs(middle.rotation - .pi) < 0.000_01)
    #expect(abs(fast.rotation - 1.5 * .pi) < 0.000_01)
}

@Test
func graphiteTiltUsesDualGrainsInTheirAuthoredOrderAndCoordinates() throws {
    let upright = graphitePencilDab(
        altitude: .pi / 2,
        capabilities: [.pressure, .altitude]
    )
    let tilted = graphitePencilDab(
        altitude: 0,
        capabilities: [.pressure, .altitude],
        direction: .pi / 2
    )
    let program = graphitePencilProgram()
    let primary = try #require(tilted.primaryGrainToWorld)
    let secondary = try #require(tilted.secondaryGrainToWorld)

    #expect(program.requiredCapabilities == [.dualGrain])
    #expect(program.definition.coverage.grains.map(\.grain) == [
        .asset("builtin.grain.graphite"),
        .asset("builtin.grain.paper"),
    ])
    #expect(abs(upright.hardness - 0.648) < 0.000_01)
    #expect(abs(tilted.hardness - 0.252) < 0.000_01)
    #expect(abs(upright.grainScale - 0.75) < 0.000_01)
    #expect(abs(tilted.grainScale - 1.4) < 0.000_01)
    #expect(primary.translation == tilted.position.simd)
    #expect(abs(secondary.translation.x - tilted.position.simd.x * 0.12) < 0.000_01)
    #expect(abs(secondary.translation.y - tilted.position.simd.y * 0.12) < 0.000_01)
    #expect(abs(primary.xAxis.x) < 0.000_01)
    #expect(abs(abs(primary.xAxis.y) - 1.4) < 0.000_01)
    #expect(secondary.xAxis == SIMD2(1.4, 0))
}

@Test
func graphiteSeededVariationIsDeterministicBoundedAndDryWithoutInteraction() {
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 128, height: 128),
        worldCenter: WorldPoint(x: 64, y: 64)
    )
    let first = graphiteLogicalDabs(seed: 91, viewport: viewport)
    let repeated = graphiteLogicalDabs(seed: 91, viewport: viewport)
    let otherSeed = graphiteLogicalDabs(seed: 92, viewport: viewport)
    let low = graphitePencilDab(random: BrushRandomValues(
        spacing: 0, scatterX: 0, scatterY: 0, rotation: 0,
        grainX: 0, grainY: 0, materialVariation: 0
    ))
    let highRandom: Float = 0.999_999
    let high = graphitePencilDab(random: BrushRandomValues(
        spacing: highRandom, scatterX: highRandom, scatterY: highRandom,
        rotation: highRandom, grainX: highRandom, grainY: highRandom,
        materialVariation: highRandom
    ))
    let centered = graphitePencilDab()

    #expect(!first.isEmpty)
    #expect(first == repeated)
    #expect(first != otherSeed)
    #expect(abs(low.spacing - 2.112) < 0.000_01)
    #expect(abs(high.spacing - 2.288) < 0.000_01)
    #expect(abs(low.scatter.x + 0.048) < 0.000_01)
    #expect(abs(low.scatter.y + 0.048) < 0.000_01)
    #expect(abs(high.scatter.x - 0.048) < 0.000_01)
    #expect(abs(high.scatter.y - 0.048) < 0.000_01)
    #expect(abs(low.rotation - (centered.rotation - 0.08)) < 0.000_01)
    #expect(abs(high.rotation - (centered.rotation + 0.08)) < 0.000_01)
    #expect(low.grainOffset == SIMD2(-0.08, -0.08))
    #expect(abs(high.grainOffset.x - 0.08) < 0.000_01)
    #expect(abs(high.grainOffset.y - 0.08) < 0.000_01)
    #expect(abs(low.materialContribution - 0.95) < 0.000_01)
    #expect(high.materialContribution == 1)
    #expect(low.materialFamily == .dry)
    #expect(graphitePencilProgram().requestedBackend == .deposition)
}

@Test
func graphiteMouseFallbackAndCausalCapRemainFiniteAndUseful() throws {
    let mouse = graphitePencilDab(pressure: 0, capabilities: [])
    var input = BrushInputDeriver()
    var generator = BrushStrokeGenerator(
        program: graphitePencilProgram(), nominalDiameter: 40, color: .black, seed: 91
    )
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 2, height: 2),
        worldCenter: WorldPoint(x: 0, y: 0)
    )
    let leading = try generator.beginBatch(input.derive(
        graphiteStrokeSample(x: 0, timestamp: 0, phase: .began), viewport: viewport
    ))
    let tail = try generator.finishBatch(input.derive(
        graphiteStrokeSample(x: 20, timestamp: 1, phase: .ended), viewport: viewport
    ))
    let emitted = leading.dabs + tail.dabs
    let totalDistance = try #require(emitted.last?.sourceDistance)
    let retapered = emitted.map {
        BrushDynamicsEngine().applyingLegacySchemaV1EndTaper(
            $0, totalDistance: totalDistance, nominalDiameter: 40,
            program: graphitePencilProgram()
        )
    }

    #expect(mouse.diameter == 40)
    #expect(mouse.flow == 0.28)
    #expect(mouse.strokeOpacity == 0.88)
    #expect(abs(mouse.hardness - 0.252) < 0.000_01)
    #expect(abs(mouse.grainScale - 1.4) < 0.000_01)
    #expect([mouse.diameter, mouse.flow, mouse.spacing, mouse.hardness,
             mouse.grainScale].allSatisfy { $0.isFinite })
    #expect(graphitePencilProgram().termination == .cap)
    #expect(graphitePencilProgram().replayContract.mode == .appendOnly)
    #expect(retapered == emitted)
}

@Test
func naturalCharcoalPressureAndTiltProduceBroaderSofterDabsThanGraphite() {
    let lightPressure = naturalCharcoalDab(pressure: 0.2, capabilities: [.pressure])
    let heavyPressure = naturalCharcoalDab(pressure: 1, capabilities: [.pressure])
    let upright = naturalCharcoalDab(
        altitude: .pi / 2,
        capabilities: [.pressure, .altitude]
    )
    let tilted = naturalCharcoalDab(
        altitude: 0,
        capabilities: [.pressure, .altitude]
    )
    let graphiteUpright = graphitePencilDab(
        altitude: .pi / 2,
        capabilities: [.pressure, .altitude]
    )
    let graphiteTilted = graphitePencilDab(
        altitude: 0,
        capabilities: [.pressure, .altitude]
    )

    #expect(abs(lightPressure.flow - 0.0672) < 0.000_01)
    #expect(abs(lightPressure.strokeOpacity - 0.368) < 0.000_01)
    #expect(heavyPressure.flow == 0.24)
    #expect(heavyPressure.strokeOpacity == 0.92)
    #expect(abs(lightPressure.grainScale - 1.28) < 0.000_01)
    #expect(abs(heavyPressure.grainScale - 0.8) < 0.000_01)
    #expect(upright.diameter == 18)
    #expect(tilted.diameter == 68)
    #expect(abs(upright.hardness - 0.4756) < 0.000_01)
    #expect(abs(tilted.hardness - 0.1276) < 0.000_01)
    #expect((tilted.diameter - upright.diameter) > (graphiteTilted.diameter - graphiteUpright.diameter))
    #expect(tilted.hardness < upright.hardness)
}

@Test
func naturalCharcoalCompiledDabsMapSpeedScatterAndDirectionEndpoints() {
    let slow = naturalCharcoalDab(direction: -.pi, velocity: 0)
    let middle = naturalCharcoalDab(direction: 0, velocity: 50_000)
    let fast = naturalCharcoalDab(direction: .pi / 2, velocity: 100_000)
    let random: Float = 0.999_999
    let slowScatter = naturalCharcoalDab(
        velocity: 0,
        random: BrushRandomValues(
            spacing: 0.5, scatterX: random, scatterY: random, rotation: 0.5,
            grainX: 0.5, grainY: 0.5, materialVariation: 0.5
        )
    )
    let fastScatter = naturalCharcoalDab(
        velocity: 100_000,
        random: BrushRandomValues(
            spacing: 0.5, scatterX: random, scatterY: random, rotation: 0.5,
            grainX: 0.5, grainY: 0.5, materialVariation: 0.5
        )
    )

    #expect(abs(slow.spacing - 1.215) < 0.000_01)
    #expect(abs(middle.spacing - 1.62) < 0.000_01)
    #expect(abs(fast.spacing - 2.025) < 0.000_01)
    #expect(abs(slowScatter.scatter.x - 0.4032) < 0.000_01)
    #expect(abs(slowScatter.scatter.y - 0.4032) < 0.000_01)
    #expect(abs(fastScatter.scatter.x - 0.864) < 0.000_01)
    #expect(abs(fastScatter.scatter.y - 0.864) < 0.000_01)
    #expect(abs(slow.rotation - 0) < 0.000_01)
    #expect(abs(middle.rotation - .pi) < 0.000_01)
    #expect(abs(fast.rotation - 1.5 * .pi) < 0.000_01)
}

@Test
func naturalCharcoalUsesTwoShapeAndGrainFramesInAuthoredOrder() throws {
    let dab = naturalCharcoalDab(direction: .pi / 2)
    let primary = try #require(dab.primaryGrainToWorld)
    let secondary = try #require(dab.secondaryGrainToWorld)

    #expect(primary.translation == dab.position.simd)
    #expect(abs(secondary.translation.x - dab.position.simd.x * 0.12) < 0.000_01)
    #expect(abs(secondary.translation.y - dab.position.simd.y * 0.12) < 0.000_01)
    #expect(abs(primary.xAxis.x) < 0.000_01)
    #expect(abs(abs(primary.xAxis.y) - 0.8) < 0.000_01)
    #expect(secondary.xAxis == SIMD2(0.8, 0))
}

@Test
func naturalCharcoalSeededVariationIsBoundedBroaderThanGraphiteAndDry() {
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 128, height: 128),
        worldCenter: WorldPoint(x: 64, y: 64)
    )
    let first = naturalCharcoalLogicalDabs(seed: 91, viewport: viewport)
    let repeated = naturalCharcoalLogicalDabs(seed: 91, viewport: viewport)
    let otherSeed = naturalCharcoalLogicalDabs(seed: 92, viewport: viewport)
    let low = naturalCharcoalDab(random: BrushRandomValues(
        spacing: 0, scatterX: 0, scatterY: 0, rotation: 0,
        grainX: 0, grainY: 0, materialVariation: 0
    ))
    let highRandom: Float = 0.999_999
    let high = naturalCharcoalDab(random: BrushRandomValues(
        spacing: highRandom, scatterX: highRandom, scatterY: highRandom,
        rotation: highRandom, grainX: highRandom, grainY: highRandom,
        materialVariation: highRandom
    ))
    let graphiteLow = graphitePencilDab(random: BrushRandomValues(
        spacing: 0.5, scatterX: highRandom, scatterY: highRandom, rotation: 0.5,
        grainX: highRandom, grainY: highRandom, materialVariation: 0.5
    ))

    #expect(!first.isEmpty)
    #expect(first == repeated)
    #expect(first != otherSeed)
    #expect(abs(low.spacing - 1.4904) < 0.000_01)
    #expect(abs(high.spacing - 1.7496) < 0.000_01)
    #expect(abs(low.scatter.x + 0.6336) < 0.000_01)
    #expect(abs(low.scatter.y + 0.6336) < 0.000_01)
    #expect(abs(high.scatter.x - 0.6336) < 0.000_01)
    #expect(abs(high.scatter.y - 0.6336) < 0.000_01)
    #expect(abs(low.rotation - (.pi - 0.18)) < 0.000_01)
    #expect(abs(high.rotation - (.pi + 0.18)) < 0.000_01)
    #expect(low.grainOffset == SIMD2(-0.16, -0.16))
    #expect(abs(high.grainOffset.x - 0.16) < 0.000_01)
    #expect(abs(high.grainOffset.y - 0.16) < 0.000_01)
    #expect(abs(low.materialContribution - 0.88) < 0.000_01)
    #expect(high.materialContribution == 1)
    #expect(abs(high.scatter.x) > abs(graphiteLow.scatter.x))
    #expect(abs(high.grainOffset.x) > abs(graphiteLow.grainOffset.x))
    #expect(low.materialFamily == .dry)
    #expect(naturalCharcoalProgram().requestedBackend == .deposition)
}

@Test
func naturalCharcoalMouseFallbackAndCausalCapRemainFiniteAndUseful() throws {
    let mouse = naturalCharcoalDab(pressure: 0, capabilities: [])
    var input = BrushInputDeriver()
    var generator = BrushStrokeGenerator(
        program: naturalCharcoalProgram(), nominalDiameter: 40, color: .black, seed: 91
    )
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 2, height: 2),
        worldCenter: WorldPoint(x: 0, y: 0)
    )
    let leading = try generator.beginBatch(input.derive(
        naturalCharcoalStrokeSample(x: 0, timestamp: 0, phase: .began), viewport: viewport
    ))
    let tail = try generator.finishBatch(input.derive(
        naturalCharcoalStrokeSample(x: 20, timestamp: 1, phase: .ended), viewport: viewport
    ))
    let emitted = leading.dabs + tail.dabs
    let totalDistance = try #require(emitted.last?.sourceDistance)
    let retapered = emitted.map {
        BrushDynamicsEngine().applyingLegacySchemaV1EndTaper(
            $0, totalDistance: totalDistance, nominalDiameter: 40,
            program: naturalCharcoalProgram()
        )
    }

    #expect(mouse.diameter == 68)
    #expect(mouse.flow == 0.24)
    #expect(mouse.strokeOpacity == 0.92)
    #expect(abs(mouse.hardness - 0.1276) < 0.000_01)
    #expect(abs(mouse.grainScale - 0.8) < 0.000_01)
    #expect([mouse.diameter, mouse.flow, mouse.spacing, mouse.hardness,
             mouse.grainScale].allSatisfy { $0.isFinite })
    #expect(naturalCharcoalProgram().termination == .cap)
    #expect(naturalCharcoalProgram().replayContract.mode == .appendOnly)
    #expect(naturalCharcoalProgram().replayContract.limits == nil)
    #expect(retapered == emitted)
}

@Test
func chiselMarkerCompiledDabsFollowDirectionWithoutScatterAndKeepConstantSpacing() {
    let horizontal = chiselMarkerDab(direction: 0, velocity: 0)
    let vertical = chiselMarkerDab(direction: .pi / 2, velocity: 50_000)
    let reverse = chiselMarkerDab(direction: .pi, velocity: 100_000)
    let zeroPressure = chiselMarkerDab(
        pressure: 0,
        capabilities: [.pressure],
        velocity: 0
    )
    let lightPressure = chiselMarkerDab(
        pressure: 0.2,
        capabilities: [.pressure],
        velocity: 0
    )
    let lightPressureFast = chiselMarkerDab(
        pressure: 0.2,
        capabilities: [.pressure],
        velocity: 100_000
    )
    let maximumRandom = BrushRandomValues(
        spacing: 0.999_999,
        scatterX: 0.999_999,
        scatterY: 0.999_999,
        rotation: 0.999_999,
        grainX: 0.999_999,
        grainY: 0.999_999,
        materialVariation: 0.999_999
    )
    let randomizedHorizontal = chiselMarkerDab(
        direction: 0,
        velocity: 0,
        random: maximumRandom
    )
    let randomizedVertical = chiselMarkerDab(
        direction: .pi / 2,
        velocity: 50_000,
        random: maximumRandom
    )
    let randomizedReverse = chiselMarkerDab(
        direction: .pi,
        velocity: 100_000,
        random: maximumRandom
    )

    #expect(abs(horizontal.rotation - Float.pi) < 0.000_01)
    #expect(abs(vertical.rotation - 1.5 * Float.pi) < 0.000_01)
    #expect(abs(reverse.rotation - 2 * Float.pi) < 0.000_01)
    #expect(abs(randomizedHorizontal.rotation - Float.pi) < 0.000_01)
    #expect(abs(randomizedVertical.rotation - 1.5 * Float.pi) < 0.000_01)
    #expect(abs(randomizedReverse.rotation - 2 * Float.pi) < 0.000_01)
    #expect([horizontal, vertical, reverse, randomizedHorizontal,
             randomizedVertical, randomizedReverse].allSatisfy { $0.scatter == .zero })
    #expect(horizontal.position == WorldPoint(x: 10, y: 20))
    #expect(vertical.position == WorldPoint(x: 10, y: 20))
    #expect(reverse.position == WorldPoint(x: 10, y: 20))
    #expect(randomizedHorizontal.position == WorldPoint(x: 10, y: 20))
    #expect(randomizedVertical.position == WorldPoint(x: 10, y: 20))
    #expect(randomizedReverse.position == WorldPoint(x: 10, y: 20))
    #expect(zeroPressure.diameter == 28)
    #expect(abs(lightPressure.diameter - 30.4) < 0.000_01)
    #expect(horizontal.diameter == 40)
    #expect(horizontal.flow == 0.56)
    #expect(abs(vertical.flow - 0.49) < 0.000_01)
    #expect(abs(reverse.flow - 0.42) < 0.000_01)
    #expect(abs(zeroPressure.diameter * 0.035 - 0.98) < 0.000_01)
    #expect(zeroPressure.spacing == 1)
    #expect(abs(lightPressure.spacing - 1.064) < 0.000_01)
    #expect(abs(lightPressureFast.spacing - 1.064) < 0.000_01)
    #expect(horizontal.spacing == 1.4)
    #expect(vertical.spacing == 1.4)
    #expect(reverse.spacing == 1.4)
    #expect(randomizedHorizontal.spacing == 1.4)
    #expect(abs(lightPressure.spacing / lightPressure.diameter - 0.035) < 0.000_01)
    #expect(abs(horizontal.spacing / horizontal.diameter - 0.035) < 0.000_01)
}

@Test
func chiselMarkerCapIsDeterministicAndHasFiniteMouseFallback() throws {
    let program = chiselMarkerProgram()
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 128, height: 128),
        worldCenter: WorldPoint(x: 64, y: 64)
    )
    let first = chiselMarkerLogicalDabs(seed: 91, viewport: viewport)
    let repeated = chiselMarkerLogicalDabs(seed: 91, viewport: viewport)
    let mouse = chiselMarkerDab(pressure: 0, capabilities: [], velocity: 0)
    var input = BrushInputDeriver()
    var generator = BrushStrokeGenerator(
        program: program, nominalDiameter: 40, color: .black, seed: 91
    )
    let shortViewport = ViewportTransform(
        drawableSize: PatternSize(width: 2, height: 2),
        worldCenter: WorldPoint(x: 0, y: 0)
    )
    let leading = try generator.beginBatch(input.derive(
        chiselMarkerStrokeSample(x: 0, timestamp: 0, phase: .began),
        viewport: shortViewport
    ))
    let tail = try generator.finishBatch(input.derive(
        chiselMarkerStrokeSample(x: 20, timestamp: 1, phase: .ended),
        viewport: shortViewport
    ))
    let emitted = leading.dabs + tail.dabs
    let totalDistance = try #require(emitted.last?.sourceDistance)
    let retapered = emitted.map {
        BrushDynamicsEngine().applyingLegacySchemaV1EndTaper(
            $0, totalDistance: totalDistance, nominalDiameter: 40,
            program: program
        )
    }
    #expect(!first.isEmpty)
    #expect(first == repeated)
    #expect(program.termination == .cap)
    #expect(program.replayContract.mode == .appendOnly)
    #expect(program.replayContract.limits == nil)
    #expect(retapered == emitted)
    #expect(mouse.diameter == 40)
    #expect(mouse.flow == 0.56)
    #expect([mouse.diameter, mouse.flow, mouse.spacing, mouse.rotation].allSatisfy {
        $0.isFinite
    })
    #expect(mouse.materialFamily == .glaze)
    #expect(mouse.materialContribution == 0.95)
    #expect(mouse.materialInputs.accumulation == .uniformGlaze)
    #expect(mouse.materialInputs.edgeTreatment == .markerOverlap)
    #expect(mouse.materialInputs.interaction == .none)
    #expect(mouse.materialInputs.strength == 0.95)
    #expect(mouse.materialInputs.accumulationLimit == 0.82)
    #expect(program.requestedBackend == .deposition)
}

private func technicalInkDab(
    pressure: Float = 1,
    capabilities: StrokeInputCapabilities = [.pressure],
    direction: Float = 0
) -> LogicalDab {
    let sample = InterpolatedStrokeSample(
        position: WorldPoint(x: 10, y: 20),
        pressure: pressure,
        timestamp: 0,
        altitude: nil,
        azimuth: nil,
        roll: nil,
        velocity: 50_000,
        artisticVelocity: 50_000,
        phase: .moved,
        source: capabilities.contains(.pressure) ? .tablet : .mouse,
        kind: .actual,
        capabilities: capabilities
    )
    return BrushDynamicsEngine().evaluate(
        sample: sample,
        context: BrushStrokeContext(
            nominalDiameter: 40,
            color: .black,
            direction: direction,
            strokeAge: 1,
            traveledDistance: 100,
            ordinal: 4,
            isPredicted: false
        ),
        program: ProfessionalBrushCatalog.technicalInk.program,
        random: BrushRandomValues(
            spacing: 0.1,
            scatterX: 0.9,
            scatterY: 0.1,
            rotation: 0.9,
            grainX: 0.9,
            grainY: 0.1,
            materialVariation: 0.9
        ),
        strokeSeed: 91
    )
}

private func graphitePencilProgram() -> BrushProgram {
    guard let entry = ProfessionalBrushCatalog.entry(
        for: BrushRecipeID("builtin.professional-graphite-pencil")
    ) else {
        fatalError("Graphite Pencil must be registered before its dynamics run")
    }
    return entry.program
}

private func naturalCharcoalProgram() -> BrushProgram {
    guard let entry = ProfessionalBrushCatalog.entry(
        for: BrushRecipeID("builtin.professional-natural-charcoal")
    ) else {
        fatalError("Natural Charcoal must be registered before its dynamics run")
    }
    return entry.program
}

private func chiselMarkerProgram() -> BrushProgram {
    guard let entry = ProfessionalBrushCatalog.entry(
        for: BrushRecipeID("builtin.professional-chisel-marker")
    ) else {
        fatalError("Chisel Marker must be registered before its dynamics run")
    }
    return entry.program
}

private func graphitePencilDab(
    pressure: Float = 1,
    altitude: Float? = .pi / 2,
    capabilities: StrokeInputCapabilities = [.pressure, .altitude],
    direction: Float = 0,
    velocity: Float = 50_000,
    random: BrushRandomValues = .centered
) -> LogicalDab {
    let sample = InterpolatedStrokeSample(
        position: WorldPoint(x: 10, y: 20), pressure: pressure, timestamp: 0,
        altitude: altitude, azimuth: nil, roll: nil, velocity: velocity,
        artisticVelocity: velocity,
        phase: .moved,
        source: capabilities.contains(.pressure) ? .tablet : .mouse,
        kind: .actual, capabilities: capabilities
    )
    return BrushDynamicsEngine().evaluate(
        sample: sample,
        context: BrushStrokeContext(
            nominalDiameter: 40, color: .black, direction: direction,
            strokeAge: 1, traveledDistance: 100, ordinal: 4, isPredicted: false
        ),
        program: graphitePencilProgram(), random: random, strokeSeed: 91
    )
}

private func naturalCharcoalDab(
    pressure: Float = 1,
    altitude: Float? = .pi / 2,
    capabilities: StrokeInputCapabilities = [.pressure, .altitude],
    direction: Float = 0,
    velocity: Float = 50_000,
    random: BrushRandomValues = .centered
) -> LogicalDab {
    let sample = InterpolatedStrokeSample(
        position: WorldPoint(x: 10, y: 20), pressure: pressure, timestamp: 0,
        altitude: altitude, azimuth: nil, roll: nil, velocity: velocity,
        artisticVelocity: velocity,
        phase: .moved,
        source: capabilities.contains(.pressure) ? .tablet : .mouse,
        kind: .actual, capabilities: capabilities
    )
    return BrushDynamicsEngine().evaluate(
        sample: sample,
        context: BrushStrokeContext(
            nominalDiameter: 40, color: .black, direction: direction,
            strokeAge: 1, traveledDistance: 100, ordinal: 4, isPredicted: false
        ),
        program: naturalCharcoalProgram(), random: random, strokeSeed: 91
    )
}

private func chiselMarkerDab(
    pressure: Float = 1,
    capabilities: StrokeInputCapabilities = [.pressure],
    direction: Float = 0,
    velocity: Float = 50_000,
    random: BrushRandomValues = .centered
) -> LogicalDab {
    let sample = InterpolatedStrokeSample(
        position: WorldPoint(x: 10, y: 20), pressure: pressure, timestamp: 0,
        altitude: nil, azimuth: nil, roll: nil, velocity: velocity,
        artisticVelocity: velocity,
        phase: .moved,
        source: capabilities.contains(.pressure) ? .tablet : .mouse,
        kind: .actual, capabilities: capabilities
    )
    return BrushDynamicsEngine().evaluate(
        sample: sample,
        context: BrushStrokeContext(
            nominalDiameter: 40, color: .black, direction: direction,
            strokeAge: 1, traveledDistance: 100, ordinal: 4, isPredicted: false
        ),
        program: chiselMarkerProgram(), random: random, strokeSeed: 91
    )
}

private func graphiteLogicalDabs(
    seed: UInt64,
    viewport: ViewportTransform
) -> [LogicalDab] {
    var input = BrushInputDeriver()
    var generator = BrushStrokeGenerator(
        program: graphitePencilProgram(), nominalDiameter: 40, color: .black, seed: seed
    )
    var dabs: [LogicalDab] = []
    for sample in StrokeTraceFixtures.professionalPressureRamp.samples where sample.kind != .predicted {
        let world = input.derive(sample, viewport: viewport)
        switch world.phase {
        case .began:
            dabs += generator.beginBatches(world).flatMap(\.dabs)
        case .moved:
            dabs += generator.appendBatches(world).flatMap(\.dabs)
        case .ended:
            dabs += generator.finishBatches(world).flatMap(\.dabs)
        case .cancelled:
            generator.cancel()
        }
    }
    return dabs
}

private func naturalCharcoalLogicalDabs(
    seed: UInt64,
    viewport: ViewportTransform
) -> [LogicalDab] {
    var input = BrushInputDeriver()
    var generator = BrushStrokeGenerator(
        program: naturalCharcoalProgram(), nominalDiameter: 40, color: .black, seed: seed
    )
    var dabs: [LogicalDab] = []
    for sample in StrokeTraceFixtures.professionalPressureRamp.samples where sample.kind != .predicted {
        let world = input.derive(sample, viewport: viewport)
        switch world.phase {
        case .began:
            dabs += generator.beginBatches(world).flatMap(\.dabs)
        case .moved:
            dabs += generator.appendBatches(world).flatMap(\.dabs)
        case .ended:
            dabs += generator.finishBatches(world).flatMap(\.dabs)
        case .cancelled:
            generator.cancel()
        }
    }
    return dabs
}

private func chiselMarkerLogicalDabs(
    seed: UInt64,
    viewport: ViewportTransform
) -> [LogicalDab] {
    var input = BrushInputDeriver()
    var generator = BrushStrokeGenerator(
        program: chiselMarkerProgram(), nominalDiameter: 40, color: .black, seed: seed
    )
    var dabs: [LogicalDab] = []
    for sample in StrokeTraceFixtures.professionalPressureRamp.samples where sample.kind != .predicted {
        let world = input.derive(sample, viewport: viewport)
        switch world.phase {
        case .began:
            dabs += generator.beginBatches(world).flatMap(\.dabs)
        case .moved:
            dabs += generator.appendBatches(world).flatMap(\.dabs)
        case .ended:
            dabs += generator.finishBatches(world).flatMap(\.dabs)
        case .cancelled:
            generator.cancel()
        }
    }
    return dabs
}

private func graphiteStrokeSample(
    x: Float,
    timestamp: TimeInterval,
    phase: StrokePhase
) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x + 1, y: 1), pressure: 1, timestamp: timestamp,
        phase: phase, source: .pencil, capabilities: [.pressure]
    )
}

private func naturalCharcoalStrokeSample(
    x: Float,
    timestamp: TimeInterval,
    phase: StrokePhase
) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x + 1, y: 1), pressure: 1, timestamp: timestamp,
        phase: phase, source: .pencil, capabilities: [.pressure]
    )
}

private func chiselMarkerStrokeSample(
    x: Float,
    timestamp: TimeInterval,
    phase: StrokePhase
) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x + 1, y: 1), pressure: 1, timestamp: timestamp,
        phase: phase, source: .pencil, capabilities: [.pressure]
    )
}

private func technicalInkStrokeSample(
    x: Float,
    timestamp: TimeInterval,
    phase: StrokePhase
) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x + 1, y: 1),
        pressure: 1,
        timestamp: timestamp,
        phase: phase,
        source: .pencil,
        capabilities: [.pressure]
    )
}
