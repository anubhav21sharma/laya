import Foundation
@testable import PatternEngine
import Testing

@Test
func capTerminationNeverRequestsBodyReevaluation() throws {
    let decision = try BrushTerminationEvaluator(
        program: .cap
    ).evaluate(
        BrushTerminationCorrection(
            sampleCount: 12,
            worldLength: 48,
            dabCount: 20,
            ordinalRange: 4..<24
        )
    )

    #expect(decision == .appendCap)
}

@Test
func pressureReleaseNeverRequestsBodyReevaluation() throws {
    let decision = try BrushTerminationEvaluator(
        program: .pressureRelease(maximumWorldLength: 8)
    ).evaluate(
        BrushTerminationCorrection(
            sampleCount: 4,
            worldLength: 6,
            dabCount: 7,
            ordinalRange: 10..<17
        )
    )

    #expect(
        decision == .appendPressureRelease(maximumWorldLength: 8)
    )
}

@Test
func boundedCorrectionRejectsEachIndependentLimit() throws {
    let evaluator = BrushTerminationEvaluator(
        program: .boundedCorrection(
            maximumSamples: 3,
            maximumWorldLength: 8,
            maximumDabs: 5
        )
    )
    let accepted = BrushTerminationCorrection(
        sampleCount: 3,
        worldLength: 8,
        dabCount: 5,
        ordinalRange: 10..<15
    )

    #expect(
        try evaluator.evaluate(accepted)
            == .replaceBoundedCorrection(ordinalRange: 10..<15)
    )
    #expect(
        throws: BrushTerminationEvaluationError.maximumSamplesExceeded(
            actual: 4,
            maximum: 3
        )
    ) {
        try evaluator.evaluate(
            replacing(accepted, sampleCount: 4)
        )
    }
    #expect(
        throws: BrushTerminationEvaluationError.maximumWorldLengthExceeded(
            actual: 8.01,
            maximum: 8
        )
    ) {
        try evaluator.evaluate(
            replacing(accepted, worldLength: 8.01)
        )
    }
    #expect(
        throws: BrushTerminationEvaluationError.maximumDabsExceeded(
            actual: 6,
            maximum: 5
        )
    ) {
        try evaluator.evaluate(
            replacing(accepted, dabCount: 6, ordinalRange: 10..<16)
        )
    }
}

@Test
func boundedCorrectionReplayContractRetainsItsWorldLengthLimit() throws {
    let program = try causalTerminationProgram(
        .boundedCorrection(
            maximumSamples: 3,
            maximumWorldLength: 8,
            maximumDabs: 5
        )
    )
    #expect(program.replayContract.maximumWorldLength == 8)
}

@Test
func capPointerUpPreservesBodyDabsAndReachesReleasePoint() throws {
    var generator = BrushStrokeGenerator(
        program: try causalTerminationProgram(.cap),
        nominalDiameter: 20,
        color: .black,
        seed: 41
    )
    var dabs: [LogicalDab] = []
    generator.begin(terminationSample(x: 0, timestamp: 0, phase: .began)) {
        dabs.append($0)
    }
    generator.append(terminationSample(x: 12, timestamp: 1, phase: .moved)) {
        dabs.append($0)
    }
    let body = dabs

    generator.finish(terminationSample(x: 20, timestamp: 2, phase: .ended)) {
        dabs.append($0)
    }

    #expect(Array(dabs.prefix(body.count)) == body)
    #expect(dabs.last?.position == WorldPoint(x: 20, y: 0))
    #expect(abs((dabs.last?.position.x ?? 0) - 20) <= 1)
    #expect(dabs.map(\.ordinal) == Array(0..<UInt64(dabs.count)))
}

@Test
func stabilizedCapFlushesToRawReleasePointWithoutChangingBodyDabs() throws {
    var generator = BrushStrokeGenerator(
        program: try causalTerminationProgram(.cap, stabilization: 0.5),
        nominalDiameter: 20,
        color: .black,
        seed: 42
    )
    var dabs: [LogicalDab] = []
    generator.begin(terminationSample(x: 0, timestamp: 0, phase: .began)) {
        dabs.append($0)
    }
    generator.append(terminationSample(x: 100, timestamp: 1, phase: .moved)) {
        dabs.append($0)
    }
    let body = dabs

    generator.finish(terminationSample(x: 120, timestamp: 2, phase: .ended)) {
        dabs.append($0)
    }

    #expect(Array(dabs.prefix(body.count)) == body)
    #expect(dabs.last?.position == WorldPoint(x: 120, y: 0))
}

@Test
func schemaV1ReplayKeepsItsFilteredReleaseEndpoint() throws {
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.legacy-filtered-release"),
        stabilization: 0.5,
        replayMode: .replayTail,
        replayLimits: BrushRecipePolicy.replayTailLimits
    )
    let definition = try LegacyBrushRecipeAdapter.definition(
        from: recipe,
        displayName: "Legacy Filtered Release"
    )
    let program = try BrushProgramCompiler.compile(definition)
    var generator = BrushStrokeGenerator(
        program: program,
        nominalDiameter: 20,
        color: .black,
        seed: 43
    )
    var dabs: [LogicalDab] = []

    generator.begin(terminationSample(x: 0, timestamp: 0, phase: .began)) {
        dabs.append($0)
    }
    generator.append(terminationSample(x: 100, timestamp: 1, phase: .moved)) {
        dabs.append($0)
    }
    generator.finish(terminationSample(x: 120, timestamp: 2, phase: .ended)) {
        dabs.append($0)
    }

    #expect(
        program.termination
            == .legacySchemaV1Replay(
                mode: .replayTail,
                replayLimits: BrushRecipePolicy.replayTailLimits
            )
    )
    #expect(dabs.last?.position == WorldPoint(x: 85, y: 0))
}

private func causalTerminationProgram(
    _ termination: BrushTerminationDefinition,
    stabilization: Float? = nil
) throws -> BrushProgram {
    let base = nativeTestDefinition()
    let definition = try BrushDefinition(
        id: base.id,
        schemaVersion: base.schemaVersion,
        metadata: base.metadata,
        capabilities: base.capabilities,
        resources: base.resources,
        coverage: base.coverage,
        placement: base.placement,
        dynamics: base.dynamics,
        color: base.color,
        material: base.material,
        stabilization: stabilization ?? base.stabilization,
        taper: .none,
        replayMode: .appendOnly,
        replayLimits: nil,
        termination: termination,
        seedPolicy: base.seedPolicy,
        limits: base.limits,
        performanceIntent: base.performanceIntent,
        compatibility: base.compatibility
    )
    return try BrushProgramCompiler.compile(definition)
}

private func terminationSample(
    x: Float,
    timestamp: TimeInterval,
    phase: StrokePhase
) -> WorldStrokeSample {
    WorldStrokeSample(
        sample: StrokeSample(
            position: ScreenPoint(x: x, y: 0),
            pressure: 0.5,
            timestamp: timestamp,
            phase: phase,
            source: .mouse
        ),
        position: WorldPoint(x: x, y: 0),
        velocity: 0
    )
}

private func replacing(
    _ correction: BrushTerminationCorrection,
    sampleCount: Int? = nil,
    worldLength: Float? = nil,
    dabCount: Int? = nil,
    ordinalRange: Range<UInt64>? = nil
) -> BrushTerminationCorrection {
    BrushTerminationCorrection(
        sampleCount: sampleCount ?? correction.sampleCount,
        worldLength: worldLength ?? correction.worldLength,
        dabCount: dabCount ?? correction.dabCount,
        ordinalRange: ordinalRange ?? correction.ordinalRange
    )
}
