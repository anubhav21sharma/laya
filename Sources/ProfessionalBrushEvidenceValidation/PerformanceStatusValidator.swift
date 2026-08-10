import Foundation

enum PerformanceStatusValidator {
    private struct Status: Decodable {
        let schemaVersion: Int
        let correctnessPassed: Bool
        let gpuName: String
        let gpuClassification: String
        let cpuPreparationP95Milliseconds: Double
        let cpuPreparationBudgetMilliseconds: Double
        let gpu500DabMilliseconds: Double
        let gpu500DabBudgetMilliseconds: Double
        let softwareEventToSubmitMissedFrameCountByBrush:
            [String: UInt64]
    }

    private struct PerformanceMeasurements {
        let gpuMillisecondsByBrush: [String: Double]
        let cpuPreparationP95ByBrush: [String: Double]
        let missedFrameCountByBrush: [String: UInt64]
    }

    static func validate(
        _ data: Data,
        expectedGPUName: String,
        expectedOperatingSystem: String,
        expectedCommit: String,
        expectedRendererSHA256: String,
        positiveRoot: URL,
        identities: ProfessionalSceneIdentitySet
    ) throws -> Bool {
        let object = try ArtifactFileSystem.jsonObject(
            data,
            label: "performance status"
        )
        try ArtifactFileSystem.requireExactKeys(
            object,
            [
                "schemaVersion", "correctnessPassed", "gpuName",
                "gpuClassification",
                "cpuPreparationP95Milliseconds",
                "cpuPreparationBudgetMilliseconds",
                "gpu500DabMilliseconds",
                "gpu500DabBudgetMilliseconds",
                "softwareEventToSubmitMissedFrameCountByBrush",
            ],
            label: "performance status"
        )
        let status: Status
        do {
            status = try JSONDecoder().decode(Status.self, from: data)
        } catch {
            throw ArtifactFileSystem.invalid(
                "performance status is malformed"
            )
        }
        let measurements = try validateProfessionalPerformanceArtifacts(
            positiveRoot: positiveRoot,
            expectedGPUName: expectedGPUName,
            expectedOperatingSystem: expectedOperatingSystem,
            expectedCommit: expectedCommit,
            expectedRendererSHA256: expectedRendererSHA256,
            identities: identities
        )
        let gpuByBrush = measurements.gpuMillisecondsByBrush
        guard let measuredGPU = gpuByBrush.values.max(),
              let measuredCPU = measurements
                .cpuPreparationP95ByBrush.values.max(),
              status.schemaVersion == 3,
              status.correctnessPassed,
              status.gpuName == expectedGPUName,
              status.gpuClassification
                == ArtifactFileSystem.gpuClassification(expectedGPUName),
              status.cpuPreparationP95Milliseconds.isFinite,
              status.cpuPreparationP95Milliseconds >= 0,
              status.cpuPreparationBudgetMilliseconds == 2,
              close(
                  status.cpuPreparationP95Milliseconds,
                  measuredCPU
              ),
              status.cpuPreparationP95Milliseconds < 2,
              status.gpu500DabMilliseconds.isFinite,
              status.gpu500DabMilliseconds >= 0,
              status.gpu500DabBudgetMilliseconds == 3,
              close(status.gpu500DabMilliseconds, measuredGPU),
              status.softwareEventToSubmitMissedFrameCountByBrush
                == measurements.missedFrameCountByBrush
        else {
            throw ArtifactFileSystem.invalid(
                "performance status disagrees with current professional "
                    + "artifacts (status CPU "
                    + "\(status.cpuPreparationP95Milliseconds), measured "
                    + "\(measurements.cpuPreparationP95ByBrush); status GPU "
                    + "\(status.gpu500DabMilliseconds), measured "
                    + "\(gpuByBrush); status missed "
                    + "\(status.softwareEventToSubmitMissedFrameCountByBrush), "
                    + "measured \(measurements.missedFrameCountByBrush))"
            )
        }
        if status.gpuClassification == "physical" {
            guard gpuByBrush.values.allSatisfy({ $0 < 3 }) else {
                throw ArtifactFileSystem.invalid(
                    "a professional brush exceeded the physical GPU 500-dab budget"
                )
            }
            return true
        }
        return false
    }

