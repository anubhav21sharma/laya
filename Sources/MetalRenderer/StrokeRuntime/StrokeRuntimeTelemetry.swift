import Foundation
import PatternEngine

public enum StageDAcceptanceProducerKind: String, Codable, Sendable {
    case packageHarness
    case xcodeUITest
    case applicationRoute
    case productionRuntime
    case allocationProbe
    case independentReview
    case acceptanceComparison
}

public enum StageDAcceptanceStatus: String, Codable, Sendable {
    case passed
    case failed
    case skipped
}

public enum StageDAcceptanceBackend: String, Codable, Sendable {
    case productionSparseMetal
    case softwareReference
    case nonproduction
}

public struct StageDAcceptanceNumericOracle:
    Codable, Equatable, Sendable
{
    public let expected: Double
    public let actual: Double
    public let tolerance: Double

    public init(expected: Double, actual: Double, tolerance: Double) {
        self.expected = expected
        self.actual = actual
        self.tolerance = tolerance
    }
}

public struct StageDAcceptanceRow: Codable, Equatable, Sendable {
    public let scenarioID: String
    public let producer: StageDAcceptanceProducerKind
    public let seed: UInt64
    public let inputTrace: String
    public let expectedSemanticHash: String?
    public let numericOracle: StageDAcceptanceNumericOracle?
    public let status: StageDAcceptanceStatus
    public let backend: StageDAcceptanceBackend
    public let metrics: [String: Double]
    public let attributes: [String: String]

    public init(
        scenarioID: String,
        producer: StageDAcceptanceProducerKind,
        seed: UInt64,
        inputTrace: String,
        expectedSemanticHash: String?,
        numericOracle: StageDAcceptanceNumericOracle?,
        status: StageDAcceptanceStatus,
        backend: StageDAcceptanceBackend,
        metrics: [String: Double],
        attributes: [String: String] = [:]
    ) {
        self.scenarioID = scenarioID
        self.producer = producer
        self.seed = seed
        self.inputTrace = inputTrace
        self.expectedSemanticHash = expectedSemanticHash
        self.numericOracle = numericOracle
        self.status = status
        self.backend = backend
        self.metrics = metrics
        self.attributes = attributes
    }
}

public struct StageDAcceptanceManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let gitCommit: String
    public let rows: [StageDAcceptanceRow]

    public init(
        generatedAt: Date,
        gitCommit: String,
        rows: [StageDAcceptanceRow]
    ) {
        schemaVersion = Self.schemaVersion
        self.generatedAt = generatedAt
        self.gitCommit = gitCommit
        self.rows = rows
    }
}

public struct StageDAcceptanceSuiteCounts: Equatable, Sendable {
    public let testCount: Int
    public let suiteCount: Int

    public init(testCount: Int, suiteCount: Int) {
        self.testCount = testCount
        self.suiteCount = suiteCount
    }
}

public enum StageDAcceptanceSuiteLogValidationError:
    Error, Equatable, Sendable
{
    case missingPositivePassingSummary
    case runRecordedIssueOrFailure
    case unexpectedCounts(
        expected: StageDAcceptanceSuiteCounts,
        actual: StageDAcceptanceSuiteCounts
    )
}

public enum StageDAcceptanceSuiteLogValidator {
    public static func validate(
        _ log: String
    ) throws -> StageDAcceptanceSuiteCounts {
        guard !log.contains("recorded an issue"),
              !log.contains("failed after")
        else {
            throw StageDAcceptanceSuiteLogValidationError
                .runRecordedIssueOrFailure
        }

        var passingSummaries: [StageDAcceptanceSuiteCounts] = []
        for line in log.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard let start = tokens.indices.first(where: {
                tokens[$0] == "Test"
            }),
            start + 9 < tokens.endIndex,
            tokens[start + 1] == "run",
            tokens[start + 2] == "with",
            let testCount = Int(tokens[start + 3]),
            tokens[start + 4].hasPrefix("test"),
            tokens[start + 5] == "in",
            let suiteCount = Int(tokens[start + 6]),
            tokens[start + 7].hasPrefix("suite"),
            tokens[start + 8] == "passed",
            tokens[start + 9] == "after",
            testCount > 0,
            suiteCount > 0
            else { continue }
            passingSummaries.append(.init(
                testCount: testCount,
                suiteCount: suiteCount
            ))
        }
        guard passingSummaries.count == 1,
              let counts = passingSummaries.first
        else {
            throw StageDAcceptanceSuiteLogValidationError
                .missingPositivePassingSummary
        }
        return counts
    }

    public static func validate(
        _ log: String,
        expected: StageDAcceptanceSuiteCounts
    ) throws -> StageDAcceptanceSuiteCounts {
        let actual = try validate(log)
        guard actual == expected else {
            throw StageDAcceptanceSuiteLogValidationError.unexpectedCounts(
                expected: expected,
                actual: actual
            )
        }
        return actual
    }
}

public enum StageDAcceptanceBroadSuiteValidationError:
    Error, Equatable, Sendable
{
    case missingCompleteSummary
    case unexpectedCounts(
        expected: StageDAcceptanceSuiteCounts,
        actual: StageDAcceptanceSuiteCounts
    )
    case baselineVerifierDidNotApprove(expectedIssueCount: Int)
}

public enum StageDAcceptanceBroadSuiteEvidenceValidator {
    public static func validate(
        suiteLog: String,
        baselineVerifierLog: String,
        expectedCounts: StageDAcceptanceSuiteCounts,
        expectedIssueCount: Int
    ) throws -> StageDAcceptanceSuiteCounts {
        var summaries: [StageDAcceptanceSuiteCounts] = []
        for line in suiteLog.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard let start = tokens.indices.first(where: {
                tokens[$0] == "Test"
            }),
            start + 8 < tokens.endIndex,
            tokens[start + 1] == "run",
            tokens[start + 2] == "with",
            let testCount = Int(tokens[start + 3].replacingOccurrences(
                of: ",",
                with: ""
            )),
            tokens[start + 4].hasPrefix("test"),
            tokens[start + 5] == "in",
            let suiteCount = Int(tokens[start + 6].replacingOccurrences(
                of: ",",
                with: ""
            )),
            tokens[start + 7].hasPrefix("suite"),
            tokens[start + 8] == "failed" || tokens[start + 8] == "passed",
            testCount > 0,
            suiteCount > 0
            else { continue }
            summaries.append(.init(
                testCount: testCount,
                suiteCount: suiteCount
            ))
        }
        guard summaries.count == 1, let actual = summaries.first else {
            throw StageDAcceptanceBroadSuiteValidationError
                .missingCompleteSummary
        }
        guard actual == expectedCounts else {
            throw StageDAcceptanceBroadSuiteValidationError.unexpectedCounts(
                expected: expectedCounts,
                actual: actual
            )
        }
        let expectedApproval = "Swift Testing baseline verified: "
            + "\(expectedIssueCount) complete issue records."
        guard baselineVerifierLog.split(whereSeparator: \.isNewline)
            .contains(where: { $0 == expectedApproval })
        else {
            throw StageDAcceptanceBroadSuiteValidationError
                .baselineVerifierDidNotApprove(
                    expectedIssueCount: expectedIssueCount
                )
        }
        return actual
    }
}

public struct StageDAcceptanceReviewDisposition:
    Codable, Equatable, Sendable
{
    public let schemaVersion: Int
    public let baseRevision: String
    public let gitCommit: String
    public let reviewer: String
    public let criticalFindingCount: Int
    public let importantFindingCount: Int

    public init(
        schemaVersion: Int,
        baseRevision: String,
        gitCommit: String,
        reviewer: String,
        criticalFindingCount: Int,
        importantFindingCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.baseRevision = baseRevision
        self.gitCommit = gitCommit
        self.reviewer = reviewer
        self.criticalFindingCount = criticalFindingCount
        self.importantFindingCount = importantFindingCount
    }
}

public enum StageDAcceptanceReviewValidationError:
    Error, Equatable, Sendable
{
    case unsupportedSchema(Int)
    case baseRevisionMismatch
    case gitCommitMismatch
    case missingReviewer
    case invalidFindingCount
    case unresolvedFindings(critical: Int, important: Int)
}

public enum StageDAcceptanceReviewDispositionValidator {
    public static func validate(
        _ disposition: StageDAcceptanceReviewDisposition,
        expectedBaseRevision: String,
        expectedGitCommit: String
    ) throws -> StageDAcceptanceReviewDisposition {
        guard disposition.schemaVersion == 1 else {
            throw StageDAcceptanceReviewValidationError.unsupportedSchema(
                disposition.schemaVersion
            )
        }
        guard disposition.baseRevision == expectedBaseRevision else {
            throw StageDAcceptanceReviewValidationError.baseRevisionMismatch
        }
        guard disposition.gitCommit == expectedGitCommit else {
            throw StageDAcceptanceReviewValidationError.gitCommitMismatch
        }
        guard !disposition.reviewer.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw StageDAcceptanceReviewValidationError.missingReviewer
        }
        guard disposition.criticalFindingCount >= 0,
              disposition.importantFindingCount >= 0
        else {
            throw StageDAcceptanceReviewValidationError.invalidFindingCount
        }
        guard disposition.criticalFindingCount == 0,
              disposition.importantFindingCount == 0
        else {
            throw StageDAcceptanceReviewValidationError.unresolvedFindings(
                critical: disposition.criticalFindingCount,
                important: disposition.importantFindingCount
            )
        }
        return disposition
    }
}

public enum StageDAcceptanceRequirements {
    public static let color = "stage-d.color"
    public static let sparseSampling = "stage-d.sparse-sampling"
    public static let strokeLifecycle = "stage-d.stroke-lifecycle"
    public static let modes = "stage-d.modes"
    public static let layers = "stage-d.layers"
    public static let persistenceExport = "stage-d.persistence-export"
    public static let runtimeWall = "stage-d.runtime.wall"
    public static let runtimeAccelerated = "stage-d.runtime.accelerated"
    public static let allocation = "stage-d.allocation"
    public static let negativeControls = "stage-d.negative-controls"
    public static let appControls = "stage-d.app.controls"
    public static let appShortcuts = "stage-d.app.shortcuts"
    public static let appPersistence = "stage-d.app.persistence"
    public static let appXcodeHosted = "stage-d.app.xcode-hosted"
    public static let broadRegression = "stage-d.broad-regression"
    public static let independentReview = "stage-d.independent-review"
    public static let repeatability = "stage-d.repeatability"

