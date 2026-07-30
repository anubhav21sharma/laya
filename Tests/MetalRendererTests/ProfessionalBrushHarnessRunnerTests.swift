import BrushFormat
import BrushDepositionEvidenceValidation
import CoreGraphics
import EditorCore
import Foundation
import ImageIO
import Metal
import PatternEngine
@testable import MetalRenderer
@testable import ProfessionalBrushEvidenceValidation
import Testing
import UniformTypeIdentifiers

@Suite("Professional brush harness runner", .serialized)
struct ProfessionalBrushHarnessRunnerTests {
    @Test
    func sceneContractIsExactSortedAndPaired() throws {
        #expect(ProfessionalBrushEvidenceValidator.positiveSceneNames == [
            "professional-chisel-marker",
            "professional-graphite-pencil",
            "professional-natural-charcoal",
            "professional-technical-ink",
        ])
        #expect(
            ProfessionalBrushEvidenceValidator.negativeSceneNames
                == ProfessionalBrushEvidenceValidator.positiveSceneNames.map {
                    "\($0)-negative-control"
                }
        )
        #expect(
            ProfessionalBrushEvidenceValidator.sceneNames
                == ProfessionalBrushEvidenceValidator.sceneNames.sorted()
        )

        let scenes = try ProfessionalBrushEvidenceValidator.loadScenes(
            from: professionalSceneDirectory()
        )
        try ProfessionalBrushEvidenceValidator.validateSceneSet(scenes)
        #expect(
            scenes.map(\.name)
                == ProfessionalBrushEvidenceValidator.sceneNames
        )
    }

    @Test
    func sceneLoaderRejectsFilenameAndDecodedNameMismatch() throws {
        let directory = temporaryDirectory(named: "scene-name-binding")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let source = professionalSceneDirectory().appendingPathComponent(
            "professional-technical-ink.json"
        )
        try FileManager.default.copyItem(
            at: source,
            to: directory.appendingPathComponent(
                "professional-renamed-input.json"
            )
        )

        #expect(throws: Error.self) {
            _ = try ProfessionalBrushEvidenceValidator.loadScenes(
                from: directory
            )
        }
    }

    @Test
    func negativeSceneMayFlipOnlyProfessionalDefinitionIdentity() throws {
        let directory = temporaryDirectory(named: "negative-pair-contract")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        for name in ProfessionalBrushEvidenceValidator.sceneNames {
            let source = professionalSceneDirectory().appendingPathComponent(
                "\(name).json"
            )
            let destination = directory.appendingPathComponent("\(name).json")
            if name == "professional-technical-ink-negative-control" {
                var object = try #require(
                    JSONSerialization.jsonObject(
                        with: Data(contentsOf: source)
                    ) as? [String: Any]
                )
                var expectations = try #require(
                    object["depositionInvariantExpectations"]
                        as? [String: Bool]
                )
                expectations["professionalDefinitionIdentityExact"] = true
                expectations["predictionOnOffEqual"] = false
                object["depositionInvariantExpectations"] = expectations
                try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys]
                ).write(to: destination)
            } else {
                try FileManager.default.copyItem(
                    at: source,
                    to: destination
                )
            }
        }

        let scenes = try ProfessionalBrushEvidenceValidator.loadScenes(
            from: directory
        )
        #expect(throws: Error.self) {
            try ProfessionalBrushEvidenceValidator.validateSceneSet(scenes)
        }
    }

    @Test(arguments: professionalEntries)
    private func committedDefinitionsMatchGoldenSemanticHashesAndResources(
        _ fixture: ProfessionalEntryFixture
    ) throws {
        let package = try BrushPackage(
            manifest: BrushPackageManifest(resources: []),
            definition: fixture.entry.definition,
            resourceData: [:]
        )

        #expect(
            try package.contentHash
                == ProfessionalBrushEvidenceValidator.expectedSemanticHash(
                    forPositiveScene: fixture.scene
                )
        )
        #expect(
            ProfessionalBrushEvidenceValidator.expectedResourceLevels(
                forPositiveScene: fixture.scene
            ) == fixture.resources
        )
    }

    @Test
    func evidenceSchemaRejectsEveryRequiredFieldMutation() throws {
        #expect(ProfessionalBrushSceneEvidence.currentSchemaVersion == 2)
        let valid = professionalEvidenceFixture()
        try ProfessionalBrushEvidenceValidator.validate(valid)

        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("schema", { $0["schemaVersion"] = 0 }),
            ("scene", { $0["scene"] = "professional-unknown" }),
            ("family", { $0["family"] = "" }),
            ("definition", { $0["definitionID"] = "wrong" }),
            ("semantic hash", {
                $0["definitionSemanticHash"] = String(repeating: "0", count: 64)
            }),
            ("pipeline", { $0["pipelineKey"] = "" }),
            ("ABI", { $0["abiVersion"] = 0 }),
            ("resident bytes", { $0["residentResourceBytes"] = -1 }),
            ("logical count", { $0["logicalDabCount"] = 0 }),
            ("projected count", { $0["projectedInstanceCount"] = 0 }),
            ("live hash", { $0["livePNGSHA256"] = "bad" }),
            ("committed hash", { $0["committedPNGSHA256"] = "bad" }),
            ("canonical hash", { $0["canonicalPNGSHA256"] = "bad" }),
            ("characterization hash", {
                $0["characterizationSHA256"] = "bad"
            }),
            ("preview delta", {
                $0["previewCommitMaximumChannelDelta"] = 2
            }),
            ("resources", { $0["resolvedResources"] = [] }),
            ("invariants", { $0["invariantResults"] = [:] }),
        ]

        for (name, mutate) in mutations {
            var object = try validJSONObject(valid)
            mutate(&object)
            #expect(throws: Error.self, "\(name)") {
                _ = try ProfessionalBrushSceneEvidence.decode(
                    try JSONSerialization.data(
                        withJSONObject: object,
                        options: [.sortedKeys]
                    )
                )
            }
        }
    }

    @Test
    func evidenceRejectsDuplicateOrUnsortedResourcesAndFalseInvariant()
        throws
    {
        let valid = professionalEvidenceFixture()

        for resourceMutation in ["unsorted", "duplicate"] {
            var object = try validJSONObject(valid)
            var resources = try #require(
                object["resolvedResources"] as? [[String: Any]]
            )
            if resourceMutation == "unsorted" {
                resources.reverse()
            } else {
                resources.append(resources[0])
            }
            object["resolvedResources"] = resources
            #expect(throws: Error.self, "\(resourceMutation)") {
                _ = try ProfessionalBrushSceneEvidence.decode(
                    try JSONSerialization.data(
                        withJSONObject: object,
                        options: [.sortedKeys]
                    )
                )
            }
        }
        var object = try validJSONObject(valid)
        var invariants = try #require(
            object["invariantResults"] as? [String: Bool]
        )
        invariants["predictionOnOffEqual"] = false
        object["invariantResults"] = invariants
        #expect(throws: Error.self) {
            _ = try ProfessionalBrushSceneEvidence.decode(
                try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys]
                )
            )
        }
    }

    @Test(
        arguments:
            ProfessionalBrushEvidenceValidator.positiveSceneNames
    )
    @MainActor
    func everyPositiveSceneWritesTheExactProfessionalArtifactSet(
        _ sceneName: String
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let output = temporaryDirectory(named: sceneName)
        defer { try? FileManager.default.removeItem(at: output) }

        let result = try await professionalHarnessRunner(
            device: device,
            library: depositionHarnessTestLibrary(device: device)
        ).run(
            scene: repositoryScene(named: sceneName),
            outputDirectory: output,
            build: BenchmarkBuild(
                configuration: "Debug",
                gitCommit: String(repeating: "e", count: 40)
            )
        )
        let evidence = try ProfessionalBrushSceneEvidence.decode(
            Data(
                contentsOf: output.appendingPathComponent(
                    "\(sceneName).professional-evidence.json"
                )
            )
        )

        try ProfessionalBrushEvidenceValidator.validate(evidence)
        #expect(evidence.invariantResults.values.allSatisfy { $0 })
        let decodedCanonical = try RasterObservationValidator.decode(
            Data(
                contentsOf: output.appendingPathComponent(
                    "\(sceneName).canonical.png"
                )
            ),
            label: "canonical"
        )
        #expect(
            ArtifactFileSystem.sha256(Data(decodedCanonical.bgra))
                == evidence.observations.canonicalBGRA8SHA256
        )
        let benchmarkObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: output.appendingPathComponent(
                        "\(sceneName).benchmark.json"
                    )
                )
            ) as? [String: Any]
        )
        #expect(
            Set(benchmarkObject.keys)
                == SceneArtifactValidator.benchmarkKeys
        )
        let longRaw = try #require(
            JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: output.appendingPathComponent(
                        "professional-long-stroke.raw.json"
                    )
                )
            ) as? [String: Any]
        )
        let trace = try #require(
            JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: output.appendingPathComponent(
                        "professional-long-stroke-trace.json"
                    )
                )
            ) as? [String: Any]
        )
        let identityFrames = try #require(
            longRaw["identityFrames"] as? [[String: Any]]
        )
        let traceSamples = try #require(
            trace["samples"] as? [[String: Any]]
        )
        let measuredPhases = identityFrames.compactMap {
            $0["inputPhase"] as? String
        }
        let tracePhases = traceSamples.compactMap {
            $0["phase"] as? String
        }
        #expect(identityFrames.count == 128)
        #expect(
            (longRaw["cpuPreparationMilliseconds"] as? [Double])?
                .count == 128
        )
        #expect(
            (longRaw["gpuMilliseconds"] as? [Double])?.count == 128
        )
        #expect(measuredPhases == tracePhases)
        #expect(!measuredPhases.contains("commit"))
        #expect(result.artifactURLs.count == 20)
        #expect(Set(result.artifactURLs.map(\.lastPathComponent)) == [
            "\(sceneName).benchmark.json",
            "\(sceneName).canonical.png",
            "\(sceneName).characterization.json",
            "\(sceneName).committed.png",
            "\(sceneName).eraser-after.png",
            "\(sceneName).eraser-before.png",
            "\(sceneName).grid-origin.png",
            "\(sceneName).grid-translated.png",
            "\(sceneName).live.png",
            "\(sceneName).prediction-off.png",
            "\(sceneName).prediction-on.png",
            "\(sceneName).professional-evidence.json",
            "\(sceneName).radial-reflection-reference.png",
            "\(sceneName).radial-reflection-rendered.png",
            "\(sceneName).radial-rotation-reference.png",
            "\(sceneName).radial-rotation-rendered.png",
            "professional-five-hundred-dabs.raw.json",
            "professional-long-stroke.raw.json",
            "professional-long-stroke-trace.json",
            "professional-performance.json",
        ])
    }

    @Test
    @MainActor
    func artifactValidatorDerivesAllPositiveClaimsFromRawFiles()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let root = temporaryDirectory(named: "positive-artifact-root")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        var gpuName = ""
        var operatingSystem = ""
        var executableHash = ""
        for sceneName in
            ProfessionalBrushEvidenceValidator.positiveSceneNames
        {
            let emitted = root.appendingPathComponent(
                "emitted-\(sceneName)"
            )
            let destination = root.appendingPathComponent(sceneName)
            let result = try await professionalHarnessRunner(
                device: device,
                library: depositionHarnessTestLibrary(device: device)
            ).run(
                scene: repositoryScene(named: sceneName),
                outputDirectory: emitted,
                build: BenchmarkBuild(
                    configuration: "Debug",
                    gitCommit: String(repeating: "e", count: 40)
                )
            )
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: false
            )
            for sourceURL in result.artifactURLs {
                let prefix = "\(sceneName)."
                var name = sourceURL.lastPathComponent.hasPrefix(prefix)
                    ? String(
                        sourceURL.lastPathComponent.dropFirst(
                            prefix.count
                        )
                    )
                    : sourceURL.lastPathComponent
                if name == "professional-evidence.json" {
                    name = "evidence.json"
                }
                try FileManager.default.copyItem(
                    at: sourceURL,
                    to: destination.appendingPathComponent(name)
                )
            }
            try FileManager.default.removeItem(at: emitted)
            gpuName = result.benchmark.hardware.gpuName
            operatingSystem = result.benchmark.operatingSystem
            let evidence = try ProfessionalBrushSceneEvidence.decode(
                Data(
                    contentsOf: destination.appendingPathComponent(
                        "evidence.json"
                    )
                )
            )
            executableHash = evidence.rendererExecutableSHA256
        }

        #expect(
            try SceneArtifactValidator.validatePositive(
                root: root,
                expectedCommit: String(repeating: "e", count: 40),
                expectedGPUName: gpuName,
                expectedOperatingSystem: operatingSystem,
                expectedRendererSHA256: executableHash,
                baseline:
                    try professionalCharacterizationBaselineForValidation()
            ) >= 0
        )

        let mutatedScene =
            ProfessionalBrushEvidenceValidator.positiveSceneNames[0]
        let sceneDirectory = root.appendingPathComponent(mutatedScene)
        let evidenceURL = sceneDirectory
            .appendingPathComponent("evidence.json")
        let benchmarkURL = sceneDirectory
            .appendingPathComponent("benchmark.json")
        let committedURL = sceneDirectory
            .appendingPathComponent("committed.png")
        let originalEvidenceData = try Data(contentsOf: evidenceURL)
        let originalBenchmarkData = try Data(contentsOf: benchmarkURL)
        let originalCommittedData = try Data(contentsOf: committedURL)
        func validate() throws {
            _ = try SceneArtifactValidator.validatePositive(
                root: root,
                expectedCommit: String(repeating: "e", count: 40),
                expectedGPUName: gpuName,
                expectedOperatingSystem: operatingSystem,
                expectedRendererSHA256: executableHash,
                baseline:
                    try professionalCharacterizationBaselineForValidation()
            )
        }
        func restore() throws {
            try originalEvidenceData.write(to: evidenceURL)
            try originalBenchmarkData.write(to: benchmarkURL)
            try originalCommittedData.write(to: committedURL)
        }
        func mutateEvidence(
            _ mutation: (inout [String: Any]) throws -> Void
        ) throws {
            var object = try #require(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: evidenceURL)
                ) as? [String: Any]
            )
            try mutation(&object)
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ).write(to: evidenceURL)
        }

        var object = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: evidenceURL)
            ) as? [String: Any]
        )
        var observations = try #require(
            object["observations"] as? [String: Any]
        )
        observations["canonicalBGRA8SHA256"] =
            String(repeating: "0", count: 64)
        object["observations"] = observations
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: evidenceURL)
        #expect(throws: Error.self) {
            try validate()
        }

        let originalEvidenceObject = try #require(
            JSONSerialization.jsonObject(with: originalEvidenceData)
                as? [String: Any]
        )
        let reportedPreviewDelta = try #require(
            originalEvidenceObject[
                "previewCommitMaximumChannelDelta"
            ] as? Int
        )
        for value in [
            -1,
            reportedPreviewDelta == 0 ? 1 : 0,
        ] {
            try restore()
            try mutateEvidence {
                $0["previewCommitMaximumChannelDelta"] = value
            }
            #expect(throws: Error.self, "reported delta \(value)") {
                try validate()
            }
        }

        try restore()
        let committed = try RasterObservationValidator.decode(
            originalCommittedData,
            label: "committed"
        )
        var changedCommitted = committed.bgra
        let opaqueAlphaIndex = try #require(
            stride(from: 3, to: changedCommitted.count, by: 4)
                .first { changedCommitted[$0] == 255 }
        )
        let changedChannelIndex = opaqueAlphaIndex - 3
        changedCommitted[changedChannelIndex] =
            changedCommitted[changedChannelIndex] > 10
                ? changedCommitted[changedChannelIndex] - 10
                : changedCommitted[changedChannelIndex] + 10
        try PNGWriter.writeBGRA(
            changedCommitted,
            pixelSize: PixelSize(width: 128, height: 128),
            to: committedURL
        )
        try mutateEvidence {
            let png = try Data(contentsOf: committedURL)
            $0["committedPNGSHA256"] = ArtifactFileSystem.sha256(png)
            var observations = try #require(
                $0["observations"] as? [String: Any]
            )
            observations["committedBGRA8SHA256"] =
                ArtifactFileSystem.sha256(Data(changedCommitted))
            observations["committedNontransparentPixelCount"] =
                RasterObservationValidator.nontransparentPixelCount(
                    changedCommitted
                )
            $0["observations"] = observations
        }
        #expect(throws: Error.self) {
            try validate()
        }

        let telemetryMutations: [(String, Any)] = [
            ("encodedInstanceCount", 0),
            ("encodedInstanceCount", Int.max),
            ("bufferHighWater", 0),
            ("bufferHighWater", 4),
        ]
        for (key, value) in telemetryMutations {
            try restore()
            try mutateEvidence {
                var telemetry = try #require(
                    $0["telemetry"] as? [String: Any]
                )
                telemetry[key] = value
                $0["telemetry"] = telemetry
            }
            #expect(throws: Error.self, "\(key)=\(value)") {
                try validate()
            }
        }

        try restore()
        try mutateEvidence {
            var telemetry = try #require(
                $0["telemetry"] as? [String: Any]
            )
            telemetry["missedFrameCount"] = 1
            $0["telemetry"] = telemetry
        }
        var benchmark = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: benchmarkURL)
            ) as? [String: Any]
        )
        benchmark["missedFrameCount"] = 1
        try JSONSerialization.data(
            withJSONObject: benchmark,
            options: [.sortedKeys]
        ).write(to: benchmarkURL)
        #expect(throws: Error.self) {
            try validate()
        }

        for value in [-1, Int.max] {
            try restore()
            try mutateEvidence {
                var observations = try #require(
                    $0["observations"] as? [String: Any]
                )
                observations["pipelinePrepareCallCountBeforeStroke"] =
                    value
                observations["pipelinePrepareCallCountAfterStroke"] =
                    value
                $0["observations"] = observations
            }
            #expect(throws: Error.self, "pipeline count \(value)") {
                try validate()
            }
        }

        for value in [-1, Int.max] {
            try restore()
            try mutateEvidence {
                var counters = try #require(
                    $0["compilerCounters"] as? [String: Any]
                )
                var afterCompile = try #require(
                    counters["afterCompile"] as? [String: Any]
                )
                afterCompile["packageDecodeCount"] = value
                counters["afterCompile"] = afterCompile
                $0["compilerCounters"] = counters
            }
            #expect(throws: Error.self, "compiler count \(value)") {
                try validate()
            }
        }

        try restore()
        try mutateEvidence {
            var counters = try #require(
                $0["compilerCounters"] as? [String: Any]
            )
            var afterCacheHit = try #require(
                counters["afterCacheHit"] as? [String: Any]
            )
            afterCacheHit["cacheHitCount"] = Int.max
            counters["afterCacheHit"] = afterCacheHit
            $0["compilerCounters"] = counters
        }
        #expect(throws: Error.self, "cache counter overflow") {
            try validate()
        }
    }

    @Test
    func rasterDecoderRejectsJPEGAndTIFFBytesRenamedAsPNG() throws {
        let directory = temporaryDirectory(named: "renamed-raster")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var pixels = [UInt8](repeating: 0, count: 128 * 128 * 4)
        for alpha in stride(from: 3, to: pixels.count, by: 4) {
            pixels[alpha] = 255
        }
        let pngURL = directory.appendingPathComponent("source.png")
        try PNGWriter.writeBGRA(
            pixels,
            pixelSize: PixelSize(width: 128, height: 128),
            to: pngURL
        )
        let source = try #require(
            CGImageSourceCreateWithURL(pngURL as CFURL, nil)
        )
        let image = try #require(
            CGImageSourceCreateImageAtIndex(source, 0, nil)
        )

        for type in [UTType.jpeg.identifier, UTType.tiff.identifier] {
            let encoded = NSMutableData()
            let destination = try #require(
                CGImageDestinationCreateWithData(
                    encoded,
                    type as CFString,
                    1,
                    nil
                )
            )
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            #expect(throws: Error.self, "\(type) renamed .png") {
                _ = try RasterObservationValidator.decode(
                    encoded as Data,
                    label: "renamed.png"
                )
            }
        }
    }

    @Test
    @MainActor
    func completeArtifactRootIsValidatedEndToEndAndFailsClosed()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let catalogs = try exportedManualCatalogs()
        let stageFour = try StageFourArtifactFixture()
        defer { stageFour.remove() }
        try catalogs.stageFour.write(
            to: stageFour.root.appendingPathComponent(
                "brush-lab-cards/catalog.json"
            )
        )
        try stageFour.rewriteProvenanceCatalogDigest()
        try mutateJSONObject(
            at: stageFour.root.appendingPathComponent(
                "performance-status.txt"
            )
        ) {
            $0["gpu500DabMilliseconds"] = 2.5
        }
        try mutateJSONObject(
            at: stageFour.root.appendingPathComponent(
                "logs/five-hundred-dabs.benchmark.json"
            )
        ) {
            $0["dabGPUMilliseconds"] = [2.5]
        }
        try stageFour.rewriteManifest()
        let stageFourStatus = try stageFour.validateProductionContract()
        guard case .performancePending = stageFourStatus else {
            Issue.record("production Stage 4 fixture must remain pending")
            return
        }

        let root = temporaryDirectory(named: "complete-stage5-root")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in [
            "manual-cards", "negative-control", "physical-profiles",
            "positive", "raw-provenance", "runtime", "scene-inputs",
        ] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        try stageFour.sourceTree.write(
            to: root.appendingPathComponent("source-tree.txt")
        )
        try stageFour.sourceTree.write(
            to: root.appendingPathComponent("source-tree-terminal.txt")
        )
        try professionalCharacterizationBaselineForValidation()
            .encoded().write(
                to: root.appendingPathComponent(
                    "characterization-baseline.json"
                )
            )
        try catalogs.stageFive.write(
            to: root.appendingPathComponent(
                "manual-cards/catalog.json"
            )
        )
        try rootSceneMatrixData().write(
            to: root.appendingPathComponent("scene-matrix.json")
        )
        for name in ProfessionalBrushEvidenceValidator.sceneNames {
            try FileManager.default.copyItem(
                at: professionalSceneDirectory()
                    .appendingPathComponent("\(name).json"),
                to: root.appendingPathComponent(
                    "scene-inputs/\(name).json"
                )
            )
        }

        let executableURL = URL(
            fileURLWithPath: try #require(CommandLine.arguments.first)
        ).resolvingSymlinksInPath().standardizedFileURL
        let executableData = try Data(contentsOf: executableURL)
        try executableData.write(
            to: root.appendingPathComponent("runtime/PatternSpike")
        )
        let executableHash = ArtifactFileSystem.sha256(executableData)

        var gpuName = ""
        var operatingSystem = ""
        var maximumCPUP95 = 0.0
        var maximumGPU500Dab = 0.0
        for sceneName in
            ProfessionalBrushEvidenceValidator.positiveSceneNames
        {
            let emitted = root.appendingPathComponent(
                "emitted-\(sceneName)"
            )
            let destination = root.appendingPathComponent(
                "positive/\(sceneName)"
            )
            let result = try await professionalHarnessRunner(
                device: device,
                library: depositionHarnessTestLibrary(device: device)
            ).run(
                scene: repositoryScene(named: sceneName),
                outputDirectory: emitted,
                build: BenchmarkBuild(
                    configuration: "Debug",
                    gitCommit: stageFour.commit
                )
            )
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: false
            )
            for sourceURL in result.artifactURLs {
                let prefix = "\(sceneName)."
                var name = sourceURL.lastPathComponent.hasPrefix(prefix)
                    ? String(
                        sourceURL.lastPathComponent.dropFirst(
                            prefix.count
                        )
                    )
                    : sourceURL.lastPathComponent
                if name == "professional-evidence.json" {
                    name = "evidence.json"
                }
                try FileManager.default.copyItem(
                    at: sourceURL,
                    to: destination.appendingPathComponent(name)
                )
            }
            try FileManager.default.removeItem(at: emitted)
            gpuName = result.benchmark.hardware.gpuName
            operatingSystem = result.benchmark.operatingSystem
            maximumCPUP95 = max(
                maximumCPUP95,
                testPercentile95(
                    result.benchmark.cpuEncodeMilliseconds
                )
            )
            let performanceRaw = try #require(
                JSONSerialization.jsonObject(
                    with: Data(
                        contentsOf: destination.appendingPathComponent(
                            "professional-five-hundred-dabs.raw.json"
                        )
                    )
                ) as? [String: Any]
            )
            maximumGPU500Dab = max(
                maximumGPU500Dab,
                try #require(
                    (performanceRaw["gpuMilliseconds"] as? [Double])?
                        .max()
                )
            )
            let evidence = try ProfessionalBrushSceneEvidence.decode(
                Data(
                    contentsOf: destination.appendingPathComponent(
                        "evidence.json"
                    )
                )
            )
            #expect(
                evidence.rendererExecutableSHA256 == executableHash
            )
        }

        for scene in
            ProfessionalBrushEvidenceValidator.positiveSceneNames
        {
            let directory = root.appendingPathComponent(
                "negative-control/\(scene)"
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            try Data().write(
                to: directory.appendingPathComponent("stdout.log")
            )
            try Data(
                "HARNESS FAIL \(scene)-negative-control expectation 'professionalDefinitionIdentityExact' did not match\n"
                    .utf8
            ).write(to: directory.appendingPathComponent("stderr.log"))
            try Data("1\n".utf8).write(
                to: directory.appendingPathComponent(
                    "exit-status.txt"
                )
            )
        }

        let rawRoot = root.appendingPathComponent("raw-provenance")
        let rawValues: [String: Data] = [
            "hardware-machine.txt": try commandOutput(
                "/usr/bin/uname", ["-m"]
            ),
            "hardware-model.txt": Data("FixtureMac,1\n".utf8),
            "hardware.txt": Data(),
            "kernel.txt": try commandOutput("/usr/bin/uname", ["-a"]),
            "operating-system.txt": try commandOutput(
                "/usr/bin/sw_vers", []
            ),
            "swift-toolchain.txt": Data("Swift fixture\nBuild 1\n".utf8),
            "validator-nm-undefined.txt": try commandOutput(
                "/usr/bin/nm", ["-u", executableURL.path]
            ),
            "validator-otool.txt": try commandOutput(
                "/usr/bin/otool", ["-L", executableURL.path]
            ),
            "xcode-toolchain.txt": Data("Xcode fixture\nBuild 1\n".utf8),
            "xcodegen-toolchain.txt": Data("Version: fixture\n".utf8),
        ]
        var rawHashes: [String: String] = [:]
        for (name, data) in rawValues {
            try data.write(to: rawRoot.appendingPathComponent(name))
            rawHashes[name] = ArtifactFileSystem.sha256(data)
        }

        let stageFourManifestData = try Data(
            contentsOf: stageFour.root.appendingPathComponent(
                "artifact-sha256.txt"
            )
        )
        let stageFourManifestHash =
            ArtifactFileSystem.sha256(stageFourManifestData)
        try testJSONData([
            "schemaVersion": 1,
            "exitStatus": 2,
            "artifactRoot": stageFour.root.standardizedFileURL.path,
            "commit": stageFour.commit,
            "sourceTreeSHA256": stageFour.sourceTreeSHA256,
            "artifactManifestSHA256": stageFourManifestHash,
            "terminalLine":
                "BRUSH STAGE 4 PERFORMANCE PENDING artifacts=\(stageFour.root.standardizedFileURL.path) commit=\(stageFour.commit) gpu=\(stageFour.gpuName)",
        ]).write(
            to: root.appendingPathComponent(
                "stage-four-regression.json"
            )
        )
        try testJSONData([
            "schemaVersion": 2,
            "commit": stageFour.commit,
            "sourceTreeSHA256": stageFour.sourceTreeSHA256,
            "configuration": "Debug",
            "swiftVersion": "Swift fixture Build 1",
            "xcodeVersion": "Xcode fixture Build 1",
            "xcodegenVersion": "Version: fixture",
            "operatingSystem": operatingSystem,
            "kernel": String(
                decoding: rawValues["kernel.txt"]!,
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines),
            "hardwareMachine": String(
                decoding: rawValues["hardware-machine.txt"]!,
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines),
            "hardwareModel": "FixtureMac,1",
            "gpuName": gpuName,
            "gpuClassification":
                ArtifactFileSystem.gpuClassification(gpuName),
            "artifactRoot": root.standardizedFileURL.path,
            "stageFourExitStatus": 2,
            "stageFourArtifactManifestSHA256":
                stageFourManifestHash,
            "rawProvenanceSHA256": rawHashes,
            "rendererExecutableSHA256": executableHash,
        ]).write(to: root.appendingPathComponent("provenance.json"))
        try testJSONData([
            "schemaVersion": 2,
            "correctnessPassed": true,
            "gpuName": gpuName,
            "gpuClassification":
                ArtifactFileSystem.gpuClassification(gpuName),
            "cpuPreparationP95Milliseconds": maximumCPUP95,
            "cpuPreparationBudgetMilliseconds": 2.0,
            "gpu500DabMilliseconds": maximumGPU500Dab,
            "gpu500DabBudgetMilliseconds": 3.0,
        ]).write(
            to: root.appendingPathComponent(
                "performance-status.json"
            )
        )
        try writeStageFiveManifest(root: root)

        func validate() throws -> ProfessionalBrushArtifactValidationStatus {
            try ProfessionalBrushArtifactValidator.validate(
                artifactRoot: root.standardizedFileURL,
                expectedCommit: stageFour.commit,
                expectedSourceTreeSHA256: stageFour.sourceTreeSHA256,
                expectedStageFourArtifactRoot:
                    stageFour.root.standardizedFileURL
            )
        }
        func reject(_ label: String) {
            #expect(throws: Error.self, "\(label)") {
                _ = try validate()
            }
        }
        #expect(try validate() == .pending)

        let stageFourManifestURL = stageFour.root.appendingPathComponent(
            "artifact-sha256.txt"
        )
        try Data("corrupt\n".utf8).write(to: stageFourManifestURL)
        reject("fresh Stage 4 validation")
        try stageFourManifestData.write(to: stageFourManifestURL)

        for name in ["extra.txt", ".hidden"] {
            let url = root.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            reject("unexpected root entry \(name)")
            try FileManager.default.removeItem(at: url)
        }
        let terminalURL = root.appendingPathComponent(
            "source-tree-terminal.txt"
        )
        try FileManager.default.removeItem(at: terminalURL)
        reject("missing root entry")
        try stageFour.sourceTree.write(to: terminalURL)

        let manifestURL = root.appendingPathComponent(
            "artifact-sha256.txt"
        )
        let validManifest = try Data(contentsOf: manifestURL)
        try Data("corrupt\n".utf8).write(to: manifestURL)
        reject("artifact manifest")
        try validManifest.write(to: manifestURL)

        let provenanceURL = root.appendingPathComponent(
            "provenance.json"
        )
        let validProvenance = try Data(contentsOf: provenanceURL)
        try mutateJSONObject(at: provenanceURL) {
            $0["operatingSystem"] = "Version 0 (Build Wrong)"
        }
        try writeStageFiveManifest(root: root)
        reject("raw provenance cross-link")
        try validProvenance.write(to: provenanceURL)

        let regressionURL = root.appendingPathComponent(
            "stage-four-regression.json"
        )
        let validRegression = try Data(contentsOf: regressionURL)
        try mutateJSONObject(at: regressionURL) {
            $0["artifactManifestSHA256"] =
                String(repeating: "0", count: 64)
        }
        try writeStageFiveManifest(root: root)
        reject("Stage 4 manifest cross-link")
        try validRegression.write(to: regressionURL)

        let performanceURL = root.appendingPathComponent(
            "performance-status.json"
        )
        let validPerformance = try Data(contentsOf: performanceURL)
        try mutateJSONObject(at: performanceURL) {
            $0["correctnessPassed"] = false
        }
        try writeStageFiveManifest(root: root)
        reject("status composition")
        try validPerformance.write(to: performanceURL)

        let manualURL = root.appendingPathComponent(
            "manual-cards/catalog.json"
        )
        let validManual = try Data(contentsOf: manualURL)
        try mutateJSONObject(at: manualURL) { object in
            var assessments =
                object["assessments"] as! [[String: Any]]
            for index in assessments.indices {
                for field in [
                    "responsiveness", "edgeQuality",
                    "taperTermination", "textureCohesion",
                    "pressureResponse", "tiltDirectionResponse",
                    "buildup", "symmetryBehavior", "eraserMatch",
                ] {
                    assessments[index][field] = "pass"
                }
                assessments[index]["notes"] = NSNull()
            }
            object["assessments"] = assessments
        }
        try writeStageFiveManifest(root: root)
        #expect(
            try validate() == .pending,
            "manual completion alone cannot make the root pass"
        )
        try validManual.write(to: manualURL)

        let unknownPhysical = root.appendingPathComponent(
            "physical-profiles/unknown"
        )
        try FileManager.default.createDirectory(
            at: unknownPhysical,
            withIntermediateDirectories: false
        )
        try writeStageFiveManifest(root: root)
        reject("partial physical evidence")
        try FileManager.default.removeItem(at: unknownPhysical)
        try writeStageFiveManifest(root: root)
        #expect(try validate() == .pending)
    }

    @Test(
        arguments:
            ProfessionalBrushEvidenceValidator.negativeSceneNames
    )
    @MainActor
    func everyNegativeSceneFailsItsSingleRequirement(
        _ sceneName: String
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let output = temporaryDirectory(named: sceneName)
        defer { try? FileManager.default.removeItem(at: output) }

        await #expect(
            throws: ProfessionalBrushEvidenceValidationError.self
        ) {
            _ = try await professionalHarnessRunner(
                device: device,
                library: depositionHarnessTestLibrary(device: device)
            ).run(
                scene: repositoryScene(named: sceneName),
                outputDirectory: output,
                build: BenchmarkBuild(
                    configuration: "Testing",
                    gitCommit: String(repeating: "f", count: 40)
                )
            )
        }
    }
}