    private static func validateProfessionalPerformanceArtifacts(
        positiveRoot: URL,
        expectedGPUName: String,
        expectedOperatingSystem: String,
        expectedCommit: String,
        expectedRendererSHA256: String,
        identities: ProfessionalSceneIdentitySet
    ) throws -> PerformanceMeasurements {
        guard try ArtifactFileSystem.entryNames(positiveRoot)
                == Set(ProfessionalBrushTruth.positiveSceneNames)
        else {
            throw ArtifactFileSystem.invalid(
                "professional performance scene set is not exact"
            )
        }
        var gpuResult: [String: Double] = [:]
        var cpuResult: [String: Double] = [:]
        var missedFrameResult: [String: UInt64] = [:]
        for scene in ProfessionalBrushTruth.positiveSceneNames {
            let directory = positiveRoot.appendingPathComponent(scene)
            let measurement = try validatePerformanceIndex(
                directory: directory,
                scene: scene,
                expectedGPUName: expectedGPUName,
                expectedOperatingSystem: expectedOperatingSystem,
                expectedCommit: expectedCommit,
                expectedRendererSHA256: expectedRendererSHA256,
                identities: identities
            )
            gpuResult[scene] = measurement.gpuMilliseconds
            cpuResult[scene] = measurement.cpuPreparationP95Milliseconds
            missedFrameResult[scene] = measurement.missedFrameCount
        }
        return PerformanceMeasurements(
            gpuMillisecondsByBrush: gpuResult,
            cpuPreparationP95ByBrush: cpuResult,
            missedFrameCountByBrush: missedFrameResult
        )
    }

    private static func validatePerformanceIndex(
        directory: URL,
        scene: String,
        expectedGPUName: String,
        expectedOperatingSystem: String,
        expectedCommit: String,
        expectedRendererSHA256: String,
        identities: ProfessionalSceneIdentitySet
    ) throws -> (
        gpuMilliseconds: Double,
        cpuPreparationP95Milliseconds: Double,
        missedFrameCount: UInt64
    ) {
        guard let truth = ProfessionalBrushTruth.sceneContracts[scene],
              let identity = identities[scene]
        else {
            throw ArtifactFileSystem.invalid(
                "\(scene): professional performance truth is missing"
            )
        }
        let data = try ArtifactFileSystem.regularFileData(
            directory.appendingPathComponent(
                "professional-performance.json"
            ),
            label: "\(scene) professional performance index"
        )
        let index = try ArtifactFileSystem.jsonObject(
            data,
            label: "\(scene) professional performance index"
        )
        try ArtifactFileSystem.requireExactKeys(
            index,
            [
                "schemaVersion", "scene", "definitionID", "semanticHash",
                "resolvedResources", "source", "fiveHundredDabs",
                "longStroke",
            ],
            label: "\(scene) professional performance index"
        )
        guard integer(index["schemaVersion"]) == 1,
              index["scene"] as? String == scene,
              index["definitionID"] as? String == identity.definitionID,
              index["semanticHash"] as? String
                == identity.definitionSemanticHash,
              validResources(index["resolvedResources"], truth: truth),
              let source = index["source"] as? [String: Any],
              validSource(
                  source,
                  commit: expectedCommit,
                  renderer: expectedRendererSHA256,
                  gpu: expectedGPUName,
                  operatingSystem: expectedOperatingSystem
              ),
              let five = index["fiveHundredDabs"] as? [String: Any],
              let long = index["longStroke"] as? [String: Any]
        else {
            throw ArtifactFileSystem.invalid(
                "\(scene): professional performance identity or provenance is invalid"
            )
        }
        let fiveData = try referencedRawData(
            five,
            expectedPath: "professional-five-hundred-dabs.raw.json",
            directory: directory,
            label: "\(scene) 500-dab reference"
        )
        let longData = try referencedRawData(
            long,
            expectedPath: "professional-long-stroke.raw.json",
            directory: directory,
            label: "\(scene) long-stroke reference"
        )
        let gpu = try validateFiveHundredDabs(
            fiveData,
            scene: scene,
            truth: truth,
            identity: identity,
            source: source
        )
        let longStroke = try validateLongStroke(
            longData,
            directory: directory,
            scene: scene,
            truth: truth,
            identity: identity,
            source: source,
            enforceGPUStability:
                ArtifactFileSystem.gpuClassification(expectedGPUName)
                    == "physical"
        )
        return (
            gpu,
            longStroke.cpuPreparationP95Milliseconds,
            longStroke.missedFrameCount
        )
    }

