import EditorCore
import Foundation
import Metal
import PatternEngine
import Testing
@testable import MetalRenderer

@Suite("Persistent canonical composite tile cache", .serialized)
struct CanvasCompositeTileCacheTests {
    @Test
    func presentationMemoryEnvelopeIsOneCheckedPhysicalPartition() throws {
        let envelope = CanvasPresentationMemoryEnvelope.production

        let exactMetadata = CanvasPresentationMemoryEnvelope
            .canonicalProductionSnapshotMetadataBytes
        #expect(envelope.maximumPhysicalBytes
            == 1_024 * 1_024 * 1_024
                + 281 * 1_024 * 1_024 + exactMetadata)
        #expect(envelope.documentStoreBytes == 512 * 1_024 * 1_024)
        #expect(envelope.transientCacheBytes == 512 * 1_024 * 1_024)
        #expect(envelope.canonicalCacheBytes
            == 281 * 1_024 * 1_024 + exactMetadata)
        #expect(envelope.canonicalStoreTransferBytes == 265 * 1_024 * 1_024)
        #expect(envelope.canonicalSnapshotMetadataBytes == exactMetadata)
        #expect(try envelope.checkedPartitionByteCount()
            == envelope.maximumPhysicalBytes)
        #expect(envelope.canonicalBatchWorkspaceBytes
            >= 3 * PaintTileDescriptor.residentByteCount)
        let canonicalPartition = envelope.canonicalResidentBytes
            + envelope.canonicalBatchWorkspaceBytes
            + envelope.canonicalCopyOnWriteHeadroomBytes
            + envelope.canonicalSnapshotMetadataBytes
        #expect(canonicalPartition == envelope.canonicalCacheBytes)
        #expect(envelope.canonicalStoreTransferBytes
            == envelope.canonicalResidentBytes
                + envelope.canonicalCopyOnWriteHeadroomBytes)

        let highMemory = try CanvasPresentationMemoryEnvelope.production(
            recommendedMaxWorkingSetSize: 8_000 * 1_024 * 1_024,
            platform: .macOS
        )
        #expect(highMemory.documentStoreBytes == 512 * 1_024 * 1_024)
        #expect(highMemory.transientCacheBytes == 512 * 1_024 * 1_024)
        #expect(highMemory.canonicalCacheBytes
            == 281 * 1_024 * 1_024 + exactMetadata)
        #expect(highMemory.maximumPhysicalBytes
            == 1_024 * 1_024 * 1_024 + highMemory.canonicalCacheBytes)
        #expect(try highMemory.checkedPartitionByteCount()
            == highMemory.maximumPhysicalBytes)

        let negative = CanvasPresentationMemoryEnvelope(
            maximumPhysicalBytes: 1,
            documentStoreBytes: -1,
            transientCacheBytes: 1,
            canonicalCacheBytes: 1,
            canonicalResidentBytes: 0,
            canonicalBatchWorkspaceBytes: 0,
            canonicalCopyOnWriteHeadroomBytes: 1,
            canonicalSnapshotMetadataBytes: 0,
            canonicalStoreTransferBytes: 1
        )
        #expect(throws: CanvasPresentationMemoryEnvelopeError.self) {
            _ = try negative.checkedPartitionByteCount()
        }
    }

    @Test
    func lowAndUnknownDeviceBudgetsPreserveStartupAndPlatformPolicy()
        throws
    {
        let mebibyte = UInt64(1_024 * 1_024)
        let low = try CanvasPresentationMemoryEnvelope.production(
            recommendedMaxWorkingSetSize: 128 * mebibyte,
            platform: .iOS
        )
        #expect(low.documentStoreBytes == 512 * Int(mebibyte))
        #expect(low.transientCacheBytes == 512 * Int(mebibyte))
        #expect(low.canonicalStoreTransferBytes == 0)
        #expect(low.canonicalCacheBytes == 0)
        #expect(try low.checkedPartitionByteCount()
            == low.maximumPhysicalBytes)

        let unknownMac = try CanvasPresentationMemoryEnvelope.production(
            recommendedMaxWorkingSetSize: 0,
            platform: .macOS
        )
        let unknownIOS = try CanvasPresentationMemoryEnvelope.production(
            recommendedMaxWorkingSetSize: 0,
            platform: .iOS
        )
        #expect(unknownMac.canonicalCacheBytes
            == 281 * Int(mebibyte)
                + CanvasPresentationMemoryEnvelope
                    .canonicalProductionSnapshotMetadataBytes)
        #expect(unknownIOS.canonicalCacheBytes
            < unknownMac.canonicalCacheBytes)
        #expect(unknownIOS.canonicalStoreTransferBytes == 0)
        #expect(try unknownIOS.checkedPartitionByteCount()
            == unknownIOS.maximumPhysicalBytes)
    }

    @Test
    @MainActor
    func canonicalEnableThresholdProvesOneTileInitialAndCOWCapacity()
        async throws
    {
        let legacy = UInt64(
            CanvasPresentationMemoryEnvelope.legacyDocumentProductionBytes
                + CanvasPresentationMemoryEnvelope
                    .legacyTransientProductionBytes
        )
        let fixed = UInt64(
            CanvasPresentationMemoryEnvelope.canonicalProductionWorkspaceBytes
                + CanvasPresentationMemoryEnvelope
                    .canonicalProductionSnapshotMetadataBytes
        )
        let threeTiles = UInt64(3 * PaintTileDescriptor.residentByteCount)
        let below = try CanvasPresentationMemoryEnvelope.production(
            recommendedMaxWorkingSetSize: legacy + fixed + threeTiles - 1,
            platform: .macOS
        )
        #expect(below.documentStoreBytes == 512 * 1_024 * 1_024)
        #expect(below.transientCacheBytes == 512 * 1_024 * 1_024)
        #expect(below.canonicalCacheBytes == 0)

        let exact = try CanvasPresentationMemoryEnvelope.production(
            recommendedMaxWorkingSetSize: legacy + fixed + threeTiles,
            platform: .macOS
        )
        #expect(exact.canonicalStoreTransferBytes == Int(threeTiles))
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer],
            envelope: exact
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        _ = try await rig.applyInitial()
        var stack = rig.context.layerStack
        try stack.setOpacity(layer.id, opacity: 0.5)
        let change = try rig.context.applyLayerStack(stack)
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: change.baseCanonicalIdentity,
            targetIdentity: change.targetCanonicalIdentity,
            invalidation: change.compositeInvalidation,
            cachedCoordinates: [coordinate]
        )
        _ = try await rig.cache.apply(plan)
        let diagnostics = await rig.cache.snapshot()
        #expect(diagnostics.totalPhysicalByteCount
            <= diagnostics.maximumPhysicalBytes)
        #expect(diagnostics.physicalByteHighWater
            <= diagnostics.maximumPhysicalBytes)
        if let revision = change.revision {
            try await rig.context.releaseRevisions([revision.id])
        }
    }

    @Test
    @MainActor
    func cacheRejectsCompositorOutsideItsWorkspacePartition() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let compositor = try LayerCompositor.make(
            device: device,
            library: canvasCompositeTestLibrary(device: device),
            backendRequest: .forceFallback
        )
        do {
            let cache = try CanvasCompositeTileCache(
                device: device,
                compositor: CanonicalTileCompositor(wrapping: compositor),
                storagePixelSize: PixelSize(width: 256, height: 256),
                baselineIdentity: CanvasCanonicalStateIdentity(
                    documentGeneration: 0,
                    geometry: try DocumentPaintGeometry(
                        documentPixelSize: PixelSize(width: 256, height: 256),
                        storagePixelSize: PixelSize(width: 256, height: 256),
                        radialLayout: nil
                    ),
                    geometryRevision: 0,
                    layerStackRevision: 0,
                    compositeRevision: 0
                )
            )
            try await cache.shutdown()
            Issue.record("unpartitioned compositor unexpectedly accepted")
        } catch let error as CanvasPresentationMemoryEnvelopeError {
            #expect(error == .invalidPartition(
                required: 66 * 1_024 * 1_024,
                maximum: CanvasPresentationMemoryEnvelope.production
                    .canonicalBatchWorkspaceBytes
            ))
        }
        try await compositor.shutdown()
    }

    @Test
    func invalidationClassificationSeparatesRasterFullMetadataAndNoOp()
        throws
    {
        let active = UUID()
        let second = UUID()
        let bottom = try layer(active, name: "Bottom")
        let top = try layer(second, name: "Top")
        let before = try LayerStack(
            layers: [bottom, top],
            activeLayerID: active
        )
        let dirty = [
            PaintTileCoordinate(x: 29, y: 17),
            PaintTileCoordinate(x: 0, y: 0),
        ]

        #expect(CanvasCompositeInvalidation.classify(
            before: before,
            after: before,
            rasterDirtyCoordinates: dirty,
            geometryChanged: false,
            documentReplaced: false
        ) == .exact(dirty.sorted()))
        #expect(CanvasCompositeInvalidation.classify(
            before: before,
            after: try LayerStack(
                layers: [bottom, try layer(second, name: "Top", opacity: 0.5)],
                activeLayerID: active
            ),
            rasterDirtyCoordinates: [],
            geometryChanged: false,
            documentReplaced: false
        ) == .full)
        #expect(CanvasCompositeInvalidation.classify(
            before: before,
            after: try LayerStack(
                layers: [try layer(active, name: "Renamed"), top],
                activeLayerID: active
            ),
            rasterDirtyCoordinates: [],
            geometryChanged: false,
            documentReplaced: false
        ) == .metadataOnly)
        #expect(CanvasCompositeInvalidation.classify(
            before: before,
            after: before,
            rasterDirtyCoordinates: [],
            geometryChanged: false,
            documentReplaced: false
        ) == .none)
        #expect(CanvasCompositeInvalidation.classify(
            before: before,
            after: before,
            rasterDirtyCoordinates: [],
            geometryChanged: true,
            documentReplaced: false
        ) == .full)
    }

    @Test
    func disjointDirtiesRemainTwoPhysicalTileRegions() throws {
        let size = PixelSize(
            width: PaintTileDescriptor.side * 30,
            height: PaintTileDescriptor.side * 18
        )
        let dirties = [
            PaintTileCoordinate(x: 29, y: 17),
            PaintTileCoordinate(x: 0, y: 0),
        ]

        let regions = try CanvasCompositeTileUpdatePlan.outputRegions(
            dirtyCoordinates: dirties,
            storagePixelSize: size
        )

        #expect(regions.count == 2)
        #expect(regions.map { $0.width } == [256, 256])
        #expect(regions.map { $0.height } == [256, 256])
        let pixelCount = regions.reduce(0) {
            $0 + $1.width * $1.height
        }
        #expect(pixelCount == 2 * PaintTileDescriptor.side
            * PaintTileDescriptor.side)
    }

    @Test
    func batchPolicyBoundsSubmissionsScratchAndPreparedResources() throws {
        let policy = try CanvasCompositeBatchPolicy(
            maximumTilesPerChunk: 8,
            maximumLayersPerTile: 8
        )
        let metrics = try policy.structuralMetrics(
            tileCount: 30,
            layerCount: 8
        )

        #expect(metrics.commandSubmissionCount == 4)
        #expect(metrics.commandWaitCount == 4)
        #expect(metrics.sampleEncodeCount == 240)
        #expect(metrics.scratchSetCount == 1)
        #expect(metrics.maximumScratchPixelCount
            == PaintTileDescriptor.side * PaintTileDescriptor.side)
        #expect(metrics.maximumPreparedSubmissionCount == 64)
    }

    @Test
    @MainActor
    func exactUpdateIsPhysicalCopyOnWriteAndOldSnapshotRemainsImmutable()
        async throws
    {
        let bottom = try layer(UUID(), name: "Bottom")
        let top = try layer(UUID(), name: "Top")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 30 * 256, height: 18 * 256),
            layers: [bottom, top]
        ) else { return }
        let coordinates = [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
            PaintTileCoordinate(x: 2, y: 0),
            PaintTileCoordinate(x: 29, y: 17),
        ]
        let bottomColors = Dictionary(uniqueKeysWithValues:
            coordinates[1...2].enumerated().map { index, coordinate in
                (coordinate, SIMD4<Float>(Float(index + 1) / 8, 0, 0, 1))
            })
        let topColors = Dictionary(uniqueKeysWithValues:
            [coordinates[0], coordinates[3]].enumerated().map {
                index, coordinate in
                (coordinate, SIMD4<Float>(0, Float(index + 1) / 4, 0, 1))
            })
        try await rig.install([
            bottom.id: bottomColors,
            top.id: topColors,
        ])
        let initialRevision = try await rig.applyInitial()
        let old = try await rig.cache.current(expected: initialRevision)
        let oldReferences = try old.exactReferences()
        let oldPayload = try await old.testingPayloadFingerprint(
            at: coordinates[0]
        )

        let base = rig.context.canonicalStateIdentity()
        let cleared = try await rig.context.clear()
        let target = cleared.canonicalIdentity
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: base,
            targetIdentity: target,
            invalidation: .exact(cleared.dirtyCoordinates),
            cachedCoordinates: coordinates
        )
        for tile in plan.preparedTiles {
            for preparedLayer in tile.layers {
                let records = preparedLayer.samplingPlan.bindingRecords
                #expect(Set(records.map(\.globalSlot)).count == records.count)
                #expect(Set(records.map { $0.reference }).count == records.count)
            }
        }
        let revision = try await rig.cache.apply(plan)
        let current = try await rig.cache.current(expected: revision)
        let currentReferences = try current.exactReferences()

        #expect(plan.preparedTiles.map(\.outputRegion).map { $0.width }
            == [256, 256])
        #expect(Set(oldReferences).intersection(currentReferences).count == 2)
        #expect(currentReferences == oldReferences.filter {
            $0.coordinate == coordinates[1] || $0.coordinate == coordinates[2]
        })
        #expect(try await old.testingPayloadFingerprint(at: coordinates[0])
            == oldPayload)
        #expect(!(try current.exactReferences()).contains {
            $0.coordinate == coordinates[0]
        })
        let diagnostics = await rig.cache.snapshot()
        #expect(diagnostics.lastBatchMetrics?.maximumScratchPixelCount
            == 256 * 256)
        #expect(diagnostics.lastBatchMetrics?.commandSubmissionCount == 1)
        #expect(diagnostics.lastBatchMetrics?.sampleEncodeCount == 1)
        old.close()
        current.close()
        if let pair = cleared.historyPair {
            try await rig.context.releaseRevisions(pair.revisionIDs)
        }
    }

    @Test
    @MainActor
    func transparentTopRemovalRevealsLowerLayerAndAllocatesNoCoverage()
        async throws
    {
        let bottom = try layer(UUID(), name: "Bottom")
        let top = try layer(UUID(), name: "Top")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [bottom, top]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            bottom.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
            top.id: [coordinate: SIMD4<Float>(0, 0, 0.5, 0.5)],
        ])
        let firstRevision = try await rig.applyInitial()
        let first = try await rig.cache.current(expected: firstRevision)
        let firstTexel = try await first.testingRGBA16FirstTexel(
            at: coordinate
        )
        #expect(firstTexel == SIMD4<Float16>(0.25, 0, 0.5, 1))
        first.close()

        let base = rig.context.canonicalStateIdentity()
        let cleared = try await rig.context.clear()
        let target = cleared.canonicalIdentity
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: base,
            targetIdentity: target,
            invalidation: cleared.compositeInvalidation,
            cachedCoordinates: [coordinate]
        )
        let revision = try await rig.cache.apply(plan)
        let current = try await rig.cache.current(expected: revision)
        let revealed = try await current.testingRGBA16FirstTexel(
            at: coordinate
        )
        #expect(revealed == SIMD4<Float16>(0.5, 0, 0, 1))
        let diagnostics = await rig.cache.snapshot()
        #expect(diagnostics.cachedCoordinates == [coordinate])
        #expect(diagnostics.residentByteCount
            == PaintTileDescriptor.residentByteCount)
        #expect(diagnostics.componentCoverageByteCount == 0)
        #expect(diagnostics.totalStorePhysicalByteCount
            <= diagnostics.maximumPhysicalBytes)
        current.close()
        if let pair = cleared.historyPair {
            try await rig.context.releaseRevisions(pair.revisionIDs)
        }
    }

    @Test
    @MainActor
    func productionEraseStrokeOnTopLayerRevealsLowerCanonicalPixel()
        async throws
    {
        let bottom = try layer(UUID(), name: "Bottom")
        let top = try layer(UUID(), name: "Top")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [bottom, top]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            bottom.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
            top.id: [coordinate: SIMD4<Float>(0, 0, 0.5, 0.5)],
        ])
        let initialRevision = try await rig.applyInitial()
        let initial = try await rig.cache.current(expected: initialRevision)
        #expect(try await initial.testingRGBA16FirstTexel(at: coordinate)
            == SIMD4<Float16>(0.25, 0, 0.5, 1))
        initial.close()

        let capability = try rig.context.beginStrokeSurface()
        let frame = try capability.reserveStrokeTiles(
            role: .authoritative,
            coordinates: [coordinate],
            pinReasons: [.dirty, .inFlight],
            workspace: PaintTileStrokeLeaseWorkspace(maximumBindingCount: 1),
            failureInjection: nil
        )
        try fillCompositeTexture(
            frame.bindings[0].texture,
            color: SIMD4<Float16>(1, 1, 1, 1),
            device: rig.device
        )
        try capability.testingMarkDirty(frame)
        try capability.releaseFrameReservations(
            authoritative: frame,
            prediction: nil
        )
        let source = try #require(try capability.issueCommitMutationSource())
        let erased = try await rig.context.commitStroke(
            source,
            compositeParameters: DocumentPaintStrokeCompositeParameters(
                mode: .erase,
                strokeOpacity: 1,
                accumulationLimit: 1,
                eraserStrength: 1
            )
        )
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: erased.baseCanonicalIdentity,
            targetIdentity: erased.canonicalIdentity,
            invalidation: erased.compositeInvalidation,
            cachedCoordinates: [coordinate]
        )
        let revision = try await rig.cache.apply(plan)
        let current = try await rig.cache.current(expected: revision)
        #expect(try await current.testingRGBA16FirstTexel(at: coordinate)
            == SIMD4<Float16>(0.5, 0, 0, 1))
        #expect(await rig.cache.snapshot().componentCoverageByteCount == 0)
        current.close()
        if let pair = erased.historyPair {
            try await rig.context.releaseRevisions(pair.revisionIDs)
        }
    }

    @Test
    @MainActor
    func cacheFullTileParityMatchesNonuniformCPUAndExportOracles()
        async throws
    {
        let cases: [(LayerBlendMode, Float)] = [
            (.normal, 0), (.normal, 0.5), (.normal, 1),
            (.multiply, 0.5), (.multiply, 1),
            (.screen, 0.5), (.screen, 1),
        ]
        for (index, value) in cases.enumerated() {
            let bottom = try layer(UUID(), name: "Bottom")
            let top = try layer(
                UUID(),
                name: "Top",
                opacity: value.1,
                blendMode: value.0
            )
            guard let rig = try CacheRig.make(
                size: PixelSize(width: 256, height: 256),
                layers: [bottom, top]
            ) else { return }
            let coordinate = PaintTileCoordinate(x: 0, y: 0)
            let bottomSample: (Int, Int) -> SIMD4<Float> = { x, y in
                SIMD4(
                    Float((x % 4) + 2) / 16,
                    Float((y % 4) + 1) / 16,
                    Float(((x + y) % 3) + 1) / 32,
                    1
                )
            }
            let topSample: (Int, Int) -> SIMD4<Float> = { x, y in
                let alpha = Float(((x / 17 + y / 29) % 3) + 2) / 8
                return SIMD4(
                    alpha / 4,
                    alpha / 2,
                    alpha / 8,
                    alpha
                )
            }
            let bottomPayload = patternedCompositePayload(bottomSample)
            let topPayload = patternedCompositePayload(topSample)
            try await rig.installNativePayloads([
                bottom.id: [coordinate: bottomPayload],
                top.id: [coordinate: topPayload],
            ])
            let revision = try await rig.applyInitial()
            let snapshot = try await rig.cache.current(expected: revision)
            let stack = try LayerStack(
                layers: [bottom, top],
                activeLayerID: top.id
            )
            let expectedAt: (Int, Int) -> SIMD4<Float> = { x, y in
                let bottomColor = quantizedRGBA16(bottomSample(x, y))
                let topColor = quantizedRGBA16(topSample(x, y))
                return LayerCPUCompositingReference.composite(
                    stack: stack,
                    sample: { descriptor in
                        descriptor.id == bottom.id
                            ? bottomColor : topColor
                    }
                )
            }
            let export = try await rig.context.exportFiniteCanvas(
                strategy: TilingStrategy(
                    documentConfiguration: .finite(.plain),
                    canvasSize: PixelSize(width: 256, height: 256)
                ),
                outputGeometryRevision: UInt64(index + 1),
                transparentBackground: true
            )
            #expect(try await snapshot.testingEncodedBGRA8Fingerprint(
                at: coordinate
            ) == compositePayloadFingerprint(Data(export.bgra8Bytes)))
            let probes = [
                (0, 0), (255, 0), (0, 255), (255, 255),
                (73, 149), (127, 31),
            ]
            for (x, y) in probes {
                let cacheTexel = try await snapshot.testingRGBA16Texel(
                    at: coordinate,
                    x: x,
                    y: y
                )
                let expected = expectedAt(x, y)
                for channel in 0..<4 {
                    #expect(
                        abs(Float(cacheTexel[channel]) - expected[channel])
                            <= 0.002,
                        "parity case \(index), (\(x), \(y)), channel \(channel)"
                    )
                }
                let encoded = DocumentColorPipeline
                    .exportEncodedPremultipliedBGRA8(
                        try #require(LinearPremultipliedColor(
                            red: Float(cacheTexel.x),
                            green: Float(cacheTexel.y),
                            blue: Float(cacheTexel.z),
                            alpha: Float(cacheTexel.w)
                        ))
                    )
                let byteOffset = (y * 256 + x) * 4
                #expect(Array(export.bgra8Bytes[
                    byteOffset..<(byteOffset + 4)
                ]) == [
                    encoded.blue, encoded.green,
                    encoded.red, encoded.alpha,
                ])
            }
            snapshot.close()
        }
    }

    @Test
    @MainActor
    func stalePlanRejectsBeforeAllocationAndClosesItsExactCapture()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        let base = rig.context.canonicalStateIdentity()
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: base,
            targetIdentity: base,
            invalidation: .full,
            cachedCoordinates: []
        )
        var targetStack = rig.context.layerStack
        try targetStack.setOpacity(layer.id, opacity: 0.75)
        let change = try rig.context.applyLayerStack(targetStack)

        await #expect(throws: CanvasCompositeTileCacheError.staleIdentity(
            expected: base,
            current: change.targetCanonicalIdentity
        )) {
            _ = try await rig.cache.apply(plan)
        }
        #expect(plan.isClosed)
        let diagnostics = await rig.cache.snapshot()
        #expect(diagnostics.revision == nil)
        #expect(diagnostics.totalStorePhysicalByteCount == 0)
        #expect(diagnostics.activeUpdateCount == 0)
        #expect(diagnostics.candidateLeaseCount == 0)
        if let revision = change.revision {
            try await rig.context.releaseRevisions([revision.id])
        }
    }

    @Test
    @MainActor
    func canonicalClaimRejectsSplicedBaseScopeAndDirtiesBeforeAllocation()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        _ = try await rig.applyInitial()

        let result = try await rig.context.clear()
        let forgedBase = CanvasCanonicalStateIdentity(
            documentGeneration: result.baseCanonicalIdentity.documentGeneration,
            geometry: result.baseCanonicalIdentity.geometry,
            geometryRevision: result.baseCanonicalIdentity.geometryRevision,
            layerStackRevision: result.baseCanonicalIdentity.layerStackRevision,
            compositeRevision: result.baseCanonicalIdentity.compositeRevision + 1
        )

        func expectPreparationRejected(
            base: CanvasCanonicalStateIdentity,
            invalidation: CanvasCompositeInvalidation,
            cachedCoordinates: [PaintTileCoordinate]
        ) {
            do {
                let plan = try rig.context.prepareCompositeTileUpdatePlan(
                    baseIdentity: base,
                    targetIdentity: result.canonicalIdentity,
                    invalidation: invalidation,
                    cachedCoordinates: cachedCoordinates
                )
                plan.close()
                Issue.record("spliced canonical application was accepted")
            } catch {
                #expect(error is CanvasCompositeTileCacheError)
            }
        }

        expectPreparationRejected(
            base: forgedBase,
            invalidation: result.compositeInvalidation,
            cachedCoordinates: [coordinate]
        )
        expectPreparationRejected(
            base: result.baseCanonicalIdentity,
            invalidation: .full,
            cachedCoordinates: [coordinate]
        )
        expectPreparationRejected(
            base: result.baseCanonicalIdentity,
            invalidation: .exact([]),
            cachedCoordinates: [coordinate]
        )

        let beforeApply = await rig.cache.snapshot()
        #expect(beforeApply.cachedCoordinates == [coordinate])
        #expect(beforeApply.candidateLeaseCount == 0)
        #expect(beforeApply.activeUpdateCount == 0)

        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: result.baseCanonicalIdentity,
            targetIdentity: result.canonicalIdentity,
            invalidation: result.compositeInvalidation,
            cachedCoordinates: [coordinate]
        )
        _ = try await rig.cache.apply(plan)
        if let pair = result.historyPair {
            try await rig.context.releaseRevisions(pair.revisionIDs)
        }
    }

    @Test
    @MainActor
    func revokedBetweenFinalValidationAndAssignmentCannotPublish()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        let initialRevision = try await rig.applyInitial()
        let result = try await rig.context.clear()
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: result.baseCanonicalIdentity,
            targetIdentity: result.canonicalIdentity,
            invalidation: result.compositeInvalidation,
            cachedCoordinates: [coordinate]
        )

        await #expect(throws: CanvasCompositeTileCacheError.self) {
            _ = try await rig.cache.apply(
                plan,
                beforePublicationClaimForTesting: {
                    try await MainActor.run {
                        var stack = rig.context.layerStack
                        try stack.setOpacity(layer.id, opacity: 0.5)
                        _ = try rig.context.applyLayerStack(stack)
                    }
                }
            )
        }
        let diagnostics = await rig.cache.snapshot()
        #expect(diagnostics.revision == initialRevision)
        #expect(diagnostics.activeUpdateCount == 0)
        #expect(diagnostics.candidateLeaseCount == 0)
        #expect(diagnostics.preparedRetirementCount == 0)
        #expect(diagnostics.pendingRetirementCount == 0)
        if let pair = result.historyPair {
            try await rig.context.releaseRevisions(pair.revisionIDs)
        }
    }

    @Test
    @MainActor
    func fullUpdateCannotOmitPreviouslyPublishedCoordinate()
        async throws
    {
        let bottom = try layer(UUID(), name: "Bottom")
        let top = try layer(UUID(), name: "Top")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 512, height: 256),
            layers: [bottom, top]
        ) else { return }
        let bottomCoordinate = PaintTileCoordinate(x: 0, y: 0)
        let topCoordinate = PaintTileCoordinate(x: 1, y: 0)
        try await rig.install([
            bottom.id: [bottomCoordinate: SIMD4<Float>(0.5, 0, 0, 1)],
            top.id: [topCoordinate: SIMD4<Float>(0, 0.5, 0, 1)],
        ])
        let initial = try await rig.applyInitial()

        var stack = rig.context.layerStack
        try stack.setVisibility(top.id, isVisible: false)
        let result = try rig.context.applyLayerStack(stack)
        let omitted = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: result.baseCanonicalIdentity,
            targetIdentity: result.targetCanonicalIdentity,
            invalidation: result.compositeInvalidation,
            cachedCoordinates: []
        )

        await #expect(throws: CanvasCompositeTileCacheError.self) {
            _ = try await rig.cache.apply(omitted)
        }
        let diagnostics = await rig.cache.snapshot()
        #expect(diagnostics.revision == initial)
        #expect(diagnostics.cachedCoordinates == [
            bottomCoordinate, topCoordinate,
        ])
        #expect(diagnostics.activeUpdateCount == 0)
        if let revision = result.revision {
            try await rig.context.releaseRevisions([revision.id])
        }
    }

    @Test
    @MainActor
    func firstPublicationRejectsTransitionFromUnregisteredBaseline()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        var stack = rig.context.layerStack
        try stack.setVisibility(layer.id, isVisible: false)
        let result = try rig.context.applyLayerStack(stack)
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: result.baseCanonicalIdentity,
            targetIdentity: result.targetCanonicalIdentity,
            invalidation: result.compositeInvalidation,
            cachedCoordinates: []
        )

        await #expect(throws: CanvasCompositeTileCacheError.revisionGap(
            expectedBase: rig.baselineIdentity,
            actualBase: result.baseCanonicalIdentity
        )) {
            _ = try await rig.cache.apply(plan)
        }
        let diagnostics = await rig.cache.snapshot()
        #expect(diagnostics.revision == nil)
        #expect(diagnostics.totalStorePhysicalByteCount == 0)
        if let revision = result.revision {
            try await rig.context.releaseRevisions([revision.id])
        }
    }

    @Test
    @MainActor
    func reserveFailureIsPrepublicationAndLeavesNoTerminalOwnership()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 512, height: 256),
            layers: [layer]
        ) else { return }
        let coordinates = [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
        ]
        try await rig.install([
            layer.id: Dictionary(uniqueKeysWithValues: coordinates.map {
                ($0, SIMD4<Float>(0.5, 0, 0, 1))
            }),
        ])
        let identity = rig.context.canonicalStateIdentity()
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: identity,
            targetIdentity: identity,
            invalidation: .full,
            cachedCoordinates: []
        )

        await #expect(
            throws: PaintTileStoreError.injectedAllocationFailure(
                reserveIndex: 1
            )
        ) {
            _ = try await rig.cache.apply(
                plan,
                destinationFailureInjection: .init(
                    failingAtReserveIndex: 1
                )
            )
        }
        #expect(plan.isClosed)
        let diagnostics = await rig.cache.snapshot()
        #expect(diagnostics.revision == nil)
        #expect(diagnostics.totalStorePhysicalByteCount == 0)
        #expect(diagnostics.activeUpdateCount == 0)
        #expect(diagnostics.sourceSnapshotTokenCount == 0)
        #expect(diagnostics.candidateLeaseCount == 0)
        #expect(diagnostics.preparedRetirementCount == 0)
        #expect(diagnostics.pendingRetirementCount == 0)
    }

    @Test
    @MainActor
    func skippedMetadataRevisionIsRejectedAsAGap() async throws {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let baseRevision = try await rig.applyInitial()
        let baseIdentity = baseRevision.identity
        var stack = rig.context.layerStack
        try stack.rename(layer.id, to: "First")
        let first = try rig.context.applyLayerStack(stack)
        try stack.rename(layer.id, to: "Second")
        let second = try rig.context.applyLayerStack(stack)
        let targetIdentity = rig.context.canonicalStateIdentity()
        #expect(first.didPublish)
        #expect(second.didPublish)
        #expect(targetIdentity.layerStackRevision
            == baseIdentity.layerStackRevision + 2)
        #expect(throws: CanvasCompositeTileCacheError.invalidPlan) {
            _ = try rig.context.prepareCompositeTileUpdatePlan(
                baseIdentity: baseIdentity,
                targetIdentity: targetIdentity,
                invalidation: .metadataOnly,
                cachedCoordinates: []
            )
        }
        for revision in [first.revision, second.revision].compactMap({ $0 }) {
            try await rig.context.releaseRevisions([revision.id])
        }
    }

    @Test
    @MainActor
    func metadataRebaseCarriesExactReferencesWithoutGPUWork() async throws {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        let initialRevision = try await rig.applyInitial()
        let initial = try await rig.cache.current(expected: initialRevision)
        let references = try initial.exactReferences()
        let metrics = await rig.cache.snapshot().lastBatchMetrics
        initial.close()
        var stack = rig.context.layerStack
        try stack.rename(layer.id, to: "Renamed")
        let change = try rig.context.applyLayerStack(stack)
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: change.baseCanonicalIdentity,
            targetIdentity: change.targetCanonicalIdentity,
            invalidation: change.compositeInvalidation,
            cachedCoordinates: [coordinate]
        )

        let revision = try await rig.cache.apply(plan)
        let rebased = try await rig.cache.current(expected: revision)

        #expect(try rebased.exactReferences() == references)
        #expect(await rig.cache.snapshot().lastBatchMetrics == metrics)
        rebased.close()
        if let history = change.revision {
            try await rig.context.releaseRevisions([history.id])
        }
    }

    @Test
    @MainActor
    func staleAfterGPUCompletionCannotPublishAndSettlesCandidateOwnership()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        let identity = rig.context.canonicalStateIdentity()
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: identity,
            targetIdentity: identity,
            invalidation: .full,
            cachedCoordinates: []
        )

        await #expect(throws: CanvasCompositeTileCacheError.self) {
            _ = try await rig.cache.apply(
                plan,
                afterCompositionForTesting: { @MainActor in
                    rig.context.testingInvalidateCanonicalIdentityClaim()
                }
            )
        }

        #expect(plan.isClosed)
        let diagnostics = await rig.cache.snapshot()
        #expect(diagnostics.revision == nil)
        #expect(diagnostics.activeUpdateCount == 0)
        #expect(diagnostics.sourceSnapshotTokenCount == 0)
        #expect(diagnostics.candidateLeaseCount == 0)
        #expect(diagnostics.preparedRetirementCount == 0)
        #expect(diagnostics.pendingRetirementCount == 0)
    }

    @Test
    @MainActor
    func copiedSnapshotSharesOneIdempotentCloseCore() async throws {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        let revision = try await rig.applyInitial()
        let first = try await rig.cache.current(expected: revision)
        let copy = first
        #expect(await rig.cache.snapshot().activeSnapshotCount == 1)

        first.close()
        copy.close()

        #expect(first.isClosed)
        #expect(copy.isClosed)
        #expect(throws: CanvasCompositeTileCacheError.closedSnapshot) {
            _ = try copy.exactReferences()
        }
        #expect(await rig.cache.snapshot().activeSnapshotCount == 0)
        await #expect(throws: CanvasCompositeTileCacheError.closedSnapshot) {
            _ = try await copy.testingPayloadFingerprint(at: coordinate)
        }
    }

    @Test
    @MainActor
    func closedExternalSnapshotLeavesExactMetadataHighWaterEvidence()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        let revision = try await rig.applyInitial()
        let before = await rig.cache.snapshot()
        let externalMetadata =
            PaintTileStore.snapshotRetentionFixedMetadataBytes
            + PaintTileStore.snapshotRetentionReferenceMetadataBytes

        let external = try await rig.cache.current(expected: revision)
        external.close()
        let after = await rig.cache.snapshot()

        #expect(after.snapshotMetadataByteCount
            == before.snapshotMetadataByteCount)
        #expect(after.snapshotMetadataByteHighWater
            == before.snapshotMetadataByteCount + externalMetadata)
        #expect(after.physicalByteHighWater
            >= before.totalPhysicalByteCount + externalMetadata)
        #expect(after.physicalByteHighWater <= after.maximumPhysicalBytes)
    }

    @Test
    @MainActor
    func currentObservesWorkspaceGrowthWhileCaptureMetadataIsLive()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        let revision = try await rig.applyInitial()
        await rig.compositor.testingSetWorkspaceSnapshotOverride(0)
        let before = await rig.cache.snapshot()
        let externalMetadata =
            PaintTileStore.snapshotRetentionFixedMetadataBytes
            + PaintTileStore.snapshotRetentionReferenceMetadataBytes
        let grownWorkspace = 8 * 1_024 * 1_024

        await rig.compositor.testingSetWorkspaceSnapshotOverride(
            grownWorkspace
        )
        let external = try await rig.cache.current(expected: revision)
        external.close()
        await rig.compositor.testingSetWorkspaceSnapshotOverride(0)
        let after = await rig.cache.snapshot()

        #expect(after.physicalByteHighWater
            >= before.totalStorePhysicalByteCount
                + externalMetadata + grownWorkspace)
    }

    @Test
    @MainActor
    func currentDoesNotCombineOldWorkspaceWithLaterCaptureMetadata()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        let revision = try await rig.applyInitial()
        await rig.compositor.testingSetWorkspaceSnapshotOverride(
            8 * 1_024 * 1_024
        )
        let grown = await rig.cache.snapshot()
        await rig.compositor.testingSetWorkspaceSnapshotOverride(0)

        var captures: [CanvasCompositeTileSnapshot] = []
        for _ in 0..<32 {
            captures.append(try await rig.cache.current(expected: revision))
        }
        let after = await rig.cache.snapshot()

        #expect(after.totalPhysicalByteCount < grown.physicalByteHighWater)
        #expect(after.physicalByteHighWater == grown.physicalByteHighWater)
        for capture in captures { capture.close() }
    }

    @Test
    @MainActor
    func nonemptyMetadataRebaseRecordsBothCapturesBeforePriorClose()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        _ = try await rig.applyInitial()
        let tokenMetadata =
            PaintTileStore.snapshotRetentionFixedMetadataBytes
            + PaintTileStore.snapshotRetentionReferenceMetadataBytes

        var stack = rig.context.layerStack
        try stack.rename(layer.id, to: "Renamed")
        let change = try rig.context.applyLayerStack(stack)
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: change.baseCanonicalIdentity,
            targetIdentity: change.targetCanonicalIdentity,
            invalidation: change.compositeInvalidation,
            cachedCoordinates: [coordinate]
        )
        _ = try await rig.cache.apply(plan)
        let after = await rig.cache.snapshot()

        #expect(after.snapshotMetadataByteCount == tokenMetadata)
        #expect(after.snapshotMetadataByteHighWater == 2 * tokenMetadata)
        if let revision = change.revision {
            try await rig.context.releaseRevisions([revision.id])
        }
    }

    @Test
    @MainActor
    func emptyAndMetadataPublicationsRecordAdmissionHighWaterImmediately()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let initial = try await rig.applyInitial()
        let empty = await rig.cache.snapshot()
        #expect(empty.revision == initial)
        #expect(empty.physicalAdmissionCount == 1)

        var stack = rig.context.layerStack
        try stack.rename(layer.id, to: "Renamed")
        let change = try rig.context.applyLayerStack(stack)
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: change.baseCanonicalIdentity,
            targetIdentity: change.targetCanonicalIdentity,
            invalidation: change.compositeInvalidation,
            cachedCoordinates: []
        )
        _ = try await rig.cache.apply(plan)
        let rebased = await rig.cache.snapshot()
        #expect(rebased.physicalAdmissionCount
            == empty.physicalAdmissionCount + 1)
        #expect(rebased.physicalByteHighWater
            <= rebased.maximumPhysicalBytes)
        if let revision = change.revision {
            try await rig.context.releaseRevisions([revision.id])
        }
    }

    @Test
    @MainActor
    func shutdownWaitsForExternalSnapshotThenRetiresPublishedOwnership()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        let revision = try await rig.applyInitial()
        let external = try await rig.cache.current(expected: revision)

        await #expect(throws:
            CanvasCompositeTileCacheError.shutdownSnapshotsOutstanding(
                count: 1
            )
        ) {
            try await rig.cache.shutdown()
        }
        let held = await rig.cache.snapshot()
        #expect(held.revision == revision)
        #expect(held.activeSnapshotCount == 1)
        #expect(held.totalStorePhysicalByteCount > 0)
        #expect(held.snapshotMetadataByteCount > 0)
        #expect(held.snapshotPayloadLiabilityByteCount > 0)

        external.close()
        try await rig.cache.shutdown()
        let settled = await rig.cache.snapshot()
        #expect(settled.revision == nil)
        #expect(settled.activeSnapshotCount == 0)
        #expect(settled.totalStorePhysicalByteCount == 0)
        #expect(settled.snapshotMetadataByteCount == 0)
        #expect(settled.snapshotPayloadLiabilityByteCount == 0)
        #expect(settled.sourceSnapshotTokenCount == 0)
        #expect(settled.candidateLeaseCount == 0)
        #expect(settled.preparedRetirementCount == 0)
        #expect(settled.pendingRetirementCount == 0)
    }

    @Test
    @MainActor
    func shutdownInterleavedWithGatedUpdateAllowsNoPostShutdownPublish()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        let initialRevision = try await rig.applyInitial()
        let result = try await rig.context.clear()
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: result.baseCanonicalIdentity,
            targetIdentity: result.canonicalIdentity,
            invalidation: result.compositeInvalidation,
            cachedCoordinates: [coordinate]
        )
        let gate = CanvasCompositeTestGate()
        let shutdownGate = CanvasCompositeTestGate()
        defer {
            Task {
                await gate.release()
                await shutdownGate.release()
            }
        }
        let update = Task {
            try await rig.cache.apply(
                plan,
                afterCompositionForTesting: { await gate.arriveAndWait() }
            )
        }
        try await gate.waitUntilArrived()
        let shutdown = Task {
            try await rig.cache.shutdown(
                afterSnapshotCheckForTesting: {
                    await shutdownGate.arriveAndWait()
                }
            )
        }
        try await shutdownGate.waitUntilArrived()
        await #expect(throws: CanvasCompositeTileCacheError.isShutdown) {
            _ = try await rig.cache.current(expected: initialRevision)
        }
        await shutdownGate.release()
        await gate.release()

        await #expect(throws: CanvasCompositeTileCacheError.isShutdown) {
            _ = try await update.value
        }
        try await shutdown.value
        let settled = await rig.cache.snapshot()
        #expect(settled.revision == nil)
        #expect(settled.activeUpdateCount == 0)
        #expect(settled.totalStorePhysicalByteCount == 0)
        if let pair = result.historyPair {
            try await rig.context.releaseRevisions(pair.revisionIDs)
        }
    }

    @Test
    @MainActor
    func fullInvalidationUnionsCachedCoordinatesAndRemovesTransparentOutput()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        let firstRevision = try await rig.applyInitial()
        let first = try await rig.cache.current(expected: firstRevision)
        first.close()
        let base = rig.context.canonicalStateIdentity()
        let cleared = try await rig.context.clear()
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: base,
            targetIdentity: cleared.canonicalIdentity,
            invalidation: cleared.compositeInvalidation,
            cachedCoordinates: [coordinate]
        )

        #expect(plan.dirtyCoordinates == [coordinate])
        #expect(plan.preparedTiles[0].layers.isEmpty)
        let revision = try await rig.cache.apply(plan)
        let current = try await rig.cache.current(expected: revision)
        #expect(try current.exactReferences().isEmpty)
        #expect(await rig.cache.snapshot().cachedCoordinates.isEmpty)
        current.close()
        if let pair = cleared.historyPair {
            try await rig.context.releaseRevisions(pair.revisionIDs)
        }
    }

    @Test
    @MainActor
    func resizeRebuildsCacheInNewStorageGeometryAndDropsClippedCoordinates()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 512, height: 256),
            layers: [layer]
        ) else { return }
        let coordinates = [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
        ]
        try await rig.install([
            layer.id: Dictionary(uniqueKeysWithValues: coordinates.map {
                ($0, SIMD4<Float>(0.5, 0, 0, 1))
            }),
        ])
        let initialRevision = try await rig.applyInitial()
        let initial = try await rig.cache.current(expected: initialRevision)
        #expect(try initial.exactReferences().map(\.coordinate) == coordinates)
        initial.close()
        let newGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 256, height: 256),
            storagePixelSize: PixelSize(width: 256, height: 256),
            radialLayout: nil
        )
        let resized = try #require(
            try await rig.context.resize(to: newGeometry)
        )
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: resized.baseCanonicalIdentity,
            targetIdentity: resized.targetCanonicalIdentity,
            invalidation: resized.compositeInvalidation,
            cachedCoordinates: coordinates
        )

        let revision = try await rig.cache.apply(plan)
        let snapshot = try await rig.cache.current(expected: revision)

        #expect(snapshot.pixelSize == newGeometry.storagePixelSize)
        #expect(try snapshot.exactReferences().map(\.coordinate)
            == [coordinates[0]])
        snapshot.close()
        if let history = resized.revision {
            try await rig.context.releaseRevisions([history.id])
        }
    }

    @Test
    @MainActor
    func memoryPressureIsDeterministicAndRehydrationPreservesPhysicalTotal()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 768, height: 256),
            layers: [layer]
        ) else { return }
        let coordinates = (0..<3).map {
            PaintTileCoordinate(x: $0, y: 0)
        }
        try await rig.install([
            layer.id: Dictionary(uniqueKeysWithValues: coordinates.map {
                ($0, SIMD4<Float>(0.5, 0, 0, 1))
            }),
        ])
        let revision = try await rig.applyInitial()
        let snapshot = try await rig.cache.current(expected: revision)
        let before = await rig.cache.snapshot()
        let initialLRU = before.leastRecentlyUsedCoordinates

        let pressure = try await rig.cache.applyMemoryPressure(
            targetResidentBytes: PaintTileDescriptor.residentByteCount
        )
        let pressured = await rig.cache.snapshot()

        #expect(pressure.residentByteCount
            == PaintTileDescriptor.residentByteCount)
        #expect(pressure.evictedIdentities.count == 2)
        #expect(pressure.evictedIdentities.map(\.coordinate)
            == Array(initialLRU.prefix(2)))
        #expect(pressured.residentByteCount
            < before.residentByteCount)
        #expect(pressured.totalStorePhysicalByteCount
            == before.totalStorePhysicalByteCount)
        try await snapshot.rehydrate(at: coordinates[0])
        let rehydrated = await rig.cache.snapshot()
        #expect(rehydrated.residentByteCount
            == 2 * PaintTileDescriptor.residentByteCount)
        #expect(rehydrated.totalStorePhysicalByteCount
            == before.totalStorePhysicalByteCount)
        snapshot.close()
    }

    @Test
    @MainActor
    func pressureUsesItsOwnTransferReceiptAcrossReentrantWorkspaceObservation()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 768, height: 256),
            layers: [layer]
        ) else { return }
        let tile = PaintTileDescriptor.residentByteCount
        let coordinates = (0..<3).map {
            PaintTileCoordinate(x: $0, y: 0)
        }
        try await rig.install([
            layer.id: Dictionary(uniqueKeysWithValues: coordinates.map {
                ($0, SIMD4<Float>(0.5, 0, 0, 1))
            }),
        ])
        _ = try await rig.applyInitial()
        let before = await rig.cache.snapshot()
        let gate = CanvasCompositeTestGate()

        await rig.compositor.testingSetWorkspaceSnapshotOverride(2 * tile)
        let noTransfer = Task {
            try await rig.cache.applyMemoryPressure(
                targetResidentBytes: 2 * tile,
                beforeWorkspaceObservationForTesting: {
                    await gate.arriveAndWait()
                }
            )
        }
        try await gate.waitUntilArrived()
        await rig.compositor.testingSetWorkspaceSnapshotOverride(tile)
        let transferred = try await rig.cache.applyMemoryPressure(
            targetResidentBytes: 2 * tile
        )
        await rig.compositor.testingSetWorkspaceSnapshotOverride(2 * tile)
        await gate.release()
        let noTransferResult = try await noTransfer.value
        await rig.compositor.testingSetWorkspaceSnapshotOverride(0)
        let after = await rig.cache.snapshot()

        #expect(transferred.evictedIdentities.count == 1)
        #expect(noTransferResult.evictedIdentities.isEmpty)
        #expect(after.physicalAdmissionCount
            == before.physicalAdmissionCount + 1)
        #expect(after.lastCausalTransferAccounting?
            .additionalPhysicalBytesAtPeak == tile)
    }

    @Test
    @MainActor
    func residentRehydrateDoesNotClaimAReentrantPressureReceipt()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 512, height: 256),
            layers: [layer]
        ) else { return }
        let tile = PaintTileDescriptor.residentByteCount
        let coordinates = (0..<2).map {
            PaintTileCoordinate(x: $0, y: 0)
        }
        try await rig.install([
            layer.id: Dictionary(uniqueKeysWithValues: coordinates.map {
                ($0, SIMD4<Float>(0.5, 0, 0, 1))
            }),
        ])
        let revision = try await rig.applyInitial()
        let retained = try await rig.cache.current(expected: revision)
        let before = await rig.cache.snapshot()
        let exactLRU = try #require(before.leastRecentlyUsedCoordinates
            .first)
        let residentCoordinate = try #require(before
            .leastRecentlyUsedCoordinates.last)
        let gate = CanvasCompositeTestGate()

        await rig.compositor.testingSetWorkspaceSnapshotOverride(2 * tile)
        let residentLease = Task {
            try await retained.rehydrate(
                at: residentCoordinate,
                beforeWorkspaceObservationForTesting: {
                    await gate.arriveAndWait()
                }
            )
        }
        try await gate.waitUntilArrived()
        await rig.compositor.testingSetWorkspaceSnapshotOverride(tile)
        let pressure = try await rig.cache.applyMemoryPressure(
            targetResidentBytes: tile
        )
        await rig.compositor.testingSetWorkspaceSnapshotOverride(2 * tile)
        await gate.release()
        try await residentLease.value
        await rig.compositor.testingSetWorkspaceSnapshotOverride(0)
        let after = await rig.cache.snapshot()

        #expect(pressure.evictedIdentities.map(\.coordinate) == [exactLRU])
        #expect(after.physicalAdmissionCount
            == before.physicalAdmissionCount + 1)
        #expect(after.lastCausalTransferAccounting?
            .additionalPhysicalBytesAtPeak == tile)
        retained.close()
    }

    @Test
    @MainActor
    func pixelProbeRejectsBeforeUnadmittedReadbackAtClosedCap()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        let revision = try await rig.applyInitial()
        let retained = try await rig.cache.current(expected: revision)
        let before = await rig.cache.snapshot()

        await rig.compositor.testingSetWorkspaceSnapshotOverride(
            before.maximumPhysicalBytes
        )
        await #expect(throws: PaintTileStoreError.self) {
            _ = try await retained.testingPayloadFingerprint(at: coordinate)
        }
        await rig.compositor.testingSetWorkspaceSnapshotOverride(0)
        let after = await rig.cache.snapshot()

        #expect(after.physicalAdmissionCount == before.physicalAdmissionCount)
        #expect(after.storeTransferPeakByteHighWater
            == before.storeTransferPeakByteHighWater)
        retained.close()
    }

    @Test
    @MainActor
    func pixelProbeRecordsItsOwnCausalReadbackReceipt() async throws {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let tile = PaintTileDescriptor.residentByteCount
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        let revision = try await rig.applyInitial()
        let retained = try await rig.cache.current(expected: revision)
        let before = await rig.cache.snapshot()

        await rig.compositor.testingSetWorkspaceSnapshotOverride(tile)
        _ = try await retained.testingPayloadFingerprint(at: coordinate)
        await rig.compositor.testingSetWorkspaceSnapshotOverride(0)
        let after = await rig.cache.snapshot()
        let receipt = try #require(after.lastCausalTransferAccounting)

        #expect(after.physicalAdmissionCount
            == before.physicalAdmissionCount + 1)
        #expect(receipt.readbackStagingBytes == tile)
        #expect(receipt.capturedPayloadBytes == tile)
        #expect(receipt.additionalPhysicalBytesAtPeak == tile)
        #expect(after.physicalByteHighWater
            >= receipt.aggregatePeakTrackedBytes)
        retained.close()
    }

    @Test
    @MainActor
    func retainedSnapshotRehydrateRecordsLiveMetadataWorkspaceAndTransfer()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        let revision = try await rig.applyInitial()
        var captures: [CanvasCompositeTileSnapshot] = []
        for _ in 0..<16 {
            captures.append(try await rig.cache.current(expected: revision))
        }
        _ = try await rig.cache.applyMemoryPressure(targetResidentBytes: 0)
        let before = await rig.cache.snapshot()
        let probeWorkspace = PaintTileDescriptor.residentByteCount
        await rig.compositor.testingSetWorkspaceSnapshotOverride(
            probeWorkspace
        )
        try await captures[0].rehydrate(at: coordinate)
        await rig.compositor.testingSetWorkspaceSnapshotOverride(0)
        let after = await rig.cache.snapshot()
        let receipt = try #require(after.lastCausalTransferAccounting)

        #expect(after.residentByteCount
            == PaintTileDescriptor.residentByteCount)
        #expect(after.physicalAdmissionCount
            == before.physicalAdmissionCount + 1)
        #expect(receipt.additionalPhysicalBytesAtPeak == probeWorkspace)
        #expect(receipt.readbackStagingBytes == 0)
        #expect(receipt.uploadStagingBytes
            == PaintTileDescriptor.residentByteCount)
        #expect(after.physicalByteHighWater
            >= receipt.aggregatePeakTrackedBytes)
        #expect(after.physicalByteHighWater <= after.maximumPhysicalBytes)
        for capture in captures { capture.close() }
    }

    @Test
    @MainActor
    func closedPhysicalCapacityFailsBeforeAllocationOrEncoding() async throws {
        let layer = try layer(UUID(), name: "Paint")
        let tile = PaintTileDescriptor.residentByteCount
        let metadata = PaintTileStore.snapshotRetentionFixedMetadataBytes
            + 3 * PaintTileStore.snapshotRetentionReferenceMetadataBytes
        let envelope = CanvasPresentationMemoryEnvelope(
            maximumPhysicalBytes: 7 * tile + metadata,
            documentStoreBytes: 0,
            transientCacheBytes: 0,
            canonicalCacheBytes: 7 * tile + metadata,
            canonicalResidentBytes: tile,
            canonicalBatchWorkspaceBytes: 5 * tile,
            canonicalCopyOnWriteHeadroomBytes: tile,
            canonicalSnapshotMetadataBytes: metadata,
            canonicalStoreTransferBytes: 2 * tile
        )
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 768, height: 256),
            layers: [layer],
            envelope: envelope
        ) else { return }
        let coordinates = (0..<3).map {
            PaintTileCoordinate(x: $0, y: 0)
        }
        try await rig.install([
            layer.id: Dictionary(uniqueKeysWithValues: coordinates.map {
                ($0, SIMD4<Float>(0.5, 0, 0, 1))
            }),
        ])
        let identity = rig.context.canonicalStateIdentity()
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: identity,
            targetIdentity: identity,
            invalidation: .full,
            cachedCoordinates: []
        )

        do {
            _ = try await rig.cache.apply(plan)
            Issue.record("closed physical capacity unexpectedly succeeded")
        } catch let error as CanvasCompositeTileCacheError {
            #expect(error == .physicalCapacityExceeded(
                requested: 8 * tile,
                current: 0,
                highWater: 0,
                maximum: 7 * tile + metadata
            ))
        }
        let diagnostics = await rig.cache.snapshot()
        #expect(plan.isClosed)
        #expect(diagnostics.revision == nil)
        #expect(diagnostics.totalStorePhysicalByteCount == 0)
        #expect(diagnostics.totalPhysicalByteCount == 0)
        #expect(diagnostics.lastBatchMetrics == nil)
        #expect(diagnostics.physicalByteHighWater
            <= diagnostics.maximumPhysicalBytes)
    }

    @Test
    @MainActor
    func aggregateTransferAdmissionRejectsBeforeDestinationAllocation()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        await rig.compositor.testingSetWorkspaceSnapshotOverride(
            CanvasPresentationMemoryEnvelope.production
                .canonicalCacheBytes
        )

        await #expect(throws: CanvasCompositeTileCacheError.self) {
            _ = try await rig.applyInitial()
        }
        let after = await rig.cache.snapshot()
        #expect(after.revision == nil)
        #expect(after.totalStorePhysicalByteCount == 0)
        #expect(after.candidateLeaseCount == 0)
        #expect(after.lastBatchMetrics == nil)
        #expect(after.physicalByteHighWater <= after.maximumPhysicalBytes)
    }

    @Test
    @MainActor
    func metadataTransferAndWorkspaceShareOneClosedCanonicalCap()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        let tile = PaintTileDescriptor.residentByteCount
        let coordinates = (0..<3).map {
            PaintTileCoordinate(x: $0, y: 0)
        }
        let tokenMetadata = PaintTileStore.snapshotRetentionFixedMetadataBytes
            + coordinates.count
                * PaintTileStore.snapshotRetentionReferenceMetadataBytes
        let metadataMaximum = 3 * tokenMetadata
        let workspaceMaximum = 5 * tile
        // Transfer admission owns resident old + new allocation plus the
        // shared persistent-zero source at the exact observed peak.
        let storeMaximum = 7 * tile
        let canonicalMaximum = storeMaximum + metadataMaximum
            + workspaceMaximum
        let envelope = CanvasPresentationMemoryEnvelope(
            maximumPhysicalBytes: canonicalMaximum,
            documentStoreBytes: 0,
            transientCacheBytes: 0,
            canonicalCacheBytes: canonicalMaximum,
            canonicalResidentBytes: storeMaximum,
            canonicalBatchWorkspaceBytes: workspaceMaximum,
            canonicalCopyOnWriteHeadroomBytes: 0,
            canonicalSnapshotMetadataBytes: metadataMaximum,
            canonicalStoreTransferBytes: storeMaximum
        )
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 768, height: 256),
            layers: [layer],
            envelope: envelope
        ) else { return }
        try await rig.install([
            layer.id: Dictionary(uniqueKeysWithValues: coordinates.map {
                ($0, SIMD4<Float>(0.5, 0, 0, 1))
            }),
        ])
        let firstRevision = try await rig.applyInitial()
        let old = try await rig.cache.current(expected: firstRevision)

        var stack = rig.context.layerStack
        try stack.setOpacity(layer.id, opacity: 0.75)
        let firstChange = try rig.context.applyLayerStack(stack)
        let firstPlan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: firstChange.baseCanonicalIdentity,
            targetIdentity: firstChange.targetCanonicalIdentity,
            invalidation: firstChange.compositeInvalidation,
            cachedCoordinates: coordinates
        )
        let secondRevision = try await rig.cache.apply(firstPlan)
        let current = try await rig.cache.current(expected: secondRevision)
        let atCap = await rig.cache.snapshot()
        #expect(atCap.snapshotMetadataByteCount == metadataMaximum)
        #expect(atCap.storeTransferPeakByteHighWater == storeMaximum)
        #expect(atCap.workspacePhysicalByteCount <= workspaceMaximum)
        #expect(atCap.totalPhysicalByteCount <= canonicalMaximum)
        #expect(atCap.snapshotMetadataByteHighWater == metadataMaximum)
        #expect(atCap.physicalByteHighWater
            >= atCap.totalPhysicalByteCount)
        #expect(atCap.physicalByteHighWater
            >= storeMaximum + (metadataMaximum - tokenMetadata)
                + atCap.workspacePhysicalByteCount)
        #expect(atCap.physicalByteHighWater <= canonicalMaximum)

        try stack.setOpacity(layer.id, opacity: 0.5)
        let secondChange = try rig.context.applyLayerStack(stack)
        let secondPlan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: secondChange.baseCanonicalIdentity,
            targetIdentity: secondChange.targetCanonicalIdentity,
            invalidation: secondChange.compositeInvalidation,
            cachedCoordinates: coordinates
        )
        await #expect(throws: CanvasCompositeTileCacheError.self) {
            _ = try await rig.cache.apply(secondPlan)
        }
        let rejected = await rig.cache.snapshot()
        #expect(rejected.revision == secondRevision)
        #expect(rejected.snapshotMetadataByteCount == metadataMaximum)
        #expect(rejected.storeTransferPeakByteHighWater == storeMaximum)
        #expect(rejected.totalPhysicalByteCount <= canonicalMaximum)
        #expect(rejected.physicalByteHighWater <= canonicalMaximum)
        #expect(rejected.candidateLeaseCount == 0)
        #expect(rejected.activeUpdateCount == 0)
        #expect(secondPlan.isClosed)

        old.close()
        current.close()
        for revision in [firstChange.revision, secondChange.revision]
            .compactMap({ $0 })
        {
            try await rig.context.releaseRevisions([revision.id])
        }
    }

    @Test
    @MainActor
    func warmedWorkspaceAndEvictionReadbackHaveOneCausalPeak()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        let tile = PaintTileDescriptor.residentByteCount
        let tokenMetadata =
            PaintTileStore.snapshotRetentionFixedMetadataBytes
            + PaintTileStore.snapshotRetentionReferenceMetadataBytes
        let metadataMaximum = 3 * tokenMetadata
        let storeMaximum = 5 * tile
        let workspaceMaximum = 5 * tile
        let canonicalMaximum = storeMaximum + workspaceMaximum
            + metadataMaximum
        let envelope = CanvasPresentationMemoryEnvelope(
            maximumPhysicalBytes: canonicalMaximum,
            documentStoreBytes: 0,
            transientCacheBytes: 0,
            canonicalCacheBytes: canonicalMaximum,
            canonicalResidentBytes: tile,
            canonicalBatchWorkspaceBytes: workspaceMaximum,
            canonicalCopyOnWriteHeadroomBytes: storeMaximum - tile,
            canonicalSnapshotMetadataBytes: metadataMaximum,
            canonicalStoreTransferBytes: storeMaximum
        )
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer],
            envelope: envelope
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        _ = try await rig.applyInitial()
        let warmed = await rig.cache.snapshot()
        #expect(warmed.workspacePhysicalByteCount > 0)

        var stack = rig.context.layerStack
        try stack.setOpacity(layer.id, opacity: 0.75)
        let change = try rig.context.applyLayerStack(stack)
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: change.baseCanonicalIdentity,
            targetIdentity: change.targetCanonicalIdentity,
            invalidation: change.compositeInvalidation,
            cachedCoordinates: [coordinate]
        )
        _ = try await rig.cache.apply(plan)
        let after = await rig.cache.snapshot()
        let causalPeak = storeMaximum + tokenMetadata
            + warmed.workspacePhysicalByteCount

        #expect(after.storeTransferPeakByteHighWater == storeMaximum)
        #expect(after.physicalByteHighWater >= causalPeak)
        #expect(after.physicalByteHighWater <= canonicalMaximum)
        if let revision = change.revision {
            try await rig.context.releaseRevisions([revision.id])
        }
    }

    @Test
    @MainActor
    func production4096FullInvalidationChunksDestinationsWithinClosedCap()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 4_096, height: 4_096),
            layers: [layer]
        ) else { return }
        let coordinates = (0..<16).flatMap { y in
            (0..<16).map { x in PaintTileCoordinate(x: x, y: y) }
        }
        try await rig.install([
            layer.id: Dictionary(uniqueKeysWithValues: coordinates.map {
                coordinate in
                (coordinate, SIMD4<Float>(0.5, 0.25, 0, 1))
            }),
        ])
        let firstRevision = try await rig.applyInitial()
        let old = try await rig.cache.current(expected: firstRevision)
        let oldFirst = try await old.testingPayloadFingerprint(
            at: coordinates[0]
        )

        var stack = rig.context.layerStack
        try stack.setOpacity(layer.id, opacity: 0.5)
        let result = try rig.context.applyLayerStack(stack)
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: result.baseCanonicalIdentity,
            targetIdentity: result.targetCanonicalIdentity,
            invalidation: result.compositeInvalidation,
            cachedCoordinates: coordinates
        )
        let revision = try await rig.cache.apply(plan)
        let current = try await rig.cache.current(expected: revision)
        let diagnostics = await rig.cache.snapshot()

        #expect(diagnostics.cachedCoordinates.count == 256)
        #expect(diagnostics.lastBatchMetrics?.commandSubmissionCount == 32)
        #expect(diagnostics.maximumCandidateLeaseTileCount <= 8)
        #expect(diagnostics.totalPhysicalByteCount
            <= diagnostics.maximumPhysicalBytes)
        #expect(diagnostics.physicalByteHighWater
            <= diagnostics.maximumPhysicalBytes)
        #expect(try await old.testingPayloadFingerprint(at: coordinates[0])
            == oldFirst)
        #expect(try await current.testingPayloadFingerprint(at: coordinates[0])
            != oldFirst)
        old.close()
        current.close()
        if let revision = result.revision {
            try await rig.context.releaseRevisions([revision.id])
        }
    }

    @Test
    @MainActor
    func realThirtyTileEightLayerBatchUsesFourCommandSubmissions()
        async throws
    {
        let layers = try (0..<8).map {
            try layer(UUID(), name: "Layer \($0)")
        }
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 30 * 256, height: 256),
            layers: layers
        ) else { return }
        let coordinates = (0..<30).map {
            PaintTileCoordinate(x: $0, y: 0)
        }
        var colors: [UUID: [PaintTileCoordinate: SIMD4<Float>]] = [:]
        for (index, layer) in layers.enumerated() {
            let alpha = Float(index + 1) / 8
            colors[layer.id] = Dictionary(uniqueKeysWithValues:
                coordinates.map { coordinate in
                    let red = alpha * Float(coordinate.x + 1) / 31
                    return (coordinate, SIMD4<Float>(red, 0, 0, alpha))
                })
        }
        try await rig.install(colors)

        let revision = try await rig.applyInitial()
        let diagnostics = await rig.cache.snapshot()
        let metrics = try #require(diagnostics.lastBatchMetrics)
        let snapshot = try await rig.cache.current(expected: revision)
        let left = try await snapshot.testingRGBA16FirstTexel(
            at: coordinates[0]
        )
        let adjacent = try await snapshot.testingRGBA16FirstTexel(
            at: coordinates[1]
        )

        #expect(metrics.commandSubmissionCount == 4)
        #expect(metrics.commandWaitCount == 4)
        #expect(metrics.sampleEncodeCount == 240)
        #expect(metrics.scratchSetCount == 1)
        #expect(metrics.maximumScratchPixelCount == 256 * 256)
        #expect(metrics.maximumPreparedSubmissionCount == 64)
        #expect(diagnostics.workspacePhysicalByteCount
            <= CanvasPresentationMemoryEnvelope.production
                .canonicalBatchWorkspaceBytes)
        #expect(diagnostics.totalPhysicalByteCount
            <= diagnostics.maximumPhysicalBytes)
        #expect(diagnostics.physicalByteHighWater
            <= diagnostics.maximumPhysicalBytes)
        #expect(left != adjacent)
        snapshot.close()
    }

    @Test
    @MainActor
    func sourceCaptureFailurePublishesNoOwnership() async throws {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        let identity = rig.context.canonicalStateIdentity()
        let invalidLimits = SparseTilePlanLimits(
            maximumPageEntries: 0,
            maximumPageChunks: 0,
            maximumPageTableBytes: 0,
            maximumBindingSlots: 0,
            maximumBindingChunks: 0,
            maximumBindingBytes: 0,
            maximumTexturesPerBatch: 0,
            maximumBatchCount: 0
        )

        #expect(throws: SparseTileSamplingPlanError.self) {
            _ = try rig.context.prepareCompositeTileUpdatePlan(
                baseIdentity: identity,
                targetIdentity: identity,
                invalidation: .full,
                cachedCoordinates: [],
                limits: invalidLimits
            )
        }
        let context = await rig.context.snapshot()
        let cache = await rig.cache.snapshot()
        #expect(context.activeSnapshotTokenCount == 0)
        #expect(cache.revision == nil)
        #expect(cache.activeUpdateCount == 0)
        #expect(cache.sourceSnapshotTokenCount == 0)
    }

    @Test
    @MainActor
    func encodeCommandCancellationAndPublicationFailuresSettleEverything()
        async throws
    {
        enum FailureCase: CaseIterable {
            case encode
            case commandTerminal
            case cancellation
            case publication
        }
        for failure in FailureCase.allCases {
            let layer = try layer(UUID(), name: "Paint")
            guard let rig = try CacheRig.make(
                size: PixelSize(width: 256, height: 256),
                layers: [layer]
            ) else { return }
            let coordinate = PaintTileCoordinate(x: 0, y: 0)
            try await rig.install([
                layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
            ])
            let identity = rig.context.canonicalStateIdentity()
            let plan = try rig.context.prepareCompositeTileUpdatePlan(
                baseIdentity: identity,
                targetIdentity: identity,
                invalidation: .full,
                cachedCoordinates: []
            )

            do {
                switch failure {
                case .encode:
                    _ = try await rig.cache.apply(
                        plan,
                        batchFailureInjection: .init(
                            failingSampleEncodeIndex: 0
                        )
                    )
                case .commandTerminal:
                    _ = try await rig.cache.apply(
                        plan,
                        batchFailureInjection: .init(
                            failingCommandTerminalChunkIndex: 0
                        )
                    )
                case .cancellation:
                    let operation = Task {
                        try await rig.cache.apply(
                            plan,
                            afterCompositionForTesting: {
                                withUnsafeCurrentTask { task in
                                    task?.cancel()
                                }
                            }
                        )
                    }
                    _ = try await operation.value
                case .publication:
                    _ = try await rig.cache.apply(
                        plan,
                        failPublicationForTesting: true
                    )
                }
                Issue.record("failure case \(failure) unexpectedly succeeded")
            } catch {
                // Every injected terminal is expected to fail.
            }

            #expect(plan.isClosed)
            let diagnostics = await rig.cache.snapshot()
            let contextDiagnostics = await rig.context.snapshot()
            #expect(diagnostics.revision == nil)
            #expect(diagnostics.activeUpdateCount == 0)
            #expect(diagnostics.sourceSnapshotTokenCount == 0)
            #expect(diagnostics.candidateLeaseCount == 0)
            #expect(diagnostics.preparedRetirementCount == 0)
            #expect(diagnostics.pendingRetirementCount == 0)
            #expect(contextDiagnostics.activeSnapshotTokenCount == 0)
            #expect(contextDiagnostics.activeTileLeaseCount == 0)
        }
    }

    @Test
    @MainActor
    func cancellationBetweenDestinationChunksStopsBeforeNextAllocation()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 4_096, height: 256),
            layers: [layer]
        ) else { return }
        let coordinates = (0..<16).map {
            PaintTileCoordinate(x: $0, y: 0)
        }
        try await rig.install([
            layer.id: Dictionary(uniqueKeysWithValues: coordinates.map {
                ($0, SIMD4<Float>(0.5, 0.25, 0, 1))
            }),
        ])
        let identity = rig.context.canonicalStateIdentity()
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: identity,
            targetIdentity: identity,
            invalidation: .full,
            cachedCoordinates: []
        )
        let completedChunks = CanvasCompositeTestCounter()

        let operation = Task {
            try await rig.cache.apply(
                plan,
                afterChunkForTesting: { chunkIndex in
                    await completedChunks.record(chunkIndex)
                    if chunkIndex == 0 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            )
        }
        do {
            _ = try await operation.value
            Issue.record("mid-composition cancellation unexpectedly published")
        } catch is CancellationError {
            // Expected at the cancellation check before the second chunk.
        }

        let diagnostics = await rig.cache.snapshot()
        #expect(await completedChunks.values == [0])
        #expect(plan.isClosed)
        #expect(diagnostics.revision == nil)
        #expect(diagnostics.activeUpdateCount == 0)
        #expect(diagnostics.candidateLeaseCount == 0)
        #expect(diagnostics.preparedRetirementCount == 0)
        #expect(diagnostics.pendingRetirementCount == 0)
        #expect(diagnostics.maximumCandidateLeaseTileCount == 8)
        #expect(diagnostics.totalStorePhysicalByteCount == 0)
        #expect(diagnostics.cleanupDebtCount == 0)
        #expect(diagnostics.totalPhysicalByteCount
            <= diagnostics.workspacePhysicalByteCount)
    }

    @Test
    @MainActor
    func cleanupDebtIsExplicitRetryableAndNeverReportsIdle()
        async throws
    {
        let stages: [(CanvasCompositeCleanupStage,
            CanvasCompositeCleanupFailureInjection)] = [
            (.leaseReturn, .init(leaseReturn: 1)),
            (.retirementPrepare, .init(retirementPrepare: 1)),
            (.retirementRequest, .init(retirementRequest: 1)),
        ]
        for (stage, injection) in stages {
            let layer = try layer(UUID(), name: "Paint")
            guard let rig = try CacheRig.make(
                size: PixelSize(width: 256, height: 256),
                layers: [layer]
            ) else { return }
            let coordinate = PaintTileCoordinate(x: 0, y: 0)
            try await rig.install([
                layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
            ])
            let identity = rig.context.canonicalStateIdentity()
            let plan = try rig.context.prepareCompositeTileUpdatePlan(
                baseIdentity: identity,
                targetIdentity: identity,
                invalidation: .full,
                cachedCoordinates: []
            )

            await #expect(throws:
                CanvasCompositeTileCacheError.cleanupPending(stage: stage)
            ) {
                _ = try await rig.cache.apply(
                    plan,
                    failPublicationForTesting: stage != .leaseReturn,
                    cleanupFailureInjection: injection,
                    batchFailureInjection: stage == .leaseReturn
                        ? .init(failingSampleEncodeIndex: 0) : nil
                )
            }
            let pending = await rig.cache.snapshot()
            #expect(pending.cleanupDebtCount == 1)
            #expect(pending.activeUpdateCount == 0)
            if stage == .leaseReturn {
                #expect(pending.candidateLeaseCount == 1)
            }
            try await rig.cache.retryCleanup()
            let settled = await rig.cache.snapshot()
            #expect(settled.cleanupDebtCount == 0)
            #expect(settled.candidateLeaseCount == 0)
            #expect(settled.preparedRetirementCount == 0)
            #expect(settled.pendingRetirementCount == 0)
            #expect(settled.totalStorePhysicalByteCount == 0)
            try await rig.cache.shutdown()
        }
    }

    @Test
    @MainActor
    func failedShutdownCleanupReturnsLifecycleToRetryableActiveState()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        let identity = rig.context.canonicalStateIdentity()
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: identity,
            targetIdentity: identity,
            invalidation: .full,
            cachedCoordinates: []
        )
        let injection = CanvasCompositeCleanupFailureInjection(leaseReturn: 2)
        await #expect(throws:
            CanvasCompositeTileCacheError.cleanupPending(stage: .leaseReturn)
        ) {
            _ = try await rig.cache.apply(
                plan,
                cleanupFailureInjection: injection,
                batchFailureInjection: .init(failingSampleEncodeIndex: 0)
            )
        }

        await #expect(throws:
            CanvasCompositeTileCacheError.cleanupPending(stage: .leaseReturn)
        ) {
            try await rig.cache.shutdown()
        }
        let failed = await rig.cache.snapshot()
        #expect(failed.acceptsUpdates)
        #expect(!failed.isShutDown)
        #expect(failed.cleanupDebtCount == 1)

        try await rig.cache.retryCleanup()
        try await rig.cache.shutdown()
        let settled = await rig.cache.snapshot()
        #expect(!settled.acceptsUpdates)
        #expect(settled.isShutDown)
        #expect(settled.cleanupDebtCount == 0)
        #expect(settled.totalStorePhysicalByteCount == 0)
    }

    @Test
    @MainActor
    func sequenceOverflowFailsClosedAndSettlesPlanOwnership() async throws {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let identity = rig.context.canonicalStateIdentity()
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: identity,
            targetIdentity: identity,
            invalidation: .full,
            cachedCoordinates: []
        )
        await rig.cache.testingSetSequenceForNextPublication(UInt64.max)

        await #expect(throws: CanvasCompositeTileCacheError.sequenceOverflow) {
            _ = try await rig.cache.apply(plan)
        }
        let diagnostics = await rig.cache.snapshot()
        #expect(plan.isClosed)
        #expect(diagnostics.revision == nil)
        #expect(diagnostics.activeUpdateCount == 0)
        #expect(diagnostics.sourceSnapshotTokenCount == 0)
        #expect(diagnostics.cleanupDebtCount == 0)
    }

    @Test
    @MainActor
    func noOpAtMaximumSequenceReturnsCurrentRevisionWithoutConsumption()
        async throws
    {
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer]
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        let revision = try await rig.applyInitial()
        let plan = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: revision.identity,
            targetIdentity: revision.identity,
            invalidation: .none,
            cachedCoordinates: [coordinate]
        )
        await rig.cache.testingSetSequenceForNextPublication(UInt64.max)

        let result = try await rig.cache.apply(plan)
        let diagnostics = await rig.cache.snapshot()

        #expect(result == revision)
        #expect(plan.isClosed)
        #expect(diagnostics.revision == revision)
        #expect(diagnostics.activeUpdateCount == 0)
    }

    @Test
    @MainActor
    func compositorCompletionDebtIsCountedAndSettledBeforeAnotherBatch()
        async throws
    {
        let completionFailures =
            SparseTileSamplingCompletionFailureInjector(failures: 40)
        let layer = try layer(UUID(), name: "Paint")
        guard let rig = try CacheRig.make(
            size: PixelSize(width: 256, height: 256),
            layers: [layer],
            completionFailureInjector: completionFailures
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        try await rig.install([
            layer.id: [coordinate: SIMD4<Float>(0.5, 0, 0, 1)],
        ])
        let identity = rig.context.canonicalStateIdentity()
        let first = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: identity,
            targetIdentity: identity,
            invalidation: .full,
            cachedCoordinates: []
        )
        await #expect(throws: LayerCompositorError.cleanupPending) {
            _ = try await rig.cache.apply(first)
        }
        let pending = await rig.cache.snapshot()
        #expect(pending.compositorPendingPlanCompletionCount == 1)
        #expect(pending.compositorPendingPlanMetalBufferBytes > 0)
        #expect(pending.workspacePhysicalByteCount
            >= pending.compositorPendingPlanMetalBufferBytes)
        #expect(pending.totalPhysicalByteCount
            <= pending.maximumPhysicalBytes)
        #expect(pending.candidateLeaseCount == 0)

        let blocked = try rig.context.prepareCompositeTileUpdatePlan(
            baseIdentity: identity,
            targetIdentity: identity,
            invalidation: .full,
            cachedCoordinates: []
        )
        await #expect(throws: LayerCompositorError.cleanupPending) {
            _ = try await rig.cache.apply(blocked)
        }
        #expect(await rig.cache.snapshot().candidateLeaseCount == 0)

        var settled = false
        for _ in 0..<4 where !settled {
            do {
                try await rig.cache.retryCleanup()
                settled = true
            } catch LayerCompositorError.cleanupPending {
                continue
            }
        }
        #expect(settled)
        let final = await rig.cache.snapshot()
        #expect(final.compositorPendingPlanCompletionCount == 0)
        #expect(final.compositorPendingPlanMetalBufferBytes == 0)
        #expect(final.workspacePhysicalByteCount
            <= CanvasPresentationMemoryEnvelope.production
                .canonicalBatchWorkspaceBytes)
        try await rig.cache.shutdown()
    }

    private func layer(
        _ id: UUID,
        name: String,
        opacity: Float = 1,
        blendMode: LayerBlendMode = .normal,
        isVisible: Bool = true,
        isLocked: Bool = false
    ) throws -> LayerDescriptor {
        try LayerDescriptor(
            id: id,
            name: name,
            isVisible: isVisible,
            opacity: opacity,
            isLocked: isLocked,
            blendMode: blendMode
        )
    }
}