private struct ProfessionalEntryFixture: CustomTestStringConvertible {
    let scene: String
    let entry: ProfessionalBrushEntry
    let resources: [String: Int]

    var testDescription: String { scene }
}

private let professionalEntries = [
    ProfessionalEntryFixture(
        scene: "professional-chisel-marker",
        entry: ProfessionalBrushCatalog.chiselMarker,
        resources: ["builtin.shape.marker-chisel": 8]
    ),
    ProfessionalEntryFixture(
        scene: "professional-graphite-pencil",
        entry: ProfessionalBrushCatalog.graphitePencil,
        resources: [
            "builtin.grain.graphite": 9,
            "builtin.grain.paper": 7,
            "builtin.shape.graphite-tip": 8,
        ]
    ),
    ProfessionalEntryFixture(
        scene: "professional-natural-charcoal",
        entry: ProfessionalBrushCatalog.naturalCharcoal,
        resources: [
            "builtin.grain.charcoal": 9,
            "builtin.grain.paper": 7,
            "builtin.shape.charcoal-tip": 8,
            "builtin.shape.soft-round": 7,
        ]
    ),
    ProfessionalEntryFixture(
        scene: "professional-technical-ink",
        entry: ProfessionalBrushCatalog.technicalInk,
        resources: ["builtin.shape.technical-nib": 8]
    ),
]

