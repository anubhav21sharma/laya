import Foundation
import MetalRenderer
import Testing

@Test
func benchmarkRecordRoundTripsWithoutLosingMetrics() throws {
    let record = BenchmarkRecord(
        schemaVersion: 1,
        timestampUTC: "2026-07-18T12:00:00Z",
        sceneName: "blank-canvas",
        hardware: BenchmarkHardware(
            gpuName: "Test GPU",
            logicalProcessorCount: 8,
            physicalMemoryBytes: 16_000_000_000
        ),
        operatingSystem: "macOS Test",
        build: BenchmarkBuild(
            configuration: "Debug",
            gitCommit: "0123456789abcdef"
        ),
        frameCount: 1,
        cpuEncodeMilliseconds: [0.25],
        gpuMilliseconds: [0.50],
        peakResidentBytes: 42_000_000
    )

    let data = try BenchmarkRecord.encode(record)
    let decoded = try JSONDecoder().decode(BenchmarkRecord.self, from: data)

    #expect(decoded == record)
}
