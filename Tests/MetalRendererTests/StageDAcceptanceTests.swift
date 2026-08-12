import Foundation
@preconcurrency import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Stage D acceptance evidence", .serialized)
struct StageDAcceptanceTests {
    @Test
    func productionRuntimeProfilesFreezeInputAndSteadyFrameInventories() {
        for profile in [
            StrokeRuntimeTraceProfile.productionTenSeconds,
            .productionAcceleratedTenMinutes,
        ] {
            #expect(profile.requiredMovedSampleCount == 600)
            #expect(profile.requiredLongStrokeFrameCount == 400)
            #expect(profile.requiredWallDurationNanoseconds == 10_000_000_000)
        }
    }

    @Test
    func packageSuiteLogRequiresOnePositiveIssueFreeSummary() throws {
        let counts = try StageDAcceptanceSuiteLogValidator.validate("""
        Test Suite 'Selected tests' passed.
        ◇ Test run started.
        ✔ Test run with 26 tests in 3 suites passed after 0.125 seconds.
        """)
        #expect(counts == .init(testCount: 26, suiteCount: 3))

        #expect(throws: StageDAcceptanceSuiteLogValidationError
            .missingPositivePassingSummary) {
            _ = try StageDAcceptanceSuiteLogValidator.validate(
                "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds."
            )
        }
        #expect(throws: StageDAcceptanceSuiteLogValidationError
            .runRecordedIssueOrFailure) {
            _ = try StageDAcceptanceSuiteLogValidator.validate("""
            ✘ Test example() recorded an issue.
            ✔ Test run with 1 test in 1 suite passed after 0.001 seconds.
            """)
        }
        #expect(throws: StageDAcceptanceSuiteLogValidationError
            .runRecordedIssueOrFailure) {
            _ = try StageDAcceptanceSuiteLogValidator.validate("""
            ✘ Test run with 1 test in 1 suite failed after 0.001 seconds.
            """)
        }
    }

    @Test
    func packageSuiteLogMustMatchReviewedExactInventory() throws {
        let reviewed = StageDAcceptanceSuiteCounts(
            testCount: 26,
            suiteCount: 3
        )
        let log = """
        ◇ Test run started.
        ✔ Test run with 26 tests in 3 suites passed after 0.125 seconds.
        """

        #expect(try StageDAcceptanceSuiteLogValidator.validate(
            log,
            expected: reviewed
        ) == reviewed)
        #expect(throws: StageDAcceptanceSuiteLogValidationError
            .unexpectedCounts(
                expected: reviewed,
                actual: .init(testCount: 1, suiteCount: 1)
            )) {
            _ = try StageDAcceptanceSuiteLogValidator.validate(
                "✔ Test run with 1 test in 1 suite passed after 0.001 seconds.",
                expected: reviewed
            )
        }
    }

    @Test
    func packageSuiteRequirementsMatchCurrentReviewedInventories() {
        #expect(
            StageDAcceptancePackageSuiteRequirements
                .expectedCountsByScenario
                == [
                    StageDAcceptanceRequirements.color:
                        .init(testCount: 26, suiteCount: 3),
                    StageDAcceptanceRequirements.sparseSampling:
                        .init(testCount: 220, suiteCount: 5),
                    StageDAcceptanceRequirements.strokeLifecycle:
                        .init(testCount: 189, suiteCount: 3),
                    StageDAcceptanceRequirements.modes:
                        .init(testCount: 51, suiteCount: 3),
                    StageDAcceptanceRequirements.layers:
                        .init(testCount: 35, suiteCount: 2),
                    StageDAcceptanceRequirements.persistenceExport:
                        .init(testCount: 36, suiteCount: 4),
                    StageDAcceptanceRequirements.negativeControls:
                        .init(testCount: 99, suiteCount: 4),
                ]
        )
        #expect(
            StageDAcceptancePackageSuiteRequirements.broadCounts
                == .init(testCount: 2_206, suiteCount: 120)
        )
        #expect(
            StageDAcceptancePackageSuiteRequirements.broadKnownIssueCount == 0
        )
    }

    @Test
    func allocationEvidenceParsesExactAnchoredProductionMetrics() throws {
        let log = """
        ALLOCATOR PROBE STAGE D TILES PASS partition=20/0 lease=13/0 metal_driver=10/233
        ALLOCATOR PROBE STAGE D SAMPLING PASS backends=directFallback,tier2ArgumentBuffer events=510 app_acquire=3060/max6 app_preflight=2040/max4 app_completion=0/max0 app_wait=0/max0 metal_submission=13771/max28 plan_bytes=[712, 4672] upload_bytes=[1536, 1536] draws=[2, 1]
        ALLOCATOR PROBE OFF-MAIN PASS application=0 workspace=0 main=0 authoritative=0 estimated=0 prediction=0 packaging=0 surface_metal_mallocs=5948 tile_partition=0 tile_lease=0
        ALLOCATOR PROBE PRODUCTION PASS allocations=0
        ALLOCATOR PROBE TEN-MINUTE TRACE PASS samples=36000 hot_allocations=0/0 lifecycle=41/0 cpu_ns=37956/34924 missed=0 zero_work=606/2649 deferred=605
        """
        let evidence = try StageDAllocationEvidenceValidator.validate(log)
        #expect(evidence.inputSampleCount == 36_000)
        #expect(evidence.partitionEventCount == 20)
        #expect(evidence.leaseEventCount == 13)
        #expect(evidence.metalDriverAllocationCount == 233)
        #expect(evidence.offMainSurfaceMetalAllocationCount == 5_948)
        #expect(evidence.firstDecileNanosecondsPerEvent == 37_956)
        #expect(evidence.lastDecileNanosecondsPerEvent == 34_924)
        #expect(evidence.zeroWorkLeaseCount == 606)
        #expect(evidence.maximumZeroWorkLeaseCount == 2_649)

        #expect(throws: StageDAllocationEvidenceValidationError
            .invalidField("sampling.app_acquire")) {
            _ = try StageDAllocationEvidenceValidator.validate(
                log.replacingOccurrences(
                    of: "app_acquire=3060/max6",
                    with: "app_acquire=3061/max6"
                )
            )
        }
        #expect(throws: StageDAllocationEvidenceValidationError
            .invalidField("sampling.app_acquire")) {
            _ = try StageDAllocationEvidenceValidator.validate(
                log.replacingOccurrences(
                    of: "app_acquire=3060/max6",
                    with: "app_acquire=0/max6"
                )
            )
        }
        #expect(throws: StageDAllocationEvidenceValidationError
            .invalidField("sampling.app_acquire")) {
            _ = try StageDAllocationEvidenceValidator.validate(
                log.replacingOccurrences(
                    of: "app_acquire=3060/max6",
                    with: "app_acquire=3060/max1"
                )
            )
        }
        #expect(throws: StageDAllocationEvidenceValidationError
            .invalidField("sampling.metal_submission")) {
            _ = try StageDAllocationEvidenceValidator.validate(
                log.replacingOccurrences(
                    of: "metal_submission=13771/max28",
                    with: "metal_submission=1/max28"
                )
            )
        }
        #expect(throws: StageDAllocationEvidenceValidationError
            .invalidField("sampling.metal_submission")) {
            _ = try StageDAllocationEvidenceValidator.validate(
                log.replacingOccurrences(
                    of: "metal_submission=13771/max28",
                    with: "metal_submission=13771/max1"
                )
            )
        }
        #expect(throws: StageDAllocationEvidenceValidationError
            .invalidField("sampling.app_preflight")) {
            _ = try StageDAllocationEvidenceValidator.validate(
                log.replacingOccurrences(
                    of: "app_preflight=2040/max4",
                    with: "app_preflight=2040/max5"
                )
            )
        }
        #expect(throws: StageDAllocationEvidenceValidationError
            .invalidField("sampling.app_completion")) {
            _ = try StageDAllocationEvidenceValidator.validate(
                log.replacingOccurrences(
                    of: "app_completion=0/max0",
                    with: "app_completion=1/max0"
                )
            )
        }

        #expect(throws: StageDAllocationEvidenceValidationError
            .invalidField("production.allocations")) {
            _ = try StageDAllocationEvidenceValidator.validate(
                log.replacingOccurrences(
                    of: "PRODUCTION PASS allocations=0",
                    with: "PRODUCTION PASS allocations=1"
                )
            )
        }
        #expect(throws: StageDAllocationEvidenceValidationError
            .duplicateLine("production")) {
            _ = try StageDAllocationEvidenceValidator.validate(
                log + "\nALLOCATOR PROBE PRODUCTION PASS allocations=0\n"
            )
        }
        #expect(throws: StageDAllocationEvidenceValidationError
            .invalidField("trace.samples")) {
            _ = try StageDAllocationEvidenceValidator.validate(
                log.replacingOccurrences(
                    of: "samples=36000",
                    with: "samples=35999"
                )
            )
        }
        #expect(throws: StageDAllocationEvidenceValidationError
            .invalidField("trace.zero_work")) {
            _ = try StageDAllocationEvidenceValidator.validate(
                log.replacingOccurrences(
                    of: "zero_work=606/2649",
                    with: "zero_work=2650/2649"
                )
            )
        }
    }

    @Test
    func broadAndReviewEvidenceFailClosed() throws {
        let commit = String(repeating: "a", count: 40)
        let counts = try StageDAcceptanceBroadSuiteEvidenceValidator.validate(
            suiteLog: """
            ✔ Test run with 2,206 tests in 120 suites passed after 1,982 seconds.
            """,
            baselineVerifierLog:
                "Swift Testing baseline verified: 0 complete issue records.",
            expectedCounts: .init(testCount: 2_206, suiteCount: 120),
            expectedIssueCount: 0
        )
        #expect(counts == .init(testCount: 2_206, suiteCount: 120))
        #expect(throws: StageDAcceptanceBroadSuiteValidationError
            .suiteDidNotPass) {
            _ = try StageDAcceptanceBroadSuiteEvidenceValidator.validate(
                suiteLog: """
                ✘ Test run with 2,206 tests in 120 suites failed after 1,982 seconds.
                """,
                baselineVerifierLog:
                    "Swift Testing baseline verified: 0 complete issue records.",
                expectedCounts: .init(testCount: 2_206, suiteCount: 120),
                expectedIssueCount: 0
            )
        }

        let review = StageDAcceptanceReviewDisposition(
            schemaVersion: 1,
            baseRevision: "ca5dff5",
            gitCommit: commit,
            reviewer: "independent-reviewer",
            criticalFindingCount: 0,
            importantFindingCount: 0
        )
        #expect(try StageDAcceptanceReviewDispositionValidator.validate(
            review,
            expectedBaseRevision: "ca5dff5",
            expectedGitCommit: commit
        ) == review)

        let unresolved = StageDAcceptanceReviewDisposition(
            schemaVersion: 1,
            baseRevision: "ca5dff5",
            gitCommit: commit,
            reviewer: "independent-reviewer",
            criticalFindingCount: 0,
            importantFindingCount: 1
        )
        #expect(throws: StageDAcceptanceReviewValidationError
            .unresolvedFindings(critical: 0, important: 1)) {
            _ = try StageDAcceptanceReviewDispositionValidator.validate(
                unresolved,
                expectedBaseRevision: "ca5dff5",
                expectedGitCommit: commit
            )
        }
    }

    @Test
    func twoRunEvidenceRequiresStableSemanticsAndNoResourceGrowth() throws {
        let commit = String(repeating: "b", count: 40)
        let reference = acceptanceRunManifest(
            commit: commit,
            semanticSuffix: "1",
            residentHighWater: 1_024
        )
        let identical = acceptanceRunManifest(
            commit: commit,
            semanticSuffix: "1",
            residentHighWater: 1_024
        )
        let result = try StageDAcceptanceRepeatabilityValidator.validate(
            reference: reference,
            candidate: identical
        )
        #expect(result.comparedSemanticHashCount == 5)
        #expect(result.comparedResourceMetricCount > 0)

        let changed = acceptanceRunManifest(
            commit: commit,
            semanticSuffix: "2",
            residentHighWater: 1_024
        )
        #expect(throws: StageDAcceptanceRepeatabilityError
            .semanticHashMismatch(StageDAcceptanceRequirements.runtimeWall)) {
            _ = try StageDAcceptanceRepeatabilityValidator.validate(
                reference: reference,
                candidate: changed
            )
        }

        let grown = acceptanceRunManifest(
            commit: commit,
            semanticSuffix: "1",
            residentHighWater: 2_048
        )
        #expect(throws: StageDAcceptanceRepeatabilityError.resourceGrowth(
            scenarioID: StageDAcceptanceRequirements.appControls,
            metric: "residentTileHighWaterBytes",
            reference: 1_024,
            candidate: 2_048
        )) {
            _ = try StageDAcceptanceRepeatabilityValidator.validate(
                reference: reference,
                candidate: grown
            )
        }
    }

    @Test
    func completeProductionManifestRoundTripsAndValidates() throws {
        let manifest = StageDAcceptanceManifest(
            generatedAt: Date(timeIntervalSince1970: 1_786_291_200),
            gitCommit: String(repeating: "a", count: 40),
            rows: StageDAcceptanceRequirements.requiredScenarioIDs.enumerated()
                .map { index, scenarioID in
                    row(
                        scenarioID: scenarioID,
                        producer: StageDAcceptanceRequirements
                            .producer(for: scenarioID),
                        seed: UInt64(index + 1)
                    )
                }
        )

        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(
            StageDAcceptanceManifest.self,
            from: encoded
        )
        let validated = try StageDAcceptanceManifestValidator.validate(decoded)

        #expect(validated == decoded)
        #expect(validated.rows.map(\.scenarioID).sorted()
            == StageDAcceptanceRequirements.requiredScenarioIDs.sorted())
    }

    @Test
    func manifestRejectsDuplicateMissingSkippedAndNonproductionRows() throws {
        let base = StageDAcceptanceRequirements.requiredScenarioIDs.enumerated()
            .map { index, scenarioID in
                row(
                    scenarioID: scenarioID,
                    producer: StageDAcceptanceRequirements
                        .producer(for: scenarioID),
                    seed: UInt64(index + 1)
                )
            }
        let header = (
            generatedAt: Date(timeIntervalSince1970: 1_786_291_200),
            gitCommit: String(repeating: "b", count: 40)
        )

        #expect(throws: StageDAcceptanceValidationError
            .duplicateScenarioID(base[0].scenarioID)) {
            _ = try StageDAcceptanceManifestValidator.validate(.init(
                generatedAt: header.generatedAt,
                gitCommit: header.gitCommit,
                rows: base + [base[0]]
            ))
        }

        #expect(throws: StageDAcceptanceValidationError
            .missingRequiredScenarioID(base.last!.scenarioID)) {
            _ = try StageDAcceptanceManifestValidator.validate(.init(
                generatedAt: header.generatedAt,
                gitCommit: header.gitCommit,
                rows: Array(base.dropLast())
            ))
        }

        let unexpectedScenarioID = "stage-d.unrecognized"
        #expect(throws: StageDAcceptanceValidationError
            .unexpectedScenarioID(unexpectedScenarioID)) {
            _ = try StageDAcceptanceManifestValidator.validate(.init(
                generatedAt: header.generatedAt,
                gitCommit: header.gitCommit,
                rows: base + [row(
                    scenarioID: unexpectedScenarioID,
                    producer: .packageHarness,
                    seed: 99
                )]
            ))
        }

        var skipped = base
        skipped[0] = row(
            scenarioID: skipped[0].scenarioID,
            producer: skipped[0].producer,
            seed: skipped[0].seed,
            status: .skipped
        )
        #expect(throws: StageDAcceptanceValidationError
            .scenarioDidNotPass(skipped[0].scenarioID, .skipped)) {
            _ = try StageDAcceptanceManifestValidator.validate(.init(
                generatedAt: header.generatedAt,
                gitCommit: header.gitCommit,
                rows: skipped
            ))
        }

        var software = base
        software[1] = row(
            scenarioID: software[1].scenarioID,
            producer: software[1].producer,
            seed: software[1].seed,
            backend: .softwareReference
        )
        #expect(throws: StageDAcceptanceValidationError
            .nonproductionBackend(software[1].scenarioID)) {
            _ = try StageDAcceptanceManifestValidator.validate(.init(
                generatedAt: header.generatedAt,
                gitCommit: header.gitCommit,
                rows: software
            ))
        }
    }

    @Test
    func manifestRejectsInvalidOracleAndNonfiniteMetric() throws {
        var base = StageDAcceptanceRequirements.requiredScenarioIDs.enumerated()
            .map { index, scenarioID in
                row(
                    scenarioID: scenarioID,
                    producer: StageDAcceptanceRequirements
                        .producer(for: scenarioID),
                    seed: UInt64(index + 1)
                )
            }
        let scenarioID = base[0].scenarioID
        base[0] = StageDAcceptanceRow(
            scenarioID: scenarioID,
            producer: base[0].producer,
            seed: base[0].seed,
            inputTrace: base[0].inputTrace,
            expectedSemanticHash: nil,
            numericOracle: nil,
            status: .passed,
            backend: .productionSparseMetal,
            metrics: [:]
        )
        let manifest = StageDAcceptanceManifest(
            generatedAt: Date(timeIntervalSince1970: 1_786_291_200),
            gitCommit: String(repeating: "c", count: 40),
            rows: base
        )
        #expect(throws: StageDAcceptanceValidationError
            .missingOracle(scenarioID)) {
            _ = try StageDAcceptanceManifestValidator.validate(manifest)
        }

        base[0] = row(
            scenarioID: scenarioID,
            producer: base[0].producer,
            seed: base[0].seed,
            metrics: ["p95": .infinity]
        )
        #expect(throws: StageDAcceptanceValidationError
            .nonfiniteMetric(scenarioID, "p95")) {
            _ = try StageDAcceptanceManifestValidator.validate(.init(
                generatedAt: manifest.generatedAt,
                gitCommit: manifest.gitCommit,
                rows: base
            ))
        }
    }

    @Test
    @MainActor
    func rendererAttestsProductionSparseQuiescentState() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary()
        else { return }
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 96, height: 80),
            configuration: TilingCanvasConfiguration(
                pixelSize: PixelSize(width: 96, height: 80),
                tiling: .grid
            )
        )

        let evidence = await renderer.stageDAcceptanceEvidence()

        #expect(evidence.backend == .productionSparseMetal)
        #expect(evidence.documentGeneration == 0)
        #expect(evidence.layerCount == 1)
        #expect(evidence.tileByteBudget > 0)
        #expect(evidence.residentTileBytes <= evidence.tileByteBudget)
        #expect(evidence.residentTileHighWaterBytes <= evidence.tileByteBudget)
        #expect(evidence.residentTileHighWaterBytes >= evidence.residentTileBytes)
        #expect(evidence.storageAuthority == .sparseRGBA16Float)
        #expect(evidence.tileIndexEntryCount == 0)
        #expect(evidence.cpuCachedPlanCount == 0)
        #expect(evidence.gpuCachedPlanCount == 0)
        #expect(evidence.cpuPlanCacheHitCount == 0)
        #expect(evidence.cpuPlanCacheMissCount == 0)
        #expect(evidence.gpuPlanCacheHitCount == 0)
        #expect(evidence.gpuPlanCacheMissCount == 0)
        #expect(evidence.cachedPlanMetalBufferBytes == 0)
        #expect(evidence.uploadRingMetalBufferBytes == 0)
        #expect(evidence.residentResourceBytes >= evidence.residentTileBytes)
        #expect(
            evidence.residentResourceHighWaterBytes
                >= evidence.residentResourceBytes
        )
        #expect(evidence.activeUploadSlotCount == 0)
        #expect(evidence.pendingPlanCompletionCount == 0)
        #expect(evidence.pendingConsumerCompletionCount == 0)
        #expect(evidence.activeSnapshotTokenCount == 0)
        #expect(evidence.retainedDisplaySnapshotTokenCount == 0)
        #expect(evidence.retainedHistorySnapshotTokenCount == 0)
        #expect(evidence.pendingOwnershipCount == 0)
        #expect(evidence.aggregateSnapshotReferenceCount == 0)
        #expect(evidence.activeTileLeaseCount == 0)
        #expect(evidence.activeStrokeSurfaceCount == 0)
        #expect(evidence.activeCommandOperationCount == 0)
        #expect(evidence.pendingLayerDisplayAcknowledgementCount == 0)

        let benchmark = BenchmarkRecord(
            schemaVersion: 1,
            timestampUTC: "2026-08-11T00:00:00Z",
            sceneName: "stage-d-runtime",
            hardware: .init(
                gpuName: device.name,
                logicalProcessorCount: 1,
                physicalMemoryBytes: 1
            ),
            operatingSystem: "test",
            build: .init(configuration: "Release", gitCommit: "abc"),
            frameCount: 1,
            cpuEncodeMilliseconds: [1],
            gpuMilliseconds: [1],
            peakResidentBytes: 1,
            stageDAcceptanceRendererEvidence: evidence
        )
        let decoded = try BenchmarkRecord.decode(
            BenchmarkRecord.encode(benchmark)
        )
        #expect(decoded.stageDAcceptanceRendererEvidence == evidence)
        #expect(!evidence.hasStageDProductionPlanCacheEvidence)

        var liveTraceRoot = try #require(
            JSONSerialization.jsonObject(
                with: BenchmarkRecord.encode(benchmark)
            ) as? [String: Any]
        )
        var liveTraceEvidence = try #require(
            liveTraceRoot["stageDAcceptanceRendererEvidence"]
                as? [String: Any]
        )
        liveTraceEvidence["cpuPlanCacheMissCount"] = 1_205
        liveTraceEvidence["gpuPlanCacheMissCount"] = 1_205
        liveTraceRoot["stageDAcceptanceRendererEvidence"] = liveTraceEvidence
        let liveTrace = try BenchmarkRecord.decode(
            JSONSerialization.data(withJSONObject: liveTraceRoot)
        )
        let liveTraceDecoded = try #require(
            liveTrace.stageDAcceptanceRendererEvidence
        )
        #expect(liveTraceDecoded.cpuPlanCacheHitCount == 0)
        #expect(liveTraceDecoded.gpuPlanCacheHitCount == 0)
        #expect(liveTraceDecoded.hasStageDProductionPlanCacheEvidence)

        var legacyRoot = try #require(
            JSONSerialization.jsonObject(
                with: BenchmarkRecord.encode(benchmark)
            ) as? [String: Any]
        )
        var legacyEvidence = try #require(
            legacyRoot["stageDAcceptanceRendererEvidence"]
                as? [String: Any]
        )
        legacyEvidence.removeValue(
            forKey: "retainedDisplaySnapshotTokenCount"
        )
        legacyEvidence.removeValue(
            forKey: "retainedHistorySnapshotTokenCount"
        )
        legacyRoot["stageDAcceptanceRendererEvidence"] = legacyEvidence
        let legacy = try BenchmarkRecord.decode(
            JSONSerialization.data(withJSONObject: legacyRoot)
        )
        let legacyDecoded = try #require(
            legacy.stageDAcceptanceRendererEvidence
        )
        #expect(legacyDecoded.retainedDisplaySnapshotTokenCount == 0)
        #expect(legacyDecoded.retainedHistorySnapshotTokenCount == 0)

        var inconsistentEvidence = legacyEvidence
        inconsistentEvidence["activeSnapshotTokenCount"] = 1
        inconsistentEvidence["retainedDisplaySnapshotTokenCount"] = 2
        inconsistentEvidence["retainedHistorySnapshotTokenCount"] = 0
        legacyRoot["stageDAcceptanceRendererEvidence"] = inconsistentEvidence
        let inconsistent = try BenchmarkRecord.decode(
            JSONSerialization.data(withJSONObject: legacyRoot)
        )
        let inconsistentDecoded = try #require(
            inconsistent.stageDAcceptanceRendererEvidence
        )
        #expect(
            inconsistentDecoded.snapshotOwnershipAccountingMismatchCount == 1
        )
        #expect(inconsistentDecoded.pendingOwnershipCount == 1)
    }

    private func row(
        scenarioID: String,
        producer: StageDAcceptanceProducerKind,
        seed: UInt64,
        status: StageDAcceptanceStatus = .passed,
        backend: StageDAcceptanceBackend = .productionSparseMetal,
        metrics: [String: Double] = ["p95": 0.25],
        attributes: [String: String] = [:]
    ) -> StageDAcceptanceRow {
        StageDAcceptanceRow(
            scenarioID: scenarioID,
            producer: producer,
            seed: seed,
            inputTrace: "trace-\(scenarioID)-\(seed)",
            expectedSemanticHash: String(repeating: "d", count: 64),
            numericOracle: nil,
            status: status,
            backend: backend,
            metrics: metrics,
            attributes: attributes
        )
    }

    private func acceptanceRunManifest(
        commit: String,
        semanticSuffix: String,
        residentHighWater: Double
    ) -> StageDAcceptanceManifest {
        let semanticIDs = Set(
            StageDAcceptanceRunRequirements.semanticScenarioIDs
        )
        return StageDAcceptanceManifest(
            generatedAt: Date(timeIntervalSince1970: 1_786_291_200),
            gitCommit: commit,
            rows: StageDAcceptanceRunRequirements.requiredScenarioIDs
                .enumerated()
                .map { index, scenarioID in
                    var metrics: [String: Double] = ["p95": 0.25]
                    if [
                        StageDAcceptanceRequirements.runtimeWall,
                        StageDAcceptanceRequirements.runtimeAccelerated,
                    ].contains(scenarioID) {
                        metrics["residentMemoryHighWaterBytes"] = 1_024
                        metrics["authoritativeQueueHighWater"] = 0
                        metrics["predictedQueueHighWater"] = 0
                        metrics["cacheMissCount"] = 0
                    }
                    if [
                        StageDAcceptanceRequirements.appControls,
                        StageDAcceptanceRequirements.appShortcuts,
                        StageDAcceptanceRequirements.appPersistence,
                    ].contains(scenarioID) {
                        metrics["residentTileHighWaterBytes"] = scenarioID
                            == StageDAcceptanceRequirements.appControls
                            ? residentHighWater : 1_024
                        metrics["revisionResidentBytes"] = 0
                        metrics["tileIndexEntryCount"] = 0
                        metrics["cpuCachedPlanCount"] = 0
                        metrics["gpuCachedPlanCount"] = 0
                        metrics["cachedPlanMetalBufferBytes"] = 0
                    }
                    return row(
                        scenarioID: scenarioID,
                        producer: StageDAcceptanceRequirements.producer(
                            for: scenarioID
                        ),
                        seed: UInt64(index + 1),
                        metrics: metrics,
                        attributes: semanticIDs.contains(scenarioID)
                            ? [
                                "observedSemanticHash": String(
                                    repeating: semanticSuffix,
                                    count: 64
                                ),
                            ]
                            : [:]
                    )
                }
        )
    }
}