private func professionalEvidenceFixture() -> ProfessionalBrushSceneEvidence {
    let resources = [
        ProfessionalBrushResolvedResource(
            identity: "builtin.grain.graphite",
            kind: "grain",
            mipCount: 9
        ),
        ProfessionalBrushResolvedResource(
            identity: "builtin.grain.paper",
            kind: "grain",
            mipCount: 7
        ),
        ProfessionalBrushResolvedResource(
            identity: "builtin.shape.graphite-tip",
            kind: "shape",
            mipCount: 8
        ),
    ]
    let afterCompile = ProfessionalBrushCompilerCounterSnapshot(
        packageDecodeCount: 1,
        imageDecodeCount: 0,
        textureUploadCount: 3,
        cacheHitCount: 0,
        activationCount: 1
    )
    let afterCacheHit = ProfessionalBrushCompilerCounterSnapshot(
        packageDecodeCount: 2,
        imageDecodeCount: 0,
        textureUploadCount: 3,
        cacheHitCount: 3,
        activationCount: 2
    )
    return ProfessionalBrushSceneEvidence(
        schemaVersion: ProfessionalBrushSceneEvidence.currentSchemaVersion,
        scene: "professional-graphite-pencil",
        family: "Graphite Pencil",
        definitionID: "builtin.professional-graphite-pencil",
        definitionSemanticHash:
            ProfessionalBrushEvidenceValidator.expectedSemanticHash(
                forPositiveScene: "professional-graphite-pencil"
            )!,
        pipelineKey:
            "deposition:flow:dryBreakup:s0:g1:h1:d0:abi1:format80:samples1",
        abiVersion: DepositionABI.version,
        residentResourceBytes: 114_687,
        resolvedResources: resources,
        logicalDabCount: 4,
        projectedInstanceCount: 4,
        livePNGSHA256: String(repeating: "a", count: 64),
        committedPNGSHA256: String(repeating: "b", count: 64),
        canonicalPNGSHA256: String(repeating: "c", count: 64),
        characterizationSHA256: String(repeating: "d", count: 64),
        rendererExecutableSHA256: String(repeating: "e", count: 64),
        previewCommitMaximumChannelDelta: 1,
        compilerCounters: ProfessionalBrushCompilerCounterEvidence(
            beforeCompile: .zero,
            afterCompile: afterCompile,
            afterCacheHit: afterCacheHit,
            beforeStroke: afterCacheHit,
            afterStroke: afterCacheHit
        ),
        telemetry: DepositionTelemetryEvidence(
            authoritativeBacklog: 0,
            predictedBacklog: 0,
            backlogHighWater: 4,
            encodedInstanceCount: 4,
            bufferHighWater: 1,
            missedFrameCount: 0
        ),
        observations: ProfessionalBrushInvariantObservations(
            liveBGRA8SHA256: String(repeating: "1", count: 64),
            committedBGRA8SHA256: String(repeating: "2", count: 64),
            canonicalBGRA8SHA256: String(repeating: "3", count: 64),
            liveNontransparentPixelCount: 1,
            committedNontransparentPixelCount: 1,
            canonicalNontransparentPixelCount: 1,
            predictionOffBGRA8SHA256: String(repeating: "4", count: 64),
            predictionOnBGRA8SHA256: String(repeating: "4", count: 64),
            predictionMaximumChannelDelta: 0,
            gridOriginBGRA8SHA256: String(repeating: "5", count: 64),
            gridTranslatedBGRA8SHA256: String(repeating: "5", count: 64),
            gridMaximumChannelDelta: 0,
            eraserBeforeBGRA8SHA256: String(repeating: "6", count: 64),
            eraserAfterBGRA8SHA256: String(repeating: "7", count: 64),
            eraserBeforeNontransparentPixelCount: 2,
            eraserAfterNontransparentPixelCount: 1,
            eraserReducedAlphaPixelCount: 1,
            radialRotationRenderedBGRA8SHA256:
                String(repeating: "8", count: 64),
            radialRotationReferenceBGRA8SHA256:
                String(repeating: "8", count: 64),
            radialRotationMaximumChannelDelta: 0,
            radialReflectionRenderedBGRA8SHA256:
                String(repeating: "9", count: 64),
            radialReflectionReferenceBGRA8SHA256:
                String(repeating: "9", count: 64),
            radialReflectionMaximumChannelDelta: 0,
            replayMode: "replayTail",
            replayMaximumSamples: 256,
            replayMaximumDabs: 2_048,
            replayMaximumProjectedInstances: 4_096,
            pipelinePrepareCallCountBeforeStroke: 1,
            pipelinePrepareCallCountAfterStroke: 1
        ),
        invariantResults: Dictionary(
            uniqueKeysWithValues:
                ProfessionalBrushEvidenceValidator.requiredInvariantNames.map {
                    ($0, true)
                }
        )
    )
}

