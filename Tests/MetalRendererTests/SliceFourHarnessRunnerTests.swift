import Foundation
import Metal
import EditorCore
@testable import MetalRenderer
import PatternEngine
import Testing

@Test
@MainActor
func sliceFourRealRunnerProducesMeasuredPNGsAndRejectsEveryNegativeControl()
    throws
{
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let library = try makeSliceFourTestLibrary(device: device)
    let root = sliceFourSceneRoot()
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(
        "slice4-real-runner-\(UUID().uuidString)"
    )
    let positiveRoot = output.appendingPathComponent("positive")
    let negativeRoot = output.appendingPathComponent("negative")
    defer { try? FileManager.default.removeItem(at: output) }
    let build = BenchmarkBuild(
        configuration: "Debug",
        gitCommit: "slice4-test-commit"
    )

    for name in SliceFourEvidenceValidator.sceneNames {
        let runner = makeSliceFourRunner(device: device, library: library)
        let positive = try HarnessScene.decode(Data(contentsOf:
            root.appendingPathComponent("\(name).json")
        ))
        let negative = try HarnessScene.decode(Data(contentsOf:
            root.appendingPathComponent("\(name)-negative-control.json")
        ))
        let directory = positiveRoot.appendingPathComponent(name)
        let result = try runner.run(
            scene: positive,
            outputDirectory: directory,
            build: build
        )
        #expect(result.artifactURLs.filter { $0.pathExtension == "png" }.count == 3)
        let evidence = try JSONDecoder().decode(
            SliceFourMeasuredEvidence.self,
            from: Data(contentsOf: directory.appendingPathComponent(
                "\(name).slice4-evidence.json"
            ))
        )
        #expect(evidence.rendererBacked)
        try SliceFourHarnessRunner.evaluateStructuralChecks(
            scene: positive,
            values: evidence.structuralValues
        )
        #expect(throws: SliceFourHarnessRunError.self) {
            try SliceFourHarnessRunner.evaluateStructuralChecks(
                scene: negative,
                values: evidence.structuralValues
            )
        }
        let stdout = "HARNESS PASS scene=\(name) image=\(directory.appendingPathComponent("\(name).live.png").path) benchmark=\(directory.appendingPathComponent("\(name).benchmark.json").path)\n"
        try Data(stdout.utf8).write(
            to: directory.appendingPathComponent("stdout.log")
        )
        try Data().write(to: directory.appendingPathComponent("stderr.log"))
        let negativeDirectory = negativeRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: negativeDirectory,
            withIntermediateDirectories: true
        )
        let negativeWork = output.appendingPathComponent("negative-work/\(name)")
        let negativeRunner = makeSliceFourRunner(device: device, library: library)
        let negativeError: Error
        do {
            _ = try negativeRunner.run(
                scene: negative,
                outputDirectory: negativeWork,
                build: build
            )
            Issue.record("Negative scene unexpectedly passed: \(name)")
            continue
        } catch {
            negativeError = error
        }
        try Data().write(to: negativeDirectory.appendingPathComponent("stdout.log"))
        try Data("HARNESS FAIL \(negativeError.localizedDescription)\n".utf8).write(
            to: negativeDirectory.appendingPathComponent("stderr.log")
        )
        try Data("1\n".utf8).write(
            to: negativeDirectory.appendingPathComponent("exit-status.txt")
        )
    }

    let validation = try SliceFourEvidenceValidator.validate(
        positiveRoot: positiveRoot,
        negativeRoot: negativeRoot,
        sceneRoot: root,
        expectedCommit: "slice4-test-commit"
    )
    switch validation {
    case .passed:
        break
    case let .performancePending(gpuName):
        #expect(gpuName.lowercased().contains("paravirtual"))
    }

    let firstName = try #require(SliceFourEvidenceValidator.sceneNames.first)
    let firstNegative = negativeRoot.appendingPathComponent(firstName)
    let statusURL = firstNegative.appendingPathComponent("exit-status.txt")
    try Data("2\n".utf8).write(to: statusURL)
    #expect(throws: SliceFourEvidenceValidationError.self) {
        _ = try SliceFourEvidenceValidator.validate(
            positiveRoot: positiveRoot,
            negativeRoot: negativeRoot,
            sceneRoot: root,
            expectedCommit: "slice4-test-commit"
        )
    }
    try Data("1\n".utf8).write(to: statusURL)

    let negativeStdout = firstNegative.appendingPathComponent("stdout.log")
    try Data("unexpected\n".utf8).write(to: negativeStdout)
    #expect(throws: SliceFourEvidenceValidationError.self) {
        _ = try SliceFourEvidenceValidator.validate(
            positiveRoot: positiveRoot,
            negativeRoot: negativeRoot,
            sceneRoot: root,
            expectedCommit: "slice4-test-commit"
        )
    }
    try Data().write(to: negativeStdout)

    let firstPositive = positiveRoot.appendingPathComponent(firstName)
    let evidenceURL = firstPositive.appendingPathComponent(
        "\(firstName).slice4-evidence.json"
    )
    let originalEvidence = try Data(contentsOf: evidenceURL)
    var evidenceObject = try #require(
        JSONSerialization.jsonObject(with: originalEvidence)
            as? [String: Any]
    )
    evidenceObject["coverage"] = ["forged-static-coverage"]
    try JSONSerialization.data(withJSONObject: evidenceObject).write(
        to: evidenceURL
    )
    #expect(throws: SliceFourEvidenceValidationError.self) {
        _ = try SliceFourEvidenceValidator.validate(
            positiveRoot: positiveRoot,
            negativeRoot: negativeRoot,
            sceneRoot: root,
            expectedCommit: "slice4-test-commit"
        )
    }
    try originalEvidence.write(to: evidenceURL)

    let benchmarkURL = firstPositive.appendingPathComponent(
        "\(firstName).benchmark.json"
    )
    let originalBenchmark = try Data(contentsOf: benchmarkURL)
    var benchmarkObject = try #require(
        JSONSerialization.jsonObject(with: originalBenchmark)
            as? [String: Any]
    )
    benchmarkObject["peakRetainedSampleCount"] = 999_999
    try JSONSerialization.data(withJSONObject: benchmarkObject).write(
        to: benchmarkURL
    )
    #expect(throws: SliceFourEvidenceValidationError.self) {
        _ = try SliceFourEvidenceValidator.validate(
            positiveRoot: positiveRoot,
            negativeRoot: negativeRoot,
            sceneRoot: root,
            expectedCommit: "slice4-test-commit"
        )
    }
    try originalBenchmark.write(to: benchmarkURL)

    let longName = "slice4-long-stroke-bounds"
    let longBenchmarkURL = positiveRoot.appendingPathComponent(longName)
        .appendingPathComponent("\(longName).benchmark.json")
    let originalLongBenchmark = try Data(contentsOf: longBenchmarkURL)
    var longBenchmarkObject = try #require(
        JSONSerialization.jsonObject(with: originalLongBenchmark)
            as? [String: Any]
    )
    let instanceCounts = try #require(
        longBenchmarkObject["newInstanceCounts"] as? [Int]
    )
    longBenchmarkObject["newInstanceCounts"] = instanceCounts.map {
        min($0, 499)
    }
    try JSONSerialization.data(withJSONObject: longBenchmarkObject).write(
        to: longBenchmarkURL
    )
    #expect(throws: SliceFourEvidenceValidationError.self) {
        _ = try SliceFourEvidenceValidator.validate(
            positiveRoot: positiveRoot,
            negativeRoot: negativeRoot,
            sceneRoot: root,
            expectedCommit: "slice4-test-commit"
        )
    }
    try originalLongBenchmark.write(to: longBenchmarkURL)

    longBenchmarkObject = try #require(
        JSONSerialization.jsonObject(with: originalLongBenchmark)
            as? [String: Any]
    )
    var substitutedCounts = try #require(
        longBenchmarkObject["newInstanceCounts"] as? [Int]
    )
    substitutedCounts[0] = 500
    longBenchmarkObject["newInstanceCounts"] = substitutedCounts
    longBenchmarkObject["fiveHundredDabStressFrameIndex"] = 0
    try JSONSerialization.data(withJSONObject: longBenchmarkObject).write(
        to: longBenchmarkURL
    )
    #expect(throws: SliceFourEvidenceValidationError.self) {
        _ = try SliceFourEvidenceValidator.validate(
            positiveRoot: positiveRoot,
            negativeRoot: negativeRoot,
            sceneRoot: root,
            expectedCommit: "slice4-test-commit"
        )
    }
    try originalLongBenchmark.write(to: longBenchmarkURL)

    longBenchmarkObject = try #require(
        JSONSerialization.jsonObject(with: originalLongBenchmark)
            as? [String: Any]
    )
    var upwardCounts = try #require(
        longBenchmarkObject["newInstanceCounts"] as? [Int]
    )
    let stressIndex = try #require(
        longBenchmarkObject["fiveHundredDabStressFrameIndex"] as? Int
    )
    upwardCounts[stressIndex] = 501
    longBenchmarkObject["newInstanceCounts"] = upwardCounts
    try JSONSerialization.data(withJSONObject: longBenchmarkObject).write(
        to: longBenchmarkURL
    )
    #expect(throws: SliceFourEvidenceValidationError.self) {
        _ = try SliceFourEvidenceValidator.validate(
            positiveRoot: positiveRoot,
            negativeRoot: negativeRoot,
            sceneRoot: root,
            expectedCommit: "slice4-test-commit"
        )
    }
    try originalLongBenchmark.write(to: longBenchmarkURL)
}

