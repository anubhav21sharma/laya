import BrushFormat
import CShaderTypes
import Foundation
import PatternEngine

enum SceneArtifactValidator {
    private static let evidenceKeys: Set<String> = [
        "schemaVersion", "scene", "family", "definitionID",
        "definitionSemanticHash", "pipelineKey", "abiVersion",
        "residentResourceBytes", "resolvedResources",
        "logicalDabCount", "projectedInstanceCount",
        "livePNGSHA256", "committedPNGSHA256",
        "canonicalPNGSHA256", "characterizationSHA256",
        "rendererExecutableSHA256",
        "previewCommitMaximumChannelDelta", "compilerCounters",
        "telemetry", "observations", "invariantResults",
    ]
    private static let observationKeys: Set<String> = [
        "liveBGRA8SHA256", "committedBGRA8SHA256",
        "canonicalBGRA8SHA256", "liveNontransparentPixelCount",
        "committedNontransparentPixelCount",
        "canonicalNontransparentPixelCount",
        "predictionOffBGRA8SHA256", "predictionOnBGRA8SHA256",
        "predictionMaximumChannelDelta", "gridOriginBGRA8SHA256",
        "gridTranslatedBGRA8SHA256", "gridMaximumChannelDelta",
        "eraserBeforeBGRA8SHA256", "eraserAfterBGRA8SHA256",
        "eraserBeforeNontransparentPixelCount",
        "eraserAfterNontransparentPixelCount",
        "eraserReducedAlphaPixelCount",
        "radialRotationRenderedBGRA8SHA256",
        "radialRotationReferenceBGRA8SHA256",
        "radialRotationMaximumChannelDelta",
        "radialReflectionRenderedBGRA8SHA256",
        "radialReflectionReferenceBGRA8SHA256",
        "radialReflectionMaximumChannelDelta", "replayMode",
        "replayMaximumSamples", "replayMaximumDabs",
        "replayMaximumProjectedInstances",
        "pipelinePrepareCallCountBeforeStroke",
        "pipelinePrepareCallCountAfterStroke",
    ]
    static let benchmarkKeys: Set<String> = [
        "schemaVersion", "timestampUTC", "sceneName", "program",
        "hardware", "operatingSystem", "build", "frameCount",
        "cpuEncodeMilliseconds", "gpuMilliseconds",
        "peakResidentBytes", "newInstanceCounts", "missedFrameCount",
        "totalProjectedFragmentCount", "totalInstanceBytes",
        "previewCommitViolationCount", "recipeID", "seed",
        "replayMode", "assetResidentBytes", "logicalDabDigest",
        "canonicalBGRA8Digest", "logicalDabCount",
    ]
    private static let artifactFiles: Set<String> = [
        "benchmark.json", "canonical.png", "characterization.json",
        "committed.png", "eraser-after.png", "eraser-before.png",
        "evidence.json", "grid-origin.png", "grid-translated.png",
        "live.png", "prediction-off.png", "prediction-on.png",
        "radial-reflection-reference.png",
        "radial-reflection-rendered.png",
        "radial-rotation-reference.png",
        "radial-rotation-rendered.png",
    ]