private func validJSONObject(
    _ evidence: ProfessionalBrushSceneEvidence
) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(with: try evidence.encoded())
            as? [String: Any]
    )
}

private func professionalSceneDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("App/PatternSpike/Harness/Scenes")
}

func professionalCharacterizationBaselineForValidation()
    throws -> ProfessionalBrushLogicalBaseline
{
    let records = try ProfessionalBrushCatalog.all.flatMap { entry in
        let package = try BrushPackage(
            manifest: BrushPackageManifest(resources: []),
            definition: entry.definition,
            resourceData: [:]
        )
        let hash = try package.contentHash
        return StrokeTraceFixtures.professional.map { trace in
            ProfessionalBrushCharacterizer.record(
                family: entry.displayName,
                definitionSemanticHash: hash,
                trace: trace,
                program: entry.program
            )
        }
    }.sorted {
        ($0.brushID, $0.traceName) < ($1.brushID, $1.traceName)
    }
    return try ProfessionalBrushLogicalBaseline(
        validatingSchemaVersion:
            ProfessionalBrushLogicalBaseline.schemaVersion,
        records: records
    )
}

private func exportedManualCatalogs() throws
    -> (stageFour: Data, stageFive: Data)
{
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let package = temporaryDirectory(named: "manual-catalog-exporter")
    defer { try? FileManager.default.removeItem(at: package) }
    let sources = package.appendingPathComponent(
        "Sources/CardExporter",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: sources,
        withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(
        at: repositoryRoot.appendingPathComponent(
            "App/PatternSpike/BrushLab/BrushLabManualCard.swift"
        ),
        to: sources.appendingPathComponent("BrushLabManualCard.swift")
    )
    let packageSource = """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "ProfessionalBrushCardExporter",
        platforms: [.macOS(.v14)],
        dependencies: [
            .package(name: "PatternModules", path: "\(repositoryRoot.path)"),
        ],
        targets: [
            .executableTarget(
                name: "CardExporter",
                dependencies: [
                    .product(
                        name: "PatternEngine",
                        package: "PatternModules"
                    ),
                    .product(
                        name: "EditorCore",
                        package: "PatternModules"
                    ),
                ]
            ),
        ]
    )
    """
    try Data(packageSource.utf8).write(
        to: package.appendingPathComponent("Package.swift")
    )
    let mainSource = """
    import Foundation

    guard CommandLine.arguments.count == 3 else {
        fatalError("usage: CardExporter STAGE4 STAGE5")
    }
    try BrushLabManualCatalog.pending().encoded().write(
        to: URL(fileURLWithPath: CommandLine.arguments[1])
    )
    try BrushLabProfessionalManualCatalog.pending().encoded().write(
        to: URL(fileURLWithPath: CommandLine.arguments[2])
    )
    """
    try Data(mainSource.utf8).write(
        to: sources.appendingPathComponent("main.swift")
    )
    let stageFourURL = package.appendingPathComponent("stage-four.json")
    let stageFiveURL = package.appendingPathComponent("stage-five.json")
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = [
        "run", "--package-path", package.path, "--configuration", "debug",
        "CardExporter", stageFourURL.path, stageFiveURL.path,
    ]
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        throw ProfessionalBrushArtifactValidationError.invalid(
            "manual catalog exporter failed: "
                + String(decoding: error, as: UTF8.self)
        )
    }
    let stageFour = try Data(contentsOf: stageFourURL)
    let stageFive = try Data(contentsOf: stageFiveURL)
    guard ArtifactFileSystem.sha256(stageFour)
            == StageFourEvidenceValidator.brushLabCatalogSHA256,
          try ProfessionalManualEvidenceValidator.validate(stageFive)
            == false
    else {
        throw ProfessionalBrushArtifactValidationError.invalid(
            "manual catalog exporter did not produce frozen goldens"
        )
    }
    return (stageFour, stageFive)
}

