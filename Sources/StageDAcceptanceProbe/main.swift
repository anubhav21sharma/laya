import CryptoKit
import Foundation
import MetalRenderer

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@main
enum StageDAcceptanceProbe {
    static func main() throws {
        var raw = CommandLine.arguments.dropFirst()
        let command: String
        if raw.first == "emit-package" || raw.first == "aggregate" {
            command = raw.removeFirst()
        } else {
            command = "aggregate"
        }
        switch command {
        case "emit-package":
            try emitPackage(arguments: try PackageArguments(raw))
        case "aggregate":
            try aggregate(arguments: try AggregateArguments(raw))
        default:
            throw ProbeError.unknownCommand(command)
        }
    }

    private static func emitPackage(arguments: PackageArguments) throws {
        let suiteRows = try arguments.suites.map { suite in
            try PackageEvidence.suiteRow(
                scenarioID: suite.scenarioID,
                logURL: suite.logURL
            )
        }
        let wall = try PackageEvidence.runtimeRow(
            scenarioID: StageDAcceptanceRequirements.runtimeWall,
            benchmarkURL: arguments.wallBenchmarkURL,
            expectedProfile: .productionTenSeconds,
            expectedGitCommit: arguments.gitCommit,
            expectedConfiguration: "Release"
        )
        let accelerated = try PackageEvidence.runtimeRow(
            scenarioID: StageDAcceptanceRequirements.runtimeAccelerated,
            benchmarkURL: arguments.acceleratedBenchmarkURL,
            expectedProfile: .productionAcceleratedTenMinutes,
            expectedGitCommit: arguments.gitCommit,
            expectedConfiguration: "Release"
        )
        let allocation = try PackageEvidence.allocationRow(
            logURL: arguments.allocationLogURL
        )
        let broad = try PackageEvidence.broadRegressionRow(
            suiteLogURL: arguments.broadSuiteLogURL,
            baselineVerifierLogURL: arguments.broadBaselineVerifierLogURL
        )
        let review = try PackageEvidence.independentReviewRow(
            evidenceURL: arguments.reviewEvidenceURL,
            expectedGitCommit: arguments.gitCommit
        )
        let manifest = StageDAcceptanceManifest(
            generatedAt: arguments.generatedAt,
            gitCommit: arguments.gitCommit,
            rows: (
                suiteRows + [
                    wall,
                    accelerated,
                    allocation,
                    broad,
                    review,
                ]
            ).sorted { $0.scenarioID < $1.scenarioID }
        )
        try PackageEvidence.validatePackageCoverage(manifest)
        try write(manifest, to: arguments.outputURL)
        print(
            "Stage D package manifest verified: "
                + "\(manifest.rows.count) scenarios."
        )
    }

    private static func aggregate(arguments: AggregateArguments) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifests: [StageDAcceptanceManifest] = []
        manifests.reserveCapacity(arguments.manifestURLs.count)
        for url in arguments.manifestURLs {
            manifests.append(try decoder.decode(
                StageDAcceptanceManifest.self,
                from: Data(contentsOf: url)
            ))
        }
        guard let first = manifests.first else {
            throw ProbeError.missingManifest
        }
        guard manifests.allSatisfy({ $0.gitCommit == first.gitCommit }) else {
            throw ProbeError.gitCommitMismatch
        }