@Test
@MainActor
func sliceFourRunnerRejectsIncompleteAttributedTrace() throws {
    let url = sliceFourSceneRoot().appendingPathComponent(
        "slice4-legacy-ink-parity.json"
    )
    var object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url))
            as? [String: Any]
    )
    var samples = try #require(object["attributedSamples"] as? [[String: Any]])
    samples[0]["phase"] = "moved"
    object["attributedSamples"] = samples
    let scene = try HarnessScene.decode(
        JSONSerialization.data(withJSONObject: object)
    )
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let runner = makeSliceFourRunner(
        device: device,
        library: try makeSliceFourTestLibrary(device: device)
    )
    #expect(throws: SliceFourHarnessRunError.self) {
        _ = try runner.run(
            scene: scene,
            outputDirectory: FileManager.default.temporaryDirectory,
            build: BenchmarkBuild(configuration: "Debug", gitCommit: "test")
        )
    }
}

@Test
@MainActor
func recipeSpecificSeamOracleMatchesTheActualBrushPipeline() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let library = try makeSliceFourTestLibrary(device: device)
    let renderer = try GridRenderer(
        device: device,
        library: library,
        drawableSize: PatternSize(width: 96, height: 96),
        configuration: TilingCanvasConfiguration(
            pixelSize: PixelSize(width: 64, height: 64),
            tiling: .halfDrop
        )
    )
    let recipe = try BrushRecipe(
        id: BrushRecipeID("test.recipe-seam-oracle"),
        shape: .softRound,
        grain: .paper,
        grainCoordinateMode: .brushLocal,
        material: BrushMaterial(
            family: .dry,
            strength: 0.8,
            wetness: 0,
            bleedRadius: 0,
            softenPasses: 0,
            accumulationLimit: 1
        ),
        baseHardness: 0.7,
        aspectRatio: 0.75
    )
    let transform = Affine2D(
        xAxis: SIMD2(96, 0),
        yAxis: SIMD2(0, 72),
        translation: SIMD2(64, 32)
    )
    let footprint = StampFootprint(
        brushToWorld: transform,
        localBounds: AxisAlignedRect(
            minimum: SIMD2(-1, -1),
            maximum: SIMD2(1, 1)
        ),
        coverageSymmetry: .halfTurnInvariant
    )
    let attributes = SIMD4<Float>(
        recipe.baseHardness,
        recipe.grainTransform.scale,
        recipe.grainTransform.offset.x,
        recipe.grainTransform.offset.y
    )

    let rendered = try renderer.renderBrushFootprintForHarness(
        footprint: footprint,
        radius: 72,
        recipe: recipe,
        brushAttributes: attributes
    )
    let oracle = SliceFourHarnessRunner.recipeCoverageOracleForTests(
        fragments: rendered.fragments,
        pixelSize: PixelSize(width: 64, height: 64),
        recipe: recipe,
        radius: 72,
        brushAttributes: attributes,
        resolvedShapeIdentity: rendered.shapeIdentity,
        resolvedGrainIdentity: rendered.grainIdentity
    )
    let comparison = SliceFourHarnessRunner.compareRecipeCoverageForTests(
        expected: oracle,
        productionBGRA: sliceFourTextureBytes(rendered.canonical)
    )

    #expect(rendered.assetsWereExact)
    #expect(comparison.holeCount == 0)
    #expect(comparison.phantomCount == 0)
}