    public static let requiredScenarioIDs = [
        color,
        sparseSampling,
        strokeLifecycle,
        modes,
        layers,
        persistenceExport,
        runtimeWall,
        runtimeAccelerated,
        allocation,
        negativeControls,
        appControls,
        appShortcuts,
        appPersistence,
        appXcodeHosted,
        broadRegression,
        independentReview,
        repeatability,
    ]

    public static func producer(
        for scenarioID: String
    ) -> StageDAcceptanceProducerKind {
        switch scenarioID {
        case runtimeWall, runtimeAccelerated:
            .productionRuntime
        case allocation:
            .allocationProbe
        case appXcodeHosted:
            .xcodeUITest
        case independentReview:
            .independentReview
        case repeatability:
            .acceptanceComparison
        case appControls, appShortcuts, appPersistence:
            .applicationRoute
        default:
            .packageHarness
        }
    }
}

public enum StageDAcceptanceRunRequirements {
    public static let requiredScenarioIDs =
        StageDAcceptanceRequirements.requiredScenarioIDs.filter {
            $0 != StageDAcceptanceRequirements.repeatability
        }

    public static let semanticScenarioIDs = [
        StageDAcceptanceRequirements.runtimeWall,
        StageDAcceptanceRequirements.runtimeAccelerated,
        StageDAcceptanceRequirements.appControls,
        StageDAcceptanceRequirements.appShortcuts,
        StageDAcceptanceRequirements.appPersistence,
    ]

    fileprivate static let resourceMetricsByScenario: [String: [String]] = [
        StageDAcceptanceRequirements.runtimeWall: [
            "residentMemoryHighWaterBytes",
            "authoritativeQueueHighWater",
            "predictedQueueHighWater",
            "cacheMissCount",
        ],
        StageDAcceptanceRequirements.runtimeAccelerated: [
            "residentMemoryHighWaterBytes",
            "authoritativeQueueHighWater",
            "predictedQueueHighWater",
            "cacheMissCount",
        ],
        StageDAcceptanceRequirements.appControls: [
            "residentTileHighWaterBytes",
            "revisionResidentBytes",
            "tileIndexEntryCount",
            "cpuCachedPlanCount",
            "gpuCachedPlanCount",
            "cachedPlanMetalBufferBytes",
        ],
        StageDAcceptanceRequirements.appShortcuts: [
            "residentTileHighWaterBytes",
            "revisionResidentBytes",
            "tileIndexEntryCount",
            "cpuCachedPlanCount",
            "gpuCachedPlanCount",
            "cachedPlanMetalBufferBytes",
        ],
        StageDAcceptanceRequirements.appPersistence: [
            "residentTileHighWaterBytes",
            "revisionResidentBytes",
            "tileIndexEntryCount",
            "cpuCachedPlanCount",
            "gpuCachedPlanCount",
            "cachedPlanMetalBufferBytes",
        ],
    ]
}

public enum StageDAcceptancePackageSuiteRequirements {
    public static let expectedCountsByScenario: [
        String: StageDAcceptanceSuiteCounts
    ] = [
        StageDAcceptanceRequirements.color:
            .init(testCount: 26, suiteCount: 3),
        StageDAcceptanceRequirements.sparseSampling:
            .init(testCount: 220, suiteCount: 5),
        StageDAcceptanceRequirements.strokeLifecycle:
            .init(testCount: 176, suiteCount: 3),
        StageDAcceptanceRequirements.modes:
            .init(testCount: 50, suiteCount: 3),
        StageDAcceptanceRequirements.layers:
            .init(testCount: 32, suiteCount: 2),
        StageDAcceptanceRequirements.persistenceExport:
            .init(testCount: 36, suiteCount: 4),
        StageDAcceptanceRequirements.negativeControls:
            .init(testCount: 98, suiteCount: 4),
    ]

    public static let broadCounts = StageDAcceptanceSuiteCounts(
        testCount: 2_134,
        suiteCount: 110
    )
    public static let broadKnownIssueCount = 5
}

public struct StageDAcceptanceRepeatabilityResult:
    Equatable, Sendable
{
    public let comparedSemanticHashCount: Int
    public let comparedResourceMetricCount: Int
}

public enum StageDAcceptanceRepeatabilityError:
    Error, Equatable, Sendable
{
    case gitCommitMismatch
    case incompleteRun
    case duplicateScenarioID(String)
    case scenarioDidNotPass(String)
    case missingSemanticHash(String)
    case semanticHashMismatch(String)
    case missingResourceMetric(scenarioID: String, metric: String)
    case resourceGrowth(
        scenarioID: String,
        metric: String,
        reference: Double,
        candidate: Double
    )
}

public enum StageDAcceptanceRepeatabilityValidator {
    public static func validate(
        reference: StageDAcceptanceManifest,
        candidate: StageDAcceptanceManifest
    ) throws -> StageDAcceptanceRepeatabilityResult {
        _ = try StageDAcceptanceManifestValidator.validateRun(reference)
        _ = try StageDAcceptanceManifestValidator.validateRun(candidate)
        guard reference.gitCommit == candidate.gitCommit else {
            throw StageDAcceptanceRepeatabilityError.gitCommitMismatch
        }
        let referenceRows = try rowsByID(reference)
        let candidateRows = try rowsByID(candidate)
        let required = Set(StageDAcceptanceRunRequirements.requiredScenarioIDs)
        guard Set(referenceRows.keys) == required,
              Set(candidateRows.keys) == required
        else {
            throw StageDAcceptanceRepeatabilityError.incompleteRun
        }

        var semanticCount = 0
        for scenarioID in StageDAcceptanceRunRequirements.semanticScenarioIDs {
            guard let first = referenceRows[scenarioID]?.attributes[
                "observedSemanticHash"
            ],
            let second = candidateRows[scenarioID]?.attributes[
                "observedSemanticHash"
            ],
            Self.isSHA256(first),
            Self.isSHA256(second)
            else {
                throw StageDAcceptanceRepeatabilityError
                    .missingSemanticHash(scenarioID)
            }
            guard first.lowercased() == second.lowercased() else {
                throw StageDAcceptanceRepeatabilityError
                    .semanticHashMismatch(scenarioID)
            }
            semanticCount += 1
        }

        var resourceCount = 0
        for (scenarioID, metricNames) in
            StageDAcceptanceRunRequirements.resourceMetricsByScenario
        {
            for metric in metricNames {
                guard let first = referenceRows[scenarioID]?.metrics[metric],
                      let second = candidateRows[scenarioID]?.metrics[metric]
                else {
                    throw StageDAcceptanceRepeatabilityError
                        .missingResourceMetric(
                            scenarioID: scenarioID,
                            metric: metric
                        )
                }
                guard second <= first else {
                    throw StageDAcceptanceRepeatabilityError.resourceGrowth(
                        scenarioID: scenarioID,
                        metric: metric,
                        reference: first,
                        candidate: second
                    )
                }
                resourceCount += 1
            }
        }
        return StageDAcceptanceRepeatabilityResult(
            comparedSemanticHashCount: semanticCount,
            comparedResourceMetricCount: resourceCount
        )
    }

    private static func rowsByID(
        _ manifest: StageDAcceptanceManifest
    ) throws -> [String: StageDAcceptanceRow] {
        var rows: [String: StageDAcceptanceRow] = [:]
        for row in manifest.rows {
            guard rows[row.scenarioID] == nil else {
                throw StageDAcceptanceRepeatabilityError
                    .duplicateScenarioID(row.scenarioID)
            }
            guard row.status == .passed,
                  row.backend == .productionSparseMetal,
                  row.producer == StageDAcceptanceRequirements.producer(
                    for: row.scenarioID
                  )
            else {
                throw StageDAcceptanceRepeatabilityError
                    .scenarioDidNotPass(row.scenarioID)
            }
            rows[row.scenarioID] = row
        }
        return rows
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0)
                || (97...102).contains($0)
        }
    }
}

public enum StageDAcceptanceValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidGitCommit
    case duplicateScenarioID(String)
    case unexpectedScenarioID(String)
    case missingRequiredScenarioID(String)
    case unexpectedProducer(String)
    case invalidSeed(String)
    case missingInputTrace(String)
    case missingOracle(String)
    case ambiguousOracle(String)
    case invalidSemanticHash(String)
    case invalidNumericOracle(String)
    case numericOracleMismatch(String)
    case scenarioDidNotPass(String, StageDAcceptanceStatus)
    case nonproductionBackend(String)
    case nonfiniteMetric(String, String)
}

public enum StageDAcceptanceManifestValidator {
    public static func validate(
        _ manifest: StageDAcceptanceManifest
    ) throws -> StageDAcceptanceManifest {
        try validate(
            manifest,
            requiredScenarioIDs:
                StageDAcceptanceRequirements.requiredScenarioIDs
        )
    }

    public static func validateRun(
        _ manifest: StageDAcceptanceManifest
    ) throws -> StageDAcceptanceManifest {
        try validate(
            manifest,
            requiredScenarioIDs:
                StageDAcceptanceRunRequirements.requiredScenarioIDs
        )
    }

