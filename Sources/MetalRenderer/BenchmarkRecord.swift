import Foundation

public struct BenchmarkHardware: Codable, Equatable, Sendable {
    public let gpuName: String
    public let logicalProcessorCount: Int
    public let physicalMemoryBytes: UInt64

    public init(
        gpuName: String,
        logicalProcessorCount: Int,
        physicalMemoryBytes: UInt64
    ) {
        self.gpuName = gpuName
        self.logicalProcessorCount = logicalProcessorCount
        self.physicalMemoryBytes = physicalMemoryBytes
    }
}

public struct BenchmarkBuild: Codable, Equatable, Sendable {
    public let configuration: String
    public let gitCommit: String

    public init(configuration: String, gitCommit: String) {
        self.configuration = configuration
        self.gitCommit = gitCommit
    }
}

public struct BenchmarkRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let timestampUTC: String
    public let sceneName: String
    public let hardware: BenchmarkHardware
    public let operatingSystem: String
    public let build: BenchmarkBuild
    public let frameCount: Int
    public let cpuEncodeMilliseconds: [Double]
    public let gpuMilliseconds: [Double]
    public let peakResidentBytes: UInt64
    public let brushProcessingMilliseconds: [Double]?
    public let eventToSubmitMilliseconds: [Double]?
    public let dabGPUMilliseconds: [Double]?
    public let gridGPUMilliseconds: [Double]?
    public let commitGPUMilliseconds: [Double]?
    public let commitPendingMilliseconds: [Double]?
    public let displayFrameBudgetMilliseconds: Double?
    public let newInstanceCounts: [Int]?
    public let totalStrokeInstanceCounts: [Int]?
    public let missedFrameCount: Int?

    public init(
        schemaVersion: Int,
        timestampUTC: String,
        sceneName: String,
        hardware: BenchmarkHardware,
        operatingSystem: String,
        build: BenchmarkBuild,
        frameCount: Int,
        cpuEncodeMilliseconds: [Double],
        gpuMilliseconds: [Double],
        peakResidentBytes: UInt64,
        brushProcessingMilliseconds: [Double]? = nil,
        eventToSubmitMilliseconds: [Double]? = nil,
        dabGPUMilliseconds: [Double]? = nil,
        gridGPUMilliseconds: [Double]? = nil,
        commitGPUMilliseconds: [Double]? = nil,
        commitPendingMilliseconds: [Double]? = nil,
        displayFrameBudgetMilliseconds: Double? = nil,
        newInstanceCounts: [Int]? = nil,
        totalStrokeInstanceCounts: [Int]? = nil,
        missedFrameCount: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.timestampUTC = timestampUTC
        self.sceneName = sceneName
        self.hardware = hardware
        self.operatingSystem = operatingSystem
        self.build = build
        self.frameCount = frameCount
        self.cpuEncodeMilliseconds = cpuEncodeMilliseconds
        self.gpuMilliseconds = gpuMilliseconds
        self.peakResidentBytes = peakResidentBytes
        self.brushProcessingMilliseconds = brushProcessingMilliseconds
        self.eventToSubmitMilliseconds = eventToSubmitMilliseconds
        self.dabGPUMilliseconds = dabGPUMilliseconds
        self.gridGPUMilliseconds = gridGPUMilliseconds
        self.commitGPUMilliseconds = commitGPUMilliseconds
        self.commitPendingMilliseconds = commitPendingMilliseconds
        self.displayFrameBudgetMilliseconds = displayFrameBudgetMilliseconds
        self.newInstanceCounts = newInstanceCounts
        self.totalStrokeInstanceCounts = totalStrokeInstanceCounts
        self.missedFrameCount = missedFrameCount
    }

    public static func encode(_ record: BenchmarkRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(record)
    }

    public static func percentile95(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        let sorted = values.sorted()
        let index = Int(ceil(Double(sorted.count) * 0.95)) - 1
        return sorted[max(0, min(index, sorted.count - 1))]
    }

    public var missedFrameFraction: Double {
        guard frameCount > 0 else {
            return 0
        }
        return Double(missedFrameCount ?? 0) / Double(frameCount)
    }
}
