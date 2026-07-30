import BrushDepositionEvidenceValidation
import Foundation

enum PhysicalEvidenceValidator {
    static func validate(
        root: URL,
        expectedCommit: String,
        expectedSourceTreeSHA256: String,
        expectedRendererSHA256: String
    ) throws -> Bool {
        let profileIDs = try ArtifactFileSystem.entryNames(root)
        if profileIDs.isEmpty {
            return false
        }
        guard profileIDs
                == Set(StageFourEvidenceValidator.requiredPhysicalProfiles)
        else {
            throw ArtifactFileSystem.invalid(
                "physical evidence must be empty or contain the exact eight-profile set"
            )
        }
        for profileID in profileIDs.sorted() {
            try validateProfile(
                root.appendingPathComponent(profileID),
                profileID: profileID,
                expectedCommit: expectedCommit,
                expectedSourceTreeSHA256: expectedSourceTreeSHA256,
                expectedRendererSHA256: expectedRendererSHA256
            )
        }
        return true
    }

    private static func validateProfile(
        _ directory: URL,
        profileID: String,
        expectedCommit: String,
        expectedSourceTreeSHA256: String,
        expectedRendererSHA256: String
    ) throws {
        guard try ArtifactFileSystem.entryNames(directory)
                == ["evidence.json", "raw"]
        else {
            throw ArtifactFileSystem.invalid(
                "\(profileID): physical evidence file set is not exact"
            )
        }
        let data = try ArtifactFileSystem.regularFileData(
            directory.appendingPathComponent("evidence.json"),
            label: "\(profileID) physical evidence"
        )
        let evidence = try ArtifactFileSystem.jsonObject(
            data,
            label: "\(profileID) physical evidence"
        )
        try ArtifactFileSystem.requireExactKeys(
            evidence,
            [
                "schemaVersion", "profileID", "scenarioID", "source",
                "device", "workloads",
            ],
            label: "\(profileID) physical evidence"
        )
        guard integer(evidence["schemaVersion"]) == 2,
              evidence["profileID"] as? String == profileID,
              evidence["scenarioID"] as? String
                == "professional-\(profileID)",
              let source = evidence["source"] as? [String: Any],
              validSource(
                  source,
                  commit: expectedCommit,
                  tree: expectedSourceTreeSHA256,
                  renderer: expectedRendererSHA256
              ),
              let device = evidence["device"] as? [String: Any],
              let workloads = evidence["workloads"] as? [[String: Any]]
        else {
            throw ArtifactFileSystem.invalid(
                "\(profileID): physical identity or provenance is invalid"
            )
        }
        let rawRoot = directory.appendingPathComponent("raw")
        var rawNames: Set<String> = []
        var definitionIDs: [String] = []
        for workload in workloads {
            let definitionID = try validateWorkload(
                workload,
                profileID: profileID,
                source: source,
                device: device,
                rawRoot: rawRoot
            )
            definitionIDs.append(definitionID)
            rawNames.insert("\(definitionID).json")
        }
        guard definitionIDs == ProfessionalBrushTruth
                .truthByDefinitionID.keys.sorted(),
              Set(definitionIDs).count == definitionIDs.count,
              try ArtifactFileSystem.entryNames(rawRoot) == rawNames
        else {
            throw ArtifactFileSystem.invalid(
                "\(profileID): physical workloads are not the exact four-brush set"
            )
        }
    }

