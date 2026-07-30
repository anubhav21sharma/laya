import Foundation
import PatternEngine

enum CharacterizationValidator {
    private static let recordKeys: Set<String> = [
        "schemaVersion", "family", "brushID",
        "definitionSemanticHash", "traceName", "sampleCount",
        "logicalDabCount", "logicalDabDigest", "minimumDiameter",
        "maximumDiameter", "minimumFlow", "maximumFlow",
        "minimumOpacity", "maximumOpacity", "minimumHardness",
        "maximumHardness", "minimumGrainScale", "maximumGrainScale",
        "minimumRotation", "maximumRotation",
        "minimumScatterMagnitude", "maximumScatterMagnitude",
        "worldBounds",
    ]
    private static let boundsKeys: Set<String> = [
        "minimumX", "minimumY", "maximumX", "maximumY",
    ]

    static func validateBaseline(
        _ url: URL
    ) throws -> ProfessionalBrushLogicalBaseline {
        let data = try ArtifactFileSystem.regularFileData(
            url,
            label: "professional characterization baseline"
        )
        let object = try ArtifactFileSystem.jsonObject(
            data,
            label: "professional characterization baseline"
        )
        try ArtifactFileSystem.requireExactKeys(
            object,
            ["schemaVersion", "records"],
            label: "professional characterization baseline"
        )
        guard let records = object["records"] as? [[String: Any]],
              records.count == 40,
              ArtifactFileSystem.sha256(data)
                == ProfessionalBrushTruth
                    .professionalCharacterizationBaselineSHA256
        else {
            throw ArtifactFileSystem.invalid(
                "professional characterization baseline is not the exact golden baseline"
            )
        }
        for record in records {
            try validateRecordKeys(record)
        }
        let baseline: ProfessionalBrushLogicalBaseline
        do {
            baseline = try JSONDecoder().decode(
                ProfessionalBrushLogicalBaseline.self,
                from: data
            )
        } catch {
            throw ArtifactFileSystem.invalid(
                "professional characterization baseline is malformed"
            )
        }
        let expected = ProfessionalBrushTruth.sceneTruth.values
            .map(\.definitionID).sorted().flatMap { brushID in
                ProfessionalBrushTruth.traces.map {
                    "\(brushID)\u{0}\($0)"
                }
            }
        let actual = baseline.records.map {
            "\($0.brushID)\u{0}\($0.traceName)"
        }
        guard baseline.schemaVersion
                == ProfessionalBrushLogicalBaseline.schemaVersion,
              actual == expected,
              baseline.records.allSatisfy(isExactRecord)
        else {
            throw ArtifactFileSystem.invalid(
                "professional characterization baseline membership or record truth is not exact"
            )
        }
        return baseline
    }

    static func decodeRecord(
        _ data: Data,
        label: String
    ) throws -> ProfessionalBrushCharacterizationRecord {
        let object = try ArtifactFileSystem.jsonObject(data, label: label)
        try validateRecordKeys(object)
        do {
            return try JSONDecoder().decode(
                ProfessionalBrushCharacterizationRecord.self,
                from: data
            )
        } catch {
            throw ArtifactFileSystem.invalid("\(label) is malformed")
        }
    }

    private static func validateRecordKeys(
        _ record: [String: Any]
    ) throws {
        try ArtifactFileSystem.requireExactKeys(
            record,
            recordKeys,
            label: "professional characterization record"
        )
        guard let bounds = record["worldBounds"] as? [String: Any]
        else {
            throw ArtifactFileSystem.invalid(
                "characterization world bounds are malformed"
            )
        }
        try ArtifactFileSystem.requireExactKeys(
            bounds,
            boundsKeys,
            label: "characterization world bounds"
        )
    }

    private static func isExactRecord(
        _ record: ProfessionalBrushCharacterizationRecord
    ) -> Bool {
        guard let truth = ProfessionalBrushTruth.truthByDefinitionID[
            record.brushID
        ] else {
            return false
        }
        return record.schemaVersion
                == ProfessionalBrushLogicalBaseline.schemaVersion
            && record.family == truth.family
            && record.definitionSemanticHash == truth.semanticHash
            && ProfessionalBrushTruth.traces.contains(record.traceName)
            && record.sampleCount > 0
            && record.logicalDabCount > 0
            && record.logicalDabDigest.utf8.count == 16
            && record.logicalDabDigest.utf8.allSatisfy({
                (48 ... 57).contains($0) || (97 ... 102).contains($0)
            })
            && record.minimumDiameter > 0
            && record.minimumFlow >= 0
            && record.maximumFlow <= 1
            && record.minimumOpacity >= 0
            && record.maximumOpacity <= 1
            && record.minimumHardness >= 0
            && record.maximumHardness <= 1
            && record.minimumGrainScale > 0
            && record.minimumScatterMagnitude >= 0
    }
}