    static func validatePositive(
        root: URL,
        expectedCommit: String,
        expectedGPUName: String,
        expectedOperatingSystem: String,
        expectedRendererSHA256: String,
        baseline: ProfessionalBrushLogicalBaseline
    ) throws -> Double {
        guard try ArtifactFileSystem.entryNames(root)
                == Set(ProfessionalBrushTruth.positiveSceneNames)
        else {
            throw ArtifactFileSystem.invalid(
                "positive artifact set is not the exact four-scene set"
            )
        }
        var p95Values: [Double] = []
        for scene in ProfessionalBrushTruth.positiveSceneNames {
            let directory = root.appendingPathComponent(scene)
            guard try ArtifactFileSystem.entryNames(directory)
                    == artifactFiles
            else {
                throw ArtifactFileSystem.invalid(
                    "\(scene) artifact file set is not exact"
                )
            }
            let evidence = try decodeEvidence(
                directory: directory,
                scene: scene,
                expectedRendererSHA256: expectedRendererSHA256
            )
            let characterizationData =
                try ArtifactFileSystem.regularFileData(
                    directory.appendingPathComponent(
                        "characterization.json"
                    ),
                    label: "\(scene) characterization"
                )
            guard ArtifactFileSystem.sha256(characterizationData)
                    == evidence.characterizationSHA256
            else {
                throw ArtifactFileSystem.invalid(
                    "\(scene) characterization digest changed"
                )
            }
            let characterization =
                try CharacterizationValidator.decodeRecord(
                    characterizationData,
                    label: "\(scene) characterization"
                )
            guard characterization.traceName
                    == "professional-slow-line",
                  characterization.brushID == evidence.definitionID,
                  characterization.family == evidence.family,
                  characterization.definitionSemanticHash
                    == evidence.definitionSemanticHash,
                  baseline.records.contains(characterization)
            else {
                throw ArtifactFileSystem.invalid(
                    "\(scene) renderer characterization is not an exact baseline member"
                )
            }
            let benchmarkData = try ArtifactFileSystem.regularFileData(
                directory.appendingPathComponent("benchmark.json"),
                label: "\(scene) benchmark"
            )
            try validateBenchmarkKeys(benchmarkData, label: scene)
            let benchmark: ProfessionalBenchmark
            do {
                benchmark = try JSONDecoder().decode(
                    ProfessionalBenchmark.self,
                    from: benchmarkData
                )
            } catch {
                throw ArtifactFileSystem.invalid(
                    "\(scene) benchmark is malformed"
                )
            }
            try validateBenchmark(
                benchmark,
                scene: scene,
                evidence: evidence,
                characterization: characterization,
                expectedCommit: expectedCommit,
                expectedGPUName: expectedGPUName,
                expectedOperatingSystem: expectedOperatingSystem
            )
            p95Values.append(
                percentile95(benchmark.cpuEncodeMilliseconds)
            )
        }
        guard let maximum = p95Values.max(), maximum < 2 else {
            throw ArtifactFileSystem.invalid(
                "professional CPU preparation p95 is not below 2 ms"
            )
        }
        return maximum
    }

    static func validateNegative(root: URL) throws {
        guard try ArtifactFileSystem.entryNames(root)
                == Set(ProfessionalBrushTruth.positiveSceneNames)
        else {
            throw ArtifactFileSystem.invalid(
                "negative-control artifacts are not the exact scene set"
            )
        }
        for scene in ProfessionalBrushTruth.positiveSceneNames {
            let directory = root.appendingPathComponent(scene)
            guard try ArtifactFileSystem.entryNames(directory) == [
                "exit-status.txt", "stderr.log", "stdout.log",
            ] else {
                throw ArtifactFileSystem.invalid(
                    "\(scene) negative-control file set is not exact"
                )
            }
            let status = try ArtifactFileSystem.regularFileData(
                directory.appendingPathComponent("exit-status.txt"),
                label: "\(scene) negative exit"
            )
            let stdout = try ArtifactFileSystem.regularFileData(
                directory.appendingPathComponent("stdout.log"),
                label: "\(scene) negative stdout"
            )
            let stderr = try ArtifactFileSystem.regularFileData(
                directory.appendingPathComponent("stderr.log"),
                label: "\(scene) negative stderr"
            )
            let expected =
                "HARNESS FAIL \(scene)-negative-control expectation 'professionalDefinitionIdentityExact' did not match\n"
            guard status == Data("1\n".utf8),
                  stdout.isEmpty,
                  stderr == Data(expected.utf8)
            else {
                throw ArtifactFileSystem.invalid(
                    "\(scene) negative control did not fail closed exactly"
                )
            }
        }
    }

