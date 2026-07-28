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
} else if arguments.first == "record-foundation" {
    guard arguments.count == 7,
          arguments[1] == "--logical-output",
          arguments[3] == "--parity-output",
          arguments[5] == "--commit"
    else {
        throw ToolError.usage
    }
    let records = anchorCharacterizationRecords()
    let baseline = try BrushLogicalBaseline(
        validatingSchemaVersion: BrushLogicalBaseline.schemaVersion,
        records: records.map(\.program)
    )
    let parity = BrushAnchorAdapterParityEvidence(
        commit: arguments[6],
        records: records.map {
            BrushAnchorAdapterParityRecord(
                recipeID: $0.program.recipeID,
                traceName: $0.program.traceName,
                programLogicalDabCount: $0.program.logicalDabCount,
                compatibilityLogicalDabCount:
                    $0.compatibility.logicalDabCount,
                programLogicalDabDigest: $0.program.logicalDabDigest,
                compatibilityLogicalDabDigest:
                    $0.compatibility.logicalDabDigest
            )
        }
    )
    let logicalEncoder = JSONEncoder()
    logicalEncoder.outputFormatting = [.sortedKeys]
    try logicalEncoder.encode(baseline).write(
        to: URL(fileURLWithPath: arguments[2]),
        options: .atomic
    )
    let parityEncoder = JSONEncoder()
    parityEncoder.outputFormatting = [
        .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
    ]
    try parityEncoder.encode(parity).write(
        to: URL(fileURLWithPath: arguments[4]),
        options: .atomic
    )
    print(
        "BRUSH FOUNDATION LOGICAL EVIDENCE records=\(baseline.records.count)"
    )
} else {
    let records = anchorCharacterizationRecords().map(\.program)

    let baseline = try BrushLogicalBaseline(
        validatingSchemaVersion: BrushLogicalBaseline.schemaVersion,
        records: records
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(baseline))
}

private func anchorCharacterizationRecords() -> [(
    program: BrushCharacterizationRecord,
    compatibility: BrushCharacterizationRecord
)] {
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
            (
                program: BrushCharacterizer.record(
                    trace: trace,
                    program: anchor.program,
                    nominalDiameter: 20,
                    color: .black,
                    seed: 41,
                    viewport: viewport
                ),
                compatibility: BrushCharacterizer.record(
                    trace: trace,
                    program: anchor.program,
                    nominalDiameter: 20,
                    color: .black,
                    seed: 41,
                    viewport: viewport
                )
            )
        }
    }
    .sorted {
        ($0.program.recipeID, $0.program.traceName)
            < ($1.program.recipeID, $1.program.traceName)
    }
}

private enum ToolError: Error, LocalizedError {
    case usage

    var errorDescription: String? {
        "Usage: BrushCharacterizationTool merge-renderer --input-root <path> --output <path> | validate-renderer --baseline <path> --expected-record-count <count> | record-foundation --logical-output <path> --parity-output <path> --commit <commit>"
    }
}
