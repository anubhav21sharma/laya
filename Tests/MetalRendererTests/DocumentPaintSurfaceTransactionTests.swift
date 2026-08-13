import Foundation
@testable import EditorCore
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Document paint surface transaction", .serialized)
struct DocumentPaintSurfaceTransactionTests {
    @Test
    func quiescenceOracleCapturesEveryObservableOwnershipDimension() throws {
        guard let fixture = try TransactionFixture.make() else { return }
        let history = DocumentHistory()
        let oracle = try TransactionQuiescenceOracle.capture(
            fixture,
            history: history
        )

        try oracle.expectRestored(fixture, history: history)
        #expect(oracle.transactionOwnership.candidateIdentity == nil)
        #expect(oracle.transactionOwnership.reduction == nil)
        #expect(!oracle.transactionOwnership.hasResizePlan)
        #expect(history.diagnosticSnapshotForTesting().commands.isEmpty)
        #expect(oracle.activeLayerPayloads.count == 1)
    }

    @Test
    func quiescenceOracleDetectsCanonicalByteChangesWithStableMetadata() throws {
        guard let fixture = try TransactionFixture.make(width: 256, height: 256)
        else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try transactionSeedActive(fixture, coordinates: [coordinate])
        let oracle = try TransactionQuiescenceOracle.capture(fixture)
        let metadata = fixture.registry.snapshot()

        try transactionOverwriteActiveCanonicalBytes(
            fixture,
            coordinate: coordinate,
            byte: 0x3c
        )

        #expect(fixture.registry.snapshot() == metadata)
        #expect(try !oracle.matchesActiveLayerPayloads(fixture))
    }

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
    func clearBackendOperationHasNoReadSourcesOrDestinations() throws {
        guard let fixture = try TransactionFixture.make() else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try transactionSeedActive(fixture, coordinates: [coordinate])
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareMutation(
                fixture.request(
                    kind: .clear,
                    dirty: [],
                    removing: [coordinate]
                )
            )
        )

        let encoded = try fixture.coordinator.encodeMutation(prepared)

