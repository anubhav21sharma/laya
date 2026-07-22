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

public enum BenchmarkMetricError: Error, Equatable, LocalizedError {
    case insufficientLongStrokeFrames(Int)
    case nonFiniteMeasurement(series: String, frame: Int)
    case nonPositiveMeasurement(series: String, frame: Int, value: Double)
    case nonUniformProjectedInstanceCount(
        frame: Int,
        expected: Int,
        actual: Int
    )
    case longStrokeP95Growth(
        series: String,
        early: Double,
        late: Double,
        limit: Double
    )
    case longStrokeSlopeGrowth(
        series: String,
        actual: Double,
        limit: Double
    )

    public var errorDescription: String? {
        switch self {
        case let .insufficientLongStrokeFrames(count):
            "Long-stroke metrics require exactly 400 measured frames; found \(count)."
        case let .nonFiniteMeasurement(series, frame):
            "Long-stroke \(series) measurement at frame \(frame) is not finite."
        case let .nonPositiveMeasurement(series, frame, value):
            "Long-stroke \(series) measurement at frame \(frame) is \(value) ms instead of a positive measured duration."
        case let .nonUniformProjectedInstanceCount(frame, expected, actual):
            "Long-stroke frame \(frame) emitted \(actual) projected instances instead of \(expected)."
        case let .longStrokeP95Growth(series, early, late, limit):
            "Long-stroke \(series) late p95 \(late) ms exceeds \(limit) ms from early p95 \(early) ms."
        case let .longStrokeSlopeGrowth(series, actual, limit):
            "Long-stroke \(series) slope \(actual) ms/frame exceeds \(limit) ms/frame."
        }
    }
}

public struct BenchmarkLongStrokeMetrics: Equatable, Sendable {
    public static let segmentCount = 400
    public static let earlyWindow = 40...119
    public static let lateWindow = 280...359
    public static let maximumSlopeMillisecondsPerFrame = 0.001

    public let earlyCPUP95Milliseconds: Double
    public let lateCPUP95Milliseconds: Double
    public let earlyDabGPUP95Milliseconds: Double
    public let lateDabGPUP95Milliseconds: Double
    public let cpuMillisecondsPerFrameSlope: Double
    public let dabGPUMillisecondsPerFrameSlope: Double

    public static func measure(
        cpuMilliseconds: [Double],
        dabGPUMilliseconds: [Double],
        projectedInstanceCounts: [Int]
    ) throws -> BenchmarkLongStrokeMetrics {
        let measuredCount = min(
            cpuMilliseconds.count,
            dabGPUMilliseconds.count,
            projectedInstanceCounts.count
        )
        guard
            cpuMilliseconds.count == segmentCount,
            dabGPUMilliseconds.count == segmentCount,
            projectedInstanceCounts.count == segmentCount
        else {
            throw BenchmarkMetricError.insufficientLongStrokeFrames(
                measuredCount
            )
        }

        try validateMeasurements(cpuMilliseconds, series: "cpu")
        try validateMeasurements(dabGPUMilliseconds, series: "dabGPU")
        guard let expectedCount = projectedInstanceCounts.first else {
            throw BenchmarkMetricError.insufficientLongStrokeFrames(0)
        }
        for (frame, actualCount) in projectedInstanceCounts.enumerated()
        where actualCount != expectedCount {
            throw BenchmarkMetricError.nonUniformProjectedInstanceCount(
                frame: frame,
                expected: expectedCount,
                actual: actualCount
            )
        }

        let earlyCPU = BenchmarkRecord.percentile95(
            Array(cpuMilliseconds[earlyWindow])
        )
        let lateCPU = BenchmarkRecord.percentile95(
            Array(cpuMilliseconds[lateWindow])
        )
        let earlyDabGPU = BenchmarkRecord.percentile95(
            Array(dabGPUMilliseconds[earlyWindow])
        )
        let lateDabGPU = BenchmarkRecord.percentile95(
            Array(dabGPUMilliseconds[lateWindow])
        )
        try validateP95(
            series: "cpu",
            early: earlyCPU,
            late: lateCPU
        )
        try validateP95(
            series: "dabGPU",
            early: earlyDabGPU,
            late: lateDabGPU
        )

        let cpuSlope = leastSquaresSlope(cpuMilliseconds)
        let dabGPUSlope = leastSquaresSlope(dabGPUMilliseconds)
        try validateSlope(series: "cpu", slope: cpuSlope)
        try validateSlope(series: "dabGPU", slope: dabGPUSlope)

        return BenchmarkLongStrokeMetrics(
            earlyCPUP95Milliseconds: earlyCPU,
            lateCPUP95Milliseconds: lateCPU,
            earlyDabGPUP95Milliseconds: earlyDabGPU,
            lateDabGPUP95Milliseconds: lateDabGPU,
            cpuMillisecondsPerFrameSlope: cpuSlope,
            dabGPUMillisecondsPerFrameSlope: dabGPUSlope
        )
    }

