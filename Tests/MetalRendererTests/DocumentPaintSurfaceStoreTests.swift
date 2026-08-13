import EditorCore
import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Document paint surface registry", .serialized)
struct DocumentPaintSurfaceStoreTests {
    private let tileBytes = PaintTileDescriptor.residentByteCount

    @Test
    func defaultTransferCapacityIncludesExactlyOnePersistentZeroTile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 256, height: 256),
            storagePixelSize: PixelSize(width: 256, height: 256),
            radialLayout: nil
        )
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: tileBytes * 2,
            geometry: geometry,
            layerIDs: [UUID()]
        )

        #expect(registry.sharedTileStore.transferByteCapacity == tileBytes * 9)
    }

    @Test
    func explicitSnapshotLiabilityBudgetReachesSoleSharedTileStore() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 768, height: 256),
            storagePixelSize: PixelSize(width: 768, height: 256),
            radialLayout: nil
        )
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: tileBytes,
            snapshotPayloadLiabilityByteBudget: tileBytes * 3,
            // The third seed overlaps one resident texture, one existing
            // backing, one candidate texture, the persistent zero source,
            // and both the readback buffer and its captured Data payload.
            transferByteCapacity: tileBytes * 6,
            geometry: geometry,
            layerIDs: [layer]
        )
        let physicalSurface = UUID()
        for index in 0..<3 {
            _ = try seed(
                store: registry.sharedTileStore,
                surfaceID: physicalSurface,
                layerID: layer,
                generation: 1,
                size: geometry.storagePixelSize,
                coordinate: .init(x: index, y: 0)
            )
        }
        let references = try registry.sharedTileStore.references(
            surfaceID: physicalSurface,
            layerID: layer,
            generation: 1
        )
        #expect(references.count == 3)
        let physical = registry.sharedTileStore.snapshot()
        #expect(physical.residentByteCount == tileBytes)
        #expect(physical.backingByteCount == tileBytes * 2)
        #expect(physical.persistentZeroAllocationBytes == tileBytes)
        #expect(physical.lastTransferAccounting?.residentTextureBytesBefore
            == tileBytes)
        #expect(physical.lastTransferAccounting?.allocatedTextureBytes
            == tileBytes)
        #expect(physical.lastTransferAccounting?.readbackStagingBytes
            == tileBytes)
        #expect(physical.lastTransferAccounting?.capturedPayloadBytes
            == tileBytes)
        #expect(physical.lastTransferAccounting?.peakTrackedBytes
            == tileBytes * 6)
        #expect(physical.lastTransferAccounting?.capacityBytes
            == tileBytes * 6)
        #expect(physical.transferPeakTrackedByteHighWater == tileBytes * 6)

        let token = try registry.sharedTileStore.retainSnapshotReferences(
            references
        )
        #expect(
            registry.sharedTileStore.snapshot()
                .snapshotPayloadDebtByteCount == tileBytes * 3
        )
        token.close()
        #expect(
            registry.sharedTileStore.snapshot()
                .snapshotPayloadDebtByteCount == 0
        )
    }

    @Test
    func emptyRegistryHasGenericLayerBindingsAndCheckedGeometry() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let first = UUID()
        let second = UUID()
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 4_096, height: 2_048),
            storagePixelSize: PixelSize(width: 4_096, height: 2_048),
            radialLayout: nil
        )
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: tileBytes * 8,
            transferByteCapacity: tileBytes * 9,
            geometry: geometry,
            layerIDs: [first, second],
            generation: 4
        )

        #expect(registry.generation == 4)
        #expect(registry.geometry == geometry)
        #expect(registry.layerIDs == [first, second])
        #expect(try registry.binding(for: first).canonical.references.isEmpty)
        #expect(try registry.binding(for: second).canonical.references.isEmpty)
        #expect(registry.tileStoreIdentity == registry.sharedTileStore.identity)
        #expect(registry.sharedTileStore.transferByteCapacity == tileBytes * 9)
        #expect(registry.snapshot().tileByteBudget == tileBytes * 8)
        #expect(registry.snapshot().activeTileLeaseCount == 0)
        #expect(registry.snapshot().issuedNamespaceCount == 0)
        #expect(registry.snapshot().preparedCandidateCount == 0)
        #expect(throws: DocumentPaintSurfaceStoreError.duplicateLayerID(first)) {
            _ = try DocumentPaintSurfaceStore(
                device: device,
                byteBudget: tileBytes,
                geometry: geometry,
                layerIDs: [first, first]
            )
        }
        #expect(throws: DocumentPaintSurfaceStoreError.geometryByteCountOverflow) {
            _ = try DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: Int.max, height: 2),
                storagePixelSize: PixelSize(width: Int.max, height: 2),
                radialLayout: nil
            )
        }
    }

    @Test
    func radialGeometryUsesSparsePagesAndRejectsMismatchedAtlasStorage() throws {
        let layout = try RadialSectorLayout(
            maximumRadius: 1_024,
            sectorAngleRadians: .pi / 9
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 2_048, height: 2_048),
            storagePixelSize: layout.atlasPixelSize,
            radialLayout: layout
        )
        #expect(geometry.storageResidentByteCount
            == (try layout.residentByteCount(bytesPerPixel: 8)))

        let mismatch = PixelSize(
            width: layout.atlasPixelSize.width + 1,
            height: layout.atlasPixelSize.height
        )
        #expect(throws: DocumentPaintSurfaceStoreError
            .radialStorageSizeMismatch(
                expected: layout.atlasPixelSize,
                actual: mismatch
            )) {
            _ = try DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: 2_048, height: 2_048),
                storagePixelSize: mismatch,
                radialLayout: layout
            )
        }
    }

    @Test
    func registryIssuesAuthenticatedRoleSpecificStrokeNamespace() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let lease = try registry.issueCurrentStrokeNamespace(layerID: layer)

        #expect(lease.storeIdentity == registry.tileStoreIdentity)
        #expect(lease.layerID == layer)
        #expect(lease.generation == registry.generation)
        #expect(lease.authoritative.role == .authoritative)
        #expect(lease.prediction.role == .prediction)
        #expect(lease.authoritative.surfaceID != lease.prediction.surfaceID)
        #expect(lease.isAuthenticated(
            storeIdentity: registry.tileStoreIdentity,
            layerID: layer,
            generation: registry.generation
        ))
        #expect(!lease.isAuthenticated(
            storeIdentity: PaintTileStoreIdentity(),
            layerID: layer,
            generation: registry.generation
        ))
        lease.reportRetired()
        #expect(!lease.isAuthenticated(
            storeIdentity: registry.tileStoreIdentity,
            layerID: layer,
            generation: registry.generation
        ))
    }

    @Test
    func preparedEpochPublishesGenerationGeometryOrderAndLayersTogether() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let firstLayer = UUID()
        let secondLayer = UUID()
        let registry = try makeRegistry(
            device: device,
            layers: [firstLayer, secondLayer]
        )
        let beforeIdentity = registry.testingCurrentEpochIdentity
        let before = registry.snapshot()
        let replacementGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 2_048, height: 512),
            storagePixelSize: PixelSize(width: 2_048, height: 512),
            radialLayout: nil
        )
        let coordinate = PaintTileCoordinate(x: 3, y: 1)
        let candidate = try registry.makeCandidate(
            geometry: replacementGeometry,
            dirtyCoordinatesByLayer: [secondLayer: [coordinate]]
        )

        let prepared = try registry.prepareCommit(candidate)
        #expect(prepared.testingEpochIdentity != beforeIdentity)
        #expect(registry.testingCurrentEpochIdentity == beforeIdentity)
        #expect(registry.snapshot().generation == before.generation)
        #expect(registry.snapshot().geometry == before.geometry)
        #expect(registry.snapshot().layers == before.layers)

        registry.commitPrepared(prepared)

        let after = registry.snapshot()
        #expect(registry.testingCurrentEpochIdentity
            == prepared.testingEpochIdentity)
        #expect(after.generation == candidate.generation)
        #expect(after.geometry == replacementGeometry)
        #expect(after.layers.map(\.layerID) == [firstLayer, secondLayer])
        #expect(after.layers[0].references.isEmpty)
        #expect(after.layers[1].references.map(\.coordinate) == [coordinate])
        let firstBinding = try registry.binding(for: firstLayer)
        let secondBinding = try registry.binding(for: secondLayer)
        #expect(firstBinding.generation == candidate.generation)
        #expect(secondBinding.generation == candidate.generation)
        #expect(firstBinding.canonical.pixelSize
            == replacementGeometry.storagePixelSize)
        #expect(secondBinding.canonical.pixelSize
            == replacementGeometry.storagePixelSize)
    }

    @Test
    func currentStrokeAuthorityTracksGeometryChangingEpochCommit() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let initialGeneration = registry.generation
        let initialGeometry = registry.geometry

        let initialNamespace = try registry.issueCurrentStrokeNamespace(
            layerID: layer
        )
        #expect(initialNamespace.generation == initialGeneration)
        initialNamespace.reportRetired()

        let initialOwner = UUID()
        let initialCapability = try registry
            .issueCurrentStrokeSurfaceCapability(
                layerID: layer,
                ownerIdentity: initialOwner,
                onTerminal: { _ in }
            )
        #expect(initialCapability.generation == initialGeneration)
        #expect(initialCapability.pixelSize == initialGeometry.storagePixelSize)
        #expect(initialCapability.radialLayout == initialGeometry.radialLayout)
        try initialCapability.cancel(expectedOwnerIdentity: initialOwner)

        let replacementGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 1_536, height: 768),
            storagePixelSize: PixelSize(width: 1_536, height: 768),
            radialLayout: nil
        )
        let replacement = try registry.makeCandidate(
            geometry: replacementGeometry
        )
        registry.commitPrepared(try registry.prepareCommit(replacement))

        let replacementNamespace = try registry.issueCurrentStrokeNamespace(
            layerID: layer
        )
        #expect(replacementNamespace.generation == replacement.generation)
        replacementNamespace.reportRetired()

        let replacementOwner = UUID()
        let replacementCapability = try registry
            .issueCurrentStrokeSurfaceCapability(
                layerID: layer,
                ownerIdentity: replacementOwner,
                onTerminal: { _ in }
            )
        #expect(replacementCapability.generation == replacement.generation)
        #expect(replacementCapability.pixelSize
            == replacementGeometry.storagePixelSize)
        #expect(replacementCapability.radialLayout
            == replacementGeometry.radialLayout)
        try replacementCapability.cancel(
            expectedOwnerIdentity: replacementOwner
        )
    }

    @Test
    func visibleCaptureRetriesPublicationBetweenSelectionAndRetention() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let initial = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]]
        )
        registry.commitPrepared(try registry.prepareCommit(initial))

        let replacement = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 1, y: 0)]]
        )
        let preparedReplacement = try registry.prepareCommit(replacement)
        let publication = OneShotDocumentPaintAction()
        registry.testingVisibleSelectionCompleted = {
            publication.run {
                registry.commitPrepared(preparedReplacement)
            }
        }

        let capture = try registry.captureCanonicalVisibleSources(
            layerID: layer,
            addressing: .finite(registry.geometry.storagePixelSize),
            addressingRevision: 9,
            outputRegion: try SparseTileOutputRegion(
                minX: 256, minY: 0, maxX: 257, maxY: 1
            ),
            outputGeometryRevision: 11
        )
        registry.testingVisibleSelectionCompleted = nil

        #expect(publication.runCount == 1)
        #expect(capture.key.documentGeneration == replacement.generation)
        #expect(capture.key.addressingRevision == 9)
        #expect(capture.key.outputGeometryRevision == 11)
        #expect(capture.sourceBatch.sources.count == 1)
        #expect(capture.sourceBatch.sources[0].references.map(\.coordinate)
            == [.init(x: 0, y: 0), .init(x: 1, y: 0)])
        #expect(capture.sourceBatch.sources[0].provider
            .entitledReferences.map(\.coordinate) == [.init(x: 1, y: 0)])
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 1)
        try capture.sourceBatch.abandon()
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 0)
    }

    @Test
    func capturedOldEpochReferenceSurvivesReplacementUntilExplicitClose()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let initial = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]]
        )
        registry.commitPrepared(try registry.prepareCommit(initial))
        let oldReference = try #require(
            registry.binding(for: layer).canonical.references.first
        )
        let capture = try registry.captureCanonicalVisibleSources(
            layerID: layer,
            addressing: .finite(registry.geometry.storagePixelSize),
            addressingRevision: 1,
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 1, maxY: 1
            ),
            outputGeometryRevision: 1
        )

        let replacement = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]]
        )
        registry.commitPrepared(try registry.prepareCommit(replacement))
        let newReference = try #require(
            registry.binding(for: layer).canonical.references.first
        )
        #expect(newReference.identity != oldReference.identity)
        let retained = registry.sharedTileStore.snapshot()
        #expect(retained.pendingRetirementCount == 1)
        #expect(retained.entries.first {
            $0.identity == oldReference.identity
        }?.snapshotRetainCount == 1)

        try capture.sourceBatch.abandon()
        let released = registry.sharedTileStore.snapshot()
        #expect(released.pendingRetirementCount == 0)
        #expect(!released.entries.contains {
            $0.identity == oldReference.identity
        })
        #expect(released.entries.contains {
            $0.identity == newReference.identity
        })
    }

    @Test
    func disjointVisibleCapturePreservesFingerprintButOwnsNoToken() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let emptyCapture = try registry.captureCanonicalVisibleSources(
            layerID: layer,
            addressing: .finite(registry.geometry.storagePixelSize),
            addressingRevision: 1,
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 1, maxY: 1
            ),
            outputGeometryRevision: 1
        )
        #expect(emptyCapture.sourceBatch.sources[0].references.isEmpty)
        #expect(emptyCapture.sourceBatch.sources[0].provider
            .entitledReferences.isEmpty)
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 0)
        try emptyCapture.sourceBatch.abandon()

        let initial = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]]
        )
        registry.commitPrepared(try registry.prepareCommit(initial))
        let expected = try registry.binding(for: layer).canonical.references

        let capture = try registry.captureCanonicalVisibleSources(
            layerID: layer,
            addressing: .finite(registry.geometry.storagePixelSize),
            addressingRevision: 1,
            outputRegion: try SparseTileOutputRegion(
                minX: 768, minY: 768, maxX: 769, maxY: 769
            ),
            outputGeometryRevision: 1
        )

        #expect(capture.sourceBatch.sources[0].references == expected)
        #expect(capture.sourceBatch.sources[0].provider
            .entitledReferences.isEmpty)
        let snapshot = registry.sharedTileStore.snapshot()
        #expect(snapshot.activeSnapshotTokenCount == 0)
        #expect(snapshot.aggregateSnapshotReferenceCount == 0)
        try capture.sourceBatch.abandon()
    }

    @Test
    func visibleCaptureContentionIsBoundedAndLeavesNoRetentionDebt() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let initial = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]]
        )
        registry.commitPrepared(try registry.prepareCommit(initial))
        let beforeGeneration = registry.generation
        let publisher = RepeatingDocumentPaintPublisher(
            registry: registry
        )
        registry.testingVisibleSelectionCompleted = publisher.run

        #expect(throws: DocumentPaintSurfaceStoreError
            .visibleCaptureContention(
                maximumAttempts:
                    DocumentPaintSurfaceStore.maximumVisibleCaptureAttempts
            )) {
            _ = try registry.captureCanonicalVisibleSources(
                layerID: layer,
                addressing: .finite(registry.geometry.storagePixelSize),
                addressingRevision: 1,
                outputRegion: try SparseTileOutputRegion(
                    minX: 0, minY: 0, maxX: 1, maxY: 1
                ),
                outputGeometryRevision: 1
            )
        }
        registry.testingVisibleSelectionCompleted = nil

        #expect(publisher.failureDescription == nil)
        #expect(publisher.runCount
            == DocumentPaintSurfaceStore.maximumVisibleCaptureAttempts)
        #expect(registry.generation == beforeGeneration
            + UInt64(DocumentPaintSurfaceStore.maximumVisibleCaptureAttempts))
        let snapshot = registry.sharedTileStore.snapshot()
        #expect(snapshot.activeSnapshotTokenCount == 0)
        #expect(snapshot.aggregateSnapshotReferenceCount == 0)
    }

    @Test
    func layerCompositeCaptureBindsExactStackOrderBeforeRetention() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let first = try LayerDescriptor(id: UUID(), name: "Bottom")
        let second = try LayerDescriptor(id: UUID(), name: "Top")
        let stack = try LayerStack(
            layers: [first, second],
            activeLayerID: second.id
        )
        let registry = try makeRegistry(
            device: device,
            layers: [first.id, second.id],
            layerStack: stack
        )
        let candidate = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [
                first.id: [.init(x: 0, y: 0)],
                second.id: [.init(x: 0, y: 0)],
            ]
        )
        registry.commitPrepared(try registry.prepareCommit(candidate))
        let reversed = try LayerStack(
            layers: [second, first],
            activeLayerID: first.id
        )
        let before = registry.sharedTileStore.snapshot()

        #expect(throws: DocumentPaintSurfaceStoreError.layerStackMismatch(
            expected: [first.id, second.id],
            actual: [second.id, first.id]
        )) {
            _ = try registry.prepareLayerCompositePlan(
                layerStack: reversed,
                addressing: .finite(registry.geometry.storagePixelSize),
                addressingRevision: 1,
                outputRegion: SparseTileOutputRegion(
                    minX: 0, minY: 0, maxX: 1, maxY: 1
                ),
                outputGeometryRevision: 1,
                limits: .documentProduction
            )
        }
        let after = registry.sharedTileStore.snapshot()
        #expect(after.activeSnapshotTokenCount
            == before.activeSnapshotTokenCount)
        #expect(after.aggregateSnapshotReferenceCount
            == before.aggregateSnapshotReferenceCount)
        #expect(after.snapshotMetadataByteCount
            == before.snapshotMetadataByteCount)
        #expect(after.snapshotPayloadDebtByteCount
            == before.snapshotPayloadDebtByteCount)

        let plan = try registry.prepareLayerCompositePlan(
            layerStack: stack,
            addressing: .finite(registry.geometry.storagePixelSize),
            addressingRevision: 2,
            outputRegion: SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 1, maxY: 1
            ),
            outputGeometryRevision: 3,
            limits: .documentProduction
        )
        #expect(plan.layers.map(\.layerID) == [first.id, second.id])
        #expect(plan.documentGeneration == registry.generation)
        let retained = registry.sharedTileStore.snapshot()
        #expect(retained.activeSnapshotTokenCount == 1)
        #expect(retained.aggregateSnapshotReferenceCount == 2)
        #expect(retained.snapshotPayloadDebtByteCount == tileBytes * 2)
        plan.close()
        plan.close()
        let closed = registry.sharedTileStore.snapshot()
        #expect(closed.activeSnapshotTokenCount == 0)
        #expect(closed.aggregateSnapshotReferenceCount == 0)
        #expect(closed.snapshotMetadataByteCount == 0)
        #expect(closed.snapshotPayloadDebtByteCount == 0)
    }

    @Test
    func layerCompositeCaptureRetriesWholeEpochWithoutMixedRoots() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bottom = try LayerDescriptor(id: UUID(), name: "Bottom")
        let top = try LayerDescriptor(id: UUID(), name: "Top")
        let stack = try LayerStack(
            layers: [bottom, top],
            activeLayerID: top.id
        )
        let registry = try makeRegistry(
            device: device,
            layers: stack.orderedLayerIDs,
            layerStack: stack
        )
        let initial = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [bottom.id: [.init(x: 0, y: 0)]]
        )
        registry.commitPrepared(try registry.prepareCommit(initial))
        let replacement = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [top.id: [.init(x: 1, y: 0)]]
        )
        let preparedReplacement = try registry.prepareCommit(replacement)
        let publication = OneShotDocumentPaintAction()
        registry.testingVisibleSelectionCompleted = {
            publication.run {
                registry.commitPrepared(preparedReplacement)
            }
        }

        let plan = try registry.prepareLayerCompositePlan(
            layerStack: stack,
            addressing: .finite(registry.geometry.storagePixelSize),
            addressingRevision: 5,
            outputRegion: SparseTileOutputRegion(
                minX: 256, minY: 0, maxX: 257, maxY: 1
            ),
            outputGeometryRevision: 7,
            limits: .documentProduction
        )
        registry.testingVisibleSelectionCompleted = nil

        #expect(publication.runCount == 1)
        #expect(plan.documentGeneration == replacement.generation)
        #expect(plan.layers.map(\.layerID) == [top.id])
        let retained = registry.sharedTileStore.snapshot()
        #expect(retained.activeSnapshotTokenCount == 1)
        #expect(retained.aggregateSnapshotReferenceCount == 1)
        plan.close()
        let closed = registry.sharedTileStore.snapshot()
        #expect(closed.activeSnapshotTokenCount == 0)
        #expect(closed.aggregateSnapshotReferenceCount == 0)
        #expect(closed.snapshotMetadataByteCount == 0)
        #expect(closed.snapshotPayloadDebtByteCount == 0)
    }

    @Test
    func layerCompositeAggregateRetentionFailurePublishesNoPartialRoot()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bottom = try LayerDescriptor(id: UUID(), name: "Bottom")
        let top = try LayerDescriptor(id: UUID(), name: "Top")
        let stack = try LayerStack(
            layers: [bottom, top],
            activeLayerID: top.id
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 256, height: 256),
            storagePixelSize: PixelSize(width: 256, height: 256),
            radialLayout: nil
        )
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: tileBytes * 4,
            snapshotPayloadLiabilityByteBudget: tileBytes,
            geometry: geometry,
            layerIDs: stack.orderedLayerIDs,
            layerStack: stack
        )
        let candidate = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [
                bottom.id: [.init(x: 0, y: 0)],
                top.id: [.init(x: 0, y: 0)],
            ]
        )
        registry.commitPrepared(try registry.prepareCommit(candidate))
        let before = registry.sharedTileStore.snapshot()

        #expect(throws: PaintTileStoreError.snapshotRetentionLimitExceeded(
            limit: .payloadDebtBytes,
            required: tileBytes * 2,
            maximum: tileBytes
        )) {
            _ = try registry.prepareLayerCompositePlan(
                layerStack: stack,
                addressing: .finite(geometry.storagePixelSize),
                addressingRevision: 1,
                outputRegion: SparseTileOutputRegion(
                    minX: 0, minY: 0, maxX: 1, maxY: 1
                ),
                outputGeometryRevision: 1,
                limits: .documentProduction
            )
        }

        #expect(registry.sharedTileStore.snapshot() == before)
    }

    @Test
    func transientUnionCaptureOwnsOneAggregateTokenForThreeRoles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let canonical = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [coordinate]]
        )
        registry.commitPrepared(try registry.prepareCommit(canonical))
        let owner = UUID()
        let capability = try registry.issueCurrentStrokeSurfaceCapability(
            layerID: layer,
            ownerIdentity: owner,
            onTerminal: { _ in }
        )
        let reservation = try capability.reserveStrokeTiles(
            role: .authoritative,
            coordinates: [coordinate],
            pinReasons: [.visible, .inFlight],
            workspace: PaintTileStrokeLeaseWorkspace(maximumBindingCount: 1),
            failureInjection: nil
        )
        try capability.testingMarkDirty(reservation)
        try capability.releaseFrameReservations(
            authoritative: reservation,
            prediction: nil
        )
        let addressing = SparseTileAddressing.finite(
            registry.geometry.storagePixelSize
        )
        let descriptor = try DocumentPaintTransientVisibleSourceDescriptor(
            capability: capability,
            changedRole: .authoritative,
            changedCoordinates: [coordinate],
            addressing: addressing,
            disposition: .fullSnapshot
        )

        let capture = try registry.captureTransientVisibleSources(
            layerID: layer,
            descriptor: descriptor,
            addressing: addressing,
            addressingRevision: 3,
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 1, maxY: 1
            ),
            outputGeometryRevision: 4
        )
        #expect(capture.sourceBatch.sources.map(\.role)
            == [.canonical, .authoritative, .prediction])
        let retained = registry.sharedTileStore.snapshot()
        #expect(retained.activeSnapshotTokenCount == 1)
        #expect(retained.aggregateSnapshotReferenceCount == 2)
        try capture.sourceBatch.abandon()
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 0)
        try capability.cancel(expectedOwnerIdentity: owner)
    }

    @Test
    func transientCaptureRejectsForeignStaleAndRetiredAuthorityWithZeroDebt()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let foreignRegistry = try makeRegistry(device: device, layers: [layer])
        let addressing = SparseTileAddressing.finite(
            registry.geometry.storagePixelSize
        )
        let output = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 1, maxY: 1
        )

        let foreignOwner = UUID()
        let foreignCapability = try foreignRegistry
            .issueCurrentStrokeSurfaceCapability(
                layerID: layer,
                ownerIdentity: foreignOwner,
                onTerminal: { _ in }
            )
        let foreignDescriptor = try
            DocumentPaintTransientVisibleSourceDescriptor(
                capability: foreignCapability,
                changedRole: .authoritative,
                changedCoordinates: [],
                addressing: addressing,
                disposition: .delta
            )
        #expect(throws: DocumentPaintStrokeSurfaceError.staleCapability) {
            _ = try registry.captureTransientVisibleSources(
                layerID: layer,
                descriptor: foreignDescriptor,
                addressing: addressing,
                addressingRevision: 1,
                outputRegion: output,
                outputGeometryRevision: 1
            )
        }
        try foreignCapability.cancel(expectedOwnerIdentity: foreignOwner)

        let staleOwner = UUID()
        let staleCapability = try registry.issueCurrentStrokeSurfaceCapability(
            layerID: layer,
            ownerIdentity: staleOwner,
            onTerminal: { _ in }
        )
        let staleDescriptor = try
            DocumentPaintTransientVisibleSourceDescriptor(
                capability: staleCapability,
                changedRole: .authoritative,
                changedCoordinates: [],
                addressing: addressing,
                disposition: .delta
            )
        let replacement = try registry.makeCandidate()
        registry.commitPrepared(try registry.prepareCommit(replacement))
        #expect(throws: DocumentPaintStrokeSurfaceError.staleCapability) {
            _ = try registry.captureTransientVisibleSources(
                layerID: layer,
                descriptor: staleDescriptor,
                addressing: addressing,
                addressingRevision: 1,
                outputRegion: output,
                outputGeometryRevision: 1
            )
        }
        try staleCapability.cancel(expectedOwnerIdentity: staleOwner)

        let retiredOwner = UUID()
        let retiredCapability = try registry.issueCurrentStrokeSurfaceCapability(
            layerID: layer,
            ownerIdentity: retiredOwner,
            onTerminal: { _ in }
        )
        let retiredDescriptor = try
            DocumentPaintTransientVisibleSourceDescriptor(
                capability: retiredCapability,
                changedRole: .authoritative,
                changedCoordinates: [],
                addressing: addressing,
                disposition: .delta
            )
        try retiredCapability.cancel(expectedOwnerIdentity: retiredOwner)
        #expect(throws: DocumentPaintStrokeSurfaceError.staleCapability) {
            _ = try registry.captureTransientVisibleSources(
                layerID: layer,
                descriptor: retiredDescriptor,
                addressing: addressing,
                addressingRevision: 1,
                outputRegion: output,
                outputGeometryRevision: 1
            )
        }
        let snapshot = registry.sharedTileStore.snapshot()
        #expect(snapshot.activeSnapshotTokenCount == 0)
        #expect(snapshot.aggregateSnapshotReferenceCount == 0)
    }

    @Test
    func resizedEpochRejectsStaleVisibleAddressingWithoutRetentionDebt()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let oldAddressing = SparseTileAddressing.finite(
            registry.geometry.storagePixelSize
        )
        let replacementGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 512, height: 512),
            storagePixelSize: PixelSize(width: 512, height: 512),
            radialLayout: nil
        )
        let replacement = try registry.makeCandidate(
            geometry: replacementGeometry
        )
        let prepared = try registry.prepareCommit(replacement)
        let publication = OneShotDocumentPaintAction()
        registry.testingVisibleSelectionCompleted = {
            publication.run { registry.commitPrepared(prepared) }
        }

        #expect(throws: SparseTileSamplingPlanError.inconsistentAddressing) {
            _ = try registry.captureCanonicalVisibleSources(
                layerID: layer,
                addressing: oldAddressing,
                addressingRevision: 1,
                outputRegion: try SparseTileOutputRegion(
                    minX: 0, minY: 0, maxX: 1, maxY: 1
                ),
                outputGeometryRevision: 1
            )
        }
        registry.testingVisibleSelectionCompleted = nil
        #expect(publication.runCount == 1)
        #expect(registry.geometry == replacementGeometry)
        let snapshot = registry.sharedTileStore.snapshot()
        #expect(snapshot.activeSnapshotTokenCount == 0)
        #expect(snapshot.aggregateSnapshotReferenceCount == 0)
    }

    @Test
    func transientPublicationInterleaveRejectsOldNamespaceWithZeroDebt()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let owner = UUID()
        let capability = try registry.issueCurrentStrokeSurfaceCapability(
            layerID: layer,
            ownerIdentity: owner,
            onTerminal: { _ in }
        )
        let addressing = SparseTileAddressing.finite(
            registry.geometry.storagePixelSize
        )
        let descriptor = try DocumentPaintTransientVisibleSourceDescriptor(
            capability: capability,
            changedRole: .authoritative,
            changedCoordinates: [],
            addressing: addressing,
            disposition: .delta
        )
        let replacement = try registry.makeCandidate()
        let prepared = try registry.prepareCommit(replacement)
        let publication = OneShotDocumentPaintAction()
        registry.testingVisibleSelectionCompleted = {
            publication.run { registry.commitPrepared(prepared) }
        }

        #expect(throws: DocumentPaintStrokeSurfaceError.staleCapability) {
            _ = try registry.captureTransientVisibleSources(
                layerID: layer,
                descriptor: descriptor,
                addressing: addressing,
                addressingRevision: 1,
                outputRegion: try SparseTileOutputRegion(
                    minX: 0, minY: 0, maxX: 1, maxY: 1
                ),
                outputGeometryRevision: 1
            )
        }
        registry.testingVisibleSelectionCompleted = nil
        #expect(publication.runCount == 1)
        let snapshot = registry.sharedTileStore.snapshot()
        #expect(snapshot.activeSnapshotTokenCount == 0)
        #expect(snapshot.aggregateSnapshotReferenceCount == 0)
        try capability.cancel(expectedOwnerIdentity: owner)
    }

    @Test
    func concurrentCommitAndSnapshotObserveOnlyCompleteEpochs() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let firstLayer = UUID()
        let secondLayer = UUID()
        let registry = try makeRegistry(
            device: device,
            layers: [firstLayer, secondLayer]
        )
        let old = registry.snapshot()
        let firstGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 1_536, height: 768),
            storagePixelSize: PixelSize(width: 1_536, height: 768),
            radialLayout: nil
        )
        let firstCoordinate = PaintTileCoordinate(x: 4, y: 2)
        let firstCandidate = try registry.makeCandidate(
            geometry: firstGeometry,
            dirtyCoordinatesByLayer: [secondLayer: [firstCoordinate]]
        )
        let firstPrepared = try registry.prepareCommit(firstCandidate)

        // Reader owns the lock first: the overlapping commit must publish only
        // after this snapshot has completed from the old immutable epoch.
        let oldReadBarrier = DocumentPaintEpochRaceBarrier(
            target: .snapshotCaptured
        )
        registry.testingEpochHook = oldReadBarrier.hook
        let oldSnapshotTask = Task.detached { registry.snapshot() }
        try await oldReadBarrier.waitUntilReached()
        defer { oldReadBarrier.release() }
        let firstCommitStarted = DispatchSemaphore(value: 0)
        let firstCommitTask = Task.detached {
            firstCommitStarted.signal()
            registry.commitPrepared(firstPrepared)
        }
        let didStartFirstCommit = await waitForDocumentPaintSignal(
            firstCommitStarted
        )
        #expect(didStartFirstCommit)
        oldReadBarrier.release()
        let observedOld = await oldSnapshotTask.value
        await firstCommitTask.value
        registry.testingEpochHook = nil

        #expect(observedOld.generation == old.generation)
        #expect(observedOld.geometry == old.geometry)
        #expect(observedOld.layers == old.layers)
        let firstPublished = registry.snapshot()
        #expect(firstPublished.generation == firstCandidate.generation)
        #expect(firstPublished.geometry == firstGeometry)
        #expect(firstPublished.layers.map(\.layerID)
            == [firstLayer, secondLayer])
        #expect(firstPublished.layers[0].references.isEmpty)
        #expect(firstPublished.layers[1].references.map(\.coordinate)
            == [firstCoordinate])

        let secondGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 768, height: 1_536),
            storagePixelSize: PixelSize(width: 768, height: 1_536),
            radialLayout: nil
        )
        let secondCoordinate = PaintTileCoordinate(x: 1, y: 4)
        let secondCandidate = try registry.makeCandidate(
            geometry: secondGeometry,
            dirtyCoordinatesByLayer: [firstLayer: [secondCoordinate]]
        )
        let secondPrepared = try registry.prepareCommit(secondCandidate)

        // Publisher owns the lock first: the overlapping reader must observe
        // the complete replacement epoch after the single pointer swap.
        let publicationBarrier = DocumentPaintEpochRaceBarrier(
            target: .beforePublication
        )
        registry.testingEpochHook = publicationBarrier.hook
        let secondCommitTask = Task.detached {
            registry.commitPrepared(secondPrepared)
        }
        try await publicationBarrier.waitUntilReached()
        defer { publicationBarrier.release() }
        let newReadStarted = DispatchSemaphore(value: 0)
        let newSnapshotTask = Task.detached {
            newReadStarted.signal()
            return registry.snapshot()
        }
        let didStartNewRead = await waitForDocumentPaintSignal(newReadStarted)
        #expect(didStartNewRead)
        publicationBarrier.release()
        await secondCommitTask.value
        let observedNew = await newSnapshotTask.value
        registry.testingEpochHook = nil

        #expect(observedNew.generation == secondCandidate.generation)
        #expect(observedNew.geometry == secondGeometry)
        #expect(observedNew.layers.map(\.layerID)
            == [firstLayer, secondLayer])
        #expect(observedNew.layers[0].references.map(\.coordinate)
            == [secondCoordinate])
        #expect(observedNew.layers[1].references.isEmpty)
    }

    @Test
    func concurrentCommitAndCurrentAuthorityCannotMixOrForgeEpochs() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let oldGeneration = registry.generation
        let oldGeometry = registry.geometry
        let firstGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 1_536, height: 768),
            storagePixelSize: PixelSize(width: 1_536, height: 768),
            radialLayout: nil
        )
        let firstCandidate = try registry.makeCandidate(
            geometry: firstGeometry
        )
        let firstPrepared = try registry.prepareCommit(firstCandidate)

        // Issuance captures the old epoch first while the commit is blocked on
        // the registry lock. Capability construction may finish after publish,
        // but its generation and geometry must remain the captured old tuple.
        let oldAuthorityBarrier = DocumentPaintEpochRaceBarrier(
            target: .strokeAuthorityCaptured
        )
        registry.testingEpochHook = oldAuthorityBarrier.hook
        let oldOwner = UUID()
        let oldCapabilityTask = Task.detached {
            try registry.issueCurrentStrokeSurfaceCapability(
                layerID: layer,
                ownerIdentity: oldOwner,
                onTerminal: { _ in }
            )
        }
        try await oldAuthorityBarrier.waitUntilReached()
        defer { oldAuthorityBarrier.release() }
        let firstCommitStarted = DispatchSemaphore(value: 0)
        let firstCommitTask = Task.detached {
            firstCommitStarted.signal()
            registry.commitPrepared(firstPrepared)
        }
        let didStartFirstCommit = await waitForDocumentPaintSignal(
            firstCommitStarted
        )
        #expect(didStartFirstCommit)
        oldAuthorityBarrier.release()
        let oldCapability = try await oldCapabilityTask.value
        await firstCommitTask.value
        registry.testingEpochHook = nil

        #expect(oldCapability.layerID == layer)
        #expect(oldCapability.generation == oldGeneration)
        #expect(oldCapability.pixelSize == oldGeometry.storagePixelSize)
        #expect(oldCapability.radialLayout == oldGeometry.radialLayout)
        try oldCapability.cancel(expectedOwnerIdentity: oldOwner)

        let secondGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 768, height: 1_536),
            storagePixelSize: PixelSize(width: 768, height: 1_536),
            radialLayout: nil
        )
        let secondCandidate = try registry.makeCandidate(
            geometry: secondGeometry
        )
        let secondPrepared = try registry.prepareCommit(secondCandidate)

        // Publication owns the lock first, so concurrent current-only issuance
        // must derive both authority generation and geometry from the new epoch.
        let publicationBarrier = DocumentPaintEpochRaceBarrier(
            target: .beforePublication
        )
        registry.testingEpochHook = publicationBarrier.hook
        let secondCommitTask = Task.detached {
            registry.commitPrepared(secondPrepared)
        }
        try await publicationBarrier.waitUntilReached()
        defer { publicationBarrier.release() }
        let newOwner = UUID()
        let newAuthorityStarted = DispatchSemaphore(value: 0)
        let newCapabilityTask = Task.detached {
            newAuthorityStarted.signal()
            return try registry.issueCurrentStrokeSurfaceCapability(
                layerID: layer,
                ownerIdentity: newOwner,
                onTerminal: { _ in }
            )
        }
        let didStartNewAuthority = await waitForDocumentPaintSignal(
            newAuthorityStarted
        )
        #expect(didStartNewAuthority)
        publicationBarrier.release()
        await secondCommitTask.value
        let newCapability = try await newCapabilityTask.value
        registry.testingEpochHook = nil

        #expect(newCapability.layerID == layer)
        #expect(newCapability.generation == secondCandidate.generation)
        #expect(newCapability.pixelSize == secondGeometry.storagePixelSize)
        #expect(newCapability.radialLayout == secondGeometry.radialLayout)
        try newCapability.cancel(expectedOwnerIdentity: newOwner)

    }

    @Test
    func exactReferencesRejectForeignStoreStaleIdentityAndUnsortedInput() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: tileBytes * 4)
        let other = PaintTileStore(device: device, byteBudget: tileBytes * 4)
        let layer = UUID()
        let surface = UUID()
        let size = PixelSize(width: 512, height: 256)
        let lease = try store.reserve(
            surfaceID: surface,
            layerID: layer,
            generation: 8,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            pinReasons: [.dirty]
        )
        try store.markModified(lease, surfaceID: surface, currentGeneration: 8)
        try store.release(lease, surfaceID: surface, currentGeneration: 8)
        let refs = try store.references(
            surfaceID: surface,
            layerID: layer,
            generation: 8
        )
        #expect(refs.map(\.coordinate) == [
            .init(x: 0, y: 0), .init(x: 1, y: 0),
        ])
        #expect(refs.allSatisfy { $0.storeIdentity == store.identity })

        #expect(throws: PaintTileStoreError.foreignStoreReference) {
            _ = try other.reserveReferences(
                refs,
                leaseSurfaceID: UUID(),
                leaseLayerID: layer,
                leaseGeneration: 9,
                pinReasons: [.visible]
            )
        }
        #expect(throws: PaintTileStoreError.unsortedReference) {
            _ = try store.reserveReferences(
                refs.reversed(),
                leaseSurfaceID: UUID(),
                leaseLayerID: layer,
                leaseGeneration: 9,
                pinReasons: [.visible]
            )
        }
        var stale = refs
        stale[0] = stale[0].replacing(
            identity: PaintTileIdentity(
                layerID: layer,
                coordinate: stale[0].coordinate,
                tileID: PaintTileID(rawValue: .max)
            )
        )
        #expect(throws: PaintTileStoreError.staleTileReference) {
            _ = try store.reserveReferences(
                stale,
                leaseSurfaceID: UUID(),
                leaseLayerID: layer,
                leaseGeneration: 9,
                pinReasons: [.visible]
            )
        }
    }

    @Test
    func mixedNamespaceReferenceLeaseIsExactSortedAndAtomic() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: tileBytes * 4)
        let layer = UUID()
        let size = PixelSize(width: 512, height: 256)
        let first = try seed(
            store: store, surfaceID: UUID(), layerID: layer,
            generation: 1, size: size, coordinate: .init(x: 0, y: 0)
        )
        let second = try seed(
            store: store, surfaceID: UUID(), layerID: layer,
            generation: 2, size: size, coordinate: .init(x: 1, y: 0)
        )
        let references = [first, second].sorted()
        let owner = UUID()
        let before = store.snapshot()
        let lease = try store.reserveReferences(
            references,
            leaseSurfaceID: owner,
            leaseLayerID: layer,
            leaseGeneration: 3,
            pinReasons: [.visible, .inFlight]
        )
        #expect(lease.storeIdentity == store.identity)
        #expect(lease.bindings.map(\.identity) == references.map(\.identity))
        #expect(store.snapshot().activeLeaseCount == before.activeLeaseCount + 1)
        try store.release(lease, surfaceID: owner, currentGeneration: 3)
        #expect(store.snapshot().activeLeaseCount == before.activeLeaseCount)

        let state = store.snapshot()
        #expect(throws: PaintTileStoreError.staleTileReference) {
            _ = try store.reserveReferences(
                [first, second.replacing(
                    identity: PaintTileIdentity(
                        layerID: layer,
                        coordinate: second.coordinate,
                        tileID: PaintTileID(rawValue: .max)
                    )
                )].sorted(),
                leaseSurfaceID: owner,
                leaseLayerID: layer,
                leaseGeneration: 3,
                pinReasons: [.visible]
            )
        }
        #expect(store.snapshot() == state)
    }

    @Test
    func immutableSurfaceViewLeasesExactReferencesAndRejectsMutation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: tileBytes * 2)
        let layer = UUID()
        let physical = UUID()
        let size = PixelSize(width: 512, height: 256)
        _ = try seed(
            store: store, surfaceID: physical, layerID: layer,
            generation: 2, size: size, coordinate: .init(x: 1, y: 0)
        )
        let refs = try store.references(
            surfaceID: physical, layerID: layer, generation: 2
        )
        let view = try TiledRasterCoordinateReferenceView(
            storeIdentity: store.identity,
            surfaceID: UUID(),
            layerID: layer,
            pixelSize: size,
            generation: 3,
            revision: RasterRevision(rawValue: 7),
            references: refs
        )
        let surface = try TiledRasterSurface(store: store, referenceView: view)
        #expect(surface.references == refs)
        #expect(surface.revision == RasterRevision(rawValue: 7))
        let lease = try surface.leaseExistingTiles(
            at: [.init(x: 1, y: 0)], pinReasons: [.visible]
        )
        try surface.returnLease(lease)
        #expect(throws: TiledRasterSurfaceError.immutableReferenceView) {
            _ = try surface.reserveTiles(
                at: [.init(x: 0, y: 0)], pinReasons: [.dirty]
            )
        }
    }

    @Test
    func immutableBackingSnapshotNeverSubstitutesReusedPhysicalCoordinate() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: tileBytes * 2)
        let layer = UUID()
        let physical = UUID()
        let size = PixelSize(width: 256, height: 256)
        let old = try seed(
            store: store, surfaceID: physical, layerID: layer,
            generation: 1, size: size, coordinate: .init(x: 0, y: 0)
        )
        let view = try TiledRasterCoordinateReferenceView(
            storeIdentity: store.identity,
            surfaceID: UUID(),
            layerID: layer,
            pixelSize: size,
            generation: 2,
            revision: RasterRevision(rawValue: 1),
            references: [old]
        )
        let immutable = try TiledRasterSurface(store: store, referenceView: view)
        try store.retire(surfaceID: physical, generation: 1)
        let replacement = try seed(
            store: store, surfaceID: physical, layerID: layer,
            generation: 1, size: size, coordinate: .init(x: 0, y: 0)
        )
        #expect(replacement.identity != old.identity)
        #expect(throws: PaintTileStoreError.staleTileReference) {
            _ = try store.snapshot(exactReferences: [old])
        }
        #expect(immutable.backingSnapshot().entries.isEmpty)
    }

    @Test
    func candidateCOWSharesUnchangedReferencesAndOwnsOnlyDirtyCoordinates() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let initial = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [
                .init(x: 0, y: 0), .init(x: 1, y: 0),
            ]]
        )
        let preparedInitial = try registry.prepareCommit(initial)
        registry.commitPrepared(preparedInitial)
        let before = try registry.binding(for: layer).canonical.references

        let candidate = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 1, y: 0)]]
        )
        let after = try candidate.binding(for: layer).canonical.references
        #expect(after.count == 2)
        #expect(after[0] == before[0])
        #expect(after[1].coordinate == before[1].coordinate)
        #expect(after[1].identity != before[1].identity)
        #expect(candidate.ownedReferences == [after[1]])
        #expect(candidate.ownedNamespaces.count == 1)
        #expect(candidate.ownedNamespaces[0].role == .provisional)
        #expect(candidate.ownedNamespaces[0].surfaceID
            == after[1].physicalSurfaceID)
    }

    @Test
    func candidateCanRemoveCoordinateWithoutAllocatingReplacement() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let initial = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]]
        )
        registry.commitPrepared(try registry.prepareCommit(initial))
        let candidate = try registry.makeCandidate(
            removingCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]]
        )
        #expect(try candidate.binding(for: layer).canonical.references.isEmpty)
        #expect(candidate.ownedReferences.isEmpty)
        registry.commitPrepared(try registry.prepareCommit(candidate))
        #expect(try registry.binding(for: layer).canonical.references.isEmpty)
        #expect(registry.sharedTileStore.snapshot().entries.isEmpty)
    }

    @Test
    func commitRetiresReplacedReferenceOnlyAfterOldViewReturnsFinalLease() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let initial = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]]
        )
        registry.commitPrepared(try registry.prepareCommit(initial))
        let oldSurface = try registry.binding(for: layer).canonical
        let oldReference = try #require(oldSurface.references.first)
        let displayLease = try oldSurface.leaseExistingTiles(
            at: [oldReference.coordinate],
            pinReasons: [.visible, .inFlight]
        )

        let replacement = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [oldReference.coordinate]]
        )
        registry.commitPrepared(try registry.prepareCommit(replacement))
        let newReference = try #require(
            registry.binding(for: layer).canonical.references.first
        )
        #expect(newReference.identity != oldReference.identity)
        #expect(registry.sharedTileStore.isRetirementPending(oldReference))
        #expect(registry.sharedTileStore.lookup(
            surfaceID: oldReference.physicalSurfaceID,
            layerID: oldReference.layerID,
            generation: oldReference.physicalGeneration,
            coordinate: oldReference.coordinate
        ) != nil)

        try oldSurface.returnLease(displayLease)
        #expect(!registry.sharedTileStore.isRetirementPending(oldReference))
        #expect(registry.sharedTileStore.lookup(
            surfaceID: oldReference.physicalSurfaceID,
            layerID: oldReference.layerID,
            generation: oldReference.physicalGeneration,
            coordinate: oldReference.coordinate
        ) == nil)
        #expect(registry.sharedTileStore.lookup(
            surfaceID: newReference.physicalSurfaceID,
            layerID: newReference.layerID,
            generation: newReference.physicalGeneration,
            coordinate: newReference.coordinate
        ) != nil)
    }

    @Test
    func geometryCandidateStartsExplicitlyEmptyAndSwapsOrDiscardsAtomically() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let initial = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]]
        )
        registry.commitPrepared(try registry.prepareCommit(initial))
        let oldSurface = try registry.binding(for: layer).canonical
        let oldReference = try #require(oldSurface.references.first)
        let oldLease = try oldSurface.leaseExistingTiles(
            at: [oldReference.coordinate], pinReasons: [.visible]
        )
        let oldSnapshot = registry.snapshot()
        let resizedGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 2_048, height: 512),
            storagePixelSize: PixelSize(width: 2_048, height: 512),
            radialLayout: nil
        )

        let discarded = try registry.makeCandidate(geometry: resizedGeometry)
        #expect(try discarded.binding(for: layer).canonical.references.isEmpty)
        try registry.discard(discarded)
        #expect(registry.snapshot() == oldSnapshot)
        #expect(oldSurface.references == [oldReference])

        let committed = try registry.makeCandidate(geometry: resizedGeometry)
        registry.commitPrepared(try registry.prepareCommit(committed))
        #expect(registry.geometry == resizedGeometry)
        #expect(registry.generation == oldSnapshot.generation + 1)
        #expect(try registry.binding(for: layer).canonical.references.isEmpty)
        #expect(oldSurface.references == [oldReference])
        #expect(registry.sharedTileStore.isRetirementPending(oldReference))
        try oldSurface.returnLease(oldLease)
        #expect(!registry.sharedTileStore.isRetirementPending(oldReference))
    }

    @Test
    func candidateFailureStaleCommitAndDiscardPreserveActiveRegistry() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let before = registry.snapshot()
        #expect(throws: PaintTileStoreError.injectedAllocationFailure(reserveIndex: 0)) {
            _ = try registry.makeCandidate(
                dirtyCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]],
                failureInjection: .init(failingAtReserveIndex: 0)
            )
        }
        #expect(registry.snapshot() == before)

        let first = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]]
        )
        let stale = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 1, y: 0)]]
        )
        registry.commitPrepared(try registry.prepareCommit(first))
        let committed = registry.snapshot()
        #expect(throws: DocumentPaintSurfaceStoreError.staleCandidate(
            expectedGeneration: registry.generation,
            actualGeneration: stale.baseGeneration
        )) {
            _ = try registry.prepareCommit(stale)
        }
        try registry.discard(stale)
        let afterDiscard = registry.snapshot()
        #expect(afterDiscard.generation == committed.generation)
        #expect(afterDiscard.geometry == committed.geometry)
        #expect(afterDiscard.layers == committed.layers)
        #expect(afterDiscard.residentTileBytes < committed.residentTileBytes)
        #expect(throws: DocumentPaintSurfaceStoreError.candidateAlreadyConsumed) {
            try registry.discard(stale)
        }
    }

    @Test
    func preparedCandidateRequiresExplicitSingleUseCommitOrCancellation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let activeBefore = registry.snapshot()
        let candidate = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 0, y: 0)]]
        )
        let owned = try #require(candidate.ownedReferences.first)
        let prepared = try registry.prepareCommit(candidate)
        #expect(registry.snapshot().preparedCandidateCount == 1)
        #expect(throws: DocumentPaintSurfaceStoreError
            .preparedCandidateRequiresExplicitCancellation) {
            try registry.discard(candidate)
        }
        registry.cancelPrepared(prepared)
        #expect(registry.snapshot() == activeBefore)
        #expect(registry.sharedTileStore.lookup(
            surfaceID: owned.physicalSurfaceID,
            layerID: owned.layerID,
            generation: owned.physicalGeneration,
            coordinate: owned.coordinate
        ) == nil)

        // Both terminal APIs are idempotent after the one ownership token was
        // consumed; the cancelled candidate can never publish later.
        registry.commitPrepared(prepared)
        registry.cancelPrepared(prepared)
        #expect(registry.snapshot() == activeBefore)

        let committedCandidate = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [.init(x: 1, y: 0)]]
        )
        let committed = try registry.prepareCommit(committedCandidate)
        registry.commitPrepared(committed)
        let afterCommit = registry.snapshot()
        registry.commitPrepared(committed)
        registry.cancelPrepared(committed)
        #expect(registry.snapshot() == afterCommit)
    }

    @Test
    func candidatePrunesOnlyExactOwnedDirtyReferencesBeforePublication() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let baseCoordinate = PaintTileCoordinate(x: 0, y: 0)
        let firstDirty = PaintTileCoordinate(x: 1, y: 0)
        let secondDirty = PaintTileCoordinate(x: 2, y: 0)

        let initial = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [baseCoordinate]]
        )
        registry.commitPrepared(try registry.prepareCommit(initial))
        let candidate = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [firstDirty, secondDirty]]
        )
        let leasedView = try candidate.binding(for: layer).canonical
        let firstReference = try #require(leasedView.references.first {
            $0.coordinate == firstDirty
        })
        let lease = try leasedView.leaseExistingTiles(
            at: [firstDirty],
            pinReasons: [.visible]
        )
        let initialBytes = registry.sharedTileStore.snapshot().residentByteCount

        #expect(throws: DocumentPaintSurfaceStoreError.unsortedCoordinate(
            previous: secondDirty,
            current: firstDirty
        )) {
            try registry.pruneFullyTransparentCoordinates(
                [secondDirty, firstDirty],
                from: candidate,
                layerID: layer
            )
        }
        #expect(throws: DocumentPaintSurfaceStoreError
            .duplicateCoordinate(firstDirty)) {
            try registry.pruneFullyTransparentCoordinates(
                [firstDirty, firstDirty],
                from: candidate,
                layerID: layer
            )
        }
        #expect(throws: DocumentPaintSurfaceStoreError
            .unownedCandidateCoordinate(baseCoordinate)) {
            try registry.pruneFullyTransparentCoordinates(
                [baseCoordinate],
                from: candidate,
                layerID: layer
            )
        }

        try registry.pruneFullyTransparentCoordinates(
            [firstDirty],
            from: candidate,
            layerID: layer
        )
        let deferred = registry.sharedTileStore.snapshot()
        #expect(deferred.preparedRetirementCount == 0)
        #expect(deferred.pendingRetirementCount == 1)
        #expect(deferred.residentByteCount == initialBytes)
        #expect(candidate.ownedReferences.map(\.coordinate) == [secondDirty])
        #expect(try candidate.binding(for: layer).canonical.references.map(
            \.coordinate
        ) == [baseCoordinate, secondDirty])
        #expect(registry.sharedTileStore.isRetirementPending(firstReference))

        try leasedView.returnLease(lease)
        let returned = registry.sharedTileStore.snapshot()
        #expect(returned.preparedRetirementCount == 0)
        #expect(returned.pendingRetirementCount == 0)
        #expect(returned.residentByteCount == initialBytes - tileBytes)

        try registry.pruneFullyTransparentCoordinates(
            [secondDirty],
            from: candidate,
            layerID: layer
        )
        let fullyPruned = registry.sharedTileStore.snapshot()
        #expect(candidate.ownedReferences.isEmpty)
        #expect(fullyPruned.residentByteCount == initialBytes - tileBytes * 2)
        let beforeEmptyPrune = fullyPruned
        try registry.pruneFullyTransparentCoordinates(
            [],
            from: candidate,
            layerID: layer
        )
        #expect(registry.sharedTileStore.snapshot() == beforeEmptyPrune)

        let prepared = try registry.prepareCommit(candidate)
        #expect(registry.sharedTileStore.snapshot().preparedRetirementCount == 2)
        registry.commitPreparedForCoordinator(prepared)
        #expect(registry.sharedTileStore.snapshot().preparedRetirementCount == 0)
        #expect(try registry.binding(for: layer).canonical.references.map(
            \.coordinate
        ) == [baseCoordinate])
        #expect(throws: DocumentPaintSurfaceStoreError.candidateAlreadyConsumed) {
            _ = try candidate.binding(for: layer)
        }
    }

    @Test
    func candidatePruneRejectsForeignAndStaleCandidatesWithoutMutation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = UUID()
        let registry = try makeRegistry(device: device, layers: [layer])
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let stale = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [coordinate]]
        )
        let winner = try registry.makeCandidate()
        registry.commitPrepared(try registry.prepareCommit(winner))
        let staleSnapshot = registry.sharedTileStore.snapshot()
        #expect(throws: DocumentPaintSurfaceStoreError.staleCandidate(
            expectedGeneration: registry.generation,
            actualGeneration: stale.baseGeneration
        )) {
            try registry.pruneFullyTransparentCoordinates(
                [coordinate],
                from: stale,
                layerID: layer
            )
        }
        #expect(registry.sharedTileStore.snapshot() == staleSnapshot)
        try registry.discard(stale)

        let foreignRegistry = try makeRegistry(device: device, layers: [layer])
        let foreign = try foreignRegistry.makeCandidate(
            dirtyCoordinatesByLayer: [layer: [coordinate]]
        )
        let beforeForeign = registry.sharedTileStore.snapshot()
        #expect(throws: DocumentPaintSurfaceStoreError.foreignCandidate) {
            try registry.pruneFullyTransparentCoordinates(
                [coordinate],
                from: foreign,
                layerID: layer
            )
        }
        #expect(registry.sharedTileStore.snapshot() == beforeForeign)
        try foreignRegistry.discard(foreign)
    }

    @Test
    func retirementDeletesImmediatelyOrAfterFinalLeaseAndCanBeCancelled() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(device: device, byteBudget: tileBytes * 3)
        let layer = UUID()
        let size = PixelSize(width: 768, height: 256)
        let immediate = try seed(
            store: store, surfaceID: UUID(), layerID: layer,
            generation: 1, size: size, coordinate: .init(x: 0, y: 0)
        )
        let deferred = try seed(
            store: store, surfaceID: UUID(), layerID: layer,
            generation: 1, size: size, coordinate: .init(x: 1, y: 0)
        )
        let cancelled = try seed(
            store: store, surfaceID: UUID(), layerID: layer,
            generation: 1, size: size, coordinate: .init(x: 2, y: 0)
        )
        let owner = UUID()
        let lease = try store.reserveReferences(
            [deferred],
            leaseSurfaceID: owner,
            leaseLayerID: layer,
            leaseGeneration: 2,
            pinReasons: [.visible]
        )
        #expect(throws: PaintTileStoreError.outstandingLeases(
            surfaceID: deferred.physicalSurfaceID,
            generation: deferred.physicalGeneration,
            count: 1
        )) {
            try store.retire(
                surfaceID: deferred.physicalSurfaceID,
                generation: deferred.physicalGeneration
            )
        }
        let immediatePlan = try store.prepareRetirement([immediate])
        #expect(store.snapshot().preparedRetirementCount == 1)
        #expect(store.snapshot().pendingRetirementCount == 0)
        store.requestRetirement(immediatePlan)
        #expect(store.snapshot().preparedRetirementCount == 0)
        #expect(store.snapshot().pendingRetirementCount == 0)
        #expect(try store.references(
            surfaceID: immediate.physicalSurfaceID,
            layerID: layer,
            generation: immediate.physicalGeneration
        ).isEmpty)

        let deferredPlan = try store.prepareRetirement([deferred])
        #expect(store.snapshot().preparedRetirementCount == 1)
        store.requestRetirement(deferredPlan)
        #expect(store.snapshot().preparedRetirementCount == 0)
        #expect(store.snapshot().pendingRetirementCount == 1)
        #expect(store.isRetirementPending(deferred))
        try store.release(lease, surfaceID: owner, currentGeneration: 2)
        #expect(store.snapshot().pendingRetirementCount == 0)
        #expect(!store.isRetirementPending(deferred))
        #expect(try store.references(
            surfaceID: deferred.physicalSurfaceID,
            layerID: layer,
            generation: deferred.physicalGeneration
        ).isEmpty)

        let cancelPlan = try store.prepareRetirement([cancelled])
        #expect(store.snapshot().preparedRetirementCount == 1)
        store.cancelRetirement(cancelPlan)
        #expect(store.snapshot().preparedRetirementCount == 0)
        #expect(store.snapshot().pendingRetirementCount == 0)
        #expect(try store.references(
            surfaceID: cancelled.physicalSurfaceID,
            layerID: layer,
            generation: cancelled.physicalGeneration
        ) == [cancelled])
    }

    private func makeRegistry(
        device: any MTLDevice,
        layers: [UUID],
        layerStack: LayerStack? = nil
    ) throws -> DocumentPaintSurfaceStore {
        try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: tileBytes * 16,
            geometry: DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: 1_024, height: 1_024),
                storagePixelSize: PixelSize(width: 1_024, height: 1_024),
                radialLayout: nil
            ),
            layerIDs: layers,
            layerStack: layerStack
        )
    }

    private func seed(
        store: PaintTileStore,
        surfaceID: UUID,
        layerID: UUID,
        generation: UInt64,
        size: PixelSize,
        coordinate: PaintTileCoordinate
    ) throws -> PaintTileReference {
        let lease = try store.reserve(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation,
            pixelSize: size,
            coordinates: [coordinate],
            pinReasons: [.dirty]
        )
        try store.markModified(
            lease, surfaceID: surfaceID, currentGeneration: generation
        )
        try store.release(
            lease, surfaceID: surfaceID, currentGeneration: generation
        )
        return try #require(store.references(
            surfaceID: surfaceID,
            layerID: layerID,
            generation: generation
        ).first)
    }
}