@Test
func recipeSeamComparisonRejectsAOnePixelShiftedMask() {
    let oracle = OracleCoverage(
        pixelSize: PixelSize(width: 3, height: 3),
        bytes: [
            0, 0, 0,
            0, 255, 0,
            0, 0, 0,
        ]
    )
    var shiftedBGRA = [UInt8](repeating: 0, count: 3 * 3 * 4)
    shiftedBGRA[(1 * 3 + 2) * 4 + 3] = 255

    let comparison = SliceFourHarnessRunner.compareRecipeCoverageForTests(
        expected: oracle,
        productionBGRA: shiftedBGRA
    )

    #expect(comparison.holeCount == 1)
    #expect(comparison.phantomCount == 1)
    #expect(comparison.maximumDelta == 255)
}

@Test
func sliceFourNegativeMatrixCoversEveryRequiredFamilyIndependently() throws {
    let root = sliceFourSceneRoot()
    #expect(
        Set(SliceFourEvidenceValidator.sceneNames)
            == Set(sliceFourSpecRequiredNegativeControlMetrics.keys)
    )
    for name in SliceFourEvidenceValidator.sceneNames {
        let positive = try HarnessScene.decode(Data(contentsOf:
            root.appendingPathComponent("\(name).json")
        ))
        let negative = try HarnessScene.decode(Data(contentsOf:
            root.appendingPathComponent("\(name)-negative-control.json")
        ))

        try SliceFourEvidenceValidator.validateNegativeControlForTests(
            positive: positive,
            negative: negative
        )
        let requiredBySpec = try #require(
            sliceFourSpecRequiredNegativeControlMetrics[name]
        )
        let requiredByValidator = try #require(
            SliceFourEvidenceValidator.requiredNegativeControlMetrics[name]
        )
        let specNames = Set(requiredBySpec.map(\.rawValue))
        #expect(Set(requiredByValidator.map(\.rawValue)) == specNames)
        #expect(
            Set(negative.negativeControls.map { $0.metric.rawValue })
                == specNames
        )
    }

    let name = "slice4-pressure-scatter"
    let pressureNegative = try HarnessScene.decode(Data(contentsOf:
        root.appendingPathComponent("\(name)-negative-control.json")
    ))
    var values = Dictionary(
        uniqueKeysWithValues: pressureNegative.negativeControls.map {
            ($0.metric.rawValue, 0)
        }
    )
    values[HarnessStructuralMetric.assetIdentityMismatchCount.rawValue] = 1
    #expect(
        throws: SliceFourHarnessRunError.negativeControlUnexpectedlyPassed(
            sceneName: pressureNegative.name,
            metric: .assetIdentityMismatchCount
        )
    ) {
        try SliceFourHarnessRunner.evaluateNegativeControls(
            scene: pressureNegative,
            values: values
        )
    }
}