    private static func referencedRawData(
        _ reference: [String: Any],
        expectedPath: String,
        directory: URL,
        label: String
    ) throws -> Data {
        try ArtifactFileSystem.requireExactKeys(
            reference,
            ["path", "sha256"],
            label: label
        )
        guard reference["path"] as? String == expectedPath,
              let digest = reference["sha256"] as? String,
              ArtifactFileSystem.isSHA256(digest)
        else {
            throw ArtifactFileSystem.invalid(
                "\(label) is malformed"
            )
        }
        let data = try ArtifactFileSystem.regularFileData(
            directory.appendingPathComponent(expectedPath),
            label: label
        )
        guard ArtifactFileSystem.sha256(data) == digest else {
            throw ArtifactFileSystem.invalid(
                "\(label) digest changed"
            )
        }
        return data
    }

    private static func validateFiveHundredDabs(
        _ data: Data,
        scene: String,
        truth: ProfessionalSceneContract,
        identity: ProfessionalSceneIdentity,
        source: [String: Any]
    ) throws -> Double {
        let raw = try ArtifactFileSystem.jsonObject(
            data,
            label: "\(scene) 500-dab raw evidence"
        )
        try ArtifactFileSystem.requireExactKeys(
            raw,
            [
                "schemaVersion", "workloadID", "scene", "definitionID",
                "semanticHash", "resolvedResources", "source",
                "recordCount", "measurementCount", "gpuMilliseconds",
                "compilerCountersBefore", "compilerCountersAfter",
            ],
            label: "\(scene) 500-dab raw evidence"
        )
        guard integer(raw["schemaVersion"]) == 1,
              raw["workloadID"] as? String == "professional-500-dabs",
              raw["scene"] as? String == scene,
              raw["definitionID"] as? String == identity.definitionID,
              raw["semanticHash"] as? String
                == identity.definitionSemanticHash,
              validResources(raw["resolvedResources"], truth: truth),
              dictionariesEqual(raw["source"], source),
              integer(raw["recordCount"]) == 500,
              integer(raw["measurementCount"]) == 3,
              let gpu = doubles(raw["gpuMilliseconds"]),
              gpu.count == 3,
              validUnchangedCounters(
                  raw["compilerCountersBefore"],
                  raw["compilerCountersAfter"]
              ),
              let maximum = gpu.max()
        else {
            throw ArtifactFileSystem.invalid(
                "\(scene): 500-dab raw evidence is malformed"
            )
        }
        return maximum
    }