        let xcode = try XcodeEvidence.read(
            xcresultURL: arguments.xcresultURL,
            requiredTestIdentifier: arguments.requiredUITestIdentifier
        )
        var rows = manifests.flatMap(\.rows)
        rows.append(StageDAcceptanceRow(
            scenarioID: StageDAcceptanceRequirements.appXcodeHosted,
            producer: .xcodeUITest,
            seed: 1,
            inputTrace: arguments.requiredUITestIdentifier,
            expectedSemanticHash: nil,
            numericOracle: StageDAcceptanceNumericOracle(
                expected: 1,
                actual: 1,
                tolerance: 0
            ),
            status: .passed,
            backend: .productionSparseMetal,
            metrics: [
                "totalTestCount": Double(xcode.totalTestCount),
                "passedTestCount": Double(xcode.passedTestCount),
                "failedTestCount": Double(xcode.failedTestCount),
                "skippedTestCount": Double(xcode.skippedTestCount),
            ]
        ))
        let runManifest = StageDAcceptanceManifest(
            generatedAt: manifests.map(\.generatedAt).max() ?? Date(),
            gitCommit: first.gitCommit,
            rows: rows.sorted { $0.scenarioID < $1.scenarioID }
        )
        let validatedRun = try StageDAcceptanceManifestValidator.validateRun(
            runManifest
        )
        guard let referenceURL = arguments.referenceManifestURL else {
            try write(validatedRun, to: arguments.outputURL)
            print(
                "Stage D run manifest verified: "
                    + "\(validatedRun.rows.count) scenarios; "
                    + "a second fresh run is required for acceptance."
            )
            return
        }
        let reference = try decoder.decode(
            StageDAcceptanceManifest.self,
            from: Data(contentsOf: referenceURL)
        )
        let repeatability = try StageDAcceptanceRepeatabilityValidator
            .validate(reference: reference, candidate: validatedRun)
        rows.append(StageDAcceptanceRow(
            scenarioID: StageDAcceptanceRequirements.repeatability,
            producer: .acceptanceComparison,
            seed: 0x5457_4F52_554E,
            inputTrace: "two-fresh-runs:\(sha256(try Data(contentsOf: referenceURL)))"
                + ":\(sha256(try JSONEncoder().encode(validatedRun)))",
            expectedSemanticHash: nil,
            numericOracle: .init(expected: 1, actual: 1, tolerance: 0),
            status: .passed,
            backend: .productionSparseMetal,
            metrics: [
                "comparedSemanticHashCount": Double(
                    repeatability.comparedSemanticHashCount
                ),
                "comparedResourceMetricCount": Double(
                    repeatability.comparedResourceMetricCount
                ),
            ]
        ))
        let finalManifest = StageDAcceptanceManifest(
            generatedAt: runManifest.generatedAt,
            gitCommit: runManifest.gitCommit,
            rows: rows.sorted { $0.scenarioID < $1.scenarioID }
        )
        let validated = try StageDAcceptanceManifestValidator.validate(
            finalManifest
        )
        try write(validated, to: arguments.outputURL)
        print(
            "Stage D acceptance manifest verified across two fresh runs: "
                + "\(validated.rows.count) scenarios."
        )
    }

    private static func write(
        _ manifest: StageDAcceptanceManifest,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var output = try encoder.encode(manifest)
        output.append(0x0a)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try output.write(to: url, options: .atomic)
    }
}

private struct AggregateArguments {
    let manifestURLs: [URL]
    let referenceManifestURL: URL?
    let xcresultURL: URL
    let requiredUITestIdentifier: String
    let outputURL: URL

    init(_ raw: ArraySlice<String>) throws {
        var manifests: [URL] = []
        var referenceManifest: URL?
        var xcresult: URL?
        var requiredUITest: String?
        var output: URL?
        var index = raw.startIndex
        while index < raw.endIndex {
            let flag = raw[index]
            let valueIndex = raw.index(after: index)
            guard valueIndex < raw.endIndex else {
                throw ProbeError.missingValue(flag)
            }
            let value = raw[valueIndex]
            switch flag {
            case "--manifest":
                manifests.append(URL(fileURLWithPath: value))
            case "--reference-manifest":
                guard referenceManifest == nil else {
                    throw ProbeError.duplicateArgument(flag)
                }
                referenceManifest = URL(fileURLWithPath: value)
            case "--xcresult":
                guard xcresult == nil else {
                    throw ProbeError.duplicateArgument(flag)
                }
                xcresult = URL(fileURLWithPath: value)
            case "--required-ui-test":
                guard requiredUITest == nil else {
                    throw ProbeError.duplicateArgument(flag)
                }
                requiredUITest = value
            case "--output":
                guard output == nil else {
                    throw ProbeError.duplicateArgument(flag)
                }
                output = URL(fileURLWithPath: value)
            default:
                throw ProbeError.unknownArgument(flag)
            }
            index = raw.index(after: valueIndex)
        }
        guard !manifests.isEmpty else { throw ProbeError.missingManifest }
        guard let xcresult else {
            throw ProbeError.missingArgument("--xcresult")
        }
        guard let requiredUITest, !requiredUITest.isEmpty else {
            throw ProbeError.missingArgument("--required-ui-test")
        }
        guard let output else { throw ProbeError.missingArgument("--output") }
        manifestURLs = manifests
        referenceManifestURL = referenceManifest
        xcresultURL = xcresult
        requiredUITestIdentifier = requiredUITest
        outputURL = output
    }
}