        #expect(fixture.backend.clearOperationCount == 1)
        #expect(fixture.backend.strokePayload == nil)
        #expect(fixture.backend.destinations.isEmpty)
        try fixture.coordinator.discard(encoded)
    }

    @Test
    func productionStrokeRejectsMissingTask5AuthoritativeLeaseWithoutLeaks()
        throws
    {
        guard let fixture = try TransactionFixture.make(
            allowsTestStrokeSources: false
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareMutation(
                fixture.request(dirty: [coordinate])
            )
        )

        #expect(throws: DocumentPaintSurfaceTransactionError
            .missingStrokeAuthoritativeLease) {
            _ = try fixture.coordinator.encodeMutation(prepared)
        }
        let ownership = fixture.coordinator.ownershipSnapshotForTesting()
        #expect(ownership.destinationLeaseID == nil)
        #expect(ownership.strokeBaseSourceLeaseID == nil)
        #expect(ownership.strokeCommitSourceLeaseID == nil)
        #expect(fixture.backend.encodeCallCount == 0)
        try fixture.coordinator.discard(prepared)
    }

    @Test
    func strokePayloadOrdersPresentAndKnownClearCanonicalSourcesExactly()
        throws
    {
        guard let fixture = try TransactionFixture.make(width: 512, height: 256)
        else { return }
        let present = PaintTileCoordinate(x: 0, y: 0)
        let missing = PaintTileCoordinate(x: 1, y: 0)
        try transactionSeedActive(fixture, coordinates: [present])
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareMutation(
                fixture.request(dirty: [present, missing])
            )
        )

        let encoded = try fixture.coordinator.encodeMutation(prepared)

        let payload = try #require(fixture.backend.strokePayload)
        #expect(payload.baseSources.map(\.coordinate) == [present, missing])
        #expect(payload.authoritativeSources.map(\.coordinate)
            == [present, missing])
        guard case .texture = payload.baseSources[0],
              case .knownClear = payload.baseSources[1],
              case .knownClear = payload.authoritativeSources[0],
              case .knownClear = payload.authoritativeSources[1]
        else {
            Issue.record("Unexpected typed stroke source variants")
            return
        }
        let ownership = fixture.coordinator.ownershipSnapshotForTesting()
        #expect(ownership.strokeBaseSourceLeaseID != nil)
        #expect(ownership.strokeCommitSourceLeaseID == nil)
        try fixture.coordinator.discard(encoded)
    }

    @Test
    func strokePayloadRejectsReadDestinationTextureAliasBeforeBackend() throws {
        guard let fixture = try TransactionFixture.make(width: 256, height: 256)
        else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: PaintTileDescriptor.pixelFormat,
            width: PaintTileDescriptor.side,
            height: PaintTileDescriptor.side,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        let texture = try #require(fixture.device.makeTexture(
            descriptor: descriptor
        ))
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let bounds = try PaintTileDescriptor(
            coordinate: coordinate,
            logicalPixelSize: fixture.geometry.storagePixelSize
        ).logicalBounds
        let source = DocumentPaintSurfaceMutationSource(
            coordinate: coordinate,
            logicalBounds: bounds,
            texture: texture
        )
        let payload = DocumentPaintSurfaceStrokeBackendPayload(
            geometry: fixture.geometry,
            compositeParameters: .opaqueDraw,
            baseSources: [.knownClear(
                coordinate: coordinate,
                logicalBounds: bounds
            )],
            authoritativeSources: [.texture(source)],
            predictionSources: [.knownClear(
                coordinate: coordinate,
                logicalBounds: bounds
            )],
            destinations: [.init(
                coordinate: coordinate,
                logicalBounds: bounds,
                texture: texture
            )]
        )

        #expect(throws: DocumentPaintSurfaceTransactionError
            .strokeTextureAlias) {
            try DocumentPaintSurfaceTransaction.validateStrokePayload(
                payload,
                expectedCoordinates: [coordinate]
            )
        }
        #expect(fixture.backend.encodeCallCount == 0)
    }

    @Test
    func requestValidationRejectsWrongLayerGeometryAndBounds() throws {
        guard let fixture = try TransactionFixture.make() else { return }
        let zero = PaintTileCoordinate(x: 0, y: 0)
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
    func transactionBoundarySortsAndDeduplicatesDirtyCoordinates() throws {
        guard let fixture = try TransactionFixture.make() else { return }
        let zero = PaintTileCoordinate(x: 0, y: 0)
        let one = PaintTileCoordinate(x: 1, y: 0)

        let result = try transactionCommitWithHistory(
            fixture,
            request: fixture.request(dirty: [one, zero, one])
        )

        #expect(result.dirtyCoordinates == [zero, one])
        #expect(fixture.registry.snapshot().layers[0].references
            .map(\.coordinate) == [zero, one])
        if let pair = result.historyPair {
            try fixture.revisions.release(pair.revisionIDs)
        }
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
    func quiescenceOracleCoversMissingMutationAndHistoryRows() throws {
        let first = PaintTileCoordinate(x: 0, y: 0)
        let second = PaintTileCoordinate(x: 1, y: 0)

        guard let reserve = try TransactionFixture.make(width: 512, height: 256)
        else { return }
        let reserveOracle = try TransactionQuiescenceOracle.capture(reserve)
        #expect(throws: PaintTileStoreError
            .injectedAllocationFailure(reserveIndex: 1)) {
            _ = try reserve.coordinator.prepareMutation(
                reserve.request(
                    dirty: [first, second],
                    requiresHistoryPair: false
                ),
                failureInjection: .init(failingAt: .candidateReserve(1))
            )
        }
        try reserveOracle.expectRestored(reserve)
        _ = try transactionCommitNoHistory(
            reserve,
            request: reserve.request(
                dirty: [first],
                requiresHistoryPair: false
            )
        )

        for outcome in [
            RasterRevisionOperationOutcome.failed,
            .cancelled,
        ] {
            guard let fixture = try TransactionFixture.make() else { return }
            let oracle = try TransactionQuiescenceOracle.capture(fixture)
            let prepared = try transactionPrepared(
                fixture.coordinator.prepareMutation(
                    fixture.request(
                        dirty: [first],
                        requiresHistoryPair: false
                    )
                )
            )
            let encoded = try fixture.coordinator.encodeMutation(prepared)
            #expect(throws: DocumentPaintSurfaceTransactionError
                .mutationCommandFailed) {
                _ = try fixture.coordinator.completeMutation(
                    encoded,
                    as: outcome
                )
            }
            try oracle.expectRestored(fixture)
            _ = try transactionCommitNoHistory(
                fixture,
                request: fixture.request(
                    dirty: [first],
                    requiresHistoryPair: false
                )
            )
        }

        for point in [
            DocumentPaintSurfaceTransactionFailurePoint.historyAllocation(1),
            .historyEncoding,
        ] {
            guard let fixture = try TransactionFixture.make() else { return }
            try transactionSeedActive(fixture, coordinates: [first])
            let oracle = try TransactionQuiescenceOracle.capture(fixture)
            let request = fixture.request(dirty: [first])
            let reduced = try transactionReduced(fixture, coordinates: [first])
            let expected: DocumentPaintSurfaceTransactionError =
                point == .historyEncoding
                    ? .historyCaptureFailed
                    : .historyAllocationFailed
            #expect(throws: expected) {
                _ = try fixture.coordinator.encodeHistoryCapture(
                    reduced,
                    failureInjection: .init(failingAt: point)
                )
            }
            try oracle.expectRestored(fixture)
            let result = try transactionCommitWithHistory(
                fixture,
                request: request
            )
            try fixture.revisions.release(
                try #require(result.historyPair).revisionIDs
            )
        }

        for outcome in [
            RasterRevisionOperationOutcome.failed,
            .cancelled,
        ] {
            guard let fixture = try TransactionFixture.make() else { return }
            try transactionSeedActive(fixture, coordinates: [first])
            let oracle = try TransactionQuiescenceOracle.capture(fixture)
            let request = fixture.request(dirty: [first])
            let reduced = try transactionReduced(fixture, coordinates: [first])
            let encodedHistory = try fixture.coordinator
                .encodeHistoryCapture(reduced)
            #expect(throws: DocumentPaintSurfaceTransactionError
                .historyFinalizationFailed) {
                _ = try fixture.coordinator.completeHistoryCapture(
                    encodedHistory,
                    as: outcome
                )
            }
            try oracle.expectRestored(fixture)
            let result = try transactionCommitWithHistory(
                fixture,
                request: request
            )
            try fixture.revisions.release(
                try #require(result.historyPair).revisionIDs
            )
        }
    }

    @Test
    func quiescenceOracleCoversMutationCleanupAtEveryOwnedPhase() throws {
        let coordinate = PaintTileCoordinate(x: 0, y: 0)

        guard let encodedFixture = try TransactionFixture.make() else { return }
        let encodedOracle = try TransactionQuiescenceOracle.capture(encodedFixture)
        let encodedRequest = encodedFixture.request(
            dirty: [coordinate],
            requiresHistoryPair: false
        )
        let prepared = try transactionPrepared(
            encodedFixture.coordinator.prepareMutation(encodedRequest)
        )
        let encoded = try encodedFixture.coordinator.encodeMutation(prepared)
        #expect(throws: DocumentPaintSurfaceTransactionError.cleanupFailed) {
            try encodedFixture.coordinator.discard(
                encoded,
                failureInjection: .init(failingAt: .cleanup)
            )
        }
        #expect(encodedFixture.coordinator.snapshot().state == .discardPending)
        #expect(encodedFixture.backend.liveResourceCount == 1)
        try encodedFixture.coordinator.retryDiscard()
        try encodedOracle.expectRestored(encodedFixture)
        _ = try transactionCommitNoHistory(
            encodedFixture,
            request: encodedRequest
        )

        for terminalPhase in [false, true] {
            guard let fixture = try TransactionFixture.make() else { return }
            let oracle = try TransactionQuiescenceOracle.capture(fixture)
            let request = fixture.request(dirty: [coordinate])
            let reduced = try transactionReduced(fixture, coordinates: [coordinate])
            let encodedHistory = try fixture.coordinator
                .encodeHistoryCapture(reduced)
            if terminalPhase {
                let completed = try fixture.coordinator.completeHistoryCapture(
                    encodedHistory,
                    as: .succeeded
                )
                let terminal = try fixture.coordinator
                    .prepareTerminalCommit(completed)
                #expect(throws: DocumentPaintSurfaceTransactionError
                    .cleanupFailed) {
                    try fixture.coordinator.discard(
                        terminal,
                        failureInjection: .init(failingAt: .cleanup)
                    )
                }
            } else {
                #expect(throws: DocumentPaintSurfaceTransactionError
                    .cleanupFailed) {
                    try fixture.coordinator.discard(
                        encodedHistory,
                        failureInjection: .init(failingAt: .cleanup)
                    )
                }
            }
            #expect(fixture.coordinator.snapshot().state == .discardPending)
            try fixture.coordinator.retryDiscard()
            try oracle.expectRestored(fixture)
            let result = try transactionCommitWithHistory(
                fixture,
                request: request
            )
            try fixture.revisions.release(
                try #require(result.historyPair).revisionIDs
            )
        }
    }

    @Test
    func quiescenceOracleCoversLateResizePublishRollback() throws {
        guard let fixture = try TransactionFixture.make(width: 257, height: 256)
        else { return }
        let kept = PaintTileCoordinate(x: 0, y: 0)
        let cropped = PaintTileCoordinate(x: 1, y: 0)
        try transactionSeedActive(fixture, coordinates: [kept, cropped])
        let target = try transactionGeometry(width: 255, height: 256)
        let request = fixture.request(
            kind: .resize,
            dirty: [kept],
            removing: [cropped],
            candidateGeometry: target
        )
        let oracle = try TransactionQuiescenceOracle.capture(fixture)
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareMutation(request)
        )
        let encoded = try fixture.coordinator.encodeMutation(prepared)
        let reduced = try fixture.coordinator.completeMutation(
            encoded,
            as: .succeeded
        )
        let encodedHistory = try fixture.coordinator
            .encodeHistoryCapture(reduced)
        let completed = try fixture.coordinator.completeHistoryCapture(
            encodedHistory,
            as: .succeeded
        )
        let terminal = try fixture.coordinator.prepareTerminalCommit(completed)
        #expect(throws: DocumentPaintSurfaceTransactionError
            .revisionPublishFailed) {
            _ = try fixture.coordinator.publish(
                terminal,
                failureInjection: .init(failingAt: .revisionPublish)
            )
        }
        #expect(fixture.coordinator.snapshot().phase == .terminalPrepared)
        try fixture.coordinator.discard(terminal)
        try oracle.expectRestored(fixture)

        let result = try transactionCommitWithHistory(
            fixture,
            request: request
        )
        try fixture.revisions.release(
            try #require(result.historyPair).revisionIDs
        )
    }

    @Test
    func quiescenceOracleCoversImportOutcomesAndCleanup() throws {
        for outcome in [
            RasterRevisionOperationOutcome.failed,
            .cancelled,
        ] {
            guard let fixture = try TransactionFixture.make(width: 1, height: 1)
            else { return }
            let request = try transactionEncodedImportRequest(
                fixture,
                bytes: Data([19, 37, 91, 255])
            )
            let oracle = try TransactionQuiescenceOracle.capture(fixture)
            let prepared = try transactionPrepared(
                fixture.coordinator.prepareEncodedImport(request)
            )
            let encoded = try fixture.coordinator.encodeMutation(prepared)
            #expect(throws: DocumentPaintSurfaceTransactionError
                .mutationCommandFailed) {
                _ = try fixture.coordinator.completeMutation(
                    encoded,
                    as: outcome
                )
            }
            try oracle.expectRestored(fixture)
            _ = try transactionCommitEncodedImport(
                fixture,
                request: request
            )
        }

        guard let cleanup = try TransactionFixture.make(width: 1, height: 1)
        else { return }
        let request = try transactionEncodedImportRequest(
            cleanup,
            bytes: Data([19, 37, 91, 255])
        )
        let oracle = try TransactionQuiescenceOracle.capture(cleanup)
        let prepared = try transactionPrepared(
            cleanup.coordinator.prepareEncodedImport(request)
        )
        let encoded = try cleanup.coordinator.encodeMutation(prepared)
        #expect(throws: DocumentPaintSurfaceTransactionError.cleanupFailed) {
            try cleanup.coordinator.discard(
                encoded,
                failureInjection: .init(failingAt: .cleanup)
            )
        }
        #expect(cleanup.coordinator.snapshot().state == .discardPending)
        try cleanup.coordinator.retryDiscard()
        try oracle.expectRestored(cleanup)
        _ = try transactionCommitEncodedImport(cleanup, request: request)
    }

    @Test
    func quiescenceOracleCoversRestoreOutcomesAndCleanup() throws {
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        for outcome in [
            RasterRevisionOperationOutcome.failed,
            .cancelled,
        ] {
            guard let fixture = try TransactionFixture.make(width: 256, height: 256)
            else { return }
            let pair = try transactionCapturedPair(
                fixture,
                coordinate: coordinate,
                publish: true
            )
            let request = fixture.restoreRequest(
                reference: pair.after
            )
            let oracle = try TransactionQuiescenceOracle.capture(fixture)
            let prepared = try fixture.coordinator.prepareRestore(request)
            let encoded = try fixture.coordinator.encodeRestore(prepared)
            #expect(throws: DocumentPaintSurfaceTransactionError
                .restoreCommandFailed) {
                _ = try fixture.coordinator.completeRestore(
                    encoded,
                    as: outcome
                )
            }
            #expect(fixture.coordinator.snapshot().state == .discardPending)
            try fixture.coordinator.retryDiscard()
            try oracle.expectRestored(fixture)
            _ = try transactionCommitRestore(fixture, request: request)
            try fixture.revisions.release(pair.revisionIDs)
        }

        for terminalPhase in [false, true] {
            guard let fixture = try TransactionFixture.make(width: 256, height: 256)
            else { return }
            let pair = try transactionCapturedPair(
                fixture,
                coordinate: coordinate,
                publish: true
            )
            let request = fixture.restoreRequest(
                reference: pair.after
            )
            let oracle = try TransactionQuiescenceOracle.capture(fixture)
            let prepared = try fixture.coordinator.prepareRestore(request)
            let encoded = try fixture.coordinator.encodeRestore(prepared)
            if terminalPhase {
                let completed = try fixture.coordinator.completeRestore(
                    encoded,
                    as: .succeeded
                )
                let terminal = try fixture.coordinator
                    .prepareTerminalRestore(completed)
                #expect(throws: DocumentPaintSurfaceTransactionError
                    .cleanupFailed) {
                    try fixture.coordinator.discard(
                        terminal,
                        failureInjection: .init(failingAt: .cleanup)
                    )
                }
            } else {
                #expect(throws: DocumentPaintSurfaceTransactionError
                    .cleanupFailed) {
                    try fixture.coordinator.discard(
                        encoded,
                        failureInjection: .init(failingAt: .cleanup)
                    )
                }
            }
            #expect(fixture.coordinator.snapshot().state == .discardPending)
            try fixture.coordinator.retryDiscard()
            try oracle.expectRestored(fixture)
            _ = try transactionCommitRestore(fixture, request: request)
            try fixture.revisions.release(pair.revisionIDs)
        }
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
        let sourceConfiguration = RadialSymmetryConfiguration(
            kind: .mirror,
            rayCount: 1,
            center: WorldPoint(x: 1_024, y: 1_024)
        )
        let targetConfiguration = RadialSymmetryConfiguration(
            kind: .mandala,
            rayCount: 3,
            center: WorldPoint(x: 700, y: 700)
        )
        let sourceCompiled = try SymmetryDescriptorCompiler.compile(
            finiteConfiguration: .radial(sourceConfiguration),
            canvasSize: PixelSize(width: 2_048, height: 2_048)
        )
        let targetCompiled = try SymmetryDescriptorCompiler.compile(
            finiteConfiguration: .radial(targetConfiguration),
            canvasSize: PixelSize(width: 1_400, height: 1_400)
        )
        let sourceLayout = try #require(
            sourceCompiled.domain.finite?.radial.layout
        )
        let targetLayout = try #require(
            targetCompiled.domain.finite?.radial.layout
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
                    candidateGeometry: targetGeometry,
                    targetRadialConfiguration: targetConfiguration
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
    func transparentEncodedImportAllocatesNothingButStillReplacesWhenRequired() throws {
        let transparentGarbage = Data([
            255, 91, 37, 0,
            12, 240, 200, 0,
        ])
        guard let empty = try TransactionFixture.make(width: 2, height: 1)
        else { return }
        let emptyBaseline = empty.registry.snapshot()
        let noOp = try empty.coordinator.prepareEncodedImport(
            try transactionValidatedImportRequest(
                layerID: empty.layerID,
                geometry: empty.geometry,
                width: 2,
                height: 1,
                bytesPerRow: 8,
                bytes: transparentGarbage
            )
        )
        guard case let .noOp(receipt) = noOp else {
            Issue.record("Expected an allocation-free transparent import no-op")
            return
        }
        #expect(receipt.kind == .encodedImport)
        #expect(empty.registry.snapshot() == emptyBaseline)
        #expect(empty.backend.encodeCallCount == 0)

        guard let replacement = try TransactionFixture.make(width: 2, height: 1)
        else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try transactionSeedActive(replacement, coordinates: [coordinate])
        let replacementBaseline = replacement.registry.snapshot()
        let revisions = replacement.revisions.snapshot()
        let prepared = try transactionPrepared(
            replacement.coordinator.prepareEncodedImport(
                try transactionValidatedImportRequest(
                    layerID: replacement.layerID,
                    geometry: replacement.geometry,
                    width: 2,
                    height: 1,
                    bytesPerRow: 8,
                    bytes: transparentGarbage
                )
            )
        )
        #expect(replacement.registry.snapshot() == replacementBaseline)
        let encoded = try replacement.coordinator.encodeMutation(prepared)
        let payload = try #require(replacement.backend.encodedImportPayload)
        #expect(payload.destinations.isEmpty)
        #expect(payload.planeBindings.isEmpty)
        #expect(replacement.registry.snapshot().activeTileLeaseCount == 0)
        let reduced = try replacement.coordinator.completeMutation(
            encoded,
            as: .succeeded
        )
        let terminal = try replacement.coordinator.prepareTerminalCommit(reduced)
        let result = try replacement.coordinator.publish(terminal)
        #expect(result.historyPair == nil)
        #expect(replacement.registry.snapshot().generation
            == replacementBaseline.generation + 1)
        #expect(replacement.registry.snapshot().layers[0].references.isEmpty)
        #expect(replacement.registry.snapshot().residentTileBytes == 0)
        #expect(replacement.revisions.snapshot() == revisions)

        guard let geometryChange = try TransactionFixture.make(width: 2, height: 1)
        else { return }
        let target = try transactionGeometry(width: 1, height: 1)
        let changed = try transactionPrepared(
            geometryChange.coordinator.prepareEncodedImport(
                try transactionValidatedImportRequest(
                    layerID: geometryChange.layerID,
                    geometry: target,
                    width: 1,
                    height: 1,
                    bytesPerRow: 4,
                    bytes: Data([255, 99, 17, 0])
                )
            )
        )
        let changedEncoded = try geometryChange.coordinator.encodeMutation(changed)
        let changedReduced = try geometryChange.coordinator.completeMutation(
            changedEncoded,
            as: .succeeded
        )
        let changedTerminal = try geometryChange.coordinator
            .prepareTerminalCommit(changedReduced)
        _ = try geometryChange.coordinator.publish(changedTerminal)
        #expect(geometryChange.registry.snapshot().geometry == target)
        #expect(geometryChange.registry.snapshot().layers[0].references.isEmpty)
        #expect(geometryChange.registry.snapshot().residentTileBytes == 0)
    }

    @Test
    func encodedImport257x259UsesExactPaddedTilewiseColorBoundary() throws {
        let width = 257
        let height = 259
        let bytesPerRow = width * 4 + 8
        var bytes = Data(repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for offset in (width * 4)..<bytesPerRow {
                bytes[y * bytesPerRow + offset] = 255
            }
        }
        func setPixel(
            x: Int,
            y: Int,
            blue: UInt8,
            green: UInt8,
            red: UInt8,
            alpha: UInt8
        ) {
            let offset = y * bytesPerRow + x * 4
            bytes[offset] = blue
            bytes[offset + 1] = green
            bytes[offset + 2] = red
            bytes[offset + 3] = alpha
        }
        setPixel(x: 0, y: 0, blue: 255, green: 91, red: 37, alpha: 0)
        setPixel(x: 1, y: 0, blue: 32, green: 16, red: 64, alpha: 128)
        setPixel(x: 255, y: 0, blue: 3, green: 2, red: 1, alpha: 255)
        setPixel(x: 256, y: 0, blue: 200, green: 1, red: 255, alpha: 128)
        setPixel(x: 0, y: 256, blue: 17, green: 61, red: 93, alpha: 128)
        setPixel(x: 256, y: 258, blue: 7, green: 11, red: 19, alpha: 255)

        guard let fixture = try TransactionFixture.make(
            width: width,
            height: height
        ) else { return }
        let old = PaintTileCoordinate(x: 0, y: 0)
        let coordinates = [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
            PaintTileCoordinate(x: 0, y: 1),
            PaintTileCoordinate(x: 1, y: 1),
        ]
        try transactionSeedActive(fixture, coordinates: [old])
        let baseline = fixture.registry.snapshot()
        let revisionBaseline = fixture.revisions.snapshot()
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareEncodedImport(
                try transactionValidatedImportRequest(
                    layerID: fixture.layerID,
                    geometry: fixture.geometry,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow,
                    bytes: bytes
                )
            )
        )
        let preparedSnapshot = fixture.registry.snapshot()
        #expect(preparedSnapshot.generation == baseline.generation)
        #expect(preparedSnapshot.geometry == baseline.geometry)
        #expect(preparedSnapshot.layers == baseline.layers)
        #expect(preparedSnapshot.residentTileBytes
            == baseline.residentTileBytes
                + coordinates.count * PaintTileDescriptor.residentByteCount)
        let encoded = try fixture.coordinator.encodeMutation(prepared)
        let payload = try #require(fixture.backend.encodedImportPayload)
        #expect(payload.destinations.map(\.coordinate) == coordinates)
        #expect(payload.planeBindings.map(\.width) == [256, 1, 256, 1])
        #expect(payload.planeBindings.map(\.height) == [256, 256, 3, 3])
        #expect(payload.planeBindings.map(\.bytesPerRow) == [1024, 4, 1024, 4])
        let encodedSnapshot = fixture.registry.snapshot()
        #expect(encodedSnapshot.generation == baseline.generation)
        #expect(encodedSnapshot.layers == baseline.layers)
        #expect(encodedSnapshot.activeTileLeaseCount == 1)

        let transparent = transactionImportPayloadColor(payload, x: 0, y: 0)
        #expect(transparent == .zero)
        let translucent = transactionImportPayloadColor(payload, x: 1, y: 0)
        let translucentOracle = DocumentColorPipeline
            .importEncodedPremultipliedBGRA8(.init(
                blue: 32,
                green: 16,
                red: 64,
                alpha: 128
            )).simd
        #expect(translucent == translucentOracle)
        #expect(translucent != transactionWrongStraightAlphaImport(
            blue: 32,
            green: 16,
            red: 64,
            alpha: 128
        ))
        #expect(translucent != transactionWrongEncodedPremultipliedImport(
            blue: 32,
            green: 16,
            red: 64,
            alpha: 128
        ))
        #expect(translucent != transactionWrongDoubleDecodedImport(translucent))
        #expect(transactionImportPayloadColor(payload, x: 255, y: 0)
            == DocumentColorPipeline.importEncodedPremultipliedBGRA8(.init(
                blue: 3,
                green: 2,
                red: 1,
                alpha: 255
            )).simd)
        let tolerant = transactionImportPayloadColor(payload, x: 256, y: 0)
        #expect(abs(tolerant.x - tolerant.w) < 1e-7)
        #expect(abs(tolerant.z - tolerant.w) < 1e-7)

        let reduced = try fixture.coordinator.completeMutation(
            encoded,
            as: .succeeded
        )
        #expect(throws: DocumentPaintSurfaceTransactionError.historyNotRequired) {
            _ = try fixture.coordinator.encodeHistoryCapture(reduced)
        }
        let terminal = try fixture.coordinator.prepareTerminalCommit(reduced)
        let result = try fixture.coordinator.publish(terminal)
        #expect(result.historyPair == nil)
        #expect(result.dirtyCoordinates == coordinates)
        #expect(fixture.registry.snapshot().generation == baseline.generation + 1)
        #expect(fixture.registry.snapshot().layers[0].references.map(\.coordinate)
            == coordinates)
        #expect(fixture.revisions.snapshot() == revisionBaseline)
        #expect(fixture.registry.snapshot().activeTileLeaseCount == 0)
    }

    @Test
    func encodedImportReductionPrunesAConvertedAlphaZeroTile() throws {
        guard let fixture = try TransactionFixture.make(width: 1, height: 1)
        else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        fixture.backend.alphaByCoordinate[coordinate] = 0
        let request = try transactionEncodedImportRequest(
            fixture,
            bytes: Data([19, 37, 91, 255])
        )
        let prepared = try transactionPrepared(
            fixture.coordinator.prepareEncodedImport(request)
        )
        let encoded = try fixture.coordinator.encodeMutation(prepared)
        #expect(fixture.backend.encodedImportPayload?.destinations.count == 1)
        let reduced = try fixture.coordinator.completeMutation(
            encoded,
            as: .succeeded
        )
        #expect(fixture.coordinator.snapshot().candidateCoordinates.isEmpty)
        #expect(fixture.registry.snapshot().residentTileBytes == 0)
        let terminal = try fixture.coordinator.prepareTerminalCommit(reduced)
        let result = try fixture.coordinator.publish(terminal)
        #expect(result.historyPair == nil)
        #expect(result.dirtyCoordinates == [coordinate])
        #expect(fixture.registry.snapshot().layers[0].references.isEmpty)
        #expect(fixture.registry.snapshot().residentTileBytes == 0)
    }

    @Test
    func encodedImportFailuresRestoreExactBaselineAndAllowImmediateReuse() throws {
        guard let reserve = try TransactionFixture.make(width: 1, height: 1)
        else { return }
        let reserveRequest = try transactionEncodedImportRequest(
            reserve,
            bytes: Data([19, 37, 91, 255])
        )
        let reserveRegistry = reserve.registry.snapshot()
        let reserveRevisions = reserve.revisions.snapshot()
        #expect(throws: PaintTileStoreError
            .injectedAllocationFailure(reserveIndex: 0)) {
            _ = try reserve.coordinator.prepareEncodedImport(
                reserveRequest,
                failureInjection: .init(failingAt: .candidateReserve(0))
            )
        }
        try transactionRequireEncodedImportQuiescentAndReusable(
            reserve,
            request: reserveRequest,
            registryBaseline: reserveRegistry,
            revisionBaseline: reserveRevisions
        )

        guard let encode = try TransactionFixture.make(width: 1, height: 1)
        else { return }
        let encodeRequest = try transactionEncodedImportRequest(
            encode,
            bytes: Data([19, 37, 91, 255])
        )
        let encodeRegistry = encode.registry.snapshot()
        let encodeRevisions = encode.revisions.snapshot()
        let encodePrepared = try transactionPrepared(
            encode.coordinator.prepareEncodedImport(encodeRequest)
        )
        #expect(throws: DocumentPaintSurfaceTransactionError
            .backendEncodingFailed) {
            _ = try encode.coordinator.encodeMutation(
                encodePrepared,
                failureInjection: .init(failingAt: .mutationEncode)
            )
        }
        #expect(encode.coordinator.snapshot().phase == .prepared)
        try encode.coordinator.discard(encodePrepared)
        try transactionRequireEncodedImportQuiescentAndReusable(
            encode,
            request: encodeRequest,
            registryBaseline: encodeRegistry,
            revisionBaseline: encodeRevisions
        )

        for (point, expected) in [
            (
                DocumentPaintSurfaceTransactionFailurePoint.mutationCompletion,
                DocumentPaintSurfaceTransactionError.backendCompletionFailed
            ),
            (.reductionValidation, .reductionValidationFailed),
            (.destinationLeaseReturn, .destinationLeaseReturnFailed),
            (.candidatePrune, .candidatePruneFailed),
        ] {
            guard let fixture = try TransactionFixture.make(width: 1, height: 1)
            else { return }
            let request = try transactionEncodedImportRequest(
                fixture,
                bytes: Data([19, 37, 91, 255])
            )
            let registry = fixture.registry.snapshot()
            let revisions = fixture.revisions.snapshot()
            let prepared = try transactionPrepared(
                fixture.coordinator.prepareEncodedImport(request)
            )
            let encoded = try fixture.coordinator.encodeMutation(prepared)
            #expect(throws: expected) {
                _ = try fixture.coordinator.completeMutation(
                    encoded,
                    as: .succeeded,
                    failureInjection: .init(failingAt: point)
                )
            }
            if fixture.coordinator.snapshot().state == .discardPending {
                try fixture.coordinator.retryDiscard()
            }
            try transactionRequireEncodedImportQuiescentAndReusable(
                fixture,
                request: request,
                registryBaseline: registry,
                revisionBaseline: revisions
            )
        }

        for (point, expected) in [
            (
                DocumentPaintSurfaceTransactionFailurePoint.terminalPreflight,
                DocumentPaintSurfaceTransactionError.terminalPreflightFailed
            ),
            (.registryPrepare, .registryPreparationFailed),
        ] {
            guard let fixture = try TransactionFixture.make(width: 1, height: 1)
            else { return }
            let request = try transactionEncodedImportRequest(
                fixture,
                bytes: Data([19, 37, 91, 255])
            )
            let registry = fixture.registry.snapshot()
            let revisions = fixture.revisions.snapshot()
            let prepared = try transactionPrepared(
                fixture.coordinator.prepareEncodedImport(request)
            )
            let encoded = try fixture.coordinator.encodeMutation(prepared)
            let reduced = try fixture.coordinator.completeMutation(
                encoded,
                as: .succeeded
            )
            #expect(throws: expected) {
                _ = try fixture.coordinator.prepareTerminalCommit(
                    reduced,
                    failureInjection: .init(failingAt: point)
                )
            }
            try fixture.coordinator.discard(reduced)
            try transactionRequireEncodedImportQuiescentAndReusable(
                fixture,
                request: request,
                registryBaseline: registry,
                revisionBaseline: revisions
            )
        }

        guard let publish = try TransactionFixture.make(width: 1, height: 1)
        else { return }
        let publishRequest = try transactionEncodedImportRequest(
            publish,
            bytes: Data([19, 37, 91, 255])
        )
        let publishRegistry = publish.registry.snapshot()
        let publishRevisions = publish.revisions.snapshot()
        let publishPrepared = try transactionPrepared(
            publish.coordinator.prepareEncodedImport(publishRequest)
        )
        let publishEncoded = try publish.coordinator.encodeMutation(
            publishPrepared
        )
        let publishReduced = try publish.coordinator.completeMutation(
            publishEncoded,
            as: .succeeded
        )
        let terminal = try publish.coordinator.prepareTerminalCommit(
            publishReduced
        )
        #expect(throws: DocumentPaintSurfaceTransactionError
            .revisionPublishFailed) {
            _ = try publish.coordinator.publish(
                terminal,
                failureInjection: .init(failingAt: .revisionPublish)
            )
        }
        try publish.coordinator.discard(terminal)
        try transactionRequireEncodedImportQuiescentAndReusable(
            publish,
            request: publishRequest,
            registryBaseline: publishRegistry,
            revisionBaseline: publishRevisions
        )
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
            mutationBackend: winningBackend,
            allowKnownClearAuthoritativeStrokeSourcesForTesting: true
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
                reference: pair.before
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
                reference: pair.after
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
                    reference: pair.after
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
    func restoreRejectsProvisionalForgedForeignAndMismatchedGeometry() throws {
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
                    reference: provisional.after
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
                    reference: forged
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
                    reference: foreign.after
                )
            )
        }

        let wrongGeometry = try transactionGeometry(width: 512, height: 256)
        #expect(throws: DocumentPaintSurfaceTransactionError
            .restoreGeometryMismatch) {
            _ = try fixture.coordinator.prepareRestore(
                fixture.restoreRequest(
                    reference: published.after,
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
                    targetGeometry: wrongVisibleGeometry
                )
            )
        }
        #expect(fixture.coordinator.snapshot().state == .idle)
        try fixture.revisions.release(published.revisionIDs)
        #expect(throws: DocumentPaintSurfaceTransactionError
            .restoreReferenceUnavailable) {
            _ = try fixture.coordinator.prepareRestore(
                fixture.restoreRequest(
                    reference: published.after
                )
            )
        }
        #expect(fixture.coordinator.snapshot().state == .idle)
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
                    reference: pair.after
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
                    reference: pair.after
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
                reference: pair.before
            )
        )
        let encoded = try fixture.coordinator.encodeRestore(prepared)
        let completed = try fixture.coordinator.completeRestore(
            encoded,
            as: .succeeded
        )
        let terminal = try fixture.coordinator.prepareTerminalRestore(completed)
        let before = fixture.registry.snapshot()
        let retryableOracle = try TransactionQuiescenceOracle.capture(
            fixture,
            history: history
        )

        #expect(throws: DocumentPaintSurfaceTransactionError
            .restoreConsumeFailed) {
            _ = try fixture.coordinator.publishRestore(
                terminal,
                failureInjection: .init(failingAt: .restoreConsume)
            )
        }
        #expect(fixture.registry.snapshot() == before)
        #expect(fixture.coordinator.snapshot().phase == .restoreTerminalPrepared)
        try retryableOracle.expectRestored(fixture, history: history)
        #expect(history.canUndo)
        #expect(!history.canRedo)

        _ = try fixture.coordinator.publishRestore(terminal)
        #expect(Optional(history.diagnosticSnapshotForTesting())
            == retryableOracle.history)
        try history.finishNavigation(token: undo.token, succeeded: true)
        #expect(history.commandCount == 1)
        #expect(history.retainedRasterBytes
            == pair.before.retainedBytes + pair.after.retainedBytes)
        #expect(!history.canUndo)
        #expect(history.canRedo)
        #expect(history.currentDocumentIsEmpty)
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
                    reference: reservePair.after
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
                    reference: pair.after
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
                    reference: pair.after
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
                reference: terminalPair.after
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
                reference: terminalPair.after
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
                reference: pair.after
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

}