    private static func decodeEvidence(
        directory: URL,
        scene: String,
        expectedRendererSHA256: String
    ) throws -> SceneEvidence {
        let data = try ArtifactFileSystem.regularFileData(
            directory.appendingPathComponent("evidence.json"),
            label: "\(scene) evidence"
        )
        let object = try ArtifactFileSystem.jsonObject(
            data,
            label: "\(scene) evidence"
        )
        try ArtifactFileSystem.requireExactKeys(
            object,
            evidenceKeys,
            label: "\(scene) evidence"
        )
        try validateEvidenceNestedKeys(object, label: scene)
        let evidence: SceneEvidence
        do {
            evidence = try JSONDecoder().decode(SceneEvidence.self, from: data)
        } catch {
            throw ArtifactFileSystem.invalid(
                "\(scene) evidence is malformed"
            )
        }
        guard let truth = ProfessionalBrushTruth.sceneTruth[scene],
              evidence.schemaVersion == 2,
              evidence.scene == scene,
              evidence.family == truth.family,
              evidence.definitionID == truth.definitionID,
              evidence.definitionSemanticHash == truth.semanticHash,
              evidence.pipelineKey == truth.pipelineKey,
              evidence.abiVersion == 1,
              evidence.residentResourceBytes == truth.residentBytes,
              evidence.logicalDabCount > 0,
              evidence.projectedInstanceCount >= evidence.logicalDabCount,
              evidence.previewCommitMaximumChannelDelta >= 0,
              evidence.previewCommitMaximumChannelDelta <= 1,
              evidence.rendererExecutableSHA256
                == expectedRendererSHA256
        else {
            throw ArtifactFileSystem.invalid(
                "\(scene) evidence identity, pipeline, or executable is invalid"
            )
        }
        try validateResources(evidence, truth: truth, scene: scene)
        try validateNumericBounds(evidence, truth: truth, scene: scene)
        let rasters = try loadRasters(directory: directory, scene: scene)
        try validatePNGHashes(
            directory: directory,
            scene: scene,
            evidence: evidence
        )
        let derived = try deriveInvariants(
            evidence,
            truth: truth,
            rasters: rasters
        )
        guard derived.values.allSatisfy({ $0 }),
              evidence.invariantResults == derived
        else {
            throw ArtifactFileSystem.invalid(
                "\(scene) claimed invariants disagree with raw artifacts"
            )
        }
        return evidence
    }

    private static func validateResources(
        _ evidence: SceneEvidence,
        truth: ProfessionalSceneTruth,
        scene: String
    ) throws {
        let names = evidence.resolvedResources.map(\.identity)
        let levels = Dictionary(
            uniqueKeysWithValues: evidence.resolvedResources.map {
                ($0.identity, $0.mipCount)
            }
        )
        guard names == names.sorted(),
              Set(names).count == names.count,
              levels == truth.resourceLevels,
              evidence.resolvedResources.allSatisfy({
                  $0.mipCount > 0
                      && ($0.kind == "shape"
                          ? $0.identity.hasPrefix("builtin.shape.")
                          : $0.kind == "grain"
                            && $0.identity.hasPrefix("builtin.grain."))
              })
        else {
            throw ArtifactFileSystem.invalid(
                "\(scene) resolved resource set is not exact"
            )
        }
    }

    private static func loadRasters(
        directory: URL,
        scene: String
    ) throws -> [String: [UInt8]] {
        let names = artifactFiles.filter { $0.hasSuffix(".png") }
        return try Dictionary(uniqueKeysWithValues: names.map { name in
            let data = try ArtifactFileSystem.regularFileData(
                directory.appendingPathComponent(name),
                label: "\(scene) \(name)"
            )
            let raster = try RasterObservationValidator.decode(
                data,
                label: "\(scene) \(name)"
            )
            return (name, raster.bgra)
        })
    }