    private static func validate(
        _ manifest: StageDAcceptanceManifest,
        requiredScenarioIDs orderedRequiredScenarioIDs: [String]
    ) throws -> StageDAcceptanceManifest {
        guard manifest.schemaVersion == StageDAcceptanceManifest.schemaVersion
        else {
            throw StageDAcceptanceValidationError.unsupportedSchema(
                manifest.schemaVersion
            )
        }
        guard isHex(manifest.gitCommit),
              (7...64).contains(manifest.gitCommit.count)
        else {
            throw StageDAcceptanceValidationError.invalidGitCommit
        }

        var byID: [String: StageDAcceptanceRow] = [:]
        byID.reserveCapacity(manifest.rows.count)
        let requiredScenarioIDs = Set(
            orderedRequiredScenarioIDs
        )
        for row in manifest.rows {
            guard requiredScenarioIDs.contains(row.scenarioID) else {
                throw StageDAcceptanceValidationError.unexpectedScenarioID(
                    row.scenarioID
                )
            }
            guard byID.updateValue(row, forKey: row.scenarioID) == nil else {
                throw StageDAcceptanceValidationError.duplicateScenarioID(
                    row.scenarioID
                )
            }
            guard row.seed > 0 else {
                throw StageDAcceptanceValidationError.invalidSeed(row.scenarioID)
            }
            guard !row.inputTrace.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                throw StageDAcceptanceValidationError.missingInputTrace(
                    row.scenarioID
                )
            }
            guard row.status == .passed else {
                throw StageDAcceptanceValidationError.scenarioDidNotPass(
                    row.scenarioID,
                    row.status
                )
            }
            guard row.backend == .productionSparseMetal else {
                throw StageDAcceptanceValidationError.nonproductionBackend(
                    row.scenarioID
                )
            }
            switch (row.expectedSemanticHash, row.numericOracle) {
            case let (.some(hash), nil):
                guard hash.count == 64, isHex(hash) else {
                    throw StageDAcceptanceValidationError.invalidSemanticHash(
                        row.scenarioID
                    )
                }
            case let (nil, .some(oracle)):
                guard oracle.expected.isFinite,
                      oracle.actual.isFinite,
                      oracle.tolerance.isFinite,
                      oracle.tolerance >= 0
                else {
                    throw StageDAcceptanceValidationError.invalidNumericOracle(
                        row.scenarioID
                    )
                }
                guard abs(oracle.actual - oracle.expected) <= oracle.tolerance
                else {
                    throw StageDAcceptanceValidationError.numericOracleMismatch(
                        row.scenarioID
                    )
                }
            case (nil, nil):
                throw StageDAcceptanceValidationError.missingOracle(
                    row.scenarioID
                )
            case (.some, .some):
                throw StageDAcceptanceValidationError.ambiguousOracle(
                    row.scenarioID
                )
            }
            for (name, value) in row.metrics where !value.isFinite {
                throw StageDAcceptanceValidationError.nonfiniteMetric(
                    row.scenarioID,
                    name
                )
            }
        }

        for scenarioID in orderedRequiredScenarioIDs {
            guard let row = byID[scenarioID] else {
                throw StageDAcceptanceValidationError
                    .missingRequiredScenarioID(scenarioID)
            }
            guard row.producer
                    == StageDAcceptanceRequirements.producer(for: scenarioID)
            else {
                throw StageDAcceptanceValidationError.unexpectedProducer(
                    scenarioID
                )
            }
        }
        return manifest
    }

    private static func isHex(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0)
                || (97...102).contains($0)
        }
    }
}

public struct StageDAcceptanceRendererEvidence:
    Codable, Equatable, Sendable
{
    public let storageAuthority: StageDAcceptanceStorageAuthority
    public let backend: StageDAcceptanceBackend
    public let documentGeneration: UInt64
    public let layerCount: Int
    public let tileByteBudget: Int
    public let residentTileBytes: Int
    public let residentTileHighWaterBytes: Int
    public let backingTileBytes: Int
    public let tileIndexEntryCount: Int
    public let cpuCachedPlanCount: Int
    public let gpuCachedPlanCount: Int
    public let cpuPlanCacheHitCount: UInt64
    public let cpuPlanCacheMissCount: UInt64
    public let gpuPlanCacheHitCount: UInt64
    public let gpuPlanCacheMissCount: UInt64
    public let cachedPlanMetalBufferBytes: Int
    public let uploadRingMetalBufferBytes: Int
    public let residentResourceBytes: Int
    public let residentResourceHighWaterBytes: Int
    public let planMetalBufferAllocationCount: Int
    public let activeUploadSlotCount: Int
    public let uploadSlotHighWater: Int
    public let pendingPlanCompletionCount: Int
    public let pendingConsumerCompletionCount: Int
    public let revisionResidentBytes: Int
    public let activeSnapshotTokenCount: Int
    public let retainedDisplaySnapshotTokenCount: Int
    public let retainedHistorySnapshotTokenCount: Int
    public let aggregateSnapshotReferenceCount: Int
    public let activeTileLeaseCount: Int
    public let activeStrokeSurfaceCount: Int
    public let activeCommandOperationCount: Int
    public let pendingLayerDisplayAcknowledgementCount: Int

    private enum CodingKeys: String, CodingKey {
        case storageAuthority
        case backend
        case documentGeneration
        case layerCount
        case tileByteBudget
        case residentTileBytes
        case residentTileHighWaterBytes
        case backingTileBytes
        case tileIndexEntryCount
        case cpuCachedPlanCount
        case gpuCachedPlanCount
        case cpuPlanCacheHitCount
        case cpuPlanCacheMissCount
        case gpuPlanCacheHitCount
        case gpuPlanCacheMissCount
        case cachedPlanMetalBufferBytes
        case uploadRingMetalBufferBytes
        case residentResourceBytes
        case residentResourceHighWaterBytes
        case planMetalBufferAllocationCount
        case activeUploadSlotCount
        case uploadSlotHighWater
        case pendingPlanCompletionCount
        case pendingConsumerCompletionCount
        case revisionResidentBytes
        case activeSnapshotTokenCount
        case retainedDisplaySnapshotTokenCount
        case retainedHistorySnapshotTokenCount
        case aggregateSnapshotReferenceCount
        case activeTileLeaseCount
        case activeStrokeSurfaceCount
        case activeCommandOperationCount
        case pendingLayerDisplayAcknowledgementCount
    }

    public var snapshotOwnershipAccountingMismatchCount: Int {
        let retained = retainedDisplaySnapshotTokenCount
            + retainedHistorySnapshotTokenCount
        return retained > activeSnapshotTokenCount
            ? retained - activeSnapshotTokenCount
            : 0
    }

    public var pendingOwnershipCount: Int {
        let retained = retainedDisplaySnapshotTokenCount
            + retainedHistorySnapshotTokenCount
        let unclassifiedOrInconsistentSnapshotCount =
            activeSnapshotTokenCount >= retained
                ? activeSnapshotTokenCount - retained
                : retained - activeSnapshotTokenCount
        return unclassifiedOrInconsistentSnapshotCount
            + activeTileLeaseCount
            + activeStrokeSurfaceCount
            + activeCommandOperationCount
            + pendingLayerDisplayAcknowledgementCount
            + activeUploadSlotCount
            + pendingPlanCompletionCount
            + pendingConsumerCompletionCount
    }
}

extension StageDAcceptanceRendererEvidence {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storageAuthority = try container.decode(
            StageDAcceptanceStorageAuthority.self,
            forKey: .storageAuthority
        )
        backend = try container.decode(
            StageDAcceptanceBackend.self,
            forKey: .backend
        )
        documentGeneration = try container.decode(
            UInt64.self,
            forKey: .documentGeneration
        )
        layerCount = try container.decode(Int.self, forKey: .layerCount)
        tileByteBudget = try container.decode(Int.self, forKey: .tileByteBudget)
        residentTileBytes = try container.decode(
            Int.self,
            forKey: .residentTileBytes
        )
        residentTileHighWaterBytes = try container.decode(
            Int.self,
            forKey: .residentTileHighWaterBytes
        )
        backingTileBytes = try container.decode(
            Int.self,
            forKey: .backingTileBytes
        )
        tileIndexEntryCount = try container.decode(
            Int.self,
            forKey: .tileIndexEntryCount
        )
        cpuCachedPlanCount = try container.decode(
            Int.self,
            forKey: .cpuCachedPlanCount
        )
        gpuCachedPlanCount = try container.decode(
            Int.self,
            forKey: .gpuCachedPlanCount
        )
        cpuPlanCacheHitCount = try container.decode(
            UInt64.self,
            forKey: .cpuPlanCacheHitCount
        )
        cpuPlanCacheMissCount = try container.decode(
            UInt64.self,
            forKey: .cpuPlanCacheMissCount
        )
        gpuPlanCacheHitCount = try container.decode(
            UInt64.self,
            forKey: .gpuPlanCacheHitCount
        )
        gpuPlanCacheMissCount = try container.decode(
            UInt64.self,
            forKey: .gpuPlanCacheMissCount
        )
        cachedPlanMetalBufferBytes = try container.decode(
            Int.self,
            forKey: .cachedPlanMetalBufferBytes
        )
        uploadRingMetalBufferBytes = try container.decode(
            Int.self,
            forKey: .uploadRingMetalBufferBytes
        )
        residentResourceBytes = try container.decode(
            Int.self,
            forKey: .residentResourceBytes
        )
        residentResourceHighWaterBytes = try container.decode(
            Int.self,
            forKey: .residentResourceHighWaterBytes
        )
        planMetalBufferAllocationCount = try container.decode(
            Int.self,
            forKey: .planMetalBufferAllocationCount
        )
        activeUploadSlotCount = try container.decode(
            Int.self,
            forKey: .activeUploadSlotCount
        )
        uploadSlotHighWater = try container.decode(
            Int.self,
            forKey: .uploadSlotHighWater
        )
        pendingPlanCompletionCount = try container.decode(
            Int.self,
            forKey: .pendingPlanCompletionCount
        )
        pendingConsumerCompletionCount = try container.decode(
            Int.self,
            forKey: .pendingConsumerCompletionCount
        )
        revisionResidentBytes = try container.decode(
            Int.self,
            forKey: .revisionResidentBytes
        )
        activeSnapshotTokenCount = try container.decode(
            Int.self,
            forKey: .activeSnapshotTokenCount
        )
        retainedDisplaySnapshotTokenCount = try container.decodeIfPresent(
            Int.self,
            forKey: .retainedDisplaySnapshotTokenCount
        ) ?? 0
        retainedHistorySnapshotTokenCount = try container.decodeIfPresent(
            Int.self,
            forKey: .retainedHistorySnapshotTokenCount
        ) ?? 0
        aggregateSnapshotReferenceCount = try container.decode(
            Int.self,
            forKey: .aggregateSnapshotReferenceCount
        )
        activeTileLeaseCount = try container.decode(
            Int.self,
            forKey: .activeTileLeaseCount
        )
        activeStrokeSurfaceCount = try container.decode(
            Int.self,
            forKey: .activeStrokeSurfaceCount
        )
        activeCommandOperationCount = try container.decode(
            Int.self,
            forKey: .activeCommandOperationCount
        )
        pendingLayerDisplayAcknowledgementCount = try container.decode(
            Int.self,
            forKey: .pendingLayerDisplayAcknowledgementCount
        )
    }
}

