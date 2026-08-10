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
        _ url: URL,
        identities: ProfessionalSceneIdentitySet,
        positiveCharacterizations: [ProfessionalBrushCharacterizationRecord]
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
              records.count == 40
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
        let expected = identities.definitionIDs.flatMap { brushID in
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
              baseline.records.allSatisfy({
                  isValidRecord($0, identities: identities)
              }),
              Set(positiveCharacterizations.map {
                  "\($0.brushID)\u{0}\($0.traceName)"
              }).count == positiveCharacterizations.count,
              positiveCharacterizations.count
                == ProfessionalBrushTruth.positiveSceneNames.count,
              positiveCharacterizations.allSatisfy({
                  baseline.records.contains($0)
              })
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

    private static func isValidRecord(
        _ record: ProfessionalBrushCharacterizationRecord,
        identities: ProfessionalSceneIdentitySet
    ) -> Bool {
        guard let identity = identities.identity(
            definitionID: record.brushID
        ) else {
            return false
        }
        return record.schemaVersion
                == ProfessionalBrushLogicalBaseline.schemaVersion
            && record.family == identity.family
            && record.definitionSemanticHash
                == identity.definitionSemanticHash
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