private struct PackageArguments {
    struct Suite {
        let scenarioID: String
        let logURL: URL
    }

    let gitCommit: String
    let generatedAt: Date
    let suites: [Suite]
    let wallBenchmarkURL: URL
    let acceleratedBenchmarkURL: URL
    let allocationLogURL: URL
    let broadSuiteLogURL: URL
    let broadBaselineVerifierLogURL: URL
    let reviewEvidenceURL: URL
    let outputURL: URL

    init(_ raw: ArraySlice<String>) throws {
        var gitCommit: String?
        var generatedAt: Date?
        var suites: [Suite] = []
        var wall: URL?
        var accelerated: URL?
        var allocation: URL?
        var broadSuite: URL?
        var broadBaseline: URL?
        var reviewEvidence: URL?
        var output: URL?
        var index = raw.startIndex
        while index < raw.endIndex {
            let flag = raw[index]
            let valueIndex = raw.index(after: index)
            guard valueIndex < raw.endIndex else {
                throw ProbeError.missingValue(flag)
            }
            let value = raw[valueIndex]
            switch flag {
            case "--git-commit":
                guard gitCommit == nil else {
                    throw ProbeError.duplicateArgument(flag)
                }
                gitCommit = value
            case "--generated-at":
                guard generatedAt == nil else {
                    throw ProbeError.duplicateArgument(flag)
                }
                generatedAt = ISO8601DateFormatter().date(from: value)
                guard generatedAt != nil else {
                    throw ProbeError.invalidDate(value)
                }
            case "--suite":
                guard let separator = value.firstIndex(of: "=") else {
                    throw ProbeError.invalidSuite(value)
                }
                let scenarioID = String(value[..<separator])
                let path = String(value[value.index(after: separator)...])
                guard !scenarioID.isEmpty, !path.isEmpty else {
                    throw ProbeError.invalidSuite(value)
                }
                suites.append(Suite(
                    scenarioID: scenarioID,
                    logURL: URL(fileURLWithPath: path)
                ))
            case "--wall-benchmark":
                guard wall == nil else {
                    throw ProbeError.duplicateArgument(flag)
                }
                wall = URL(fileURLWithPath: value)
            case "--accelerated-benchmark":
                guard accelerated == nil else {
                    throw ProbeError.duplicateArgument(flag)
                }
                accelerated = URL(fileURLWithPath: value)
            case "--allocation-log":
                guard allocation == nil else {
                    throw ProbeError.duplicateArgument(flag)
                }
                allocation = URL(fileURLWithPath: value)
            case "--broad-suite-log":
                guard broadSuite == nil else {
                    throw ProbeError.duplicateArgument(flag)
                }
                broadSuite = URL(fileURLWithPath: value)
            case "--broad-baseline-verifier-log":
                guard broadBaseline == nil else {
                    throw ProbeError.duplicateArgument(flag)
                }
                broadBaseline = URL(fileURLWithPath: value)
            case "--review-evidence":
                guard reviewEvidence == nil else {
                    throw ProbeError.duplicateArgument(flag)
                }
                reviewEvidence = URL(fileURLWithPath: value)
            case "--output":
                guard output == nil else {
                    throw ProbeError.duplicateArgument(flag)
                }
                output = URL(fileURLWithPath: value)
            default:
                throw ProbeError.unknownArgument(flag)
            }
            index = raw.index(after: valueIndex)
        }
        guard let gitCommit else {
            throw ProbeError.missingArgument("--git-commit")
        }
        guard let generatedAt else {
            throw ProbeError.missingArgument("--generated-at")
        }
        guard !suites.isEmpty else {
            throw ProbeError.missingArgument("--suite")
        }
        guard let wall else {
            throw ProbeError.missingArgument("--wall-benchmark")
        }
        guard let accelerated else {
            throw ProbeError.missingArgument("--accelerated-benchmark")
        }
        guard let allocation else {
            throw ProbeError.missingArgument("--allocation-log")
        }
        guard let broadSuite else {
            throw ProbeError.missingArgument("--broad-suite-log")
        }
        guard let broadBaseline else {
            throw ProbeError.missingArgument(
                "--broad-baseline-verifier-log"
            )
        }
        guard let reviewEvidence else {
            throw ProbeError.missingArgument("--review-evidence")
        }
        guard let output else { throw ProbeError.missingArgument("--output") }
        self.gitCommit = gitCommit
        self.generatedAt = generatedAt
        self.suites = suites
        wallBenchmarkURL = wall
        acceleratedBenchmarkURL = accelerated
        allocationLogURL = allocation
        broadSuiteLogURL = broadSuite
        broadBaselineVerifierLogURL = broadBaseline
        reviewEvidenceURL = reviewEvidence
        outputURL = output
    }
}