    private static func validatePNGHashes(
        directory: URL,
        scene: String,
        evidence: SceneEvidence
    ) throws {
        for (name, hash) in [
            ("live.png", evidence.livePNGSHA256),
            ("committed.png", evidence.committedPNGSHA256),
            ("canonical.png", evidence.canonicalPNGSHA256),
        ] {
            let data = try ArtifactFileSystem.regularFileData(
                directory.appendingPathComponent(name),
                label: "\(scene) \(name)"
            )
            guard ArtifactFileSystem.sha256(data) == hash else {
                throw ArtifactFileSystem.invalid(
                    "\(scene) \(name) digest changed"
                )
            }
        }
    }

    private static func deriveInvariants(
        _ evidence: SceneEvidence,
        truth: ProfessionalSceneTruth,
        rasters: [String: [UInt8]]
    ) throws -> [String: Bool] {
        func bytes(_ name: String) throws -> [UInt8] {
            guard let value = rasters[name] else {
                throw ArtifactFileSystem.invalid("missing raster \(name)")
            }
            return value
        }
        let live = try bytes("live.png")
        let committed = try bytes("committed.png")
        let canonical = try bytes("canonical.png")
        let predictionOff = try bytes("prediction-off.png")
        let predictionOn = try bytes("prediction-on.png")
        let gridOrigin = try bytes("grid-origin.png")
        let gridTranslated = try bytes("grid-translated.png")
        let eraserBefore = try bytes("eraser-before.png")
        let eraserAfter = try bytes("eraser-after.png")
        let rotationRendered = try bytes(
            "radial-rotation-rendered.png"
        )
        let rotationReference = try bytes(
            "radial-rotation-reference.png"
        )
        let reflectionRendered = try bytes(
            "radial-reflection-rendered.png"
        )
        let reflectionReference = try bytes(
            "radial-reflection-reference.png"
        )
        let observation = evidence.observations
        let hashesMatch = [
            (live, observation.liveBGRA8SHA256),
            (committed, observation.committedBGRA8SHA256),
            (canonical, observation.canonicalBGRA8SHA256),
            (predictionOff, observation.predictionOffBGRA8SHA256),
            (predictionOn, observation.predictionOnBGRA8SHA256),
            (gridOrigin, observation.gridOriginBGRA8SHA256),
            (gridTranslated, observation.gridTranslatedBGRA8SHA256),
            (eraserBefore, observation.eraserBeforeBGRA8SHA256),
            (eraserAfter, observation.eraserAfterBGRA8SHA256),
            (
                rotationRendered,
                observation.radialRotationRenderedBGRA8SHA256
            ),
            (
                rotationReference,
                observation.radialRotationReferenceBGRA8SHA256
            ),
            (
                reflectionRendered,
                observation.radialReflectionRenderedBGRA8SHA256
            ),
            (
                reflectionReference,
                observation.radialReflectionReferenceBGRA8SHA256
            ),
        ].allSatisfy {
            ArtifactFileSystem.sha256(Data($0.0)) == $0.1
        }
        let predictionDelta = RasterObservationValidator
            .maximumChannelDelta(predictionOff, predictionOn)
        let previewCommitDelta = RasterObservationValidator
            .maximumChannelDelta(live, committed)
        let gridDelta = RasterObservationValidator.maximumChannelDelta(
            gridOrigin,
            gridTranslated
        )
        let rotationDelta = RasterObservationValidator.maximumChannelDelta(
            rotationRendered,
            rotationReference
        )
        let reflectionDelta = RasterObservationValidator
            .maximumChannelDelta(
                reflectionRendered,
                reflectionReference
            )
        let eraserReduced =
            RasterObservationValidator.reducedAlphaPixelCount(
                before: eraserBefore,
                after: eraserAfter
            )
        let countsMatch =
            RasterObservationValidator.nontransparentPixelCount(live)
                == observation.liveNontransparentPixelCount
            && RasterObservationValidator.nontransparentPixelCount(committed)
                == observation.committedNontransparentPixelCount
            && RasterObservationValidator.nontransparentPixelCount(canonical)
                == observation.canonicalNontransparentPixelCount
            && RasterObservationValidator.nontransparentPixelCount(
                eraserBefore
            ) == observation.eraserBeforeNontransparentPixelCount
            && RasterObservationValidator.nontransparentPixelCount(
                eraserAfter
            ) == observation.eraserAfterNontransparentPixelCount
            && eraserReduced == observation.eraserReducedAlphaPixelCount
        let deltasMatch =
            predictionDelta == observation.predictionMaximumChannelDelta
            && gridDelta == observation.gridMaximumChannelDelta
            && rotationDelta
                == observation.radialRotationMaximumChannelDelta
            && reflectionDelta
                == observation.radialReflectionMaximumChannelDelta
        let previewCommitMatches =
            previewCommitDelta <= 1
            && previewCommitDelta
                == evidence.previewCommitMaximumChannelDelta
        let uploads = UInt64(truth.resourceLevels.count)
        let compiled = CompilerCounterSnapshot(
            packageDecodeCount: 1,
            imageDecodeCount: 0,
            textureUploadCount: uploads,
            cacheHitCount: 0,
            activationCount: 1
        )
        let cached = CompilerCounterSnapshot(
            packageDecodeCount: 2,
            imageDecodeCount: 0,
            textureUploadCount: uploads,
            cacheHitCount: uploads,
            activationCount: 2
        )
        let counters = evidence.compilerCounters
        let telemetry = evidence.telemetry
        return [
            "boundedLiveWork":
                observation.replayMode == "replayTail"
                && observation.replayMaximumSamples == 256
                && observation.replayMaximumDabs == 2_048
                && observation.replayMaximumProjectedInstances == 4_096
                && evidence.logicalDabCount <= 2_048
                && evidence.projectedInstanceCount <= 4_096
                && telemetry.authoritativeBacklog == 0
                && telemetry.predictedBacklog == 0
                && telemetry.backlogHighWater > 0
                && telemetry.backlogHighWater
                    <= evidence.projectedInstanceCount,
            "destinationOutEraserCompatible":
                hashesMatch && countsMatch && eraserReduced > 0
                && eraserBefore != eraserAfter,
            "nonemptyVisibleOutput":
                countsMatch
                && observation.liveNontransparentPixelCount > 0
                && observation.committedNontransparentPixelCount > 0
                && observation.canonicalNontransparentPixelCount > 0,
            "predictionOnOffEqual":
                hashesMatch && deltasMatch && predictionDelta == 0,
            "previewCommitMaximumDeltaWithinTolerance":
                previewCommitMatches,
            "professionalDefinitionIdentityExact": true,
            "radialRotationAndReflectionCorrect":
                hashesMatch && deltasMatch
                && rotationDelta <= 8 && reflectionDelta <= 8,
            "resolvedResourcesAndMipsExact": true,
            "strokeCompilerCacheCountersUnchanged":
                counters.beforeCompile == .zero
                && counters.afterCompile == compiled
                && counters.afterCacheHit == cached
                && counters.beforeStroke == cached
                && counters.afterStroke == cached
                && observation.pipelinePrepareCallCountBeforeStroke
                    == observation.pipelinePrepareCallCountAfterStroke,
            "tilingPeriodTranslationEqual":
                hashesMatch && deltasMatch && gridDelta == 0,
        ]
    }

