import BrushFormat
import EditorCore
import Foundation
import PatternEngine

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments {
case []:
    let records = anchorCharacterizationRecords()
    let baseline = try BrushLogicalBaseline(
        validatingSchemaVersion: BrushLogicalBaseline.schemaVersion,
        records: records
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(baseline))
case ["professional"]:
    let baseline = try professionalCharacterizationBaseline()
    FileHandle.standardOutput.write(try baseline.encoded())
default:
    FileHandle.standardError.write(
        Data(
            "usage: BrushCharacterizationTool [professional]\n".utf8
        )
    )
    exit(1)
}

private func anchorCharacterizationRecords()
    -> [BrushCharacterizationRecord]
{
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

private func professionalCharacterizationBaseline() throws
    -> ProfessionalBrushLogicalBaseline
{
    let records = try ProfessionalBrushCatalog.all.flatMap { entry in
        let package = try BrushPackage(
            manifest: BrushPackageManifest(resources: []),
            definition: entry.definition,
            resourceData: [:]
        )
        let hash = try package.contentHash
        return try StrokeTraceFixtures.professional.map { trace in
            try ProfessionalBrushCharacterizer.record(
                family: entry.displayName,
                definitionSemanticHash: hash,
                trace: trace,
                program: entry.program
            )
        }
    }
    .sorted {
        ($0.brushID, $0.traceName) < ($1.brushID, $1.traceName)
    }
    return try ProfessionalBrushLogicalBaseline(
        validatingSchemaVersion:
            ProfessionalBrushLogicalBaseline.schemaVersion,
        records: records
    )
}
