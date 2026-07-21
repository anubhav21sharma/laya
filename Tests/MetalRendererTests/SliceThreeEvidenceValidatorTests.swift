import Foundation
@testable import MetalRenderer
import PatternEngine
import Testing

private struct SliceThreeArtifactFixtureTruth {
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

enum SliceThreeArtifactCorruption: CaseIterable {
    case stdout
    case schema
    case program
    case scene
    case historyBytes
    case historyCommands
    case historyCanUndo
    case historyCanRedo
    case historyAppendCount
    case historyNavigationFinishCount
    case historyReleasedRevisionCount
    case changedRegions
    case coloredOutputMismatchCount
    case previewCommitViolationCount
    case fragments
    case maximumFragments
    case instanceBytes
    case missingRecordField
    case unknownRecordField
    case frameSampleCount
    case corruptPNG
    case missingPNG
    case extraPNG
    case wrongPNGDimensions

}

enum SliceThreePerformanceCorruption: CaseIterable {
    case missingBrushSeries
    case missingTilingSeries
    case missingCommitSeries
    case missingEventSeries
    case missingMissedFrames
    case incompleteEventSamples
    case mismatchedSliceOneHardware
    case mismatchedOperatingSystem
    case invalidLongStrokeIdentity
}

@Test
func sliceThreeArtifactTruthTableAcceptsCompleteFixture() throws {
    let fixture = try makeSliceThreeArtifactFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }

    try SliceThreeEvidenceValidator.validateSliceThreeArtifacts(
        root: fixture,
        expectedCommit: "fixture-commit"
    )
}

@Test(arguments: SliceThreeArtifactCorruption.allCases)
func sliceThreeArtifactTruthTableRejectsCorruptedFixture(
    _ corruption: SliceThreeArtifactCorruption
) throws {
    let fixture = try makeSliceThreeArtifactFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    try corruptSliceThreeArtifactFixture(fixture, corruption: corruption)

    #expect(throws: SliceThreeEvidenceValidationError.self) {
        try SliceThreeEvidenceValidator.validateSliceThreeArtifacts(
            root: fixture,
            expectedCommit: "fixture-commit"
        )
    }
}

@Test
func stablePerformanceTruthTableAcceptsCompleteFixture() throws {
    let fixture = try makeCompletePerformanceFixture()
    defer { fixture.remove() }

    #expect(
        try SliceThreeEvidenceValidator.validate(
            sliceTwoRoot: fixture.sliceTwo,
            sliceThreeRoot: fixture.sliceThree,
            sliceOneRoot: fixture.sliceOne,
            expectedCommit: "fixture-commit"
        ) == .passed
    )
}

@Test(arguments: SliceThreePerformanceCorruption.allCases)
func stablePerformanceTruthTableRejectsIncompleteOrMixedFixture(
    _ corruption: SliceThreePerformanceCorruption
) throws {
    let fixture = try makeCompletePerformanceFixture()
    defer { fixture.remove() }
    try corruptPerformanceFixture(fixture, corruption: corruption)

    #expect(throws: SliceThreeEvidenceValidationError.self) {
        try SliceThreeEvidenceValidator.validate(
            sliceTwoRoot: fixture.sliceTwo,
            sliceThreeRoot: fixture.sliceThree,
            sliceOneRoot: fixture.sliceOne,
            expectedCommit: "fixture-commit"
        )
    }
}

@Test
func performanceCompletenessFailsBeforeAnyAbsoluteBudgetIsEvaluated() throws {
    let fixture = try makeCompletePerformanceFixture()
    defer { fixture.remove() }
    try mutateRecord(
        fixture.sliceThree
            .appendingPathComponent("colored-draw/colored-draw.benchmark.json")
    ) {
        $0.removeValue(forKey: "commitGPUMilliseconds")
        $0["brushProcessingMilliseconds"] = [3.0, 3.0]
    }

    do {
        _ = try SliceThreeEvidenceValidator.validate(
            sliceTwoRoot: fixture.sliceTwo,
            sliceThreeRoot: fixture.sliceThree,
            sliceOneRoot: fixture.sliceOne,
            expectedCommit: "fixture-commit"
        )
        Issue.record("incomplete evidence was accepted")
    } catch let error as SliceThreeEvidenceValidationError {
        #expect(error.localizedDescription.contains("commitGPUMilliseconds"))
    }
}

