import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Document paint surface transaction", .serialized)
struct DocumentPaintSurfaceTransactionTests {
    @Test
    func emptyClearIsExplicitNoOpWithoutAllocatingOrOpeningTransaction() throws {
        guard let fixture = try TransactionFixture.make() else { return }
        let registryBefore = fixture.registry.snapshot()
        let historyBefore = fixture.revisions.snapshot()

        let preparation = try fixture.coordinator.prepareMutation(
            fixture.request(kind: .clear, dirty: [], removing: [])
        )

        guard case let .noOp(result) = preparation else {
            Issue.record("Empty clear must return the explicit no-op result")
            return
        }
        #expect(result.kind == .clear)
        #expect(result.layerID == fixture.layerID)
        #expect(result.generation == registryBefore.generation)
        #expect(fixture.coordinator.snapshot().state == .idle)
        #expect(fixture.registry.snapshot() == registryBefore)
        #expect(fixture.revisions.snapshot() == historyBefore)
        #expect(fixture.backend.encodeCallCount == 0)
    }

    @Test
    func requestValidationRejectsWrongLayerGeometryOrderDuplicatesAndBounds() throws {
        guard let fixture = try TransactionFixture.make() else { return }
        let zero = PaintTileCoordinate(x: 0, y: 0)
        let one = PaintTileCoordinate(x: 1, y: 0)
        let wrongLayer = UUID()
        let wrongGeometry = try transactionGeometry(width: 768, height: 512)
        let baseline = fixture.registry.snapshot()

        #expect(throws: DocumentPaintSurfaceTransactionError
            .unknownLayerID(wrongLayer)) {
            _ = try fixture.coordinator.prepareMutation(
                DocumentPaintSurfaceMutationRequest(
                    kind: .stroke,
                    layerID: wrongLayer,
                    baseGeometry: fixture.geometry,
                    candidateGeometry: fixture.geometry,
                    dirtyCoordinates: [zero],
                    explicitlyRemovedCoordinates: [],
                    requiresHistoryPair: true
                )
            )
        }
        #expect(throws: DocumentPaintSurfaceTransactionError
            .baseGeometryMismatch(
                expected: fixture.geometry,
                actual: wrongGeometry
            )) {
            _ = try fixture.coordinator.prepareMutation(
                fixture.request(
                    dirty: [zero],
                    baseGeometry: wrongGeometry
                )
            )
        }
        #expect(throws: DocumentPaintSurfaceTransactionError
            .unsortedCoordinate(previous: one, current: zero)) {
            _ = try fixture.coordinator.prepareMutation(
                fixture.request(dirty: [one, zero])
            )
        }
        #expect(throws: DocumentPaintSurfaceTransactionError
            .duplicateCoordinate(zero)) {
            _ = try fixture.coordinator.prepareMutation(
                fixture.request(dirty: [zero, zero])
            )
        }
        let outside = PaintTileCoordinate(x: 2, y: 0)
        #expect(throws: DocumentPaintSurfaceTransactionError
            .coordinateOutsideCandidate(outside)) {
            _ = try fixture.coordinator.prepareMutation(
                fixture.request(dirty: [outside])
            )
        }
        #expect(fixture.coordinator.snapshot().state == .idle)
        #expect(fixture.registry.snapshot() == baseline)
    }

    @Test
    func onlyOneLiveTransactionExistsAndPreparedHandleIsForeignChecked() throws {
        guard let first = try TransactionFixture.make(),
              let second = try TransactionFixture.make()
        else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let preparation = try first.coordinator.prepareMutation(
            first.request(dirty: [coordinate])
        )
        let prepared = try transactionPrepared(preparation)

        #expect(first.coordinator.snapshot().state == .live)
        #expect(first.coordinator.snapshot().phase == .prepared)
        #expect(throws: DocumentPaintSurfaceTransactionError
            .transactionAlreadyLive) {
            _ = try first.coordinator.prepareMutation(
                first.request(dirty: [coordinate])
            )
        }
        #expect(throws: DocumentPaintSurfaceTransactionError.foreignHandle) {
            try second.coordinator.discard(prepared)
        }

        try first.coordinator.discard(prepared)
        #expect(first.coordinator.snapshot().state == .idle)
        #expect(throws: DocumentPaintSurfaceTransactionError.staleHandle) {
            try first.coordinator.discard(prepared)
        }

        let retry = try first.coordinator.prepareMutation(
            first.request(dirty: [coordinate])
        )
        try first.coordinator.discard(try transactionPrepared(retry))
        #expect(first.coordinator.snapshot().state == .idle)
    }

    @Test
    func mutationUsesExactClippedCandidateDestinationsAndPrunesTransparentTiles() throws {
        guard let fixture = try TransactionFixture.make(width: 300, height: 257)
        else { return }
        let coordinates = [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
            PaintTileCoordinate(x: 0, y: 1),
            PaintTileCoordinate(x: 1, y: 1),
        ].sorted()
        fixture.backend.alphaByCoordinate = [
            coordinates[0]: 1,
            coordinates[1]: 0,
            coordinates[2]: 0.5,
            coordinates[3]: 0,
        ]
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareMutation(
                fixture.request(dirty: coordinates)
            )
        )

        let encoded = try fixture.coordinator.encodeMutation(prepared)
        let reduced = try fixture.coordinator.completeMutation(
            encoded,
            as: .succeeded
        )

        #expect(fixture.backend.destinations.map(\.coordinate) == coordinates)
        #expect(fixture.backend.destinations.map(\.logicalBounds) == [
            PixelRect(minX: 0, minY: 0, maxX: 256, maxY: 256),
            PixelRect(minX: 256, minY: 0, maxX: 300, maxY: 256),
            PixelRect(minX: 0, minY: 256, maxX: 256, maxY: 257),
            PixelRect(minX: 256, minY: 256, maxX: 300, maxY: 257),
        ])
        #expect(fixture.coordinator.snapshot().phase == .mutationCompleted)
        #expect(fixture.registry.snapshot().generation == 0)
        #expect(fixture.coordinator.snapshot().candidateCoordinates == [
            coordinates[0], coordinates[2],
        ])
        try fixture.coordinator.discard(reduced)
        #expect(fixture.coordinator.snapshot().state == .idle)
    }

    @Test
    func reductionRejectsIncompleteDuplicateInvalidAndOutOfRangeEvidence() throws {
        guard let fixture = try TransactionFixture.make() else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let bounds = try PaintTileDescriptor(
            coordinate: coordinate,
            logicalPixelSize: fixture.geometry.storagePixelSize
        ).logicalBounds
        let extra = PaintTileCoordinate(x: 1, y: 0)
        let invalidCases: [(
            [DocumentPaintSurfaceMutationEvidence],
            DocumentPaintSurfaceTransactionError
        )] = [
            ([], .missingReductionCoordinate(coordinate)),
            ([
                .init(coordinate: coordinate, logicalBounds: bounds, maximumAlpha: 1),
                .init(coordinate: coordinate, logicalBounds: bounds, maximumAlpha: 1),
            ], .duplicateReductionCoordinate(coordinate)),
            ([.init(coordinate: extra, logicalBounds: bounds, maximumAlpha: 1)],
             .invalidReductionCoordinate(extra)),
            ([.init(coordinate: coordinate, logicalBounds: bounds, maximumAlpha: .nan)],
             .invalidReductionAlpha(coordinate)),
            ([.init(coordinate: coordinate, logicalBounds: bounds, maximumAlpha: -0.01)],
             .invalidReductionAlpha(coordinate)),
            ([.init(coordinate: coordinate, logicalBounds: bounds, maximumAlpha: 1.01)],
             .invalidReductionAlpha(coordinate)),
            ([.init(coordinate: coordinate, logicalBounds: bounds, maximumAlpha: 1, invalid: true)],
             .invalidReductionFlag(coordinate)),
            ([.init(
                coordinate: coordinate,
                logicalBounds: PixelRect(minX: 0, minY: 0, maxX: 1, maxY: 1)!,
                maximumAlpha: 1
            )], .invalidReductionBounds(coordinate)),
        ]

        for (evidence, expected) in invalidCases {
            fixture.backend.evidenceOverride = evidence
            let prepared = try transactionPrepared(
                fixture.coordinator.prepareMutation(
                    fixture.request(dirty: [coordinate])
                )
            )
            let encoded = try fixture.coordinator.encodeMutation(prepared)
            #expect(throws: expected) {
                _ = try fixture.coordinator.completeMutation(
                    encoded,
                    as: .succeeded
                )
            }
            #expect(fixture.coordinator.snapshot().state == .idle)
            #expect(fixture.registry.snapshot().generation == 0)
        }
    }

    @Test
    func destinationReturnFailureIsExplicitRetryableAndLeavesActiveStateUntouched() throws {
        guard let fixture = try TransactionFixture.make() else { return }
        let baseline = fixture.registry.snapshot()
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareMutation(
                fixture.request(dirty: [coordinate])
            )
        )
        let encoded = try fixture.coordinator.encodeMutation(prepared)

        #expect(throws: DocumentPaintSurfaceTransactionError
            .destinationLeaseReturnFailed) {
            _ = try fixture.coordinator.completeMutation(
                encoded,
                as: .succeeded,
                failureInjection: .init(failingAt: .destinationLeaseReturn)
            )
        }
        #expect(fixture.coordinator.snapshot().state == .discardPending)
        #expect(fixture.registry.snapshot().generation == baseline.generation)
        try fixture.coordinator.retryDiscard()
        #expect(fixture.coordinator.snapshot().state == .idle)
        #expect(fixture.registry.snapshot() == baseline)

        let retry = try transactionPrepared(
            fixture.coordinator.prepareMutation(
                fixture.request(dirty: [coordinate])
            )
        )
        try fixture.coordinator.discard(retry)
    }

    @Test
    func historyCaptureUsesExactKnownClearAndPresentEndpointsThenCleansUp() throws {
        guard let fixture = try TransactionFixture.make(width: 300, height: 256)
        else { return }
        let first = PaintTileCoordinate(x: 0, y: 0)
        let edge = PaintTileCoordinate(x: 1, y: 0)
        fixture.backend.alphaByCoordinate = [first: 1, edge: 0]
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareMutation(
                fixture.request(dirty: [first, edge])
            )
        )
        let encoded = try fixture.coordinator.encodeMutation(prepared)
        let reduced = try fixture.coordinator.completeMutation(
            encoded,
            as: .succeeded
        )

        let history = try fixture.coordinator.encodeHistoryCapture(reduced)
        let completed = try fixture.coordinator.completeHistoryCapture(
            history,
            as: .succeeded
        )

        let snapshot = fixture.revisions.snapshot()
        #expect(snapshot.provisionalRevisionCount == 2)
        #expect(snapshot.inFlightOperationCount == 0)
        #expect(snapshot.residentBytes == PaintTileDescriptor.residentByteCount)

        try fixture.coordinator.discard(completed)
        #expect(fixture.revisions.snapshot() == .empty(
            maximumRetainedBytes: PaintTileDescriptor.residentByteCount * 32
        ))
        #expect(fixture.coordinator.snapshot().state == .idle)
    }

    @Test
    func terminalPublicationAtomicallyPublishesHistoryThenSwapsRegistry() throws {
        guard let fixture = try TransactionFixture.make(width: 300, height: 256)
        else { return }
        let first = PaintTileCoordinate(x: 0, y: 0)
        let edge = PaintTileCoordinate(x: 1, y: 0)
        fixture.backend.alphaByCoordinate = [first: 1, edge: 0]
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareMutation(
                fixture.request(dirty: [first, edge])
            )
        )
        let encoded = try fixture.coordinator.encodeMutation(prepared)
        let reduced = try fixture.coordinator.completeMutation(
            encoded,
            as: .succeeded
        )
        let history = try fixture.coordinator.encodeHistoryCapture(reduced)
        let completed = try fixture.coordinator.completeHistoryCapture(
            history,
            as: .succeeded
        )

        let terminal = try fixture.coordinator.prepareTerminalCommit(completed)
        let result = try fixture.coordinator.publish(terminal)

        #expect(result.layerID == fixture.layerID)
        #expect(result.beforeGeneration == 0)
        #expect(result.afterGeneration == 1)
        #expect(result.dirtyCoordinates == [first, edge])
        let pair = try #require(result.historyPair)
        #expect(pair.before.tileCoordinates == [
            RasterRevisionTileCoordinate(x: first.x, y: first.y),
            RasterRevisionTileCoordinate(x: edge.x, y: edge.y),
        ])
        #expect(pair.after.tileCoordinates == [
            RasterRevisionTileCoordinate(x: first.x, y: first.y),
            RasterRevisionTileCoordinate(x: edge.x, y: edge.y),
        ])
        #expect(pair.before.retainedBytes == 0)
        #expect(pair.after.retainedBytes == PaintTileDescriptor.residentByteCount)
        #expect(fixture.registry.snapshot().generation == 1)
        #expect(fixture.registry.snapshot().layers[0].references.map(\.coordinate) == [first])
        #expect(fixture.revisions.snapshot().publishedRevisionCount == 2)
        #expect(fixture.coordinator.snapshot().state == .idle)
        try fixture.revisions.release(pair.revisionIDs)
    }

    @Test
    func noHistoryCommitUsesTheSameStrictCandidateSwap() throws {
        guard let fixture = try TransactionFixture.make() else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareMutation(
                fixture.request(
                    dirty: [coordinate],
                    requiresHistoryPair: false
                )
            )
        )
        let encoded = try fixture.coordinator.encodeMutation(prepared)
        let reduced = try fixture.coordinator.completeMutation(
            encoded,
            as: .succeeded
        )
        let terminal = try fixture.coordinator.prepareTerminalCommit(reduced)
        let result = try fixture.coordinator.publish(terminal)

        #expect(result.historyPair == nil)
        #expect(fixture.registry.snapshot().generation == 1)
        #expect(fixture.revisions.snapshot().publishedRevisionCount == 0)
        #expect(fixture.coordinator.snapshot().state == .idle)
    }

    @Test
    func clearCapturesPresentBeforeAndKnownClearAfter() throws {
        guard let fixture = try TransactionFixture.make(width: 300, height: 256)
        else { return }
        let first = PaintTileCoordinate(x: 0, y: 0)
        let edge = PaintTileCoordinate(x: 1, y: 0)
        try transactionSeedActive(fixture, coordinates: [first, edge])
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareMutation(
                fixture.request(kind: .clear, dirty: [], removing: [first, edge])
            )
        )
        let encoded = try fixture.coordinator.encodeMutation(prepared)
        let reduced = try fixture.coordinator.completeMutation(
            encoded,
            as: .succeeded
        )
        let history = try fixture.coordinator.encodeHistoryCapture(reduced)
        let completed = try fixture.coordinator.completeHistoryCapture(
            history,
            as: .succeeded
        )
        let terminal = try fixture.coordinator.prepareTerminalCommit(completed)
        let result = try fixture.coordinator.publish(terminal)
        let pair = try #require(result.historyPair)

        #expect(pair.before.tileCoordinates.count == 2)
        #expect(pair.after.tileCoordinates.count == 2)
        #expect(pair.before.retainedBytes > 0)
        #expect(pair.after.retainedBytes == 0)
        #expect(fixture.registry.snapshot().layers[0].references.isEmpty)
        try fixture.revisions.release(pair.revisionIDs)
    }

    @Test
    func separatedHoleCoordinatesRemainExactAcrossHistory() throws {
        guard let fixture = try TransactionFixture.make(width: 768, height: 256)
        else { return }
        let left = PaintTileCoordinate(x: 0, y: 0)
        let right = PaintTileCoordinate(x: 2, y: 0)
        let result = try transactionCommitWithHistory(
            fixture,
            coordinates: [left, right]
        )
        let pair = try #require(result.historyPair)
        let exact = [
            RasterRevisionTileCoordinate(x: 0, y: 0),
            RasterRevisionTileCoordinate(x: 2, y: 0),
        ]
        #expect(pair.before.tileCoordinates == exact)
        #expect(pair.after.tileCoordinates == exact)
        #expect(pair.after.regions.rectangles.count == 2)
        try fixture.revisions.release(pair.revisionIDs)
    }

    @Test
    func terminalPreflightPrepareAndPublishFailuresAreRetryable() throws {
        guard let fixture = try TransactionFixture.make() else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let completed = try transactionCompletedHistory(
            fixture,
            coordinates: [coordinate]
        )
        let baseline = fixture.registry.snapshot()

        #expect(throws: DocumentPaintSurfaceTransactionError
            .terminalPreflightFailed) {
            _ = try fixture.coordinator.prepareTerminalCommit(
                completed,
                failureInjection: .init(failingAt: .terminalPreflight)
            )
        }
        #expect(fixture.coordinator.snapshot().phase == .historyCompleted)
        #expect(throws: DocumentPaintSurfaceTransactionError
            .registryPreparationFailed) {
            _ = try fixture.coordinator.prepareTerminalCommit(
                completed,
                failureInjection: .init(failingAt: .registryPrepare)
            )
        }
        #expect(fixture.registry.snapshot() == baseline)

        let terminal = try fixture.coordinator.prepareTerminalCommit(completed)
        #expect(throws: DocumentPaintSurfaceTransactionError
            .revisionPublishFailed) {
            _ = try fixture.coordinator.publish(
                terminal,
                failureInjection: .init(failingAt: .revisionPublish)
            )
        }
        #expect(fixture.coordinator.snapshot().phase == .terminalPrepared)
        #expect(fixture.registry.snapshot().generation == baseline.generation)
        #expect(fixture.registry.snapshot().preparedCandidateCount == 1)
        #expect(fixture.revisions.snapshot().provisionalRevisionCount == 2)

        let result = try fixture.coordinator.publish(terminal)
        #expect(fixture.registry.snapshot().generation == baseline.generation + 1)
        #expect(fixture.revisions.snapshot().publishedRevisionCount == 2)
        try fixture.revisions.release(try #require(result.historyPair).revisionIDs)
    }

    @Test
    func mutationAndHistoryFailureSeamsRestoreQuiescenceAndAllowRetry() throws {
        let mutationFailures: [DocumentPaintSurfaceTransactionFailurePoint] = [
            .mutationCompletion,
            .reductionValidation,
            .candidatePrune,
        ]
        for failure in mutationFailures {
            guard let fixture = try TransactionFixture.make() else { return }
            let coordinate = PaintTileCoordinate(x: 0, y: 0)
            let prepared = try transactionPrepared(
                fixture.coordinator.prepareMutation(
                    fixture.request(dirty: [coordinate])
                )
            )
            let encoded = try fixture.coordinator.encodeMutation(prepared)
            #expect(throws: (any Error).self) {
                _ = try fixture.coordinator.completeMutation(
                    encoded,
                    as: .succeeded,
                    failureInjection: .init(failingAt: failure)
                )
            }
            try transactionRequireQuiescentAndReusable(
                fixture,
                coordinate: coordinate
            )
        }

        let historyFailures: [DocumentPaintSurfaceTransactionFailurePoint] = [
            .historyAllocation(0),
            .historyCapture(0),
            .historyCapture(1),
            .historyCompletion(0),
            .historyCompletion(1),
        ]
        for failure in historyFailures {
            guard let fixture = try TransactionFixture.make() else { return }
            let coordinate = PaintTileCoordinate(x: 0, y: 0)
            let reduced = try transactionReduced(
                fixture,
                coordinates: [coordinate]
            )
            if case .historyCompletion = failure {
                let encoded = try fixture.coordinator.encodeHistoryCapture(reduced)
                #expect(throws: (any Error).self) {
                    _ = try fixture.coordinator.completeHistoryCapture(
                        encoded,
                        as: .succeeded,
                        failureInjection: .init(failingAt: failure)
                    )
                }
            } else {
                #expect(throws: (any Error).self) {
                    _ = try fixture.coordinator.encodeHistoryCapture(
                        reduced,
                        failureInjection: .init(failingAt: failure)
                    )
                }
            }
            try transactionRequireQuiescentAndReusable(
                fixture,
                coordinate: coordinate
            )
        }
    }

    @Test
    func sourceReturnFailureRetainsExactOwnershipUntilRetryDiscard() throws {
        guard let fixture = try TransactionFixture.make() else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let reduced = try transactionReduced(
            fixture,
            coordinates: [coordinate]
        )
        let encoded = try fixture.coordinator.encodeHistoryCapture(reduced)
        #expect(throws: DocumentPaintSurfaceTransactionError
            .sourceLeaseReturnFailed) {
            _ = try fixture.coordinator.completeHistoryCapture(
                encoded,
                as: .succeeded,
                failureInjection: .init(failingAt: .sourceLeaseReturn)
            )
        }
        #expect(fixture.coordinator.snapshot().state == .discardPending)
        #expect(fixture.registry.snapshot().activeTileLeaseCount == 1)
        try fixture.coordinator.retryDiscard()
        #expect(fixture.coordinator.snapshot().state == .idle)
        #expect(fixture.registry.snapshot().activeTileLeaseCount == 0)
        #expect(fixture.revisions.snapshot().provisionalRevisionCount == 0)
    }

    @Test
    func reserveAndBackendFailuresAreAtomicAndCleanupIsRetryable() throws {
        guard let reserveFixture = try TransactionFixture.make() else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        #expect(throws: (any Error).self) {
            _ = try reserveFixture.coordinator.prepareMutation(
                reserveFixture.request(dirty: [coordinate]),
                failureInjection: .init(failingAt: .candidateReserve(0))
            )
        }
        try transactionRequireQuiescentAndReusable(
            reserveFixture,
            coordinate: coordinate
        )

        guard let encodeFixture = try TransactionFixture.make() else { return }
        let prepared = try transactionPrepared(
            encodeFixture.coordinator.prepareMutation(
                encodeFixture.request(dirty: [coordinate])
            )
        )
        #expect(throws: DocumentPaintSurfaceTransactionError
            .backendEncodingFailed) {
            _ = try encodeFixture.coordinator.encodeMutation(
                prepared,
                failureInjection: .init(failingAt: .mutationEncode)
            )
        }
        #expect(encodeFixture.coordinator.snapshot().phase == .prepared)
        let encoded = try encodeFixture.coordinator.encodeMutation(prepared)
        try encodeFixture.coordinator.discard(encoded)

        guard let cleanupFixture = try TransactionFixture.make() else { return }
        var leaseCountDuringTerminalDiscard: Int?
        cleanupFixture.backend.onDiscardAndWaitUntilTerminal = {
            leaseCountDuringTerminalDiscard = cleanupFixture.registry
                .snapshot().activeTileLeaseCount
        }
        cleanupFixture.backend.discardShouldFail = true
        let cleanupPrepared = try transactionPrepared(
            cleanupFixture.coordinator.prepareMutation(
                cleanupFixture.request(dirty: [coordinate])
            )
        )
        let cleanupEncoded = try cleanupFixture.coordinator.encodeMutation(
            cleanupPrepared
        )
        #expect(throws: DocumentPaintSurfaceTransactionError.cleanupFailed) {
            _ = try cleanupFixture.coordinator.completeMutation(
                cleanupEncoded,
                as: .succeeded,
                failureInjection: .init(failingAt: .mutationCompletion)
            )
        }
        #expect(cleanupFixture.coordinator.snapshot().state == .discardPending)
        #expect(leaseCountDuringTerminalDiscard == 1)
        #expect(cleanupFixture.registry.snapshot().activeTileLeaseCount == 1)
        cleanupFixture.backend.discardShouldFail = false
        try cleanupFixture.coordinator.retryDiscard()
        #expect(cleanupFixture.coordinator.snapshot().state == .idle)
        #expect(cleanupFixture.registry.snapshot().activeTileLeaseCount == 0)
    }

    @Test
    func consumedPhaseHandlesCannotBeReplayed() throws {
        guard let fixture = try TransactionFixture.make() else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareMutation(
                fixture.request(dirty: [coordinate])
            )
        )
        let encoded = try fixture.coordinator.encodeMutation(prepared)
        #expect(throws: DocumentPaintSurfaceTransactionError
            .handleAlreadyConsumed) {
            try fixture.coordinator.discard(prepared)
        }
        try fixture.coordinator.discard(encoded)
        #expect(throws: DocumentPaintSurfaceTransactionError.staleHandle) {
            try fixture.coordinator.discard(encoded)
        }
    }

    @Test
    func geometryReplacementAndClearRequestsRequireCompleteBaseAuthority() throws {
        guard let fixture = try TransactionFixture.make() else { return }
        let first = PaintTileCoordinate(x: 0, y: 0)
        try transactionSeedActive(fixture, coordinates: [first])
        let grown = try transactionGeometry(width: 768, height: 512)

        #expect(throws: DocumentPaintSurfaceTransactionError
            .incompleteGeometryReplacement(first)) {
            _ = try fixture.coordinator.prepareMutation(
                fixture.request(
                    kind: .resize,
                    dirty: [PaintTileCoordinate(x: 2, y: 0)],
                    candidateGeometry: grown
                )
            )
        }
        #expect(throws: DocumentPaintSurfaceTransactionError
            .missingBaseCoordinate(first)) {
            _ = try fixture.coordinator.prepareMutation(
                fixture.request(kind: .clear, dirty: [], removing: [])
            )
        }
        #expect(fixture.coordinator.snapshot().state == .idle)
        #expect(fixture.registry.snapshot().generation == 1)
    }

    @Test
    func oneTwoAndFourTileHistoryKeepsExactCoordinateAuthority() throws {
        let cases: [[PaintTileCoordinate]] = [
            [.init(x: 0, y: 0)],
            [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            [
                .init(x: 0, y: 0), .init(x: 1, y: 0),
                .init(x: 0, y: 1), .init(x: 1, y: 1),
            ].sorted(),
        ]
        for coordinates in cases {
            guard let fixture = try TransactionFixture.make(
                width: 513,
                height: 513
            ) else { return }
            let result = try transactionCommitWithHistory(
                fixture,
                coordinates: coordinates
            )
            let pair = try #require(result.historyPair)
            let expected = coordinates.map {
                RasterRevisionTileCoordinate(x: $0.x, y: $0.y)
            }
            #expect(pair.before.tileCoordinates == expected)
            #expect(pair.after.tileCoordinates == expected)
            try fixture.revisions.release(pair.revisionIDs)
        }
    }

    @Test
    func geometryChangeBuildsDistinctBeforeAndAfterEndpoints() throws {
        guard let fixture = try TransactionFixture.make(width: 256, height: 256)
        else { return }
        let shared = PaintTileCoordinate(x: 0, y: 0)
        let grownOnly = PaintTileCoordinate(x: 2, y: 2)
        let grown = try transactionGeometry(width: 513, height: 513)
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareMutation(
                fixture.request(
                    kind: .resize,
                    dirty: [shared, grownOnly],
                    candidateGeometry: grown
                )
            )
        )
        let encoded = try fixture.coordinator.encodeMutation(prepared)
        let reduced = try fixture.coordinator.completeMutation(
            encoded,
            as: .succeeded
        )
        let history = try fixture.coordinator.encodeHistoryCapture(reduced)
        let completed = try fixture.coordinator.completeHistoryCapture(
            history,
            as: .succeeded
        )
        let terminal = try fixture.coordinator.prepareTerminalCommit(completed)
        let result = try fixture.coordinator.publish(terminal)
        let pair = try #require(result.historyPair)

        #expect(pair.before.pixelSize == fixture.geometry.storagePixelSize)
        #expect(pair.after.pixelSize == grown.storagePixelSize)
        #expect(pair.before.tileCoordinates == [
            RasterRevisionTileCoordinate(x: 0, y: 0),
        ])
        #expect(pair.after.tileCoordinates == [
            RasterRevisionTileCoordinate(x: 0, y: 0),
            RasterRevisionTileCoordinate(x: 2, y: 2),
        ])
        try fixture.revisions.release(pair.revisionIDs)
    }

    @Test
    func capturedBaseEpochCannotMixWithAConcurrentCoordinatorCommit() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let layerID = UUID()
        let geometry = try transactionGeometry(width: 512, height: 256)
        let tileBytes = PaintTileDescriptor.residentByteCount
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: tileBytes * 8,
            transferByteCapacity: tileBytes * 16,
            geometry: geometry,
            layerIDs: [layerID]
        )
        let revisions = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: tileBytes * 8
        )
        let winningBackend = TransactionTestMutationBackend()
        let winningCoordinator = DocumentPaintSurfaceTransaction(
            registry: registry,
            revisionStore: revisions,
            commandQueue: queue,
            mutationBackend: winningBackend
        )
        let winningCoordinate = PaintTileCoordinate(x: 1, y: 0)
        let winningRequest = DocumentPaintSurfaceMutationRequest(
            kind: .stroke,
            layerID: layerID,
            baseGeometry: geometry,
            candidateGeometry: geometry,
            dirtyCoordinates: [winningCoordinate],
            explicitlyRemovedCoordinates: [],
            requiresHistoryPair: false
        )
        let staleBackend = TransactionTestMutationBackend()
        let staleCoordinator = DocumentPaintSurfaceTransaction(
            registry: registry,
            revisionStore: revisions,
            commandQueue: queue,
            mutationBackend: staleBackend,
            afterBaseSnapshotForTesting: {
                let prepared = try transactionPrepared(
                    winningCoordinator.prepareMutation(winningRequest)
                )
                let encoded = try winningCoordinator.encodeMutation(prepared)
                let reduced = try winningCoordinator.completeMutation(
                    encoded,
                    as: .succeeded
                )
                let terminal = try winningCoordinator
                    .prepareTerminalCommit(reduced)
                _ = try winningCoordinator.publish(terminal)
            }
        )
        let staleCoordinate = PaintTileCoordinate(x: 0, y: 0)
        let staleRequest = DocumentPaintSurfaceMutationRequest(
            kind: .stroke,
            layerID: layerID,
            baseGeometry: geometry,
            candidateGeometry: geometry,
            dirtyCoordinates: [staleCoordinate],
            explicitlyRemovedCoordinates: [],
            requiresHistoryPair: false
        )

        #expect(throws: DocumentPaintSurfaceStoreError.staleGeneration(
            expected: 1,
            actual: 0
        )) {
            _ = try staleCoordinator.prepareMutation(staleRequest)
        }
        #expect(staleCoordinator.snapshot().state == .idle)
        #expect(staleBackend.encodeCallCount == 0)
        #expect(registry.snapshot().generation == 1)
        #expect(registry.snapshot().layers[0].references.map(\.coordinate) == [
            winningCoordinate,
        ])
    }

    @Test
    func emptyClearNoOpKeepsItsCapturedEpochDuringConcurrentCommit() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let layerID = UUID()
        let geometry = try transactionGeometry(width: 256, height: 256)
        let tileBytes = PaintTileDescriptor.residentByteCount
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: tileBytes * 4,
            transferByteCapacity: tileBytes * 8,
            geometry: geometry,
            layerIDs: [layerID]
        )
        let revisions = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: tileBytes * 4
        )
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let coordinator = DocumentPaintSurfaceTransaction(
            registry: registry,
            revisionStore: revisions,
            commandQueue: queue,
            mutationBackend: TransactionTestMutationBackend(),
            afterBaseSnapshotForTesting: {
                let candidate = try registry.makeCandidate(
                    dirtyCoordinatesByLayer: [layerID: [coordinate]]
                )
                registry.commitPrepared(
                    try registry.prepareCommit(candidate)
                )
            }
        )
        let clear = DocumentPaintSurfaceMutationRequest(
            kind: .clear,
            layerID: layerID,
            baseGeometry: geometry,
            candidateGeometry: geometry,
            dirtyCoordinates: [],
            explicitlyRemovedCoordinates: [],
            requiresHistoryPair: false
        )

        let preparation = try coordinator.prepareMutation(clear)
        guard case let .noOp(result) = preparation else {
            Issue.record("Expected clear to linearize at the captured empty epoch")
            return
        }
        #expect(result.generation == 0)
        #expect(coordinator.snapshot().state == .idle)
        #expect(registry.snapshot().generation == 1)
        #expect(registry.snapshot().layers[0].references.map(\.coordinate) == [
            coordinate,
        ])
    }
}

