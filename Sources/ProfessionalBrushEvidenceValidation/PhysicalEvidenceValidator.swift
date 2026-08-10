import Foundation

enum PhysicalEvidenceValidator {
    private static let requiredProfileIDs: Set<String> = [
        "a14Floor60Hz", "inputToPhoton", "memoryWarning", "pencil",
        "referenceMSeriesProMotion120Hz", "suspendResume",
        "sustainedThermal", "wacom",
    ]

    static func validate(
        root: URL,
        expectedCommit: String,
        expectedSourceTreeSHA256: String,
        expectedRendererSHA256: String,
        identities: ProfessionalSceneIdentitySet
    ) throws -> Bool {
        let profileIDs = try ArtifactFileSystem.entryNames(root)
        if profileIDs.isEmpty {
            return false
        }
        guard profileIDs == requiredProfileIDs
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
                expectedRendererSHA256: expectedRendererSHA256,
                identities: identities
            )
        }
        return true
    }

    private static func validateProfile(
        _ directory: URL,
        profileID: String,
        expectedCommit: String,
        expectedSourceTreeSHA256: String,
        expectedRendererSHA256: String,
        identities: ProfessionalSceneIdentitySet
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
                rawRoot: rawRoot,
                identities: identities
            )
            definitionIDs.append(definitionID)
            rawNames.insert("\(definitionID).json")
        }
        guard definitionIDs == identities.definitionIDs,
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
        rawRoot: URL,
        identities: ProfessionalSceneIdentitySet
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
                .contractByDefinitionID[definitionID],
              let identity = identities.identity(
                  definitionID: definitionID
              ),
              workload["semanticHash"] as? String
                == identity.definitionSemanticHash,
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
              raw["semanticHash"] as? String
                == identity.definitionSemanticHash,
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
        try validateCurrentPhysicalProfileTrace(
            profileID: profileID,
            device: device,
            sampleCount: sampleCount,
            sampleTimestampsNanoseconds: timestamps,
            events: events,
            measurements: measurements
        )
        return definitionID
    }

    private struct ProfileRequirement {
        let minimumSampleCount: Int
        let minimumDurationNanoseconds: Int
        let requiredEventCounts: [String: Int]
        let orderedEventKinds: [String]
        let metrics: [String: MetricRequirement]
    }

    private struct MetricRequirement {
        let aggregation: String
        let relation: String
        let threshold: Double
    }

    private static let profileRequirements: [String: ProfileRequirement] = [
        "a14Floor60Hz": .init(
            minimumSampleCount: 300,
            minimumDurationNanoseconds: 5_000_000_000,
            requiredEventCounts: [
                "displayFrame": 300, "inputSample": 300,
            ],
            orderedEventKinds: ["inputSample", "displayFrame"],
            metrics: [
                "cpuPreparationP95Milliseconds": .init(
                    aggregation: "p95", relation: "lessThan",
                    threshold: 2
                ),
                "gpu500DabMilliseconds": .init(
                    aggregation: "maximum", relation: "lessThan",
                    threshold: 3
                ),
                "missedFrameFraction": .init(
                    aggregation: "maximum", relation: "lessThan",
                    threshold: 0.01
                ),
            ]
        ),
        "inputToPhoton": .init(
            minimumSampleCount: 120,
            minimumDurationNanoseconds: 5_000_000_000,
            requiredEventCounts: [
                "inputEvent": 120, "photonObserved": 120,
            ],
            orderedEventKinds: ["inputEvent", "photonObserved"],
            metrics: [
                "inputToPhotonP95Milliseconds": .init(
                    aggregation: "p95", relation: "lessThan",
                    threshold: 16.667
                ),
            ]
        ),
        "memoryWarning": .init(
            minimumSampleCount: 5,
            minimumDurationNanoseconds: 5_000_000_000,
            requiredEventCounts: [
                "memoryWarning": 5, "rendererRecovered": 5,
            ],
            orderedEventKinds: ["memoryWarning", "rendererRecovered"],
            metrics: [
                "memoryWarningRecoveryMilliseconds": .init(
                    aggregation: "maximum", relation: "lessThan",
                    threshold: 1_000
                ),
                "recoveryFailureCount": .init(
                    aggregation: "sum", relation: "equal", threshold: 0
                ),
            ]
        ),
        "pencil": .init(
            minimumSampleCount: 240,
            minimumDurationNanoseconds: 1_000_000_000,
            requiredEventCounts: [
                "inputSample": 240, "renderedSample": 240,
            ],
            orderedEventKinds: ["inputSample", "renderedSample"],
            metrics: [
                "inputContinuityFailureCount": .init(
                    aggregation: "sum", relation: "equal", threshold: 0
                ),
                "predictionTransitionFailureCount": .init(
                    aggregation: "sum", relation: "equal", threshold: 0
                ),
            ]
        ),
        "referenceMSeriesProMotion120Hz": .init(
            minimumSampleCount: 600,
            minimumDurationNanoseconds: 5_000_000_000,
            requiredEventCounts: [
                "displayFrame": 600, "inputSample": 600,
            ],
            orderedEventKinds: ["inputSample", "displayFrame"],
            metrics: [
                "cpuPreparationP95Milliseconds": .init(
                    aggregation: "p95", relation: "lessThan",
                    threshold: 2
                ),
                "gpu500DabMilliseconds": .init(
                    aggregation: "maximum", relation: "lessThan",
                    threshold: 3
                ),
                "missedFrameFraction": .init(
                    aggregation: "maximum", relation: "lessThan",
                    threshold: 0.01
                ),
            ]
        ),
        "suspendResume": .init(
            minimumSampleCount: 5,
            minimumDurationNanoseconds: 5_000_000_000,
            requiredEventCounts: [
                "applicationSuspended": 5, "applicationResumed": 5,
                "rendererRecovered": 5,
            ],
            orderedEventKinds: [
                "applicationSuspended", "applicationResumed",
                "rendererRecovered",
            ],
            metrics: [
                "recoveryFailureCount": .init(
                    aggregation: "sum", relation: "equal", threshold: 0
                ),
                "suspendResumeRecoveryMilliseconds": .init(
                    aggregation: "maximum", relation: "lessThan",
                    threshold: 1_000
                ),
            ]
        ),
        "sustainedThermal": .init(
            minimumSampleCount: 600,
            minimumDurationNanoseconds: 600_000_000_000,
            requiredEventCounts: [
                "displayFrame": 600, "thermalStateSample": 600,
            ],
            orderedEventKinds: ["thermalStateSample", "displayFrame"],
            metrics: [
                "cpuPreparationP95Milliseconds": .init(
                    aggregation: "p95", relation: "lessThan",
                    threshold: 2
                ),
                "gpu500DabMilliseconds": .init(
                    aggregation: "maximum", relation: "lessThan",
                    threshold: 3
                ),
                "missedFrameFraction": .init(
                    aggregation: "maximum", relation: "lessThan",
                    threshold: 0.01
                ),
                "thermalDurationSeconds": .init(
                    aggregation: "sum", relation: "greaterThanOrEqual",
                    threshold: 600
                ),
            ]
        ),
        "wacom": .init(
            minimumSampleCount: 120,
            minimumDurationNanoseconds: 1_000_000_000,
            requiredEventCounts: [
                "inputSample": 120, "renderedSample": 120,
            ],
            orderedEventKinds: ["inputSample", "renderedSample"],
            metrics: [
                "inputContinuityFailureCount": .init(
                    aggregation: "sum", relation: "equal", threshold: 0
                ),
                "pressureMonotonicityFailureCount": .init(
                    aggregation: "sum", relation: "equal", threshold: 0
                ),
            ]
        ),
    ]

    private static func validateCurrentPhysicalProfileTrace(
        profileID: String,
        device: [String: Any],
        sampleCount: Int,
        sampleTimestampsNanoseconds: [Int],
        events: [[String: Any]],
        measurements: [String: [Double]]
    ) throws {
        guard let requirement = profileRequirements[profileID],
              sampleCount >= requirement.minimumSampleCount,
              validCurrentPhysicalDevice(device, profileID: profileID),
              Set(measurements.keys) == Set(requirement.metrics.keys),
              validPhysicalTimestamps(
                  sampleTimestampsNanoseconds,
                  sampleCount: sampleCount,
                  minimumDurationNanoseconds:
                    requirement.minimumDurationNanoseconds
              ),
              let eventTimestamps = physicalEventTimestamps(
                  events,
                  requiredCounts: requirement.requiredEventCounts,
                  orderedKinds: requirement.orderedEventKinds,
                  sampleTimestamps: sampleTimestampsNanoseconds
              )
        else {
            throw ArtifactFileSystem.invalid(
                "\(profileID): current physical profile identity, device, or events are invalid"
            )
        }
        for (metricID, metricRequirement) in requirement.metrics {
            guard let values = measurements[metricID],
                  values.count == sampleCount,
                  values.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  let value = aggregate(
                      values,
                      kind: metricRequirement.aggregation
                  ),
                  thresholdSatisfied(
                      value,
                      relation: metricRequirement.relation,
                      threshold: metricRequirement.threshold
                  )
            else {
                throw ArtifactFileSystem.invalid(
                    "\(profileID): current physical metric \(metricID) is malformed or failed its threshold"
                )
            }
        }
        guard let missedFrames = missedFrameSamples(
            profileID: profileID,
            device: device,
            eventTimestamps: eventTimestamps
        ) else {
            throw ArtifactFileSystem.invalid(
                "\(profileID): display refresh claim disagrees with frame events"
            )
        }
        var derived = derivedPhysicalSamples(
            profileID: profileID,
            sampleTimestamps: sampleTimestampsNanoseconds,
            eventTimestamps: eventTimestamps
        )
        if !missedFrames.isEmpty {
            derived["missedFrameFraction"] = missedFrames
        }
        for (metricID, values) in derived {
            guard let claimed = measurements[metricID],
                  claimed.count == values.count,
                  zip(claimed, values).allSatisfy({
                      close($0.0, $0.1)
                  })
            else {
                throw ArtifactFileSystem.invalid(
                    "\(profileID): current physical metric \(metricID) disagrees with raw events"
                )
            }
        }
    }

    private static func validCurrentPhysicalDevice(
        _ device: [String: Any],
        profileID: String
    ) -> Bool {
        let isWacom = profileID == "wacom"
        let isReference = profileID == "referenceMSeriesProMotion120Hz"
        let isA14 = profileID == "a14Floor60Hz"
        let expectedPlatform = isWacom ? "macOS" : "iPadOS"
        let expectedInputKind = isWacom
            ? "wacomStylus"
            : (["inputToPhoton", "pencil"].contains(profileID)
                ? "applePencil" : "touch")
        let expectedVendor = isWacom ? "Wacom" : "Apple"
        let expectedTelemetry = isWacom
            ? "NSEvent.tabletPoint"
            : (expectedInputKind == "applePencil"
                ? "UIEvent.coalescedTouches+predictedTouches"
                : "UITouch.timestamp")
        guard Set(device.keys) == [
            "display", "gpuName", "gpuRegistryID", "hardwareModel",
            "inputDevice", "operatingSystem", "platform",
            "processorClass",
        ],
              let gpuName = device["gpuName"] as? String,
              !gpuName.localizedCaseInsensitiveContains("virtual"),
              gpuName.localizedCaseInsensitiveContains(
                  isA14 ? "A14" : "Apple"
              ),
              let registryID = device["gpuRegistryID"] as? String,
              !registryID.isEmpty,
              let hardwareModel = device["hardwareModel"] as? String,
              hardwareModel.hasPrefix(isWacom ? "Mac" : "iPad"),
              device["platform"] as? String == expectedPlatform,
              (device["operatingSystem"] as? String)?
                .hasPrefix(expectedPlatform) == true,
              let processorClass = device["processorClass"] as? String,
              ["A14Class", "MSeries"].contains(processorClass),
              (!isA14 || processorClass == "A14Class"),
              (!isReference && !isWacom || processorClass == "MSeries"),
              let display = device["display"] as? [String: Any],
              Set(display.keys) == [
                  "measuredRefreshHertz", "measurementProvenance",
                  "nominalRefreshHertz",
              ],
              let nominal = number(display["nominalRefreshHertz"])?
                .doubleValue,
              let measured = number(display["measuredRefreshHertz"])?
                .doubleValue,
              nominal.isFinite,
              measured.isFinite,
              nominal >= (isReference ? 120 : 60),
              measured >= (isReference ? 120 : 60),
              display["measurementProvenance"] as? String
                == (isWacom
                    ? "CGDisplayMode.refreshRate+frameTimestampTrace"
                    : "CADisplayLink.maximumFramesPerSecond+frameTimestampTrace"),
              let input = device["inputDevice"] as? [String: Any],
              Set(input.keys) == [
                  "kind", "model", "samplingHertz",
                  "telemetryProvenance", "transport", "vendor",
              ],
              input["kind"] as? String == expectedInputKind,
              input["vendor"] as? String == expectedVendor,
              (input["model"] as? String)?
                .localizedCaseInsensitiveContains(
                    isWacom ? "Wacom"
                        : (expectedInputKind == "applePencil"
                            ? "Apple Pencil" : "Multi-Touch")
                ) == true,
              input["telemetryProvenance"] as? String
                == expectedTelemetry,
              !(input["transport"] as? String ?? "").isEmpty,
              let sampling = number(input["samplingHertz"])?.doubleValue,
              sampling.isFinite,
              sampling > 0
        else {
            return false
        }
        return true
    }

    private static func validPhysicalTimestamps(
        _ timestamps: [Int],
        sampleCount: Int,
        minimumDurationNanoseconds: Int
    ) -> Bool {
        guard timestamps.count == sampleCount,
              let first = timestamps.first,
              let last = timestamps.last,
              first >= 0,
              last - first >= minimumDurationNanoseconds
        else {
            return false
        }
        return zip(timestamps, timestamps.dropFirst()).allSatisfy(<)
    }

    private static func physicalEventTimestamps(
        _ events: [[String: Any]],
        requiredCounts: [String: Int],
        orderedKinds: [String],
        sampleTimestamps: [Int]
    ) -> [String: [Int]]? {
        guard let lastTimestamp = sampleTimestamps.last else { return nil }
        var counts: [String: Int] = [:]
        var byKindAndSample: [String: [Int: Int]] = [:]
        var previousTimestamp: Int?
        for event in events {
            guard Set(event.keys) == [
                "kind", "sampleIndex", "timestampNanoseconds",
            ],
                  let kind = event["kind"] as? String,
                  requiredCounts[kind] != nil,
                  let sampleIndex = integer(event["sampleIndex"]),
                  sampleTimestamps.indices.contains(sampleIndex),
                  let timestamp = integer(event["timestampNanoseconds"]),
                  (0...lastTimestamp).contains(timestamp),
                  previousTimestamp.map({ $0 <= timestamp }) ?? true,
                  byKindAndSample[kind]?[sampleIndex] == nil
            else {
                return nil
            }
            counts[kind, default: 0] += 1
            byKindAndSample[kind, default: [:]][sampleIndex] = timestamp
            previousTimestamp = timestamp
        }
        guard requiredCounts.allSatisfy({
            counts[$0.key, default: 0] >= $0.value
        }) else {
            return nil
        }
        var ordered = Dictionary(uniqueKeysWithValues: orderedKinds.map {
            ($0, [Int](repeating: 0, count: sampleTimestamps.count))
        })
        for sampleIndex in sampleTimestamps.indices {
            var preceding = sampleIndex == 0
                ? nil : sampleTimestamps[sampleIndex - 1]
            for kind in orderedKinds {
                guard let timestamp = byKindAndSample[kind]?[sampleIndex],
                      preceding.map({ $0 < timestamp }) ?? true
                else {
                    return nil
                }
                ordered[kind]![sampleIndex] = timestamp
                preceding = timestamp
            }
            guard preceding == sampleTimestamps[sampleIndex] else {
                return nil
            }
        }
        return ordered
    }

    private static func missedFrameSamples(
        profileID: String,
        device: [String: Any],
        eventTimestamps: [String: [Int]]
    ) -> [Double]? {
        guard [
            "a14Floor60Hz", "referenceMSeriesProMotion120Hz",
        ].contains(profileID) else {
            return []
        }
        guard let frames = eventTimestamps["displayFrame"],
              frames.count > 1,
              let first = frames.first,
              let last = frames.last,
              last > first,
              let display = device["display"] as? [String: Any],
              let measured = number(display["measuredRefreshHertz"])?
                .doubleValue
        else {
            return nil
        }
        let observed = Double(frames.count - 1) * 1_000_000_000
            / Double(last - first)
        guard observed.isFinite,
              abs(observed - measured) <= max(0.5, measured * 0.005)
        else {
            return nil
        }
        let expectedInterval = 1_000_000_000 / measured
        var result = [Double](repeating: 0, count: frames.count)
        for index in 1..<frames.count {
            let elapsed = max(
                1,
                Int((Double(frames[index] - frames[index - 1])
                    / expectedInterval).rounded())
            )
            result[index] = Double(elapsed - 1) / Double(elapsed)
        }
        return result
    }

    private static func derivedPhysicalSamples(
        profileID: String,
        sampleTimestamps: [Int],
        eventTimestamps: [String: [Int]]
    ) -> [String: [Double]] {
        func elapsedMilliseconds(_ first: String, _ last: String)
            -> [Double]
        {
            guard let starts = eventTimestamps[first],
                  let ends = eventTimestamps[last],
                  starts.count == ends.count
            else { return [] }
            return zip(starts, ends).map {
                Double($0.1 - $0.0) / 1_000_000
            }
        }
        switch profileID {
        case "inputToPhoton":
            return [
                "inputToPhotonP95Milliseconds": elapsedMilliseconds(
                    "inputEvent", "photonObserved"
                ),
            ]
        case "memoryWarning":
            return [
                "memoryWarningRecoveryMilliseconds": elapsedMilliseconds(
                    "memoryWarning", "rendererRecovered"
                ),
                "recoveryFailureCount": [Double](
                    repeating: 0, count: sampleTimestamps.count
                ),
            ]
        case "suspendResume":
            return [
                "suspendResumeRecoveryMilliseconds": elapsedMilliseconds(
                    "applicationResumed", "rendererRecovered"
                ),
                "recoveryFailureCount": [Double](
                    repeating: 0, count: sampleTimestamps.count
                ),
            ]
        case "sustainedThermal":
            var durations = [Double](
                repeating: 0, count: sampleTimestamps.count
            )
            for index in 1..<sampleTimestamps.count {
                durations[index] = Double(
                    sampleTimestamps[index]
                        - sampleTimestamps[index - 1]
                ) / 1_000_000_000
            }
            return ["thermalDurationSeconds": durations]
        default:
            return [:]
        }
    }

    private static func aggregate(
        _ values: [Double],
        kind: String
    ) -> Double? {
        switch kind {
        case "maximum": values.max()
        case "p95":
            values.sorted()[max(
                0,
                Int(ceil(Double(values.count) * 0.95)) - 1
            )]
        case "sum": values.reduce(0, +)
        default: nil
        }
    }

    private static func thresholdSatisfied(
        _ value: Double,
        relation: String,
        threshold: Double
    ) -> Bool {
        switch relation {
        case "lessThan": value < threshold
        case "equal": close(value, threshold)
        case "greaterThanOrEqual": value >= threshold
        default: false
        }
    }

    private static func close(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs.isFinite && rhs.isFinite
            && abs(lhs - rhs) <= max(1, abs(lhs), abs(rhs)) * 1e-12
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
        truth: ProfessionalSceneContract
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