@Test
func paravirtualEvidenceIsValidatedBeforeReturningPending() throws {
    let fixture = try makeCompletePerformanceFixture(gpuName: "Apple Paravirtual device")
    defer { fixture.remove() }
    #expect(
        try SliceThreeEvidenceValidator.validate(
            sliceTwoRoot: fixture.sliceTwo,
            sliceThreeRoot: fixture.sliceThree,
            sliceOneRoot: fixture.sliceOne,
            expectedCommit: "fixture-commit"
        ) == .performancePending(gpuName: "Apple Paravirtual device")
    )

    try mutateRecord(
        fixture.sliceThree
            .appendingPathComponent("colored-draw/colored-draw.benchmark.json")
    ) { $0.removeValue(forKey: "eventToSubmitMilliseconds") }
    #expect(throws: SliceThreeEvidenceValidationError.self) {
        try SliceThreeEvidenceValidator.validate(
            sliceTwoRoot: fixture.sliceTwo,
            sliceThreeRoot: fixture.sliceThree,
            sliceOneRoot: fixture.sliceOne,
            expectedCommit: "fixture-commit"
        )
    }
}

private func makeSliceThreeArtifactFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    for (name, truth) in sliceThreeArtifactFixtureTruths() {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let benchmark = directory.appendingPathComponent(
            "\(name).benchmark.json"
        )
        let record: [String: Any] = [
            "schemaVersion": 4,
            "timestampUTC": "2026-07-21T00:00:00Z",
            "sceneName": name,
            "program": truth.program,
            "hardware": [
                "gpuName": "Fixture GPU",
                "logicalProcessorCount": 8,
                "physicalMemoryBytes": 8_589_934_592,
            ],
            "operatingSystem": "Fixture OS",
            "build": [
                "configuration": "Debug",
                "gitCommit": "fixture-commit",
            ],
            "frameCount": truth.frameCount,
            "cpuEncodeMilliseconds": fixtureSeries(truth.frameCount),
            "gpuMilliseconds": fixtureSeries(truth.frameCount),
            "peakResidentBytes": 1_000_000,
            "brushProcessingMilliseconds": fixtureSeries(truth.brushCount),
            "eventToSubmitMilliseconds": fixtureSeries(truth.eventCount),
            "dabGPUMilliseconds": fixtureSeries(truth.dabCount),
            "gridGPUMilliseconds": fixtureSeries(truth.gridCount),
            "commitGPUMilliseconds": fixtureSeries(truth.commitCount),
            "displayFrameBudgetMilliseconds": 1_000.0 / 60.0,
            "missedFrameCount": 0,
            "tilingRawValue": 0,
            "tileWidth": truth.tileWidth,
            "tileHeight": truth.tileHeight,
            "totalProjectedFragmentCount": truth.fragments,
            "maximumFragmentsPerFootprint": truth.maximumFragments,
            "totalInstanceBytes": truth.instanceBytes,
            "diagnosticMode": "hardRound",
            "revisionCaptureMilliseconds": fixtureSeries(truth.captureCount),
            "revisionRestoreMilliseconds": fixtureSeries(truth.restoreCount),
            "historyResidentBytes": truth.historyBytes,
            "historyCommandCount": truth.historyCommands,
            "historyCanUndo": true,
            "historyCanRedo": false,
            "historyAppendCount": truth.historyCommands,
            "historyNavigationFinishCount": truth.historyNavigationFinishes,
            "historyReleasedRevisionCount": 0,
            "changedRegionCount": truth.changedRegions,
            "coloredOutputMismatchCount": 0,
            "previewCommitViolationCount": 0,
        ]
        try JSONSerialization.data(
            withJSONObject: record,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: benchmark)

        for (suffix, size) in truth.pngSizes {
            try writeFixturePNG(
                to: directory.appendingPathComponent("\(name).\(suffix)"),
                size: size
            )
        }
        let primary = directory.appendingPathComponent(
            "\(name).\(truth.primarySuffix)"
        )
        let stdout = "HARNESS PASS scene=\(name) image=\(primary.path) benchmark=\(benchmark.path)\n"
        try Data(stdout.utf8).write(
            to: directory.appendingPathComponent("stdout.log")
        )
        try Data().write(to: directory.appendingPathComponent("stderr.log"))
    }
    return root
}

