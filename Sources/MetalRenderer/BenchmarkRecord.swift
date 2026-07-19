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
        peakResidentBytes: UInt64
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
    }

    public static func encode(_ record: BenchmarkRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(record)
    }
}
