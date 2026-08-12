import BrushFormat
import EditorCore
import Foundation
import PatternEngine
import Testing

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
        let material = $0.definition.components[0].material
        return material.interaction == .none
            && material.wetness == 0
            && material.bleedRadius == 0
            && material.softenPasses == 0
            && material.interactionParameters == nil
    })
    #expect(records.count == 40)
    #expect(records.map { "\($0.brushID)\u{0}\($0.traceName)" } == expectedRecordKeys)
    #expect(throws: ProfessionalBrushLogicalBaselineError.recordsNotSorted) {
        _ = try ProfessionalBrushLogicalBaseline(
            validatingSchemaVersion: ProfessionalBrushLogicalBaseline.schemaVersion,
            records: unsortedRecords
        )
    }
    #expect(directionRecords == predictionFreeRecords)
    #expect(
        throws: BrushDefinitionValidationError
            .unsupportedComponentInteraction(
                ordinal: 0,
                interaction: .wetMix
            )
    ) {
        try decodingMarkerWithWetInteraction()
    }
}

private func professionalDefinitionSemanticHash(_ definition: BrushDefinition) throws -> String {
    try BrushPackage(
        manifest: BrushPackageManifest(resources: []),
        definition: definition,
        resourceData: [:]
    ).contentHash
}

private func decodingMarkerWithWetInteraction() throws -> BrushDefinition {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(ProfessionalBrushCatalog.chiselMarker.definition)
    let jsonObject = try JSONSerialization.jsonObject(with: data)
    guard var object = jsonObject as? [String: Any],
          var components = object["components"] as? [[String: Any]],
          !components.isEmpty,
          var material = components[0]["material"] as? [String: Any]
    else {
        preconditionFailure("The real Chisel Marker definition must encode as an object")
    }
    material["interaction"] = "wetMix"
    components[0]["material"] = material
    object["components"] = components
    return try JSONDecoder().decode(
        BrushDefinition.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}
