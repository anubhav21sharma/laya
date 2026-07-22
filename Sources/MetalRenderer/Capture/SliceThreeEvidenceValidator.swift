import CShaderTypes
import Foundation
import ImageIO
import PatternEngine
import UniformTypeIdentifiers

public enum SliceThreeEvidenceValidationError: Error, Equatable, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(message): message
        }
    }
}

public enum SliceThreeEvidenceValidationStatus: Equatable, Sendable {
    case passed
    case performancePending(gpuName: String)
}

public enum SliceThreeEvidenceValidator {
    private struct Truth {
        let program: String
        let tileWidth: Int
        let tileHeight: Int
        let frameCount: Int
        let brushCount: Int
        let eventCount: Int
        let dabCount: Int
        let gridCount: Int
        let commitCount: Int
        let captureCount: Int
        let restoreCount: Int
        let historyBytes: Int
        let historyCommands: Int
        let historyNavigationFinishes: Int
        let changedRegions: Int
        let fragments: Int
        let maximumFragments: Int
        let instanceBytes: Int
        let primarySuffix: String
        let pngSizes: [String: PixelSize]
    }

    private struct PerformanceTruth {
        let frameCount: Int
        let cpuCount: Int
        let gpuCount: Int
        let brushCount: Int
        let eventCount: Int
        let dabCount: Int
        let gridCount: Int
        let commitCount: Int
        let fragments: Int
        let maximumFragments: Int
        let instanceBytes: Int
    }

    private static let schemaFourKeys: Set<String> = [
        "schemaVersion", "timestampUTC", "sceneName", "program",
        "hardware", "operatingSystem", "build", "frameCount",
        "cpuEncodeMilliseconds", "gpuMilliseconds", "peakResidentBytes",
        "brushProcessingMilliseconds", "eventToSubmitMilliseconds",
        "dabGPUMilliseconds", "gridGPUMilliseconds",
        "commitGPUMilliseconds", "displayFrameBudgetMilliseconds",
        "missedFrameCount", "tilingRawValue", "tileWidth", "tileHeight",
        "totalProjectedFragmentCount", "maximumFragmentsPerFootprint",
        "totalInstanceBytes", "diagnosticMode",
        "revisionCaptureMilliseconds", "revisionRestoreMilliseconds",
        "historyResidentBytes", "historyCommandCount", "changedRegionCount",
        "historyCanUndo", "historyCanRedo", "historyAppendCount",
        "historyNavigationFinishCount", "historyReleasedRevisionCount",
        "coloredOutputMismatchCount", "previewCommitViolationCount",
    ]
    private static let hardwareKeys: Set<String> = [
        "gpuName", "logicalProcessorCount", "physicalMemoryBytes",
    ]
    private static let buildKeys: Set<String> = [
        "configuration", "gitCommit",
    ]
    private static let frameBudget = 1_000.0 / 60.0