private final class TransactionTestMutationBackend:
    DocumentPaintSurfaceMutationBackend, @unchecked Sendable
{
    private(set) var encodeCallCount = 0
    private(set) var discardCallCount = 0
    private(set) var activeEncodingIDs: Set<UUID> = []
    var liveResourceCount: Int { activeEncodingIDs.count }
    var alphaByCoordinate: [PaintTileCoordinate: Float] = [:]
    var evidenceOverride: [DocumentPaintSurfaceMutationEvidence]?
    var discardShouldFail = false
    var onDiscardAndWaitUntilTerminal: (() -> Void)?
    private(set) var destinations: [DocumentPaintSurfaceMutationDestination] = []
    private(set) var strokePayload: DocumentPaintSurfaceStrokeBackendPayload?
    private(set) var clearOperationCount = 0
    private(set) var resizePayload: DocumentPaintSurfaceResizeBackendPayload?
    private(set) var encodedImportPayload:
        DocumentPaintSurfaceEncodedImportBackendPayload?

    func encode(
        _ operation: DocumentPaintSurfaceBackendOperation
    ) throws -> DocumentPaintSurfaceMutationBackendEncoding {
        encodeCallCount += 1
        switch operation {
        case let .stroke(payload):
            strokePayload = payload
            destinations = payload.destinations
        case .clear:
            clearOperationCount += 1
            destinations = []
        case let .resize(payload):
            resizePayload = payload
            destinations = payload.destinations
        case let .encodedImport(payload):
            encodedImportPayload = payload
            destinations = payload.destinations
        }
        let encoding = DocumentPaintSurfaceMutationBackendEncoding()
        activeEncodingIDs.insert(encoding.rawValue)
        return encoding
    }

    func complete(
        _ encoding: DocumentPaintSurfaceMutationBackendEncoding,
        as outcome: RasterRevisionOperationOutcome
    ) throws -> [DocumentPaintSurfaceMutationEvidence] {
        _ = encoding
        _ = outcome
        let evidence = evidenceOverride ?? destinations.map {
            DocumentPaintSurfaceMutationEvidence(
                coordinate: $0.coordinate,
                logicalBounds: $0.logicalBounds,
                maximumAlpha: alphaByCoordinate[$0.coordinate] ?? 1
            )
        }
        activeEncodingIDs.remove(encoding.rawValue)
        return evidence
    }

    func discardAndWaitUntilTerminal(
        _ encoding: DocumentPaintSurfaceMutationBackendEncoding
    ) throws {
        _ = encoding
        discardCallCount += 1
        onDiscardAndWaitUntilTerminal?()
        if discardShouldFail { throw TransactionTestError.backendFailure }
        activeEncodingIDs.remove(encoding.rawValue)
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
        geometry requestedGeometry: DocumentPaintGeometry? = nil,
        allowsTestStrokeSources: Bool = true
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
            mutationBackend: backend,
            allowKnownClearAuthoritativeStrokeSourcesForTesting:
                allowsTestStrokeSources
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
        targetRadialConfiguration: RadialSymmetryConfiguration? = nil,
        requiresHistoryPair: Bool = true
    ) -> DocumentPaintSurfaceMutationRequest {
        DocumentPaintSurfaceMutationRequest(
            kind: kind,
            layerID: layerID,
            baseGeometry: baseGeometry ?? geometry,
            candidateGeometry: candidateGeometry ?? geometry,
            targetRadialConfiguration: targetRadialConfiguration,
            dirtyCoordinates: dirty,
            explicitlyRemovedCoordinates: removing,
            requiresHistoryPair: requiresHistoryPair
        )
    }

    func restoreRequest(
        reference: RasterRevisionReference,
        targetGeometry: DocumentPaintGeometry? = nil
    ) -> DocumentPaintSurfaceRestoreRequest {
        DocumentPaintSurfaceRestoreRequest(
            reference: reference,
            targetGeometry: targetGeometry ?? geometry
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

private func transactionImportPayloadColor(
    _ payload: DocumentPaintSurfaceEncodedImportBackendPayload,
    x: Int,
    y: Int
) -> SIMD4<Float> {
    let coordinate = PaintTileCoordinate(
        x: x / PaintTileDescriptor.side,
        y: y / PaintTileDescriptor.side
    )
    guard let binding = payload.planeBindings.first(where: {
        $0.coordinate == coordinate
    }) else { return .zero }
    let localX = x % PaintTileDescriptor.side
    let localY = y % PaintTileDescriptor.side
    let offset = localY * binding.bytesPerRow + localX * 4
    let pixel = EncodedPremultipliedBGRA8(
        blue: binding.bytes[offset],
        green: binding.bytes[offset + 1],
        red: binding.bytes[offset + 2],
        alpha: binding.bytes[offset + 3]
    )
    return DocumentColorPipeline.importEncodedPremultipliedBGRA8(pixel).simd
}

private func transactionWrongStraightAlphaImport(
    blue: UInt8,
    green: UInt8,
    red: UInt8,
    alpha: UInt8
) -> SIMD4<Float> {
    EncodedSRGBColor(
        red: Float(red) / 255,
        green: Float(green) / 255,
        blue: Float(blue) / 255,
        alpha: Float(alpha) / 255
    )!.linearPremultiplied().simd
}

private func transactionWrongEncodedPremultipliedImport(
    blue: UInt8,
    green: UInt8,
    red: UInt8,
    alpha: UInt8
) -> SIMD4<Float> {
    SIMD4(
        Float(red) / 255,
        Float(green) / 255,
        Float(blue) / 255,
        Float(alpha) / 255
    )
}

private func transactionWrongDoubleDecodedImport(
    _ correct: SIMD4<Float>
) -> SIMD4<Float> {
    guard correct.w > 0 else { return .zero }
    return EncodedSRGBColor(
        red: min(1, correct.x / correct.w),
        green: min(1, correct.y / correct.w),
        blue: min(1, correct.z / correct.w),
        alpha: correct.w
    )!.linearPremultiplied().simd
}

private func transactionEncodedImportRequest(
    _ fixture: TransactionFixture,
    bytes: Data
) throws -> DocumentPaintSurfaceEncodedImportRequest {
    let size = fixture.geometry.storagePixelSize
    return try DocumentPaintSurfaceEncodedImportRequest.validate(
        layerID: fixture.layerID,
        candidateGeometry: fixture.geometry,
        input: .singleRaster(.init(
            width: size.width,
            height: size.height,
            bytesPerRow: size.width * 4,
            bytes: bytes
        )),
        maximumUploadBytes: size.width * size.height * 4
    )
}

private func transactionValidatedImportRequest(
    layerID: UUID,
    geometry: DocumentPaintGeometry,
    width: Int,
    height: Int,
    bytesPerRow: Int,
    bytes: Data
) throws -> DocumentPaintSurfaceEncodedImportRequest {
    try DocumentPaintSurfaceEncodedImportRequest.validate(
        layerID: layerID,
        candidateGeometry: geometry,
        input: .singleRaster(.init(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytes: bytes
        )),
        maximumUploadBytes: width * height * 4
    )
}

private func transactionRequireEncodedImportQuiescentAndReusable(
    _ fixture: TransactionFixture,
    request: DocumentPaintSurfaceEncodedImportRequest,
    registryBaseline: DocumentPaintSurfaceStoreSnapshot,
    revisionBaseline: TiledRasterRevisionStoreSnapshot
) throws {
    #expect(fixture.coordinator.snapshot().state == .idle)
    #expect(fixture.registry.snapshot() == registryBaseline)
    #expect(fixture.revisions.snapshot() == revisionBaseline)

    let prepared = try transactionPrepared(
        fixture.coordinator.prepareEncodedImport(request)
    )
    let encoded = try fixture.coordinator.encodeMutation(prepared)
    let reduced = try fixture.coordinator.completeMutation(
        encoded,
        as: .succeeded
    )
    let terminal = try fixture.coordinator.prepareTerminalCommit(reduced)
    let result = try fixture.coordinator.publish(terminal)
    #expect(result.historyPair == nil)
    #expect(fixture.coordinator.snapshot().state == .idle)
    #expect(fixture.registry.snapshot().generation
        == registryBaseline.generation + 1)
    #expect(fixture.registry.snapshot().activeTileLeaseCount == 0)
    #expect(fixture.revisions.snapshot() == revisionBaseline)
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

@discardableResult
private func transactionCommitNoHistory(
    _ fixture: TransactionFixture,
    request: DocumentPaintSurfaceMutationRequest
) throws -> DocumentPaintSurfaceCommitResult {
    let prepared = try transactionPrepared(
        fixture.coordinator.prepareMutation(request)
    )
    let encoded = try fixture.coordinator.encodeMutation(prepared)
    let reduced = try fixture.coordinator.completeMutation(
        encoded,
        as: .succeeded
    )
    let terminal = try fixture.coordinator.prepareTerminalCommit(reduced)
    let result = try fixture.coordinator.publish(terminal)
    #expect(fixture.coordinator.snapshot().state == .idle)
    #expect(fixture.coordinator.ownershipSnapshotForTesting() == .empty)
    #expect(fixture.backend.activeEncodingIDs.isEmpty)
    return result
}

@discardableResult
private func transactionCommitWithHistory(
    _ fixture: TransactionFixture,
    request: DocumentPaintSurfaceMutationRequest
) throws -> DocumentPaintSurfaceCommitResult {
    let prepared = try transactionPrepared(
        fixture.coordinator.prepareMutation(request)
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
    #expect(fixture.coordinator.snapshot().state == .idle)
    #expect(fixture.coordinator.ownershipSnapshotForTesting() == .empty)
    #expect(fixture.backend.activeEncodingIDs.isEmpty)
    return result
}

@discardableResult
private func transactionCommitEncodedImport(
    _ fixture: TransactionFixture,
    request: DocumentPaintSurfaceEncodedImportRequest
) throws -> DocumentPaintSurfaceCommitResult {
    let prepared = try transactionPrepared(
        fixture.coordinator.prepareEncodedImport(request)
    )
    let encoded = try fixture.coordinator.encodeMutation(prepared)
    let reduced = try fixture.coordinator.completeMutation(
        encoded,
        as: .succeeded
    )
    let terminal = try fixture.coordinator.prepareTerminalCommit(reduced)
    let result = try fixture.coordinator.publish(terminal)
    #expect(fixture.coordinator.snapshot().state == .idle)
    #expect(fixture.coordinator.ownershipSnapshotForTesting() == .empty)
    #expect(fixture.backend.activeEncodingIDs.isEmpty)
    return result
}

@discardableResult
private func transactionCommitRestore(
    _ fixture: TransactionFixture,
    request: DocumentPaintSurfaceRestoreRequest
) throws -> DocumentPaintSurfaceRestoreResult {
    let prepared = try fixture.coordinator.prepareRestore(request)
    let encoded = try fixture.coordinator.encodeRestore(prepared)
    let completed = try fixture.coordinator.completeRestore(
        encoded,
        as: .succeeded
    )
    let terminal = try fixture.coordinator.prepareTerminalRestore(completed)
    let result = try fixture.coordinator.publishRestore(terminal)
    #expect(fixture.coordinator.snapshot().state == .idle)
    #expect(fixture.coordinator.ownershipSnapshotForTesting() == .empty)
    #expect(fixture.backend.activeEncodingIDs.isEmpty)
    return result
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

private func transactionOverwriteActiveCanonicalBytes(
    _ fixture: TransactionFixture,
    coordinate: PaintTileCoordinate,
    byte: UInt8
) throws {
    let binding = try fixture.registry.binding(for: fixture.layerID)
    let lease = try binding.canonical.leaseExistingTiles(
        at: [coordinate],
        pinReasons: [.inFlight]
    )
    defer { try? binding.canonical.returnLease(lease) }
    let texture = try #require(lease.bindings.first?.texture)
    let bytesPerRow = texture.width * MemoryLayout<UInt16>.size * 4
    let bytesPerImage = bytesPerRow * texture.height
    let staging = try #require(fixture.device.makeBuffer(
        length: bytesPerImage,
        options: .storageModeShared
    ))
    staging.contents().initializeMemory(
        as: UInt8.self,
        repeating: byte,
        count: bytesPerImage
    )
    let queue = try #require(fixture.device.makeCommandQueue())
    let command = try #require(queue.makeCommandBuffer())
    let blit = try #require(command.makeBlitCommandEncoder())
    blit.copy(
        from: staging,
        sourceOffset: 0,
        sourceBytesPerRow: bytesPerRow,
        sourceBytesPerImage: bytesPerImage,
        sourceSize: MTLSize(
            width: texture.width,
            height: texture.height,
            depth: 1
        ),
        to: texture,
        destinationSlice: 0,
        destinationLevel: 0,
        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
    )
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    try fixture.registry.sharedTileStore.markModified(
        lease,
        surfaceID: lease.surfaceID,
        currentGeneration: lease.generation,
        coordinates: [coordinate]
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

private struct TransactionTileStoreQuiescenceSnapshot: Equatable {
    let residentByteCount: Int
    let backingByteCount: Int
    let activeLeaseCount: Int
    let provisionalReservationCount: Int
    let provisionalByteCount: Int
    let preparedRetirementCount: Int
    let pendingRetirementCount: Int
    let entries: [TransactionTileEntryQuiescenceSnapshot]
    let leastRecentlyUsedOrder: [PaintTileIdentity]

    init(_ snapshot: PaintTileStoreSnapshot) {
        residentByteCount = snapshot.residentByteCount
        backingByteCount = snapshot.backingByteCount
        activeLeaseCount = snapshot.activeLeaseCount
        provisionalReservationCount = snapshot.provisionalReservationCount
        provisionalByteCount = snapshot.provisionalByteCount
        preparedRetirementCount = snapshot.preparedRetirementCount
        pendingRetirementCount = snapshot.pendingRetirementCount
        entries = snapshot.entries.map(TransactionTileEntryQuiescenceSnapshot.init)
        leastRecentlyUsedOrder = snapshot.leastRecentlyUsedOrder
    }
}

private struct TransactionTileEntryQuiescenceSnapshot: Equatable {
    let surfaceID: UUID
    let generation: UInt64
    let identity: PaintTileIdentity
    let descriptor: PaintTileDescriptor
    let isResident: Bool
    let backing: PaintTileBackingSnapshot
    let pinCounts: [PaintTilePinReason: Int]

    init(_ snapshot: PaintTileStoreEntrySnapshot) {
        surfaceID = snapshot.surfaceID
        generation = snapshot.generation
        identity = snapshot.identity
        descriptor = snapshot.descriptor
        isResident = snapshot.isResident
        backing = snapshot.backing
        pinCounts = snapshot.pinCounts
    }
}

private struct TransactionQuiescenceOracle {
    let registry: DocumentPaintSurfaceStoreSnapshot
    let activeLayerPayloads: [TransactionActiveLayerPayloadSnapshot]
    let tileStore: TransactionTileStoreQuiescenceSnapshot
    let revisions: TiledRasterRevisionStoreSnapshot
    let revisionPayloads: [TiledRasterRevisionHarnessSnapshot]
    let transaction: DocumentPaintSurfaceTransactionSnapshot
    let transactionOwnership:
        DocumentPaintSurfaceTransactionOwnershipSnapshot
    let backendActiveEncodingIDs: Set<UUID>
    let history: DocumentHistoryDiagnosticSnapshot?

    static func capture(
        _ fixture: TransactionFixture,
        history: DocumentHistory? = nil
    ) throws -> Self {
        Self(
            registry: fixture.registry.snapshot(),
            activeLayerPayloads: try captureActiveLayerPayloads(fixture),
            tileStore: .init(fixture.registry.sharedTileStore.snapshot()),
            revisions: fixture.revisions.snapshot(),
            revisionPayloads: try fixture.revisions.snapshotsForHarness(),
            transaction: fixture.coordinator.snapshot(),
            transactionOwnership:
                fixture.coordinator.ownershipSnapshotForTesting(),
            backendActiveEncodingIDs: fixture.backend.activeEncodingIDs,
            history: history?.diagnosticSnapshotForTesting()
        )
    }

    func matchesActiveLayerPayloads(
        _ fixture: TransactionFixture
    ) throws -> Bool {
        let actual = try Self.captureActiveLayerPayloads(fixture)
        return actual == activeLayerPayloads
    }

    func expectRestored(
        _ fixture: TransactionFixture,
        history actualHistory: DocumentHistory? = nil
    ) throws {
        let actualRegistry = fixture.registry.snapshot()
        #expect(actualRegistry == registry)
        #expect(try matchesActiveLayerPayloads(fixture))
        #expect(TransactionTileStoreQuiescenceSnapshot(
            fixture.registry.sharedTileStore.snapshot()
        ) == tileStore)
        #expect(actualRegistry.activeTileLeaseCount
            == registry.activeTileLeaseCount)
        #expect(actualRegistry.preparedCandidateCount
            == registry.preparedCandidateCount)
        #expect(fixture.revisions.snapshot() == revisions)
        #expect(try fixture.revisions.snapshotsForHarness()
            == revisionPayloads)
        #expect(fixture.coordinator.snapshot() == transaction)
        #expect(fixture.coordinator.ownershipSnapshotForTesting()
            == transactionOwnership)
        #expect(fixture.backend.activeEncodingIDs
            == backendActiveEncodingIDs)
        if let history {
            #expect(actualHistory?.diagnosticSnapshotForTesting() == history)
        } else {
            #expect(actualHistory == nil)
        }
    }

    private static func captureActiveLayerPayloads(
        _ fixture: TransactionFixture
    ) throws -> [TransactionActiveLayerPayloadSnapshot] {
        try fixture.registry.layerIDs.map { layerID in
            let binding = try fixture.registry.binding(for: layerID)
            let references = binding.canonical.references
            let activeIdentities = Set(references.map(\.identity))
            let namespaces = Set(references.map {
                TransactionActivePhysicalNamespace(
                    surfaceID: $0.physicalSurfaceID,
                    generation: $0.physicalGeneration
                )
            }).sorted()
            var payloadByIdentity: [
                PaintTileIdentity: TransactionActiveTilePayloadSnapshot
            ] = [:]
            for namespace in namespaces {
                let payload = try fixture.registry.sharedTileStore.payloadSnapshot(
                    surfaceID: namespace.surfaceID,
                    layerID: layerID,
                    generation: namespace.generation
                )
                for entry in payload.entries
                where activeIdentities.contains(entry.identity) {
                    payloadByIdentity[entry.identity] = .init(
                        physicalSurfaceID: namespace.surfaceID,
                        physicalGeneration: namespace.generation,
                        entry: entry
                    )
                }
            }
            let tiles = try references.map { reference in
                let tile = try #require(payloadByIdentity[reference.identity])
                #expect(tile.entry.descriptor == reference.descriptor)
                #expect(tile.physicalSurfaceID == reference.physicalSurfaceID)
                #expect(tile.physicalGeneration == reference.physicalGeneration)
                return tile
            }
            return TransactionActiveLayerPayloadSnapshot(
                logicalSurfaceID: binding.canonical.surfaceID,
                layerID: layerID,
                generation: binding.generation,
                tiles: tiles
            )
        }
    }
}

private struct TransactionActiveLayerPayloadSnapshot: Equatable {
    let logicalSurfaceID: UUID
    let layerID: UUID
    let generation: UInt64
    let tiles: [TransactionActiveTilePayloadSnapshot]
}

private struct TransactionActivePhysicalNamespace:
    Hashable, Comparable
{
    let surfaceID: UUID
    let generation: UInt64

    static func < (
        lhs: TransactionActivePhysicalNamespace,
        rhs: TransactionActivePhysicalNamespace
    ) -> Bool {
        if lhs.surfaceID.uuidString != rhs.surfaceID.uuidString {
            return lhs.surfaceID.uuidString < rhs.surfaceID.uuidString
        }
        return lhs.generation < rhs.generation
    }
}

private struct TransactionActiveTilePayloadSnapshot: Equatable {
    let physicalSurfaceID: UUID
    let physicalGeneration: UInt64
    let entry: PaintTilePayloadEntry
}

private enum TransactionTestError: Error {
    case expectedPrepared
    case backendFailure
}
