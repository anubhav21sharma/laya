import BrushFormat
import EditorCore
import Foundation
import PatternEngine
import Testing

@Test
func anchorCatalogMatchesImmutablePreTaskSixBaseline() throws {
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 256, height: 256),
        worldCenter: WorldPoint(x: 128, y: 128)
    )
    let traces = [
        StrokeTraceFixtures.pressureRamp,
        StrokeTraceFixtures.curved,
        StrokeTraceFixtures.predictionCorrection,
    ]
    let actual = AnchorBrushCatalog.all.flatMap { anchor in
        traces.map { trace in
            BrushCharacterizer.record(
                trace: trace,
                program: anchor.program,
                nominalDiameter: 20,
                color: .black,
                seed: 41,
                viewport: viewport
            )
        }
    }.sorted {
        ($0.recipeID, $0.traceName) < ($1.recipeID, $1.traceName)
    }
    let data = try characterizationFixture(named: "brush-logical-v1")
    let baseline = try JSONDecoder().decode(
        BrushLogicalBaseline.self,
        from: data
    )

    #expect(baseline.records.count == 18)
    #expect(Set(baseline.records.map(\.recipeID))
        == Set(AnchorBrushCatalog.all.map { $0.id.rawValue }))
    try baseline.requireMatches(actual)

    let corrupted = try JSONDecoder().decode(
        BrushLogicalBaseline.self,
        from: corruptFirstLogicalDigest(in: data)
    )
    #expect(throws: BrushLogicalBaselineError.mismatch) {
        try corrupted.requireMatches(actual)
    }
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
    let baselineData = try characterizationFixture(
        named: "professional-brush-logical-v1"
    )
    let baseline = try JSONDecoder().decode(
        ProfessionalBrushLogicalBaseline.self,
        from: baselineData
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
    #expect(records.map { "\($0.brushID)\u{0}\($0.traceName)" } == expectedRecordKeys)
    #expect(throws: ProfessionalBrushLogicalBaselineError.recordsNotSorted) {
        _ = try ProfessionalBrushLogicalBaseline(
            validatingSchemaVersion: ProfessionalBrushLogicalBaseline.schemaVersion,
            records: unsortedRecords
        )
    }
    #expect(directionRecords == predictionFreeRecords)
    try baseline.requireMatches(records)
    let corrupted = try JSONDecoder().decode(
        ProfessionalBrushLogicalBaseline.self,
        from: corruptFirstLogicalDigest(in: baselineData)
    )
    #expect(throws: ProfessionalBrushLogicalBaselineError.mismatch) {
        try corrupted.requireMatches(records)
    }
    #expect(throws: BrushDefinitionValidationError.missingCapability("wetMix")) {
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

private func characterizationFixture(named name: String) throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    return try Data(contentsOf: url)
}

private func corruptFirstLogicalDigest(in data: Data) throws -> Data {
    guard var root = try JSONSerialization.jsonObject(with: data)
            as? [String: Any],
          var records = root["records"] as? [[String: Any]],
          var first = records.first,
          let digest = first["logicalDabDigest"] as? String,
          !digest.isEmpty
    else {
        throw CocoaError(.fileReadCorruptFile)
    }
    first["logicalDabDigest"] = String(
        repeating: digest.first == "0" ? "1" : "0",
        count: digest.count
    )
    records[0] = first
    root["records"] = records
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
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
