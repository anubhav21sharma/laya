import Foundation

enum PhysicalEvidenceValidator {
    private struct DeviceRequirement {
        let platform: String
        let hardwarePrefix: String
        let gpuFragment: String
        let minimumRefreshHertz: Double
        let inputKind: String
        let inputVendor: String
        let inputModelFragment: String
        let telemetry: String
        let predictionMode: String
    }

    private static let profileRequirements: [String: DeviceRequirement] = [
        "a14Floor60Hz": .init(
            platform: "iPadOS", hardwarePrefix: "iPad",
            gpuFragment: "A14", minimumRefreshHertz: 60,
            inputKind: "touch", inputVendor: "Apple",
            inputModelFragment: "Multi-Touch",
            telemetry: "UITouch.timestamp", predictionMode: "none"
        ),
        "inputToPhoton": .init(
            platform: "iPadOS", hardwarePrefix: "iPad",
            gpuFragment: "Apple", minimumRefreshHertz: 60,
            inputKind: "applePencil", inputVendor: "Apple",
            inputModelFragment: "Apple Pencil",
            telemetry: "UIEvent.coalescedTouches+predictedTouches",
            predictionMode: "coalescedAndPredicted"
        ),
        "memoryWarning": .init(
            platform: "iPadOS", hardwarePrefix: "iPad",
            gpuFragment: "Apple", minimumRefreshHertz: 60,
            inputKind: "touch", inputVendor: "Apple",
            inputModelFragment: "Multi-Touch",
            telemetry: "UITouch.timestamp", predictionMode: "none"
        ),
        "pencil": .init(
            platform: "iPadOS", hardwarePrefix: "iPad",
            gpuFragment: "Apple", minimumRefreshHertz: 60,
            inputKind: "applePencil", inputVendor: "Apple",
            inputModelFragment: "Apple Pencil",
            telemetry: "UIEvent.coalescedTouches+predictedTouches",
            predictionMode: "coalescedAndPredicted"
        ),
        "referenceMSeriesProMotion120Hz": .init(
            platform: "iPadOS", hardwarePrefix: "iPad",
            gpuFragment: "Apple", minimumRefreshHertz: 120,
            inputKind: "touch", inputVendor: "Apple",
            inputModelFragment: "Multi-Touch",
            telemetry: "UITouch.timestamp", predictionMode: "none"
        ),
        "suspendResume": .init(
            platform: "iPadOS", hardwarePrefix: "iPad",
            gpuFragment: "Apple", minimumRefreshHertz: 60,
            inputKind: "touch", inputVendor: "Apple",
            inputModelFragment: "Multi-Touch",
            telemetry: "UITouch.timestamp", predictionMode: "none"
        ),
        "sustainedThermal": .init(
            platform: "iPadOS", hardwarePrefix: "iPad",
            gpuFragment: "Apple", minimumRefreshHertz: 60,
            inputKind: "touch", inputVendor: "Apple",
            inputModelFragment: "Multi-Touch",
            telemetry: "UITouch.timestamp", predictionMode: "none"
        ),
        "wacom": .init(
            platform: "macOS", hardwarePrefix: "Mac",
            gpuFragment: "Apple M", minimumRefreshHertz: 60,
            inputKind: "wacomStylus", inputVendor: "Wacom",
            inputModelFragment: "Wacom",
            telemetry: "NSEvent.tabletPoint", predictionMode: "coalesced"
        ),
    ]

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
        guard profileIDs == Set(profileRequirements.keys) else {
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
        guard integer(evidence["schemaVersion"]) == 1,
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
              let requirement = profileRequirements[profileID],
              validDevice(device, requirement: requirement),
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
              let truth = ProfessionalBrushTruth
                .truthByDefinitionID[definitionID],
              workload["semanticHash"] as? String == truth.semanticHash,
              validResources(
                  workload["resolvedResources"],
                  truth: truth
              ),
              workload["rawTracePath"] as? String
                == "raw/\(definitionID).json",
              let digest = workload["rawTraceSHA256"] as? String,
              ArtifactFileSystem.isSHA256(digest)
        else {
            throw ArtifactFileSystem.invalid(
                "\(profileID): physical workload identity or resources are invalid"
            )
        }
        let rawURL = rawRoot.appendingPathComponent(
            "\(definitionID).json"
        )
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
                "resolvedResources", "inputSampleCount", "inputSamples",
                "cpuPreparationMilliseconds", "gpu500DabMilliseconds",
                "missedFrameFlags", "compilerCountersBefore",
                "compilerCountersAfter",
            ],
            label: "\(profileID) raw physical trace"
        )
        guard integer(raw["schemaVersion"]) == 1,
              raw["profileID"] as? String == profileID,
              raw["scenarioID"] as? String
                == "professional-\(profileID)",
              dictionariesEqual(raw["source"], source),
              dictionariesEqual(raw["device"], device),
              raw["definitionID"] as? String == definitionID,
              raw["semanticHash"] as? String == truth.semanticHash,
              validResources(raw["resolvedResources"], truth: truth),
              let count = integer(raw["inputSampleCount"]),
              count >= 20,
              let samples = raw["inputSamples"] as? [[String: Any]],
              validInputSamples(
                  samples,
                  count: count,
                  predictionMode: device["predictionMode"] as? String
              ),
              let cpu = doubles(raw["cpuPreparationMilliseconds"]),
              let gpu = doubles(raw["gpu500DabMilliseconds"]),
              cpu.count == count,
              !gpu.isEmpty,
              percentile95(cpu) < 2,
              gpu.max()! < 3,
              let missed = integers(raw["missedFrameFlags"]),
              missed.count == count,
              missed.allSatisfy({ $0 == 0 || $0 == 1 }),
              Double(missed.reduce(0, +)) / Double(count) < 0.01,
              validUnchangedCounters(
                  raw["compilerCountersBefore"],
                  raw["compilerCountersAfter"]
              )
        else {
            throw ArtifactFileSystem.invalid(
                "\(profileID): raw physical measurements are malformed or failed"
            )
        }
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

    private static func validDevice(
        _ device: [String: Any],
        requirement: DeviceRequirement
    ) -> Bool {
        guard Set(device.keys) == [
            "platform", "hardwareModel", "gpuName", "gpuRegistryID",
            "displayRefreshHertz", "inputKind", "inputVendor",
            "inputModel", "inputTelemetryProvenance", "predictionMode",
        ],
            device["platform"] as? String == requirement.platform,
            let hardware = device["hardwareModel"] as? String,
            hardware.hasPrefix(requirement.hardwarePrefix),
            let gpu = device["gpuName"] as? String,
            ArtifactFileSystem.gpuClassification(gpu) == "physical",
            gpu.localizedCaseInsensitiveContains(requirement.gpuFragment),
            ArtifactFileSystem.nonemptyString(device, "gpuRegistryID") != nil,
            let refresh = number(
                device["displayRefreshHertz"]
            )?.doubleValue,
            refresh.isFinite,
            refresh >= requirement.minimumRefreshHertz,
            device["inputKind"] as? String == requirement.inputKind,
            device["inputVendor"] as? String == requirement.inputVendor,
            let model = device["inputModel"] as? String,
            model.localizedCaseInsensitiveContains(
                requirement.inputModelFragment
            ),
            device["inputTelemetryProvenance"] as? String
                == requirement.telemetry,
            device["predictionMode"] as? String
                == requirement.predictionMode
        else {
            return false
        }
        return true
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

    private static func validInputSamples(
        _ samples: [[String: Any]],
        count: Int,
        predictionMode: String?
    ) -> Bool {
        guard samples.count == count,
              samples.indices.allSatisfy({
                  Set(samples[$0].keys) == [
                      "timestampNanoseconds", "phase", "kind",
                      "pressure", "x", "y",
                  ]
              }),
              samples.first?["phase"] as? String == "began",
              samples.last?["phase"] as? String == "ended",
              samples.dropFirst().dropLast().allSatisfy({
                  $0["phase"] as? String == "moved"
              })
        else {
            return false
        }
        let timestamps = samples.compactMap {
            integer($0["timestampNanoseconds"])
        }
        guard timestamps.count == count,
              zip(timestamps, timestamps.dropFirst()).allSatisfy(<),
              samples.allSatisfy({
                  guard let pressure =
                      number($0["pressure"])?.doubleValue,
                      let x = number($0["x"])?.doubleValue,
                      let y = number($0["y"])?.doubleValue
                  else { return false }
                  return pressure.isFinite && (0...1).contains(pressure)
                      && x.isFinite && y.isFinite
              })
        else {
            return false
        }
        let kinds = Set(samples.compactMap { $0["kind"] as? String })
        switch predictionMode {
        case "none":
            return kinds == ["actual"]
        case "coalesced":
            return kinds.contains("actual")
                && kinds.contains("coalesced")
                && kinds.isSubset(of: ["actual", "coalesced"])
        case "coalescedAndPredicted":
            return kinds.contains("actual")
                && kinds.contains("coalesced")
                && kinds.contains("predicted")
                && kinds.isSubset(
                    of: ["actual", "coalesced", "predicted"]
                )
        default:
            return false
        }
    }

    private static func validUnchangedCounters(
        _ before: Any?,
        _ after: Any?
    ) -> Bool {
        guard let before = before as? [String: Any],
              let after = after as? [String: Any],
              Set(before.keys) == counterKeys,
              Set(after.keys) == counterKeys,
              before.keys.allSatisfy({
                  let lhs = unsignedInteger(before[$0])
                  let rhs = unsignedInteger(after[$0])
                  return lhs != nil && lhs == rhs
              })
        else {
            return false
        }
        return true
    }

    private static let counterKeys: Set<String> = [
        "packageDecodeCount", "imageDecodeCount", "textureUploadCount",
        "cacheHitCount", "activationCount",
    ]

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
        guard result.count == values.count else { return nil }
        return !result.isEmpty
            && result.allSatisfy({ $0.isFinite && $0 >= 0 })
            ? result : nil
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

    private static func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[
            max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        ]
    }
}