private enum PackageEvidence {
    private static let packageScenarioIDs: Set<String> = [
        StageDAcceptanceRequirements.color,
        StageDAcceptanceRequirements.sparseSampling,
        StageDAcceptanceRequirements.strokeLifecycle,
        StageDAcceptanceRequirements.modes,
        StageDAcceptanceRequirements.layers,
        StageDAcceptanceRequirements.persistenceExport,
        StageDAcceptanceRequirements.negativeControls,
    ]

    static func suiteRow(
        scenarioID: String,
        logURL: URL
    ) throws -> StageDAcceptanceRow {
        guard packageScenarioIDs.contains(scenarioID),
              let expectedCounts = StageDAcceptancePackageSuiteRequirements
                .expectedCountsByScenario[scenarioID]
        else {
            throw ProbeError.invalidPackageScenario(scenarioID)
        }
        let data = try Data(contentsOf: logURL)
        let log = String(decoding: data, as: UTF8.self)
        let counts: StageDAcceptanceSuiteCounts
        do {
            counts = try StageDAcceptanceSuiteLogValidator.validate(
                log,
                expected: expectedCounts
            )
        } catch {
            throw ProbeError.suiteDidNotPass(scenarioID)
        }
        let digest = sha256(data)
        return StageDAcceptanceRow(
            scenarioID: scenarioID,
            producer: .packageHarness,
            seed: stableSeed(scenarioID),
            inputTrace: "swift-testing:\(logURL.lastPathComponent):\(digest)",
            expectedSemanticHash: nil,
            numericOracle: .init(
                expected: Double(expectedCounts.testCount),
                actual: Double(counts.testCount),
                tolerance: 0
            ),
            status: .passed,
            backend: .productionSparseMetal,
            metrics: [
                "suitePassed": 1,
                "testCount": Double(counts.testCount),
                "suiteCount": Double(counts.suiteCount),
            ],
            attributes: ["logSHA256": digest]
        )
    }