private func corruptSliceThreeArtifactFixture(
    _ root: URL,
    corruption: SliceThreeArtifactCorruption
) throws {
    let name = "colored-draw"
    let directory = root.appendingPathComponent(name)
    let recordURL = directory.appendingPathComponent("\(name).benchmark.json")
    let stdoutURL = directory.appendingPathComponent("stdout.log")
    let pngURL = directory.appendingPathComponent("\(name).canonical.png")

    switch corruption {
    case .stdout:
        try Data("HARNESS PASS scene=wrong\n".utf8).write(to: stdoutURL)
    case .corruptPNG:
        try Data("not a png".utf8).write(to: pngURL)
    case .missingPNG:
        try FileManager.default.removeItem(at: pngURL)
    case .extraPNG:
        try writeFixturePNG(
            to: directory.appendingPathComponent("\(name).extra.png"),
            size: PixelSize(width: 1, height: 1)
        )
    case .wrongPNGDimensions:
        try writeFixturePNG(
            to: pngURL,
            size: PixelSize(width: 1, height: 1)
        )
    default:
        var record = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: recordURL)
            ) as? [String: Any]
        )
        switch corruption {
        case .schema:
            record["schemaVersion"] = 3
        case .program:
            record["program"] = "eraserLiveCommit"
        case .scene:
            record["sceneName"] = "wrong"
        case .historyBytes:
            record["historyResidentBytes"] = 4_225
        case .historyCommands:
            record["historyCommandCount"] = 2
        case .historyCanUndo:
            record["historyCanUndo"] = false
        case .historyCanRedo:
            record["historyCanRedo"] = true
        case .historyAppendCount:
            record["historyAppendCount"] = 2
        case .historyNavigationFinishCount:
            record["historyNavigationFinishCount"] = 1
        case .historyReleasedRevisionCount:
            record["historyReleasedRevisionCount"] = 1
        case .changedRegions:
            record["changedRegionCount"] = 2
        case .coloredOutputMismatchCount:
            record["coloredOutputMismatchCount"] = 1
        case .previewCommitViolationCount:
            record["previewCommitViolationCount"] = 1
        case .fragments:
            record["totalProjectedFragmentCount"] = 2
        case .maximumFragments:
            record["maximumFragmentsPerFootprint"] = 2
        case .instanceBytes:
            record["totalInstanceBytes"] = 113
        case .missingRecordField:
            record.removeValue(forKey: "revisionRestoreMilliseconds")
        case .unknownRecordField:
            record["unexpected"] = 1
        case .frameSampleCount:
            record["cpuEncodeMilliseconds"] = [1.0]
        case .stdout, .corruptPNG, .missingPNG, .extraPNG,
             .wrongPNGDimensions:
            Issue.record("handled before record mutation")
        }
        try JSONSerialization.data(
            withJSONObject: record,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: recordURL)
    }
}