    public static func leastSquaresSlope(_ values: [Double]) -> Double {
        guard values.count > 1 else {
            return 0
        }
        let count = Double(values.count)
        let meanX = Double(values.count - 1) * 0.5
        let meanY = values.reduce(0, +) / count
        var numerator = 0.0
        var denominator = 0.0
        for (index, value) in values.enumerated() {
            let centeredX = Double(index) - meanX
            numerator += centeredX * (value - meanY)
            denominator += centeredX * centeredX
        }
        return numerator / denominator
    }

    private static func validateMeasurements(
        _ values: [Double],
        series: String
    ) throws {
        for (frame, value) in values.enumerated() {
            guard value.isFinite else {
                throw BenchmarkMetricError.nonFiniteMeasurement(
                    series: series,
                    frame: frame
                )
            }
            guard value > 0 else {
                throw BenchmarkMetricError.nonPositiveMeasurement(
                    series: series,
                    frame: frame,
                    value: value
                )
            }
        }
    }

    private static func validateP95(
        series: String,
        early: Double,
        late: Double
    ) throws {
        let limit = max(early * 1.15, early + 0.10)
        guard late <= limit else {
            throw BenchmarkMetricError.longStrokeP95Growth(
                series: series,
                early: early,
                late: late,
                limit: limit
            )
        }
    }

    private static func validateSlope(
        series: String,
        slope: Double
    ) throws {
        guard slope <= maximumSlopeMillisecondsPerFrame else {
            throw BenchmarkMetricError.longStrokeSlopeGrowth(
                series: series,
                actual: slope,
                limit: maximumSlopeMillisecondsPerFrame
            )
        }
    }
}