public enum StageDAcceptanceStorageAuthority: String, Codable, Sendable {
    case sparseRGBA16Float
}

public protocol StrokeRuntimeTimestampSource: Sendable {
    func nowNanoseconds() -> UInt64
}

public struct StrokeRuntimeUptimeTimestampSource:
    StrokeRuntimeTimestampSource, Sendable
{
    public init() {}

    public func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

public enum StrokeRuntimeTraceProfile: String, Codable, Sendable {
    case productionTenSeconds
    case productionAcceleratedTenMinutes
    case syntheticTest

    public var requiredMovedSampleCount: Int {
        isProduction ? 600 : 0
    }

    public var requiredLongStrokeFrameCount: Int {
        isProduction ? BenchmarkLongStrokeMetrics.segmentCount : 0
    }

    public var logicalDurationNanoseconds: UInt64 {
        switch self {
        case .productionTenSeconds:
            10_000_000_000
        case .productionAcceleratedTenMinutes:
            600_000_000_000
        case .syntheticTest:
            0
        }
    }

    public var requiredWallDurationNanoseconds: UInt64 {
        switch self {
        case .productionTenSeconds, .productionAcceleratedTenMinutes:
            10_000_000_000
        case .syntheticTest:
            0
        }
    }

    public func logicalDuration(forWallDuration wall: UInt64) -> UInt64 {
        guard isAccelerated else { return wall }
        let (scaled, overflow) = wall.multipliedReportingOverflow(by: 60)
        return overflow ? .max : scaled
    }

    public var isAccelerated: Bool {
        self == .productionAcceleratedTenMinutes
    }

    public var isProduction: Bool {
        switch self {
        case .productionTenSeconds, .productionAcceleratedTenMinutes:
            true
        case .syntheticTest:
            false
        }
    }
}

/// Deterministic production performance workload. The circular path keeps an
/// exact four-point chord between inputs while fitting a bounded display plan.
/// Equal input spacing keeps the long-stroke latency comparison independent of
/// spacing aliases without making a synthetic 600-frame line require a 4K
/// render target.
public enum StrokeRuntimeTraceWorkload {
    public static let canvasDimension = 512

    public static func position(frameIndex: Int) -> ScreenPoint {
        precondition(frameIndex >= 0)
        let radius = 200.0
        let chord = 4.0
        let angle = Double(frameIndex) * 2 * asin(chord / (2 * radius))
        return ScreenPoint(
            x: 256 + Float(radius * cos(angle)),
            y: 256 + Float(radius * sin(angle))
        )
    }
}

public enum StrokeRuntimeRecorderOrigin: String, Codable, Sendable {
    case productionRenderer
    case syntheticOrImported
}

public enum StrokeRuntimePresentationSemantics: String, Codable, Sendable {
    case drawablePresented
    case offscreenCommandCompleted
    case mixed
    case unknown
}

public struct StrokeRuntimeRecorderAttestation:
    Codable, Equatable, Sendable
{
    public let origin: StrokeRuntimeRecorderOrigin
    public let traceProfile: StrokeRuntimeTraceProfile
    public let completeFrameEventCount: UInt64
    public let queueObservationCount: UInt64
    public let longestBacklogGrowthRun: UInt64
    public let firstInputTimestamp: UInt64?
    public let lastPresentationTimestamp: UInt64?
    public let begunFrameEventCount: UInt64
    public let attributedFrameEventCount: UInt64
    public let discardedFrameEventCount: UInt64
    public let unconsumedInputEventCount: UInt64
    public let presentationSemantics: StrokeRuntimePresentationSemantics

    fileprivate init(
        origin: StrokeRuntimeRecorderOrigin,
        traceProfile: StrokeRuntimeTraceProfile,
        completeFrameEventCount: UInt64,
        queueObservationCount: UInt64,
        longestBacklogGrowthRun: UInt64,
        firstInputTimestamp: UInt64?,
        lastPresentationTimestamp: UInt64?,
        begunFrameEventCount: UInt64,
        attributedFrameEventCount: UInt64,
        discardedFrameEventCount: UInt64,
        unconsumedInputEventCount: UInt64,
        presentationSemantics: StrokeRuntimePresentationSemantics
    ) {
        self.origin = origin
        self.traceProfile = traceProfile
        self.completeFrameEventCount = completeFrameEventCount
        self.queueObservationCount = queueObservationCount
        self.longestBacklogGrowthRun = longestBacklogGrowthRun
        self.firstInputTimestamp = firstInputTimestamp
        self.lastPresentationTimestamp = lastPresentationTimestamp
        self.begunFrameEventCount = begunFrameEventCount
        self.attributedFrameEventCount = attributedFrameEventCount
        self.discardedFrameEventCount = discardedFrameEventCount
        self.unconsumedInputEventCount = unconsumedInputEventCount
        self.presentationSemantics = presentationSemantics
    }

    private enum CodingKeys: String, CodingKey {
        case origin
        case traceProfile
        case completeFrameEventCount
        case queueObservationCount
        case longestBacklogGrowthRun
        case firstInputTimestamp
        case lastPresentationTimestamp
        case begunFrameEventCount
        case attributedFrameEventCount
        case discardedFrameEventCount
        case unconsumedInputEventCount
        case presentationSemantics
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        origin = try container.decode(
            StrokeRuntimeRecorderOrigin.self,
            forKey: .origin
        )
        traceProfile = try container.decode(
            StrokeRuntimeTraceProfile.self,
            forKey: .traceProfile
        )
        completeFrameEventCount = try container.decode(
            UInt64.self,
            forKey: .completeFrameEventCount
        )
        queueObservationCount = try container.decode(
            UInt64.self,
            forKey: .queueObservationCount
        )
        longestBacklogGrowthRun = try container.decode(
            UInt64.self,
            forKey: .longestBacklogGrowthRun
        )
        firstInputTimestamp = try container.decodeIfPresent(
            UInt64.self,
            forKey: .firstInputTimestamp
        )
        lastPresentationTimestamp = try container.decodeIfPresent(
            UInt64.self,
            forKey: .lastPresentationTimestamp
        )
        begunFrameEventCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .begunFrameEventCount
        ) ?? completeFrameEventCount
        attributedFrameEventCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .attributedFrameEventCount
        ) ?? completeFrameEventCount
        discardedFrameEventCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .discardedFrameEventCount
        ) ?? 0
        unconsumedInputEventCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .unconsumedInputEventCount
        ) ?? 0
        presentationSemantics = try container.decodeIfPresent(
            StrokeRuntimePresentationSemantics.self,
            forKey: .presentationSemantics
        ) ?? .unknown
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(origin, forKey: .origin)
        try container.encode(traceProfile, forKey: .traceProfile)
        try container.encode(
            completeFrameEventCount,
            forKey: .completeFrameEventCount
        )
        try container.encode(
            queueObservationCount,
            forKey: .queueObservationCount
        )
        try container.encode(
            longestBacklogGrowthRun,
            forKey: .longestBacklogGrowthRun
        )
        try container.encodeIfPresent(
            firstInputTimestamp,
            forKey: .firstInputTimestamp
        )
        try container.encodeIfPresent(
            lastPresentationTimestamp,
            forKey: .lastPresentationTimestamp
        )
        try container.encode(
            begunFrameEventCount,
            forKey: .begunFrameEventCount
        )
        try container.encode(
            attributedFrameEventCount,
            forKey: .attributedFrameEventCount
        )
        try container.encode(
            discardedFrameEventCount,
            forKey: .discardedFrameEventCount
        )
        try container.encode(
            unconsumedInputEventCount,
            forKey: .unconsumedInputEventCount
        )
        try container.encode(
            presentationSemantics,
            forKey: .presentationSemantics
        )
    }

    public static func == (
        lhs: StrokeRuntimeRecorderAttestation,
        rhs: StrokeRuntimeRecorderAttestation
    ) -> Bool {
        lhs.origin == rhs.origin
            && lhs.traceProfile == rhs.traceProfile
            && lhs.completeFrameEventCount == rhs.completeFrameEventCount
            && lhs.queueObservationCount == rhs.queueObservationCount
            && lhs.longestBacklogGrowthRun == rhs.longestBacklogGrowthRun
            && lhs.firstInputTimestamp == rhs.firstInputTimestamp
            && lhs.lastPresentationTimestamp == rhs.lastPresentationTimestamp
            && lhs.begunFrameEventCount == rhs.begunFrameEventCount
            && lhs.attributedFrameEventCount
                == rhs.attributedFrameEventCount
            && lhs.discardedFrameEventCount == rhs.discardedFrameEventCount
            && lhs.unconsumedInputEventCount
                == rhs.unconsumedInputEventCount
            && lhs.presentationSemantics == rhs.presentationSemantics
    }
}

public enum StrokeRuntimeInputProvenance: String, Codable, Sendable {
    case actual
    case coalesced
    case predicted
    case estimatedUpdate
}

public struct StrokeRuntimeInputProvenanceCounts:
    Codable, Equatable, Sendable
{
    public var actual: UInt64
    public var coalesced: UInt64
    public var predicted: UInt64
    public var estimatedUpdate: UInt64

    public static let zero = StrokeRuntimeInputProvenanceCounts(
        actual: 0,
        coalesced: 0,
        predicted: 0,
        estimatedUpdate: 0
    )

    public init(
        actual: UInt64,
        coalesced: UInt64,
        predicted: UInt64,
        estimatedUpdate: UInt64
    ) {
        self.actual = actual
        self.coalesced = coalesced
        self.predicted = predicted
        self.estimatedUpdate = estimatedUpdate
    }

    mutating func record(
        _ provenance: StrokeRuntimeInputProvenance,
        count: UInt64
    ) {
        switch provenance {
        case .actual:
            actual = Self.saturatingAdd(actual, count)
        case .coalesced:
            coalesced = Self.saturatingAdd(coalesced, count)
        case .predicted:
            predicted = Self.saturatingAdd(predicted, count)
        case .estimatedUpdate:
            estimatedUpdate = Self.saturatingAdd(estimatedUpdate, count)
        }
    }

    private static func saturatingAdd(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }
}

