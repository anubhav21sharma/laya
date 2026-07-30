import CryptoKit
import EditorCore
import Foundation
import PatternEngine
import Testing

@Test
func allNativeAnchorTraceBatchesAreDeterministicAndNonempty() {
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 256, height: 256),
        worldCenter: WorldPoint(x: 128, y: 128)
    )
    let traces = [
        StrokeTraceFixtures.pressureRamp,
        StrokeTraceFixtures.curved,
        StrokeTraceFixtures.predictionCorrection,
    ]
    var characterizationCount = 0

    for anchor in AnchorBrushCatalog.all {
        for trace in traces {
            let programBatches = logicalBatches(
                trace: trace,
                viewport: viewport,
                generator: BrushStrokeGenerator(
                    program: anchor.program,
                    nominalDiameter: 20,
                    color: .black,
                    seed: 41
                )
            )
            let repeatedBatches = logicalBatches(
                trace: trace,
                viewport: viewport,
                generator: BrushStrokeGenerator(
                    program: anchor.program,
                    nominalDiameter: 20,
                    color: .black,
                    seed: 41
                )
            )

            #expect(!programBatches.flatMap(\.dabs).isEmpty)
            #expect(programBatches == repeatedBatches)
            characterizationCount += 1
        }
    }

    #expect(characterizationCount == AnchorBrushCatalog.all.count * 3)
}

@Test
func professionalCatalogCompilesToDistinctNoninteractingSemanticRecordsForEveryTrace() throws {
    let entries = ProfessionalBrushCatalog.all
    let compiled = try entries.map { try BrushProgramCompiler.compile($0.definition) }
    let hashes = try entries.map { try professionalDefinitionSemanticHash($0.definition) }
    let unsortedRecords = try entries.indices.flatMap { index in
        let entry = entries[index]
        let program = compiled[index]
        let hash = hashes[index]
        return try StrokeTraceFixtures.professional.map { trace in
            try ProfessionalBrushCharacterizer.record(
                family: entry.displayName,
                definitionSemanticHash: hash,
                trace: trace,
                program: program
            )
        }
    }
    let records = unsortedRecords.sorted {
        ($0.brushID, $0.traceName) < ($1.brushID, $1.traceName)
    }
    let repeated = try entries.indices.flatMap { index in
        let entry = entries[index]
        let program = compiled[index]
        let hash = hashes[index]
        return try StrokeTraceFixtures.professional.map { trace in
            try ProfessionalBrushCharacterizer.record(
                family: entry.displayName,
                definitionSemanticHash: hash,
                trace: trace,
                program: program
            )
        }
    }.sorted {
        ($0.brushID, $0.traceName) < ($1.brushID, $1.traceName)
    }
    let predictionFreeTrace = StrokeTraceFixture(
        name: StrokeTraceFixtures.professionalDirectionTurn.name,
        samples: StrokeTraceFixtures.professionalDirectionTurn.samples.filter {
            $0.kind == .actual || $0.kind == .coalesced
        }
    )
    let directionRecords = records.filter {
        $0.traceName == StrokeTraceFixtures.professionalDirectionTurn.name
    }
    let predictionFreeRecords = try entries.indices.map { index in
        let entry = entries[index]
        let program = compiled[index]
        return try ProfessionalBrushCharacterizer.record(
            family: entry.displayName,
            definitionSemanticHash: hashes[index],
            trace: predictionFreeTrace,
            program: program
        )
    }.sorted {
        ($0.brushID, $0.traceName) < ($1.brushID, $1.traceName)
    }
    let baseline = try ProfessionalBrushLogicalBaseline(
        validatingSchemaVersion: ProfessionalBrushLogicalBaseline.schemaVersion,
        records: records
    )
    let expectedRecordKeys = [
        "builtin.professional-chisel-marker",
        "builtin.professional-graphite-pencil",
        "builtin.professional-natural-charcoal",
        "builtin.professional-technical-ink",
    ].flatMap { brushID in
        [
            "professional-corner",
            "professional-direction-turn",
            "professional-fast-line",
            "professional-grid-seam",
            "professional-hatching",
            "professional-pressure-ramp",
            "professional-radial-spoke",
            "professional-slow-line",
            "professional-tap",
            "professional-tilt-sweep",
        ].map { "\(brushID)\u{0}\($0)" }
    }

    #expect(entries.count == 4)
    #expect(compiled == entries.map(\.program))
    #expect(Set(hashes).count == 4)
    #expect(entries.allSatisfy {
        $0.definition.material.interaction == .none
            && $0.definition.material.wetness == 0
            && $0.definition.material.bleedRadius == 0
            && $0.definition.material.softenPasses == 0
            && $0.definition.material.interactionParameters == nil
    })
    #expect(records.count == 40)
    #expect(records == repeated)
    #expect(records.map { "\($0.brushID)\u{0}\($0.traceName)" } == expectedRecordKeys)
    #expect(throws: ProfessionalBrushLogicalBaselineError.recordsNotSorted) {
        _ = try ProfessionalBrushLogicalBaseline(
            validatingSchemaVersion: ProfessionalBrushLogicalBaseline.schemaVersion,
            records: unsortedRecords
        )
    }
    #expect(directionRecords == predictionFreeRecords)
    #expect(try baseline.encoded() == baseline.encoded())
    #expect(throws: BrushDefinitionValidationError.missingCapability("wetMix")) {
        try decodingMarkerWithWetInteraction()
    }
}

private func professionalDefinitionSemanticHash(_ definition: BrushDefinition) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return SHA256.hash(data: try encoder.encode(definition))
        .map { String(format: "%02x", $0) }
        .joined()
}

private func decodingMarkerWithWetInteraction() throws -> BrushDefinition {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(ProfessionalBrushCatalog.chiselMarker.definition)
    let jsonObject = try JSONSerialization.jsonObject(with: data)
    guard var object = jsonObject as? [String: Any],
          var material = object["material"] as? [String: Any]
    else {
        preconditionFailure("The real Chisel Marker definition must encode as an object")
    }
    material["interaction"] = "wetMix"
    object["material"] = material
    return try JSONDecoder().decode(
        BrushDefinition.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}

private func logicalBatches(
    trace: StrokeTraceFixture,
    viewport: ViewportTransform,
    generator initialGenerator: BrushStrokeGenerator
) -> [LogicalDabBatch] {
    var input = BrushInputDeriver()
    var generator = initialGenerator
    var batches: [LogicalDabBatch] = []

    for sample in trace.samples where sample.kind != .predicted {
        let worldSample = input.derive(sample, viewport: viewport)
        switch worldSample.phase {
        case .began:
            batches.append(contentsOf: generator.beginBatches(worldSample))
        case .moved:
            batches.append(contentsOf: generator.appendBatches(worldSample))
        case .ended:
            batches.append(contentsOf: generator.finishBatches(worldSample))
        case .cancelled:
            generator.cancel()
        }
    }
    return batches
}