private final class TransactionTestMutationBackend:
    DocumentPaintSurfaceMutationBackend, @unchecked Sendable
{
    private(set) var encodeCallCount = 0
    private(set) var discardCallCount = 0
    var alphaByCoordinate: [PaintTileCoordinate: Float] = [:]
    var evidenceOverride: [DocumentPaintSurfaceMutationEvidence]?
    var discardShouldFail = false
    var onDiscardAndWaitUntilTerminal: (() -> Void)?
    private(set) var destinations: [DocumentPaintSurfaceMutationDestination] = []

    func encode(
        destinations: [DocumentPaintSurfaceMutationDestination]
    ) throws -> DocumentPaintSurfaceMutationBackendEncoding {
        encodeCallCount += 1
        self.destinations = destinations
        return DocumentPaintSurfaceMutationBackendEncoding()
    }

    func complete(
        _ encoding: DocumentPaintSurfaceMutationBackendEncoding,
        as outcome: RasterRevisionOperationOutcome
    ) throws -> [DocumentPaintSurfaceMutationEvidence] {
        _ = encoding
        _ = outcome
        if let evidenceOverride { return evidenceOverride }
        return destinations.map {
            DocumentPaintSurfaceMutationEvidence(
                coordinate: $0.coordinate,
                logicalBounds: $0.logicalBounds,
                maximumAlpha: alphaByCoordinate[$0.coordinate] ?? 1
            )
        }
    }

    func discardAndWaitUntilTerminal(
        _ encoding: DocumentPaintSurfaceMutationBackendEncoding
    ) throws {
        _ = encoding
        discardCallCount += 1
        onDiscardAndWaitUntilTerminal?()
        if discardShouldFail { throw TransactionTestError.backendFailure }
    }
}