public struct BenchmarkRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let timestampUTC: String
    public let sceneName: String
    public let program: String?
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
    public let tilingRawValue: UInt32?
    public let tileWidth: Int?
    public let tileHeight: Int?
    public let totalProjectedFragmentCount: Int?
    public let maximumFragmentsPerFootprint: Int?
    public let totalInstanceBytes: Int?
    public let oracleHoleCount: Int?
    public let oraclePhantomCount: Int?
    public let oracleMaximumDelta: Int?
    public let diagnosticMode: String?
    public let longStrokeEarlyCPUP95Milliseconds: Double?
    public let longStrokeLateCPUP95Milliseconds: Double?
    public let longStrokeEarlyDabGPUP95Milliseconds: Double?
    public let longStrokeLateDabGPUP95Milliseconds: Double?
    public let longStrokeCPUMillisecondsPerFrameSlope: Double?
    public let longStrokeDabGPUMillisecondsPerFrameSlope: Double?
    public let revisionCaptureMilliseconds: [Double]?
    public let revisionRestoreMilliseconds: [Double]?
    public let historyResidentBytes: Int?
    public let historyCommandCount: Int?
    public let historyCanUndo: Bool?
    public let historyCanRedo: Bool?
    public let historyAppendCount: Int?
    public let historyNavigationFinishCount: Int?
    public let historyReleasedRevisionCount: Int?
    public let changedRegionCount: Int?
    public let coloredOutputMismatchCount: Int?
    public let previewCommitViolationCount: Int?
    public let recipeID: String?
    public let material: String?
    public let seed: UInt64?
    public let replayMode: String?
    public let peakRetainedSampleCount: Int?
    public let peakRetainedDabCount: Int?
    public let replayCount: Int?
    public let promotedSettledPrefixCount: Int?
    public let replayDegradationCount: Int?
    public let assetResidentBytes: Int?
    public let materialGPUMilliseconds: [Double]?
    public let fiveHundredDabStressFrameIndex: Int?
    public let fiveHundredDabStressNewDabCount: Int?
    public let processedWashPixelCount: Int?
    public let washWorkingBytes: Int?

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
        missedFrameCount: Int? = nil,
        tilingRawValue: UInt32? = nil,
        tileWidth: Int? = nil,
        tileHeight: Int? = nil,
        totalProjectedFragmentCount: Int? = nil,
        maximumFragmentsPerFootprint: Int? = nil,
        totalInstanceBytes: Int? = nil,
        oracleHoleCount: Int? = nil,
        oraclePhantomCount: Int? = nil,
        oracleMaximumDelta: Int? = nil,
        diagnosticMode: String? = nil,
        longStrokeEarlyCPUP95Milliseconds: Double? = nil,
        longStrokeLateCPUP95Milliseconds: Double? = nil,
        longStrokeEarlyDabGPUP95Milliseconds: Double? = nil,
        longStrokeLateDabGPUP95Milliseconds: Double? = nil,
        longStrokeCPUMillisecondsPerFrameSlope: Double? = nil,
        longStrokeDabGPUMillisecondsPerFrameSlope: Double? = nil,
        revisionCaptureMilliseconds: [Double]? = nil,
        revisionRestoreMilliseconds: [Double]? = nil,
        historyResidentBytes: Int? = nil,
        historyCommandCount: Int? = nil,
        historyCanUndo: Bool? = nil,
        historyCanRedo: Bool? = nil,
        historyAppendCount: Int? = nil,
        historyNavigationFinishCount: Int? = nil,
        historyReleasedRevisionCount: Int? = nil,
        changedRegionCount: Int? = nil,
        coloredOutputMismatchCount: Int? = nil,
        previewCommitViolationCount: Int? = nil,
        recipeID: String? = nil,
        material: String? = nil,
        seed: UInt64? = nil,
        replayMode: String? = nil,
        peakRetainedSampleCount: Int? = nil,
        peakRetainedDabCount: Int? = nil,
        replayCount: Int? = nil,
        promotedSettledPrefixCount: Int? = nil,
        replayDegradationCount: Int? = nil,
        assetResidentBytes: Int? = nil,
        materialGPUMilliseconds: [Double]? = nil,
        fiveHundredDabStressFrameIndex: Int? = nil,
        fiveHundredDabStressNewDabCount: Int? = nil,
        processedWashPixelCount: Int? = nil,
        washWorkingBytes: Int? = nil,
        program: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.timestampUTC = timestampUTC
        self.sceneName = sceneName
        self.program = program
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
        self.tilingRawValue = tilingRawValue
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.totalProjectedFragmentCount = totalProjectedFragmentCount
        self.maximumFragmentsPerFootprint = maximumFragmentsPerFootprint
        self.totalInstanceBytes = totalInstanceBytes
        self.oracleHoleCount = oracleHoleCount
        self.oraclePhantomCount = oraclePhantomCount
        self.oracleMaximumDelta = oracleMaximumDelta
        self.diagnosticMode = diagnosticMode
        self.longStrokeEarlyCPUP95Milliseconds =
            longStrokeEarlyCPUP95Milliseconds
        self.longStrokeLateCPUP95Milliseconds =
            longStrokeLateCPUP95Milliseconds
        self.longStrokeEarlyDabGPUP95Milliseconds =
            longStrokeEarlyDabGPUP95Milliseconds
        self.longStrokeLateDabGPUP95Milliseconds =
            longStrokeLateDabGPUP95Milliseconds
        self.longStrokeCPUMillisecondsPerFrameSlope =
            longStrokeCPUMillisecondsPerFrameSlope
        self.longStrokeDabGPUMillisecondsPerFrameSlope =
            longStrokeDabGPUMillisecondsPerFrameSlope
        self.revisionCaptureMilliseconds = revisionCaptureMilliseconds
        self.revisionRestoreMilliseconds = revisionRestoreMilliseconds
        self.historyResidentBytes = historyResidentBytes
        self.historyCommandCount = historyCommandCount
        self.historyCanUndo = historyCanUndo
        self.historyCanRedo = historyCanRedo
        self.historyAppendCount = historyAppendCount
        self.historyNavigationFinishCount = historyNavigationFinishCount
        self.historyReleasedRevisionCount = historyReleasedRevisionCount
        self.changedRegionCount = changedRegionCount
        self.coloredOutputMismatchCount = coloredOutputMismatchCount
        self.previewCommitViolationCount = previewCommitViolationCount
        self.recipeID = recipeID
        self.material = material
        self.seed = seed
        self.replayMode = replayMode
        self.peakRetainedSampleCount = peakRetainedSampleCount
        self.peakRetainedDabCount = peakRetainedDabCount
        self.replayCount = replayCount
        self.promotedSettledPrefixCount = promotedSettledPrefixCount
        self.replayDegradationCount = replayDegradationCount
        self.assetResidentBytes = assetResidentBytes
        self.materialGPUMilliseconds = materialGPUMilliseconds
        self.fiveHundredDabStressFrameIndex = fiveHundredDabStressFrameIndex
        self.fiveHundredDabStressNewDabCount = fiveHundredDabStressNewDabCount
        self.processedWashPixelCount = processedWashPixelCount
        self.washWorkingBytes = washWorkingBytes
    }

    public static func encode(_ record: BenchmarkRecord) throws -> Data {
        try record.validateVersionedMetrics()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(record)
    }

    public static func decode(_ data: Data) throws -> BenchmarkRecord {
        let record = try JSONDecoder().decode(BenchmarkRecord.self, from: data)
        try record.validateVersionedMetrics()
        return record
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

    private func validateVersionedMetrics() throws {
        if schemaVersion == 4 || schemaVersion == 5 {
            try validateSchemaFourMetrics()
        }
        if schemaVersion == 5 {
            try validateSchemaFiveMetrics()
        }
    }

    private func validateSchemaFourMetrics() throws {

        guard program != nil else {
            throw BenchmarkRecordError.missingSchemaFourMetric("program")
        }

        guard let revisionCaptureMilliseconds else {
            throw BenchmarkRecordError.missingSchemaFourMetric(
                "revisionCaptureMilliseconds"
            )
        }
        guard let revisionRestoreMilliseconds else {
            throw BenchmarkRecordError.missingSchemaFourMetric(
                "revisionRestoreMilliseconds"
            )
        }
        guard let historyResidentBytes else {
            throw BenchmarkRecordError.missingSchemaFourMetric(
                "historyResidentBytes"
            )
        }
        guard let historyCommandCount else {
            throw BenchmarkRecordError.missingSchemaFourMetric(
                "historyCommandCount"
            )
        }
        guard historyCanUndo != nil else {
            throw BenchmarkRecordError.missingSchemaFourMetric(
                "historyCanUndo"
            )
        }
        guard historyCanRedo != nil else {
            throw BenchmarkRecordError.missingSchemaFourMetric(
                "historyCanRedo"
            )
        }
        guard let historyAppendCount else {
            throw BenchmarkRecordError.missingSchemaFourMetric(
                "historyAppendCount"
            )
        }
        guard let historyNavigationFinishCount else {
            throw BenchmarkRecordError.missingSchemaFourMetric(
                "historyNavigationFinishCount"
            )
        }
        guard let historyReleasedRevisionCount else {
            throw BenchmarkRecordError.missingSchemaFourMetric(
                "historyReleasedRevisionCount"
            )
        }
        guard let changedRegionCount else {
            throw BenchmarkRecordError.missingSchemaFourMetric(
                "changedRegionCount"
            )
        }
        guard let coloredOutputMismatchCount else {
            throw BenchmarkRecordError.missingSchemaFourMetric(
                "coloredOutputMismatchCount"
            )
        }
        guard let previewCommitViolationCount else {
            throw BenchmarkRecordError.missingSchemaFourMetric(
                "previewCommitViolationCount"
            )
        }

        try Self.validateNonnegativeFinite(
            cpuEncodeMilliseconds,
            field: "cpuEncodeMilliseconds"
        )
        try Self.validateNonnegativeFinite(
            gpuMilliseconds,
            field: "gpuMilliseconds"
        )
        try Self.validateNonnegativeFinite(
            revisionCaptureMilliseconds,
            field: "revisionCaptureMilliseconds"
        )
        try Self.validateNonnegativeFinite(
            revisionRestoreMilliseconds,
            field: "revisionRestoreMilliseconds"
        )
        guard frameCount >= 0 else {
            throw BenchmarkRecordError.invalidNumericValue(field: "frameCount")
        }
        for (field, value) in [
            ("historyResidentBytes", historyResidentBytes),
            ("historyCommandCount", historyCommandCount),
            ("historyAppendCount", historyAppendCount),
            ("historyNavigationFinishCount", historyNavigationFinishCount),
            ("historyReleasedRevisionCount", historyReleasedRevisionCount),
            ("changedRegionCount", changedRegionCount),
            ("coloredOutputMismatchCount", coloredOutputMismatchCount),
            ("previewCommitViolationCount", previewCommitViolationCount),
        ] where value < 0 {
            throw BenchmarkRecordError.invalidNumericValue(field: field)
        }
    }

    private func validateSchemaFiveMetrics() throws {
        guard let recipeID,
              !recipeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw BenchmarkRecordError.missingSchemaFiveMetric("recipeID")
        }
        guard let material else {
            throw BenchmarkRecordError.missingSchemaFiveMetric("material")
        }
        guard ["ink", "dry", "glaze", "boundedWash"].contains(material) else {
            throw BenchmarkRecordError.invalidTextValue(
                field: "material",
                value: material
            )
        }
        guard let seed else {
            throw BenchmarkRecordError.missingSchemaFiveMetric("seed")
        }
        guard seed != 0 else {
            throw BenchmarkRecordError.invalidNumericValue(field: "seed")
        }
        guard let replayMode else {
            throw BenchmarkRecordError.missingSchemaFiveMetric("replayMode")
        }
        guard ["appendOnly", "replayTail", "boundedWholeStroke"]
            .contains(replayMode)
        else {
            throw BenchmarkRecordError.invalidTextValue(
                field: "replayMode",
                value: replayMode
            )
        }
        guard let peakRetainedSampleCount else {
            throw BenchmarkRecordError.missingSchemaFiveMetric(
                "peakRetainedSampleCount"
            )
        }
        guard let peakRetainedDabCount else {
            throw BenchmarkRecordError.missingSchemaFiveMetric(
                "peakRetainedDabCount"
            )
        }
        guard let replayCount else {
            throw BenchmarkRecordError.missingSchemaFiveMetric("replayCount")
        }
        guard let promotedSettledPrefixCount else {
            throw BenchmarkRecordError.missingSchemaFiveMetric(
                "promotedSettledPrefixCount"
            )
        }
        guard let replayDegradationCount else {
            throw BenchmarkRecordError.missingSchemaFiveMetric(
                "replayDegradationCount"
            )
        }
        guard let assetResidentBytes else {
            throw BenchmarkRecordError.missingSchemaFiveMetric(
                "assetResidentBytes"
            )
        }
        guard let materialGPUMilliseconds else {
            throw BenchmarkRecordError.missingSchemaFiveMetric(
                "materialGPUMilliseconds"
            )
        }
        guard let dabGPUMilliseconds else {
            throw BenchmarkRecordError.missingSchemaFiveMetric(
                "dabGPUMilliseconds"
            )
        }
        guard let newInstanceCounts else {
            throw BenchmarkRecordError.missingSchemaFiveMetric(
                "newInstanceCounts"
            )
        }
        guard let processedWashPixelCount else {
            throw BenchmarkRecordError.missingSchemaFiveMetric(
                "processedWashPixelCount"
            )
        }
        guard let washWorkingBytes else {
            throw BenchmarkRecordError.missingSchemaFiveMetric(
                "washWorkingBytes"
            )
        }

        try Self.validateNonnegativeFinite(
            materialGPUMilliseconds,
            field: "materialGPUMilliseconds"
        )
        try Self.validateNonnegativeFinite(
            dabGPUMilliseconds,
            field: "dabGPUMilliseconds"
        )
        guard !newInstanceCounts.isEmpty,
              newInstanceCounts.count == dabGPUMilliseconds.count,
              newInstanceCounts.allSatisfy({ $0 >= 0 })
        else {
            throw BenchmarkRecordError.invalidNumericValue(
                field: "newInstanceCounts"
            )
        }
        let stressScene = "slice4-long-stroke-bounds"
        if sceneName == stressScene {
            guard let fiveHundredDabStressFrameIndex else {
                throw BenchmarkRecordError.missingSchemaFiveMetric(
                    "fiveHundredDabStressFrameIndex"
                )
            }
            guard let fiveHundredDabStressNewDabCount else {
                throw BenchmarkRecordError.missingSchemaFiveMetric(
                    "fiveHundredDabStressNewDabCount"
                )
            }
            guard fiveHundredDabStressFrameIndex
                    == dabGPUMilliseconds.index(before: dabGPUMilliseconds.endIndex),
                  fiveHundredDabStressNewDabCount == 500,
                  newInstanceCounts[fiveHundredDabStressFrameIndex] == 500
            else {
                throw BenchmarkRecordError.invalidNumericValue(
                    field: "fiveHundredDabStressFrameIndex"
                )
            }
        } else if fiveHundredDabStressFrameIndex != nil
                    || fiveHundredDabStressNewDabCount != nil
        {
            throw BenchmarkRecordError.invalidNumericValue(
                field: "fiveHundredDabStressFrameIndex"
            )
        }
        for (field, value) in [
            ("peakRetainedSampleCount", peakRetainedSampleCount),
            ("peakRetainedDabCount", peakRetainedDabCount),
            ("replayCount", replayCount),
            ("promotedSettledPrefixCount", promotedSettledPrefixCount),
            ("replayDegradationCount", replayDegradationCount),
            ("assetResidentBytes", assetResidentBytes),
            ("processedWashPixelCount", processedWashPixelCount),
            ("washWorkingBytes", washWorkingBytes),
        ] where value < 0 {
            throw BenchmarkRecordError.invalidNumericValue(field: field)
        }
    }

    private static func validateNonnegativeFinite(
        _ values: [Double],
        field: String
    ) throws {
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw BenchmarkRecordError.invalidNumericValue(field: field)
        }
    }
}

public enum BenchmarkRecordError: Error, Equatable, LocalizedError {
    case missingSchemaFourMetric(String)
    case missingSchemaFiveMetric(String)
    case invalidNumericValue(field: String)
    case invalidTextValue(field: String, value: String)

    public var errorDescription: String? {
        switch self {
        case let .missingSchemaFourMetric(field):
            "Schema 4 benchmark record requires '\(field)'."
        case let .missingSchemaFiveMetric(field):
            "Schema 5 benchmark record requires '\(field)'."
        case let .invalidNumericValue(field):
            "Benchmark field '\(field)' contains an invalid numeric value."
        case let .invalidTextValue(field, value):
            "Benchmark field '\(field)' contains invalid value '\(value)'."
        }
    }
}
