import EditorCore
import Foundation
import MetalRenderer
import PatternEngine

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "merge-renderer" {
    guard arguments.count == 5,
          arguments[1] == "--input-root",
          arguments[3] == "--output"
    else {
        throw ToolError.usage
    }
    let baseline = try BrushCharacterizationBaseline.merge(
        inputRoot: URL(fileURLWithPath: arguments[2])
    )
    try baseline.writeAtomically(to: URL(fileURLWithPath: arguments[4]))
} else if arguments.first == "validate-renderer" {
    guard arguments.count == 5,
          arguments[1] == "--baseline",
          arguments[3] == "--expected-record-count",
          let expectedCount = Int(arguments[4])
    else {
        throw ToolError.usage
    }
    let baseline = try JSONDecoder().decode(
        BrushCharacterizationBaseline.self,
        from: Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    )
    try baseline.validate(expectedRecordCount: expectedCount)
    print("BRUSH CHARACTERIZATION VALID records=\(baseline.records.count)")
} else {
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
}

private enum ToolError: Error, LocalizedError {
    case usage

    var errorDescription: String? {
        "Usage: BrushCharacterizationTool merge-renderer --input-root <path> --output <path> | validate-renderer --baseline <path> --expected-record-count <count>"
    }
}