private struct TransactionFixture {
    let device: any MTLDevice
    let layerID: UUID
    let geometry: DocumentPaintGeometry
    let registry: DocumentPaintSurfaceStore
    let revisions: TiledRasterRevisionStore
    let backend: TransactionTestMutationBackend
    let coordinator: DocumentPaintSurfaceTransaction

    static func make(width: Int = 512, height: Int = 512) throws -> Self? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }
        let layerID = UUID()
        let geometry = try transactionGeometry(width: width, height: height)
        let tileBytes = PaintTileDescriptor.residentByteCount
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: tileBytes * 16,
            transferByteCapacity: tileBytes * 32,
            geometry: geometry,
            layerIDs: [layerID]
        )
        let revisions = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: tileBytes * 32
        )
        let backend = TransactionTestMutationBackend()
        let coordinator = DocumentPaintSurfaceTransaction(
            registry: registry,
            revisionStore: revisions,
            commandQueue: queue,
            mutationBackend: backend
        )
        return Self(
            device: device,
            layerID: layerID,
            geometry: geometry,
            registry: registry,
            revisions: revisions,
            backend: backend,
            coordinator: coordinator
        )
    }

    func request(
        kind: DocumentPaintSurfaceTransactionKind = .stroke,
        dirty: [PaintTileCoordinate],
        removing: [PaintTileCoordinate] = [],
        baseGeometry: DocumentPaintGeometry? = nil,
        candidateGeometry: DocumentPaintGeometry? = nil,
        requiresHistoryPair: Bool = true
    ) -> DocumentPaintSurfaceMutationRequest {
        DocumentPaintSurfaceMutationRequest(
            kind: kind,
            layerID: layerID,
            baseGeometry: baseGeometry ?? geometry,
            candidateGeometry: candidateGeometry ?? geometry,
            dirtyCoordinates: dirty,
            explicitlyRemovedCoordinates: removing,
            requiresHistoryPair: requiresHistoryPair
        )
    }
}