    @discardableResult
    public static func validateSliceThreeArtifacts(
        root: URL,
        expectedCommit: String
    ) throws -> [BenchmarkRecord] {
        let truths = truthTable
        let sceneDirectories = try directoryNames(at: root)
        guard sceneDirectories == Set(truths.keys) else {
            throw invalid(
                "Slice 3 positive directory set is not the exact six-scene truth table"
            )
        }

        var records: [BenchmarkRecord] = []
        var identity: (BenchmarkHardware, String)?
        for name in truths.keys.sorted() {
            let truth = truths[name]!
            let directory = root.appendingPathComponent(name)
            let benchmarkURL = directory.appendingPathComponent(
                "\(name).benchmark.json"
            )
            let expectedFiles = Set(
                ["stdout.log", "stderr.log", "\(name).benchmark.json"]
                    + truth.pngSizes.keys.map { "\(name).\($0)" }
            )
            let actualFiles = try directoryNames(at: directory)
            guard actualFiles == expectedFiles else {
                throw invalid("\(name): artifact file set does not match the truth table")
            }

            let stdoutURL = directory.appendingPathComponent("stdout.log")
            let stderrURL = directory.appendingPathComponent("stderr.log")
            try requireRegularFile(stdoutURL, allowsEmpty: false)
            try requireRegularFile(stderrURL, allowsEmpty: true)
            guard try Data(contentsOf: stderrURL).isEmpty else {
                throw invalid("\(name): positive stderr is not empty")
            }
            let primaryURL = directory.appendingPathComponent(
                "\(name).\(truth.primarySuffix)"
            )
            let expectedStdout = "HARNESS PASS scene=\(name) image=\(primaryURL.path) benchmark=\(benchmarkURL.path)\n"
            guard try Data(contentsOf: stdoutURL) == Data(expectedStdout.utf8) else {
                throw invalid("\(name): stdout is not the exact positive pass line")
            }

            let record = try validateRecord(
                at: benchmarkURL,
                name: name,
                truth: truth,
                expectedCommit: expectedCommit
            )
            if let identity,
               identity.0 != record.hardware
                || identity.1 != record.operatingSystem
            {
                throw invalid("\(name): Slice 3 benchmark provenance is mixed")
            }
            identity = identity ?? (record.hardware, record.operatingSystem)
            records.append(record)

            for (suffix, size) in truth.pngSizes {
                try validatePNG(
                    directory.appendingPathComponent("\(name).\(suffix)"),
                    expectedSize: size,
                    scene: name
                )
            }
        }
        return records
    }

    public static func validate(
        sliceTwoRoot: URL,
        sliceThreeRoot: URL,
        sliceOneRoot: URL,
        expectedCommit: String
    ) throws -> SliceThreeEvidenceValidationStatus {
        let sliceThree = try validateSliceThreeArtifacts(
            root: sliceThreeRoot,
            expectedCommit: expectedCommit
        )
        let sliceTwo = try validateSliceTwoPerformanceRecords(
            root: sliceTwoRoot,
            expectedCommit: expectedCommit
        )
        let fiveHundred = try validateFiveHundredDabRecord(
            root: sliceOneRoot,
            expectedCommit: expectedCommit
        )
        guard let reference = sliceTwo.first else {
            throw invalid("Slice 2 benchmark identity is unavailable")
        }
        for record in sliceTwo + sliceThree + [fiveHundred] {
            guard record.hardware == reference.hardware,
                  record.operatingSystem == reference.operatingSystem,
                  record.build.configuration == "Debug",
                  record.build.gitCommit == expectedCommit
            else {
                throw invalid(
                    "\(record.sceneName): benchmark hardware, OS, configuration, or commit provenance is mixed"
                )
            }
        }

        if reference.hardware.gpuName.lowercased().contains("paravirtual") {
            return .performancePending(gpuName: reference.hardware.gpuName)
        }

        try evaluateAbsoluteBudgets(
            records: sliceTwo + sliceThree,
            fiveHundred: fiveHundred
        )
        return .passed
    }

