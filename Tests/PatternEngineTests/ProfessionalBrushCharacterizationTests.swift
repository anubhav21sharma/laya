import Foundation
@testable import PatternEngine
import Testing

@Test
func professionalCharacterizerEvaluatesThenReplacesPredictedSuffix() throws {
    let program = nativeTestProgram()
    let expectedHash = String(repeating: "a", count: 64)
    let began = characterizationSample(
        x: 64,
        y: 64,
        pressure: 0.4,
        timestamp: 50,
        phase: .began
    )
    let moved = characterizationSample(
        x: 256,
        y: 64,
        pressure: 0.6,
        timestamp: 50.1,
        phase: .moved
    )
    let predictedFirst = characterizationSample(
        x: 256,
        y: 320,
        pressure: 0.8,
        timestamp: 50.2,
        phase: .moved,
        kind: .predicted
    )
    let predictedSecond = characterizationSample(
        x: 384,
        y: 320,
        pressure: 0.9,
        timestamp: 50.25,
        phase: .moved,
        kind: .predicted
    )
    let corrected = characterizationSample(
        x: 256,
        y: 224,
        pressure: 0.8,
        timestamp: 50.2,
        phase: .moved
    )
    let ended = characterizationSample(
        x: 384,
        y: 224,
        pressure: 1,
        timestamp: 50.3,
        phase: .ended
    )
    let withPrediction = StrokeTraceFixture(
        name: "prediction-replacement",
        samples: [
            began,
            moved,
            predictedFirst,
            predictedSecond,
            corrected,
            ended,
        ]
    )
    let predictionFreeFinalTrace = StrokeTraceFixture(
        name: "prediction-replacement",
        samples: [began, moved, corrected, ended]
    )

    let characterized = try ProfessionalBrushCharacterizer.characterize(
        family: "Calibration",
        definitionSemanticHash: expectedHash,
        trace: withPrediction,
        program: program
    )
    let authoritative = try ProfessionalBrushCharacterizer.record(
        family: "Calibration",
        definitionSemanticHash: expectedHash,
        trace: predictionFreeFinalTrace,
        program: program
    )

    #expect(ProfessionalBrushCharacterizer.nominalDiameter == 40)
    #expect(ProfessionalBrushCharacterizer.color == .black)
    #expect(ProfessionalBrushCharacterizer.seed == 0x5A17_E5)
    #expect(ProfessionalBrushCharacterizer.viewport == ViewportTransform(
        drawableSize: PatternSize(width: 512, height: 512),
        worldCenter: WorldPoint(x: 256, y: 256)
    ))
    #expect(characterized.evaluatedPredictedSampleCount == 2)
    #expect(characterized.evaluatedPredictedLogicalDabCount > 0)
    #expect(characterized.record == authoritative)
    #expect(characterized.record.sampleCount == 4)
    #expect(characterized.record.brushID == program.definition.id.rawValue)
    #expect(characterized.record.definitionSemanticHash == expectedHash)
    #expect(characterized.record.logicalDabCount > 0)
    #expect(
        characterized.record.minimumDiameter
            <= characterized.record.maximumDiameter
    )
    #expect(
        characterized.record.worldBounds.minimumX
            <= characterized.record.worldBounds.maximumX
    )
}

@Test
func professionalCharacterizerIgnoresEstimatedUpdates() throws {
    let program = nativeTestProgram()
    let hash = String(repeating: "a", count: 64)
    let authoritativeSamples = StrokeTraceFixtures
        .professionalDirectionTurn.samples.filter {
            $0.kind == .actual || $0.kind == .coalesced
        }
    let estimatedUpdate = StrokeSample(
        position: ScreenPoint(x: 320, y: 64),
        pressure: 0.7,
        timestamp: 50.15,
        phase: .moved,
        source: .pencil,
        kind: .estimatedUpdate,
        capabilities: [.pressure],
        estimationUpdateIndex: 1
    )
    let withEstimatedUpdate = StrokeTraceFixture(
        name: "professional-direction-turn",
        samples: authoritativeSamples.prefix(2)
            + [estimatedUpdate]
            + authoritativeSamples.dropFirst(2)
    )
    let authoritative = try ProfessionalBrushCharacterizer.record(
        family: "Calibration",
        definitionSemanticHash: hash,
        trace: StrokeTraceFixture(
            name: "professional-direction-turn",
            samples: authoritativeSamples
        ),
        program: program
    )
    let actual = try ProfessionalBrushCharacterizer.record(
        family: "Calibration",
        definitionSemanticHash: hash,
        trace: withEstimatedUpdate,
        program: program
    )

    #expect(actual == authoritative)
}

