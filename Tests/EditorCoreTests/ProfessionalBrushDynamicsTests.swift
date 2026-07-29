import EditorCore
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
