import Foundation
import PatternEngine
import Testing

@Test
func professionalCharacterizerPinsTheCalibrationInputsAndIgnoresPrediction() throws {
    let program = nativeTestProgram()
    let expectedHash = String(repeating: "a", count: 64)
    let predicted = ProfessionalBrushCharacterizer.record(
        family: "Calibration",
        definitionSemanticHash: expectedHash,
        trace: StrokeTraceFixtures.professionalDirectionTurn,
        program: program
    )
    let authoritative = ProfessionalBrushCharacterizer.record(
        family: "Calibration",
        definitionSemanticHash: expectedHash,
        trace: StrokeTraceFixture(
            name: "professional-direction-turn",
            samples: StrokeTraceFixtures.professionalDirectionTurn.samples.filter {
                $0.kind != .predicted
            }
        ),
        program: program
    )

    #expect(ProfessionalBrushCharacterizer.nominalDiameter == 40)
    #expect(ProfessionalBrushCharacterizer.color == .black)
    #expect(ProfessionalBrushCharacterizer.seed == 0x5A17_E5)
    #expect(ProfessionalBrushCharacterizer.viewport == ViewportTransform(
        drawableSize: PatternSize(width: 512, height: 512),
        worldCenter: WorldPoint(x: 256, y: 256)
    ))
    #expect(predicted == authoritative)
    #expect(predicted.sampleCount == 4)
    #expect(predicted.brushID == program.definition.id.rawValue)
    #expect(predicted.definitionSemanticHash == expectedHash)
    #expect(predicted.logicalDabCount > 0)
    #expect(predicted.minimumDiameter <= predicted.maximumDiameter)
    #expect(predicted.worldBounds.minimumX <= predicted.worldBounds.maximumX)
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