    private static func validateWorkload(
        _ workload: [String: Any],
        profileID: String,
        source: [String: Any],
        device: [String: Any],
        rawRoot: URL
    ) throws -> String {
        try ArtifactFileSystem.requireExactKeys(
            workload,
            [
                "definitionID", "semanticHash", "resolvedResources",
                "rawTracePath", "rawTraceSHA256",
            ],
            label: "\(profileID) physical workload"
        )
        guard let definitionID = workload["definitionID"] as? String,
              let truth =
                ProfessionalBrushTruth.truthByDefinitionID[definitionID],
              workload["semanticHash"] as? String == truth.semanticHash,
              validResources(workload["resolvedResources"], truth: truth),
              workload["rawTracePath"] as? String
                == "raw/\(definitionID).json",
              let digest = workload["rawTraceSHA256"] as? String,
              ArtifactFileSystem.isSHA256(digest)
        else {
            throw ArtifactFileSystem.invalid(
                "\(profileID): physical workload identity or resources are invalid"
            )
        }
        let rawURL = rawRoot.appendingPathComponent("\(definitionID).json")
        let rawData = try ArtifactFileSystem.regularFileData(
            rawURL,
            label: "\(profileID) \(definitionID) raw physical trace"
        )
        guard ArtifactFileSystem.sha256(rawData) == digest else {
            throw ArtifactFileSystem.invalid(
                "\(profileID): raw physical trace digest changed"
            )
        }
        let raw = try ArtifactFileSystem.jsonObject(
            rawData,
            label: "\(profileID) \(definitionID) raw physical trace"
        )
        try ArtifactFileSystem.requireExactKeys(
            raw,
            [
                "schemaVersion", "profileID", "scenarioID", "source",
                "device", "definitionID", "semanticHash",
                "resolvedResources", "sampleCount",
                "sampleTimestampsNanoseconds", "events", "measurements",
                "compilerCountersBefore", "compilerCountersAfter",
            ],
            label: "\(profileID) raw physical trace"
        )
        guard integer(raw["schemaVersion"]) == 2,
              raw["profileID"] as? String == profileID,
              raw["scenarioID"] as? String
                == "professional-\(profileID)",
              dictionariesEqual(raw["source"], source),
              dictionariesEqual(raw["device"], device),
              raw["definitionID"] as? String == definitionID,
              raw["semanticHash"] as? String == truth.semanticHash,
              validResources(raw["resolvedResources"], truth: truth),
              let sampleCount = integer(raw["sampleCount"]),
              let timestamps =
                integers(raw["sampleTimestampsNanoseconds"]),
              let events = raw["events"] as? [[String: Any]],
              let measurements = measurements(raw["measurements"]),
              validUnchangedCounters(
                  raw["compilerCountersBefore"],
                  raw["compilerCountersAfter"]
              )
        else {
            throw ArtifactFileSystem.invalid(
                "\(profileID): raw physical trace is malformed"
            )
        }
        try StageFourEvidenceValidator.validatePhysicalProfileTrace(
            profileID: profileID,
            device: device,
            sampleCount: sampleCount,
            sampleTimestampsNanoseconds: timestamps,
            events: events,
            measurements: measurements
        )
        return definitionID
    }

    private static func validSource(
        _ source: [String: Any],
        commit: String,
        tree: String,
        renderer: String
    ) -> Bool {
        Set(source.keys) == [
            "commit", "sourceTreeSHA256", "rendererExecutableSHA256",
        ]
            && source["commit"] as? String == commit
            && ArtifactFileSystem.isCommit(commit)
            && source["sourceTreeSHA256"] as? String == tree
            && ArtifactFileSystem.isSHA256(tree)
            && source["rendererExecutableSHA256"] as? String == renderer
            && ArtifactFileSystem.isSHA256(renderer)
    }

    private static func validResources(
        _ value: Any?,
        truth: ProfessionalSceneTruth
    ) -> Bool {
        guard let values = value as? [[String: Any]] else { return false }
        let expected = truth.resourceLevels.keys.sorted()
        guard values.count == expected.count else { return false }
        return zip(values, expected).allSatisfy { value, identity in
            Set(value.keys) == ["identity", "kind", "mipCount"]
                && value["identity"] as? String == identity
                && value["kind"] as? String
                    == (identity.hasPrefix("builtin.shape.")
                        ? "shape" : "grain")
                && integer(value["mipCount"])
                    == truth.resourceLevels[identity]
        }
    }

    private static func measurements(
        _ value: Any?
    ) -> [String: [Double]]? {
        guard let object = value as? [String: Any] else { return nil }
        var result: [String: [Double]] = [:]
        for (key, value) in object {
            guard let series = doubles(value) else { return nil }
            result[key] = series
        }
        return result
    }

    private static let counterKeys: Set<String> = [
        "packageDecodeCount", "imageDecodeCount", "textureUploadCount",
        "cacheHitCount", "activationCount",
    ]

    private static func validUnchangedCounters(
        _ before: Any?,
        _ after: Any?
    ) -> Bool {
        guard let before = before as? [String: Any],
              let after = after as? [String: Any],
              Set(before.keys) == counterKeys,
              Set(after.keys) == counterKeys
        else {
            return false
        }
        return before.keys.allSatisfy {
            unsignedInteger(before[$0])
                == unsignedInteger(after[$0])
                && unsignedInteger(before[$0]) != nil
        }
    }

    private static func dictionariesEqual(
        _ value: Any?,
        _ expected: [String: Any]
    ) -> Bool {
        guard let value = value as? [String: Any] else { return false }
        return NSDictionary(dictionary: value).isEqual(to: expected)
    }

    private static func doubles(_ value: Any?) -> [Double]? {
        guard let values = value as? [Any] else { return nil }
        let result = values.compactMap { number($0)?.doubleValue }
        guard result.count == values.count,
              !result.isEmpty,
              result.allSatisfy({ $0.isFinite && $0 >= 0 })
        else {
            return nil
        }
        return result
    }

    private static func integers(_ value: Any?) -> [Int]? {
        guard let values = value as? [Any] else { return nil }
        let result = values.compactMap(integer)
        return result.count == values.count ? result : nil
    }

    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        return number
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value) else { return nil }
        return Int(number.stringValue)
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let number = number(value) else { return nil }
        return UInt64(number.stringValue)
    }
}