@MainActor
private final class CacheRig {
    let device: any MTLDevice
    let context: DocumentPaintRenderContext
    let cache: CanvasCompositeTileCache
    let compositor: CanonicalTileCompositor
    let layers: [LayerDescriptor]
    let geometry: DocumentPaintGeometry
    let baselineIdentity: CanvasCanonicalStateIdentity
    private var importRevision: UInt64 = 0

    init(
        device: any MTLDevice,
        context: DocumentPaintRenderContext,
        cache: CanvasCompositeTileCache,
        compositor: CanonicalTileCompositor,
        layers: [LayerDescriptor],
        geometry: DocumentPaintGeometry,
        baselineIdentity: CanvasCanonicalStateIdentity
    ) {
        self.device = device
        self.context = context
        self.cache = cache
        self.compositor = compositor
        self.layers = layers
        self.geometry = geometry
        self.baselineIdentity = baselineIdentity
    }

    static func make(
        size: PixelSize,
        layers: [LayerDescriptor],
        envelope: CanvasPresentationMemoryEnvelope = .production,
        returnLease: SparseTileLeaseReturner? = nil,
        completionFailureInjector:
            SparseTileSamplingCompletionFailureInjector? = nil
    ) throws -> CacheRig? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }
        let library = try canvasCompositeTestLibrary(device: device)
        let stack = try LayerStack(
            layers: layers,
            activeLayerID: try #require(layers.last?.id)
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: size,
            storagePixelSize: size,
            radialLayout: nil
        )
        let context = try DocumentPaintRenderContext(
            device: device,
            commandQueue: queue,
            library: library,
            geometry: geometry,
            initialLayerStack: stack,
            byteBudget: 256 * 1_024 * 1_024,
            transferByteCapacity: 256 * 1_024 * 1_024,
            maximumRevisionBytes: 256 * 1_024 * 1_024
        )
        let compositor = try (returnLease != nil
            || completionFailureInjector != nil) ?
            CanonicalTileCompositor.makeForTesting(
                device: device,
                library: library,
                workspaceByteBudget: envelope.canonicalBatchWorkspaceBytes,
                returnLease: returnLease ?? { lease in
                    try lease.returnLease()
                },
                completionFailureInjector: completionFailureInjector
            ) : CanonicalTileCompositor.make(
                device: device,
                library: library,
                backendRequest: .forceFallback,
                workspaceByteBudget: envelope.canonicalBatchWorkspaceBytes
            )
        let cache = try CanvasCompositeTileCache(
            device: device,
            compositor: compositor,
            storagePixelSize: size,
            baselineIdentity: context.canonicalStateIdentity(),
            envelope: envelope
        )
        return CacheRig(
            device: device,
            context: context,
            cache: cache,
            compositor: compositor,
            layers: layers,
            geometry: geometry,
            baselineIdentity: context.canonicalStateIdentity()
        )
    }

    func install(
        _ colors: [UUID: [PaintTileCoordinate: SIMD4<Float>]]
    ) async throws {
        try await installNativePayloads(colors.mapValues { values in
            values.mapValues(solidCompositePayload)
        })
    }

    func installNativePayloads(
        _ nativePayloads: [UUID: [PaintTileCoordinate: Data]]
    ) async throws {
        importRevision += 1
        var payloads: [UUID: Data] = [:]
        let archives = try layers.map { layer in
            let tiles = try (nativePayloads[layer.id] ?? [:]).sorted {
                $0.key < $1.key
            }.map { coordinate, payload in
                let persistedID = UUID()
                payloads[persistedID] = payload
                let descriptor = try PaintTileDescriptor(
                    coordinate: coordinate,
                    logicalPixelSize: geometry.storagePixelSize
                )
                return DocumentPaintNativeArchiveTile(
                    persistedID: persistedID,
                    coordinate: coordinate,
                    logicalBounds: descriptor.logicalBounds
                )
            }
            return DocumentPaintNativeArchiveLayer(
                layerID: layer.id,
                rasterRevision: importRevision,
                tiles: tiles
            )
        }
        let manifest = try DocumentPaintNativeArchiveImportManifest(
            geometry: geometry,
            layerStack: try LayerStack(
                layers: layers,
                activeLayerID: try #require(layers.last?.id)
            ),
            layers: archives
        )
        let frozenPayloads = payloads
        try await context.importNativeArchive(manifest) { writer in
            for (id, payload) in frozenPayloads {
                try writer.install(payload, for: id)
            }
        }
    }

    func applyInitial() async throws -> CanvasCompositeRevision {
        let identity = context.canonicalStateIdentity()
        let plan = try context.prepareCompositeTileUpdatePlan(
            baseIdentity: identity,
            targetIdentity: identity,
            invalidation: .full,
            cachedCoordinates: []
        )
        return try await cache.apply(plan)
    }
}

