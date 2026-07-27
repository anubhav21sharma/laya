import EditorCore
import Foundation
import PatternEngine

let viewport = ViewportTransform(
    drawableSize: PatternSize(width: 256, height: 256),
    worldCenter: WorldPoint(x: 128, y: 128)
)
let traces = [
    StrokeTraceFixtures.pressureRamp,
    StrokeTraceFixtures.curved,
    StrokeTraceFixtures.predictionCorrection,
]
let records = AnchorBrushCatalog.all.flatMap { anchor in
    traces.map { trace in
        BrushCharacterizer.record(
            trace: trace,
            recipe: anchor.recipe,
            nominalDiameter: 20,
            color: .black,
            seed: 41,
            viewport: viewport
        )
    }
}
.sorted { ($0.recipeID, $0.traceName) < ($1.recipeID, $1.traceName) }

let baseline = try BrushLogicalBaseline(
    validatingSchemaVersion: BrushLogicalBaseline.schemaVersion,
    records: records
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(baseline))