public struct StrokeRuntimeFrameTimestamps:
    Codable, Equatable, Sendable
{
    public let input: UInt64
    public let prepareStarted: UInt64
    public let prepareFinished: UInt64
    public let submitted: UInt64
    public let gpuStarted: UInt64
    public let gpuFinished: UInt64
    public let presented: UInt64

    public init(
        input: UInt64,
        prepareStarted: UInt64,
        prepareFinished: UInt64,
        submitted: UInt64,
        gpuStarted: UInt64,
        gpuFinished: UInt64,
        presented: UInt64
    ) {
        self.input = input
        self.prepareStarted = prepareStarted
        self.prepareFinished = prepareFinished
        self.submitted = submitted
        self.gpuStarted = gpuStarted
        self.gpuFinished = gpuFinished
        self.presented = presented
    }
}

public struct StrokeRuntimeFrameSample: Codable, Equatable, Sendable {
    public let strokeID: UUID
    public let timestamps: StrokeRuntimeFrameTimestamps
    public let targetFrameDurationNanoseconds: UInt64
    public let newLogicalDabCount: UInt64
    public let newProjectedDabCount: UInt64
    public let authoritativeReplayCount: UInt64
    public let predictedReplayCount: UInt64
    public let authoritativeQueueDepth: Int
    public let predictedQueueDepth: Int
    public let cacheHitCount: UInt64
    public let cacheMissCount: UInt64
    public let residentMemoryBytes: UInt64
    public let inputWasAttributed: Bool
    public let presentationSemantics: StrokeRuntimePresentationSemantics

    public init(
        strokeID: UUID,
        timestamps: StrokeRuntimeFrameTimestamps,
        targetFrameDurationNanoseconds: UInt64,
        newLogicalDabCount: UInt64,
        newProjectedDabCount: UInt64,
        authoritativeReplayCount: UInt64,
        predictedReplayCount: UInt64,
        authoritativeQueueDepth: Int,
        predictedQueueDepth: Int,
        cacheHitCount: UInt64,
        cacheMissCount: UInt64,
        residentMemoryBytes: UInt64,
        inputWasAttributed: Bool = true,
        presentationSemantics: StrokeRuntimePresentationSemantics =
            .drawablePresented
    ) {
        self.strokeID = strokeID
        self.timestamps = timestamps
        self.targetFrameDurationNanoseconds =
            targetFrameDurationNanoseconds
        self.newLogicalDabCount = newLogicalDabCount
        self.newProjectedDabCount = newProjectedDabCount
        self.authoritativeReplayCount = authoritativeReplayCount
        self.predictedReplayCount = predictedReplayCount
        self.authoritativeQueueDepth = authoritativeQueueDepth
        self.predictedQueueDepth = predictedQueueDepth
        self.cacheHitCount = cacheHitCount
        self.cacheMissCount = cacheMissCount
        self.residentMemoryBytes = residentMemoryBytes
        self.inputWasAttributed = inputWasAttributed
        self.presentationSemantics = presentationSemantics
    }
}

public enum StrokeRuntimeSegmentEventKind: String, Codable, Sendable {
    case segmentBegan
    case segmentEnded
}

public struct StrokeRuntimeSegmentMarker: Codable, Equatable, Sendable {
    public let kind: StrokeRuntimeSegmentEventKind
    public let sessionID: UUID
    public let segmentID: UUID
    public let strokeID: UUID?
    public let timestampNanoseconds: UInt64
    public let traceProfile: StrokeRuntimeTraceProfile

    public init(
        kind: StrokeRuntimeSegmentEventKind,
        sessionID: UUID,
        segmentID: UUID,
        strokeID: UUID?,
        timestampNanoseconds: UInt64,
        traceProfile: StrokeRuntimeTraceProfile
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.strokeID = strokeID
        self.timestampNanoseconds = timestampNanoseconds
        self.traceProfile = traceProfile
    }
}

public struct StrokeRuntimeTelemetrySnapshot:
    Codable, Equatable, Sendable
{
    public let sessionID: UUID
    public let segmentID: UUID?
    public let strokeID: UUID?
    public let traceProfile: StrokeRuntimeTraceProfile
    public let inputProvenance: StrokeRuntimeInputProvenanceCounts
    public let newLogicalDabCount: UInt64
    public let newProjectedDabCount: UInt64
    public let authoritativeReplayCount: UInt64
    public let predictedReplayCount: UInt64
    public let authoritativeQueueDepth: Int
    public let predictedQueueDepth: Int
    public let authoritativeQueueHighWater: Int
    public let predictedQueueHighWater: Int
    public let prepare: DepositionDurationPercentiles
    public let eventToSubmit: DepositionDurationPercentiles
    public let gpu: DepositionDurationPercentiles
    public let frame: DepositionDurationPercentiles
    public let missedFrameCount: UInt64
    public let eventToSubmitMissCount: UInt64
    public let frameCount: UInt64
    public let attributedFrameCount: UInt64?
    public let observedDurationNanoseconds: UInt64
    public let wallDurationNanoseconds: UInt64
    public let logicalDurationNanoseconds: UInt64
    public let cacheHitCount: UInt64
    public let cacheMissCount: UInt64
    public let memoryHighWaterBytes: UInt64
    public let authoritativeQueueDepths: [Int]
    public let lastTimestamps: StrokeRuntimeFrameTimestamps?
    public let frameRecords: [StrokeRuntimeFrameSample]?
    public let traceOverflowCount: UInt64?
    public private(set) var attestation: StrokeRuntimeRecorderAttestation?

    public var missedFrameFraction: Double {
        guard frameCount > 0 else { return 0 }
        return Double(missedFrameCount) / Double(frameCount)
    }

    public var eventToSubmitMissFraction: Double {
        let denominator = attributedFrameCount ?? frameCount
        guard denominator > 0 else { return 0 }
        return Double(eventToSubmitMissCount) / Double(denominator)
    }

    public func requiredLongStrokeMetrics(
        validatesPerformance: Bool = true
    ) throws -> BenchmarkLongStrokeMetrics {
        let attributed = (frameRecords ?? []).filter(\.inputWasAttributed)
        guard attributed.count >= BenchmarkLongStrokeMetrics.segmentCount else {
            throw BenchmarkMetricError.insufficientLongStrokeFrames(
                attributed.count
            )
        }
        let measured = attributed.suffix(
            BenchmarkLongStrokeMetrics.segmentCount
        )
        var cpuMilliseconds: [Double] = []
        var gpuMilliseconds: [Double] = []
        var projectedInstanceCounts: [Int] = []
        cpuMilliseconds.reserveCapacity(BenchmarkLongStrokeMetrics.segmentCount)
        gpuMilliseconds.reserveCapacity(BenchmarkLongStrokeMetrics.segmentCount)
        projectedInstanceCounts.reserveCapacity(
            BenchmarkLongStrokeMetrics.segmentCount
        )
        for (index, frame) in measured.enumerated() {
            cpuMilliseconds.append(
                Double(
                    frame.timestamps.prepareFinished
                        - frame.timestamps.prepareStarted
                ) / 1_000_000
            )
            gpuMilliseconds.append(
                Double(
                    frame.timestamps.gpuFinished
                        - frame.timestamps.gpuStarted
                ) / 1_000_000
            )
            guard frame.newProjectedDabCount <= UInt64(Int.max) else {
                throw BenchmarkMetricError.projectedInstanceCountOverflow(
                    frame: index,
                    actual: frame.newProjectedDabCount
                )
            }
            projectedInstanceCounts.append(Int(frame.newProjectedDabCount))
        }
        return try BenchmarkLongStrokeMetrics.measure(
            cpuMilliseconds: cpuMilliseconds,
            dabGPUMilliseconds: gpuMilliseconds,
            projectedInstanceCounts: projectedInstanceCounts,
            validatesPerformance: validatesPerformance
        )
    }

    public init(
        sessionID: UUID,
        segmentID: UUID?,
        strokeID: UUID?,
        traceProfile: StrokeRuntimeTraceProfile,
        inputProvenance: StrokeRuntimeInputProvenanceCounts,
        newLogicalDabCount: UInt64,
        newProjectedDabCount: UInt64,
        authoritativeReplayCount: UInt64,
        predictedReplayCount: UInt64,
        authoritativeQueueDepth: Int,
        predictedQueueDepth: Int,
        authoritativeQueueHighWater: Int,
        predictedQueueHighWater: Int,
        prepare: DepositionDurationPercentiles,
        eventToSubmit: DepositionDurationPercentiles,
        gpu: DepositionDurationPercentiles,
        frame: DepositionDurationPercentiles,
        missedFrameCount: UInt64,
        eventToSubmitMissCount: UInt64,
        frameCount: UInt64,
        attributedFrameCount: UInt64? = nil,
        observedDurationNanoseconds: UInt64,
        wallDurationNanoseconds: UInt64? = nil,
        logicalDurationNanoseconds: UInt64? = nil,
        cacheHitCount: UInt64,
        cacheMissCount: UInt64,
        memoryHighWaterBytes: UInt64,
        authoritativeQueueDepths: [Int],
        lastTimestamps: StrokeRuntimeFrameTimestamps?,
        frameRecords: [StrokeRuntimeFrameSample]? = nil,
        traceOverflowCount: UInt64? = nil
    ) {
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.strokeID = strokeID
        self.traceProfile = traceProfile
        self.inputProvenance = inputProvenance
        self.newLogicalDabCount = newLogicalDabCount
        self.newProjectedDabCount = newProjectedDabCount
        self.authoritativeReplayCount = authoritativeReplayCount
        self.predictedReplayCount = predictedReplayCount
        self.authoritativeQueueDepth = authoritativeQueueDepth
        self.predictedQueueDepth = predictedQueueDepth
        self.authoritativeQueueHighWater = authoritativeQueueHighWater
        self.predictedQueueHighWater = predictedQueueHighWater
        self.prepare = prepare
        self.eventToSubmit = eventToSubmit
        self.gpu = gpu
        self.frame = frame
        self.missedFrameCount = missedFrameCount
        self.eventToSubmitMissCount = eventToSubmitMissCount
        self.frameCount = frameCount
        self.attributedFrameCount = attributedFrameCount
        self.observedDurationNanoseconds = observedDurationNanoseconds
        self.wallDurationNanoseconds =
            wallDurationNanoseconds ?? observedDurationNanoseconds
        self.logicalDurationNanoseconds =
            logicalDurationNanoseconds ?? observedDurationNanoseconds
        self.cacheHitCount = cacheHitCount
        self.cacheMissCount = cacheMissCount
        self.memoryHighWaterBytes = memoryHighWaterBytes
        self.authoritativeQueueDepths = authoritativeQueueDepths
        self.lastTimestamps = lastTimestamps
        self.frameRecords = frameRecords
        self.traceOverflowCount = traceOverflowCount
        attestation = nil
    }

    mutating func attest(
        origin: StrokeRuntimeRecorderOrigin,
        traceProfile: StrokeRuntimeTraceProfile,
        completeFrameEventCount: UInt64,
        queueObservationCount: UInt64,
        longestBacklogGrowthRun: UInt64,
        firstInputTimestamp: UInt64?,
        lastPresentationTimestamp: UInt64?,
        begunFrameEventCount: UInt64? = nil,
        attributedFrameEventCount: UInt64? = nil,
        discardedFrameEventCount: UInt64 = 0,
        unconsumedInputEventCount: UInt64 = 0,
        presentationSemantics: StrokeRuntimePresentationSemantics =
            .drawablePresented
    ) {
        attestation = StrokeRuntimeRecorderAttestation(
            origin: origin,
            traceProfile: traceProfile,
            completeFrameEventCount: completeFrameEventCount,
            queueObservationCount: queueObservationCount,
            longestBacklogGrowthRun: longestBacklogGrowthRun,
            firstInputTimestamp: firstInputTimestamp,
            lastPresentationTimestamp: lastPresentationTimestamp,
            begunFrameEventCount:
                begunFrameEventCount ?? completeFrameEventCount,
            attributedFrameEventCount:
                attributedFrameEventCount ?? completeFrameEventCount,
            discardedFrameEventCount: discardedFrameEventCount,
            unconsumedInputEventCount: unconsumedInputEventCount,
            presentationSemantics: presentationSemantics
        )
    }
}