    private static func validateSliceTwoPerformanceRecords(
        root: URL,
        expectedCommit: String
    ) throws -> [BenchmarkRecord] {
        let truths = sliceTwoPerformanceTruthTable
        guard try directoryNames(at: root) == Set(truths.keys) else {
            throw invalid("Slice 2 performance record set is not the exact 26-scene truth table")
        }
        var records: [BenchmarkRecord] = []
        for name in truths.keys.sorted() {
            let truth = truths[name]!
            let record = try loadRecord(
                root.appendingPathComponent(name)
                    .appendingPathComponent("\(name).benchmark.json"),
                scene: name
            )
            guard record.schemaVersion == 3,
                  record.sceneName == name,
                  ISO8601DateFormatter().date(from: record.timestampUTC) != nil,
                  !record.hardware.gpuName.isEmpty,
                  record.hardware.logicalProcessorCount > 0,
                  record.hardware.physicalMemoryBytes > 0,
                  !record.operatingSystem.isEmpty,
                  record.build.configuration == "Debug",
                  record.build.gitCommit == expectedCommit,
                  record.peakResidentBytes > 0,
                  record.frameCount == truth.frameCount,
                  record.cpuEncodeMilliseconds.count == truth.cpuCount,
                  record.gpuMilliseconds.count == truth.gpuCount,
                  record.totalProjectedFragmentCount == truth.fragments,
                  record.maximumFragmentsPerFootprint == truth.maximumFragments,
                  record.totalInstanceBytes == truth.instanceBytes,
                  truth.instanceBytes == truth.fragments * 128
            else {
                throw invalid("\(name): Slice 2 identity, count, or 128-byte ABI truth does not match")
            }
            _ = try requireSeries(
                record.brushProcessingMilliseconds,
                field: "brushProcessingMilliseconds",
                expectedCount: truth.brushCount,
                scene: name
            )
            let events = try requireSeries(
                record.eventToSubmitMilliseconds,
                field: "eventToSubmitMilliseconds",
                expectedCount: truth.eventCount,
                scene: name
            )
            _ = try requireSeries(
                record.dabGPUMilliseconds,
                field: "dabGPUMilliseconds",
                expectedCount: truth.dabCount,
                scene: name
            )
            _ = try requireSeries(
                record.gridGPUMilliseconds,
                field: "gridGPUMilliseconds",
                expectedCount: truth.gridCount,
                scene: name
            )
            _ = try requireSeries(
                record.commitGPUMilliseconds,
                field: "commitGPUMilliseconds",
                expectedCount: truth.commitCount,
                scene: name
            )
            try validateCoreSeries(record, scene: name)
            try validateMissedFrames(record, events: events, scene: name)

            if name == "projected-long-stroke" {
                guard record.newInstanceCounts == [Int](repeating: 1, count: 401),
                      record.totalStrokeInstanceCounts == Array(1...401)
                else {
                    throw invalid("projected-long-stroke: projected instance identity is incomplete")
                }
                try validateStoredLongStrokeSummary(record)
            }
            records.append(record)
        }
        return records
    }

    private static func validateFiveHundredDabRecord(
        root: URL,
        expectedCommit: String
    ) throws -> BenchmarkRecord {
        let name = "five-hundred-dabs"
        let record = try loadRecord(
            root.appendingPathComponent(name)
                .appendingPathComponent("\(name).benchmark.json"),
            scene: name
        )
        guard record.schemaVersion == 2,
              record.sceneName == name,
              ISO8601DateFormatter().date(from: record.timestampUTC) != nil,
              !record.hardware.gpuName.isEmpty,
              record.hardware.logicalProcessorCount > 0,
              record.hardware.physicalMemoryBytes > 0,
              !record.operatingSystem.isEmpty,
              record.build.configuration == "Debug",
              record.build.gitCommit == expectedCommit,
              record.frameCount == 1,
              record.cpuEncodeMilliseconds.count == 2,
              record.gpuMilliseconds.count == 2,
              record.peakResidentBytes > 0,
              record.newInstanceCounts == [500],
              record.totalStrokeInstanceCounts == [500]
        else {
            throw invalid("five-hundred-dabs: identity or exact sample counts do not match")
        }
        _ = try requireSeries(
            record.brushProcessingMilliseconds,
            field: "brushProcessingMilliseconds",
            expectedCount: 1,
            scene: name
        )
        let events = try requireSeries(
            record.eventToSubmitMilliseconds,
            field: "eventToSubmitMilliseconds",
            expectedCount: 1,
            scene: name
        )
        _ = try requireSeries(
            record.dabGPUMilliseconds,
            field: "dabGPUMilliseconds",
            expectedCount: 1,
            scene: name
        )
        _ = try requireSeries(
            record.gridGPUMilliseconds,
            field: "gridGPUMilliseconds",
            expectedCount: 1,
            scene: name
        )
        _ = try requireSeries(
            record.commitGPUMilliseconds,
            field: "commitGPUMilliseconds",
            expectedCount: 0,
            scene: name
        )
        try validateCoreSeries(record, scene: name)
        try validateMissedFrames(record, events: events, scene: name)
        return record
    }

    private static func loadRecord(_ url: URL, scene: String) throws
        -> BenchmarkRecord
    {
        try requireRegularFile(url, allowsEmpty: false)
        do {
            return try BenchmarkRecord.decode(Data(contentsOf: url))
        } catch {
            throw invalid("\(scene): benchmark record cannot be decoded: \(error)")
        }
    }