    static func runtimeRow(
        scenarioID: String,
        benchmarkURL: URL,
        expectedProfile: StrokeRuntimeTraceProfile,
        expectedGitCommit: String,
        expectedConfiguration: String
    ) throws -> StageDAcceptanceRow {
        let data = try Data(contentsOf: benchmarkURL)
        let benchmark = try BenchmarkRecord.decode(data)
        let attributedInputCount = [
            benchmark.strokeRuntime?.inputProvenance.actual ?? 0,
            benchmark.strokeRuntime?.inputProvenance.coalesced ?? 0,
            benchmark.strokeRuntime?.inputProvenance.predicted ?? 0,
            benchmark.strokeRuntime?.inputProvenance.estimatedUpdate ?? 0,
        ].reduce(UInt64(0)) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? .max : sum
        }
        guard let runtime = benchmark.strokeRuntime,
              let renderer = benchmark.stageDAcceptanceRendererEvidence,
              let attestation = runtime.attestation,
              let attributedCount = runtime.attributedFrameCount,
              runtime.traceProfile == expectedProfile,
              attestation.origin == .productionRenderer,
              attestation.traceProfile == expectedProfile,
              attestation.completeFrameEventCount == runtime.frameCount,
              attestation.begunFrameEventCount == runtime.frameCount,
              attestation.attributedFrameEventCount == attributedCount,
              attestation.discardedFrameEventCount == 0,
              attestation.unconsumedInputEventCount == 0,
              runtime.frameCount > 0,
              attributedCount > 0,
              attributedCount <= attributedInputCount,
              runtime.authoritativeQueueDepth == 0,
              runtime.predictedQueueDepth == 0,
              runtime.wallDurationNanoseconds
                >= expectedProfile.requiredWallDurationNanoseconds,
              runtime.logicalDurationNanoseconds
                >= expectedProfile.logicalDurationNanoseconds,
              runtime.eventToSubmitMissFraction <= 0.01,
              runtime.missedFrameFraction <= 0.01,
              runtime.inputProvenance.actual
                == UInt64(expectedProfile.requiredMovedSampleCount + 2),
              runtime.inputProvenance.coalesced == 0,
              runtime.inputProvenance.predicted == 0,
              runtime.inputProvenance.estimatedUpdate == 0,
              renderer.storageAuthority == .sparseRGBA16Float,
              renderer.backend == .productionSparseMetal,
              renderer.residentTileBytes <= renderer.tileByteBudget,
              renderer.residentTileHighWaterBytes <= renderer.tileByteBudget,
              renderer.residentResourceHighWaterBytes
                >= renderer.residentResourceBytes,
              renderer.hasStageDProductionPlanCacheEvidence,
              renderer.activeSnapshotTokenCount == 0,
              renderer.aggregateSnapshotReferenceCount == 0,
              renderer.activeTileLeaseCount == 0,
              renderer.activeStrokeSurfaceCount == 0,
              renderer.activeCommandOperationCount == 0,
              renderer.pendingLayerDisplayAcknowledgementCount == 0,
              renderer.activeUploadSlotCount == 0,
              renderer.pendingPlanCompletionCount == 0,
              renderer.pendingConsumerCompletionCount == 0,
              benchmark.build.gitCommit == expectedGitCommit,
              benchmark.build.configuration == expectedConfiguration,
              let hash = benchmark.canonicalBGRA8Digest,
              hash.count == 64,
              hash.allSatisfy({ $0.isHexDigit })
        else {
            throw ProbeError.invalidRuntimeEvidence(expectedProfile.rawValue)
        }
        let longStroke = try runtime.requiredLongStrokeMetrics(
            validatesPerformance: !BenchmarkHardware
                .isPerformancePendingEnvironment(
                    gpuName: benchmark.hardware.gpuName
                )
        )
        let digest = sha256(data)
        return StageDAcceptanceRow(
            scenarioID: scenarioID,
            producer: .productionRuntime,
            seed: benchmark.seed ?? stableSeed(scenarioID),
            inputTrace: "benchmark:\(benchmarkURL.lastPathComponent):\(digest)",
            expectedSemanticHash: nil,
            numericOracle: .init(
                expected: 0,
                actual: runtime.eventToSubmitMissFraction,
                tolerance: 0.01
            ),
            status: .passed,
            backend: .productionSparseMetal,
            metrics: [
                "frameCount": Double(runtime.frameCount),
                "attributedFrameCount": Double(attributedCount),
                "prepareP95Nanoseconds": Double(runtime.prepare.p95),
                "prepareP99Nanoseconds": Double(runtime.prepare.p99),
                "eventToSubmitP95Nanoseconds": Double(
                    runtime.eventToSubmit.p95
                ),
                "eventToSubmitP99Nanoseconds": Double(
                    runtime.eventToSubmit.p99
                ),
                "gpuP95Nanoseconds": Double(runtime.gpu.p95),
                "gpuP99Nanoseconds": Double(runtime.gpu.p99),
                "presentationP95Nanoseconds": Double(runtime.frame.p95),
                "presentationP99Nanoseconds": Double(runtime.frame.p99),
                "eventToSubmitMissFraction": runtime.eventToSubmitMissFraction,
                "missedFrameFraction": runtime.missedFrameFraction,
                "authoritativeQueueHighWater": Double(
                    runtime.authoritativeQueueHighWater
                ),
                "predictedQueueHighWater": Double(
                    runtime.predictedQueueHighWater
                ),
                "cacheHitCount": Double(
                    renderer.cpuPlanCacheHitCount
                        + renderer.gpuPlanCacheHitCount
                ),
                "cacheMissCount": Double(
                    renderer.cpuPlanCacheMissCount
                        + renderer.gpuPlanCacheMissCount
                ),
                "residentMemoryHighWaterBytes": Double(max(
                    runtime.memoryHighWaterBytes,
                    UInt64(renderer.residentResourceHighWaterBytes)
                )),
                "longStrokeEarlyCPUP95Milliseconds":
                    longStroke.earlyCPUP95Milliseconds,
                "longStrokeLateCPUP95Milliseconds":
                    longStroke.lateCPUP95Milliseconds,
                "longStrokeEarlyDabGPUP95Milliseconds":
                    longStroke.earlyDabGPUP95Milliseconds,
                "longStrokeLateDabGPUP95Milliseconds":
                    longStroke.lateDabGPUP95Milliseconds,
                "longStrokeCPUMillisecondsPerFrameSlope":
                    longStroke.cpuMillisecondsPerFrameSlope,
                "longStrokeDabGPUMillisecondsPerFrameSlope":
                    longStroke.dabGPUMillisecondsPerFrameSlope,
                "wallDurationNanoseconds": Double(
                    runtime.wallDurationNanoseconds
                ),
                "logicalDurationNanoseconds": Double(
                    runtime.logicalDurationNanoseconds
                ),
            ],
            attributes: [
                "traceProfile": expectedProfile.rawValue,
                "presentationSemantics":
                    attestation.presentationSemantics.rawValue,
                "benchmarkSHA256": digest,
                "observedSemanticHash": hash.lowercased(),
                "buildConfiguration": benchmark.build.configuration,
                "buildGitCommit": benchmark.build.gitCommit,
            ]
        )
    }

    static func broadRegressionRow(
        suiteLogURL: URL,
        baselineVerifierLogURL: URL
    ) throws -> StageDAcceptanceRow {
        let suiteData = try Data(contentsOf: suiteLogURL)
        let verifierData = try Data(contentsOf: baselineVerifierLogURL)
        let counts: StageDAcceptanceSuiteCounts
        do {
            counts = try StageDAcceptanceBroadSuiteEvidenceValidator.validate(
                suiteLog: String(decoding: suiteData, as: UTF8.self),
                baselineVerifierLog: String(
                    decoding: verifierData,
                    as: UTF8.self
                ),
                expectedCounts:
                    StageDAcceptancePackageSuiteRequirements.broadCounts,
                expectedIssueCount:
                    StageDAcceptancePackageSuiteRequirements
                        .broadKnownIssueCount
            )
        } catch {
            throw ProbeError.invalidBroadRegressionEvidence
        }
        let suiteDigest = sha256(suiteData)
        let verifierDigest = sha256(verifierData)
        return StageDAcceptanceRow(
            scenarioID: StageDAcceptanceRequirements.broadRegression,
            producer: .packageHarness,
            seed: stableSeed(StageDAcceptanceRequirements.broadRegression),
            inputTrace: "broad:\(suiteDigest):baseline:\(verifierDigest)",
            expectedSemanticHash: nil,
            numericOracle: .init(
                expected: Double(
                    StageDAcceptancePackageSuiteRequirements
                        .broadKnownIssueCount
                ),
                actual: Double(
                    StageDAcceptancePackageSuiteRequirements
                        .broadKnownIssueCount
                ),
                tolerance: 0
            ),
            status: .passed,
            backend: .productionSparseMetal,
            metrics: [
                "testCount": Double(counts.testCount),
                "suiteCount": Double(counts.suiteCount),
                "reviewedIssueCount": Double(
                    StageDAcceptancePackageSuiteRequirements
                        .broadKnownIssueCount
                ),
            ],
            attributes: [
                "suiteLogSHA256": suiteDigest,
                "baselineVerifierLogSHA256": verifierDigest,
            ]
        )
    }

    static func independentReviewRow(
        evidenceURL: URL,
        expectedGitCommit: String
    ) throws -> StageDAcceptanceRow {
        let data = try Data(contentsOf: evidenceURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            StageDAcceptanceReviewDisposition.self,
            from: data
        )
        let disposition: StageDAcceptanceReviewDisposition
        do {
            disposition = try StageDAcceptanceReviewDispositionValidator
                .validate(
                    decoded,
                    expectedBaseRevision: "ca5dff5",
                    expectedGitCommit: expectedGitCommit
                )
        } catch {
            throw ProbeError.invalidIndependentReviewEvidence
        }
        let digest = sha256(data)
        return StageDAcceptanceRow(
            scenarioID: StageDAcceptanceRequirements.independentReview,
            producer: .independentReview,
            seed: stableSeed(StageDAcceptanceRequirements.independentReview),
            inputTrace: "review:\(disposition.reviewer):\(digest)",
            expectedSemanticHash: nil,
            numericOracle: .init(
                expected: 0,
                actual: Double(
                    disposition.criticalFindingCount
                        + disposition.importantFindingCount
                ),
                tolerance: 0
            ),
            status: .passed,
            backend: .productionSparseMetal,
            metrics: [
                "criticalFindingCount": Double(
                    disposition.criticalFindingCount
                ),
                "importantFindingCount": Double(
                    disposition.importantFindingCount
                ),
            ],
            attributes: [
                "reviewer": disposition.reviewer,
                "reviewEvidenceSHA256": digest,
                "reviewedBaseRevision": disposition.baseRevision,
                "reviewedGitCommit": disposition.gitCommit,
            ]
        )
    }

    static func allocationRow(logURL: URL) throws -> StageDAcceptanceRow {
        let data = try Data(contentsOf: logURL)
        let log = String(decoding: data, as: UTF8.self)
        let evidence: StageDAllocationEvidence
        do {
            evidence = try StageDAllocationEvidenceValidator.validate(log)
        } catch {
            throw ProbeError.invalidAllocationEvidence
        }
        let digest = sha256(data)
        return StageDAcceptanceRow(
            scenarioID: StageDAcceptanceRequirements.allocation,
            producer: .allocationProbe,
            seed: stableSeed(StageDAcceptanceRequirements.allocation),
            inputTrace: "allocation:\(logURL.lastPathComponent):\(digest)",
            expectedSemanticHash: nil,
            numericOracle: .init(
                expected: 0,
                actual: Double(
                    evidence.firstLifecycleAllocationCount
                        - evidence.lastLifecycleAllocationCount
                ),
                tolerance: 8
            ),
            status: .passed,
            backend: .productionSparseMetal,
            metrics: [
                "postWarmApplicationAllocationCount": 0,
                "acceleratedInputSampleCount": Double(
                    evidence.inputSampleCount
                ),
                "surfaceTilePartitionEventCount": Double(
                    evidence.partitionEventCount
                ),
                "surfaceTileLeaseEventCount": Double(
                    evidence.leaseEventCount
                ),
                "metalDriverAllocationCount": Double(
                    evidence.metalDriverAllocationCount
                ),
                "offMainSurfaceMetalAllocationCount": Double(
                    evidence.offMainSurfaceMetalAllocationCount
                ),
                "firstLifecycleAllocationCount": Double(
                    evidence.firstLifecycleAllocationCount
                ),
                "lastLifecycleAllocationCount": Double(
                    evidence.lastLifecycleAllocationCount
                ),
                "firstDecileNanosecondsPerEvent": Double(
                    evidence.firstDecileNanosecondsPerEvent
                ),
                "lastDecileNanosecondsPerEvent": Double(
                    evidence.lastDecileNanosecondsPerEvent
                ),
            ],
            attributes: ["logSHA256": digest]
        )
    }

    static func validatePackageCoverage(
        _ manifest: StageDAcceptanceManifest
    ) throws {
        let required = packageScenarioIDs.union([
            StageDAcceptanceRequirements.runtimeWall,
            StageDAcceptanceRequirements.runtimeAccelerated,
            StageDAcceptanceRequirements.allocation,
            StageDAcceptanceRequirements.broadRegression,
            StageDAcceptanceRequirements.independentReview,
        ])
        let observed = Set(manifest.rows.map(\.scenarioID))
        guard observed == required,
              manifest.rows.count == required.count
        else { throw ProbeError.incompletePackageEvidence }
        guard (7...64).contains(manifest.gitCommit.count),
              manifest.gitCommit.allSatisfy({ $0.isHexDigit })
        else { throw ProbeError.invalidGitCommit }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func stableSeed(_ value: String) -> UInt64 {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        } | 1
    }
}

