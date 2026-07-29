import BrushFormat
import EditorCore
import Foundation
import Metal
import PatternEngine
@testable import MetalRenderer
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
                configuration: "Testing",
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
        #expect(Set(result.artifactURLs.map(\.lastPathComponent)) == [
            "\(sceneName).benchmark.json",
            "\(sceneName).canonical.png",
            "\(sceneName).characterization.json",
            "\(sceneName).committed.png",
            "\(sceneName).live.png",
            "\(sceneName).professional-evidence.json",
        ])
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