    private static func requireSeries(
        _ values: [Double]?,
        field: String,
        expectedCount: Int,
        scene: String
    ) throws -> [Double] {
        guard let values else {
            throw invalid("\(scene): missing \(field)")
        }
        guard values.count == expectedCount else {
            throw invalid(
                "\(scene): \(field) has \(values.count) samples instead of \(expectedCount)"
            )
        }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw invalid("\(scene): \(field) contains a nonfinite or negative sample")
        }
        return values
    }

    private static func validateCoreSeries(
        _ record: BenchmarkRecord,
        scene: String
    ) throws {
        guard record.cpuEncodeMilliseconds.allSatisfy({ $0.isFinite && $0 >= 0 }),
              record.gpuMilliseconds.allSatisfy({ $0.isFinite && $0 >= 0 })
        else {
            throw invalid("\(scene): core timing contains a nonfinite or negative sample")
        }
    }

    private static func validateMissedFrames(
        _ record: BenchmarkRecord,
        events: [Double],
        scene: String
    ) throws {
        guard let budget = record.displayFrameBudgetMilliseconds,
              budget.isFinite,
              budget == frameBudget
        else { throw invalid("\(scene): missing or invalid displayFrameBudgetMilliseconds") }
        guard let missed = record.missedFrameCount else {
            throw invalid("\(scene): missing missedFrameCount")
        }
        let derived = events.filter { $0 > budget }.count
        guard missed == derived else {
            throw invalid("\(scene): missedFrameCount does not derive from event-to-submit samples")
        }
    }

    private static func validateStoredLongStrokeSummary(
        _ record: BenchmarkRecord
    ) throws {
        let events = Array(record.eventToSubmitMilliseconds!.dropFirst())
        let dab = Array(record.dabGPUMilliseconds!.dropFirst())
        guard events.count == BenchmarkLongStrokeMetrics.segmentCount,
              dab.count == BenchmarkLongStrokeMetrics.segmentCount,
              events.allSatisfy({ $0.isFinite && $0 > 0 }),
              dab.allSatisfy({ $0.isFinite && $0 > 0 })
        else {
            throw invalid("projected-long-stroke: raw summary evidence is incomplete")
        }
        let measured = (
            earlyCPU: BenchmarkRecord.percentile95(
                Array(events[BenchmarkLongStrokeMetrics.earlyWindow])
            ),
            lateCPU: BenchmarkRecord.percentile95(
                Array(events[BenchmarkLongStrokeMetrics.lateWindow])
            ),
            earlyDab: BenchmarkRecord.percentile95(
                Array(dab[BenchmarkLongStrokeMetrics.earlyWindow])
            ),
            lateDab: BenchmarkRecord.percentile95(
                Array(dab[BenchmarkLongStrokeMetrics.lateWindow])
            ),
            cpuSlope: BenchmarkLongStrokeMetrics.leastSquaresSlope(events),
            dabSlope: BenchmarkLongStrokeMetrics.leastSquaresSlope(dab)
        )
        let stored: [Double?] = [
            record.longStrokeEarlyCPUP95Milliseconds,
            record.longStrokeLateCPUP95Milliseconds,
            record.longStrokeEarlyDabGPUP95Milliseconds,
            record.longStrokeLateDabGPUP95Milliseconds,
            record.longStrokeCPUMillisecondsPerFrameSlope,
            record.longStrokeDabGPUMillisecondsPerFrameSlope,
        ]
        guard stored.allSatisfy({ $0?.isFinite == true }),
              close(stored[0]!, measured.earlyCPU),
              close(stored[1]!, measured.lateCPU),
              close(stored[2]!, measured.earlyDab),
              close(stored[3]!, measured.lateDab),
              close(stored[4]!, measured.cpuSlope),
              close(stored[5]!, measured.dabSlope)
        else {
            throw invalid("projected-long-stroke: stored summaries do not match raw evidence")
        }
    }

    private static func close(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= max(1, abs(lhs), abs(rhs)) * 1e-12
    }

    private static func evaluateAbsoluteBudgets(
        records: [BenchmarkRecord],
        fiveHundred: BenchmarkRecord
    ) throws {
        for record in records + [fiveHundred] {
            if let brush = record.brushProcessingMilliseconds, !brush.isEmpty,
               BenchmarkRecord.percentile95(brush) >= 2
            {
                throw invalid("\(record.sceneName): brush p95 is not below 2 ms")
            }
            if let grid = record.gridGPUMilliseconds, !grid.isEmpty,
               BenchmarkRecord.percentile95(grid) >= 2
            {
                throw invalid("\(record.sceneName): tiling p95 is not below 2 ms")
            }
            if record.frameCount > 0,
               Double(record.missedFrameCount!) / Double(record.frameCount) >= 0.01
            {
                throw invalid("\(record.sceneName): missed-frame fraction is not below 0.01")
            }
        }
        guard let maximumDab = fiveHundred.dabGPUMilliseconds?.max(),
              maximumDab > 0,
              maximumDab < 3
        else {
            throw invalid("five-hundred-dabs: GPU maximum is not below 3 ms")
        }
        guard let long = records.first(where: {
            $0.sceneName == "projected-long-stroke"
        }) else {
            throw invalid("projected-long-stroke: record is missing")
        }
        do {
            _ = try BenchmarkLongStrokeMetrics.measure(
                cpuMilliseconds: Array(
                    long.eventToSubmitMilliseconds!.dropFirst()
                ),
                dabGPUMilliseconds: Array(
                    long.dabGPUMilliseconds!.dropFirst()
                ),
                projectedInstanceCounts: Array(
                    long.newInstanceCounts!.dropFirst()
                )
            )
        } catch {
            throw invalid("projected-long-stroke: growth budget failed: \(error)")
        }
    }

    private static func validateRecord(
        at url: URL,
        name: String,
        truth: Truth,
        expectedCommit: String
    ) throws -> BenchmarkRecord {
        try requireRegularFile(url, allowsEmpty: false)
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { throw invalid("\(name): benchmark JSON is not an object") }
        try requireExactKeys(
            Set(object.keys),
            expected: schemaFourKeys,
            field: "benchmark",
            scene: name
        )
        guard let hardware = object["hardware"] as? [String: Any] else {
            throw invalid("\(name): hardware is not an object")
        }
        try requireExactKeys(
            Set(hardware.keys),
            expected: hardwareKeys,
            field: "hardware",
            scene: name
        )
        guard let build = object["build"] as? [String: Any] else {
            throw invalid("\(name): build is not an object")
        }
        try requireExactKeys(
            Set(build.keys),
            expected: buildKeys,
            field: "build",
            scene: name
        )
        let record: BenchmarkRecord
        do {
            record = try BenchmarkRecord.decode(data)
        } catch {
            throw invalid("\(name): benchmark JSON cannot be decoded strictly: \(error)")
        }

        guard record.schemaVersion == 4,
              record.sceneName == name,
              record.program == truth.program,
              ISO8601DateFormatter().date(from: record.timestampUTC) != nil,
              !record.hardware.gpuName.isEmpty,
              record.hardware.logicalProcessorCount > 0,
              record.hardware.physicalMemoryBytes > 0,
              !record.operatingSystem.isEmpty,
              record.build.configuration == "Debug",
              record.build.gitCommit == expectedCommit,
              record.peakResidentBytes > 0,
              record.frameCount == truth.frameCount,
              record.cpuEncodeMilliseconds.count == truth.frameCount,
              record.gpuMilliseconds.count == truth.frameCount,
              record.brushProcessingMilliseconds?.count == truth.brushCount,
              record.eventToSubmitMilliseconds?.count == truth.eventCount,
              record.dabGPUMilliseconds?.count == truth.dabCount,
              record.gridGPUMilliseconds?.count == truth.gridCount,
              record.commitGPUMilliseconds?.count == truth.commitCount,
              record.displayFrameBudgetMilliseconds == frameBudget,
              record.tilingRawValue == 0,
              record.tileWidth == truth.tileWidth,
              record.tileHeight == truth.tileHeight,
              record.totalProjectedFragmentCount == truth.fragments,
              record.maximumFragmentsPerFootprint == truth.maximumFragments,
              record.totalInstanceBytes == truth.instanceBytes,
              record.diagnosticMode == HarnessDiagnosticMode.hardRound.rawValue,
              record.revisionCaptureMilliseconds?.count == truth.captureCount,
              record.revisionRestoreMilliseconds?.count == truth.restoreCount,
              record.historyResidentBytes == truth.historyBytes,
              record.historyCommandCount == truth.historyCommands,
              record.historyCanUndo == true,
              record.historyCanRedo == false,
              record.historyAppendCount == truth.historyCommands,
              record.historyNavigationFinishCount
                == truth.historyNavigationFinishes,
              record.historyReleasedRevisionCount == 0,
              record.changedRegionCount == truth.changedRegions,
              record.coloredOutputMismatchCount == 0,
              record.previewCommitViolationCount == 0
        else {
            throw invalid("\(name): benchmark values do not match the truth table")
        }

        let series = [
            record.cpuEncodeMilliseconds,
            record.gpuMilliseconds,
            record.brushProcessingMilliseconds!,
            record.eventToSubmitMilliseconds!,
            record.dabGPUMilliseconds!,
            record.gridGPUMilliseconds!,
            record.commitGPUMilliseconds!,
            record.revisionCaptureMilliseconds!,
            record.revisionRestoreMilliseconds!,
        ]
        guard series.flatMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw invalid("\(name): benchmark timing contains a nonfinite or negative value")
        }
        let events = record.eventToSubmitMilliseconds!
        let derivedMisses = events.filter { $0 > frameBudget }.count
        guard record.missedFrameCount == derivedMisses else {
            throw invalid("\(name): missed frames do not derive from event-to-submit samples")
        }
        guard truth.instanceBytes == truth.fragments
                * MemoryLayout<PatternProjectedStampInstance>.stride,
              MemoryLayout<PatternProjectedStampInstance>.stride == 128
        else {
            throw invalid("\(name): projected fragments violate the approved 128-byte ABI")
        }
        return record
    }

    private static func validatePNG(
        _ url: URL,
        expectedSize: PixelSize,
        scene: String
    ) throws {
        try requireRegularFile(url, allowsEmpty: false)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == expectedSize.width,
              image.height == expectedSize.height
        else {
            throw invalid("\(scene): PNG is undecodable or has the wrong dimensions: \(url.lastPathComponent)")
        }
    }

    private static func requireRegularFile(
        _ url: URL,
        allowsEmpty: Bool
    ) throws {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              allowsEmpty || (values.fileSize ?? 0) > 0
        else {
            throw invalid("required regular artifact is missing or empty: \(url.path)")
        }
    }

    private static func directoryNames(at url: URL) throws -> Set<String> {
        Set(
            try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            ).map(\.lastPathComponent)
        )
    }

    private static func invalid(_ message: String)
        -> SliceThreeEvidenceValidationError
    {
        .invalid(message)
    }

    private static func requireExactKeys(
        _ actual: Set<String>,
        expected: Set<String>,
        field: String,
        scene: String
    ) throws {
        guard actual == expected else {
            let missing = expected.subtracting(actual).sorted().joined(separator: ",")
            let extra = actual.subtracting(expected).sorted().joined(separator: ",")
            throw invalid(
                "\(scene): \(field) keys are not exact; missing=[\(missing)] extra=[\(extra)]"
            )
        }
    }

    private static var truthTable: [String: Truth] {
        let square = PixelSize(width: 128, height: 128)
        let strokePNGs = [
            "live.screen.png": square,
            "committed.screen.png": square,
            "undone.canonical.png": square,
            "redone.canonical.png": square,
            "canonical.png": square,
        ]
        return [
            "colored-draw": Truth(
                program: "coloredDraw", tileWidth: 128, tileHeight: 128,
                frameCount: 4, brushCount: 2, eventCount: 1, dabCount: 1,
                gridCount: 2, commitCount: 1, captureCount: 1,
                restoreCount: 2, historyBytes: 4_224, historyCommands: 1,
                historyNavigationFinishes: 2,
                changedRegions: 1, fragments: 1, maximumFragments: 1,
                instanceBytes: 128, primarySuffix: "live.screen.png",
                pngSizes: strokePNGs
            ),
            "eraser-live-commit": Truth(
                program: "eraserLiveCommit", tileWidth: 128, tileHeight: 128,
                frameCount: 7, brushCount: 4, eventCount: 2, dabCount: 2,
                gridCount: 3, commitCount: 2, captureCount: 2,
                restoreCount: 2, historyBytes: 8_448, historyCommands: 2,
                historyNavigationFinishes: 2,
                changedRegions: 1, fragments: 1, maximumFragments: 1,
                instanceBytes: 128, primarySuffix: "live.screen.png",
                pngSizes: strokePNGs
            ),
            "region-undo-seam": Truth(
                program: "regionUndoSeam", tileWidth: 128, tileHeight: 128,
                frameCount: 4, brushCount: 2, eventCount: 1, dabCount: 1,
                gridCount: 2, commitCount: 1, captureCount: 1,
                restoreCount: 2, historyBytes: 1_792, historyCommands: 1,
                historyNavigationFinishes: 2,
                changedRegions: 2, fragments: 2, maximumFragments: 2,
                instanceBytes: 256, primarySuffix: "live.screen.png",
                pngSizes: strokePNGs
            ),
            "clear-undo": Truth(
                program: "clearUndo", tileWidth: 128, tileHeight: 128,
                frameCount: 4, brushCount: 2, eventCount: 1, dabCount: 1,
                gridCount: 2, commitCount: 1, captureCount: 2,
                restoreCount: 2, historyBytes: 135_296, historyCommands: 2,
                historyNavigationFinishes: 2,
                changedRegions: 1, fragments: 1, maximumFragments: 1,
                instanceBytes: 128, primarySuffix: "committed.screen.png",
                pngSizes: [
                    "committed.screen.png": square,
                    "before-clear.canonical.png": square,
                    "cleared.canonical.png": square,
                    "undone.canonical.png": square,
                    "redone.canonical.png": square,
                    "canonical.png": square,
                ]
            ),
            "tiling-undo": Truth(
                program: "tilingUndo", tileWidth: 128, tileHeight: 128,
                frameCount: 7, brushCount: 2, eventCount: 1, dabCount: 1,
                gridCount: 5, commitCount: 1, captureCount: 1,
                restoreCount: 0, historyBytes: 4_416, historyCommands: 2,
                historyNavigationFinishes: 2,
                changedRegions: 0, fragments: 1, maximumFragments: 1,
                instanceBytes: 128,
                primarySuffix: "initial-tiling.screen.png",
                pngSizes: [
                    "initial-tiling.screen.png": PixelSize(width: 256, height: 128),
                    "alternate-tiling.screen.png": PixelSize(width: 256, height: 128),
                    "restored-tiling.screen.png": PixelSize(width: 256, height: 128),
                    "redone-tiling.screen.png": PixelSize(width: 256, height: 128),
                    "canonical.png": square,
                ]
            ),
            "resize-crop-fill": Truth(
                program: "resizeCropFill", tileWidth: 96, tileHeight: 80,
                frameCount: 1, brushCount: 0, eventCount: 0, dabCount: 0,
                gridCount: 1, commitCount: 0, captureCount: 2,
                restoreCount: 4, historyBytes: 104_448, historyCommands: 2,
                historyNavigationFinishes: 4,
                changedRegions: 2, fragments: 0, maximumFragments: 0,
                instanceBytes: 0, primarySuffix: "committed.screen.png",
                pngSizes: [
                    "committed.screen.png": PixelSize(width: 192, height: 192),
                    "original.canonical.png": PixelSize(width: 96, height: 80),
                    "shrunk.canonical.png": PixelSize(width: 64, height: 72),
                    "grown.canonical.png": PixelSize(width: 96, height: 96),
                    "undone.canonical.png": PixelSize(width: 96, height: 80),
                    "redone.canonical.png": PixelSize(width: 96, height: 96),
                    "canonical.png": PixelSize(width: 96, height: 96),
                ]
            ),
        ]
    }

    private static var sliceTwoPerformanceTruthTable: [String: PerformanceTruth] {
        func truth(
            _ frame: Int,
            _ cpu: Int,
            _ gpu: Int,
            _ brush: Int,
            _ event: Int,
            _ dab: Int,
            _ grid: Int,
            _ commit: Int,
            _ fragments: Int,
            _ maximum: Int,
            _ bytes: Int
        ) -> PerformanceTruth {
            PerformanceTruth(
                frameCount: frame,
                cpuCount: cpu,
                gpuCount: gpu,
                brushCount: brush,
                eventCount: event,
                dabCount: dab,
                gridCount: grid,
                commitCount: commit,
                fragments: fragments,
                maximumFragments: maximum,
                instanceBytes: bytes
            )
        }
        return [
            "generalized-grid": truth(1, 4, 4, 0, 1, 1, 2, 1, 4, 4, 512),
            "halfdrop-interior": truth(1, 5, 5, 0, 1, 1, 3, 1, 1, 1, 128),
            "halfdrop-edge": truth(1, 5, 5, 0, 1, 1, 3, 1, 3, 3, 384),
            "halfdrop-corner": truth(1, 5, 5, 0, 1, 1, 3, 1, 3, 3, 384),
            "brick-transpose": truth(1, 5, 5, 0, 1, 1, 3, 1, 3, 3, 384),
            "mirror-x": truth(1, 1, 1, 0, 0, 1, 0, 0, 2, 2, 256),
            "mirror-y": truth(1, 1, 1, 0, 0, 1, 0, 0, 2, 2, 256),
            "mirror-xy": truth(1, 1, 1, 0, 0, 1, 0, 0, 4, 4, 512),
            "rotational-generator": truth(1, 1, 1, 0, 0, 1, 0, 0, 2, 2, 256),
            "rotational-fixed-point": truth(1, 4, 4, 0, 1, 1, 2, 1, 1, 1, 128),
            "rotational-orientation": truth(1, 1, 1, 0, 0, 1, 0, 0, 2, 2, 256),
            "large-footprint": truth(1, 4, 4, 0, 1, 1, 2, 1, 48, 48, 6_144),
            "asymmetric-footprint": truth(1, 1, 1, 0, 0, 1, 0, 0, 4, 4, 512),
            "canonical-coordinate-continuity": truth(1, 1, 1, 0, 0, 1, 0, 0, 3, 3, 384),
            "brush-local-coordinate-continuity": truth(1, 1, 1, 0, 0, 1, 0, 0, 4, 4, 512),
            "rectangular-tile": truth(1, 4, 4, 0, 1, 1, 2, 1, 4, 4, 512),
            "noncentral-visible-cell-grid": truth(1, 3, 3, 0, 1, 1, 1, 1, 2, 1, 256),
            "noncentral-visible-cell-halfdrop": truth(1, 3, 3, 0, 1, 1, 1, 1, 2, 1, 256),
            "noncentral-visible-cell-brick": truth(1, 3, 3, 0, 1, 1, 1, 1, 2, 1, 256),
            "noncentral-visible-cell-mirror-x": truth(1, 3, 3, 0, 1, 1, 1, 1, 2, 1, 256),
            "noncentral-visible-cell-mirror-y": truth(1, 3, 3, 0, 1, 1, 1, 1, 2, 1, 256),
            "noncentral-visible-cell-mirror-xy": truth(1, 3, 3, 0, 1, 1, 1, 1, 2, 1, 256),
            "noncentral-visible-cell-rotational": truth(1, 3, 3, 0, 1, 1, 1, 1, 4, 2, 512),
            "metadata-tiling-switch": truth(1, 5, 5, 0, 1, 1, 3, 1, 1, 1, 128),
            "projected-live-commit": truth(1, 4, 4, 2, 1, 1, 2, 1, 33, 3, 4_224),
            "projected-long-stroke": truth(401, 404, 404, 401, 401, 401, 2, 1, 401, 1, 51_328),
        ]
    }
}
