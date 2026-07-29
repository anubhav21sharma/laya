import BrushFormat
import BrushDepositionEvidenceGate
import EditorCore
import Foundation
import Metal
import PatternEngine
@testable import MetalRenderer
import Testing

@Suite("Native deposition harness runner", .serialized)
struct DepositionHarnessRunnerTests {
    @Test
    func requiredSceneContractIsExactAndSorted() {
        #expect(
            DepositionEvidenceValidator.positiveSceneNames == [
                "deposition-airbrush",
                "deposition-cache-pinning",
                "deposition-custom-asymmetric",
                "deposition-dry",
                "deposition-erase",
                "deposition-failure-matrix",
                "deposition-glaze",
                "deposition-ink",
                "deposition-kinematics",
                "deposition-layer-matrix",
                "deposition-marker",
                "deposition-periodic-seams",
                "deposition-prediction",
                "deposition-preview-commit",
                "deposition-radial-reflection",
                "deposition-stamp-size-mips",
            ]
        )
        #expect(
            DepositionEvidenceValidator.negativeSceneNames
                == DepositionEvidenceValidator.positiveSceneNames.map {
                    "\($0)-negative-control"
                }
        )
        #expect(
            DepositionEvidenceValidator.sceneNames
                == DepositionEvidenceValidator.sceneNames.sorted()
        )
        #expect(DepositionEvidenceValidator.sceneNames.count == 32)
    }

    @Test
    func repositorySceneDirectoryMatchesTheExactContract() throws {
        let scenes = try DepositionEvidenceValidator.loadScenes(
            from: repositorySceneDirectory()
        )

        #expect(scenes.count == 32)
        #expect(scenes.map(\.name) == DepositionEvidenceValidator.sceneNames)
        #expect(scenes.allSatisfy { $0.schemaVersion == 6 })
        try DepositionEvidenceValidator.validateSceneSet(scenes)
    }

    @Test
    func schemaSixSceneCarriesOnlySortedAuthoritativeExpectations() throws {
        let data = Data(
            """
            {
              "schemaVersion": 6,
              "name": "deposition-ink",
              "width": 128,
              "height": 128,
              "depositionInvariantExpectations": {
                "familyAndAccumulationCorrect": true,
                "previewCommitMaximumDeltaWithinTolerance": true
              }
            }
            """.utf8
        )

        let scene = try HarnessScene.decode(data)

        #expect(
            scene.depositionInvariantExpectations == [
                "familyAndAccumulationCorrect": true,
                "previewCommitMaximumDeltaWithinTolerance": true,
            ]
        )
    }

    @Test
    func fabricatedTelemetryCannotClaimACompletedNativeRun() throws {
        let evidence = DepositionSceneEvidence(
            schemaVersion: DepositionSceneEvidence.currentSchemaVersion,
            scene: "deposition-ink",
            definitionID: "builtin.native-ink",
            semanticHash: String(repeating: "a", count: 64),
            pipelineKey:
                "deposition:flow:none:s0:g0:h0:d0:abi1:format80:samples1",
            abiVersion: DepositionABI.version,
            resourceBytes: 5_461,
            textureLevels: ["builtin.shape.hard-round": 7],
            logicalDabCount: 4,
            projectedInstanceCount: 4,
            canonicalSHA256: String(repeating: "b", count: 64),
            cpuReferenceSHA256: nil,
            maximumCPUGPUChannelDelta: nil,
            previewCommitMaximumChannelDelta: 0,
            telemetry: DepositionTelemetryEvidence(
                authoritativeBacklog: 1,
                predictedBacklog: 0,
                backlogHighWater: 1,
                encodedInstanceCount: 3,
                bufferHighWater: 0,
                missedFrameCount: 9
            ),
            invariantResults: [
                "previewCommitMaximumDeltaWithinTolerance": true,
            ]
        )

        #expect(throws: DepositionEvidenceValidationError.self) {
            try DepositionEvidenceValidator.validate(evidence)
        }
    }

    @Test
    @MainActor
    func nativeInkRunCompilesActivatesRendersAndWritesEvidence()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try depositionHarnessTestLibrary(device: device)
        let scene = try repositoryScene(
            named: "deposition-ink"
        )
        let output = temporaryDirectory(
            named: "native-ink"
        )
        defer { try? FileManager.default.removeItem(at: output) }

        let result = try await depositionHarnessRunner(
            device: device,
            library: library
        ).run(
            scene: scene,
            outputDirectory: output,
            build: BenchmarkBuild(
                configuration: "Testing",
                gitCommit: String(repeating: "a", count: 40)
            )
        )
        let evidenceURL = output.appendingPathComponent(
            "deposition-ink.deposition-evidence.json"
        )
        let evidence = try DepositionSceneEvidence.decode(
            Data(contentsOf: evidenceURL)
        )

        #expect(result.imageURL.lastPathComponent == "deposition-ink.live.png")
        #expect(result.artifactURLs.count == 6)
        #expect(evidence.scene == "deposition-ink")
        #expect(evidence.definitionID == "builtin.native-ink")
        #expect(evidence.abiVersion == DepositionABI.version)
        #expect(evidence.logicalDabCount > 0)
        #expect(evidence.projectedInstanceCount >= evidence.logicalDabCount)
        #expect(evidence.canonicalSHA256 != String(repeating: "0", count: 64))
        #expect(evidence.cpuReferenceSHA256 != nil)
        #expect(evidence.maximumCPUGPUChannelDelta != nil)
        #expect(evidence.invariantResults.values.allSatisfy { $0 })
        #expect(
            Set(result.artifactURLs.map(\.lastPathComponent)) == [
                "deposition-ink.live.png",
                "deposition-ink.committed.png",
                "deposition-ink.canonical.png",
                "deposition-ink.cpu-reference.png",
                "deposition-ink.deposition-evidence.json",
                "deposition-ink.benchmark.json",
            ]
        )
    }

    @Test
    @MainActor
    func pairedNegativeControlFailsItsSingleAuthoritativeExpectation()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try depositionHarnessTestLibrary(device: device)
        let scene = try repositoryScene(
            named: "deposition-ink-negative-control"
        )
        let output = temporaryDirectory(
            named: "native-ink-negative"
        )
        defer { try? FileManager.default.removeItem(at: output) }

        await #expect(throws: DepositionEvidenceValidationError.self) {
            _ = try await depositionHarnessRunner(
                device: device,
                library: library
            ).run(
                scene: scene,
                outputDirectory: output,
                build: BenchmarkBuild(
                    configuration: "Testing",
                    gitCommit: String(repeating: "a", count: 40)
                )
            )
        }
    }

    @Test(arguments: DepositionEvidenceValidator.positiveSceneNames)
    @MainActor
    func everyPositiveSceneProducesValidNativeEvidence(
        _ name: String
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let output = temporaryDirectory(named: name)
        defer { try? FileManager.default.removeItem(at: output) }

        _ = try await depositionHarnessRunner(
            device: device,
            library: depositionHarnessTestLibrary(device: device)
        ).run(
            scene: repositoryScene(named: name),
            outputDirectory: output,
            build: BenchmarkBuild(
                configuration: "Testing",
                gitCommit: String(repeating: "b", count: 40)
            )
        )
        let evidence = try DepositionSceneEvidence.decode(
            Data(
                contentsOf: output.appendingPathComponent(
                    "\(name).deposition-evidence.json"
                )
            )
        )

        try DepositionEvidenceValidator.validate(evidence)
        #expect(evidence.invariantResults.values.allSatisfy { $0 })
    }

    @Test(arguments: DepositionEvidenceValidator.negativeSceneNames)
    @MainActor
    func everyPairedNegativeFailsItsSingleExpectation(
        _ name: String
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let output = temporaryDirectory(named: name)
        defer { try? FileManager.default.removeItem(at: output) }

        await #expect(throws: DepositionEvidenceValidationError.self) {
            _ = try await depositionHarnessRunner(
                device: device,
                library: depositionHarnessTestLibrary(device: device)
            ).run(
                scene: repositoryScene(named: name),
                outputDirectory: output,
                build: BenchmarkBuild(
                    configuration: "Testing",
                    gitCommit: String(repeating: "b", count: 40)
                )
            )
        }
    }

    @Test
    @MainActor
    func sixAnchorScenesUseExactProductionCatalogDefinitions() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try depositionHarnessTestLibrary(device: device)
        let fixtures: [(String, AnchorBrushEntry)] = [
            ("deposition-airbrush", AnchorBrushCatalog.airbrush),
            ("deposition-dry", AnchorBrushCatalog.dryMedia),
            ("deposition-erase", AnchorBrushCatalog.eraser),
            ("deposition-glaze", AnchorBrushCatalog.glaze),
            ("deposition-ink", AnchorBrushCatalog.ink),
            ("deposition-marker", AnchorBrushCatalog.marker),
        ]

        for (sceneName, anchor) in fixtures {
            let output = temporaryDirectory(
                named: "production-anchor-\(sceneName)"
            )
            defer { try? FileManager.default.removeItem(at: output) }
            _ = try await depositionHarnessRunner(
                device: device,
                library: library
            ).run(
                scene: repositoryScene(named: sceneName),
                outputDirectory: output,
                build: BenchmarkBuild(
                    configuration: "Testing",
                    gitCommit: String(repeating: "c", count: 40)
                )
            )
            let evidence = try DepositionSceneEvidence.decode(
                Data(
                    contentsOf: output.appendingPathComponent(
                        "\(sceneName).deposition-evidence.json"
                    )
                )
            )
            let package = try BrushPackage(
                manifest: BrushPackageManifest(resources: []),
                definition: anchor.definition,
                resourceData: [:]
            )
            let expectedSemanticHash = try package.contentHash

            #expect(evidence.definitionID == anchor.id.rawValue)
            #expect(evidence.semanticHash == expectedSemanticHash)
            #expect(
                StageFourEvidenceValidator.expectedSemanticHash(
                    forPositiveScene: sceneName
                ) == expectedSemanticHash
            )
            #expect(
                evidence.invariantResults[
                    "productionAnchorIdentityExact"
                ] == true
            )
        }
    }

    @Test(arguments: [
        (
            "deposition-ink",
            "strokePipelinePreparationUnchanged"
        ),
        (
            "deposition-failure-matrix",
            "failureStartsFromNonemptyExactHistory"
        ),
        (
            "deposition-failure-matrix",
            "pipelineFailureUsesSeededRenderer"
        ),
        (
            "deposition-layer-matrix",
            "layerCartesianRenderDistinct"
        ),
        (
            "deposition-cache-pinning",
            "activeBrushSurvivesPressureAndFailure"
        ),
    ])
    @MainActor
    func strengthenedEvidenceGuaranteeIsObservable(
        _ sceneName: String,
        _ invariant: String
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let output = temporaryDirectory(
            named: "strengthened-\(sceneName)-\(invariant)"
        )
        defer { try? FileManager.default.removeItem(at: output) }

        _ = try await depositionHarnessRunner(
            device: device,
            library: depositionHarnessTestLibrary(device: device)
        ).run(
            scene: repositoryScene(named: sceneName),
            outputDirectory: output,
            build: BenchmarkBuild(
                configuration: "Testing",
                gitCommit: String(repeating: "d", count: 40)
            )
        )
        let evidence = try DepositionSceneEvidence.decode(
            Data(
                contentsOf: output.appendingPathComponent(
                    "\(sceneName).deposition-evidence.json"
                )
            )
        )

        #expect(evidence.invariantResults[invariant] == true)
    }
}

private func repositorySceneDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("App/PatternSpike/Harness/Scenes")
}

func repositoryScene(named name: String) throws -> HarnessScene {
    try HarnessScene.decode(
        Data(
            contentsOf: repositorySceneDirectory()
                .appendingPathComponent("\(name).json")
        )
    )
}

func temporaryDirectory(named name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "laya-deposition-\(name)-\(UUID().uuidString)",
        isDirectory: true
    )
}

@MainActor
func depositionHarnessRunner(
    device: any MTLDevice,
    library: any MTLLibrary
) -> DepositionHarnessRunner {
    DepositionHarnessRunner(
        device: device,
        library: library,
        productionAnchorDefinitions: [
            "deposition-airbrush": AnchorBrushCatalog.airbrush.definition,
            "deposition-dry": AnchorBrushCatalog.dryMedia.definition,
            "deposition-erase": AnchorBrushCatalog.eraser.definition,
            "deposition-glaze": AnchorBrushCatalog.glaze.definition,
            "deposition-ink": AnchorBrushCatalog.ink.definition,
            "deposition-marker": AnchorBrushCatalog.marker.definition,
        ]
    )
}

@MainActor
func depositionHarnessTestLibrary(
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
