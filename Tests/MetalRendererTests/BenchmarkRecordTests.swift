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

@Test
func sliceTwoBenchmarkRecordRoundTripsEveryAppendOnlyMetric() throws {
    let record = BenchmarkRecord(
        schemaVersion: 3,
        timestampUTC: "2026-07-20T12:00:00Z",
        sceneName: "projected-long-stroke",
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
        frameCount: 400,
        cpuEncodeMilliseconds: [0.25],
        gpuMilliseconds: [0.50],
        peakResidentBytes: 42_000_000,
        tilingRawValue: 1,
        tileWidth: 288,
        tileHeight: 192,
        totalProjectedFragmentCount: 400,
        maximumFragmentsPerFootprint: 1,
        totalInstanceBytes: 38_400,
        oracleHoleCount: 0,
        oraclePhantomCount: 0,
        oracleMaximumDelta: 0,
        diagnosticMode: "hardRound",
        longStrokeEarlyCPUP95Milliseconds: 0.25,
        longStrokeLateCPUP95Milliseconds: 0.26,
        longStrokeEarlyDabGPUP95Milliseconds: 0.50,
        longStrokeLateDabGPUP95Milliseconds: 0.51,
        longStrokeCPUMillisecondsPerFrameSlope: 0.0001,
        longStrokeDabGPUMillisecondsPerFrameSlope: 0.0002
    )

    let data = try BenchmarkRecord.encode(record)
    let decoded = try JSONDecoder().decode(BenchmarkRecord.self, from: data)

    #expect(decoded == record)
}

@Test
func sliceThreeBenchmarkRecordRoundTripsRequiredMetrics() throws {
    let record = BenchmarkRecord(
        schemaVersion: 4,
        timestampUTC: "2026-07-21T12:00:00Z",
        sceneName: "region-undo-seam",
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
        frameCount: 4,
        cpuEncodeMilliseconds: [0, 0.25],
        gpuMilliseconds: [0, 0.50],
        peakResidentBytes: 42_000_000,
        tilingRawValue: 0,
        tileWidth: 96,
        tileHeight: 80,
        diagnosticMode: "hardRound",
        revisionCaptureMilliseconds: [0.75],
        revisionRestoreMilliseconds: [0.50, 0.55],
        historyResidentBytes: 4_096,
        historyCommandCount: 1,
        changedRegionCount: 2,
        program: "regionUndoSeam"
    )

    let data = try BenchmarkRecord.encode(record)
    let decoded = try BenchmarkRecord.decode(data)

    #expect(decoded == record)
    #expect(decoded.revisionCaptureMilliseconds == [0.75])
    #expect(decoded.revisionRestoreMilliseconds == [0.50, 0.55])
    #expect(decoded.historyResidentBytes == 4_096)
    #expect(decoded.historyCommandCount == 1)
    #expect(decoded.changedRegionCount == 2)
}

@Test(arguments: [
    "revisionCaptureMilliseconds",
    "revisionRestoreMilliseconds",
    "historyResidentBytes",
    "historyCommandCount",
    "changedRegionCount",
])
func sliceThreeBenchmarkParserRequiresEveryNewMetric(_ key: String) throws {
    let valid = try BenchmarkRecord.encode(sliceThreeBenchmarkFixture())
    var object = try #require(
        JSONSerialization.jsonObject(with: valid) as? [String: Any]
    )
    object.removeValue(forKey: key)

    #expect(throws: BenchmarkRecordError.missingSchemaFourMetric(key)) {
        try BenchmarkRecord.decode(
            JSONSerialization.data(withJSONObject: object)
        )
    }
}

@Test
func sliceThreeBenchmarkParserRequiresProgramIdentity() throws {
    let valid = try BenchmarkRecord.encode(sliceThreeBenchmarkFixture())
    var object = try #require(
        JSONSerialization.jsonObject(with: valid) as? [String: Any]
    )
    object.removeValue(forKey: "program")

    #expect(throws: BenchmarkRecordError.missingSchemaFourMetric("program")) {
        try BenchmarkRecord.decode(
            JSONSerialization.data(withJSONObject: object)
        )
    }
}

@Test(arguments: [
    "revisionCaptureMilliseconds",
    "revisionRestoreMilliseconds",
    "historyResidentBytes",
    "historyCommandCount",
    "changedRegionCount",
])
func sliceThreeBenchmarkParserRejectsNegativeMetrics(_ key: String) throws {
    let valid = try BenchmarkRecord.encode(sliceThreeBenchmarkFixture())
    var object = try #require(
        JSONSerialization.jsonObject(with: valid) as? [String: Any]
    )
    if key.hasSuffix("Milliseconds") {
        object[key] = [-0.01]
    } else {
        object[key] = -1
    }

    #expect(throws: BenchmarkRecordError.invalidNumericValue(field: key)) {
        try BenchmarkRecord.decode(
            JSONSerialization.data(withJSONObject: object)
        )
    }
}

@Test
func sliceThreeBenchmarkEncoderRejectsNonfiniteTiming() {
    let record = sliceThreeBenchmarkFixture(capture: [.infinity])

    #expect(
        throws: BenchmarkRecordError.invalidNumericValue(
            field: "revisionCaptureMilliseconds"
        )
    ) {
        try BenchmarkRecord.encode(record)
    }
}