private func transactionGeometry(
    width: Int,
    height: Int
) throws -> DocumentPaintGeometry {
    try DocumentPaintGeometry(
        documentPixelSize: PixelSize(width: width, height: height),
        storagePixelSize: PixelSize(width: width, height: height),
        radialLayout: nil
    )
}

private func transactionPrepared(
    _ value: DocumentPaintMutationPreparation
) throws -> DocumentPaintPreparedMutation {
    guard case let .prepared(prepared) = value else {
        throw TransactionTestError.expectedPrepared
    }
    return prepared
}

private func transactionReduced(
    _ fixture: TransactionFixture,
    coordinates: [PaintTileCoordinate]
) throws -> DocumentPaintReducedMutation {
    let prepared = try transactionPrepared(
        fixture.coordinator.prepareMutation(
            fixture.request(dirty: coordinates)
        )
    )
    let encoded = try fixture.coordinator.encodeMutation(prepared)
    return try fixture.coordinator.completeMutation(encoded, as: .succeeded)
}

private func transactionCompletedHistory(
    _ fixture: TransactionFixture,
    coordinates: [PaintTileCoordinate]
) throws -> DocumentPaintCompletedHistory {
    let reduced = try transactionReduced(fixture, coordinates: coordinates)
    let encoded = try fixture.coordinator.encodeHistoryCapture(reduced)
    return try fixture.coordinator.completeHistoryCapture(
        encoded,
        as: .succeeded
    )
}