/// A live, renderer-issued capability for running the production software
/// gate. The persisted report is intentionally Codable; this wrapper is not.
/// Its initializer is module-internal so imported or decoded reports cannot
/// manufacture production provenance.
public struct StrokeRuntimeRecordedEvidence: Sendable {
    public let report: StrokeRuntimeTelemetrySnapshot

    fileprivate init(report: StrokeRuntimeTelemetrySnapshot) {
        self.report = report
    }
}

public enum StrokeRuntimeTelemetryError: Error, Equatable {
    case segmentAlreadyActive
    case noActiveSegment
    case strokeDoesNotMatchSegment
    case invalidQueueDepth
    case invalidTargetFrameDuration
    case invalidTimestampOrder
    case timestampRegression
    case duplicateFrame
    case unknownFrame
    case incompleteFrameEvents
}

public struct StrokeRuntimeTelemetry: Sendable {
    public var snapshot: StrokeRuntimeTelemetrySnapshot {
        snapshot(
            begunFrameEventCount: frameCount,
            discardedFrameEventCount: 0,
            unconsumedInputEventCount: 0,
            includeFrameRecords: true
        )
    }

    func snapshot(
        begunFrameEventCount: UInt64,
        discardedFrameEventCount: UInt64,
        unconsumedInputEventCount: UInt64,
        includeFrameRecords: Bool
    ) -> StrokeRuntimeTelemetrySnapshot {
        var snapshot = StrokeRuntimeTelemetrySnapshot(
            sessionID: sessionID,
            segmentID: segmentID,
            strokeID: strokeID,
            traceProfile: traceProfile,
            inputProvenance: inputProvenance,
            newLogicalDabCount: newLogicalDabCount,
            newProjectedDabCount: newProjectedDabCount,
            authoritativeReplayCount: authoritativeReplayCount,
            predictedReplayCount: predictedReplayCount,
            authoritativeQueueDepth: authoritativeQueueDepth,
            predictedQueueDepth: predictedQueueDepth,
            authoritativeQueueHighWater: authoritativeQueueHighWater,
            predictedQueueHighWater: predictedQueueHighWater,
            prepare: prepareWindow.percentiles(),
            eventToSubmit: eventToSubmitWindow.percentiles(),
            gpu: gpuWindow.percentiles(),
            frame: frameWindow.percentiles(),
            missedFrameCount: missedFrameCount,
            eventToSubmitMissCount: eventToSubmitMissCount,
            frameCount: frameCount,
            attributedFrameCount: attributedFrameCount,
            observedDurationNanoseconds: observedDurationNanoseconds,
            wallDurationNanoseconds: observedDurationNanoseconds,
            logicalDurationNanoseconds: traceProfile.logicalDuration(
                forWallDuration: observedDurationNanoseconds
            ),
            cacheHitCount: cacheHitCount,
            cacheMissCount: cacheMissCount,
            memoryHighWaterBytes: memoryHighWaterBytes,
            authoritativeQueueDepths: authoritativeQueueDepths.elements,
            lastTimestamps: lastTimestamps,
            frameRecords: includeFrameRecords ? Array(frameRecords) : nil,
            traceOverflowCount: includeFrameRecords ? traceOverflowCount : nil
        )
        snapshot.attest(
            origin: recorderOrigin,
            traceProfile: traceProfile,
            completeFrameEventCount: frameCount,
            queueObservationCount: queueObservationCount,
            longestBacklogGrowthRun: longestBacklogGrowthRun,
            firstInputTimestamp: firstInputTimestamp,
            lastPresentationTimestamp: lastTimestamps?.presented,
            begunFrameEventCount: begunFrameEventCount,
            attributedFrameEventCount: attributedFrameCount,
            discardedFrameEventCount: discardedFrameEventCount,
            unconsumedInputEventCount: unconsumedInputEventCount,
            presentationSemantics: presentationSemantics ?? .unknown
        )
        return snapshot
    }

    private let sessionID: UUID
    private let traceProfile: StrokeRuntimeTraceProfile
    private let timestampSource: any StrokeRuntimeTimestampSource
    private let recorderOrigin: StrokeRuntimeRecorderOrigin
    private let queueWindowCapacity: Int
    private let frameRecordCapacity: Int
    private var segmentID: UUID?
    private var strokeID: UUID?
    private var segmentActive = false
    private var inputProvenance = StrokeRuntimeInputProvenanceCounts.zero
    private var newLogicalDabCount: UInt64 = 0
    private var newProjectedDabCount: UInt64 = 0
    private var authoritativeReplayCount: UInt64 = 0
    private var predictedReplayCount: UInt64 = 0
    private var authoritativeQueueDepth = 0
    private var predictedQueueDepth = 0
    private var authoritativeQueueHighWater = 0
    private var predictedQueueHighWater = 0
    private var prepareWindow: BoundedDurationWindow
    private var eventToSubmitWindow: BoundedDurationWindow
    private var gpuWindow: BoundedDurationWindow
    private var frameWindow: BoundedDurationWindow
    private var missedFrameCount: UInt64 = 0
    private var eventToSubmitMissCount: UInt64 = 0
    private var frameCount: UInt64 = 0
    private var attributedFrameCount: UInt64 = 0
    private var firstInputTimestamp: UInt64?
    private var observedDurationNanoseconds: UInt64 = 0
    private var cacheHitCount: UInt64 = 0
    private var cacheMissCount: UInt64 = 0
    private var memoryHighWaterBytes: UInt64 = 0
    private var authoritativeQueueDepths: BoundedIntWindow
    private var previousPresentationTimestamp: UInt64?
    private var lastTimestamps: StrokeRuntimeFrameTimestamps?
    private var queueObservationCount: UInt64 = 0
    private var currentBacklogGrowthRun: UInt64 = 0
    private var longestBacklogGrowthRun: UInt64 = 0
    private var previousAuthoritativeQueueDepth: Int?
    private var backlogRunHasGrowth = false
    private var presentationSemantics: StrokeRuntimePresentationSemantics?
    private var frameRecords: ContiguousArray<StrokeRuntimeFrameSample> = []
    private var traceOverflowCount: UInt64 = 0

    public init(
        sessionID: UUID = UUID(),
        traceProfile: StrokeRuntimeTraceProfile,
        windowCapacity: Int = 600,
        timestampSource: any StrokeRuntimeTimestampSource =
            StrokeRuntimeUptimeTimestampSource()
    ) {
        precondition(windowCapacity > 0)
        self.sessionID = sessionID
        self.traceProfile = traceProfile
        self.timestampSource = timestampSource
        recorderOrigin = .syntheticOrImported
        queueWindowCapacity = windowCapacity
        frameRecordCapacity = windowCapacity
        prepareWindow = BoundedDurationWindow(capacity: windowCapacity)
        eventToSubmitWindow = BoundedDurationWindow(
            capacity: windowCapacity
        )
        gpuWindow = BoundedDurationWindow(capacity: windowCapacity)
        frameWindow = BoundedDurationWindow(capacity: windowCapacity)
        authoritativeQueueDepths = BoundedIntWindow(capacity: windowCapacity)
        frameRecords.reserveCapacity(windowCapacity)
    }

    init(
        sessionID: UUID,
        traceProfile: StrokeRuntimeTraceProfile,
        windowCapacity: Int,
        frameRecordCapacity: Int,
        timestampSource: any StrokeRuntimeTimestampSource,
        recorderOrigin: StrokeRuntimeRecorderOrigin
    ) {
        precondition(windowCapacity > 0)
        precondition(frameRecordCapacity > 0)
        self.sessionID = sessionID
        self.traceProfile = traceProfile
        self.timestampSource = timestampSource
        self.recorderOrigin = recorderOrigin
        queueWindowCapacity = windowCapacity
        self.frameRecordCapacity = frameRecordCapacity
        prepareWindow = BoundedDurationWindow(capacity: windowCapacity)
        eventToSubmitWindow = BoundedDurationWindow(capacity: windowCapacity)
        gpuWindow = BoundedDurationWindow(capacity: windowCapacity)
        frameWindow = BoundedDurationWindow(capacity: windowCapacity)
        authoritativeQueueDepths = BoundedIntWindow(capacity: windowCapacity)
        frameRecords.reserveCapacity(frameRecordCapacity)
    }