private struct XcodeEvidence {
    let totalTestCount: Int
    let passedTestCount: Int
    let failedTestCount: Int
    let skippedTestCount: Int

    static func read(
        xcresultURL: URL,
        requiredTestIdentifier: String
    ) throws -> Self {
        let summary = try runXCResultTool(
            verb: "summary",
            xcresultURL: xcresultURL
        )
        guard let summaryJSON = try JSONSerialization.jsonObject(
            with: summary
        ) as? [String: Any],
              summaryJSON["result"] as? String == "Passed",
              let total = summaryJSON["totalTestCount"] as? Int,
              let passed = summaryJSON["passedTests"] as? Int,
              let failed = summaryJSON["failedTests"] as? Int,
              let skipped = summaryJSON["skippedTests"] as? Int,
              total > 0,
              passed == total,
              failed == 0,
              skipped == 0
        else {
            throw ProbeError.xcodeResultDidNotPass
        }

        let tests = try runXCResultTool(
            verb: "tests",
            xcresultURL: xcresultURL
        )
        let testsJSON = try JSONSerialization.jsonObject(with: tests)
        guard containsPassedTest(
            testsJSON,
            identifier: requiredTestIdentifier
        ) else {
            throw ProbeError.missingPassedUITest(requiredTestIdentifier)
        }
        return Self(
            totalTestCount: total,
            passedTestCount: passed,
            failedTestCount: failed,
            skippedTestCount: skipped
        )
    }