    private static func validateLongStroke(
        _ data: Data,
        directory: URL,
        scene: String,
        truth: ProfessionalSceneContract,
        identity: ProfessionalSceneIdentity,
        source: [String: Any],
        enforceGPUStability: Bool
    ) throws -> (
        missedFrameCount: UInt64,
        cpuPreparationP95Milliseconds: Double
    ) {
        let raw = try ArtifactFileSystem.jsonObject(
            data,
            label: "\(scene) long-stroke raw evidence"
        )
        try ArtifactFileSystem.requireExactKeys(
            raw,
            [
                "schemaVersion", "workloadID", "scene", "definitionID",
                "semanticHash", "resolvedResources", "source",
                "inputSampleCount", "tracePath", "traceSHA256",
                "cpuPreparationMilliseconds", "gpuMilliseconds",
                "eventToSubmitNanoseconds",
                "displayFrameBudgetNanoseconds",
                "missedFrameCount",
                "trend", "identityFrames",
                "logicalDabCount", "projectedInstanceCount",
                "replayMode", "replayMaximumDabs",
                "replayMaximumProjectedInstances",
                "compilerCountersBefore", "compilerCountersAfter",
            ],
            label: "\(scene) long-stroke raw evidence"
        )
        guard integer(raw["schemaVersion"]) == 4,
              raw["workloadID"] as? String
                == "professional-long-stroke",
              raw["scene"] as? String == scene,
              raw["definitionID"] as? String == identity.definitionID,
              raw["semanticHash"] as? String
                == identity.definitionSemanticHash,
              validResources(raw["resolvedResources"], truth: truth),
              dictionariesEqual(raw["source"], source),
              integer(raw["inputSampleCount"]) == 128,
              raw["tracePath"] as? String
                == "professional-long-stroke-trace.json",
              let traceDigest = raw["traceSHA256"] as? String,
              ArtifactFileSystem.isSHA256(traceDigest),
              let cpu = doubles(raw["cpuPreparationMilliseconds"]),
              let gpu = doubles(raw["gpuMilliseconds"]),
              let eventToSubmit =
                unsignedIntegers(raw["eventToSubmitNanoseconds"]),
              cpu.count == 128,
              gpu.count == 128,
              eventToSubmit.count == 128,
              unsignedInteger(raw["displayFrameBudgetNanoseconds"])
                == 16_666_667,
              let storedMissedFrameCount =
                unsignedInteger(raw["missedFrameCount"]),
              let identityFrames =
                raw["identityFrames"] as? [[String: Any]],
              identityFrames.count == 128,
              let logicalDabs = integer(raw["logicalDabCount"]),
              let projected = integer(raw["projectedInstanceCount"]),
              let maximumDabs = integer(raw["replayMaximumDabs"]),
              let maximumProjected =
                integer(raw["replayMaximumProjectedInstances"]),
              maximumDabs == 2_048,
              maximumProjected == 4_096,
              logicalDabs > 0,
              projected >= logicalDabs,
              raw["replayMode"] as? String == "replayTail",
              let countersBefore =
                counterSnapshot(raw["compilerCountersBefore"]),
              let countersAfter =
                counterSnapshot(raw["compilerCountersAfter"])
        else {
            throw ArtifactFileSystem.invalid(
                "\(scene): long-stroke work is not length-independent or hot-path clean"
            )
        }
        guard eventToSubmit.allSatisfy({ $0 > 0 }) else {
            throw ArtifactFileSystem.invalid(
                "\(scene): long-stroke event-to-submit samples must "
                    + "contain measured positive durations"
            )
        }
        guard countersBefore == countersAfter else {
            throw ArtifactFileSystem.invalid(
                "\(scene): long-stroke compiler/resource counters changed "
                    + counterDeltaDescription(
                        before: countersBefore,
                        after: countersAfter
                    )
            )
        }
        let derivedMissedFrameCount = UInt64(
            eventToSubmit.lazy.filter { $0 >= 16_666_667 }.count
        )
        guard storedMissedFrameCount == derivedMissedFrameCount else {
            throw ArtifactFileSystem.invalid(
                "\(scene): long-stroke missed-frame count does not "
                    + "derive from the 128 event-to-submit samples"
            )
        }
        _ = try auditLongStrokeTrend(
            raw["trend"],
            cpuMilliseconds: cpu,
            gpuMilliseconds: gpu,
            scene: scene
        )
        guard stableQuartiles(cpu) else {
            let quartiles = quartileP95s(cpu)
            throw ArtifactFileSystem.invalid(
                "\(scene): long-stroke CPU quartiles are not stable "
                    + "(early/late \(quartiles.early)/"
                    + "\(quartiles.late) ms)"
            )
        }
        if enforceGPUStability {
            guard stableQuartiles(gpu) else {
                let quartiles = quartileP95s(gpu)
                throw ArtifactFileSystem.invalid(
                    "\(scene): long-stroke GPU quartiles are not stable "
                        + "(early/late \(quartiles.early)/"
                        + "\(quartiles.late) ms)"
                )
            }
        }
        _ = try auditIdentityFrames(
            identityFrames,
            scene: scene,
            maximumRetainedDabs: maximumDabs,
            maximumProjectedInstancesPerFrame: maximumProjected,
            expectedFinalLogicalIdentityHighWater: logicalDabs,
            expectedProjectedInstanceTotal: projected
        )
        let traceData = try ArtifactFileSystem.regularFileData(
            directory.appendingPathComponent(
                "professional-long-stroke-trace.json"
            ),
            label: "\(scene) long-stroke trace"
        )
        guard ArtifactFileSystem.sha256(traceData) == traceDigest else {
            throw ArtifactFileSystem.invalid(
                "\(scene): long-stroke trace digest changed"
            )
        }
        try validateTrace(
            traceData,
            scene: scene,
            identity: identity
        )
        return (derivedMissedFrameCount, percentile95(cpu))
    }