private let sliceFourSpecRequiredNegativeControlMetrics: [
    String: [HarnessStructuralMetric]
] = [
    "slice4-legacy-ink-parity": [
        .legacyParityMaximumDelta,
        .anchorTilingMatrixPassCount,
        .anchorTilingNoncentralCount,
        .anchorTilingLiveCommitPassCount,
        .anchorTilingContinuityPassCount,
        .anchorTilingEraserAlphaPassCount,
        .anchorTilingEraserColorPassCount,
        .anchorCatalogEqualityCount,
        .historyCommandCount,
    ],
    "slice4-pressure-scatter": [
        .pressureResponseChangedByteCount,
        .sameSeedMaximumDelta,
        .differentSeedChangedByteCount,
        .shapeHardnessChangedByteCount,
        .assetIdentityMismatchCount,
    ],
    "slice4-dry-grain-tilings": [
        .assetIdentityMismatchCount,
        .materialMismatchCount,
        .previewCommitViolationCount,
    ],
    "slice4-glaze-live-commit": [
        .previewCommitViolationCount,
        .materialMismatchCount,
        .historyCommandCount,
    ],
    "slice4-wash-bounds": [
        .processedWashPixelCount,
        .washWorkingBytes,
        .materialMismatchCount,
        .replayDegradationCount,
    ],
    "slice4-prediction-taper-replay": [
        .predictedDuplicateSettledDabCount,
        .replayCount,
        .historyCommandCount,
    ],
    "slice4-stale-epoch-cancel": [
        .staleReplayEpochViolationCount,
        .canonicalByteDelta,
        .gpuFailurePreservedCanonicalCount,
        .allocationFailurePreservedCanonicalCount,
    ],
    "slice4-long-stroke-bounds": [
        .replayDegradationCount,
        .peakRetainedSampleCount,
        .peakRetainedDabCount,
        .promotedSettledPrefixCount,
    ],
]

