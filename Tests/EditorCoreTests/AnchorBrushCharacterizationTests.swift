import EditorCore
import Foundation
import PatternEngine
import Testing

@Test
func anchorRecipesMatchTheSortedLogicalDabBaseline() throws {
    let records = anchorRecords()

    #expect(records.count == 15)
    #expect(Set(records.map(\.recipeID)).count == 5)
    #expect(Set(records.map(\.logicalDabDigest)).count >= 10)
    #expect(records.allSatisfy { $0.logicalDabCount > 0 })

    let fixtureURL = try #require(
        Bundle.module.url(
            forResource: "brush-logical-v1",
            withExtension: "json",
            subdirectory: "Fixtures"
        )
    )
    let fixtureData = try Data(contentsOf: fixtureURL)
    let baseline = try JSONDecoder().decode(
        BrushLogicalBaseline.self,
        from: fixtureData
    )
    try baseline.requireMatches(records)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let firstEncoding = try encoder.encode(baseline)
    let decoded = try JSONDecoder().decode(
        BrushLogicalBaseline.self,
        from: firstEncoding
    )
    #expect(try encoder.encode(decoded) == firstEncoding)

    var changed = records
    let first = try #require(changed.first)
    changed[0] = BrushCharacterizationRecord(
        schemaVersion: first.schemaVersion,
        traceName: first.traceName,
        recipeID: first.recipeID,
        nominalDiameter: first.nominalDiameter,
        seed: first.seed,
        sampleCount: first.sampleCount,
        logicalDabCount: first.logicalDabCount,
        logicalDabDigest: "0000000000000000"
    )
    #expect(throws: Error.self) {
        try baseline.requireMatches(changed)
    }
}

@Test
func allAnchorTraceProgramBatchesMatchCompatibilityRecipeBatches() {
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 256, height: 256),
        worldCenter: WorldPoint(x: 128, y: 128)
    )
    let traces = [
        StrokeTraceFixtures.pressureRamp,
        StrokeTraceFixtures.curved,
        StrokeTraceFixtures.predictionCorrection,
    ]
    var comparisonCount = 0

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
            let compatibilityBatches = logicalBatches(
                trace: trace,
                viewport: viewport,
                generator: BrushStrokeGenerator(
                    recipe: anchor.compatibilityRecipe,
                    nominalDiameter: 20,
                    color: .black,
                    seed: 41
                )
            )

            #expect(programBatches == compatibilityBatches)
            comparisonCount += 1
        }
    }

    #expect(comparisonCount == 15)
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

private func anchorRecords() -> [BrushCharacterizationRecord] {
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 256, height: 256),
        worldCenter: WorldPoint(x: 128, y: 128)
    )
    let traces = [
        StrokeTraceFixtures.pressureRamp,
        StrokeTraceFixtures.curved,
        StrokeTraceFixtures.predictionCorrection,
    ]
    return AnchorBrushCatalog.all.flatMap { anchor in
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
    }
    .sorted {
        ($0.recipeID, $0.traceName) < ($1.recipeID, $1.traceName)
    }
}