private func commandOutput(
    _ executable: String,
    _ arguments: [String]
) throws -> Data {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ProfessionalBrushArtifactValidationError.invalid(
            "\(executable) fixture command failed"
        )
    }
    return standardOutput.fileHandleForReading.readDataToEndOfFile()
}

private func mutateJSONObject(
    at url: URL,
    _ mutation: (inout [String: Any]) throws -> Void
) throws {
    var object = try JSONSerialization.jsonObject(
        with: Data(contentsOf: url)
    ) as! [String: Any]
    try mutation(&object)
    try testJSONData(object).write(to: url)
}

private func testJSONData(_ object: Any) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
}

private func rootSceneMatrixData() throws -> Data {
    try testJSONData([
        "schemaVersion": 1,
        "positive":
            ProfessionalBrushEvidenceValidator.positiveSceneNames,
        "negativeControls":
            ProfessionalBrushEvidenceValidator.negativeSceneNames,
    ])
}

private func writeStageFiveManifest(root: URL) throws {
    let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey,
    ]
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: Array(keys),
        options: [],
        errorHandler: nil
    ) else {
        throw ProfessionalBrushArtifactValidationError.invalid(
            "cannot enumerate Stage 5 fixture"
        )
    }
    let prefix = root.standardizedFileURL.path + "/"
    var records: [(String, String)] = []
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else {
            throw ProfessionalBrushArtifactValidationError.invalid(
                "fixture contains a symbolic link"
            )
        }
        guard values.isRegularFile == true,
              url.lastPathComponent != "artifact-sha256.txt"
        else {
            continue
        }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else {
            throw ProfessionalBrushArtifactValidationError.invalid(
                "fixture path escaped its root"
            )
        }
        records.append(
            (
                String(path.dropFirst(prefix.count)),
                ArtifactFileSystem.sha256(try Data(contentsOf: url))
            )
        )
    }
    let manifest = records.sorted { $0.0 < $1.0 }.map {
        "\($0.1)  ./\($0.0)\n"
    }.joined()
    try Data(manifest.utf8).write(
        to: root.appendingPathComponent("artifact-sha256.txt")
    )
}

private func testPercentile95(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let index = max(
        0,
        Int(ceil(Double(sorted.count) * 0.95)) - 1
    )
    return sorted[index]
}

@MainActor
private func professionalHarnessRunner(
    device: any MTLDevice,
    library: any MTLLibrary
) -> DepositionHarnessRunner {
    DepositionHarnessRunner(
        device: device,
        library: library,
        productionAnchorDefinitions: [
            "deposition-erase": AnchorBrushCatalog.eraser.definition,
            "deposition-ink": AnchorBrushCatalog.ink.definition,
            "professional-chisel-marker":
                ProfessionalBrushCatalog.chiselMarker.definition,
            "professional-graphite-pencil":
                ProfessionalBrushCatalog.graphitePencil.definition,
            "professional-natural-charcoal":
                ProfessionalBrushCatalog.naturalCharcoal.definition,
            "professional-technical-ink":
                ProfessionalBrushCatalog.technicalInk.definition,
        ]
    )
}