private func sliceThreeArtifactFixtureTruths()
    -> [String: SliceThreeArtifactFixtureTruth]
{
    let square = PixelSize(width: 128, height: 128)
    let strokePNGs = [
        "live.screen.png": square,
        "committed.screen.png": square,
        "undone.canonical.png": square,
        "redone.canonical.png": square,
        "canonical.png": square,
    ]
    return [
        "colored-draw": SliceThreeArtifactFixtureTruth(
            program: "coloredDraw", tileWidth: 128, tileHeight: 128,
            frameCount: 4, brushCount: 2, eventCount: 1, dabCount: 1,
            gridCount: 2, commitCount: 1, captureCount: 1, restoreCount: 2,
            historyBytes: 4_224, historyCommands: 1,
            historyNavigationFinishes: 2, changedRegions: 1,
            fragments: 1, maximumFragments: 1, instanceBytes: 112,
            primarySuffix: "live.screen.png", pngSizes: strokePNGs
        ),
        "eraser-live-commit": SliceThreeArtifactFixtureTruth(
            program: "eraserLiveCommit", tileWidth: 128, tileHeight: 128,
            frameCount: 7, brushCount: 4, eventCount: 2, dabCount: 2,
            gridCount: 3, commitCount: 2, captureCount: 2, restoreCount: 2,
            historyBytes: 8_448, historyCommands: 2,
            historyNavigationFinishes: 2, changedRegions: 1,
            fragments: 1, maximumFragments: 1, instanceBytes: 112,
            primarySuffix: "live.screen.png", pngSizes: strokePNGs
        ),
        "region-undo-seam": SliceThreeArtifactFixtureTruth(
            program: "regionUndoSeam", tileWidth: 128, tileHeight: 128,
            frameCount: 4, brushCount: 2, eventCount: 1, dabCount: 1,
            gridCount: 2, commitCount: 1, captureCount: 1, restoreCount: 2,
            historyBytes: 1_792, historyCommands: 1,
            historyNavigationFinishes: 2, changedRegions: 2,
            fragments: 2, maximumFragments: 2, instanceBytes: 224,
            primarySuffix: "live.screen.png", pngSizes: strokePNGs
        ),
        "clear-undo": SliceThreeArtifactFixtureTruth(
            program: "clearUndo", tileWidth: 128, tileHeight: 128,
            frameCount: 4, brushCount: 2, eventCount: 1, dabCount: 1,
            gridCount: 2, commitCount: 1, captureCount: 2, restoreCount: 2,
            historyBytes: 135_296, historyCommands: 2,
            historyNavigationFinishes: 2, changedRegions: 1,
            fragments: 1, maximumFragments: 1, instanceBytes: 112,
            primarySuffix: "committed.screen.png",
            pngSizes: [
                "committed.screen.png": square,
                "before-clear.canonical.png": square,
                "cleared.canonical.png": square,
                "undone.canonical.png": square,
                "redone.canonical.png": square,
                "canonical.png": square,
            ]
        ),
        "tiling-undo": SliceThreeArtifactFixtureTruth(
            program: "tilingUndo", tileWidth: 128, tileHeight: 128,
            frameCount: 7, brushCount: 2, eventCount: 1, dabCount: 1,
            gridCount: 5, commitCount: 1, captureCount: 1, restoreCount: 0,
            historyBytes: 4_416, historyCommands: 2,
            historyNavigationFinishes: 2, changedRegions: 0,
            fragments: 1, maximumFragments: 1, instanceBytes: 112,
            primarySuffix: "initial-tiling.screen.png",
            pngSizes: [
                "initial-tiling.screen.png": PixelSize(width: 256, height: 128),
                "alternate-tiling.screen.png": PixelSize(width: 256, height: 128),
                "restored-tiling.screen.png": PixelSize(width: 256, height: 128),
                "redone-tiling.screen.png": PixelSize(width: 256, height: 128),
                "canonical.png": square,
            ]
        ),
        "resize-crop-fill": SliceThreeArtifactFixtureTruth(
            program: "resizeCropFill", tileWidth: 96, tileHeight: 80,
            frameCount: 1, brushCount: 0, eventCount: 0, dabCount: 0,
            gridCount: 1, commitCount: 0, captureCount: 2, restoreCount: 4,
            historyBytes: 104_448, historyCommands: 2,
            historyNavigationFinishes: 4, changedRegions: 2,
            fragments: 0, maximumFragments: 0, instanceBytes: 0,
            primarySuffix: "committed.screen.png",
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

private func fixtureSeries(_ count: Int) -> [Double] {
    [Double](repeating: 1, count: count)
}

private func writeFixturePNG(to url: URL, size: PixelSize) throws {
    try PNGWriter.writeBGRA(
        [UInt8](repeating: 0, count: size.width * size.height * 4),
        pixelSize: size,
        to: url
    )
}

private struct CompletePerformanceFixture {
    let sliceTwo: URL
    let sliceThree: URL
    let sliceOne: URL

    func remove() {
        try? FileManager.default.removeItem(at: sliceTwo)
        try? FileManager.default.removeItem(at: sliceThree)
        try? FileManager.default.removeItem(at: sliceOne)
    }
}

private struct SliceTwoPerformanceTruth {
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

private func makeCompletePerformanceFixture(
    gpuName: String = "Stable Fixture GPU"
) throws -> CompletePerformanceFixture {
    let sliceThree = try makeSliceThreeArtifactFixture()
    let sliceTwo = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let sliceOne = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: sliceTwo,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: sliceOne.appendingPathComponent("five-hundred-dabs"),
        withIntermediateDirectories: true
    )

    for name in sliceThreeArtifactFixtureTruths().keys {
        let url = sliceThree
            .appendingPathComponent(name)
            .appendingPathComponent("\(name).benchmark.json")
        try mutateRecord(url) {
            $0["hardware"] = fixtureHardware(gpuName: gpuName)
        }
    }

    for (name, truth) in sliceTwoPerformanceTruths() {
        let directory = sliceTwo.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var record = fixtureCoreRecord(
            schemaVersion: 3,
            sceneName: name,
            gpuName: gpuName,
            frameCount: truth.frameCount,
            cpuCount: truth.cpuCount,
            gpuCount: truth.gpuCount
        )
        record["brushProcessingMilliseconds"] = fixtureSeries(truth.brushCount)
        record["eventToSubmitMilliseconds"] = fixtureSeries(truth.eventCount)
        record["dabGPUMilliseconds"] = fixtureSeries(truth.dabCount)
        record["gridGPUMilliseconds"] = fixtureSeries(truth.gridCount)
        record["commitGPUMilliseconds"] = fixtureSeries(truth.commitCount)
        record["displayFrameBudgetMilliseconds"] = 1_000.0 / 60.0
        record["missedFrameCount"] = 0
        record["tilingRawValue"] = 0
        record["tileWidth"] = 128
        record["tileHeight"] = 128
        record["totalProjectedFragmentCount"] = truth.fragments
        record["maximumFragmentsPerFootprint"] = truth.maximumFragments
        record["totalInstanceBytes"] = truth.instanceBytes
        record["diagnosticMode"] = "hardRound"
        if name == "projected-long-stroke" {
            record["newInstanceCounts"] = [Int](repeating: 1, count: 401)
            record["totalStrokeInstanceCounts"] = Array(1...401)
            record["longStrokeEarlyCPUP95Milliseconds"] = 1.0
            record["longStrokeLateCPUP95Milliseconds"] = 1.0
            record["longStrokeEarlyDabGPUP95Milliseconds"] = 1.0
            record["longStrokeLateDabGPUP95Milliseconds"] = 1.0
            record["longStrokeCPUMillisecondsPerFrameSlope"] = 0.0
            record["longStrokeDabGPUMillisecondsPerFrameSlope"] = 0.0
        }
        try writeRecord(
            record,
            to: directory.appendingPathComponent("\(name).benchmark.json")
        )
    }

    var fiveHundred = fixtureCoreRecord(
        schemaVersion: 2,
        sceneName: "five-hundred-dabs",
        gpuName: gpuName,
        frameCount: 1,
        cpuCount: 2,
        gpuCount: 2
    )
    fiveHundred["brushProcessingMilliseconds"] = [1.0]
    fiveHundred["eventToSubmitMilliseconds"] = [1.0]
    fiveHundred["dabGPUMilliseconds"] = [1.0]
    fiveHundred["gridGPUMilliseconds"] = [1.0]
    fiveHundred["commitGPUMilliseconds"] = []
    fiveHundred["displayFrameBudgetMilliseconds"] = 1_000.0 / 60.0
    fiveHundred["missedFrameCount"] = 0
    fiveHundred["newInstanceCounts"] = [500]
    fiveHundred["totalStrokeInstanceCounts"] = [500]
    try writeRecord(
        fiveHundred,
        to: sliceOne
            .appendingPathComponent("five-hundred-dabs")
            .appendingPathComponent("five-hundred-dabs.benchmark.json")
    )
    return CompletePerformanceFixture(
        sliceTwo: sliceTwo,
        sliceThree: sliceThree,
        sliceOne: sliceOne
    )
}

private func corruptPerformanceFixture(
    _ fixture: CompletePerformanceFixture,
    corruption: SliceThreePerformanceCorruption
) throws {
    let colored = fixture.sliceThree
        .appendingPathComponent("colored-draw/colored-draw.benchmark.json")
    let tiling = fixture.sliceThree
        .appendingPathComponent("tiling-undo/tiling-undo.benchmark.json")
    let long = fixture.sliceTwo
        .appendingPathComponent("projected-long-stroke/projected-long-stroke.benchmark.json")
    let fiveHundred = fixture.sliceOne
        .appendingPathComponent("five-hundred-dabs/five-hundred-dabs.benchmark.json")
    switch corruption {
    case .missingBrushSeries:
        try mutateRecord(colored) { $0.removeValue(forKey: "brushProcessingMilliseconds") }
    case .missingTilingSeries:
        try mutateRecord(tiling) { $0.removeValue(forKey: "gridGPUMilliseconds") }
    case .missingCommitSeries:
        try mutateRecord(colored) { $0.removeValue(forKey: "commitGPUMilliseconds") }
    case .missingEventSeries:
        try mutateRecord(colored) { $0.removeValue(forKey: "eventToSubmitMilliseconds") }
    case .missingMissedFrames:
        try mutateRecord(colored) { $0.removeValue(forKey: "missedFrameCount") }
    case .incompleteEventSamples:
        try mutateRecord(colored) { $0["eventToSubmitMilliseconds"] = [] }
    case .mismatchedSliceOneHardware:
        try mutateRecord(fiveHundred) {
            $0["hardware"] = fixtureHardware(gpuName: "Different GPU")
        }
    case .mismatchedOperatingSystem:
        try mutateRecord(fiveHundred) { $0["operatingSystem"] = "Different OS" }
    case .invalidLongStrokeIdentity:
        try mutateRecord(long) {
            var values = [Int](repeating: 1, count: 401)
            values[400] = 2
            $0["newInstanceCounts"] = values
        }
    }
}

private func fixtureCoreRecord(
    schemaVersion: Int,
    sceneName: String,
    gpuName: String,
    frameCount: Int,
    cpuCount: Int,
    gpuCount: Int
) -> [String: Any] {
    [
        "schemaVersion": schemaVersion,
        "timestampUTC": "2026-07-21T00:00:00Z",
        "sceneName": sceneName,
        "hardware": fixtureHardware(gpuName: gpuName),
        "operatingSystem": "Fixture OS",
        "build": [
            "configuration": "Debug",
            "gitCommit": "fixture-commit",
        ],
        "frameCount": frameCount,
        "cpuEncodeMilliseconds": fixtureSeries(cpuCount),
        "gpuMilliseconds": fixtureSeries(gpuCount),
        "peakResidentBytes": 1_000_000,
    ]
}

private func fixtureHardware(gpuName: String) -> [String: Any] {
    [
        "gpuName": gpuName,
        "logicalProcessorCount": 8,
        "physicalMemoryBytes": 8_589_934_592,
    ]
}

private func mutateRecord(
    _ url: URL,
    mutation: (inout [String: Any]) -> Void
) throws {
    var record = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url))
            as? [String: Any]
    )
    mutation(&record)
    try writeRecord(record, to: url)
}