    private static func validateNumericBounds(
        _ evidence: SceneEvidence,
        truth: ProfessionalSceneTruth,
        scene: String
    ) throws {
        guard evidence.logicalDabCount <= 2_048,
              evidence.projectedInstanceCount <= 4_096,
              let projected = UInt64(
                  exactly: evidence.projectedInstanceCount
              ),
              (1 ... projected).contains(
                  evidence.telemetry.encodedInstanceCount
              ),
              (1 ... 3).contains(evidence.telemetry.bufferHighWater),
              evidence.telemetry.missedFrameCount == 0,
              evidence.telemetry.authoritativeBacklog == 0,
              evidence.telemetry.predictedBacklog == 0,
              (1 ... evidence.projectedInstanceCount).contains(
                  evidence.telemetry.backlogHighWater
              ),
              (0 ... 2).contains(
                  evidence.observations
                    .pipelinePrepareCallCountBeforeStroke
              ),
              (0 ... 2).contains(
                  evidence.observations
                    .pipelinePrepareCallCountAfterStroke
              )
        else {
            throw ArtifactFileSystem.invalid(
                "\(scene) evidence counters are negative, zero, or outside runtime bounds: "
                    + "logical=\(evidence.logicalDabCount) "
                    + "projected=\(evidence.projectedInstanceCount) "
                    + "encoded=\(evidence.telemetry.encodedInstanceCount) "
                    + "buffer=\(evidence.telemetry.bufferHighWater) "
                    + "missed=\(evidence.telemetry.missedFrameCount) "
                    + "backlog=\(evidence.telemetry.backlogHighWater) "
                    + "pipeline=\(evidence.observations.pipelinePrepareCallCountBeforeStroke)/"
                    + "\(evidence.observations.pipelinePrepareCallCountAfterStroke)"
            )
        }

        let resourceCount = UInt64(truth.resourceLevels.count)
        let snapshots = [
            evidence.compilerCounters.beforeCompile,
            evidence.compilerCounters.afterCompile,
            evidence.compilerCounters.afterCacheHit,
            evidence.compilerCounters.beforeStroke,
            evidence.compilerCounters.afterStroke,
        ]
        guard snapshots.allSatisfy({
            $0.packageDecodeCount <= 2
                && $0.imageDecodeCount == 0
                && $0.textureUploadCount <= resourceCount
                && $0.cacheHitCount <= resourceCount
                && $0.activationCount <= 2
        }) else {
            throw ArtifactFileSystem.invalid(
                "\(scene) compiler counters exceed applicable totals"
            )
        }
    }