    private static func validateTrace(
        _ data: Data,
        scene: String,
        identity: ProfessionalSceneIdentity
    ) throws {
        let trace = try ArtifactFileSystem.jsonObject(
            data,
            label: "\(scene) long-stroke trace"
        )
        try ArtifactFileSystem.requireExactKeys(
            trace,
            [
                "schemaVersion", "scene", "definitionID",
                "semanticHash", "samples",
            ],
            label: "\(scene) long-stroke trace"
        )
        guard integer(trace["schemaVersion"]) == 1,
              trace["scene"] as? String == scene,
              trace["definitionID"] as? String == identity.definitionID,
              trace["semanticHash"] as? String
                == identity.definitionSemanticHash,
              let samples = trace["samples"] as? [[String: Any]],
              samples.count == 128,
              samples.indices.allSatisfy({
                  Set(samples[$0].keys) == [
                      "x", "y", "pressure", "timestamp", "phase",
                      "source", "kind",
                  ]
              }),
              samples.first?["phase"] as? String == "began",
              samples.last?["phase"] as? String == "ended",
              samples.dropFirst().dropLast().allSatisfy({
                  $0["phase"] as? String == "moved"
              }),
              samples.allSatisfy({
                  $0["source"] as? String == "mouse"
                      && $0["kind"] as? String == "actual"
              })
        else {
            throw ArtifactFileSystem.invalid(
                "\(scene): long-stroke trace is malformed"
            )
        }
        let timestamps = samples.compactMap {
            number($0["timestamp"])?.doubleValue
        }
        guard timestamps.count == 128,
              timestamps.allSatisfy(\.isFinite),
              zip(timestamps, timestamps.dropFirst()).allSatisfy(<),
              samples.indices.allSatisfy({ index in
                  guard
                      let x = (
                          number(samples[index]["x"])
                      )?.doubleValue,
                      let y = (
                          number(samples[index]["y"])
                      )?.doubleValue,
                      let pressure = (
                          number(samples[index]["pressure"])
                      )?.doubleValue
                  else {
                      return false
                  }
                  return approximatelyEqual(
                      x,
                      index.isMultiple(of: 2) ? 64 : 448
                  )
                      && approximatelyEqual(y, 256)
                      && approximatelyEqual(
                          pressure,
                          Double(Float(0.58))
                      )
                      && approximatelyEqual(
                          timestamps[index],
                          Double(index) * 0.004
                      )
              }),
              samples.allSatisfy({
                  guard let x = number($0["x"])?.doubleValue,
                        let y = number($0["y"])?.doubleValue,
                        let pressure =
                          number($0["pressure"])?.doubleValue
                  else { return false }
                  return x.isFinite && y.isFinite
                      && pressure.isFinite
                      && (0...1).contains(pressure)
              })
        else {
            throw ArtifactFileSystem.invalid(
                "\(scene): long-stroke trace values are invalid"
            )
        }
    }

