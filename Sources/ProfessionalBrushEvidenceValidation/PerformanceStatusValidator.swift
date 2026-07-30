import Foundation

enum PerformanceStatusValidator {
    struct Status: Decodable {
        let schemaVersion: Int
        let correctnessPassed: Bool
        let gpuName: String
        let gpuClassification: String
        let cpuPreparationP95Milliseconds: Double
        let cpuPreparationBudgetMilliseconds: Double
        let gpu500DabMilliseconds: Double
        let gpu500DabBudgetMilliseconds: Double
        let completedStrokeLengthIndependent: Bool
        let hotPathCompilerResourceCountersZero: Bool
    }

    static func validate(
        _ data: Data,
        expectedGPUName: String,
        measuredCPUP95Milliseconds: Double,
        stageFourRoot: URL
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
                "completedStrokeLengthIndependent",
                "hotPathCompilerResourceCountersZero",
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
        let measuredGPU = try stageFourGPUMaximum(root: stageFourRoot)
        guard status.schemaVersion == 1,
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
              close(status.gpu500DabMilliseconds, measuredGPU),
              status.completedStrokeLengthIndependent,
              status.hotPathCompilerResourceCountersZero
        else {
            throw ArtifactFileSystem.invalid(
                "performance status disagrees with measured artifacts"
            )
        }
        if status.gpuClassification == "physical" {
            guard status.gpu500DabMilliseconds < 3 else {
                throw ArtifactFileSystem.invalid(
                    "physical GPU 500-dab budget was exceeded"
                )
            }
            return true
        }
        return false
    }

    private static func stageFourGPUMaximum(root: URL) throws -> Double {
        let data = try ArtifactFileSystem.regularFileData(
            root.appendingPathComponent(
                "logs/five-hundred-dabs.benchmark.json"
            ),
            label: "Stage 4 five-hundred-dab benchmark"
        )
        let object = try ArtifactFileSystem.jsonObject(
            data,
            label: "Stage 4 five-hundred-dab benchmark"
        )
        guard let values = object["dabGPUMilliseconds"] as? [Double],
              !values.isEmpty,
              values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              let maximum = values.max()
        else {
            throw ArtifactFileSystem.invalid(
                "Stage 4 GPU metric is unavailable"
            )
        }
        return maximum
    }

    private static func close(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs.isFinite && rhs.isFinite
            && abs(lhs - rhs) <= max(1, abs(lhs), abs(rhs)) * 1e-12
    }
}