@MainActor
private func makeSliceFourRunner(
    device: any MTLDevice,
    library: any MTLLibrary
) -> SliceFourHarnessRunner {
    let history = DocumentHistory()
    return SliceFourHarnessRunner(
        device: device,
        library: library,
        anchorRecipes: AnchorBrushCatalog.drawAnchors.map(\.recipe),
        catalogRecipeVerifier: { recipe in
            AnchorBrushCatalog.recipe(for: recipe.id) == recipe
        },
        historyRecorder: { receipt in
            if let receipt {
                let command = DocumentHistoryCommand.raster(
                    RasterHistoryCommand(
                        kind: .draw,
                        before: receipt.before,
                        after: receipt.after
                    )
                )
                try history.validateNewCommand(
                    retainedBytes: command.retainedBytes
                )
                _ = history.appendSuccessful(command)
            }
            return history.commandCount
        }
    )
}

private func makeSliceFourTestLibrary(
    device: any MTLDevice
) throws -> any MTLLibrary {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let shader = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/MetalRenderer/Shaders.metal"
        ),
        encoding: .utf8
    )
    let header = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/CShaderTypes/include/ShaderTypes.h"
        ),
        encoding: .utf8
    )
    return try device.makeLibrary(
        source: shader.replacingOccurrences(
            of: "#include \"ShaderTypes.h\"",
            with: header
        ),
        options: nil
    )
}

private func sliceFourSceneRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("App/PatternSpike/Harness/Scenes")
}

private func sliceFourTextureBytes(_ texture: any MTLTexture) -> [UInt8] {
    let bytesPerRow = texture.width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
    texture.getBytes(
        &bytes,
        bytesPerRow: bytesPerRow,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
    )
    return bytes
}