    private static func validSource(
        _ source: [String: Any],
        commit: String,
        renderer: String,
        gpu: String,
        operatingSystem: String
    ) -> Bool {
        Set(source.keys) == [
            "gitCommit", "rendererExecutableSHA256", "gpuName",
            "operatingSystem",
        ]
            && source["gitCommit"] as? String == commit
            && ArtifactFileSystem.isCommit(commit)
            && source["rendererExecutableSHA256"] as? String == renderer
            && ArtifactFileSystem.isSHA256(renderer)
            && source["gpuName"] as? String == gpu
            && !gpu.isEmpty
            && source["operatingSystem"] as? String == operatingSystem
            && !operatingSystem.isEmpty
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

    private static let counterKeys: Set<String> = [
        "packageDecodeCount", "imageDecodeCount", "textureUploadCount",
        "cacheHitCount", "activationCount",
    ]

    private static func validUnchangedCounters(
        _ before: Any?,
        _ after: Any?
    ) -> Bool {
        guard let before = counterSnapshot(before),
              let after = counterSnapshot(after)
        else {
            return false
        }
        return before == after
    }

    private static func counterSnapshot(
        _ value: Any?
    ) -> [String: UInt64]? {
        guard let object = value as? [String: Any],
              Set(object.keys) == counterKeys
        else {
            return nil
        }
        var result: [String: UInt64] = [:]
        for key in counterKeys {
            guard let count = unsignedInteger(object[key]) else {
                return nil
            }
            result[key] = count
        }
        return result
    }

    private static func counterDeltaDescription(
        before: [String: UInt64],
        after: [String: UInt64]
    ) -> String {
        counterKeys.sorted().map { key in
            let first = before[key]!
            let last = after[key]!
            let delta = last >= first
                ? "+\(last - first)"
                : "-\(first - last)"
            return "\(key)=\(first)->\(last)(\(delta))"
        }.joined(separator: ", ")
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

    private static func unsignedIntegers(_ value: Any?) -> [UInt64]? {
        guard let values = value as? [Any] else { return nil }
        let result = values.compactMap(unsignedInteger)
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

    private static func stableQuartiles(_ values: [Double]) -> Bool {
        guard values.count == 128 else { return false }
        let (early, late) = quartileP95s(values)
        return late <= max(early * 2, early + 0.5)
    }

    private static func quartileP95s(
        _ values: [Double]
    ) -> (early: Double, late: Double) {
        (
            percentile95(Array(values.prefix(32))),
            percentile95(Array(values.suffix(32)))
        )
    }

    private static func theilSenSlope(
        _ values: [Double],
        frameIndices: [Double]
    ) -> Double? {
        guard values.count == 16,
              frameIndices.count == values.count,
              values.allSatisfy(\.isFinite),
              frameIndices.allSatisfy(\.isFinite)
        else {
            return nil
        }
        var pairwiseSlopes: [Double] = []
        pairwiseSlopes.reserveCapacity(120)
        for first in 0 ..< values.count {
            for second in (first + 1) ..< values.count {
                let frameDistance =
                    frameIndices[second] - frameIndices[first]
                guard frameDistance > 0 else { return nil }
                let slope =
                    (values[second] - values[first]) / frameDistance
                guard slope.isFinite else { return nil }
                pairwiseSlopes.append(slope)
            }
        }
        guard pairwiseSlopes.count == 120 else { return nil }
        pairwiseSlopes.sort()
        return (pairwiseSlopes[59] + pairwiseSlopes[60]) / 2
    }

    private struct LongStrokeTrendBlockAudit {
        let startFrameIndex: Int
        let endFrameIndexExclusive: Int
        let centerFrameIndex: Double
        let cpuMedianMilliseconds: Double
        let gpuMedianMilliseconds: Double
    }

    private struct LongStrokeTrendAudit {
        let blocks: [LongStrokeTrendBlockAudit]
        let cpuSlopeMillisecondsPerFrame: Double
        let gpuSlopeMillisecondsPerFrame: Double
    }

    private static func auditLongStrokeTrend(
        _ value: Any?,
        cpuMilliseconds: [Double],
        gpuMilliseconds: [Double],
        scene: String
    ) throws -> LongStrokeTrendAudit {
        let estimator =
            "theil-sen-of-contiguous-eight-frame-block-medians-v1"
        guard let object = value as? [String: Any] else {
            throw ArtifactFileSystem.invalid(
                "\(scene): long-stroke trend evidence is malformed"
            )
        }
        try ArtifactFileSystem.requireExactKeys(
            object,
            [
                "estimator", "blockSize", "blocks",
                "cpuSlopeMillisecondsPerFrame",
                "gpuSlopeMillisecondsPerFrame",
            ],
            label: "\(scene) long-stroke trend evidence"
        )
        guard object["estimator"] as? String == estimator,
              integer(object["blockSize"]) == 8,
              let encodedBlocks =
                object["blocks"] as? [[String: Any]],
              let derived = deriveLongStrokeTrend(
                  cpuMilliseconds: cpuMilliseconds,
                  gpuMilliseconds: gpuMilliseconds
              ),
              encodedBlocks.count == derived.blocks.count,
              let encodedCPUSlope =
                number(
                    object["cpuSlopeMillisecondsPerFrame"]
                )?.doubleValue,
              encodedCPUSlope.isFinite,
              let encodedGPUSlope =
                number(
                    object["gpuSlopeMillisecondsPerFrame"]
                )?.doubleValue,
              encodedGPUSlope.isFinite,
              close(
                  encodedCPUSlope,
                  derived.cpuSlopeMillisecondsPerFrame
              ),
              close(
                  encodedGPUSlope,
                  derived.gpuSlopeMillisecondsPerFrame
              )
        else {
            throw ArtifactFileSystem.invalid(
                "\(scene): long-stroke trend evidence disagrees "
                    + "with its 128 raw frame samples"
            )
        }
        for (index, encoded) in encodedBlocks.enumerated() {
            let expected = derived.blocks[index]
            guard Set(encoded.keys) == [
                "startFrameIndex",
                "endFrameIndexExclusive",
                "centerFrameIndex",
                "cpuMedianMilliseconds",
                "gpuMedianMilliseconds",
            ],
                integer(encoded["startFrameIndex"])
                    == expected.startFrameIndex,
                integer(encoded["endFrameIndexExclusive"])
                    == expected.endFrameIndexExclusive,
                let center =
                  number(encoded["centerFrameIndex"])?.doubleValue,
                center.isFinite,
                close(center, expected.centerFrameIndex),
                let cpuMedian =
                  number(
                      encoded["cpuMedianMilliseconds"]
                  )?.doubleValue,
                cpuMedian.isFinite,
                cpuMedian >= 0,
                close(
                    cpuMedian,
                    expected.cpuMedianMilliseconds
                ),
                let gpuMedian =
                  number(
                      encoded["gpuMedianMilliseconds"]
                  )?.doubleValue,
                gpuMedian.isFinite,
                gpuMedian >= 0,
                close(
                    gpuMedian,
                    expected.gpuMedianMilliseconds
                )
            else {
                throw ArtifactFileSystem.invalid(
                    "\(scene): long-stroke trend block \(index) "
                        + "has invalid membership, ordering, or medians"
                )
            }
        }
        return derived
    }

    private static func deriveLongStrokeTrend(
        cpuMilliseconds: [Double],
        gpuMilliseconds: [Double]
    ) -> LongStrokeTrendAudit? {
        let blockSize = 8
        guard cpuMilliseconds.count == 128,
              gpuMilliseconds.count == 128,
              cpuMilliseconds.allSatisfy({
                  $0.isFinite && $0 >= 0
              }),
              gpuMilliseconds.allSatisfy({
                  $0.isFinite && $0 >= 0
              })
        else {
            return nil
        }
        var blocks: [LongStrokeTrendBlockAudit] = []
        blocks.reserveCapacity(cpuMilliseconds.count / blockSize)
        for start in stride(
            from: 0,
            to: cpuMilliseconds.count,
            by: blockSize
        ) {
            let end = start + blockSize
            blocks.append(
                LongStrokeTrendBlockAudit(
                    startFrameIndex: start,
                    endFrameIndexExclusive: end,
                    centerFrameIndex:
                        Double(start) + Double(blockSize - 1) / 2,
                    cpuMedianMilliseconds: median(
                        cpuMilliseconds[start ..< end]
                    ),
                    gpuMedianMilliseconds: median(
                        gpuMilliseconds[start ..< end]
                    )
                )
            )
        }
        let centers = blocks.map(\.centerFrameIndex)
        guard let cpuSlope = theilSenSlope(
            blocks.map(\.cpuMedianMilliseconds),
            frameIndices: centers
        ),
            let gpuSlope = theilSenSlope(
                blocks.map(\.gpuMedianMilliseconds),
                frameIndices: centers
            )
        else {
            return nil
        }
        return LongStrokeTrendAudit(
            blocks: blocks,
            cpuSlopeMillisecondsPerFrame: cpuSlope,
            gpuSlopeMillisecondsPerFrame: gpuSlope
        )
    }

    private static func median(
        _ values: ArraySlice<Double>
    ) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    private struct LongStrokeIdentityAudit {
        let newLogicalDabCounts: [UInt64]
        let restampedLogicalDabCounts: [UInt64]
        let newGeneratedProjectedInstanceCounts: [Int]
        let maximumEncodedGPUInstanceCount: Int
    }

    private static func auditIdentityFrames(
        _ frames: [[String: Any]],
        scene: String,
        maximumRetainedDabs: Int,
        maximumProjectedInstancesPerFrame: Int,
        expectedFinalLogicalIdentityHighWater: Int,
        expectedProjectedInstanceTotal: Int
    ) throws -> LongStrokeIdentityAudit {
        guard frames.count == 128,
              maximumRetainedDabs > 0,
              maximumProjectedInstancesPerFrame > 0,
              expectedFinalLogicalIdentityHighWater > 0,
              expectedProjectedInstanceTotal > 0,
              let expectedFinal = UInt64(
                  exactly: expectedFinalLogicalIdentityHighWater
              )
        else {
            throw ArtifactFileSystem.invalid(
                "\(scene): long-stroke identity audit dimensions are invalid"
            )
        }
        var encodedHighWater: UInt64 = 0
        var priorEmittedHighWater: UInt64 = 0
        var generatedProjectedHighWater = 0
        var maximumEncodedGPU = 0
        var newLogicalDabCounts: [UInt64] = []
        var restampedLogicalDabCounts: [UInt64] = []
        var newGeneratedProjectedInstanceCounts: [Int] = []
        var sawRetainedDab = false
        for (frameIndex, frame) in frames.enumerated() {
            guard Set(frame.keys) == [
                "inputPhase",
                "previousEncodedLogicalDabHighWater",
                "emittedLogicalDabHighWater",
                "authoritativeLogicalDabBacklogRemaining",
                "previousGeneratedProjectedInstanceHighWater",
                "generatedProjectedInstanceHighWater",
                "encodedGPUInstanceCount",
                "retainedDabCount",
                "visibleProjectedInstanceCount",
                "encodedLogicalDabIdentityRanges",
            ],
                frame["inputPhase"] as? String
                    == (
                        frameIndex == 0
                            ? "began"
                            : (frameIndex == 127 ? "ended" : "moved")
                    ),
                let previous =
                  unsignedInteger(
                      frame["previousEncodedLogicalDabHighWater"]
                  ),
                previous == encodedHighWater,
                let emitted = unsignedInteger(
                    frame["emittedLogicalDabHighWater"]
                ),
                emitted >= priorEmittedHighWater,
                emitted >= previous,
                let backlogValue = integer(
                    frame["authoritativeLogicalDabBacklogRemaining"]
                ),
                let backlog = UInt64(exactly: backlogValue),
                let previousGeneratedProjected = integer(
                    frame[
                        "previousGeneratedProjectedInstanceHighWater"
                    ]
                ),
                previousGeneratedProjected
                    == generatedProjectedHighWater,
                let currentGeneratedProjected = integer(
                    frame["generatedProjectedInstanceHighWater"]
                ),
                currentGeneratedProjected >= previousGeneratedProjected,
                (
                    frameIndex == frames.count - 1
                        || currentGeneratedProjected
                            - previousGeneratedProjected
                            <= maximumProjectedInstancesPerFrame
                ),
                let encodedGPU = integer(
                    frame["encodedGPUInstanceCount"]
                ),
                encodedGPU >= 0,
                encodedGPU
                    >= currentGeneratedProjected
                        - previousGeneratedProjected,
                let retainedDabCount = integer(
                    frame["retainedDabCount"]
                ),
                retainedDabCount >= 0,
                retainedDabCount <= maximumRetainedDabs,
                let visibleProjectedInstanceCount = integer(
                    frame["visibleProjectedInstanceCount"]
                ),
                visibleProjectedInstanceCount >= 0,
                visibleProjectedInstanceCount
                    <= maximumProjectedInstancesPerFrame,
                let ranges =
                  frame["encodedLogicalDabIdentityRanges"]
                    as? [[String: Any]]
            else {
                throw ArtifactFileSystem.invalid(
                    "\(scene): long-stroke identity frame \(frameIndex) "
                        + "has malformed, discontinuous, or over-budget metadata: "
                        + "\(frame)"
                )
            }
            var newlyEncoded: UInt64 = 0
            for range in ranges {
                guard Set(range.keys) == ["lowerBound", "upperBound"],
                      let lower = unsignedInteger(range["lowerBound"]),
                      let upper = unsignedInteger(range["upperBound"]),
                      lower == encodedHighWater,
                      upper > lower,
                      upper <= emitted
                else {
                    throw ArtifactFileSystem.invalid(
                        "\(scene): long-stroke logical-dab identity range "
                            + "failed continuity at frame \(frameIndex), "
                            + "high-water \(encodedHighWater), emitted \(emitted)"
                    )
                }
                newlyEncoded += upper - lower
                encodedHighWater = upper
            }
            guard encodedHighWater <= emitted,
                  emitted - encodedHighWater == backlog,
                  backlog != 0 || encodedHighWater == emitted
            else {
                throw ArtifactFileSystem.invalid(
                    "\(scene): long-stroke logical-dab backlog mismatch at "
                        + "frame \(frameIndex), encoded \(encodedHighWater), "
                        + "emitted \(emitted), backlog \(backlog)"
                )
            }
            let generatedProjectedDelta =
                currentGeneratedProjected - previousGeneratedProjected
            generatedProjectedHighWater = currentGeneratedProjected
            maximumEncodedGPU = max(maximumEncodedGPU, encodedGPU)
            sawRetainedDab = sawRetainedDab || retainedDabCount > 0
            newLogicalDabCounts.append(newlyEncoded)
            restampedLogicalDabCounts.append(0)
            newGeneratedProjectedInstanceCounts.append(
                generatedProjectedDelta
            )
            priorEmittedHighWater = emitted
        }
        guard sawRetainedDab,
              encodedHighWater == expectedFinal,
              generatedProjectedHighWater
                == expectedProjectedInstanceTotal
        else {
            throw ArtifactFileSystem.invalid(
                "\(scene): long-stroke retained replay state or "
                    + "identity totals disagree "
                    + "(logical high-water \(encodedHighWater)/"
                    + "\(expectedFinal); generated projected "
                    + "\(generatedProjectedHighWater)/"
                    + "\(expectedProjectedInstanceTotal); "
                    + "max encoded GPU/frame \(maximumEncodedGPU))"
            )
        }
        return LongStrokeIdentityAudit(
            newLogicalDabCounts: newLogicalDabCounts,
            restampedLogicalDabCounts: restampedLogicalDabCounts,
            newGeneratedProjectedInstanceCounts:
                newGeneratedProjectedInstanceCounts,
            maximumEncodedGPUInstanceCount: maximumEncodedGPU
        )
    }

    private static func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[
            max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        ]
    }

    private static func close(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs.isFinite && rhs.isFinite
            && abs(lhs - rhs) <= max(1, abs(lhs), abs(rhs)) * 1e-12
    }

    private static func approximatelyEqual(
        _ lhs: Double,
        _ rhs: Double
    ) -> Bool {
        lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= 1e-5
    }
}
