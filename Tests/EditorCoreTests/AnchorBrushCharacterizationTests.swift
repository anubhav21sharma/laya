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