private func writeRecord(_ record: [String: Any], to url: URL) throws {
    try JSONSerialization.data(
        withJSONObject: record,
        options: [.prettyPrinted, .sortedKeys]
    ).write(to: url)
}

private func sliceTwoPerformanceTruths() -> [String: SliceTwoPerformanceTruth] {
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
    ) -> SliceTwoPerformanceTruth {
        SliceTwoPerformanceTruth(
            frameCount: frame, cpuCount: cpu, gpuCount: gpu,
            brushCount: brush, eventCount: event, dabCount: dab,
            gridCount: grid, commitCount: commit, fragments: fragments,
            maximumFragments: maximum, instanceBytes: bytes
        )
    }
    return [
        "generalized-grid": truth(1, 4, 4, 0, 1, 1, 2, 1, 4, 4, 448),
        "halfdrop-interior": truth(1, 5, 5, 0, 1, 1, 3, 1, 1, 1, 112),
        "halfdrop-edge": truth(1, 5, 5, 0, 1, 1, 3, 1, 3, 3, 336),
        "halfdrop-corner": truth(1, 5, 5, 0, 1, 1, 3, 1, 3, 3, 336),
        "brick-transpose": truth(1, 5, 5, 0, 1, 1, 3, 1, 3, 3, 336),
        "mirror-x": truth(1, 1, 1, 0, 0, 1, 0, 0, 2, 2, 224),
        "mirror-y": truth(1, 1, 1, 0, 0, 1, 0, 0, 2, 2, 224),
        "mirror-xy": truth(1, 1, 1, 0, 0, 1, 0, 0, 4, 4, 448),
        "rotational-generator": truth(1, 1, 1, 0, 0, 1, 0, 0, 2, 2, 224),
        "rotational-fixed-point": truth(1, 4, 4, 0, 1, 1, 2, 1, 1, 1, 112),
        "rotational-orientation": truth(1, 1, 1, 0, 0, 1, 0, 0, 2, 2, 224),
        "large-footprint": truth(1, 4, 4, 0, 1, 1, 2, 1, 48, 48, 5_376),
        "asymmetric-footprint": truth(1, 1, 1, 0, 0, 1, 0, 0, 4, 4, 448),
        "canonical-coordinate-continuity": truth(1, 1, 1, 0, 0, 1, 0, 0, 3, 3, 336),
        "brush-local-coordinate-continuity": truth(1, 1, 1, 0, 0, 1, 0, 0, 4, 4, 448),
        "rectangular-tile": truth(1, 4, 4, 0, 1, 1, 2, 1, 4, 4, 448),
        "noncentral-visible-cell-grid": truth(1, 3, 3, 0, 1, 1, 1, 1, 2, 1, 224),
        "noncentral-visible-cell-halfdrop": truth(1, 3, 3, 0, 1, 1, 1, 1, 2, 1, 224),
        "noncentral-visible-cell-brick": truth(1, 3, 3, 0, 1, 1, 1, 1, 2, 1, 224),
        "noncentral-visible-cell-mirror-x": truth(1, 3, 3, 0, 1, 1, 1, 1, 2, 1, 224),
        "noncentral-visible-cell-mirror-y": truth(1, 3, 3, 0, 1, 1, 1, 1, 2, 1, 224),
        "noncentral-visible-cell-mirror-xy": truth(1, 3, 3, 0, 1, 1, 1, 1, 2, 1, 224),
        "noncentral-visible-cell-rotational": truth(1, 3, 3, 0, 1, 1, 1, 1, 4, 2, 448),
        "metadata-tiling-switch": truth(1, 5, 5, 0, 1, 1, 3, 1, 1, 1, 112),
        "projected-live-commit": truth(1, 4, 4, 2, 1, 1, 2, 1, 33, 3, 3_696),
        "projected-long-stroke": truth(401, 404, 404, 401, 401, 401, 2, 1, 401, 1, 44_912),
    ]
}