    private static func runXCResultTool(
        verb: String,
        xcresultURL: URL
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xcresulttool", "get", "test-results", verb,
            "--path", xcresultURL.path, "--compact",
        ]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw ProbeError.xcresultToolFailed(message)
        }
        return data
    }

    private static func containsPassedTest(
        _ value: Any,
        identifier: String
    ) -> Bool {
        if let dictionary = value as? [String: Any] {
            let matchesName = [
                dictionary["nodeIdentifier"] as? String,
                dictionary["nodeIdentifierURL"] as? String,
                dictionary["name"] as? String,
            ].compactMap { $0 }.contains { candidate in
                candidate == identifier
            }
            if matchesName,
               dictionary["nodeType"] as? String == "Test Case",
               dictionary["result"] as? String == "Passed"
            {
                return true
            }
            return dictionary.values.contains {
                containsPassedTest($0, identifier: identifier)
            }
        }
        if let array = value as? [Any] {
            return array.contains {
                containsPassedTest($0, identifier: identifier)
            }
        }
        return false
    }
}

private enum ProbeError: Error, CustomStringConvertible {
    case unknownCommand(String)
    case unknownArgument(String)
    case missingArgument(String)
    case missingValue(String)
    case duplicateArgument(String)
    case missingManifest
    case gitCommitMismatch
    case xcodeResultDidNotPass
    case missingPassedUITest(String)
    case xcresultToolFailed(String)
    case invalidDate(String)
    case invalidSuite(String)
    case invalidPackageScenario(String)
    case suiteDidNotPass(String)
    case invalidRuntimeEvidence(String)
    case invalidAllocationEvidence
    case invalidBroadRegressionEvidence
    case invalidIndependentReviewEvidence
    case incompletePackageEvidence
    case invalidGitCommit