    private static func validateBenchmark(
        _ benchmark: ProfessionalBenchmark,
        scene: String,
        evidence: SceneEvidence,
        characterization: ProfessionalBrushCharacterizationRecord,
        expectedCommit: String,
        expectedGPUName: String,
        expectedOperatingSystem: String
    ) throws {
        guard benchmark.schemaVersion == 3,
              benchmark.timestampUTC == "1970-01-01T00:00:00Z",
              benchmark.sceneName == scene,
              benchmark.program == "professionalNativeDeposition",
              benchmark.hardware.gpuName == expectedGPUName,
              benchmark.hardware.logicalProcessorCount > 0,
              benchmark.hardware.physicalMemoryBytes > 0,
              benchmark.operatingSystem == expectedOperatingSystem,
              benchmark.build.configuration == "Debug",
              benchmark.build.gitCommit == expectedCommit,
              benchmark.frameCount > 0,
              benchmark.cpuEncodeMilliseconds.count
                == benchmark.frameCount,
              benchmark.gpuMilliseconds.count == benchmark.frameCount,
              validDurations(benchmark.cpuEncodeMilliseconds),
              validDurations(benchmark.gpuMilliseconds),
              benchmark.peakResidentBytes
                == UInt64(evidence.residentResourceBytes),
              benchmark.newInstanceCounts
                == [evidence.projectedInstanceCount],
              benchmark.missedFrameCount
                == Int(evidence.telemetry.missedFrameCount),
              benchmark.totalProjectedFragmentCount
                == evidence.projectedInstanceCount,
              benchmark.totalInstanceBytes
                == evidence.projectedInstanceCount
                    * MemoryLayout<PatternDepositionStampInstance>.stride,
              benchmark.previewCommitViolationCount == 0,
              benchmark.recipeID == evidence.definitionID,
              benchmark.seed == 0x4c_41_59_41,
              benchmark.replayMode == "replayTail",
              benchmark.assetResidentBytes
                == evidence.residentResourceBytes,
              benchmark.logicalDabDigest
                == characterization.logicalDabDigest,
              benchmark.canonicalBGRA8Digest
                == evidence.observations.canonicalBGRA8SHA256,
              benchmark.logicalDabCount == evidence.logicalDabCount
        else {
            throw ArtifactFileSystem.invalid(
                "\(scene) benchmark does not bind exact evidence, runtime, and replay semantics"
            )
        }
    }