private func sliceThreeBenchmarkFixture(
    capture: [Double] = [0]
) -> BenchmarkRecord {
    BenchmarkRecord(
        schemaVersion: 4,
        timestampUTC: "2026-07-21T12:00:00Z",
        sceneName: "fixture",
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
        cpuEncodeMilliseconds: [0],
        gpuMilliseconds: [0],
        peakResidentBytes: 1,
        tilingRawValue: 0,
        tileWidth: 96,
        tileHeight: 80,
        diagnosticMode: "hardRound",
        revisionCaptureMilliseconds: capture,
        revisionRestoreMilliseconds: [0],
        historyResidentBytes: 0,
        historyCommandCount: 0,
        changedRegionCount: 0,
        program: "coloredDraw"
    )
}

@Test(arguments: [1, 2])
func legacyBenchmarkSchemasDecodeWithAbsentSliceTwoMetrics(
    schemaVersion: Int
) throws {
    let data = Data(
        """
        {
          "schemaVersion": \(schemaVersion),
          "timestampUTC": "2026-07-20T12:00:00Z",
          "sceneName": "legacy",
          "hardware": {
            "gpuName": "Test GPU",
            "logicalProcessorCount": 8,
            "physicalMemoryBytes": 16000000000
          },
          "operatingSystem": "macOS Test",
          "build": {
            "configuration": "Debug",
            "gitCommit": "0123456789abcdef"
          },
          "frameCount": 1,
          "cpuEncodeMilliseconds": [0.25],
          "gpuMilliseconds": [0.5],
          "peakResidentBytes": 42000000
        }
        """.utf8
    )

    let decoded = try JSONDecoder().decode(BenchmarkRecord.self, from: data)

    #expect(decoded.tilingRawValue == nil)
    #expect(decoded.tileWidth == nil)
    #expect(decoded.tileHeight == nil)
    #expect(decoded.totalProjectedFragmentCount == nil)
    #expect(decoded.maximumFragmentsPerFootprint == nil)
    #expect(decoded.totalInstanceBytes == nil)
    #expect(decoded.oracleHoleCount == nil)
    #expect(decoded.oraclePhantomCount == nil)
    #expect(decoded.oracleMaximumDelta == nil)
    #expect(decoded.diagnosticMode == nil)
    #expect(decoded.longStrokeEarlyCPUP95Milliseconds == nil)
    #expect(decoded.longStrokeLateCPUP95Milliseconds == nil)
    #expect(decoded.longStrokeEarlyDabGPUP95Milliseconds == nil)
    #expect(decoded.longStrokeLateDabGPUP95Milliseconds == nil)
    #expect(decoded.longStrokeCPUMillisecondsPerFrameSlope == nil)
    #expect(decoded.longStrokeDabGPUMillisecondsPerFrameSlope == nil)
}

@Test
func longStrokeSummaryUsesExactWindowsP95AndLeastSquaresSlopes() throws {
    let cpu = (0..<400).map { 0.20 + Double($0) * 0.0001 }
    let dab = (0..<400).map { 0.40 + Double($0) * 0.0002 }
    let summary = try BenchmarkLongStrokeMetrics.measure(
        cpuMilliseconds: cpu,
        dabGPUMilliseconds: dab,
        projectedInstanceCounts: [Int](repeating: 13, count: 400)
    )

    #expect(summary.earlyCPUP95Milliseconds == cpu[115])
    #expect(summary.lateCPUP95Milliseconds == cpu[355])
    #expect(summary.earlyDabGPUP95Milliseconds == dab[115])
    #expect(summary.lateDabGPUP95Milliseconds == dab[355])
    #expect(
        abs(summary.cpuMillisecondsPerFrameSlope - 0.0001) < 0.000_000_1
    )
    #expect(
        abs(summary.dabGPUMillisecondsPerFrameSlope - 0.0002)
            < 0.000_000_1
    )
}

@Test
func longStrokeSummaryFailsWhenRequiredWindowsAreUnavailable() {
    #expect(throws: BenchmarkMetricError.insufficientLongStrokeFrames(399)) {
        try BenchmarkLongStrokeMetrics.measure(
            cpuMilliseconds: [Double](repeating: 0.2, count: 399),
            dabGPUMilliseconds: [Double](repeating: 0.4, count: 400),
            projectedInstanceCounts: [Int](repeating: 13, count: 400)
        )
    }
}

@Test
func longStrokeSummaryFailsWhenMeasuredFramesEmitDifferentCounts() {
    var counts = [Int](repeating: 13, count: 400)
    counts[80] = 12

    #expect(
        throws: BenchmarkMetricError.nonUniformProjectedInstanceCount(
            frame: 80,
            expected: 13,
            actual: 12
        )
    ) {
        try BenchmarkLongStrokeMetrics.measure(
            cpuMilliseconds: [Double](repeating: 0.2, count: 400),
            dabGPUMilliseconds: [Double](repeating: 0.4, count: 400),
            projectedInstanceCounts: counts
        )
    }
}