private final class DocumentPaintEpochRaceBarrier: @unchecked Sendable {
    private let target: DocumentPaintSurfaceEpochTestingPoint
    private let reached = DispatchSemaphore(value: 0)
    private let permit = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didReach = false

    init(target: DocumentPaintSurfaceEpochTestingPoint) {
        self.target = target
    }

    lazy var hook: @Sendable (DocumentPaintSurfaceEpochTestingPoint) -> Void = {
        [weak self] point in
        self?.pauseIfTarget(point)
    }

    func waitUntilReached() async throws {
        guard await waitForDocumentPaintSignal(reached) else {
            throw DocumentPaintEpochRaceBarrierError.timeout
        }
    }

    func release() { permit.signal() }

    private func pauseIfTarget(
        _ point: DocumentPaintSurfaceEpochTestingPoint
    ) {
        guard point == target else { return }
        lock.lock()
        let shouldPause = !didReach
        if shouldPause { didReach = true }
        lock.unlock()
        guard shouldPause else { return }
        reached.signal()
        _ = permit.wait(timeout: .now() + 5)
    }
}

private enum DocumentPaintEpochRaceBarrierError: Error {
    case timeout
}

private func waitForDocumentPaintSignal(
    _ semaphore: DispatchSemaphore
) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(
                returning: semaphore.wait(timeout: .now() + 5) == .success
            )
        }
    }
}

private final class OneShotDocumentPaintAction: @unchecked Sendable {
    private let lock = NSLock()
    private var didRun = false
    private var count = 0

    var runCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func run(_ action: () -> Void) {
        lock.lock()
        guard !didRun else {
            lock.unlock()
            return
        }
        didRun = true
        count += 1
        lock.unlock()
        action()
    }
}

private final class RepeatingDocumentPaintPublisher: @unchecked Sendable {
    private let registry: DocumentPaintSurfaceStore
    private let lock = NSLock()
    private var count = 0
    private var failure: String?

    init(registry: DocumentPaintSurfaceStore) {
        self.registry = registry
    }

    var runCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var failureDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    func run() {
        do {
            let candidate = try registry.makeCandidate()
            registry.commitPrepared(try registry.prepareCommit(candidate))
            lock.lock()
            count += 1
            lock.unlock()
        } catch {
            lock.lock()
            failure = String(describing: error)
            lock.unlock()
        }
    }
}
