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
    }

    static func validate(
        _ data: Data,
        expectedGPUName: String,
        expectedOperatingSystem: String,
        expectedCommit: String,
        expectedRendererSHA256: String,
        measuredCPUP95Milliseconds: Double,
        positiveRoot: URL
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
        let gpuByBrush = try validateProfessionalPerformanceArtifacts(
            positiveRoot: positiveRoot,
            expectedGPUName: expectedGPUName,
            expectedOperatingSystem: expectedOperatingSystem,
            expectedCommit: expectedCommit,
            expectedRendererSHA256: expectedRendererSHA256
        )
        guard let measuredGPU = gpuByBrush.values.max(),
              status.schemaVersion == 2,
              status.correctnessPassed,
              status.gpuName == expectedGPUName,
              status.gpuClassification
                == ArtifactFileSystem.gpuClassification(expectedGPUName),
              status.cpuPreparationP95Milliseconds.isFinite,
              status.cpuPreparationP95Milliseconds >= 0,
              status.cpuPreparationBudgetMilliseconds == 2,
              close(
                  status.cpuPreparationP95Milliseconds,
                  measuredCPUP95Milliseconds
              ),
              status.cpuPreparationP95Milliseconds < 2,
              status.gpu500DabMilliseconds.isFinite,
              status.gpu500DabMilliseconds >= 0,
              status.gpu500DabBudgetMilliseconds == 3,
              close(status.gpu500DabMilliseconds, measuredGPU)
        else {
            throw ArtifactFileSystem.invalid(
                "performance status disagrees with Stage 5 professional artifacts"
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
        expectedRendererSHA256: String
    ) throws -> [String: Double] {
        guard try ArtifactFileSystem.entryNames(positiveRoot)
                == Set(ProfessionalBrushTruth.positiveSceneNames)
        else {
            throw ArtifactFileSystem.invalid(
                "professional performance scene set is not exact"
            )
        }
        var result: [String: Double] = [:]
        for scene in ProfessionalBrushTruth.positiveSceneNames {
            let directory = positiveRoot.appendingPathComponent(scene)
            result[scene] = try validatePerformanceIndex(
                directory: directory,
                scene: scene,
                expectedGPUName: expectedGPUName,
                expectedOperatingSystem: expectedOperatingSystem,
                expectedCommit: expectedCommit,
                expectedRendererSHA256: expectedRendererSHA256
            )
        }
        return result
    }

    private static func validatePerformanceIndex(
        directory: URL,
        scene: String,
        expectedGPUName: String,
        expectedOperatingSystem: String,
        expectedCommit: String,
        expectedRendererSHA256: String
    ) throws -> Double {
        guard let truth = ProfessionalBrushTruth.sceneTruth[scene] else {
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
              index["definitionID"] as? String == truth.definitionID,
              index["semanticHash"] as? String == truth.semanticHash,
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
            source: source
        )
        try validateLongStroke(
            longData,
            directory: directory,
            scene: scene,
            truth: truth,
            source: source
        )
        return gpu
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
        truth: ProfessionalSceneTruth,
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
              raw["definitionID"] as? String == truth.definitionID,
              raw["semanticHash"] as? String == truth.semanticHash,
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
        truth: ProfessionalSceneTruth,
        source: [String: Any]
    ) throws {
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
                "newInstanceCounts", "restampedInstanceCounts",
                "logicalDabCount", "projectedInstanceCount",
                "replayMode", "replayMaximumDabs",
                "replayMaximumProjectedInstances",
                "compilerCountersBefore", "compilerCountersAfter",
            ],
            label: "\(scene) long-stroke raw evidence"
        )
        guard integer(raw["schemaVersion"]) == 1,
              raw["workloadID"] as? String
                == "professional-long-stroke",
              raw["scene"] as? String == scene,
              raw["definitionID"] as? String == truth.definitionID,
              raw["semanticHash"] as? String == truth.semanticHash,
              validResources(raw["resolvedResources"], truth: truth),
              dictionariesEqual(raw["source"], source),
              integer(raw["inputSampleCount"]) == 128,
              raw["tracePath"] as? String
                == "professional-long-stroke-trace.json",
              let traceDigest = raw["traceSHA256"] as? String,
              ArtifactFileSystem.isSHA256(traceDigest),
              let cpu = doubles(raw["cpuPreparationMilliseconds"]),
              let gpu = doubles(raw["gpuMilliseconds"]),
              cpu.count == 128,
              gpu.count == 128,
              let newInstances = integers(raw["newInstanceCounts"]),
              let restamped = integers(raw["restampedInstanceCounts"]),
              newInstances.count == 128,
              restamped.count == 128,
              restamped.allSatisfy({ $0 == 0 }),
              let logicalDabs = integer(raw["logicalDabCount"]),
              let projected = integer(raw["projectedInstanceCount"]),
              let maximumDabs = integer(raw["replayMaximumDabs"]),
              let maximumProjected =
                integer(raw["replayMaximumProjectedInstances"]),
              maximumDabs == 2_048,
              maximumProjected == 4_096,
              newInstances.allSatisfy({
                  $0 >= 0 && $0 <= maximumProjected
              }),
              logicalDabs > 0,
              projected >= logicalDabs,
              raw["replayMode"] as? String == "replayTail",
              validUnchangedCounters(
                  raw["compilerCountersBefore"],
                  raw["compilerCountersAfter"]
              ),
              stableQuartiles(cpu),
              stableQuartiles(gpu)
        else {
            throw ArtifactFileSystem.invalid(
                "\(scene): long-stroke work is not length-independent or hot-path clean"
            )
        }
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
            truth: truth
        )
    }

    private static func validateTrace(
        _ data: Data,
        scene: String,
        truth: ProfessionalSceneTruth
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
              trace["definitionID"] as? String == truth.definitionID,
              trace["semanticHash"] as? String == truth.semanticHash,
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

    private static func stableQuartiles(_ values: [Double]) -> Bool {
        guard values.count == 128 else { return false }
        let early = percentile95(Array(values.prefix(32)))
        let late = percentile95(Array(values.suffix(32)))
        return late <= max(early * 2, early + 0.5)
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