@Test
func professionalCharacterizerRejectsInvalidCallerInput() throws {
    let program = nativeTestProgram()
    let hash = String(repeating: "a", count: 64)
    let predictionOnlyTrace = StrokeTraceFixture(
        name: "prediction-only",
        samples: [
            characterizationSample(
                x: 64,
                y: 64,
                pressure: 0.5,
                timestamp: 1,
                phase: .moved,
                kind: .predicted
            ),
        ]
    )
    let mismatchedIdentity = try BrushRenderIdentity(
        definitionID: BrushRecipeID(rawValue: "different-brush"),
        semanticHash: hash
    )

    #expect(
        throws: ProfessionalBrushCharacterizationRecordError
            .emptyAuthoritativeOutput
    ) {
        _ = try ProfessionalBrushCharacterizer.record(
            family: "Calibration",
            definitionSemanticHash: hash,
            trace: predictionOnlyTrace,
            program: program
        )
    }
    #expect(
        throws: ProfessionalBrushCharacterizationRecordError
            .renderIdentityMismatch
    ) {
        _ = try ProfessionalBrushCharacterizer.record(
            family: "Calibration",
            renderIdentity: mismatchedIdentity,
            trace: StrokeTraceFixtures.professionalTap,
            program: program
        )
    }
}

@Test
func professionalBaselineRejectsInvalidRecordsAndEncodesDeterministically() throws {
    let first = try professionalRecord(brushID: "a", traceName: "a")
    let second = try professionalRecord(brushID: "b", traceName: "a")
    let baseline = try ProfessionalBrushLogicalBaseline(
        validatingSchemaVersion: 1,
        records: [first, second]
    )

    #expect(try baseline.encoded() == baseline.encoded())
    #expect(try JSONDecoder().decode(
        ProfessionalBrushLogicalBaseline.self,
        from: baseline.encoded()
    ) == baseline)

    #expect(throws: ProfessionalBrushLogicalBaselineError.recordsNotSorted) {
        _ = try ProfessionalBrushLogicalBaseline(
            validatingSchemaVersion: 1,
            records: [second, first]
        )
    }
    #expect(throws: ProfessionalBrushLogicalBaselineError.duplicateRecord) {
        _ = try ProfessionalBrushLogicalBaseline(
            validatingSchemaVersion: 1,
            records: [first, first]
        )
    }
    #expect(throws: ProfessionalBrushLogicalBaselineError.unsupportedSchemaVersion(2)) {
        _ = try ProfessionalBrushLogicalBaseline(
            validatingSchemaVersion: 2,
            records: [first]
        )
    }
    #expect(throws: ProfessionalBrushCharacterizationRecordError.nonfiniteMetric) {
        _ = try professionalRecord(minimumFlow: .infinity)
    }
    #expect(throws: ProfessionalBrushCharacterizationRecordError.malformedBounds) {
        _ = try professionalRecord(
            bounds: ProfessionalBrushWorldBounds(
                minimumX: 4, minimumY: 0, maximumX: 3, maximumY: 1
            )
        )
    }
    #expect(throws: ProfessionalBrushCharacterizationRecordError.invalidIdentity) {
        _ = try professionalRecord(brushID: "brush\u{0}id")
    }
    #expect(throws: ProfessionalBrushCharacterizationRecordError.invalidIdentity) {
        _ = try professionalRecord(traceName: "trace\u{0}name")
    }
}

private func professionalRecord(
    brushID: String = "brush",
    traceName: String = "trace",
    minimumFlow: Float = 0.2,
    bounds: ProfessionalBrushWorldBounds = ProfessionalBrushWorldBounds(
        minimumX: 0, minimumY: 1, maximumX: 2, maximumY: 3
    )
) throws -> ProfessionalBrushCharacterizationRecord {
    try ProfessionalBrushCharacterizationRecord(
        schemaVersion: 1,
        family: "Calibration",
        brushID: brushID,
        definitionSemanticHash: String(repeating: "b", count: 64),
        traceName: traceName,
        sampleCount: 3,
        logicalDabCount: 2,
        logicalDabDigest: "0000000000000000",
        minimumDiameter: 1,
        maximumDiameter: 2,
        minimumFlow: minimumFlow,
        maximumFlow: 1,
        minimumOpacity: 0.2,
        maximumOpacity: 1,
        minimumHardness: 0.4,
        maximumHardness: 0.9,
        minimumGrainScale: 0.8,
        maximumGrainScale: 1.2,
        minimumRotation: -0.5,
        maximumRotation: 0.5,
        minimumScatterMagnitude: 0,
        maximumScatterMagnitude: 0.25,
        worldBounds: bounds
    )
}

private func characterizationSample(
    x: Float,
    y: Float,
    pressure: Float,
    timestamp: TimeInterval,
    phase: StrokePhase,
    kind: StrokeSampleKind = .actual
) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x, y: y),
        pressure: pressure,
        timestamp: timestamp,
        phase: phase,
        source: .pencil,
        kind: kind,
        capabilities: [.pressure]
    )
}
