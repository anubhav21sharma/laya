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
        frameCount: 200,
        cpuEncodeMilliseconds: [0.25],
        gpuMilliseconds: [0.50],
        peakResidentBytes: 42_000_000,
        brushProcessingMilliseconds: [0.4, 0.5],
        eventToSubmitMilliseconds: [1.0, 1.1],
        dabGPUMilliseconds: [0.8],
        gridGPUMilliseconds: [0.6, 0.7],
        commitGPUMilliseconds: [0.9],
        commitPendingMilliseconds: [3.2],
        displayFrameBudgetMilliseconds: 16.667,
        newInstanceCounts: [12, 9],
        totalStrokeInstanceCounts: [12, 21],
        missedFrameCount: 1
    )

    let data = try BenchmarkRecord.encode(record)
    let decoded = try JSONDecoder().decode(BenchmarkRecord.self, from: data)

    #expect(decoded == record)
    #expect(record.missedFrameFraction == 0.005)
    #expect(BenchmarkRecord.percentile95([1, 2, 3, 4, 100]) == 100)
}
