import Foundation
import EditorCore
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
            .invalidResizeMapping) {
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
    func geometryChangeBuildsDistinctEndpointsWithoutInventingExpansionTiles() throws {
        guard let fixture = try TransactionFixture.make(width: 256, height: 256)
        else { return }
        let shared = PaintTileCoordinate(x: 0, y: 0)
        try transactionSeedActive(fixture, coordinates: [shared])
        let grown = try transactionGeometry(width: 513, height: 513)
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareMutation(
                fixture.request(
                    kind: .resize,
                    dirty: [shared],
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
        ])
        try fixture.revisions.release(pair.revisionIDs)
    }

    @Test
    func blankResizePublishesZeroByteHistoryAndUndoRedoBothGeometries() throws {
        guard let fixture = try TransactionFixture.make(width: 255, height: 256)
        else { return }
        let target = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 514, height: 512),
            storagePixelSize: PixelSize(width: 257, height: 256),
            radialLayout: nil
        )
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareMutation(
                fixture.request(
                    kind: .resize,
                    dirty: [],
                    removing: [],
                    candidateGeometry: target
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
        let committed = try fixture.coordinator.publish(terminal)
        let pair = try #require(committed.historyPair)

        #expect(committed.dirtyCoordinates.isEmpty)
        #expect(pair.before.pixelSize == fixture.geometry.storagePixelSize)
        #expect(pair.before.documentPixelSize
            == fixture.geometry.documentPixelSize)
        #expect(pair.after.pixelSize == target.storagePixelSize)
        #expect(pair.after.documentPixelSize == target.documentPixelSize)
        #expect(pair.before.tileCoordinates.isEmpty)
        #expect(pair.after.tileCoordinates.isEmpty)
        #expect(pair.retainedBytes == 0)
        #expect(fixture.registry.snapshot().geometry == target)

        let undoPrepared = try fixture.coordinator.prepareRestore(
            fixture.restoreRequest(
                reference: pair.before,
                expected: [],
                targetGeometry: fixture.geometry
            )
        )
        let undoEncoded = try fixture.coordinator.encodeRestore(undoPrepared)
        let undoCompleted = try fixture.coordinator.completeRestore(
            undoEncoded,
            as: .succeeded
        )
        let undoTerminal = try fixture.coordinator.prepareTerminalRestore(
            undoCompleted
        )
        _ = try fixture.coordinator.publishRestore(undoTerminal)
        #expect(fixture.registry.snapshot().geometry == fixture.geometry)

        let redoPrepared = try fixture.coordinator.prepareRestore(
            fixture.restoreRequest(
                reference: pair.after,
                expected: [],
                targetGeometry: target
            )
        )
        let redoEncoded = try fixture.coordinator.encodeRestore(redoPrepared)
        let redoCompleted = try fixture.coordinator.completeRestore(
            redoEncoded,
            as: .succeeded
        )
        let redoTerminal = try fixture.coordinator.prepareTerminalRestore(
            redoCompleted
        )
        _ = try fixture.coordinator.publishRestore(redoTerminal)
        #expect(fixture.registry.snapshot().geometry == target)
        #expect(fixture.registry.snapshot().layers[0].references.isEmpty)
        #expect(fixture.registry.snapshot().activeTileLeaseCount == 0)
        #expect(fixture.revisions.snapshot().inFlightInstallLeaseCount == 0)
        #expect(fixture.coordinator.snapshot().state == .idle)

        try fixture.revisions.release(pair.revisionIDs)
    }

    @Test
    func plainResizeCrops257To255WithOneExactTopLeftCopyAndNoScaling() throws {
        guard let fixture = try TransactionFixture.make(width: 257, height: 256)
        else { return }
        let kept = PaintTileCoordinate(x: 0, y: 0)
        let cropped = PaintTileCoordinate(x: 1, y: 0)
        try transactionSeedActive(
            fixture,
            coordinates: [kept, cropped]
        )
        let target = try transactionGeometry(width: 255, height: 256)
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareMutation(
                fixture.request(
                    kind: .resize,
                    dirty: [kept],
                    removing: [cropped],
                    candidateGeometry: target
                )
            )
        )

        let encoded = try fixture.coordinator.encodeMutation(prepared)
        let payload = try #require(fixture.backend.resizePayload)
        #expect(payload.sourceGeometry == fixture.geometry)
        #expect(payload.candidateGeometry == target)
        #expect(payload.sources.map(\.coordinate) == [kept])
        #expect(payload.destinations.map(\.coordinate) == [kept])
        #expect(payload.mappings == [
            DocumentPaintSurfaceResizeCopyMapping(
                sourceCoordinate: kept,
                destinationCoordinate: kept,
                sourceOrigin: .zero,
                destinationOrigin: .zero,
                extent: PixelSize(width: 255, height: 256),
                logicalPage: nil,
                masksToTargetOrbit: false
            ),
        ])
        #expect(fixture.registry.snapshot().activeTileLeaseCount == 2)

        let reduced = try fixture.coordinator.completeMutation(
            encoded,
            as: .succeeded
        )
        #expect(fixture.registry.snapshot().activeTileLeaseCount == 0)
        let history = try fixture.coordinator.encodeHistoryCapture(reduced)
        let completed = try fixture.coordinator.completeHistoryCapture(
            history,
            as: .succeeded
        )
        let terminal = try fixture.coordinator.prepareTerminalCommit(completed)
        let result = try fixture.coordinator.publish(terminal)
        let pair = try #require(result.historyPair)

        #expect(pair.before.pixelSize == fixture.geometry.storagePixelSize)
        #expect(pair.after.pixelSize == target.storagePixelSize)
        #expect(pair.before.tileCoordinates == [
            RasterRevisionTileCoordinate(x: 0, y: 0),
            RasterRevisionTileCoordinate(x: 1, y: 0),
        ])
        #expect(pair.after.tileCoordinates == [
            RasterRevisionTileCoordinate(x: 0, y: 0),
        ])
        #expect(fixture.registry.snapshot().geometry == target)
        #expect(fixture.registry.snapshot().layers[0].references.map(\.coordinate)
            == [kept])
        try fixture.revisions.release(pair.revisionIDs)
    }

    @Test
    func plainResize255256257ClearsThenCopiesOnlyPresentIntersections() throws {
        let zero = PaintTileCoordinate(x: 0, y: 0)
        let one = PaintTileCoordinate(x: 1, y: 0)
        let cases: [(
            sourceWidth: Int,
            targetWidth: Int,
            sourceCoordinates: [PaintTileCoordinate],
            dirty: [PaintTileCoordinate],
            removed: [PaintTileCoordinate],
            extentWidth: Int
        )] = [
            (255, 256, [zero], [zero], [], 255),
            (256, 257, [zero], [zero], [], 256),
            (257, 256, [zero, one], [zero], [one], 256),
            (256, 255, [zero], [zero], [], 255),
        ]

        for item in cases {
            guard let fixture = try TransactionFixture.make(
                width: item.sourceWidth,
                height: 256
            ) else { return }
            try transactionSeedActive(
                fixture,
                coordinates: item.sourceCoordinates
            )
            let target = try transactionGeometry(
                width: item.targetWidth,
                height: 256
            )
            let prepared = try transactionPrepared(
                fixture.coordinator.prepareMutation(
                    fixture.request(
                        kind: .resize,
                        dirty: item.dirty,
                        removing: item.removed,
                        candidateGeometry: target
                    )
                )
            )
            let encoded = try fixture.coordinator.encodeMutation(prepared)
            let payload = try #require(fixture.backend.resizePayload)

            #expect(payload.clearsDestinationsBeforeCopy)
            #expect(payload.sources.map(\.coordinate) == item.dirty)
            #expect(payload.destinations.map(\.coordinate) == item.dirty)
            #expect(payload.mappings.count == item.dirty.count)
            #expect(payload.mappings.map(\.extent) == item.dirty.map { _ in
                PixelSize(width: item.extentWidth, height: 256)
            })
            #expect(fixture.coordinator.snapshot().candidateCoordinates
                == item.dirty)

            let reduced = try fixture.coordinator.completeMutation(
                encoded,
                as: .succeeded
            )
            #expect(fixture.registry.snapshot().activeTileLeaseCount == 0)
            try fixture.coordinator.discard(reduced)
        }

        guard let holeFixture = try TransactionFixture.make(
            width: 512,
            height: 256
        ) else { return }
        try transactionSeedActive(holeFixture, coordinates: [one])
        let expanded = try transactionGeometry(width: 513, height: 256)
        let holePrepared = try transactionPrepared(
            holeFixture.coordinator.prepareMutation(
                holeFixture.request(
                    kind: .resize,
                    dirty: [one],
                    candidateGeometry: expanded
                )
            )
        )
        let holeEncoded = try holeFixture.coordinator.encodeMutation(holePrepared)
        let holePayload = try #require(holeFixture.backend.resizePayload)
        #expect(holePayload.sources.map(\.coordinate) == [one])
        #expect(holePayload.destinations.map(\.coordinate) == [one])
        #expect(holeFixture.coordinator.snapshot().candidateCoordinates == [one])
        try holeFixture.coordinator.discard(holeEncoded)
    }

    @Test
    func prunedResizeEdgeStaysClearAfterRedoWithoutResurrectingAStoredTile() throws {
        guard let fixture = try TransactionFixture.make(width: 257, height: 256)
        else { return }
        let edge = PaintTileCoordinate(x: 1, y: 0)
        try transactionSeedActive(fixture, coordinates: [edge])
        fixture.backend.alphaByCoordinate = [edge: 0]
        let target = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 1_028, height: 512),
            storagePixelSize: fixture.geometry.storagePixelSize,
            radialLayout: nil
        )
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareMutation(
                fixture.request(
                    kind: .resize,
                    dirty: [edge],
                    candidateGeometry: target
                )
            )
        )
        let encoded = try fixture.coordinator.encodeMutation(prepared)
        let reduced = try fixture.coordinator.completeMutation(
            encoded,
            as: .succeeded
        )
        #expect(fixture.coordinator.snapshot().candidateCoordinates.isEmpty)
        let history = try fixture.coordinator.encodeHistoryCapture(reduced)
        let completed = try fixture.coordinator.completeHistoryCapture(
            history,
            as: .succeeded
        )
        let terminal = try fixture.coordinator.prepareTerminalCommit(completed)
        let result = try fixture.coordinator.publish(terminal)
        let pair = try #require(result.historyPair)
        #expect(pair.before.retainedBytes > 0)
        #expect(pair.after.retainedBytes == 0)
        #expect(fixture.registry.snapshot().layers[0].references.isEmpty)

        let undoPrepared = try fixture.coordinator.prepareRestore(
            fixture.restoreRequest(
                reference: pair.before,
                expected: [.init(coordinate: edge, disposition: .replace)],
                targetGeometry: fixture.geometry
            )
        )
        let undoEncoded = try fixture.coordinator.encodeRestore(undoPrepared)
        let undoCompleted = try fixture.coordinator.completeRestore(
            undoEncoded,
            as: .succeeded
        )
        _ = try fixture.coordinator.publishRestore(
            fixture.coordinator.prepareTerminalRestore(undoCompleted)
        )
        #expect(fixture.registry.snapshot().layers[0].references.map(\.coordinate)
            == [edge])

        let redoPrepared = try fixture.coordinator.prepareRestore(
            fixture.restoreRequest(
                reference: pair.after,
                expected: [.init(coordinate: edge, disposition: .remove)],
                targetGeometry: target
            )
        )
        let redoEncoded = try fixture.coordinator.encodeRestore(redoPrepared)
        let redoCompleted = try fixture.coordinator.completeRestore(
            redoEncoded,
            as: .succeeded
        )
        _ = try fixture.coordinator.publishRestore(
            fixture.coordinator.prepareTerminalRestore(redoCompleted)
        )
        #expect(fixture.registry.snapshot().layers[0].references.isEmpty)
        try fixture.revisions.release(pair.revisionIDs)
    }

    @Test
    func radialResizeMapsLogicalPageAcrossPermutedSlotsAndMasksTargetOrbit() throws {
        let sourceLayout = try RadialSectorLayout(
            maximumRadius: 1_024,
            sectorAngleRadians: .pi
        )
        let targetLayout = try RadialSectorLayout(
            maximumRadius: 700,
            sectorAngleRadians: .pi / 3
        )
        let sourceGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 2_048, height: 2_048),
            storagePixelSize: sourceLayout.atlasPixelSize,
            radialLayout: sourceLayout
        )
        let targetGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 1_400, height: 1_400),
            storagePixelSize: targetLayout.atlasPixelSize,
            radialLayout: targetLayout
        )
        let logicalPage = RadialPageCoordinate(x: 0, y: 0)
        let sourceCommon = try #require(
            sourceLayout.residentPage(at: logicalPage)
        )
        let targetCommon = try #require(
            targetLayout.residentPage(at: logicalPage)
        )
        let sourceSlotZero = try #require(
            sourceLayout.residentPages.first { $0.atlasSlot == 0 }
        )
        #expect(sourceCommon.atlasSlot != targetCommon.atlasSlot)
        #expect(sourceSlotZero.coordinate != logicalPage)

        let sourceCommonPhysical = transactionRadialPhysicalCoordinate(
            sourceCommon,
            layout: sourceLayout
        )
        let croppedSlotZeroPhysical = transactionRadialPhysicalCoordinate(
            sourceSlotZero,
            layout: sourceLayout
        )
        let targetPhysical = transactionRadialPhysicalCoordinate(
            targetCommon,
            layout: targetLayout
        )
        #expect(croppedSlotZeroPhysical == targetPhysical)
        #expect(sourceCommonPhysical != targetPhysical)

        guard let fixture = try TransactionFixture.make(
            geometry: sourceGeometry
        ) else { return }
        try transactionSeedActive(
            fixture,
            coordinates: [croppedSlotZeroPhysical, sourceCommonPhysical].sorted()
        )
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareMutation(
                fixture.request(
                    kind: .resize,
                    dirty: [targetPhysical],
                    removing: [sourceCommonPhysical],
                    candidateGeometry: targetGeometry
                )
            )
        )
        let encoded = try fixture.coordinator.encodeMutation(prepared)
        let payload = try #require(fixture.backend.resizePayload)

        #expect(payload.sources.map(\.coordinate) == [sourceCommonPhysical])
        #expect(payload.destinations.map(\.coordinate) == [targetPhysical])
        #expect(payload.mappings == [
            DocumentPaintSurfaceResizeCopyMapping(
                sourceCoordinate: sourceCommonPhysical,
                destinationCoordinate: targetPhysical,
                sourceOrigin: .zero,
                destinationOrigin: .zero,
                extent: PixelSize(width: 256, height: 256),
                logicalPage: logicalPage,
                masksToTargetOrbit: true
            ),
        ])
        #expect(payload.mappings.count == 1)
        #expect(fixture.registry.snapshot().activeTileLeaseCount == 2)

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

        #expect(pair.before.pixelSize == sourceLayout.atlasPixelSize)
        #expect(pair.before.documentPixelSize
            == sourceGeometry.documentPixelSize)
        #expect(pair.after.pixelSize == targetLayout.atlasPixelSize)
        #expect(pair.after.documentPixelSize
            == targetGeometry.documentPixelSize)
        #expect(pair.before.tileCoordinates.count == 2)
        #expect(pair.after.tileCoordinates == [
            RasterRevisionTileCoordinate(
                x: targetPhysical.x,
                y: targetPhysical.y
            ),
        ])
        #expect(pair.retainedBytes == PaintTileDescriptor.residentByteCount * 3)
        #expect(fixture.registry.snapshot().geometry == targetGeometry)
        #expect(fixture.registry.snapshot().layers[0].references.map(\.coordinate)
            == [targetPhysical])

        let beforePhysical = [
            croppedSlotZeroPhysical,
            sourceCommonPhysical,
        ].sorted()
        let undoPrepared = try fixture.coordinator.prepareRestore(
            fixture.restoreRequest(
                reference: pair.before,
                expected: beforePhysical.map {
                    .init(coordinate: $0, disposition: .replace)
                },
                targetGeometry: sourceGeometry
            )
        )
        let undoEncoded = try fixture.coordinator.encodeRestore(undoPrepared)
        let undoCompleted = try fixture.coordinator.completeRestore(
            undoEncoded,
            as: .succeeded
        )
        _ = try fixture.coordinator.publishRestore(
            fixture.coordinator.prepareTerminalRestore(undoCompleted)
        )
        #expect(fixture.registry.snapshot().geometry == sourceGeometry)
        #expect(fixture.registry.snapshot().layers[0].references.map(\.coordinate)
            == beforePhysical)

        let redoPrepared = try fixture.coordinator.prepareRestore(
            fixture.restoreRequest(
                reference: pair.after,
                expected: [
                    .init(coordinate: targetPhysical, disposition: .replace),
                ],
                targetGeometry: targetGeometry
            )
        )
        let redoEncoded = try fixture.coordinator.encodeRestore(redoPrepared)
        let redoCompleted = try fixture.coordinator.completeRestore(
            redoEncoded,
            as: .succeeded
        )
        _ = try fixture.coordinator.publishRestore(
            fixture.coordinator.prepareTerminalRestore(redoCompleted)
        )
        #expect(fixture.registry.snapshot().geometry == targetGeometry)
        #expect(fixture.registry.snapshot().layers[0].references.map(\.coordinate)
            == [targetPhysical])
        #expect(fixture.registry.snapshot().activeTileLeaseCount == 0)
        #expect(fixture.revisions.snapshot().inFlightInstallLeaseCount == 0)
        try fixture.revisions.release(pair.revisionIDs)
    }

    @Test
    func resizeRejectsInventedExpansionTilesAndIncompleteCropAuthority() throws {
        let zero = PaintTileCoordinate(x: 0, y: 0)
        let one = PaintTileCoordinate(x: 1, y: 0)

        guard let grow = try TransactionFixture.make(width: 256, height: 256)
        else { return }
        try transactionSeedActive(grow, coordinates: [zero])
        let grown = try transactionGeometry(width: 257, height: 256)
        let growBaseline = grow.registry.snapshot()
        #expect(throws: DocumentPaintSurfaceTransactionError
            .invalidResizeMapping) {
            _ = try grow.coordinator.prepareMutation(
                grow.request(
                    kind: .resize,
                    dirty: [zero, one],
                    candidateGeometry: grown
                )
            )
        }
        #expect(grow.registry.snapshot() == growBaseline)

        guard let crop = try TransactionFixture.make(width: 257, height: 256)
        else { return }
        try transactionSeedActive(crop, coordinates: [zero, one])
        let cropped = try transactionGeometry(width: 256, height: 256)
        let cropBaseline = crop.registry.snapshot()
        #expect(throws: DocumentPaintSurfaceTransactionError
            .invalidResizeMapping) {
            _ = try crop.coordinator.prepareMutation(
                crop.request(
                    kind: .resize,
                    dirty: [zero],
                    removing: [],
                    candidateGeometry: cropped
                )
            )
        }
        #expect(crop.registry.snapshot() == cropBaseline)
    }

    @Test
    func resizeFailureReturnsSourceAndDestinationLeasesAndAllowsImmediateRetry() throws {
        let kept = PaintTileCoordinate(x: 0, y: 0)
        let cropped = PaintTileCoordinate(x: 1, y: 0)
        for point in [
            DocumentPaintSurfaceTransactionFailurePoint.mutationCompletion,
            .destinationLeaseReturn,
            .sourceLeaseReturn,
        ] {
            guard let fixture = try TransactionFixture.make(
                width: 257,
                height: 256
            ) else { return }
            try transactionSeedActive(
                fixture,
                coordinates: [kept, cropped]
            )
            let target = try transactionGeometry(width: 255, height: 256)
            let baseline = fixture.registry.snapshot()
            let revisions = fixture.revisions.snapshot()
            let prepared = try transactionPrepared(
                fixture.coordinator.prepareMutation(
                    fixture.request(
                        kind: .resize,
                        dirty: [kept],
                        removing: [cropped],
                        candidateGeometry: target
                    )
                )
            )
            let encoded = try fixture.coordinator.encodeMutation(prepared)
            let expected: DocumentPaintSurfaceTransactionError
            switch point {
            case .mutationCompletion:
                expected = .backendCompletionFailed
            case .destinationLeaseReturn:
                expected = .destinationLeaseReturnFailed
            default:
                expected = .sourceLeaseReturnFailed
            }
            #expect(throws: expected) {
                _ = try fixture.coordinator.completeMutation(
                    encoded,
                    as: .succeeded,
                    failureInjection: .init(failingAt: point)
                )
            }
            if point == .mutationCompletion {
                #expect(fixture.coordinator.snapshot().state == .idle)
            } else {
                #expect(fixture.coordinator.snapshot().state == .discardPending)
                try fixture.coordinator.retryDiscard()
            }
            #expect(fixture.registry.snapshot() == baseline)
            #expect(fixture.revisions.snapshot() == revisions)
            #expect(fixture.registry.snapshot().activeTileLeaseCount == 0)

            let retry = try transactionPrepared(
                fixture.coordinator.prepareMutation(
                    fixture.request(
                        kind: .resize,
                        dirty: [kept],
                        removing: [cropped],
                        candidateGeometry: target
                    )
                )
            )
            let retryEncoded = try fixture.coordinator.encodeMutation(retry)
            let retryReduced = try fixture.coordinator.completeMutation(
                retryEncoded,
                as: .succeeded
            )
            try fixture.coordinator.discard(retryReduced)
            #expect(fixture.registry.snapshot() == baseline)
        }
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

    @Test
    func publishedRestoreRemovesAndReplacesWithHistoryCursorAdvancingOnlyAfterSuccess() throws {
        guard let fixture = try TransactionFixture.make(width: 256, height: 256)
        else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let committed = try transactionCommitWithHistory(
            fixture,
            coordinates: [coordinate]
        )
        let pair = try #require(committed.historyPair)
        let history = DocumentHistory()
        let command = DocumentHistoryCommand.raster(RasterHistoryCommand(
            layerID: fixture.layerID,
            kind: .draw,
            before: pair.before,
            after: pair.after
        ))
        _ = history.appendSuccessful(command)

        let undo = try #require(try history.beginUndo())
        let preparedUndo = try fixture.coordinator.prepareRestore(
            fixture.restoreRequest(
                reference: pair.before,
                expected: [.init(coordinate: coordinate, disposition: .remove)]
            )
        )
        #expect(fixture.registry.snapshot().generation == 1)
        #expect(history.canUndo)
        #expect(!history.canRedo)
        let encodedUndo = try fixture.coordinator.encodeRestore(preparedUndo)
        let completedUndo = try fixture.coordinator.completeRestore(
            encodedUndo,
            as: .succeeded
        )
        let terminalUndo = try fixture.coordinator.prepareTerminalRestore(
            completedUndo
        )
        let undoResult = try fixture.coordinator.publishRestore(terminalUndo)
        #expect(undoResult.reference == pair.before)
        #expect(undoResult.beforeGeneration == 1)
        #expect(undoResult.afterGeneration == 2)
        #expect(fixture.registry.snapshot().layers[0].references.isEmpty)
        #expect(history.canUndo)
        #expect(!history.canRedo)

        try history.finishNavigation(token: undo.token, succeeded: true)
        #expect(!history.canUndo)
        #expect(history.canRedo)

        let redo = try #require(try history.beginRedo())
        let preparedRedo = try fixture.coordinator.prepareRestore(
            fixture.restoreRequest(
                reference: pair.after,
                expected: [.init(coordinate: coordinate, disposition: .replace)]
            )
        )
        let encodedRedo = try fixture.coordinator.encodeRestore(preparedRedo)
        let completedRedo = try fixture.coordinator.completeRestore(
            encodedRedo,
            as: .succeeded
        )
        let terminalRedo = try fixture.coordinator.prepareTerminalRestore(
            completedRedo
        )
        _ = try fixture.coordinator.publishRestore(terminalRedo)
        try history.finishNavigation(token: redo.token, succeeded: true)
        #expect(history.canUndo)
        #expect(!history.canRedo)
        #expect(fixture.registry.snapshot().layers[0].references.map(\.coordinate)
            == [coordinate])
    }

    @Test
    func publishedKnownClearRestoreIsIdempotentWhenActiveBaseAlreadyOmitsCoordinate() throws {
        guard let fixture = try TransactionFixture.make(width: 256, height: 256)
        else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let pair = try transactionCapturedPair(
            fixture,
            coordinates: [coordinate],
            beforePresentCoordinates: [],
            afterPresentCoordinates: [],
            publish: true
        )

        for expectedGeneration in 1...2 {
            let prepared = try fixture.coordinator.prepareRestore(
                fixture.restoreRequest(
                    reference: pair.after,
                    expected: [
                        .init(
                            coordinate: coordinate,
                            disposition: .remove
                        ),
                    ]
                )
            )
            let encoded = try fixture.coordinator.encodeRestore(prepared)
            let completed = try fixture.coordinator.completeRestore(
                encoded,
                as: .succeeded
            )
            let terminal = try fixture.coordinator.prepareTerminalRestore(
                completed
            )
            let result = try fixture.coordinator.publishRestore(terminal)

            #expect(result.afterGeneration == UInt64(expectedGeneration))
            #expect(result.restoredCoordinates == [coordinate])
            let registry = fixture.registry.snapshot()
            #expect(registry.layers[0].references.isEmpty)
            #expect(registry.activeTileLeaseCount == 0)
            #expect(registry.preparedCandidateCount == 0)
            #expect(fixture.revisions.snapshot().inFlightInstallLeaseCount == 0)
            #expect(fixture.coordinator.snapshot().state == .idle)
        }

        try fixture.revisions.release(pair.revisionIDs)
    }

    @Test
    func restoreRejectsProvisionalForgedForeignLayerGeometryAndDispositionAuthority() throws {
        guard let fixture = try TransactionFixture.make(width: 256, height: 256)
        else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let provisional = try transactionCapturedPair(
            fixture,
            coordinate: coordinate,
            publish: false
        )
        #expect(throws: DocumentPaintSurfaceTransactionError
            .restoreReferenceUnavailable) {
            _ = try fixture.coordinator.prepareRestore(
                fixture.restoreRequest(
                    reference: provisional.after,
                    expected: [
                        .init(coordinate: coordinate, disposition: .replace),
                    ]
                )
            )
        }
        try fixture.revisions.discard(provisional)

        let published = try transactionCapturedPair(
            fixture,
            coordinate: coordinate,
            publish: true
        )
        let forged = RasterRevisionReference(
            id: published.after.id,
            pixelSize: published.after.pixelSize,
            documentPixelSize: published.after.documentPixelSize,
            regions: published.after.regions,
            retainedBytes: published.after.retainedBytes + 1,
            storage: published.after.storage
        )
        #expect(throws: DocumentPaintSurfaceTransactionError
            .restoreReferenceUnavailable) {
            _ = try fixture.coordinator.prepareRestore(
                fixture.restoreRequest(
                    reference: forged,
                    expected: [
                        .init(coordinate: coordinate, disposition: .replace),
                    ]
                )
            )
        }

        guard let foreignFixture = try TransactionFixture.make(
            width: 256,
            height: 256,
            layerID: fixture.layerID
        ) else { return }
        let foreign = try transactionCapturedPair(
            foreignFixture,
            coordinate: coordinate,
            publish: true
        )
        #expect(throws: DocumentPaintSurfaceTransactionError
            .restoreReferenceUnavailable) {
            _ = try fixture.coordinator.prepareRestore(
                fixture.restoreRequest(
                    reference: foreign.after,
                    expected: [
                        .init(coordinate: coordinate, disposition: .replace),
                    ]
                )
            )
        }

        let wrongLayer = UUID()
        #expect(throws: DocumentPaintSurfaceTransactionError
            .restoreLayerMismatch(
                expected: fixture.layerID,
                actual: wrongLayer
            )) {
            _ = try fixture.coordinator.prepareRestore(
                DocumentPaintSurfaceRestoreRequest(
                    reference: published.after,
                    targetGeometry: fixture.geometry,
                    layerID: wrongLayer,
                    expectedInstallDispositions: [
                        .init(coordinate: coordinate, disposition: .replace),
                    ]
                )
            )
        }
        let wrongGeometry = try transactionGeometry(width: 512, height: 256)
        #expect(throws: DocumentPaintSurfaceTransactionError
            .restoreGeometryMismatch) {
            _ = try fixture.coordinator.prepareRestore(
                fixture.restoreRequest(
                    reference: published.after,
                    expected: [
                        .init(coordinate: coordinate, disposition: .replace),
                    ],
                    targetGeometry: wrongGeometry
                )
            )
        }
        let wrongVisibleGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 128, height: 256),
            storagePixelSize: fixture.geometry.storagePixelSize,
            radialLayout: nil
        )
        #expect(throws: DocumentPaintSurfaceTransactionError
            .restoreGeometryMismatch) {
            _ = try fixture.coordinator.prepareRestore(
                fixture.restoreRequest(
                    reference: published.after,
                    expected: [
                        .init(
                            coordinate: coordinate,
                            disposition: .replace
                        ),
                    ],
                    targetGeometry: wrongVisibleGeometry
                )
            )
        }
        #expect(throws: DocumentPaintSurfaceTransactionError
            .restoreDispositionMismatch) {
            _ = try fixture.coordinator.prepareRestore(
                fixture.restoreRequest(
                    reference: published.after,
                    expected: [
                        .init(coordinate: coordinate, disposition: .remove),
                    ]
                )
            )
        }
        #expect(fixture.coordinator.snapshot().state == .idle)
        try fixture.revisions.release(published.revisionIDs)
        try foreignFixture.revisions.release(foreign.revisionIDs)
    }

    @Test
    func restoreCancellationAtPreparedEncodedAndCompletedIsExactlyOnceAndReusable() throws {
        for phase in 0..<3 {
            guard let fixture = try TransactionFixture.make(
                width: 256,
                height: 256
            ) else { return }
            let coordinate = PaintTileCoordinate(x: 0, y: 0)
            let pair = try transactionCapturedPair(
                fixture,
                coordinate: coordinate,
                publish: true
            )
            let prepared = try fixture.coordinator.prepareRestore(
                fixture.restoreRequest(
                    reference: pair.after,
                    expected: [
                        .init(coordinate: coordinate, disposition: .replace),
                    ]
                )
            )
            switch phase {
            case 0:
                try fixture.coordinator.discard(prepared)
                #expect(throws: DocumentPaintSurfaceTransactionError.staleHandle) {
                    try fixture.coordinator.discard(prepared)
                }
            case 1:
                let encoded = try fixture.coordinator.encodeRestore(prepared)
                try fixture.coordinator.discard(encoded)
                #expect(throws: DocumentPaintSurfaceTransactionError.staleHandle) {
                    try fixture.coordinator.discard(encoded)
                }
            default:
                let encoded = try fixture.coordinator.encodeRestore(prepared)
                let completed = try fixture.coordinator.completeRestore(
                    encoded,
                    as: .succeeded
                )
                try fixture.coordinator.discard(completed)
                #expect(throws: DocumentPaintSurfaceTransactionError.staleHandle) {
                    try fixture.coordinator.discard(completed)
                }
            }
            #expect(fixture.coordinator.snapshot().state == .idle)
            #expect(fixture.registry.snapshot().activeTileLeaseCount == 0)
            #expect(fixture.registry.snapshot().preparedCandidateCount == 0)
            #expect(fixture.revisions.snapshot().inFlightInstallLeaseCount == 0)

            let immediate = try fixture.coordinator.prepareRestore(
                fixture.restoreRequest(
                    reference: pair.after,
                    expected: [
                        .init(coordinate: coordinate, disposition: .replace),
                    ]
                )
            )
            try fixture.coordinator.discard(immediate)
            try fixture.revisions.release(pair.revisionIDs)
        }
    }

    @Test
    func actualConsumeRejectionKeepsTerminalRestoreAndHistoryCursorRetryable() throws {
        guard let fixture = try TransactionFixture.make(width: 256, height: 256)
        else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let committed = try transactionCommitWithHistory(
            fixture,
            coordinates: [coordinate]
        )
        let pair = try #require(committed.historyPair)
        let history = DocumentHistory()
        _ = history.appendSuccessful(.raster(RasterHistoryCommand(
            layerID: fixture.layerID,
            kind: .draw,
            before: pair.before,
            after: pair.after
        )))
        let undo = try #require(try history.beginUndo())
        let prepared = try fixture.coordinator.prepareRestore(
            fixture.restoreRequest(
                reference: pair.before,
                expected: [.init(coordinate: coordinate, disposition: .remove)]
            )
        )
        let encoded = try fixture.coordinator.encodeRestore(prepared)
        let completed = try fixture.coordinator.completeRestore(
            encoded,
            as: .succeeded
        )
        let terminal = try fixture.coordinator.prepareTerminalRestore(completed)
        let before = fixture.registry.snapshot()

        #expect(throws: DocumentPaintSurfaceTransactionError
            .restoreConsumeFailed) {
            _ = try fixture.coordinator.publishRestore(
                terminal,
                failureInjection: .init(failingAt: .restoreConsume)
            )
        }
        #expect(fixture.registry.snapshot() == before)
        #expect(fixture.coordinator.snapshot().phase == .restoreTerminalPrepared)
        #expect(history.canUndo)
        #expect(!history.canRedo)

        _ = try fixture.coordinator.publishRestore(terminal)
        try history.finishNavigation(token: undo.token, succeeded: true)
        #expect(!history.canUndo)
        #expect(history.canRedo)
        #expect(fixture.coordinator.snapshot().state == .idle)
    }

    @Test
    func restoreFailureSeamsRetainExactOwnershipAndAllowImmediateReuse() throws {
        let coordinate = PaintTileCoordinate(x: 0, y: 0)

        guard let reserveFixture = try TransactionFixture.make(
            width: 256,
            height: 256
        ) else { return }
        let reservePair = try transactionCapturedPair(
            reserveFixture,
            coordinate: coordinate,
            publish: true
        )
        #expect(throws: DocumentPaintSurfaceTransactionError
            .restorePreparationFailed) {
            _ = try reserveFixture.coordinator.prepareRestore(
                reserveFixture.restoreRequest(
                    reference: reservePair.after,
                    expected: [
                        .init(coordinate: coordinate, disposition: .replace),
                    ]
                ),
                failureInjection: .init(failingAt: .candidateReserve(0))
            )
        }
        #expect(reserveFixture.coordinator.snapshot().state == .idle)
        #expect(reserveFixture.registry.snapshot().activeTileLeaseCount == 0)
        #expect(reserveFixture.revisions.snapshot().inFlightInstallLeaseCount == 0)
        try reserveFixture.revisions.release(reservePair.revisionIDs)

        for point in [
            DocumentPaintSurfaceTransactionFailurePoint.restoreEncoding,
            .restoreCompletion,
            .restoreDestinationLeaseReturn,
        ] {
            guard let fixture = try TransactionFixture.make(
                width: 256,
                height: 256
            ) else { return }
            let pair = try transactionCapturedPair(
                fixture,
                coordinate: coordinate,
                publish: true
            )
            let prepared = try fixture.coordinator.prepareRestore(
                fixture.restoreRequest(
                    reference: pair.after,
                    expected: [
                        .init(coordinate: coordinate, disposition: .replace),
                    ]
                )
            )
            if point == .restoreEncoding {
                #expect(throws: DocumentPaintSurfaceTransactionError
                    .restoreEncodingFailed) {
                    _ = try fixture.coordinator.encodeRestore(
                        prepared,
                        failureInjection: .init(failingAt: point)
                    )
                }
            } else {
                let encoded = try fixture.coordinator.encodeRestore(prepared)
                let expectedError: DocumentPaintSurfaceTransactionError =
                    point == .restoreCompletion
                        ? .restoreCompletionFailed
                        : .destinationLeaseReturnFailed
                #expect(throws: expectedError) {
                    _ = try fixture.coordinator.completeRestore(
                        encoded,
                        as: .succeeded,
                        failureInjection: .init(failingAt: point)
                    )
                }
            }
            #expect(fixture.coordinator.snapshot().state == .discardPending)
            try fixture.coordinator.retryDiscard()
            #expect(fixture.coordinator.snapshot().state == .idle)
            #expect(fixture.registry.snapshot().activeTileLeaseCount == 0)
            #expect(fixture.registry.snapshot().preparedCandidateCount == 0)
            #expect(fixture.revisions.snapshot().inFlightInstallLeaseCount == 0)

            let retry = try fixture.coordinator.prepareRestore(
                fixture.restoreRequest(
                    reference: pair.after,
                    expected: [
                        .init(coordinate: coordinate, disposition: .replace),
                    ]
                )
            )
            try fixture.coordinator.discard(retry)
            try fixture.revisions.release(pair.revisionIDs)
        }

        guard let terminalFixture = try TransactionFixture.make(
            width: 256,
            height: 256
        ) else { return }
        let terminalPair = try transactionCapturedPair(
            terminalFixture,
            coordinate: coordinate,
            publish: true
        )
        let prepared = try terminalFixture.coordinator.prepareRestore(
            terminalFixture.restoreRequest(
                reference: terminalPair.after,
                expected: [
                    .init(coordinate: coordinate, disposition: .replace),
                ]
            )
        )
        let encoded = try terminalFixture.coordinator.encodeRestore(prepared)
        let completed = try terminalFixture.coordinator.completeRestore(
            encoded,
            as: .succeeded
        )
        #expect(throws: DocumentPaintSurfaceTransactionError
            .terminalPreflightFailed) {
            _ = try terminalFixture.coordinator.prepareTerminalRestore(
                completed,
                failureInjection: .init(failingAt: .restoreTerminalPreflight)
            )
        }
        #expect(throws: DocumentPaintSurfaceTransactionError
            .registryPreparationFailed) {
            _ = try terminalFixture.coordinator.prepareTerminalRestore(
                completed,
                failureInjection: .init(failingAt: .restoreRegistryPrepare)
            )
        }
        let terminal = try terminalFixture.coordinator
            .prepareTerminalRestore(completed)
        #expect(throws: DocumentPaintSurfaceTransactionError
            .restoreConsumeFailed) {
            _ = try terminalFixture.coordinator.publishRestore(
                terminal,
                failureInjection: .init(failingAt: .restoreConsume)
            )
        }
        try terminalFixture.coordinator.discard(terminal)
        #expect(terminalFixture.coordinator.snapshot().state == .idle)
        let immediate = try terminalFixture.coordinator.prepareRestore(
            terminalFixture.restoreRequest(
                reference: terminalPair.after,
                expected: [
                    .init(coordinate: coordinate, disposition: .replace),
                ]
            )
        )
        try terminalFixture.coordinator.discard(immediate)
        try terminalFixture.revisions.release(terminalPair.revisionIDs)
    }

    @Test
    func releaseDuringRestoreInstallDefersRevisionRemovalUntilConsume() throws {
        guard let fixture = try TransactionFixture.make(width: 256, height: 256)
        else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let pair = try transactionCapturedPair(
            fixture,
            coordinate: coordinate,
            publish: true
        )
        let prepared = try fixture.coordinator.prepareRestore(
            fixture.restoreRequest(
                reference: pair.after,
                expected: [.init(coordinate: coordinate, disposition: .replace)]
            )
        )
        let encoded = try fixture.coordinator.encodeRestore(prepared)

        try fixture.revisions.release([pair.after.id])
        #expect(fixture.revisions.containsRevision(pair.after.id))
        let completed = try fixture.coordinator.completeRestore(
            encoded,
            as: .succeeded
        )
        #expect(fixture.revisions.containsRevision(pair.after.id))
        let terminal = try fixture.coordinator.prepareTerminalRestore(completed)
        _ = try fixture.coordinator.publishRestore(terminal)

        #expect(!fixture.revisions.containsRevision(pair.after.id))
        #expect(fixture.registry.snapshot().layers[0].references.map(\.coordinate)
            == [coordinate])
        try fixture.revisions.release([pair.before.id])
    }

    @Test
    func restoreDispositionAuthorityRejectsOrderAndDuplicatesBeforeLeasing() throws {
        guard let fixture = try TransactionFixture.make(width: 512, height: 256)
        else { return }
        let first = PaintTileCoordinate(x: 0, y: 0)
        let second = PaintTileCoordinate(x: 1, y: 0)
        let pair = try transactionCapturedPair(
            fixture,
            coordinates: [first, second],
            beforePresentCoordinates: [],
            afterPresentCoordinates: [first, second],
            publish: true
        )
        #expect(throws: DocumentPaintSurfaceTransactionError
            .unsortedCoordinate(previous: second, current: first)) {
            _ = try fixture.coordinator.prepareRestore(
                fixture.restoreRequest(
                    reference: pair.after,
                    expected: [
                        .init(coordinate: second, disposition: .replace),
                        .init(coordinate: first, disposition: .replace),
                    ]
                )
            )
        }
        #expect(throws: DocumentPaintSurfaceTransactionError
            .duplicateCoordinate(first)) {
            _ = try fixture.coordinator.prepareRestore(
                fixture.restoreRequest(
                    reference: pair.after,
                    expected: [
                        .init(coordinate: first, disposition: .replace),
                        .init(coordinate: first, disposition: .replace),
                    ]
                )
            )
        }
        #expect(fixture.revisions.snapshot().inFlightInstallLeaseCount == 0)
        try fixture.revisions.release(pair.revisionIDs)
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
    private(set) var resizePayload: DocumentPaintSurfaceResizeBackendPayload?

    func preflight(_ operation: DocumentPaintSurfaceBackendOperation) throws {
        switch operation {
        case let .mutation(_, destinations):
            _ = destinations
        case let .resize(payload):
            resizePayload = payload
            destinations = payload.destinations
        case let .restore(payload):
            _ = payload.reference
            destinations = payload.destinations
        }
    }

    func encode(
        _ operation: DocumentPaintSurfaceBackendOperation
    ) throws -> DocumentPaintSurfaceMutationBackendEncoding {
        encodeCallCount += 1
        switch operation {
        case let .mutation(_, destinations):
            self.destinations = destinations
        case let .resize(payload):
            resizePayload = payload
            destinations = payload.destinations
        case let .restore(payload):
            destinations = payload.destinations
        }
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

    static func make(
        width: Int = 512,
        height: Int = 512,
        layerID requestedLayerID: UUID? = nil,
        geometry requestedGeometry: DocumentPaintGeometry? = nil
    ) throws -> Self? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }
        let layerID = requestedLayerID ?? UUID()
        let geometry = try requestedGeometry
            ?? transactionGeometry(width: width, height: height)
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

    func restoreRequest(
        reference: RasterRevisionReference,
        expected: [DocumentPaintSurfaceRestoreTileExpectation],
        targetGeometry: DocumentPaintGeometry? = nil
    ) -> DocumentPaintSurfaceRestoreRequest {
        DocumentPaintSurfaceRestoreRequest(
            reference: reference,
            targetGeometry: targetGeometry ?? geometry,
            layerID: layerID,
            expectedInstallDispositions: expected
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

private func transactionRadialPhysicalCoordinate(
    _ page: RadialResidentPage,
    layout: RadialSectorLayout
) -> PaintTileCoordinate {
    PaintTileCoordinate(
        x: page.atlasSlot % layout.atlasColumns,
        y: page.atlasSlot / layout.atlasColumns
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

private func transactionCapturedPair(
    _ fixture: TransactionFixture,
    coordinate: PaintTileCoordinate,
    publish: Bool
) throws -> PendingRasterRevisionPair {
    try transactionCapturedPair(
        fixture,
        coordinates: [coordinate],
        beforePresentCoordinates: [],
        afterPresentCoordinates: [coordinate],
        publish: publish
    )
}

private func transactionCapturedPair(
    _ fixture: TransactionFixture,
    coordinates: [PaintTileCoordinate],
    beforePresentCoordinates: [PaintTileCoordinate],
    afterPresentCoordinates: [PaintTileCoordinate],
    publish: Bool
) throws -> PendingRasterRevisionPair {
    let before = try TiledRasterRevisionEndpoint(
        generation: 1,
        pixelSize: fixture.geometry.storagePixelSize,
        documentPixelSize: fixture.geometry.documentPixelSize,
        coordinates: coordinates,
        presentCoordinates: beforePresentCoordinates
    )
    let after = try TiledRasterRevisionEndpoint(
        generation: 1,
        pixelSize: fixture.geometry.storagePixelSize,
        documentPixelSize: fixture.geometry.documentPixelSize,
        coordinates: coordinates,
        presentCoordinates: afterPresentCoordinates
    )
    let pair = try fixture.revisions.allocatePair(
        layerID: fixture.layerID,
        before: before,
        after: after
    )
    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: PaintTileDescriptor.pixelFormat,
        width: PaintTileDescriptor.side,
        height: PaintTileDescriptor.side,
        mipmapped: false
    )
    textureDescriptor.storageMode = .shared
    textureDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    let texture = try #require(fixture.device.makeTexture(
        descriptor: textureDescriptor
    ))
    let queue = try #require(fixture.device.makeCommandQueue())
    let command = try #require(queue.makeCommandBuffer())
    let beforePresent = Set(beforePresentCoordinates)
    let afterPresent = Set(afterPresentCoordinates)
    let beforeToken = try fixture.revisions.encodeCapture(
        pair.before,
        layerID: fixture.layerID,
        generation: 1,
        sources: coordinates.map {
            beforePresent.contains($0)
                ? .texture(coordinate: $0, texture: texture)
                : .knownClear(coordinate: $0)
        },
        on: command
    )
    let afterToken = try fixture.revisions.encodeCapture(
        pair.after,
        layerID: fixture.layerID,
        generation: 1,
        sources: coordinates.map {
            afterPresent.contains($0)
                ? .texture(coordinate: $0, texture: texture)
                : .knownClear(coordinate: $0)
        },
        on: command
    )
    command.commit()
    command.waitUntilCompleted()
    try fixture.revisions.finalize(beforeToken, as: .succeeded)
    try fixture.revisions.finalize(afterToken, as: .succeeded)
    if publish { try fixture.revisions.publish(pair) }
    return pair
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