private actor CanvasCompositeTestGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilArrived() async throws {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor CanvasCompositeTestCounter {
    private(set) var values: [Int] = []

    func record(_ value: Int) {
        values.append(value)
    }
}

private func solidCompositePayload(_ color: SIMD4<Float>) -> Data {
    let texel = [color.x, color.y, color.z, color.w].map {
        Float16($0).bitPattern
    }
    var words: [UInt16] = []
    words.reserveCapacity(PaintTileDescriptor.residentByteCount / 2)
    for _ in 0..<(PaintTileDescriptor.side * PaintTileDescriptor.side) {
        words.append(contentsOf: texel)
    }
    return words.withUnsafeBytes { Data($0) }
}

private func quantizedRGBA16(_ color: SIMD4<Float>) -> SIMD4<Float> {
    SIMD4(
        Float(Float16(color.x)),
        Float(Float16(color.y)),
        Float(Float16(color.z)),
        Float(Float16(color.w))
    )
}

private func patternedCompositePayload(
    _ sample: (_ x: Int, _ y: Int) -> SIMD4<Float>
) -> Data {
    var words: [UInt16] = []
    words.reserveCapacity(
        PaintTileDescriptor.side * PaintTileDescriptor.side * 4
    )
    for y in 0..<PaintTileDescriptor.side {
        for x in 0..<PaintTileDescriptor.side {
            let color = sample(x, y)
            words.append(Float16(color.x).bitPattern)
            words.append(Float16(color.y).bitPattern)
            words.append(Float16(color.z).bitPattern)
            words.append(Float16(color.w).bitPattern)
        }
    }
    return words.withUnsafeBytes { Data($0) }
}

private func compositePayloadFingerprint(_ payload: Data) -> UInt64 {
    payload.withUnsafeBytes { bytes in
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

private func fillCompositeTexture(
    _ texture: any MTLTexture,
    color: SIMD4<Float16>,
    device: any MTLDevice
) throws {
    let pixels = Array(
        repeating: color,
        count: texture.width * texture.height
    )
    let buffer = try pixels.withUnsafeBytes { bytes in
        try #require(device.makeBuffer(
            bytes: bytes.baseAddress!,
            length: bytes.count,
            options: .storageModeShared
        ))
    }
    let queue = try #require(device.makeCommandQueue())
    let command = try #require(queue.makeCommandBuffer())
    let blit = try #require(command.makeBlitCommandEncoder())
    blit.copy(
        from: buffer,
        sourceOffset: 0,
        sourceBytesPerRow: texture.width * 8,
        sourceBytesPerImage: texture.width * texture.height * 8,
        sourceSize: MTLSize(
            width: texture.width,
            height: texture.height,
            depth: 1
        ),
        to: texture,
        destinationSlice: 0,
        destinationLevel: 0,
        destinationOrigin: .init(x: 0, y: 0, z: 0)
    )
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else {
        throw CanvasCompositeTileCacheError.invalidPlan
    }
}

private func canvasCompositeTestLibrary(
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
