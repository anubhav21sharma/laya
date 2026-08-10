import CShaderTypes
import EditorCore
import Foundation
@preconcurrency import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Document paint render context", .serialized)
struct DocumentPaintRenderContextTests {
    enum SameSpecificationReplacementState: CaseIterable, Sendable {
        case ready
        case prepared
        case building
    }

    @Test
    @MainActor
    func lockedActiveLayerRejectsStrokeAndClearWithTypedError() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let layerID = UUID()
        let locked = try LayerDescriptor(
            id: layerID,
            name: "Locked",
            isLocked: true
        )
        let context = try DocumentPaintRenderContext(
            device: device,
            commandQueue: queue,
            library: makeShaderLibrary(device: device),
            geometry: try DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: 64, height: 64),
                storagePixelSize: PixelSize(width: 64, height: 64),
                radialLayout: nil
            ),
            initialLayerStack: try LayerStack(
                layers: [locked],
                activeLayerID: layerID
            ),
            byteBudget: PaintTileDescriptor.residentByteCount * 4,
            transferByteCapacity: PaintTileDescriptor.residentByteCount * 4,
            maximumRevisionBytes: PaintTileDescriptor.residentByteCount * 4
        )

        #expect(throws: DocumentPaintRenderContextError
            .activeLayerLocked(layerID)) {
            _ = try context.beginStrokeSurface()
        }
        await #expect(throws: DocumentPaintRenderContextError
            .activeLayerLocked(layerID)) {
            _ = try await context.clear()
        }
        #expect(await context.snapshot().documentGeneration == 0)
    }

    @Test
    @MainActor
    func activeStrokePinsPointerDownLayerAndRejectsStackRetargeting()
        async throws
    {
        guard let fixture = try makeFixture(size: 64) else { return }
        let context = fixture.context
        let capability = try context.beginStrokeSurface()
        #expect(capability.layerID == fixture.layerID)
        var target = context.layerStack
        let added = try LayerDescriptor(id: UUID(), name: "Other")
        try target.add(added, at: 1)
        try target.setActiveLayer(added.id)

        #expect(throws: DocumentPaintRenderContextError.activeStrokeExists) {
            _ = try context.applyLayerStack(target)
        }
        #expect(context.layerStack.activeLayerID == fixture.layerID)
        #expect(capability.layerID == fixture.layerID)
        try context.cancelStrokeSurface(capability)
        let result = try context.applyLayerStack(target)
        #expect(result.after == target)
        try await context.releaseRevisions([result.revision.id])
    }

    @Test
    @MainActor
    func shutdownClosesOwnedLayerHistoryRevision() async throws {
        guard let fixture = try makeFixture(size: 64) else { return }
        var target = fixture.context.layerStack
        try target.rename(fixture.layerID, to: "Renamed")
        let result = try fixture.context.applyLayerStack(target)
        #expect(fixture.context.containsLayerRevision(result.revision.id))

        let shutdown = try await fixture.context.shutdown(
            reason: .sessionReplacement
        )

        #expect(shutdown.isComplete)
        #expect(!fixture.context.containsLayerRevision(result.revision.id))
        #expect(await fixture.context.snapshot().revisionResidentBytes == 0)
    }

    @Test
    @MainActor
    func contextCommandFacadeOwnsCompleteMutationAndRevisionLifecycle()
        async throws
    {
        guard let fixture = try makeFixture(size: 2) else { return }
        let context = fixture.context
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 2, height: 2),
            storagePixelSize: PixelSize(width: 2, height: 2),
            radialLayout: nil
        )
        _ = try await context.importEncodedBGRA8(
            candidateGeometry: geometry,
            input: .singleRaster(.init(
                width: 2,
                height: 2,
                bytesPerRow: 8,
                bytes: Data([
                    0, 0, 255, 255, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0,
                ])
            ))
        )

        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let capability = try context.beginStrokeSurface()
        let frame = try capability.reserveStrokeTiles(
            role: .authoritative,
            coordinates: [coordinate],
            pinReasons: [.dirty, .inFlight],
            workspace: PaintTileStrokeLeaseWorkspace(maximumBindingCount: 1),
            failureInjection: nil
        )
        try capability.testingMarkDirty(frame)
        try capability.releaseFrameReservations(
            authoritative: frame,
            prediction: nil
        )
        let source = try #require(
            try capability.issueCommitMutationSource()
        )
        let stroke = try await context.commitStroke(
            source,
            compositeParameters: .opaqueDraw
        )
        let strokePair = try #require(stroke.historyPair)
        #expect(stroke.didPublish)
        #expect(stroke.generation == 9)
        #expect(capability.isTerminal)
        #expect(await context.snapshot().activeStrokeSurfaceCount == 0)
        try await context.releaseRevisions(strokePair.revisionIDs)

        let cleared = try await context.clear()
        let clearPair = try #require(cleared.historyPair)
        #expect(cleared.generation == 10)
        let restored = try await context.restorePublishedRevision(
            clearPair.before,
            targetGeometry: geometry
        )
        #expect(restored.afterGeneration == 11)
        try await context.releaseRevisions(clearPair.revisionIDs)

        let resizedGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 1, height: 1),
            storagePixelSize: PixelSize(width: 1, height: 1),
            radialLayout: nil
        )
        let resized = try #require(
            try await context.resize(to: resizedGeometry)
        )
        #expect(resized.generation == 12)
        try await context.releaseRevisions([resized.revision.id])
        try await context.retryTransactionCleanup()

        let output = try await context.collectStableFiniteCanonical(
            addressing: .finite(PixelSize(width: 1, height: 1)),
            addressingRevision: 1,
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 1, maxY: 1
            ),
            outputGeometryRevision: 1,
            outputMapping: .affine(.identity)
        )
        #expect(output.bgra8PremultipliedBytes.count == 4)
        for (actual, expected) in zip(
            output.bgra8PremultipliedBytes,
            [UInt8(0), 0, 255, 255]
        ) {
            #expect(abs(Int(actual) - Int(expected)) <= 1)
        }

        let terminal = await context.snapshot()
        #expect(terminal.documentGeneration == 12)
        #expect(terminal.transaction.transaction.state == .idle)
        #expect(terminal.revisionResidentBytes == 0)
        #expect(terminal.activeTileLeaseCount == 0)
        #expect(terminal.activeSnapshotTokenCount == 0)
        #expect(terminal.aggregateSnapshotReferenceCount == 0)

        let shutdown = try await context.shutdown(reason: .sessionReplacement)
        #expect(shutdown.isComplete)
        let repeated = try await context.shutdown(reason: .sessionReplacement)
        #expect(repeated == shutdown)
        #expect(throws: DocumentPaintRenderContextError.isShutdown) {
            _ = try context.beginStrokeSurface()
        }
    }

    @Test
    @MainActor
    func committedStrokeTransfersInstalledTransientOwnershipBeforeImmediateRestore()
        async throws
    {
        guard let fixture = try makeFixture(size: 16) else { return }
        let context = fixture.context
        let capability = try context.beginStrokeSurface()
        let transient = try makeTestingTransientSourceWithTile(
            context,
            capability: capability
        )
        let output = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 16, maxY: 16
        )
        let request = try await context.requestTransientVisiblePlan(
            transient,
            addressingRevision: 1,
            outputRegion: output,
            outputGeometryRevision: 1
        )
        let prepared = try await context.prepareTransientVisiblePlan(request)
        _ = try await context.installVisiblePlan(prepared)
        let mutation = try #require(
            try capability.issueCommitMutationSource()
        )

        let committed = try await context.commitStroke(
            mutation,
            compositeParameters: .opaqueDraw
        )
        let pair = try #require(committed.historyPair)
        _ = try await context.restorePublishedRevision(
            pair.before,
            targetGeometry: try DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: 16, height: 16),
                storagePixelSize: PixelSize(width: 16, height: 16),
                radialLayout: nil
            )
        )
        try await context.releaseRevisions(pair.revisionIDs)

        let canonical = try await self.request(
            context,
            addressing: 2,
            output: 2
        )
        let canonicalPrepared = try await context.prepareVisiblePlan(canonical)
        _ = try await context.installVisiblePlan(canonicalPrepared)
        try await context.retryVisiblePlanRetirementsAndCompletions()
        #expect(transient.acknowledgementStatus == .fulfilled)
        let terminal = await context.snapshot()
        #expect(terminal.revisionResidentBytes == 0)
        #expect(terminal.activeStrokeSurfaceCount == 0)
        #expect(terminal.activeCommandOperationCount == 0)
    }

    @Test
    @MainActor
    func preCancelledStrokeCommandTerminalizesSourceAndImmediatelyReusesContext()
        async throws
    {
        guard let fixture = try makeFixture(size: 2) else { return }
        let context = fixture.context
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let capability = try context.beginStrokeSurface()
        let frame = try capability.reserveStrokeTiles(
            role: .authoritative,
            coordinates: [coordinate],
            pinReasons: [.dirty, .inFlight],
            workspace: PaintTileStrokeLeaseWorkspace(maximumBindingCount: 1),
            failureInjection: nil
        )
        try capability.testingMarkDirty(frame)
        try capability.releaseFrameReservations(
            authoritative: frame,
            prediction: nil
        )
        let source = try #require(
            try capability.issueCommitMutationSource()
        )

        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await context.commitStroke(
                source,
                compositeParameters: .opaqueDraw
            )
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        let cancelled = await context.snapshot()
        #expect(capability.isTerminal)
        #expect(cancelled.activeStrokeSurfaceCount == 0)
        #expect(cancelled.documentGeneration == 7)
        #expect(cancelled.transaction.transaction.state == .idle)
        #expect(cancelled.activeTileLeaseCount == 0)

        let immediate = try context.beginStrokeSurface()
        try context.cancelStrokeSurface(immediate)
        #expect(await context.snapshot().activeStrokeSurfaceCount == 0)
    }

    @Test
    @MainActor
    func encodedImportPublishesAtomicallyAndImmediatelyReusesWorker() async throws {
        guard let fixture = try makeFixture(size: 2) else { return }
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 2, height: 2),
            storagePixelSize: PixelSize(width: 2, height: 2),
            radialLayout: nil
        )
        let bytes = Data([
            0, 0, 128, 128, 9, 7, 5, 0,
            1, 2, 3, 255, 0, 0, 0, 0,
        ])

        let first = try await fixture.context.importEncodedBGRA8(
            candidateGeometry: geometry,
            input: .singleRaster(.init(
                width: 2,
                height: 2,
                bytesPerRow: 8,
                bytes: bytes
            ))
        )
        let second = try await fixture.context.importEncodedBGRA8(
            candidateGeometry: geometry,
            input: .singleRaster(.init(
                width: 2,
                height: 2,
                bytesPerRow: 8,
                bytes: bytes
            ))
        )
        let output = try await fixture.context.collectStableFiniteCanonical(
            addressing: .finite(PixelSize(width: 2, height: 2)),
            addressingRevision: 1,
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 2, maxY: 2
            ),
            outputGeometryRevision: 1,
            outputMapping: .affine(.identity)
        )
        let snapshot = await fixture.context.snapshot()

        #expect(first.didPublish)
        #expect(second.didPublish)
        #expect(output.bgra8PremultipliedBytes.count == bytes.count)
        let sanitized = Data([
            0, 0, 128, 128, 0, 0, 0, 0,
            1, 2, 3, 255, 0, 0, 0, 0,
        ])
        for (actual, expected) in zip(
            output.bgra8PremultipliedBytes,
            sanitized
        ) {
            #expect(abs(Int(actual) - Int(expected)) <= 1)
        }
        #expect(snapshot.documentGeneration == 9)
        #expect(snapshot.transaction.transaction.state == .idle)
        #expect(snapshot.activeTileLeaseCount == 0)
    }

    @Test
    @MainActor
    func encodedImportRejectsActiveStrokeBeforeTransactionOwnership() async throws {
        guard let fixture = try makeFixture(size: 2) else { return }
        let capability = try fixture.context.beginStrokeSurface()
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 2, height: 2),
            storagePixelSize: PixelSize(width: 2, height: 2),
            radialLayout: nil
        )
        await #expect(throws: DocumentPaintRenderContextError.activeStrokeExists) {
            _ = try await fixture.context.importEncodedBGRA8(
                candidateGeometry: geometry,
                input: .singleRaster(.init(
                    width: 2,
                    height: 2,
                    bytesPerRow: 8,
                    bytes: Data(repeating: 0, count: 16)
                ))
            )
        }
        #expect(await fixture.context.snapshot().transaction.transaction.state
            == .idle)
        try fixture.context.cancelStrokeSurface(capability)
    }

    @Test
    @MainActor
    func commandClaimBlocksStrokeAdmissionAcrossSuspendedValidation()
        async throws
    {
        guard let fixture = try makeFixture(size: 2) else { return }
        let side = 4_096
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: side, height: side),
            storagePixelSize: PixelSize(width: side, height: side),
            radialLayout: nil
        )
        let importTask = Task { @MainActor in
            try await fixture.context.importEncodedBGRA8(
                candidateGeometry: geometry,
                input: .singleRaster(.init(
                    width: side,
                    height: side,
                    bytesPerRow: side * 4,
                    bytes: Data(repeating: 0, count: side * side * 4)
                ))
            )
        }

        var observedClaim = false
        for _ in 0..<10_000 {
            if await fixture.context.snapshot()
                .activeCommandOperationCount == 1 {
                observedClaim = true
                break
            }
            await Task.yield()
        }
        #expect(observedClaim)
        #expect(throws: DocumentPaintRenderContextError
            .activeCommandOperationExists) {
            _ = try fixture.context.beginStrokeSurface()
        }

        importTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await importTask.value
        }
        let terminal = await fixture.context.snapshot()
        #expect(terminal.activeCommandOperationCount == 0)
        #expect(terminal.transaction.transaction.state == .idle)
        #expect(terminal.activeTileLeaseCount == 0)

        let capability = try fixture.context.beginStrokeSurface()
        try fixture.context.cancelStrokeSurface(capability)
    }

    @Test
    @MainActor
    func radialImportPublishesLogicalPagesWithoutBuildingAnAtlasInput()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let layout = try RadialSectorLayout(
            maximumRadius: 384,
            sectorAngleRadians: .pi
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 768, height: 768),
            storagePixelSize: layout.atlasPixelSize,
            radialLayout: layout
        )
        let context = try DocumentPaintRenderContext(
            device: device,
            commandQueue: queue,
            library: makeShaderLibrary(device: device),
            geometry: geometry,
            initialLayerStack: try .single(id: UUID()),
            byteBudget: PaintTileDescriptor.residentByteCount
                * layout.residentPages.count,
            transferByteCapacity: PaintTileDescriptor.residentByteCount
                * max(8, layout.residentPages.count + 2),
            maximumRevisionBytes: PaintTileDescriptor.residentByteCount * 8
        )
        var pageBytes = Data(count: 256 * 256 * 4)
        pageBytes.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                bytes[offset] = 7
                bytes[offset + 1] = 11
                bytes[offset + 2] = 19
                bytes[offset + 3] = 128
            }
        }

        _ = try await context.importEncodedBGRA8(
            candidateGeometry: geometry,
            input: .radialPages(layout.residentPages.reversed().map { page in
                .init(
                    coordinate: page.coordinate,
                    plane: .init(
                    width: 256,
                    height: 256,
                    bytesPerRow: 1024,
                    bytes: pageBytes
                )
                )
            })
        )
        let collected = try await context.collectStableCommittedStorage(
            addressing: .radial(layout: layout),
            addressingRevision: 1,
            outputGeometryRevision: 1
        )
        guard case let .radialPages(pages) = collected.storage else {
            Issue.record("radial import must remain logical sparse pages")
            return
        }
        #expect(pages.count == layout.residentPages.count)
        #expect(pages.map(\.coordinate) == layout.residentPages
            .map(\.coordinate).sorted())
        for restored in pages {
            #expect(restored.image.bgra8PremultipliedBytes.count
                == pageBytes.count)
            for (actual, expected) in zip(
                restored.image.bgra8PremultipliedBytes,
                pageBytes
            ) {
                #expect(abs(Int(actual) - Int(expected)) <= 1)
            }
        }
        let terminal = await context.snapshot()
        #expect(terminal.transaction.transaction.state == .idle)
        #expect(terminal.activeTileLeaseCount == 0)
        #expect(terminal.aggregateSnapshotReferenceCount == 0)
    }

    @Test
    @MainActor
    func preCancelledImportOwnsNothingAndAllowsImmediateReuse() async throws {
        guard let fixture = try makeFixture(size: 2) else { return }
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 2, height: 2),
            storagePixelSize: PixelSize(width: 2, height: 2),
            radialLayout: nil
        )
        let input = DocumentPaintEncodedImportInput.singleRaster(.init(
            width: 2,
            height: 2,
            bytesPerRow: 8,
            bytes: Data(repeating: 0, count: 16)
        ))
        let task = Task { @MainActor in
            try await fixture.context.importEncodedBGRA8(
                candidateGeometry: geometry,
                input: input
            )
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        let cancelled = await fixture.context.snapshot()
        #expect(cancelled.documentGeneration == 7)
        #expect(cancelled.transaction.transaction.state == .idle)
        #expect(cancelled.activeTileLeaseCount == 0)

        let retry = try await fixture.context.importEncodedBGRA8(
            candidateGeometry: geometry,
            input: input
        )
        #expect(!retry.didPublish)
        #expect(await fixture.context.snapshot().transaction.transaction.state
            == .idle)
    }

    @Test
    @MainActor
    func ownsOnePrivateEmptySparseDocumentGraph() async throws {
        guard let fixture = try makeFixture(size: 4_096) else { return }
        let snapshot = await fixture.context.snapshot()

        #expect(snapshot.activeLayerID == fixture.layerID)
        #expect(snapshot.layerIDs == [fixture.layerID])
        #expect(snapshot.documentGeneration == 7)
        #expect(snapshot.tileByteBudget == fixture.byteBudget)
        #expect(snapshot.residentTileBytes == 0)
        #expect(snapshot.backingTileBytes == 0)
        #expect(snapshot.activeSnapshotTokenCount == 0)
        #expect(snapshot.aggregateSnapshotReferenceCount == 0)
        #expect(snapshot.revisionResidentBytes == 0)
        #expect(snapshot.activeStrokeSurfaceCount == 0)
        #expect(snapshot.transaction.transaction.state == .idle)
        #expect(snapshot.visiblePlan.currentPlanIdentity == nil)
        #expect(snapshot.visiblePlan.uploadRing == nil)
    }

    @Test
    @MainActor
    func explicitSnapshotLiabilityBudgetReachesProductionRoot() throws {
        let liabilityBudget = PaintTileDescriptor.residentByteCount * 3
        guard let fixture = try makeFixture(
            snapshotPayloadLiabilityByteBudget: liabilityBudget
        ) else { return }

        #expect(
            fixture.context.testingSnapshotPayloadLiabilityByteBudget
                == liabilityBudget
        )
    }

    @Test
    @MainActor
    func exposesStableCanonicalSnapshotFromActiveLayer() async throws {
        guard let fixture = try makeFixture(size: 256) else { return }
        let snapshot = try fixture.context.captureStableCanonicalSnapshot(
            addressing: .finite(PixelSize(width: 256, height: 256)),
            addressingRevision: 23,
            limits: .init(maximumActiveChildSelections: 1)
        )
        #expect(snapshot.documentGeneration == 7)
        #expect(snapshot.layerID == fixture.layerID)
        #expect(snapshot.addressingRevision == 23)
        #expect(snapshot.referenceCount == 0)
        snapshot.close()
        #expect(await fixture.context.snapshot().activeSnapshotTokenCount == 0)
    }

    @Test
    @MainActor
    func droppedAndSupersededUnpreparedTransientRequestsRetainThenSettleDebt()
        async throws
    {
        guard let fixture = try makeFixture(size: 256) else { return }
        let context = fixture.context
        let capability = try context.beginStrokeSurface()
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
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
        let source = try context.adoptTransientDisplayFrame(
            .testing(
                capability: capability,
                layer: .authoritative,
                changedCoordinates: [coordinate],
                acknowledgementIsAvailable: true
            ),
            addressing: .finite(PixelSize(width: 256, height: 256))
        )
        let output = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 256, maxY: 256
        )

        var dropped: DocumentPaintTransientVisiblePlanRequest? = try await
            context.requestTransientVisiblePlan(
                source,
                addressingRevision: 1,
                outputRegion: output,
                outputGeometryRevision: 1
            )
        #expect(await context.snapshot().activeSnapshotTokenCount == 1)
        dropped = nil
        #expect(dropped == nil)
        #expect(await context.snapshot().activeSnapshotTokenCount == 1)

        let stale = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 2,
            outputRegion: output,
            outputGeometryRevision: 1
        )
        _ = try await context.requestCanonicalVisiblePlan(
            addressing: .finite(PixelSize(width: 256, height: 256)),
            addressingRevision: 3,
            outputRegion: output,
            outputGeometryRevision: 1
        )
        await #expect(
            throws: DocumentPaintVisiblePlanControllerError.staleRequest
        ) {
            _ = try await context.prepareTransientVisiblePlan(stale)
        }
        let afterSupersession = await context.snapshot()
        #expect(afterSupersession.activeSnapshotTokenCount == 0)
        #expect(afterSupersession.aggregateSnapshotReferenceCount == 0)

        try context.testingReleaseTransientDisplaySourceWithoutAcknowledgement(
            source
        )
        try context.cancelStrokeSurface(capability)
    }

    @Test
    @MainActor
    func explicitCancelSettlesUnpreparedTransientRequestExactlyOnce()
        async throws
    {
        guard let fixture = try makeFixture(size: 256) else { return }
        let context = fixture.context
        let capability = try context.beginStrokeSurface()
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
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
        let source = try context.adoptTransientDisplayFrame(
            .testing(
                capability: capability,
                layer: .authoritative,
                changedCoordinates: [coordinate],
                acknowledgementIsAvailable: true
            ),
            addressing: .finite(PixelSize(width: 256, height: 256))
        )
        let output = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 256, maxY: 256
        )
        let transientRequest = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 1,
            outputRegion: output,
            outputGeometryRevision: 1
        )

        #expect(await context.snapshot().activeSnapshotTokenCount == 1)
        try await context.cancelVisiblePlanRequest(transientRequest)
        #expect(await context.snapshot().activeSnapshotTokenCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        await #expect(
            throws: DocumentPaintVisiblePlanControllerError.staleRequest
        ) {
            try await context.cancelVisiblePlanRequest(transientRequest)
        }
        await #expect(
            throws: DocumentPaintVisiblePlanControllerError
                .transientSourceNotAvailable
        ) {
            _ = try await context.requestTransientVisiblePlan(
                source,
                addressingRevision: 2,
                outputRegion: output,
                outputGeometryRevision: 1
            )
        }

        try context.cancelStrokeSurface(capability)
    }

    @Test
    @MainActor
    func sameSourceRerequestNeverACKsUntilFinalUseEnds() async throws {
        guard let fixture = try makeFixture() else { return }
        let context = fixture.context
        let capability = try context.beginStrokeSurface()
        let source = try makeTestingTransientSourceWithTile(
            context,
            capability: capability
        )
        let output = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 16, maxY: 16
        )

        _ = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 1,
            outputRegion: output,
            outputGeometryRevision: 1
        )
        let latest = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 2,
            outputRegion: output,
            outputGeometryRevision: 1
        )
        #expect(source.testingAcknowledgementRequestCount == 0)
        #expect(source.acknowledgementStatus == .available)
        #expect(await context.snapshot().activeSnapshotTokenCount == 1)

        try await context.cancelVisiblePlanRequest(latest)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        #expect(await context.snapshot().activeSnapshotTokenCount == 0)
        try context.cancelStrokeSurface(capability)
    }

    @Test
    @MainActor
    func repeatedSameSourcePlanRebuildsLeaveNoDeadRetiringPlans()
        async throws
    {
        guard let fixture = try makeFixture() else { return }
        let context = fixture.context
        let capability = try context.beginStrokeSurface()
        let source = try makeTestingTransientSourceWithTile(
            context,
            capability: capability
        )
        let output = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 16, maxY: 16
        )
        for revision in UInt64(1)...UInt64(12) {
            let request = try await context.requestTransientVisiblePlan(
                source,
                addressingRevision: revision,
                outputRegion: output,
                outputGeometryRevision: 1
            )
            let prepared = try await context.prepareTransientVisiblePlan(request)
            _ = try await context.installVisiblePlan(prepared)
            #expect(await context.snapshot().visiblePlan.retiringPlanCount == 0)
            #expect(source.testingAcknowledgementRequestCount == 0)
        }

        let canonical = try await request(context, addressing: 20, output: 1)
        let prepared = try await context.prepareVisiblePlan(canonical)
        _ = try await context.installVisiblePlan(prepared)
        #expect(await context.snapshot().visiblePlan.retiringPlanCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        try context.cancelStrokeSurface(capability)
    }

    @Test
    @MainActor
    func concurrentDuplicatePrepareConsumesRequestOnlyOnce() async throws {
        let gate = DocumentPaintPreparationTestGate()
        var configuration = DocumentPaintVisiblePlanControllerConfiguration.production
        configuration.planBuildGate = gate
        guard let fixture = try makeFixture(configuration: configuration) else {
            return
        }
        let request = try await request(
            fixture.context,
            addressing: 1,
            output: 1
        )
        let first = Task { @MainActor in
            try await fixture.context.prepareVisiblePlan(request)
        }
        for _ in 0..<1_000 {
            if await gate.waitingCount == 1 { break }
            await Task.yield()
        }
        await #expect(
            throws: DocumentPaintVisiblePlanControllerError.staleRequest
        ) {
            _ = try await fixture.context.prepareVisiblePlan(request)
        }
        await gate.open()
        let prepared = try await first.value
        _ = try await fixture.context.installVisiblePlan(prepared)
        #expect(await fixture.context.snapshot().visiblePlan.currentIsPresentable)
    }

    @Test
    @MainActor
    func suspendedTransientBuildSupersessionSettlesAfterResume()
        async throws
    {
        let gate = DocumentPaintPreparationTestGate()
        var configuration = DocumentPaintVisiblePlanControllerConfiguration.production
        configuration.planBuildGate = gate
        guard let fixture = try makeFixture(configuration: configuration) else {
            return
        }
        let capability = try fixture.context.beginStrokeSurface()
        let source = try makeTestingTransientSourceWithTile(
            fixture.context,
            capability: capability
        )
        let transient = try await fixture.context.requestTransientVisiblePlan(
            source,
            addressingRevision: 1,
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 16, maxY: 16
            ),
            outputGeometryRevision: 1
        )
        let first = Task { @MainActor in
            try await fixture.context.prepareTransientVisiblePlan(transient)
        }
        for _ in 0..<1_000 {
            if await gate.waitingCount == 1 { break }
            await Task.yield()
        }
        let replacement = try await request(
            fixture.context,
            addressing: 2,
            output: 1
        )
        #expect(await fixture.context.snapshot().activeSnapshotTokenCount == 1)
        #expect(source.testingAcknowledgementRequestCount == 0)
        await gate.open()
        await #expect(
            throws: DocumentPaintVisiblePlanControllerError.staleRequest
        ) {
            _ = try await first.value
        }
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        #expect(await fixture.context.snapshot().activeSnapshotTokenCount == 0)
        let replacementPrepared = try await fixture.context
            .prepareVisiblePlan(replacement)
        _ = try await fixture.context.installVisiblePlan(replacementPrepared)
        #expect(await fixture.context.snapshot().visiblePlan.currentIsPresentable)
        try fixture.context.cancelStrokeSurface(capability)
    }

    @Test
    @MainActor
    func controllerRejectionAfterRegistryCaptureClosesExactDebt()
        async throws
    {
        guard let fixture = try makeFixture() else { return }
        let capability = try fixture.context.beginStrokeSurface()
        let source = try makeTestingTransientSourceWithTile(
            fixture.context,
            capability: capability
        )
        let controller = try await fixture.context
            .testingShutdownVisiblePlanControllerOnly()
        #expect(controller.isComplete)

        await #expect(
            throws: DocumentPaintVisiblePlanControllerError.shuttingDown
        ) {
            _ = try await fixture.context.requestTransientVisiblePlan(
                source,
                addressingRevision: 1,
                outputRegion: try SparseTileOutputRegion(
                    minX: 0, minY: 0, maxX: 16, maxY: 16
                ),
                outputGeometryRevision: 1
            )
        }
        let rejected = await fixture.context.snapshot()
        #expect(rejected.activeSnapshotTokenCount == 0)
        #expect(rejected.aggregateSnapshotReferenceCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 0)
        #expect(source.acknowledgementStatus == .available)

        try await fixture.context.abandonTransientDisplaySource(source)
        #expect(source.acknowledgementStatus == .fulfilled)
        try fixture.context.cancelStrokeSurface(capability)
    }

    @Test
    @MainActor
    func unrequestedAdoptedSourceShutdownACKsBeforeCapabilityCancel()
        async throws
    {
        guard let fixture = try makeFixture() else { return }
        let capability = try fixture.context.beginStrokeSurface()
        let source = try makeTestingTransientSourceWithTile(
            fixture.context,
            capability: capability
        )
        let shutdown = try await fixture.context.shutdown(
            reason: .sessionReplacement
        )
        #expect(shutdown.isComplete)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        #expect(capability.isTerminal)
    }

    @Test
    @MainActor
    func transientBuildFailureClosesCaptureRetriesACKAndRemainsReusable()
        async throws
    {
        guard let fixture = try makeFixture() else { return }
        let capability = try fixture.context.beginStrokeSurface()
        let source = try makeTestingTransientSourceWithTile(
            fixture.context,
            capability: capability,
            acknowledgementReleaseFailures: [
                .unexpected("injected build-failure ACK failure")
            ]
        )
        let transient = try await fixture.context.requestTransientVisiblePlan(
            source,
            addressingRevision: 1,
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 16, maxY: 16
            ),
            outputGeometryRevision: 1
        )
        await #expect(throws: SparseTileSamplingPlanError.invalidLimit) {
            _ = try await fixture.context.prepareTransientVisiblePlan(
                transient,
                limits: invalidLimits
            )
        }
        let failed = await fixture.context.snapshot()
        #expect(failed.activeSnapshotTokenCount == 0)
        #expect(failed.visiblePlan.transientAcknowledgementFailureCount == 1)
        #expect(source.testingAcknowledgementRequestCount == 1)

        try await fixture.context.retryVisiblePlanRetirementsAndCompletions()
        #expect(source.acknowledgementStatus == .fulfilled)
        #expect(source.testingAcknowledgementRequestCount == 2)
        let canonical = try await request(
            fixture.context,
            addressing: 2,
            output: 1
        )
        let prepared = try await fixture.context.prepareVisiblePlan(canonical)
        _ = try await fixture.context.installVisiblePlan(prepared)
        #expect(await fixture.context.snapshot().visiblePlan.currentIsPresentable)
        try fixture.context.cancelStrokeSurface(capability)
    }

    @Test
    @MainActor
    func requestedReadyTransientShutdownSettlesCaptureAndACK() async throws {
        guard let fixture = try makeFixture() else { return }
        let capability = try fixture.context.beginStrokeSurface()
        let source = try makeTestingTransientSourceWithTile(
            fixture.context,
            capability: capability
        )
        _ = try await fixture.context.requestTransientVisiblePlan(
            source,
            addressingRevision: 1,
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 16, maxY: 16
            ),
            outputGeometryRevision: 1
        )
        #expect(await fixture.context.snapshot().activeSnapshotTokenCount == 1)
        let result = try await fixture.context.shutdown(
            reason: .sessionReplacement
        )
        #expect(result.isComplete)
        #expect(source.acknowledgementStatus == .fulfilled)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(await fixture.context.snapshot().activeSnapshotTokenCount == 0)
        #expect(capability.isTerminal)
    }

    @Test
    @MainActor
    func requestedReadyShutdownRetainsFailedACKUntilRetry() async throws {
        guard let fixture = try makeFixture() else { return }
        let capability = try fixture.context.beginStrokeSurface()
        let source = try makeTestingTransientSourceWithTile(
            fixture.context,
            capability: capability,
            acknowledgementReleaseFailures: [
                .unexpected("first shutdown ACK failure"),
                .unexpected("second shutdown ACK failure"),
            ]
        )
        _ = try await fixture.context.requestTransientVisiblePlan(
            source,
            addressingRevision: 1,
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 16, maxY: 16
            ),
            outputGeometryRevision: 1
        )
        let first = try await fixture.context.shutdown(
            reason: .sessionReplacement
        )
        #expect(!first.isComplete)
        #expect(source.testingAcknowledgementRequestCount == 2)
        #expect(await fixture.context.snapshot().activeSnapshotTokenCount == 0)
        let complete = try await fixture.context.shutdown(
            reason: .sessionReplacement
        )
        #expect(complete.isComplete)
        #expect(source.testingAcknowledgementRequestCount == 3)
        #expect(source.acknowledgementStatus == .fulfilled)
        #expect(capability.isTerminal)
    }

    @Test
    @MainActor
    func oldTransientGPUTerminalCannotClearSameKeyReplacementRequest()
        async throws
    {
        guard let fixture = try makeFixture() else { return }
        let context = fixture.context
        let capability = try context.beginStrokeSurface()
        let source = try makeTestingTransientSourceWithTile(
            context,
            capability: capability
        )
        let initial = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 1,
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 16, maxY: 16
            ),
            outputGeometryRevision: 1
        )
        let initialPrepared = try await context
            .prepareTransientVisiblePlan(initial)
        _ = try await context.installVisiblePlan(initialPrepared)
        let oldSubmission = try await context.prepareDisplaySubmission()
        let target = try makeTarget(device: fixture.device)
        let command = try #require(fixture.queue.makeCommandBuffer())
        try context.encodeDisplaySubmission(
            oldSubmission,
            target: target,
            commandBuffer: command,
            renderPassDescriptor: passDescriptor(target: target)
        )
        let replacement = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 1,
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 16, maxY: 16
            ),
            outputGeometryRevision: 1
        )
        #expect(await context.snapshot().visiblePlan.requestedSpecification
            == replacement.specification)
        #expect(await context.snapshot().activeSnapshotTokenCount == 1)
        #expect(source.testingAcknowledgementRequestCount == 0)

        command.commit()
        await command.completed()
        let afterOldTerminal = await context.snapshot()
        #expect(afterOldTerminal.visiblePlan.requestedSpecification
            == replacement.specification)
        #expect(afterOldTerminal.activeSnapshotTokenCount == 1)
        #expect(source.testingAcknowledgementRequestCount == 0)

        let prepared = try await context.prepareTransientVisiblePlan(replacement)
        _ = try await context.installVisiblePlan(prepared)
        #expect(await context.snapshot().visiblePlan.currentIsPresentable)
        #expect(await context.snapshot().activeSnapshotTokenCount == 0)

        let canonical = try await request(context, addressing: 2, output: 1)
        let canonicalPrepared = try await context.prepareVisiblePlan(canonical)
        _ = try await context.installVisiblePlan(canonicalPrepared)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        let terminal = await context.snapshot()
        #expect(terminal.activeSnapshotTokenCount == 0)
        #expect(terminal.aggregateSnapshotReferenceCount == 0)
        try context.cancelStrokeSurface(capability)
    }

    @Test
    @MainActor
    func cancelPreparedTransientRequestRetiresPlanAndACKsExactlyOnce()
        async throws
    {
        guard let fixture = try makeFixture() else { return }
        let context = fixture.context
        let capability = try context.beginStrokeSurface()
        let source = try makeTestingTransientSourceWithTile(
            context,
            capability: capability
        )
        let transientRequest = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 1,
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 16, maxY: 16
            ),
            outputGeometryRevision: 1
        )
        let prepared = try await context.prepareTransientVisiblePlan(
            transientRequest
        )
        #expect(await context.snapshot().visiblePlan.preparedPlanCount == 1)

        try await context.cancelVisiblePlanRequest(transientRequest)
        let cancelled = await context.snapshot()
        #expect(cancelled.visiblePlan.preparedPlanCount == 0)
        #expect(cancelled.visiblePlan.retiringPlanCount == 0)
        #expect(cancelled.visiblePlan.transientAcknowledgementPendingCount == 0)
        #expect(cancelled.visiblePlan.transientAcknowledgementFailureCount == 0)
        #expect(cancelled.activeSnapshotTokenCount == 0)
        #expect(cancelled.aggregateSnapshotReferenceCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        await #expect(
            throws: DocumentPaintVisiblePlanControllerError.stalePreparedPlan
        ) {
            _ = try await context.installVisiblePlan(prepared)
        }
        try await context.retryVisiblePlanRetirementsAndCompletions()
        #expect(source.testingAcknowledgementRequestCount == 1)
        try context.cancelStrokeSurface(capability)
    }

    @Test
    @MainActor
    func cancelInstalledTransientRequestRetiresCurrentAndACKsExactlyOnce()
        async throws
    {
        guard let fixture = try makeFixture() else { return }
        let context = fixture.context
        let capability = try context.beginStrokeSurface()
        let source = try makeTestingTransientSourceWithTile(
            context,
            capability: capability
        )
        let transientRequest = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 1,
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 16, maxY: 16
            ),
            outputGeometryRevision: 1
        )
        let prepared = try await context.prepareTransientVisiblePlan(
            transientRequest
        )
        _ = try await context.installVisiblePlan(prepared)
        let unsubmittedDisplay = try await context.prepareDisplaySubmission()
        #expect(await context.snapshot().visiblePlan.currentPlanIdentity != nil)

        try await context.cancelVisiblePlanRequest(transientRequest)
        let cancelled = await context.snapshot()
        #expect(cancelled.visiblePlan.currentPlanIdentity == nil)
        #expect(cancelled.visiblePlan.preparedPlanCount == 0)
        #expect(cancelled.visiblePlan.retiringPlanCount == 0)
        #expect(cancelled.activeSnapshotTokenCount == 0)
        #expect(cancelled.aggregateSnapshotReferenceCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        #expect(
            throws: DocumentPaintVisiblePlanControllerError
                .submissionAlreadyConsumed
        ) {
            try context.cancelDisplaySubmission(unsubmittedDisplay)
        }
        try await context.retryVisiblePlanRetirementsAndCompletions()
        #expect(source.testingAcknowledgementRequestCount == 1)

        let nextSource = try await installTestingTransientPlan(
            context,
            capability: capability
        )
        #expect(nextSource.acknowledgementStatus == .available)
        #expect(await context.snapshot().visiblePlan.currentIsPresentable)
        let canonical = try await request(context, addressing: 2, output: 1)
        let canonicalPrepared = try await context.prepareVisiblePlan(canonical)
        _ = try await context.installVisiblePlan(canonicalPrepared)
        #expect(nextSource.testingAcknowledgementRequestCount == 1)
        #expect(nextSource.acknowledgementStatus == .fulfilled)
        try context.cancelStrokeSurface(capability)
    }

    @Test(arguments: SameSpecificationReplacementState.allCases)
    @MainActor
    func cancellingSameSpecificationReplacementRestoresExactCurrentFallback(
        _ state: SameSpecificationReplacementState
    ) async throws {
        let gate = DocumentPaintPreparationTestGate()
        var configuration = DocumentPaintVisiblePlanControllerConfiguration
            .production
        configuration.planBuildGate = gate
        guard let fixture = try makeFixture(configuration: configuration) else {
            return
        }
        let context = fixture.context
        let capability = try context.beginStrokeSurface()
        let source = try makeTestingTransientSourceWithTile(
            context,
            capability: capability
        )
        let output = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 16, maxY: 16
        )
        await gate.open()
        let initial = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 1,
            outputRegion: output,
            outputGeometryRevision: 1
        )
        let initialPrepared = try await context.prepareTransientVisiblePlan(
            initial
        )
        _ = try await context.installVisiblePlan(initialPrepared)
        let initialIdentity = try #require(
            await context.snapshot().visiblePlan.currentPlanIdentity
        )

        if state == .building { await gate.close() }
        let replacement = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 1,
            outputRegion: output,
            outputGeometryRevision: 1
        )
        var replacementPrepared:
            DocumentPaintPreparedVisiblePlanToken?
        var replacementBuild:
            Task<DocumentPaintPreparedVisiblePlanToken, any Error>?
        switch state {
        case .ready:
            replacementPrepared = nil
            replacementBuild = nil
        case .prepared:
            replacementPrepared = try await context
                .prepareTransientVisiblePlan(replacement)
            replacementBuild = nil
        case .building:
            replacementPrepared = nil
            replacementBuild = Task { @MainActor in
                try await context.prepareTransientVisiblePlan(replacement)
            }
            var waitingCount = 0
            for _ in 0..<1_000 {
                waitingCount = await gate.waitingCount
                if waitingCount == 1 { break }
                await Task.yield()
            }
            #expect(waitingCount == 1)
        }

        try await context.cancelVisiblePlanRequest(replacement)
        let restored = await context.snapshot().visiblePlan
        #expect(restored.currentPlanIdentity == initialIdentity)
        #expect(restored.currentIsPresentable)
        #expect(restored.requestedSpecification == initial.specification)
        #expect(source.testingAcknowledgementRequestCount == 0)
        #expect(source.acknowledgementStatus == .available)
        let fallbackDisplay = try await context.prepareDisplaySubmission()

        if let replacementPrepared {
            await #expect(
                throws: DocumentPaintVisiblePlanControllerError
                    .stalePreparedPlan
            ) {
                _ = try await context.installVisiblePlan(replacementPrepared)
            }
        }
        if let replacementBuild {
            await gate.open()
            await #expect(
                throws: DocumentPaintVisiblePlanControllerError.staleRequest
            ) {
                _ = try await replacementBuild.value
            }
        }

        try await context.cancelVisiblePlanRequest(initial)
        let terminal = await context.snapshot()
        #expect(terminal.visiblePlan.currentPlanIdentity == nil)
        #expect(terminal.visiblePlan.preparedPlanCount == 0)
        #expect(terminal.visiblePlan.retiringPlanCount == 0)
        #expect(terminal.visiblePlan.transientAcknowledgementOwnedCount == 0)
        #expect(terminal.activeSnapshotTokenCount == 0)
        #expect(terminal.aggregateSnapshotReferenceCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        #expect(
            throws: DocumentPaintVisiblePlanControllerError
                .submissionAlreadyConsumed
        ) {
            try context.cancelDisplaySubmission(fallbackDisplay)
        }
        try context.cancelStrokeSurface(capability)
    }

    @Test
    @MainActor
    func cancellingReadyReplacementRetiresSupersededCurrentAndReusesFrame()
        async throws
    {
        guard let fixture = try makeFixture() else { return }
        let context = fixture.context
        let capability = try context.beginStrokeSurface()
        let source = try makeTestingTransientSourceWithTile(
            context,
            capability: capability
        )
        let output = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 16, maxY: 16
        )
        let initial = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 1,
            outputRegion: output,
            outputGeometryRevision: 1
        )
        let initialPrepared = try await context.prepareTransientVisiblePlan(
            initial
        )
        _ = try await context.installVisiblePlan(initialPrepared)

        let replacement = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 2,
            outputRegion: output,
            outputGeometryRevision: 1
        )
        let superseded = await context.snapshot()
        #expect(superseded.visiblePlan.currentPlanIdentity != nil)
        #expect(!superseded.visiblePlan.currentIsPresentable)
        #expect(superseded.activeSnapshotTokenCount == 1)
        #expect(source.testingAcknowledgementRequestCount == 0)

        try await context.cancelVisiblePlanRequest(replacement)
        let cancelled = await context.snapshot()
        #expect(cancelled.visiblePlan.currentPlanIdentity == nil)
        #expect(cancelled.visiblePlan.preparedPlanCount == 0)
        #expect(cancelled.visiblePlan.retiringPlanCount == 0)
        #expect(cancelled.activeSnapshotTokenCount == 0)
        #expect(cancelled.aggregateSnapshotReferenceCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)

        let nextSource = try await installTestingTransientPlan(
            context,
            capability: capability
        )
        #expect(nextSource.acknowledgementStatus == .available)
        #expect(await context.snapshot().visiblePlan.currentIsPresentable)
        let canonical = try await request(context, addressing: 3, output: 1)
        let canonicalPrepared = try await context.prepareVisiblePlan(canonical)
        _ = try await context.installVisiblePlan(canonicalPrepared)
        #expect(nextSource.testingAcknowledgementRequestCount == 1)
        #expect(nextSource.acknowledgementStatus == .fulfilled)
        try context.cancelStrokeSurface(capability)
    }

    @Test
    @MainActor
    func cancellingPreparedReplacementRetiresBothPlansAndReusesFrame()
        async throws
    {
        guard let fixture = try makeFixture() else { return }
        let context = fixture.context
        let capability = try context.beginStrokeSurface()
        let source = try makeTestingTransientSourceWithTile(
            context,
            capability: capability
        )
        let output = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 16, maxY: 16
        )
        let initial = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 1,
            outputRegion: output,
            outputGeometryRevision: 1
        )
        let initialPrepared = try await context.prepareTransientVisiblePlan(
            initial
        )
        _ = try await context.installVisiblePlan(initialPrepared)

        let replacement = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 2,
            outputRegion: output,
            outputGeometryRevision: 1
        )
        let replacementPrepared = try await context
            .prepareTransientVisiblePlan(replacement)
        let superseded = await context.snapshot()
        #expect(superseded.visiblePlan.currentPlanIdentity != nil)
        #expect(!superseded.visiblePlan.currentIsPresentable)
        #expect(superseded.visiblePlan.preparedPlanCount == 1)
        #expect(source.testingAcknowledgementRequestCount == 0)

        try await context.cancelVisiblePlanRequest(replacement)
        let cancelled = await context.snapshot()
        #expect(cancelled.visiblePlan.currentPlanIdentity == nil)
        #expect(cancelled.visiblePlan.preparedPlanCount == 0)
        #expect(cancelled.visiblePlan.retiringPlanCount == 0)
        #expect(cancelled.activeSnapshotTokenCount == 0)
        #expect(cancelled.aggregateSnapshotReferenceCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        await #expect(
            throws: DocumentPaintVisiblePlanControllerError.stalePreparedPlan
        ) {
            _ = try await context.installVisiblePlan(replacementPrepared)
        }

        let nextSource = try await installTestingTransientPlan(
            context,
            capability: capability
        )
        #expect(nextSource.acknowledgementStatus == .available)
        #expect(await context.snapshot().visiblePlan.currentIsPresentable)
        let canonical = try await request(context, addressing: 3, output: 1)
        let canonicalPrepared = try await context.prepareVisiblePlan(canonical)
        _ = try await context.installVisiblePlan(canonicalPrepared)
        #expect(nextSource.testingAcknowledgementRequestCount == 1)
        #expect(nextSource.acknowledgementStatus == .fulfilled)
        try context.cancelStrokeSurface(capability)
    }

    @Test
    @MainActor
    func cancellingBuildingReplacementSettlesAfterResumeAndReusesFrame()
        async throws
    {
        let gate = DocumentPaintPreparationTestGate()
        var configuration = DocumentPaintVisiblePlanControllerConfiguration
            .production
        configuration.planBuildGate = gate
        guard let fixture = try makeFixture(configuration: configuration) else {
            return
        }
        let context = fixture.context
        let capability = try context.beginStrokeSurface()
        let source = try makeTestingTransientSourceWithTile(
            context,
            capability: capability
        )
        let output = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 16, maxY: 16
        )
        await gate.open()
        let initial = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 1,
            outputRegion: output,
            outputGeometryRevision: 1
        )
        let initialPrepared = try await context.prepareTransientVisiblePlan(
            initial
        )
        _ = try await context.installVisiblePlan(initialPrepared)
        await gate.close()

        let replacement = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 2,
            outputRegion: output,
            outputGeometryRevision: 1
        )
        let preparation = Task { @MainActor in
            try await context.prepareTransientVisiblePlan(replacement)
        }
        var waitingCount = 0
        for _ in 0..<1_000 {
            waitingCount = await gate.waitingCount
            if waitingCount == 1 { break }
            await Task.yield()
        }
        #expect(waitingCount == 1)

        try await context.cancelVisiblePlanRequest(replacement)
        let suspended = await context.snapshot()
        #expect(suspended.visiblePlan.currentPlanIdentity == nil)
        #expect(suspended.visiblePlan.preparedPlanCount == 0)
        #expect(suspended.visiblePlan.retiringPlanCount == 0)
        #expect(suspended.activeSnapshotTokenCount == 1)
        #expect(source.testingAcknowledgementRequestCount == 0)
        await gate.open()
        await #expect(
            throws: DocumentPaintVisiblePlanControllerError.staleRequest
        ) {
            _ = try await preparation.value
        }

        let terminal = await context.snapshot()
        #expect(terminal.visiblePlan.currentPlanIdentity == nil)
        #expect(terminal.visiblePlan.preparedPlanCount == 0)
        #expect(terminal.visiblePlan.retiringPlanCount == 0)
        #expect(terminal.visiblePlan.transientAcknowledgementOwnedCount == 0)
        #expect(terminal.activeSnapshotTokenCount == 0)
        #expect(terminal.aggregateSnapshotReferenceCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)

        let nextSource = try await installTestingTransientPlan(
            context,
            capability: capability
        )
        #expect(await context.snapshot().visiblePlan.currentIsPresentable)
        let canonical = try await request(context, addressing: 3, output: 1)
        let canonicalPrepared = try await context.prepareVisiblePlan(canonical)
        _ = try await context.installVisiblePlan(canonicalPrepared)
        #expect(nextSource.testingAcknowledgementRequestCount == 1)
        #expect(nextSource.acknowledgementStatus == .fulfilled)
        try context.cancelStrokeSurface(capability)
    }

    @Test
    @MainActor
    func nextRequestPrunesAsynchronouslyFulfilledTransientObligation()
        async throws
    {
        guard let fixture = try makeFixture() else { return }
        let context = fixture.context
        let capability = try context.beginStrokeSurface()
        let source = try makeTestingTransientSourceWithTile(
            context,
            capability: capability,
            acknowledgementCompletionIsDeferred: true
        )
        let output = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 16, maxY: 16
        )
        let transient = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 1,
            outputRegion: output,
            outputGeometryRevision: 1
        )
        let transientPrepared = try await context
            .prepareTransientVisiblePlan(transient)
        _ = try await context.installVisiblePlan(transientPrepared)
        let canonical = try await request(context, addressing: 2, output: 1)
        let canonicalPrepared = try await context.prepareVisiblePlan(canonical)
        _ = try await context.installVisiblePlan(canonicalPrepared)

        let pending = await context.snapshot().visiblePlan
        #expect(source.acknowledgementStatus == .pending)
        #expect(pending.transientAcknowledgementPendingCount == 1)
        #expect(pending.transientAcknowledgementOwnedCount == 1)
        source.testingCompleteDeferredAcknowledgement()
        #expect(source.acknowledgementStatus == .fulfilled)

        let nextSource = try makeTestingTransientSourceWithTile(
            context,
            capability: capability
        )
        let next = try await context.requestTransientVisiblePlan(
            nextSource,
            addressingRevision: 3,
            outputRegion: output,
            outputGeometryRevision: 1
        )
        let afterNormalRequest = await context.snapshot().visiblePlan
        #expect(afterNormalRequest.transientAcknowledgementOwnedCount == 1)
        try await context.cancelVisiblePlanRequest(next)
        let terminal = await context.snapshot().visiblePlan
        #expect(terminal.transientAcknowledgementOwnedCount == 0)
        #expect(nextSource.testingAcknowledgementRequestCount == 1)
        #expect(nextSource.acknowledgementStatus == .fulfilled)
        try context.cancelStrokeSurface(capability)
    }

    @Test
    @MainActor
    func transactionSnapshotCallsSerializeWithoutRawCoordinatorEscape()
        async throws
    {
        guard let fixture = try makeFixture() else { return }
        let context = fixture.context
        let sequences = await withTaskGroup(of: UInt64.self) { group in
            for _ in 0..<32 {
                group.addTask { await context.snapshot().transaction.dispatchSequence }
            }
            var values: [UInt64] = []
            for await value in group { values.append(value) }
            return values.sorted()
        }
        #expect(sequences == Array(1...32))
    }

    @Test
    @MainActor
    func strokeSurfaceCapabilityIsGeometryDerivedSingleAndContextBound()
        async throws
    {
        guard let first = try makeFixture(size: 513),
              let second = try makeFixture(size: 257)
        else { return }

        let capability = try first.context.beginStrokeSurface()
        #expect(capability.layerID == first.layerID)
        #expect(capability.generation == 7)
        #expect(capability.pixelSize == PixelSize(width: 513, height: 513))
        #expect(capability.radialLayout == nil)
        #expect(await first.context.snapshot().activeStrokeSurfaceCount == 1)
        #expect(throws: DocumentPaintRenderContextError.activeStrokeExists) {
            _ = try first.context.beginStrokeSurface()
        }
        #expect(
            throws: DocumentPaintStrokeSurfaceError.foreignCapability
        ) {
            try second.context.cancelStrokeSurface(capability)
        }
        try first.context.cancelStrokeSurface(capability)
        #expect(await first.context.snapshot().activeStrokeSurfaceCount == 0)
        #expect(throws: DocumentPaintRenderContextError.noActiveStroke) {
            try first.context.cancelStrokeSurface(capability)
        }
    }

    @Test
    @MainActor
    func transientDisplayAdoptionAuthenticatesAndPublishesExactFirstSources()
        async throws
    {
        guard let first = try makeFixture(size: 513),
              let second = try makeFixture(size: 513)
        else { return }
        let firstCapability = try first.context.beginStrokeSurface()
        let secondCapability = try second.context.beginStrokeSurface()
        let firstFrame = StrokePreparedDisplayFrame.testing(
            capability: firstCapability,
            layer: .authoritative,
            changedCoordinates: [PaintTileCoordinate(x: 0, y: 0)]
        )
        let foreignFrame = StrokePreparedDisplayFrame.testing(
            capability: secondCapability
        )
        let addressing = SparseTileAddressing.finite(
            PixelSize(width: 513, height: 513)
        )

        #expect(
            throws: DocumentPaintRenderContextError
                .foreignTransientDisplayFrame
        ) {
            _ = try first.context.adoptTransientDisplayFrame(
                foreignFrame,
                addressing: addressing
            )
        }
        let source = try first.context.adoptTransientDisplayFrame(
            firstFrame,
            addressing: addressing
        )
        #expect(
            source.orderedRoles
                == [.authoritative, .prediction]
        )
        #expect(
            source.dispositions
                == [.fullSnapshot, .fullSnapshot]
        )
        #expect(
            source.contentKeys[0].surfaceIdentity
                == firstCapability.authoritativeSurfaceID
        )
        #expect(
            source.contentKeys[1].surfaceIdentity
                == firstCapability.predictionSurfaceID
        )
        #expect(source.contentKeys[0] != source.contentKeys[1])
        #expect(
            throws: DocumentPaintRenderContextError
                .activeTransientDisplaySourceExists
        ) {
            _ = try first.context.adoptTransientDisplayFrame(
                firstFrame,
                addressing: addressing
            )
        }

        try first.context
            .testingReleaseTransientDisplaySourceWithoutAcknowledgement(source)
        let predictionCoordinate = PaintTileCoordinate(x: 1, y: 0)
        let predictionFrame = StrokePreparedDisplayFrame.testing(
            capability: firstCapability,
            layer: .prediction,
            changedCoordinates: [predictionCoordinate]
        )
        let delta = try first.context.adoptTransientDisplayFrame(
            predictionFrame,
            addressing: addressing
        )
        #expect(
            delta.dispositions == [.delta, .delta]
        )
        #expect(delta.changedCoordinateSets[0].isEmpty)
        #expect(delta.changedCoordinateSets[1] == [predictionCoordinate])
        #expect(
            delta.contentKeys[0].surfaceIdentity
                == source.contentKeys[0].surfaceIdentity
        )
        #expect(
            delta.contentKeys[1].surfaceIdentity
                == source.contentKeys[1].surfaceIdentity
        )
    }

    @Test
    @MainActor
    func controllerRetainsTransientObligationAcrossPlanSupersessionFailure()
        async throws
    {
        guard let fixture = try makeFixture(size: 16) else { return }
        let context = fixture.context
        let capability = try context.beginStrokeSurface()
        let frame = StrokePreparedDisplayFrame.testing(
            capability: capability,
            acknowledgementIsAvailable: true,
            acknowledgementReleaseFailures: [
                .unexpected("first injected ACK failure"),
                .unexpected("second injected ACK failure"),
            ]
        )
        let source = try context.adoptTransientDisplayFrame(
            frame,
            addressing: .finite(PixelSize(width: 16, height: 16))
        )
        let output = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 16, maxY: 16
        )
        let transientRequest = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 1,
            outputRegion: output,
            outputGeometryRevision: 1
        )
        let transientPrepared = try await context.prepareTransientVisiblePlan(
            transientRequest
        )
        _ = try await context.installVisiblePlan(transientPrepared)
        #expect(
            await context.snapshot().visiblePlan.currentSpecification?
                .key.orderedLayers[0].roles.map(\.role)
                == [.canonical, .authoritative, .prediction]
        )

        let canonical = try await request(
            context,
            addressing: 2,
            output: 1
        )
        let canonicalPrepared = try await context.prepareVisiblePlan(canonical)
        _ = try await context.installVisiblePlan(canonicalPrepared)
        let retained = await context.snapshot().visiblePlan
        #expect(retained.retiringPlanCount == 0)
        #expect(retained.transientAcknowledgementFailureCount == 1)
        try await context.retryVisiblePlanRetirementsAndCompletions()
        #expect(
            await context.snapshot().visiblePlan
                .transientAcknowledgementFailureCount == 1
        )
    }

    @Test(arguments: [false, true])
    @MainActor
    func transientACKOccursExactlyOnceAfterGPU(terminalFailure: Bool)
        async throws
    {
        var configuration = DocumentPaintVisiblePlanControllerConfiguration
            .production
        configuration.forceTerminalFailure = terminalFailure
        guard let fixture = try makeFixture(configuration: configuration) else {
            return
        }
        let capability = try fixture.context.beginStrokeSurface()
        let source = try await installTestingTransientPlan(
            fixture.context,
            capability: capability
        )
        let submission = try await fixture.context.prepareDisplaySubmission()
        let target = try makeTarget(device: fixture.device)
        let command = try #require(fixture.queue.makeCommandBuffer())
        try fixture.context.encodeDisplaySubmission(
            submission,
            target: target,
            commandBuffer: command,
            renderPassDescriptor: passDescriptor(target: target)
        )
        #expect(source.testingAcknowledgementRequestCount == 0)
        command.commit()
        await command.completed()
        let terminal = await fixture.context.snapshot().visiblePlan
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        #expect(
            terminalFailure
                ? terminal.failedSubmissionCount == 1
                : terminal.completedSubmissionCount == 1
        )
        _ = await fixture.context.snapshot()
        #expect(source.testingAcknowledgementRequestCount == 1)
    }

    @Test
    @MainActor
    func transientPlanClosesOnFirstOutOfOrderTerminalAndWaitsForAllGPUWork()
        async throws
    {
        guard let fixture = try makeFixture(),
              let secondQueue = fixture.device.makeCommandQueue(),
              let releaseEvent = fixture.device.makeSharedEvent()
        else { return }
        let capability = try fixture.context.beginStrokeSurface()
        let source = try await installTestingTransientPlan(
            fixture.context,
            capability: capability
        )
        let blocked = try await fixture.context.prepareDisplaySubmission()
        let firstTerminal = try await fixture.context.prepareDisplaySubmission()
        let revoked = try await fixture.context.prepareDisplaySubmission()
        let blockedTarget = try makeTarget(device: fixture.device)
        let firstTerminalTarget = try makeTarget(device: fixture.device)
        let blockedCommand = try #require(fixture.queue.makeCommandBuffer())
        blockedCommand.encodeWaitForEvent(releaseEvent, value: 1)
        try fixture.context.encodeDisplaySubmission(
            blocked,
            target: blockedTarget,
            commandBuffer: blockedCommand,
            renderPassDescriptor: passDescriptor(target: blockedTarget)
        )
        let firstTerminalCommand = try #require(
            secondQueue.makeCommandBuffer()
        )
        try fixture.context.encodeDisplaySubmission(
            firstTerminal,
            target: firstTerminalTarget,
            commandBuffer: firstTerminalCommand,
            renderPassDescriptor: passDescriptor(target: firstTerminalTarget)
        )

        blockedCommand.commit()
        firstTerminalCommand.commit()
        await firstTerminalCommand.completed()
        #expect(firstTerminalCommand.status == .completed)
        #expect(blockedCommand.status != .completed)

        let closed = await fixture.context.snapshot().visiblePlan
        #expect(closed.currentPlanIdentity == nil)
        #expect(closed.preparedSubmissionCount == 0)
        #expect(closed.submittedSubmissionCount == 1)
        #expect(closed.uploadRing?.activeSlotCount == 1)
        #expect(source.testingAcknowledgementRequestCount == 0)
        #expect(source.acknowledgementStatus == .available)
        #expect(
            throws: DocumentPaintVisiblePlanControllerError
                .submissionAlreadyConsumed
        ) {
            try fixture.context.cancelDisplaySubmission(revoked)
        }
        await #expect(
            throws: DocumentPaintVisiblePlanControllerError.noCurrentPlan
        ) {
            _ = try await fixture.context.prepareDisplaySubmission()
        }

        releaseEvent.signaledValue = 1
        await blockedCommand.completed()
        #expect(blockedCommand.status == .completed)
        let terminal = try await waitForTerminal(fixture.context)
        #expect(terminal.submittedSubmissionCount == 0)
        #expect(terminal.uploadRing?.activeSlotCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        await #expect(
            throws: DocumentPaintVisiblePlanControllerError.noCurrentPlan
        ) {
            _ = try await fixture.context.prepareDisplaySubmission()
        }
        let reuseCommand = try #require(fixture.queue.makeCommandBuffer())
        #expect(
            throws: DocumentPaintVisiblePlanControllerError
                .submissionAlreadyConsumed
        ) {
            try fixture.context.encodeDisplaySubmission(
                blocked,
                target: blockedTarget,
                commandBuffer: reuseCommand,
                renderPassDescriptor: passDescriptor(target: blockedTarget)
            )
        }
    }

    @Test
    @MainActor
    func failedCurrentTransientACKRetriesThenAllowsNextFrame() async throws {
        guard let fixture = try makeFixture() else { return }
        let capability = try fixture.context.beginStrokeSurface()
        let injectedFailure = StrokePreparationFailure.unexpected(
            "injected scheduler release failure"
        )
        let source = try await installTestingTransientPlan(
            fixture.context,
            capability: capability,
            acknowledgementReleaseFailures: [injectedFailure]
        )
        let first = try await fixture.context.prepareDisplaySubmission()
        let firstTarget = try makeTarget(device: fixture.device)
        let firstCommand = try #require(fixture.queue.makeCommandBuffer())
        try fixture.context.encodeDisplaySubmission(
            first,
            target: firstTarget,
            commandBuffer: firstCommand,
            renderPassDescriptor: passDescriptor(target: firstTarget)
        )
        firstCommand.commit()
        await firstCommand.completed()
        let failed = await fixture.context.snapshot().visiblePlan
        #expect(failed.currentPlanIdentity == nil)
        // The dead plan retires immediately; the central zero-use transient
        // obligation, not a dead plan proxy, retains the failed ACK.
        #expect(failed.retiringPlanCount == 0)
        #expect(failed.transientAcknowledgementFailureCount == 1)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(
            source.acknowledgementStatus
                == .failed(.schedulerReleaseFailed(injectedFailure))
        )

        try await fixture.context.retryVisiblePlanRetirementsAndCompletions()
        let retried = await fixture.context.snapshot().visiblePlan
        #expect(retried.retiringPlanCount == 0)
        #expect(retried.transientAcknowledgementFailureCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 2)
        #expect(source.acknowledgementStatus == .fulfilled)

        let nextSource = try await installTestingTransientPlan(
            fixture.context,
            capability: capability
        )
        let next = try await fixture.context.prepareDisplaySubmission()
        let nextTarget = try makeTarget(device: fixture.device)
        let nextCommand = try #require(fixture.queue.makeCommandBuffer())
        try fixture.context.encodeDisplaySubmission(
            next,
            target: nextTarget,
            commandBuffer: nextCommand,
            renderPassDescriptor: passDescriptor(target: nextTarget)
        )
        nextCommand.commit()
        await nextCommand.completed()
        _ = try await waitForTerminal(fixture.context)
        #expect(nextSource.testingAcknowledgementRequestCount == 1)
        #expect(nextSource.acknowledgementStatus == .fulfilled)
    }

    @Test
    @MainActor
    func preSubmitSupersedeRetiresThenACKsWithoutGPU() async throws {
        guard let fixture = try makeFixture() else { return }
        let capability = try fixture.context.beginStrokeSurface()
        let source = try await installTestingTransientPlan(
            fixture.context,
            capability: capability
        )
        #expect(source.testingAcknowledgementRequestCount == 0)
        let canonical = try await request(
            fixture.context,
            addressing: 2,
            output: 1
        )
        let prepared = try await fixture.context.prepareVisiblePlan(canonical)
        _ = try await fixture.context.installVisiblePlan(prepared)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        try await fixture.context.retryVisiblePlanRetirementsAndCompletions()
        #expect(await fixture.context.snapshot().visiblePlan.retiringPlanCount == 0)
    }

    @Test
    @MainActor
    func submittedSupersedeWaitsForExactGPUTerminalBeforeACK() async throws {
        guard let fixture = try makeFixture() else { return }
        let capability = try fixture.context.beginStrokeSurface()
        let source = try await installTestingTransientPlan(
            fixture.context,
            capability: capability
        )
        let submission = try await fixture.context.prepareDisplaySubmission()
        let target = try makeTarget(device: fixture.device)
        let command = try #require(fixture.queue.makeCommandBuffer())
        try fixture.context.encodeDisplaySubmission(
            submission,
            target: target,
            commandBuffer: command,
            renderPassDescriptor: passDescriptor(target: target)
        )
        let canonical = try await request(
            fixture.context,
            addressing: 2,
            output: 1
        )
        let prepared = try await fixture.context.prepareVisiblePlan(canonical)
        _ = try await fixture.context.installVisiblePlan(prepared)
        #expect(source.testingAcknowledgementRequestCount == 0)
        command.commit()
        await command.completed()
        try await fixture.context.retryVisiblePlanRetirementsAndCompletions()
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        #expect(await fixture.context.snapshot().visiblePlan.retiringPlanCount == 0)
    }

    @Test
    @MainActor
    func shutdownDrainsTransientSourceBeforeCancellingCapability()
        async throws
    {
        guard let fixture = try makeFixture() else { return }
        let capability = try fixture.context.beginStrokeSurface()
        let source = try await installTestingTransientPlan(
            fixture.context,
            capability: capability
        )
        let first = try await fixture.context.shutdown(
            reason: .sessionReplacement
        )
        #expect(first.isComplete)
        #expect(source.acknowledgementStatus == .fulfilled)
        #expect(capability.isTerminal)
        let complete = try await fixture.context.shutdown(
            reason: .sessionReplacement
        )
        #expect(complete.isComplete)
        #expect(capability.isTerminal)
    }

    @Test
    @MainActor
    func transientCloseRetainsFailedPreparedAbandonmentUntilP4Retry()
        async throws
    {
        let failure = SparseTileSamplingPreparedAbandonmentFailureInjector(
            failures: 1
        )
        var configuration = DocumentPaintVisiblePlanControllerConfiguration
            .production
        configuration.preparedAbandonmentFailureInjector = failure
        guard let fixture = try makeFixture(configuration: configuration) else {
            return
        }
        let capability = try fixture.context.beginStrokeSurface()
        let source = try await installTestingTransientPlan(
            fixture.context,
            capability: capability
        )
        let revoked = try await fixture.context.prepareDisplaySubmission()
        let terminal = try await fixture.context.prepareDisplaySubmission()
        let target = try makeTarget(device: fixture.device)
        let command = try #require(fixture.queue.makeCommandBuffer())
        try fixture.context.encodeDisplaySubmission(
            terminal,
            target: target,
            commandBuffer: command,
            renderPassDescriptor: passDescriptor(target: target)
        )
        command.commit()
        await command.completed()

        let failed = await fixture.context.snapshot().visiblePlan
        #expect(failed.currentPlanIdentity == nil)
        #expect(failed.preparedSubmissionCount == 1)
        #expect(failed.retiringPlanCount == 1)
        #expect(failed.pendingPlanCompletionCount == 1)
        #expect(failed.pendingConsumerCompletionCount == 0)
        #expect(failed.completedSubmissionCount == 1)
        #expect(failed.failedSubmissionCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 0)
        #expect(source.acknowledgementStatus == .available)
        #expect(!capability.isTerminal)

        try await fixture.context.retryVisiblePlanRetirementsAndCompletions()
        let retried = await fixture.context.snapshot().visiblePlan
        #expect(retried.preparedSubmissionCount == 0)
        #expect(retried.retiringPlanCount == 0)
        #expect(retried.pendingPlanCompletionCount == 0)
        #expect(retried.pendingConsumerCompletionCount == 0)
        #expect(retried.completedSubmissionCount == 1)
        #expect(retried.failedSubmissionCount == 1)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        #expect(!capability.isTerminal)

        try await fixture.context.retryVisiblePlanRetirementsAndCompletions()
        let idempotent = await fixture.context.snapshot().visiblePlan
        #expect(idempotent == retried)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(
            throws: DocumentPaintVisiblePlanControllerError
                .submissionAlreadyConsumed
        ) {
            try fixture.context.cancelDisplaySubmission(revoked)
        }
    }

    @Test
    @MainActor
    func supersessionRetainsFailedPreparedAbandonmentUntilP4Retry()
        async throws
    {
        let failure = SparseTileSamplingPreparedAbandonmentFailureInjector(
            failures: 1
        )
        var configuration = DocumentPaintVisiblePlanControllerConfiguration
            .production
        configuration.preparedAbandonmentFailureInjector = failure
        guard let fixture = try makeFixture(configuration: configuration) else {
            return
        }
        let capability = try fixture.context.beginStrokeSurface()
        let source = try await installTestingTransientPlan(
            fixture.context,
            capability: capability
        )
        let revoked = try await fixture.context.prepareDisplaySubmission()
        let canonical = try await request(
            fixture.context,
            addressing: 2,
            output: 1
        )
        let prepared = try await fixture.context.prepareVisiblePlan(canonical)
        _ = try await fixture.context.installVisiblePlan(prepared)

        let failed = await fixture.context.snapshot().visiblePlan
        #expect(failed.currentSpecification == canonical.specification)
        #expect(failed.currentIsPresentable)
        #expect(failed.preparedSubmissionCount == 1)
        #expect(failed.retiringPlanCount == 1)
        #expect(failed.pendingPlanCompletionCount == 1)
        #expect(failed.pendingConsumerCompletionCount == 0)
        #expect(failed.completedSubmissionCount == 0)
        #expect(failed.failedSubmissionCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 0)
        #expect(source.acknowledgementStatus == .available)
        #expect(!capability.isTerminal)

        try await fixture.context.retryVisiblePlanRetirementsAndCompletions()
        let retried = await fixture.context.snapshot().visiblePlan
        #expect(retried.currentSpecification == canonical.specification)
        #expect(retried.currentIsPresentable)
        #expect(retried.preparedSubmissionCount == 0)
        #expect(retried.retiringPlanCount == 0)
        #expect(retried.pendingPlanCompletionCount == 0)
        #expect(retried.pendingConsumerCompletionCount == 0)
        #expect(retried.completedSubmissionCount == 0)
        #expect(retried.failedSubmissionCount == 1)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        #expect(!capability.isTerminal)

        try await fixture.context.retryVisiblePlanRetirementsAndCompletions()
        let idempotent = await fixture.context.snapshot().visiblePlan
        #expect(idempotent == retried)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(
            throws: DocumentPaintVisiblePlanControllerError
                .submissionAlreadyConsumed
        ) {
            try fixture.context.cancelDisplaySubmission(revoked)
        }
    }

    @Test
    @MainActor
    func shutdownRetainsFailedPreparedAbandonmentUntilP4Retry()
        async throws
    {
        // Shutdown performs one retry before returning, so fail the initial P4
        // return and that first retry to make the retained obligation visible.
        let failure = SparseTileSamplingPreparedAbandonmentFailureInjector(
            failures: 2
        )
        var configuration = DocumentPaintVisiblePlanControllerConfiguration
            .production
        configuration.preparedAbandonmentFailureInjector = failure
        guard let fixture = try makeFixture(configuration: configuration) else {
            return
        }
        let capability = try fixture.context.beginStrokeSurface()
        let source = try await installTestingTransientPlan(
            fixture.context,
            capability: capability
        )
        let revoked = try await fixture.context.prepareDisplaySubmission()

        let failed = try await fixture.context.shutdown(
            reason: .sessionReplacement
        )
        #expect(!failed.isComplete)
        #expect(failed.preparedSubmissionCount == 1)
        #expect(failed.submittedSubmissionCount == 0)
        #expect(failed.retiringPlanCount == 1)
        #expect(failed.pendingP4CompletionCount == 1)
        let retained = await fixture.context.snapshot().visiblePlan
        #expect(retained.pendingPlanCompletionCount == 1)
        #expect(retained.pendingConsumerCompletionCount == 0)
        #expect(retained.completedSubmissionCount == 0)
        #expect(retained.failedSubmissionCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 0)
        #expect(source.acknowledgementStatus == .available)
        #expect(!capability.isTerminal)

        let complete = try await fixture.context.shutdown(
            reason: .sessionReplacement
        )
        #expect(complete.isComplete)
        #expect(complete.preparedSubmissionCount == 0)
        #expect(complete.submittedSubmissionCount == 0)
        #expect(complete.retiringPlanCount == 0)
        #expect(complete.pendingP4CompletionCount == 0)
        let terminal = await fixture.context.snapshot().visiblePlan
        #expect(terminal.completedSubmissionCount == 0)
        #expect(terminal.failedSubmissionCount == 1)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        #expect(capability.isTerminal)

        let idempotent = try await fixture.context.shutdown(
            reason: .sessionReplacement
        )
        #expect(idempotent == complete)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(
            throws: DocumentPaintVisiblePlanControllerError
                .submissionAlreadyConsumed
        ) {
            try fixture.context.cancelDisplaySubmission(revoked)
        }
    }

    @Test
    @MainActor
    func supersessionDropDuringWeakRevocationPublishesExactP4Receipt()
        async throws
    {
        let gate = DocumentPaintPreparedCoreRevocationRaceGate()
        var configuration = DocumentPaintVisiblePlanControllerConfiguration
            .production
        configuration.preparedCoreRevocationRaceGate = gate
        guard let fixture = try makeFixture(configuration: configuration) else {
            return
        }
        let capability = try fixture.context.beginStrokeSurface()
        let source = try await installTestingTransientPlan(
            fixture.context,
            capability: capability
        )
        let owner = DocumentPaintSubmissionOwnerBox(
            try await fixture.context.prepareDisplaySubmission()
        )
        #expect(
            await fixture.context.snapshot().visiblePlan.uploadRing?
                .activeSlotCount == 1
        )

        let supersession = Task { @MainActor in
            try await request(fixture.context, addressing: 2, output: 1)
        }
        try await waitForPreparedCoreRace(gate, revocationPaused: true)
        let drop = Task.detached { owner.dropLastWrapper() }
        try await waitForPreparedCoreRace(
            gate,
            revocationPaused: true,
            coreDeinitEntered: true
        )
        gate.releaseRevocation()

        let canonical = try await supersession.value
        await drop.value
        let prepared = try await fixture.context.prepareVisiblePlan(canonical)
        _ = try await fixture.context.installVisiblePlan(prepared)
        let terminal = await fixture.context.snapshot().visiblePlan
        #expect(terminal.currentSpecification == canonical.specification)
        #expect(terminal.currentIsPresentable)
        #expect(terminal.preparationReservationCount == 0)
        #expect(terminal.preparedSubmissionCount == 0)
        #expect(terminal.submittedSubmissionCount == 0)
        #expect(terminal.submissions.isEmpty)
        #expect(terminal.retiringPlanCount == 0)
        #expect(terminal.pendingPlanCompletionCount == 0)
        #expect(terminal.pendingConsumerCompletionCount == 0)
        #expect(terminal.pendingTerminalEventCount == 0)
        #expect(terminal.uploadRing?.activeSlotCount == 0)
        #expect(terminal.completedSubmissionCount == 0)
        #expect(terminal.failedSubmissionCount == 1)
        #expect(terminal.ignoredEarlyTerminalCount == 0)
        #expect(terminal.ignoredDuplicateTerminalCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        #expect(!capability.isTerminal)

        try await fixture.context.retryVisiblePlanRetirementsAndCompletions()
        let idempotent = await fixture.context.snapshot().visiblePlan
        #expect(idempotent == terminal)
        #expect(source.testingAcknowledgementRequestCount == 1)

        // Prove the superseding canonical plan remains renderable.
        let frame = try await fixture.context.prepareDisplaySubmission()
        let target = try makeTarget(device: fixture.device)
        let command = try #require(fixture.queue.makeCommandBuffer())
        try fixture.context.encodeDisplaySubmission(
            frame,
            target: target,
            commandBuffer: command,
            renderPassDescriptor: passDescriptor(target: target)
        )
        command.commit()
        await command.completed()
        let rendered = try await waitForTerminal(fixture.context)
        #expect(rendered.completedSubmissionCount == 1)
        #expect(rendered.failedSubmissionCount == 1)
        #expect(source.testingAcknowledgementRequestCount == 1)
    }

    @Test
    @MainActor
    func shutdownDropDuringWeakRevocationPublishesExactP4Receipt()
        async throws
    {
        let gate = DocumentPaintPreparedCoreRevocationRaceGate()
        var configuration = DocumentPaintVisiblePlanControllerConfiguration
            .production
        configuration.preparedCoreRevocationRaceGate = gate
        guard let fixture = try makeFixture(configuration: configuration) else {
            return
        }
        let capability = try fixture.context.beginStrokeSurface()
        let source = try await installTestingTransientPlan(
            fixture.context,
            capability: capability
        )
        let owner = DocumentPaintSubmissionOwnerBox(
            try await fixture.context.prepareDisplaySubmission()
        )
        #expect(
            await fixture.context.snapshot().visiblePlan.uploadRing?
                .activeSlotCount == 1
        )

        let shutdown = Task { @MainActor in
            try await fixture.context.shutdown(reason: .sessionReplacement)
        }
        try await waitForPreparedCoreRace(gate, revocationPaused: true)
        let drop = Task.detached { owner.dropLastWrapper() }
        try await waitForPreparedCoreRace(
            gate,
            revocationPaused: true,
            coreDeinitEntered: true
        )
        gate.releaseRevocation()

        _ = try await shutdown.value
        await drop.value
        let complete = try await fixture.context.shutdown(
            reason: .sessionReplacement
        )
        #expect(complete.isComplete)
        #expect(complete.ownedPlanReservationCount == 0)
        #expect(complete.preparedSubmissionCount == 0)
        #expect(complete.submittedSubmissionCount == 0)
        #expect(complete.retiringPlanCount == 0)
        #expect(complete.pendingP4CompletionCount == 0)
        let terminal = await fixture.context.snapshot().visiblePlan
        #expect(terminal.preparationReservationCount == 0)
        #expect(terminal.preparedSubmissionCount == 0)
        #expect(terminal.submittedSubmissionCount == 0)
        #expect(terminal.submissions.isEmpty)
        #expect(terminal.retiringPlanCount == 0)
        #expect(terminal.pendingPlanCompletionCount == 0)
        #expect(terminal.pendingConsumerCompletionCount == 0)
        #expect(terminal.pendingTerminalEventCount == 0)
        #expect(terminal.uploadRing?.activeSlotCount == 0)
        #expect(terminal.completedSubmissionCount == 0)
        #expect(terminal.failedSubmissionCount == 1)
        #expect(terminal.ignoredEarlyTerminalCount == 0)
        #expect(terminal.ignoredDuplicateTerminalCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        #expect(capability.isTerminal)

        let idempotent = try await fixture.context.shutdown(
            reason: .sessionReplacement
        )
        #expect(idempotent == complete)
        #expect(source.testingAcknowledgementRequestCount == 1)
        let unchanged = await fixture.context.snapshot().visiblePlan
        #expect(unchanged == terminal)
    }

    @Test
    @MainActor
    func contextDeinitDoesNotExerciseStrokeCancellationAuthority()
        async throws
    {
        var context = try makeFixture()?.context
        guard context != nil else { return }
        let capability = try context!.beginStrokeSurface()
        context = nil
        #expect(!capability.isTerminal)
        try capability.cancel(expectedOwnerIdentity: capability.ownerIdentity)
        #expect(capability.isTerminal)
    }

    @Test
    @MainActor
    func terminalSourceClearsContextSlotAndAllowsImmediateNextStroke()
        async throws
    {
        guard let fixture = try makeFixture(size: 513) else { return }
        let context = fixture.context
        let coordinate = PaintTileCoordinate(x: 0, y: 0)

        let unclaimedCapability = try context.beginStrokeSurface()
        var frame = try unclaimedCapability.reserveStrokeTiles(
            role: .authoritative,
            coordinates: [coordinate],
            pinReasons: [.visible, .inFlight],
            workspace: PaintTileStrokeLeaseWorkspace(maximumBindingCount: 1),
            failureInjection: nil
        )
        try unclaimedCapability.testingMarkDirty(frame)
        try unclaimedCapability.releaseFrameReservations(
            authoritative: frame,
            prediction: nil
        )
        let unclaimed = try #require(
            try unclaimedCapability.issueCommitMutationSource()
        )
        #expect(await context.snapshot().activeStrokeSurfaceCount == 1)
        try unclaimed.cancelUnclaimed()
        #expect(await context.snapshot().activeStrokeSurfaceCount == 0)

        let claimedCapability = try context.beginStrokeSurface()
        frame = try claimedCapability.reserveStrokeTiles(
            role: .authoritative,
            coordinates: [coordinate],
            pinReasons: [.visible, .inFlight],
            workspace: PaintTileStrokeLeaseWorkspace(maximumBindingCount: 1),
            failureInjection: nil
        )
        try claimedCapability.testingMarkDirty(frame)
        try claimedCapability.releaseFrameReservations(
            authoritative: frame,
            prediction: nil
        )
        let claimed = try #require(
            try claimedCapability.issueCommitMutationSource()
        )
        let transactionID = UUID()
        _ = try claimed.claim(transactionID: transactionID)
        #expect(throws: DocumentPaintStrokeSurfaceError.alreadyClaimed) {
            try context.cancelStrokeSurface(claimedCapability)
        }
        #expect(await context.snapshot().activeStrokeSurfaceCount == 1)
        try claimed.complete(transactionID: transactionID, as: .aborted)
        #expect(await context.snapshot().activeStrokeSurfaceCount == 0)

        let immediate = try context.beginStrokeSurface()
        try context.cancelStrokeSurface(immediate)
        #expect(await context.snapshot().activeStrokeSurfaceCount == 0)
    }

    @Test
    @MainActor
    func contextAbandonmentDoesNotCycleAnOutstandingFrameCapability()
        async throws
    {
        var context = try makeFixture(size: 256)?.context
        guard context != nil else { return }
        weak let weakContext = context
        weak let weakSlot = context?.testingActiveStrokeSurfaceSlot
        var capability = try context?.beginStrokeSurface()
        guard capability != nil else { return }
        weak let weakCapability = capability
        weak let weakStore = capability?.testingStoreObject
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let frame = try capability!.reserveStrokeTiles(
            role: .authoritative,
            coordinates: [coordinate],
            pinReasons: [.visible, .inFlight],
            workspace: PaintTileStrokeLeaseWorkspace(maximumBindingCount: 1),
            failureInjection: nil
        )
        try capability!.testingMarkDirty(frame)
        #expect(capability!.snapshot.activeLeaseCount == 1)
        #expect(capability!.testingStoreSnapshot.activeLeaseCount == 1)
        #expect(capability!.testingNamespaceIsOutstanding)

        context = nil
        #expect(weakContext == nil)
        #expect(weakSlot == nil)
        #expect(weakCapability != nil)
        #expect(weakStore != nil)
        #expect(capability!.snapshot.activeLeaseCount == 1)
        #expect(capability!.testingStoreSnapshot.activeLeaseCount == 1)
        #expect(capability!.testingNamespaceIsOutstanding)

        try capability!.releaseFrameReservations(
            authoritative: frame,
            prediction: nil
        )
        #expect(capability!.snapshot.activeLeaseCount == 0)
        try capability!.cancel(
            expectedOwnerIdentity: capability!.ownerIdentity
        )
        #expect(!capability!.testingNamespaceIsOutstanding)
        #expect(capability!.testingStoreSnapshot.activeLeaseCount == 0)
        #expect(capability!.testingStoreSnapshot.entries.isEmpty)
        capability = nil
        #expect(weakCapability == nil)
        #expect(weakStore == nil)

        var droppedContext = try makeFixture(size: 256)?.context
        guard droppedContext != nil else { return }
        weak let weakDroppedContext = droppedContext
        weak let weakDroppedSlot =
            droppedContext?.testingActiveStrokeSurfaceSlot
        var droppedCapability = try droppedContext?.beginStrokeSurface()
        guard droppedCapability != nil else { return }
        weak let weakDroppedCapability = droppedCapability
        weak let weakDroppedStore = droppedCapability?.testingStoreObject
        let droppedFrame = try droppedCapability!.reserveStrokeTiles(
            role: .authoritative,
            coordinates: [coordinate],
            pinReasons: [.visible, .inFlight],
            workspace: PaintTileStrokeLeaseWorkspace(maximumBindingCount: 1),
            failureInjection: nil
        )
        try droppedCapability!.testingMarkDirty(droppedFrame)

        droppedContext = nil
        droppedCapability = nil
        #expect(weakDroppedContext == nil)
        #expect(weakDroppedSlot == nil)
        #expect(weakDroppedCapability == nil)
        #expect(weakDroppedStore == nil)
        withExtendedLifetime(droppedFrame) {}
    }

    @Test
    @MainActor
    func contextAbandonmentLeavesClaimedSourceAsOnlyTerminalOwner()
        async throws
    {
        var context = try makeFixture(size: 256)?.context
        guard context != nil else { return }
        weak let weakContext = context
        weak let weakSlot = context?.testingActiveStrokeSurfaceSlot
        var capability = try context?.beginStrokeSurface()
        guard capability != nil else { return }
        weak let weakCapability = capability
        weak let weakStore = capability?.testingStoreObject
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let frame = try capability!.reserveStrokeTiles(
            role: .authoritative,
            coordinates: [coordinate],
            pinReasons: [.visible, .inFlight],
            workspace: PaintTileStrokeLeaseWorkspace(maximumBindingCount: 1),
            failureInjection: nil
        )
        try capability!.testingMarkDirty(frame)
        try capability!.releaseFrameReservations(
            authoritative: frame,
            prediction: nil
        )
        var source = try capability!.issueCommitMutationSource()
        let transactionID = UUID()
        _ = try source?.claim(transactionID: transactionID)
        #expect(capability!.snapshot.activeLeaseCount == 1)
        #expect(capability!.testingStoreSnapshot.activeLeaseCount == 1)
        #expect(capability!.testingNamespaceIsOutstanding)

        context = nil
        capability = nil
        #expect(weakContext == nil)
        #expect(weakSlot == nil)
        #expect(weakCapability != nil)
        #expect(weakStore != nil)
        #expect(weakCapability?.snapshot.activeLeaseCount == 1)
        #expect(weakCapability?.testingStoreSnapshot.activeLeaseCount == 1)
        #expect(weakCapability?.testingNamespaceIsOutstanding == true)

        try source?.complete(transactionID: transactionID, as: .aborted)
        #expect(weakCapability?.snapshot.activeLeaseCount == 0)
        #expect(weakCapability?.testingStoreSnapshot.activeLeaseCount == 0)
        #expect(weakCapability?.testingStoreSnapshot.entries.isEmpty == true)
        #expect(weakCapability?.testingNamespaceIsOutstanding == false)
        source = nil
        #expect(weakCapability == nil)
        #expect(weakStore == nil)

        var droppedContext = try makeFixture(size: 256)?.context
        guard droppedContext != nil else { return }
        weak let weakDroppedContext = droppedContext
        weak let weakDroppedSlot =
            droppedContext?.testingActiveStrokeSurfaceSlot
        var droppedCapability = try droppedContext?.beginStrokeSurface()
        guard droppedCapability != nil else { return }
        weak let weakDroppedCapability = droppedCapability
        weak let weakDroppedStore = droppedCapability?.testingStoreObject
        let droppedFrame = try droppedCapability!.reserveStrokeTiles(
            role: .authoritative,
            coordinates: [coordinate],
            pinReasons: [.visible, .inFlight],
            workspace: PaintTileStrokeLeaseWorkspace(maximumBindingCount: 1),
            failureInjection: nil
        )
        try droppedCapability!.testingMarkDirty(droppedFrame)
        try droppedCapability!.releaseFrameReservations(
            authoritative: droppedFrame,
            prediction: nil
        )
        var droppedSource = try droppedCapability!
            .issueCommitMutationSource()
        _ = try droppedSource?.claim(transactionID: UUID())

        droppedContext = nil
        droppedCapability = nil
        droppedSource = nil
        #expect(weakDroppedContext == nil)
        #expect(weakDroppedSlot == nil)
        #expect(weakDroppedCapability == nil)
        #expect(weakDroppedStore == nil)
    }

    @Test
    @MainActor
    func requestImmediatelyRevokesDifferingFullPlanKey() async throws {
        guard let fixture = try makeFixture() else { return }
        let context = fixture.context
        let first = try await request(context, addressing: 1, output: 1)
        let prepared = try await context.prepareVisiblePlan(first)
        _ = try await context.installVisiblePlan(prepared)
        #expect(await context.snapshot().visiblePlan.currentIsPresentable)

        let second = try await request(context, addressing: 2, output: 1)
        let revoked = await context.snapshot().visiblePlan
        #expect(!revoked.currentIsPresentable)
        #expect(revoked.requestedSpecification == second.specification)
        await #expect(
            throws: DocumentPaintVisiblePlanControllerError.staleRequest
        ) {
            _ = try await context.prepareVisiblePlan(first)
        }

        let secondPrepared = try await context.prepareVisiblePlan(second)
        _ = try await context.installVisiblePlan(secondPrepared)
        let installed = await context.snapshot().visiblePlan
        #expect(installed.currentIsPresentable)
        #expect(installed.currentSpecification == second.specification)
    }

    @Test
    @MainActor
    func fullKeyIncludesAffineEvenWhenGenerationTripleMatches()
        async throws
    {
        guard let fixture = try makeFixture() else { return }
        let context = fixture.context
        let first = try await request(context, addressing: 1, output: 1)
        let firstPrepared = try await context.prepareVisiblePlan(first)
        _ = try await context.installVisiblePlan(firstPrepared)
        let translated = try await request(
            context,
            addressing: 1,
            output: 1,
            transform: SparseTileOutputToSourceTransform(
                sourceOffset: SIMD2(1, 0),
                sourceStep: SIMD2(repeating: 1)
            )
        )
        #expect(first.specification.documentGeneration
            == translated.specification.documentGeneration)
        #expect(first.specification.addressingGeneration
            == translated.specification.addressingGeneration)
        #expect(first.specification.outputGeneration
            == translated.specification.outputGeneration)
        #expect(first.specification.key != translated.specification.key)
        let revoked = await context.snapshot().visiblePlan
        #expect(!revoked.currentIsPresentable)
    }

    @Test
    @MainActor
    func buildFailureRestoresOnlyExactStillRequestedPlan() async throws {
        guard let fixture = try makeFixture() else { return }
        let context = fixture.context
        let first = try await request(context, addressing: 1, output: 1)
        let firstPrepared = try await context.prepareVisiblePlan(first)
        _ = try await context.installVisiblePlan(firstPrepared)

        let exactRetry = try await request(context, addressing: 1, output: 1)
        #expect(await context.snapshot().visiblePlan.currentIsPresentable)
        await #expect(throws: SparseTileSamplingPlanError.invalidLimit) {
            _ = try await context.prepareVisiblePlan(
                exactRetry,
                limits: invalidLimits
            )
        }
        #expect(await context.snapshot().visiblePlan.currentIsPresentable)

        let changed = try await request(context, addressing: 2, output: 1)
        let changedSnapshot = await context.snapshot().visiblePlan
        #expect(!changedSnapshot.currentIsPresentable)
        await #expect(throws: SparseTileSamplingPlanError.invalidLimit) {
            _ = try await context.prepareVisiblePlan(
                changed,
                limits: invalidLimits
            )
        }
        let failedChangedSnapshot = await context.snapshot().visiblePlan
        #expect(!failedChangedSnapshot.currentIsPresentable)
    }

    @Test
    @MainActor
    func realUploadRingBoundsReturnsAndReusesEverySlot() async throws {
        guard let fixture = try makeFixture() else { return }
        let context = fixture.context
        try await installInitialPlan(context)
        var submissions: [DocumentPaintPreparedDisplaySubmission] = []
        for _ in 0..<SparseTileSamplingGPUPlanLimits.production
            .maximumInflightEncodes
        {
            submissions.append(try await context.prepareDisplaySubmission())
        }
        let full = await context.snapshot().visiblePlan
        #expect(full.preparedSubmissionCount == 3)
        #expect(full.uploadRing?.capacity == 3)
        #expect(full.uploadRing?.activeSlotCount == 3)
        await #expect(
            throws: DocumentPaintVisiblePlanControllerError
                .preparationBackpressure(capacity: 3)
        ) {
            _ = try await context.prepareDisplaySubmission()
        }

        try context.cancelDisplaySubmission(submissions.removeFirst())
        #expect(await context.snapshot().visiblePlan.uploadRing?.activeSlotCount == 2)
        submissions.append(try await context.prepareDisplaySubmission())
        #expect(await context.snapshot().visiblePlan.uploadRing?.activeSlotCount == 3)
        for submission in submissions {
            try context.cancelDisplaySubmission(submission)
        }
        let empty = await context.snapshot().visiblePlan
        #expect(empty.preparedSubmissionCount == 0)
        #expect(empty.uploadRing?.activeSlotCount == 0)

        let reused = try await context.prepareDisplaySubmission()
        #expect(await context.snapshot().visiblePlan.uploadRing?.activeSlotCount == 1)
        try context.cancelDisplaySubmission(reused)
        #expect(await context.snapshot().visiblePlan.uploadRing?.activeSlotCount == 0)
    }

    @Test
    @MainActor
    func stalePreparedSubmissionAbandonsAndReturnsRealSlot()
        async throws
    {
        guard let fixture = try makeFixture() else { return }
        let context = fixture.context
        try await installInitialPlan(context)
        let submission = try await context.prepareDisplaySubmission()
        #expect(await context.snapshot().visiblePlan.uploadRing?.activeSlotCount == 1)

        _ = try await request(context, addressing: 2, output: 1)
        #expect(await context.snapshot().visiblePlan.uploadRing?.activeSlotCount == 0)
        #expect(
            throws: DocumentPaintVisiblePlanControllerError.submissionAlreadyConsumed
        ) {
            try context.cancelDisplaySubmission(submission)
        }
    }

    @Test
    @MainActor
    func invalidOrForeignDisplayTargetDoesNotConsumeSubmission() async throws {
        guard let first = try makeFixture(),
              let second = try makeFixture()
        else { return }
        try await installInitialPlan(first.context)
        let submission = try await first.context.prepareDisplaySubmission()
        let correct = try makeTarget(device: first.device)
        let wrongDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: DocumentColorPipeline.workingPixelFormat,
            width: correct.width,
            height: correct.height,
            mipmapped: false
        )
        wrongDescriptor.storageMode = .shared
        wrongDescriptor.usage = [.renderTarget]
        let wrong = try #require(first.device.makeTexture(
            descriptor: wrongDescriptor
        ))
        let command = try #require(first.queue.makeCommandBuffer())
        #expect(throws: SparseTileSamplingPipelineError.invalidTarget(
            "target geometry or format"
        )) {
            try first.context.encodeDisplaySubmission(
                submission,
                target: wrong,
                commandBuffer: command,
                renderPassDescriptor: passDescriptor(target: wrong)
            )
        }
        #expect(throws: DocumentPaintVisiblePlanControllerError.foreignSubmission) {
            try second.context.encodeDisplaySubmission(
                submission,
                target: correct,
                commandBuffer: command,
                renderPassDescriptor: passDescriptor(target: correct)
            )
        }
        for invalidPass in [
            passDescriptor(
                target: correct,
                loadAction: .load
            ),
            passDescriptor(
                target: correct,
                loadAction: .dontCare
            ),
            passDescriptor(
                target: correct,
                storeAction: .dontCare
            ),
            passDescriptor(
                target: correct,
                clearColor: MTLClearColorMake(0, 0, 0, 0)
            ),
        ] {
            #expect(throws: SparseTileSamplingPipelineError.invalidTarget(
                "render pass opaque display contract"
            )) {
                try first.context.encodeDisplaySubmission(
                    submission,
                    target: correct,
                    commandBuffer: command,
                    renderPassDescriptor: invalidPass
                )
            }
        }
        try first.context.encodeDisplaySubmission(
            submission,
            target: correct,
            commandBuffer: command,
            renderPassDescriptor: passDescriptor(target: correct)
        )
        command.commit()
        await command.completed()
        #expect(command.status == .completed)
        #expect((try await waitForTerminal(first.context)).completedSubmissionCount == 1)
    }

    @Test
    @MainActor
    func overwriteKeepsOldPlanUntilExactCommandCompletion()
        async throws
    {
        guard let first = try makeFixture(),
              let second = try makeFixture()
        else { return }
        let context = first.context
        try await installInitialPlan(context)
        let target = try makeTarget(device: first.device)
        let submission = try await context.prepareDisplaySubmission()
        let command = try #require(first.queue.makeCommandBuffer())
        let pass = passDescriptor(target: target)
        try context.encodeDisplaySubmission(
            submission,
            target: target,
            commandBuffer: command,
            renderPassDescriptor: pass
        )
        var before = await context.snapshot().visiblePlan
        #expect(before.submittedSubmissionCount == 1)
        #expect(before.uploadRing?.activeSlotCount == 1)

        let replacement = try await request(context, addressing: 2, output: 1)
        let replacementPrepared = try await context.prepareVisiblePlan(
            replacement
        )
        _ = try await context.installVisiblePlan(replacementPrepared)
        before = await context.snapshot().visiblePlan
        #expect(before.retiringPlanCount == 1)
        #expect(before.submittedSubmissionCount == 1)

        #expect(
            throws: DocumentPaintVisiblePlanControllerError.foreignSubmission
        ) {
            try second.context.cancelDisplaySubmission(submission)
        }

        command.commit()
        await command.completed()
        #expect(command.status == .completed)
        let terminal = try await waitForTerminal(context)
        #expect(terminal.submittedSubmissionCount == 0)
        #expect(terminal.retiringPlanCount == 0)
        #expect(terminal.uploadRing?.activeSlotCount == 0)
        #expect(terminal.completedSubmissionCount == 1)
        let duplicateCommand = try #require(first.queue.makeCommandBuffer())
        #expect(
            throws: DocumentPaintVisiblePlanControllerError.submissionAlreadyConsumed
        ) {
            try context.encodeDisplaySubmission(
                submission,
                target: target,
                commandBuffer: duplicateCommand,
                renderPassDescriptor: pass
            )
        }
    }

    @Test
    @MainActor
    func concurrentNPlusOnePreparationReservesBeforeFirstAwait()
        async throws
    {
        let gate = DocumentPaintPreparationTestGate()
        var configuration = DocumentPaintVisiblePlanControllerConfiguration.production
        configuration.preparationGate = gate
        guard let fixture = try makeFixture(configuration: configuration) else {
            return
        }
        let context = fixture.context
        try await installInitialPlan(context)
        let tasks: [Task<DocumentPaintPreparedDisplaySubmission?, Never>] =
            (0..<4).map { _ in
            Task { @MainActor in
                do {
                    return try await context.prepareDisplaySubmission()
                } catch {
                    #expect(error as? DocumentPaintVisiblePlanControllerError
                        == .preparationBackpressure(capacity: 3))
                    return nil
                }
            }
        }
        var reserved = 0
        for _ in 0..<1_000 {
            reserved = await context.snapshot().visiblePlan
                .preparationReservationCount
            if reserved == 3 { break }
            await Task.yield()
        }
        #expect(reserved == 3)
        await gate.open()
        var frames: [DocumentPaintPreparedDisplaySubmission] = []
        for task in tasks {
            if let frame = await task.value { frames.append(frame) }
        }
        #expect(frames.count == 3)
        for frame in frames { try context.cancelDisplaySubmission(frame) }
        #expect(await context.snapshot().visiblePlan.preparedSubmissionCount == 0)
    }

    @Test
    @MainActor
    func supersessionWaitsForSuspendedDisplayReservationBeforeRetireAndACK()
        async throws
    {
        let gate = DocumentPaintPreparationTestGate()
        var configuration = DocumentPaintVisiblePlanControllerConfiguration
            .production
        configuration.preparationGate = gate
        guard let fixture = try makeFixture(configuration: configuration) else {
            return
        }
        let capability = try fixture.context.beginStrokeSurface()
        let source = try await installTestingTransientPlan(
            fixture.context,
            capability: capability
        )
        let suspended = Task { @MainActor in
            try await fixture.context.prepareDisplaySubmission()
        }
        try await waitForDisplayPreparationReservation(
            fixture.context,
            gate: gate
        )

        let canonical = try await request(
            fixture.context,
            addressing: 2,
            output: 1
        )
        let prepared = try await fixture.context.prepareVisiblePlan(canonical)
        _ = try await fixture.context.installVisiblePlan(prepared)
        let retained = await fixture.context.snapshot().visiblePlan
        #expect(retained.currentSpecification == canonical.specification)
        #expect(retained.currentIsPresentable)
        #expect(retained.preparationReservationCount == 1)
        #expect(retained.retiringPlanCount == 1)
        #expect(retained.pendingPlanCompletionCount == 0)
        #expect(retained.pendingConsumerCompletionCount == 0)
        #expect(retained.completedSubmissionCount == 0)
        #expect(retained.failedSubmissionCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 0)
        #expect(source.acknowledgementStatus == .available)
        #expect(!capability.isTerminal)

        await gate.open()
        await #expect(
            throws: DocumentPaintVisiblePlanControllerError.staleSubmission
        ) {
            _ = try await suspended.value
        }
        let settled = await fixture.context.snapshot().visiblePlan
        #expect(settled.currentSpecification == canonical.specification)
        #expect(settled.currentIsPresentable)
        #expect(settled.preparationReservationCount == 0)
        #expect(settled.retiringPlanCount == 0)
        #expect(settled.pendingPlanCompletionCount == 0)
        #expect(settled.pendingConsumerCompletionCount == 0)
        #expect(settled.completedSubmissionCount == 0)
        #expect(settled.failedSubmissionCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        #expect(!capability.isTerminal)

        // The replacement remains usable after the stale reservation settles.
        let replacement = try await fixture.context.prepareDisplaySubmission()
        let target = try makeTarget(device: fixture.device)
        let command = try #require(fixture.queue.makeCommandBuffer())
        try fixture.context.encodeDisplaySubmission(
            replacement,
            target: target,
            commandBuffer: command,
            renderPassDescriptor: passDescriptor(target: target)
        )
        command.commit()
        await command.completed()
        let rendered = try await waitForTerminal(fixture.context)
        #expect(rendered.completedSubmissionCount == 1)
        #expect(rendered.failedSubmissionCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 1)
    }

    @Test
    @MainActor
    func shutdownWaitsForSuspendedDisplayReservationBeforeRetireAndACK()
        async throws
    {
        let gate = DocumentPaintPreparationTestGate()
        var configuration = DocumentPaintVisiblePlanControllerConfiguration
            .production
        configuration.preparationGate = gate
        guard let fixture = try makeFixture(configuration: configuration) else {
            return
        }
        let capability = try fixture.context.beginStrokeSurface()
        let source = try await installTestingTransientPlan(
            fixture.context,
            capability: capability
        )
        let suspended = Task { @MainActor in
            try await fixture.context.prepareDisplaySubmission()
        }
        try await waitForDisplayPreparationReservation(
            fixture.context,
            gate: gate
        )

        let retained = try await fixture.context.shutdown(
            reason: .sessionReplacement
        )
        #expect(!retained.isComplete)
        #expect(retained.preparedSubmissionCount == 0)
        #expect(retained.submittedSubmissionCount == 0)
        #expect(retained.retiringPlanCount == 1)
        #expect(retained.pendingP4CompletionCount == 0)
        let retainedVisible = await fixture.context.snapshot().visiblePlan
        #expect(retainedVisible.preparationReservationCount == 1)
        #expect(retainedVisible.retiringPlanCount == 1)
        #expect(retainedVisible.completedSubmissionCount == 0)
        #expect(retainedVisible.failedSubmissionCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 0)
        #expect(source.acknowledgementStatus == .available)
        #expect(!capability.isTerminal)

        await gate.open()
        await #expect(
            throws: DocumentPaintVisiblePlanControllerError.staleSubmission
        ) {
            _ = try await suspended.value
        }
        let settled = await fixture.context.snapshot().visiblePlan
        #expect(settled.preparationReservationCount == 0)
        #expect(settled.retiringPlanCount == 0)
        #expect(settled.pendingPlanCompletionCount == 0)
        #expect(settled.pendingConsumerCompletionCount == 0)
        #expect(settled.completedSubmissionCount == 0)
        #expect(settled.failedSubmissionCount == 0)
        #expect(source.testingAcknowledgementRequestCount == 1)
        #expect(source.acknowledgementStatus == .fulfilled)
        #expect(!capability.isTerminal)

        let complete = try await fixture.context.shutdown(
            reason: .sessionReplacement
        )
        #expect(complete.isComplete)
        #expect(complete.retiringPlanCount == 0)
        #expect(complete.pendingP4CompletionCount == 0)
        #expect(capability.isTerminal)
        let idempotent = try await fixture.context.shutdown(
            reason: .sessionReplacement
        )
        #expect(idempotent == complete)
        #expect(source.testingAcknowledgementRequestCount == 1)
        let terminal = await fixture.context.snapshot().visiblePlan
        #expect(terminal.completedSubmissionCount == 0)
        #expect(terminal.failedSubmissionCount == 0)
    }

    @Test
    @MainActor
    func terminalFailureEarlyDuplicateAndImmediateReuseAreBounded()
        async throws
    {
        var configuration = DocumentPaintVisiblePlanControllerConfiguration.production
        configuration.injectEarlyTerminalNotification = true
        configuration.injectDuplicateTerminalNotification = true
        configuration.forceTerminalFailure = true
        guard let fixture = try makeFixture(configuration: configuration) else {
            return
        }
        let context = fixture.context
        try await installInitialPlan(context)
        let target = try makeTarget(device: fixture.device)
        let frame = try await context.prepareDisplaySubmission()
        let command = try #require(fixture.queue.makeCommandBuffer())
        try context.encodeDisplaySubmission(
            frame,
            target: target,
            commandBuffer: command,
            renderPassDescriptor: passDescriptor(target: target)
        )
        command.commit()
        await command.completed()

        // No snapshot/retry is needed before reuse; prepare drains the bounded
        // terminal receipt before reserving its new slot.
        let reused = try await context.prepareDisplaySubmission()
        let snapshot = await context.snapshot().visiblePlan
        #expect(snapshot.failedSubmissionCount == 1)
        #expect(snapshot.ignoredEarlyTerminalCount == 1)
        #expect(snapshot.ignoredDuplicateTerminalCount == 1)
        #expect(snapshot.uploadRing?.activeSlotCount == 1)
        try context.cancelDisplaySubmission(reused)
    }

    @Test
    @MainActor
    func repeatedRetirementFailureRetainsExactPlanUntilRetry()
        async throws
    {
        let injector = DocumentPaintVisiblePlanFailureInjector(
            retirementFailures: 2
        )
        var configuration = DocumentPaintVisiblePlanControllerConfiguration.production
        configuration.failureInjector = injector
        guard let fixture = try makeFixture(configuration: configuration) else {
            return
        }
        let context = fixture.context
        try await installInitialPlan(context)
        let replacement = try await request(context, addressing: 2, output: 1)
        let prepared = try await context.prepareVisiblePlan(replacement)
        _ = try await context.installVisiblePlan(prepared)
        #expect(await context.snapshot().visiblePlan.retiringPlanCount == 1)
        try await context.retryVisiblePlanRetirementsAndCompletions()
        #expect(await context.snapshot().visiblePlan.retiringPlanCount == 1)
        try await context.retryVisiblePlanRetirementsAndCompletions()
        #expect(await context.snapshot().visiblePlan.retiringPlanCount == 0)
    }

    @Test
    @MainActor
    func shutdownRevokesPreparedAndRetainsInflightUntilTerminal()
        async throws
    {
        guard let fixture = try makeFixture() else { return }
        let context = fixture.context
        try await installInitialPlan(context)
        let target = try makeTarget(device: fixture.device)
        let preparedFrame = try await context.prepareDisplaySubmission()
        try context.cancelDisplaySubmission(preparedFrame)
        let inFlight = try await context.prepareDisplaySubmission()
        let command = try #require(fixture.queue.makeCommandBuffer())
        try context.encodeDisplaySubmission(
            inFlight,
            target: target,
            commandBuffer: command,
            renderPassDescriptor: passDescriptor(target: target)
        )

        let pending = try await context.shutdown(reason: .sessionReplacement)
        #expect(!pending.isComplete)
        #expect(pending.submittedSubmissionCount == 1)
        #expect(pending.retiringPlanCount == 1)
        command.commit()
        await command.completed()
        let complete = try await context.shutdown(reason: .sessionReplacement)
        #expect(complete.isComplete)
        await #expect(
            throws: DocumentPaintVisiblePlanControllerError.shuttingDown
        ) {
            _ = try await request(context, addressing: 3, output: 1)
        }
    }

    @Test
    @MainActor
    func shutdownWaitsForSuspendedPlanBuildReservation() async throws {
        let gate = DocumentPaintPreparationTestGate()
        var configuration = DocumentPaintVisiblePlanControllerConfiguration.production
        configuration.planBuildGate = gate
        guard let fixture = try makeFixture(configuration: configuration) else {
            return
        }
        let context = fixture.context
        let request = try await request(context, addressing: 1, output: 1)
        let preparation = Task { @MainActor in
            try await context.prepareVisiblePlan(request)
        }

        var waitingCount = 0
        for _ in 0..<1_000 {
            waitingCount = await gate.waitingCount
            if waitingCount == 1 { break }
            await Task.yield()
        }
        #expect(waitingCount == 1)

        let pending = try await context.shutdown(reason: .sessionReplacement)
        #expect(!pending.isComplete)
        #expect(pending.ownedPlanReservationCount == 1)

        await gate.open()
        await #expect(
            throws: DocumentPaintVisiblePlanControllerError.shuttingDown
        ) {
            _ = try await preparation.value
        }

        let complete = try await context.shutdown(reason: .sessionReplacement)
        #expect(complete.isComplete)
        #expect(complete.ownedPlanReservationCount == 0)
        #expect(complete.retiringPlanCount == 0)
    }

    @MainActor
    private func installInitialPlan(
        _ context: DocumentPaintRenderContext
    ) async throws {
        let request = try await request(context, addressing: 1, output: 1)
        let prepared = try await context.prepareVisiblePlan(request)
        _ = try await context.installVisiblePlan(prepared)
    }

    @MainActor
    private func installTestingTransientPlan(
        _ context: DocumentPaintRenderContext,
        capability: DocumentPaintStrokeSurfaceCapability,
        acknowledgementReleaseFailures: [StrokePreparationFailure] = []
    ) async throws -> DocumentPaintTransientDisplaySource {
        let frame = StrokePreparedDisplayFrame.testing(
            capability: capability,
            acknowledgementIsAvailable: true,
            acknowledgementReleaseFailures: acknowledgementReleaseFailures
        )
        let source = try context.adoptTransientDisplayFrame(
            frame,
            addressing: .finite(PixelSize(width: 16, height: 16))
        )
        let request = try await context.requestTransientVisiblePlan(
            source,
            addressingRevision: 1,
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 16, maxY: 16
            ),
            outputGeometryRevision: 1
        )
        let prepared = try await context.prepareTransientVisiblePlan(request)
        _ = try await context.installVisiblePlan(prepared)
        return source
    }

    @MainActor
    private func makeTestingTransientSourceWithTile(
        _ context: DocumentPaintRenderContext,
        capability: DocumentPaintStrokeSurfaceCapability,
        acknowledgementReleaseFailures: [StrokePreparationFailure] = [],
        acknowledgementCompletionIsDeferred: Bool = false
    ) throws -> DocumentPaintTransientDisplaySource {
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
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
        return try context.adoptTransientDisplayFrame(
            .testing(
                capability: capability,
                layer: .authoritative,
                changedCoordinates: [coordinate],
                acknowledgementIsAvailable: true,
                acknowledgementReleaseFailures:
                    acknowledgementReleaseFailures,
                acknowledgementCompletionIsDeferred:
                    acknowledgementCompletionIsDeferred
            ),
            addressing: .finite(PixelSize(width: 16, height: 16))
        )
    }

    @MainActor
    private func request(
        _ context: DocumentPaintRenderContext,
        addressing: UInt64,
        output: UInt64,
        transform: SparseTileOutputToSourceTransform = .identity
    ) async throws -> DocumentPaintCanonicalVisiblePlanRequest {
        try await context.requestCanonicalVisiblePlan(
            addressing: .finite(PixelSize(width: 16, height: 16)),
            addressingRevision: addressing,
            outputRegion: try SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 16, maxY: 16
            ),
            outputGeometryRevision: output,
            outputMapping: .affine(transform)
        )
    }

    @MainActor
    private func waitForTerminal(
        _ context: DocumentPaintRenderContext
    ) async throws -> DocumentPaintVisiblePlanControllerSnapshot {
        for _ in 0..<1_000 {
            let snapshot = await context.snapshot().visiblePlan
            if snapshot.submittedSubmissionCount == 0 { return snapshot }
            await Task.yield()
        }
        Issue.record("sampling completion observer did not reach terminal")
        return await context.snapshot().visiblePlan
    }

    @MainActor
    private func waitForDisplayPreparationReservation(
        _ context: DocumentPaintRenderContext,
        gate: DocumentPaintPreparationTestGate
    ) async throws {
        for _ in 0..<1_000 {
            let reservationCount = await context.snapshot().visiblePlan
                .preparationReservationCount
            let waitingCount = await gate.waitingCount
            if reservationCount == 1 && waitingCount == 1 { return }
            await Task.yield()
        }
        Issue.record("display preparation did not suspend after reserving")
    }

    @MainActor
    private func waitForPreparedCoreRace(
        _ gate: DocumentPaintPreparedCoreRevocationRaceGate,
        revocationPaused: Bool = false,
        coreDeinitEntered: Bool = false
    ) async throws {
        for _ in 0..<1_000 {
            let snapshot = gate.snapshot
            if snapshot.revocationPaused == revocationPaused,
               snapshot.coreDeinitEntered == coreDeinitEntered
            {
                return
            }
            await Task.yield()
        }
        Issue.record("prepared-core revocation race did not reach its barrier")
    }

    @MainActor
    private func makeFixture(
        size: Int = 16,
        snapshotPayloadLiabilityByteBudget: Int? = nil,
        configuration: DocumentPaintVisiblePlanControllerConfiguration =
            .production
    ) throws -> (
        device: any MTLDevice,
        queue: any MTLCommandQueue,
        layerID: UUID,
        byteBudget: Int,
        context: DocumentPaintRenderContext
    )? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }
        let layerID = UUID()
        let byteBudget = PaintTileDescriptor.residentByteCount * 8
        let context = try DocumentPaintRenderContext(
            device: device,
            commandQueue: queue,
            library: makeShaderLibrary(device: device),
            geometry: try DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: size, height: size),
                storagePixelSize: PixelSize(width: size, height: size),
                radialLayout: nil
            ),
            initialLayerStack: try .single(id: layerID),
            byteBudget: byteBudget,
            snapshotPayloadLiabilityByteBudget:
                snapshotPayloadLiabilityByteBudget,
            transferByteCapacity: PaintTileDescriptor.residentByteCount * 16,
            maximumRevisionBytes: PaintTileDescriptor.residentByteCount * 16,
            generation: 7,
            visiblePlanConfiguration: configuration
        )
        return (device, queue, layerID, byteBudget, context)
    }

    private var invalidLimits: SparseTilePlanLimits {
        SparseTilePlanLimits(
            maximumPageEntries: 0,
            maximumPageChunks: 0,
            maximumPageTableBytes: 0,
            maximumBindingSlots: 0,
            maximumBindingChunks: 0,
            maximumBindingBytes: 0,
            maximumTexturesPerBatch: 0,
            maximumBatchCount: 0
        )
    }

    private func makeTarget(
        device: any MTLDevice
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: DocumentColorPipeline.displayPixelFormat,
            width: 16,
            height: 16,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func passDescriptor(
        target: any MTLTexture,
        loadAction: MTLLoadAction = .clear,
        storeAction: MTLStoreAction = .store,
        clearColor: MTLClearColor = MTLClearColorMake(0, 0, 0, 1)
    ) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = loadAction
        pass.colorAttachments[0].storeAction = storeAction
        pass.colorAttachments[0].clearColor = clearColor
        return pass
    }

    @MainActor
    private func makeShaderLibrary(
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
}

private final class DocumentPaintSubmissionOwnerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var submission: DocumentPaintPreparedDisplaySubmission?

    init(_ submission: DocumentPaintPreparedDisplaySubmission) {
        self.submission = submission
    }

    func dropLastWrapper() {
        lock.lock()
        submission = nil
        lock.unlock()
    }
}