    private static func validateEvidenceNestedKeys(
        _ object: [String: Any],
        label: String
    ) throws {
        guard let resources =
                object["resolvedResources"] as? [[String: Any]],
              let compiler =
                object["compilerCounters"] as? [String: Any],
              let telemetry = object["telemetry"] as? [String: Any],
              let observations =
                object["observations"] as? [String: Any]
        else {
            throw ArtifactFileSystem.invalid(
                "\(label) evidence nested values are malformed"
            )
        }
        guard resources.allSatisfy({
            Set($0.keys) == ["identity", "kind", "mipCount"]
        }) else {
            throw ArtifactFileSystem.invalid(
                "\(label) resource keys are not exact"
            )
        }
        try ArtifactFileSystem.requireExactKeys(
            compiler,
            [
                "beforeCompile", "afterCompile", "afterCacheHit",
                "beforeStroke", "afterStroke",
            ],
            label: "\(label) compiler counters"
        )
        let snapshotKeys: Set<String> = [
            "packageDecodeCount", "imageDecodeCount",
            "textureUploadCount", "cacheHitCount", "activationCount",
        ]
        for value in compiler.values {
            guard let snapshot = value as? [String: Any] else {
                throw ArtifactFileSystem.invalid(
                    "\(label) compiler snapshot is malformed"
                )
            }
            try ArtifactFileSystem.requireExactKeys(
                snapshot,
                snapshotKeys,
                label: "\(label) compiler snapshot"
            )
        }
        try ArtifactFileSystem.requireExactKeys(
            telemetry,
            [
                "authoritativeBacklog", "predictedBacklog",
                "backlogHighWater", "encodedInstanceCount",
                "bufferHighWater", "missedFrameCount",
            ],
            label: "\(label) telemetry"
        )
        try ArtifactFileSystem.requireExactKeys(
            observations,
            observationKeys,
            label: "\(label) observations"
        )
        guard let invariants = object["invariantResults"]
                as? [String: Bool],
              Set(invariants.keys)
                == ProfessionalBrushTruth.requiredInvariantNames
        else {
            throw ArtifactFileSystem.invalid(
                "\(label) invariant result keys are not exact"
            )
        }
    }

    private static func validateBenchmarkKeys(
        _ data: Data,
        label: String
    ) throws {
        let object = try ArtifactFileSystem.jsonObject(data, label: label)
        try ArtifactFileSystem.requireExactKeys(
            object,
            benchmarkKeys,
            label: "\(label) benchmark"
        )
        guard let hardware = object["hardware"] as? [String: Any],
              let build = object["build"] as? [String: Any]
        else {
            throw ArtifactFileSystem.invalid(
                "\(label) benchmark nested values are malformed"
            )
        }
        try ArtifactFileSystem.requireExactKeys(
            hardware,
            [
                "gpuName", "logicalProcessorCount",
                "physicalMemoryBytes",
            ],
            label: "\(label) benchmark hardware"
        )
        try ArtifactFileSystem.requireExactKeys(
            build,
            ["configuration", "gitCommit"],
            label: "\(label) benchmark build"
        )
    }

    private static func validDurations(_ values: [Double]) -> Bool {
        !values.isEmpty && values.allSatisfy {
            $0.isFinite && $0 >= 0
        }
    }

    private static func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let index = max(
            0,
            Int(ceil(Double(sorted.count) * 0.95)) - 1
        )
        return sorted[index]
    }
}
