import BrushFormat
import EditorCore
import Foundation
import Metal
import PatternEngine
@testable import MetalRenderer
@testable import ProfessionalBrushEvidenceValidation
import Testing

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
                var name = String(
                    sourceURL.lastPathComponent.dropFirst(
                        "\(sceneName).".count
                    )
                )
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
        let evidenceURL = root.appendingPathComponent(mutatedScene)
            .appendingPathComponent("evidence.json")
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

private func professionalCharacterizationBaselineForValidation()
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