private func transactionCommitWithHistory(
    _ fixture: TransactionFixture,
    coordinates: [PaintTileCoordinate]
) throws -> DocumentPaintSurfaceCommitResult {
    let completed = try transactionCompletedHistory(
        fixture,
        coordinates: coordinates
    )
    let terminal = try fixture.coordinator.prepareTerminalCommit(completed)
    return try fixture.coordinator.publish(terminal)
}

private func transactionSeedActive(
    _ fixture: TransactionFixture,
    coordinates: [PaintTileCoordinate]
) throws {
    let candidate = try fixture.registry.makeCandidate(
        dirtyCoordinatesByLayer: [fixture.layerID: coordinates]
    )
    fixture.registry.commitPrepared(
        try fixture.registry.prepareCommit(candidate)
    )
}

private func transactionRequireQuiescentAndReusable(
    _ fixture: TransactionFixture,
    coordinate: PaintTileCoordinate
) throws {
    #expect(fixture.coordinator.snapshot().state == .idle)
    let registry = fixture.registry.snapshot()
    #expect(registry.generation == 0)
    #expect(registry.layers[0].references.isEmpty)
    #expect(registry.activeTileLeaseCount == 0)
    #expect(registry.preparedCandidateCount == 0)
    let revisions = fixture.revisions.snapshot()
    #expect(revisions.provisionalRevisionCount == 0)
    #expect(revisions.publishedRevisionCount == 0)
    #expect(revisions.inFlightOperationCount == 0)
    let retry = try transactionPrepared(
        fixture.coordinator.prepareMutation(
            fixture.request(dirty: [coordinate])
        )
    )
    try fixture.coordinator.discard(retry)
    #expect(fixture.coordinator.snapshot().state == .idle)
}

private enum TransactionTestError: Error {
    case expectedPrepared
    case backendFailure
}