@Test
func longStrokeSummaryRejectsZeroAndNegativeCPUMeasurements() {
    var zeroCPU = [Double](repeating: 0.2, count: 400)
    zeroCPU[17] = 0
    #expect(
        throws: BenchmarkMetricError.nonPositiveMeasurement(
            series: "cpu",
            frame: 17,
            value: 0
        )
    ) {
        try BenchmarkLongStrokeMetrics.measure(
            cpuMilliseconds: zeroCPU,
            dabGPUMilliseconds: [Double](repeating: 0.4, count: 400),
            projectedInstanceCounts: [Int](repeating: 1, count: 400)
        )
    }

    var negativeCPU = [Double](repeating: 0.2, count: 400)
    negativeCPU[23] = -0.01
    #expect(
        throws: BenchmarkMetricError.nonPositiveMeasurement(
            series: "cpu",
            frame: 23,
            value: -0.01
        )
    ) {
        try BenchmarkLongStrokeMetrics.measure(
            cpuMilliseconds: negativeCPU,
            dabGPUMilliseconds: [Double](repeating: 0.4, count: 400),
            projectedInstanceCounts: [Int](repeating: 1, count: 400)
        )
    }
}

@Test
func longStrokeSummaryRejectsZeroAndNegativeDabGPUMeasurements() {
    var zeroGPU = [Double](repeating: 0.4, count: 400)
    zeroGPU[31] = 0
    #expect(
        throws: BenchmarkMetricError.nonPositiveMeasurement(
            series: "dabGPU",
            frame: 31,
            value: 0
        )
    ) {
        try BenchmarkLongStrokeMetrics.measure(
            cpuMilliseconds: [Double](repeating: 0.2, count: 400),
            dabGPUMilliseconds: zeroGPU,
            projectedInstanceCounts: [Int](repeating: 1, count: 400)
        )
    }

    var negativeGPU = [Double](repeating: 0.4, count: 400)
    negativeGPU[47] = -0.02
    #expect(
        throws: BenchmarkMetricError.nonPositiveMeasurement(
            series: "dabGPU",
            frame: 47,
            value: -0.02
        )
    ) {
        try BenchmarkLongStrokeMetrics.measure(
            cpuMilliseconds: [Double](repeating: 0.2, count: 400),
            dabGPUMilliseconds: negativeGPU,
            projectedInstanceCounts: [Int](repeating: 1, count: 400)
        )
    }
}

@Test
func longStrokeSummaryRejectsNonfiniteCPUMeasurements() {
    for (frame, value) in [(61, Double.nan), (73, Double.infinity)] {
        var cpu = [Double](repeating: 0.2, count: 400)
        cpu[frame] = value
        #expect(
            throws: BenchmarkMetricError.nonFiniteMeasurement(
                series: "cpu",
                frame: frame
            )
        ) {
            try BenchmarkLongStrokeMetrics.measure(
                cpuMilliseconds: cpu,
                dabGPUMilliseconds: [Double](repeating: 0.4, count: 400),
                projectedInstanceCounts: [Int](repeating: 1, count: 400)
            )
        }
    }
}

@Test
func longStrokeSummaryRejectsNonfiniteDabGPUMeasurements() {
    for (frame, value) in [(89, -Double.infinity), (97, Double.nan)] {
        var gpu = [Double](repeating: 0.4, count: 400)
        gpu[frame] = value
        #expect(
            throws: BenchmarkMetricError.nonFiniteMeasurement(
                series: "dabGPU",
                frame: frame
            )
        ) {
            try BenchmarkLongStrokeMetrics.measure(
                cpuMilliseconds: [Double](repeating: 0.2, count: 400),
                dabGPUMilliseconds: gpu,
                projectedInstanceCounts: [Int](repeating: 1, count: 400)
            )
        }
    }
}

@Test
func longStrokeSummaryFailsClosedOnP95Growth() {
    var cpu = [Double](repeating: 0.2, count: 400)
    for index in 280...359 {
        cpu[index] = 0.31
    }

    #expect(
        throws: BenchmarkMetricError.longStrokeP95Growth(
            series: "cpu",
            early: 0.2,
            late: 0.31,
            limit: 0.30000000000000004
        )
    ) {
        try BenchmarkLongStrokeMetrics.measure(
            cpuMilliseconds: cpu,
            dabGPUMilliseconds: [Double](repeating: 0.4, count: 400),
            projectedInstanceCounts: [Int](repeating: 13, count: 400)
        )
    }
}

@Test
func longStrokeSummaryFailsClosedOnPositiveSlopeAboveLimit() {
    let cpu = (0..<400).map { 10 + Double($0) * 0.002 }

    #expect(
        throws: BenchmarkMetricError.longStrokeSlopeGrowth(
            series: "cpu",
            actual: 0.002,
            limit: 0.001
        )
    ) {
        try BenchmarkLongStrokeMetrics.measure(
            cpuMilliseconds: cpu,
            dabGPUMilliseconds: [Double](repeating: 0.4, count: 400),
            projectedInstanceCounts: [Int](repeating: 13, count: 400)
        )
    }
}