    var description: String {
        switch self {
        case let .unknownCommand(value): "unknown command: \(value)"
        case let .unknownArgument(value): "unknown argument: \(value)"
        case let .missingArgument(value): "missing argument: \(value)"
        case let .missingValue(value): "missing value after: \(value)"
        case let .duplicateArgument(value): "duplicate argument: \(value)"
        case .missingManifest: "at least one --manifest is required"
        case .gitCommitMismatch: "input manifests disagree on git commit"
        case .xcodeResultDidNotPass: "Xcode result did not pass every test"
        case let .missingPassedUITest(value):
            "required UI test did not pass: \(value)"
        case let .xcresultToolFailed(value):
            "xcresulttool failed: \(value)"
        case let .invalidDate(value): "invalid ISO-8601 date: \(value)"
        case let .invalidSuite(value):
            "invalid --suite value; expected SCENARIO=PATH: \(value)"
        case let .invalidPackageScenario(value):
            "invalid package scenario: \(value)"
        case let .suiteDidNotPass(value):
            "suite evidence did not pass: \(value)"
        case let .invalidRuntimeEvidence(value):
            "invalid production runtime evidence: \(value)"
        case .invalidAllocationEvidence:
            "allocation evidence lacks required production pass markers"
        case .invalidBroadRegressionEvidence:
            "broad regression evidence or reviewed baseline is invalid"
        case .invalidIndependentReviewEvidence:
            "independent review evidence is invalid or unresolved"
        case .incompletePackageEvidence:
            "package evidence does not contain the exact required scenarios"
        case .invalidGitCommit: "git commit is not a hexadecimal identity"
        }
    }
}