    public mutating func beginSegment(
        id: UUID = UUID(),
        strokeID: UUID? = nil
    ) throws -> StrokeRuntimeSegmentMarker {
        guard !segmentActive else {
            throw StrokeRuntimeTelemetryError.segmentAlreadyActive
        }
        resetSegmentAggregation()
        segmentID = id
        self.strokeID = strokeID
        segmentActive = true
        return marker(.segmentBegan, segmentID: id)
    }

    public mutating func endSegment()
        throws -> StrokeRuntimeSegmentMarker
    {
        guard segmentActive, let segmentID else {
            throw StrokeRuntimeTelemetryError.noActiveSegment
        }
        let marker = marker(.segmentEnded, segmentID: segmentID)
        segmentActive = false
        return marker
    }

    public mutating func recordInput(
        _ provenance: StrokeRuntimeInputProvenance,
        count: UInt64 = 1
    ) {
        inputProvenance.record(provenance, count: count)
    }

    public mutating func recordFrame(
        _ sample: StrokeRuntimeFrameSample
    ) throws {
        guard segmentActive else {
            throw StrokeRuntimeTelemetryError.noActiveSegment
        }
        if let strokeID, strokeID != sample.strokeID {
            throw StrokeRuntimeTelemetryError.strokeDoesNotMatchSegment
        }
        guard sample.authoritativeQueueDepth >= 0,
              sample.predictedQueueDepth >= 0
        else {
            throw StrokeRuntimeTelemetryError.invalidQueueDepth
        }
        guard sample.targetFrameDurationNanoseconds > 0 else {
            throw StrokeRuntimeTelemetryError.invalidTargetFrameDuration
        }
        let timestamps = sample.timestamps
        guard timestamps.input <= timestamps.prepareStarted,
              timestamps.prepareStarted <= timestamps.prepareFinished,
              timestamps.prepareFinished <= timestamps.submitted,
              timestamps.submitted <= timestamps.gpuStarted,
              timestamps.gpuStarted <= timestamps.gpuFinished,
              timestamps.gpuFinished <= timestamps.presented
        else {
            throw StrokeRuntimeTelemetryError.invalidTimestampOrder
        }
        if let previous = lastTimestamps {
            guard previous.input <= timestamps.input,
                  previous.prepareStarted <= timestamps.prepareStarted,
                  previous.prepareFinished <= timestamps.prepareFinished,
                  previous.submitted <= timestamps.submitted,
                  previous.gpuStarted <= timestamps.gpuStarted,
                  previous.gpuFinished <= timestamps.gpuFinished,
                  previous.presented < timestamps.presented
            else {
                throw StrokeRuntimeTelemetryError.timestampRegression
            }
        }

        strokeID = sample.strokeID
        let prepare = timestamps.prepareFinished
            - timestamps.prepareStarted
        let eventToSubmit = timestamps.submitted - timestamps.input
        let gpu = timestamps.gpuFinished - timestamps.gpuStarted
        prepareWindow.append(prepare)
        gpuWindow.append(gpu)
        if sample.inputWasAttributed {
            eventToSubmitWindow.append(eventToSubmit)
            attributedFrameCount = Self.saturatingAdd(
                attributedFrameCount,
                1
            )
            if firstInputTimestamp == nil {
                firstInputTimestamp = timestamps.input
            }
            if eventToSubmit > sample.targetFrameDurationNanoseconds {
                eventToSubmitMissCount = Self.saturatingAdd(
                    eventToSubmitMissCount,
                    1
                )
            }
        }
        if let currentSemantics = presentationSemantics,
           currentSemantics != sample.presentationSemantics
        {
            presentationSemantics = .mixed
        } else if presentationSemantics == nil {
            presentationSemantics = sample.presentationSemantics
        }

        if sample.presentationSemantics == .drawablePresented {
            if let previousPresentationTimestamp,
               timestamps.presented > previousPresentationTimestamp
            {
                let interval = timestamps.presented
                    - previousPresentationTimestamp
                frameWindow.append(interval)
                let expectedFrames = max(
                    UInt64(1),
                    Self.roundedQuotient(
                        interval,
                        sample.targetFrameDurationNanoseconds
                    )
                )
                if expectedFrames > 1 {
                    missedFrameCount = Self.saturatingAdd(
                        missedFrameCount,
                        expectedFrames - 1
                    )
                }
            }
            previousPresentationTimestamp = timestamps.presented
        }
        if let firstInputTimestamp,
           timestamps.presented >= firstInputTimestamp
        {
            observedDurationNanoseconds = timestamps.presented
                - firstInputTimestamp
        }

        newLogicalDabCount = Self.saturatingAdd(
            newLogicalDabCount,
            sample.newLogicalDabCount
        )
        newProjectedDabCount = Self.saturatingAdd(
            newProjectedDabCount,
            sample.newProjectedDabCount
        )
        authoritativeReplayCount = Self.saturatingAdd(
            authoritativeReplayCount,
            sample.authoritativeReplayCount
        )
        predictedReplayCount = Self.saturatingAdd(
            predictedReplayCount,
            sample.predictedReplayCount
        )
        authoritativeQueueDepth = sample.authoritativeQueueDepth
        predictedQueueDepth = sample.predictedQueueDepth
        authoritativeQueueHighWater = max(
            authoritativeQueueHighWater,
            sample.authoritativeQueueDepth
        )
        predictedQueueHighWater = max(
            predictedQueueHighWater,
            sample.predictedQueueDepth
        )
        recordBacklogEvidence(sample.authoritativeQueueDepth)
        authoritativeQueueDepths.append(sample.authoritativeQueueDepth)
        cacheHitCount = Self.saturatingAdd(
            cacheHitCount,
            sample.cacheHitCount
        )
        cacheMissCount = Self.saturatingAdd(
            cacheMissCount,
            sample.cacheMissCount
        )
        memoryHighWaterBytes = max(
            memoryHighWaterBytes,
            sample.residentMemoryBytes
        )
        if frameRecords.count < frameRecordCapacity {
            frameRecords.append(sample)
        } else {
            traceOverflowCount = Self.saturatingAdd(traceOverflowCount, 1)
        }
        frameCount = Self.saturatingAdd(frameCount, 1)
        lastTimestamps = timestamps
    }

    private mutating func recordBacklogEvidence(_ depth: Int) {
        queueObservationCount = Self.saturatingAdd(queueObservationCount, 1)
        defer { previousAuthoritativeQueueDepth = depth }
        guard let previous = previousAuthoritativeQueueDepth else {
            currentBacklogGrowthRun = 1
            backlogRunHasGrowth = false
            return
        }
        if depth >= previous {
            currentBacklogGrowthRun = Self.saturatingAdd(
                currentBacklogGrowthRun,
                1
            )
            backlogRunHasGrowth = backlogRunHasGrowth || depth > previous
        } else {
            currentBacklogGrowthRun = 1
            backlogRunHasGrowth = false
        }
        if backlogRunHasGrowth {
            longestBacklogGrowthRun = max(
                longestBacklogGrowthRun,
                currentBacklogGrowthRun
            )
        }
    }

    private mutating func resetSegmentAggregation() {
        inputProvenance = .zero
        newLogicalDabCount = 0
        newProjectedDabCount = 0
        authoritativeReplayCount = 0
        predictedReplayCount = 0
        authoritativeQueueDepth = 0
        predictedQueueDepth = 0
        authoritativeQueueHighWater = 0
        predictedQueueHighWater = 0
        prepareWindow = BoundedDurationWindow(capacity: queueWindowCapacity)
        eventToSubmitWindow = BoundedDurationWindow(capacity: queueWindowCapacity)
        gpuWindow = BoundedDurationWindow(capacity: queueWindowCapacity)
        frameWindow = BoundedDurationWindow(capacity: queueWindowCapacity)
        missedFrameCount = 0
        eventToSubmitMissCount = 0
        frameCount = 0
        attributedFrameCount = 0
        firstInputTimestamp = nil
        observedDurationNanoseconds = 0
        cacheHitCount = 0
        cacheMissCount = 0
        memoryHighWaterBytes = 0
        authoritativeQueueDepths.reset()
        previousPresentationTimestamp = nil
        lastTimestamps = nil
        queueObservationCount = 0
        currentBacklogGrowthRun = 0
        longestBacklogGrowthRun = 0
        previousAuthoritativeQueueDepth = nil
        backlogRunHasGrowth = false
        presentationSemantics = nil
        frameRecords.removeAll(keepingCapacity: true)
        traceOverflowCount = 0
    }

    private func marker(
        _ kind: StrokeRuntimeSegmentEventKind,
        segmentID: UUID
    ) -> StrokeRuntimeSegmentMarker {
        StrokeRuntimeSegmentMarker(
            kind: kind,
            sessionID: sessionID,
            segmentID: segmentID,
            strokeID: strokeID,
            timestampNanoseconds: timestampSource.nowNanoseconds(),
            traceProfile: traceProfile
        )
    }

    private static func roundedQuotient(
        _ numerator: UInt64,
        _ denominator: UInt64
    ) -> UInt64 {
        let quotient = numerator / denominator
        let remainder = numerator % denominator
        let roundsUp = remainder >= denominator - remainder
        return quotient + (roundsUp ? 1 : 0)
    }

    private static func saturatingAdd(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }
}

private struct BoundedIntWindow: Sendable {
    private let capacity: Int
    private var values: ContiguousArray<Int>
    private var count = 0
    private var nextIndex = 0

    init(capacity: Int) {
        self.capacity = capacity
        values = ContiguousArray(repeating: 0, count: capacity)
    }

    var elements: [Int] {
        guard count == capacity else {
            return Array(values.prefix(count))
        }
        return Array(values[nextIndex...]) + Array(values[..<nextIndex])
    }

