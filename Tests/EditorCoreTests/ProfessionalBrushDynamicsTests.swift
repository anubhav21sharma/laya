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
func technicalInkReplayIsDeterministicAndDoesNotRequestInteraction() {
    let program = ProfessionalBrushCatalog.technicalInk.program
    let trace = StrokeTraceFixtures.professionalPressureRamp
    let first = ProfessionalBrushCharacterizer.record(
        family: "Ink",
        definitionSemanticHash: String(repeating: "a", count: 64),
        trace: trace,
        program: program
    )
    let repeated = ProfessionalBrushCharacterizer.record(
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
func technicalInkReplayTailRetroactivelyTapersCompletedShortStroke() throws {
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
        BrushDynamicsEngine().applyingKnownTotalDistance(
            dab,
            totalDistance: totalDistance,
            nominalDiameter: 40,
            definition: program.definition
        )
    }
    let originalLast = try #require(emitted.last)
    let firstRetapered = try #require(retapered.first)
    let lastRetapered = try #require(retapered.last)
    let maximumDiameter = try #require(retapered.map(\.diameter).max())
    let maximumFlow = try #require(retapered.map(\.flow).max())

    #expect(program.replayContract.mode == .replayTail)
    #expect(program.replayContract.limits == BrushRecipePolicy.replayTailLimits)
    #expect(authoritativeTail.dabs.last?.sourceDistance == totalDistance)
    #expect(originalLast.diameter > lastRetapered.diameter)
    #expect(abs(firstRetapered.diameter - 3.2) < 0.000_01)
    #expect(abs(lastRetapered.diameter - 3.2) < 0.000_01)
    #expect(abs(firstRetapered.flow - 0.225) < 0.000_01)
    #expect(abs(lastRetapered.flow - 0.225) < 0.000_01)
    #expect(abs(maximumDiameter - 8.352) < 0.000_01)
    #expect(abs(maximumFlow - 0.3195) < 0.000_01)
    #expect(retapered.map(\.ordinal) == emitted.map(\.ordinal))
    #expect(retapered.map(\.randomValues) == emitted.map(\.randomValues))
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
func graphiteMouseFallbackAndReplayTailRemainFiniteAndUseful() throws {
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
        BrushDynamicsEngine().applyingKnownTotalDistance(
            $0, totalDistance: totalDistance, nominalDiameter: 40,
            definition: graphitePencilProgram().definition
        )
    }

    #expect(mouse.diameter == 40)
    #expect(mouse.flow == 0.28)
    #expect(mouse.strokeOpacity == 0.88)
    #expect([mouse.diameter, mouse.flow, mouse.spacing, mouse.hardness,
             mouse.grainScale].allSatisfy { $0.isFinite })
    #expect(graphitePencilProgram().replayContract.mode == .replayTail)
    #expect(retapered.last!.flow < emitted.last!.flow)
    #expect(retapered.map(\.ordinal) == emitted.map(\.ordinal))
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

private func graphitePencilDab(
    pressure: Float = 1,
    altitude: Float? = .pi / 2,
    capabilities: StrokeInputCapabilities = [.pressure, .altitude],
    direction: Float = 0,
    random: BrushRandomValues = .centered
) -> LogicalDab {
    let sample = InterpolatedStrokeSample(
        position: WorldPoint(x: 10, y: 20), pressure: pressure, timestamp: 0,
        altitude: altitude, azimuth: nil, roll: nil, velocity: 50_000,
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