    mutating func append(_ value: Int) {
        values[nextIndex] = value
        nextIndex = (nextIndex + 1) % capacity
        count = min(capacity, count + 1)
    }

    mutating func reset() {
        count = 0
        nextIndex = 0
    }
}

@MainActor
final class StrokeRuntimeProductionController {
    private struct PendingFrame {
        let strokeID: UUID
        let input: UInt64
        let inputWasAttributed: Bool
        let prepareStarted: UInt64
        let targetFrameDurationNanoseconds: UInt64
        var prepareFinished: UInt64?
        var submitted: UInt64?
        var gpuStarted: UInt64?
        var gpuFinished: UInt64?
        var presented: UInt64?
        var presentationSemantics: StrokeRuntimePresentationSemantics =
            .unknown
        var newLogicalDabCount: UInt64 = 0
        var newProjectedDabCount: UInt64 = 0
        var authoritativeReplayCount: UInt64 = 0
        var predictedReplayCount: UInt64 = 0
        var authoritativeQueueDepth = 0
        var predictedQueueDepth = 0
        var cacheHitCount: UInt64 = 0
        var cacheMissCount: UInt64 = 0
        var residentMemoryBytes: UInt64 = 0
    }

    var snapshot: StrokeRuntimeTelemetrySnapshot {
        makeSnapshot(includeFrameRecords: false)
    }
    private func makeSnapshot(
        includeFrameRecords: Bool
    ) -> StrokeRuntimeTelemetrySnapshot {
        telemetry.snapshot(
            begunFrameEventCount: begunFrameEventCount,
            discardedFrameEventCount: discardedFrameEventCount,
            unconsumedInputEventCount: pendingInputEventCount,
            includeFrameRecords: includeFrameRecords
        )
    }
    private(set) var recordedEvidence: StrokeRuntimeRecordedEvidence?

    private var telemetry: StrokeRuntimeTelemetry
    private var activeStrokeID: UUID?
    private var pendingInputTimestamp: UInt64?
    private var pendingInputEventCount: UInt64 = 0
    private var pendingFrames: [UInt64: PendingFrame] = [:]
    private var begunFrameEventCount: UInt64 = 0
    private var completedFrameEventCount: UInt64 = 0
    private var discardedFrameEventCount: UInt64 = 0

    var shouldPublishLiveSnapshot: Bool {
        completedFrameEventCount > 0
            && completedFrameEventCount.isMultiple(of: 15)
    }

    init(
        sessionID: UUID = UUID(),
        traceProfile: StrokeRuntimeTraceProfile,
        windowCapacity: Int = 600,
        traceCapacity: Int = 4_096,
        timestampSource: any StrokeRuntimeTimestampSource =
            StrokeRuntimeUptimeTimestampSource()
    ) {
        telemetry = StrokeRuntimeTelemetry(
            sessionID: sessionID,
            traceProfile: traceProfile,
            windowCapacity: windowCapacity,
            frameRecordCapacity: traceCapacity,
            timestampSource: timestampSource,
            recorderOrigin: .productionRenderer
        )
    }

    @discardableResult
    func beginStroke(
        segmentID: UUID = UUID(),
        strokeID: UUID
    ) throws -> StrokeRuntimeSegmentMarker {
        let marker = try telemetry.beginSegment(
            id: segmentID,
            strokeID: strokeID
        )
        activeStrokeID = strokeID
        pendingInputTimestamp = nil
        pendingInputEventCount = 0
        pendingFrames.removeAll(keepingCapacity: true)
        begunFrameEventCount = 0
        completedFrameEventCount = 0
        discardedFrameEventCount = 0
        recordedEvidence = nil
        return marker
    }

    @discardableResult
    func endStroke() throws -> StrokeRuntimeSegmentMarker {
        guard pendingFrames.isEmpty else {
            throw StrokeRuntimeTelemetryError.incompleteFrameEvents
        }
        let marker = try telemetry.endSegment()
        recordedEvidence = StrokeRuntimeRecordedEvidence(
            report: makeSnapshot(includeFrameRecords: true)
        )
        activeStrokeID = nil
        pendingInputTimestamp = nil
        pendingInputEventCount = 0
        return marker
    }

    func recordInput(
        _ provenance: StrokeRuntimeInputProvenance,
        count: UInt64 = 1,
        at timestamp: UInt64
    ) {
        guard count > 0 else { return }
        telemetry.recordInput(provenance, count: count)
        pendingInputEventCount = Self.saturatingAdd(
            pendingInputEventCount,
            count
        )
        if let pendingInputTimestamp {
            self.pendingInputTimestamp = min(pendingInputTimestamp, timestamp)
        } else {
            pendingInputTimestamp = timestamp
        }
    }

    func beginFrame(
        id: UInt64,
        prepareStarted: UInt64,
        targetFrameDurationNanoseconds: UInt64
    ) throws {
        guard let strokeID = activeStrokeID else {
            throw StrokeRuntimeTelemetryError.noActiveSegment
        }
        guard pendingFrames[id] == nil else {
            throw StrokeRuntimeTelemetryError.duplicateFrame
        }
        let attributedInput = pendingInputTimestamp
        let input = attributedInput ?? prepareStarted
        pendingInputTimestamp = nil
        pendingInputEventCount = 0
        pendingFrames[id] = PendingFrame(
            strokeID: strokeID,
            input: input,
            inputWasAttributed: attributedInput != nil,
            prepareStarted: prepareStarted,
            targetFrameDurationNanoseconds: targetFrameDurationNanoseconds
        )
        begunFrameEventCount = Self.saturatingAdd(
            begunFrameEventCount,
            1
        )
    }

    func recordPrepared(
        id: UInt64,
        at timestamp: UInt64,
        newLogicalDabCount: UInt64,
        newProjectedDabCount: UInt64,
        authoritativeReplayCount: UInt64,
        predictedReplayCount: UInt64,
        authoritativeQueueDepth: Int,
        predictedQueueDepth: Int,
        cacheHitCount: UInt64,
        cacheMissCount: UInt64,
        residentMemoryBytes: UInt64
    ) throws {
        guard var frame = pendingFrames[id] else {
            throw StrokeRuntimeTelemetryError.unknownFrame
        }
        frame.prepareFinished = timestamp
        frame.newLogicalDabCount = newLogicalDabCount
        frame.newProjectedDabCount = newProjectedDabCount
        frame.authoritativeReplayCount = authoritativeReplayCount
        frame.predictedReplayCount = predictedReplayCount
        frame.authoritativeQueueDepth = authoritativeQueueDepth
        frame.predictedQueueDepth = predictedQueueDepth
        frame.cacheHitCount = cacheHitCount
        frame.cacheMissCount = cacheMissCount
        frame.residentMemoryBytes = residentMemoryBytes
        pendingFrames[id] = frame
    }

    func recordSubmitted(id: UInt64, at timestamp: UInt64) throws {
        guard var frame = pendingFrames[id] else {
            throw StrokeRuntimeTelemetryError.unknownFrame
        }
        frame.submitted = timestamp
        pendingFrames[id] = frame
    }

    @discardableResult
    func recordGPU(
        id: UInt64,
        started: UInt64,
        finished: UInt64
    ) throws -> Bool {
        guard var frame = pendingFrames[id] else {
            throw StrokeRuntimeTelemetryError.unknownFrame
        }
        frame.gpuStarted = started
        frame.gpuFinished = finished
        pendingFrames[id] = frame
        return try finalizeFrameIfComplete(id)
    }

    @discardableResult
    func recordPresented(
        id: UInt64,
        at timestamp: UInt64,
        semantics: StrokeRuntimePresentationSemantics = .drawablePresented
    ) throws -> Bool {
        guard var frame = pendingFrames[id] else {
            throw StrokeRuntimeTelemetryError.unknownFrame
        }
        frame.presented = timestamp
        frame.presentationSemantics = semantics
        pendingFrames[id] = frame
        return try finalizeFrameIfComplete(id)
    }

    func discardFrame(id: UInt64) {
        guard pendingFrames.removeValue(forKey: id) != nil else { return }
        discardedFrameEventCount = Self.saturatingAdd(
            discardedFrameEventCount,
            1
        )
    }

    func discardPendingFrames() {
        discardedFrameEventCount = Self.saturatingAdd(
            discardedFrameEventCount,
            UInt64(pendingFrames.count)
        )
        pendingFrames.removeAll(keepingCapacity: true)
    }

    private func finalizeFrameIfComplete(
        _ id: UInt64
    ) throws -> Bool {
        guard let frame = pendingFrames[id] else {
            throw StrokeRuntimeTelemetryError.unknownFrame
        }
        guard let prepareFinished = frame.prepareFinished,
              let submitted = frame.submitted,
              let gpuStarted = frame.gpuStarted,
              let gpuFinished = frame.gpuFinished,
              let presented = frame.presented
        else {
            return false
        }
        try telemetry.recordFrame(StrokeRuntimeFrameSample(
            strokeID: frame.strokeID,
            timestamps: StrokeRuntimeFrameTimestamps(
                input: frame.input,
                prepareStarted: frame.prepareStarted,
                prepareFinished: prepareFinished,
                submitted: submitted,
                gpuStarted: gpuStarted,
                gpuFinished: gpuFinished,
                presented: presented
            ),
            targetFrameDurationNanoseconds:
                frame.targetFrameDurationNanoseconds,
            newLogicalDabCount: frame.newLogicalDabCount,
            newProjectedDabCount: frame.newProjectedDabCount,
            authoritativeReplayCount: frame.authoritativeReplayCount,
            predictedReplayCount: frame.predictedReplayCount,
            authoritativeQueueDepth: frame.authoritativeQueueDepth,
            predictedQueueDepth: frame.predictedQueueDepth,
            cacheHitCount: frame.cacheHitCount,
            cacheMissCount: frame.cacheMissCount,
            residentMemoryBytes: frame.residentMemoryBytes,
            inputWasAttributed: frame.inputWasAttributed,
            presentationSemantics: frame.presentationSemantics
        ))
        pendingFrames.removeValue(forKey: id)
        completedFrameEventCount = Self.saturatingAdd(
            completedFrameEventCount,
            1
        )
        return true
    }

    private static func saturatingAdd(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
