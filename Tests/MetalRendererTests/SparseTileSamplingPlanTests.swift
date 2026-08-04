import Metal
import PatternEngine
import Testing
@testable import MetalRenderer

@Suite("Sparse tile sampling plan")
struct SparseTileSamplingPlanTests {
    @Test
    func finiteFourNeighborCornerUsesAllTilesInLinearPremultipliedSpace()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeSource(
            device: device,
            pixelSize: PixelSize(width: 512, height: 512),
            coordinates: [
                .init(x: 0, y: 0), .init(x: 1, y: 0),
                .init(x: 0, y: 1), .init(x: 1, y: 1),
            ],
            addressing: .finite(PixelSize(width: 512, height: 512))
        )
        let cache = SparseTileSamplingPlanCache()
        let lease = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 512, 512),
            limits: .testDefaults
        )
        defer { try? lease.retire() }

        let provider = CoordinateColorProvider(colors: [
            .init(x: 0, y: 0): SIMD4(1, 0, 0, 1),
            .init(x: 1, y: 0): SIMD4(0, 1, 0, 1),
            .init(x: 0, y: 1): SIMD4(0, 0, 1, 1),
            .init(x: 1, y: 1): SIMD4(1, 1, 1, 1),
        ])
        let actual = try SparseTileCPUReferenceSampler.sample(
            at: SIMD2(256, 256),
            layerID: fixture.layerID,
            role: .canonical,
            content: lease.content,
            provider: provider
        )
        #expect(actual == SIMD4<Float>(0.5, 0.5, 0.5, 1))
    }

    @Test
    func missingFiniteNeighborIsTransparentWithoutWeightRenormalization()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeSource(
            device: device,
            pixelSize: PixelSize(width: 512, height: 256),
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(PixelSize(width: 512, height: 256))
        )
        let cache = SparseTileSamplingPlanCache()
        let lease = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 512, 256),
            limits: .testDefaults
        )
        defer { try? lease.retire() }
        let provider = CoordinateColorProvider(colors: [
            .init(x: 0, y: 0): SIMD4(0.8, 0.4, 0.2, 0.6),
        ])

        let actual = try SparseTileCPUReferenceSampler.sample(
            at: SIMD2(256, 1),
            layerID: fixture.layerID,
            role: .canonical,
            content: lease.content,
            provider: provider
        )
        #expect(actual == SIMD4<Float>(0.4, 0.2, 0.1, 0.3))
    }

    @Test
    func periodicSamplingWrapsEachNegativeNeighborBeforePageLookup() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let period = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: period,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .periodic(period: period)
        )
        let cache = SparseTileSamplingPlanCache()
        let lease = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(-2, -2, 2, 2),
            limits: .testDefaults
        )
        defer { try? lease.retire() }

        let actual = try SparseTileCPUReferenceSampler.sample(
            at: SIMD2(0, 0.5),
            layerID: fixture.layerID,
            role: .canonical,
            content: lease.content,
            provider: LocalXProvider()
        )
        #expect(abs(actual.x - 0.5) < 0.000_01)
        #expect(actual.y == 0)
        #expect(actual.w == 1)
    }

    @Test
    func radialSamplingResolvesSignedLogicalPageToCompactAtlasTile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layout = try RadialSectorLayout(
            maximumRadius: 512,
            sectorAngleRadians: .pi
        )
        let logical = try #require(layout.residentPages.first {
            $0.coordinate.x < 0
        })
        let physical = PaintTileCoordinate(
            x: logical.atlasSlot % layout.atlasColumns,
            y: logical.atlasSlot / layout.atlasColumns
        )
        let fixture = try makeSource(
            device: device,
            pixelSize: layout.atlasPixelSize,
            coordinates: [physical],
            addressing: .radial(layout: layout)
        )
        let cache = SparseTileSamplingPlanCache()
        let lease = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(-512, 0, 512, 512),
            limits: .testDefaults
        )
        defer { try? lease.retire() }

        let point = SIMD2<Double>(
            Double(logical.coordinate.x * 256) + 0.5,
            Double(logical.coordinate.y * 256) + 0.5
        )
        let expected = SIMD4<Float>(0.2, 0.3, 0.4, 0.5)
        let actual = try SparseTileCPUReferenceSampler.sample(
            at: point,
            layerID: fixture.layerID,
            role: .canonical,
            content: lease.content,
            provider: CoordinateColorProvider(colors: [physical: expected])
        )
        #expect(actual == expected)
    }

    @Test
    func cpuProviderReceivesOnlyReferenceAndLocalCoordinates() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let cache = SparseTileSamplingPlanCache()
        let lease = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        defer { try? lease.retire() }
        let provider = RecordingProvider()

        _ = try SparseTileCPUReferenceSampler.sample(
            at: SIMD2(1.5, 2.5),
            layerID: fixture.layerID,
            role: .canonical,
            content: lease.content,
            provider: provider
        )
        #expect(provider.snapshot() == [
            .init(coordinate: .init(x: 0, y: 0), localX: 1, localY: 2),
            .init(coordinate: .init(x: 0, y: 0), localX: 2, localY: 2),
            .init(coordinate: .init(x: 0, y: 0), localX: 1, localY: 3),
            .init(coordinate: .init(x: 0, y: 0), localX: 2, localY: 3),
        ])
    }

    @Test
    func batchingSplitsLargestDimensionWithCompleteBilinearHalos() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 1_024, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: (0..<4).map { .init(x: $0, y: 0) },
            addressing: .finite(size)
        )
        let cache = SparseTileSamplingPlanCache()
        let lease = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 1_024, 256),
            limits: limits(maximumTexturesPerBatch: 2)
        )
        defer { try? lease.retire() }

        #expect(lease.content.batches.map(\.outputRegion) == [
            try region(0, 0, 256, 256),
            try region(256, 0, 512, 256),
            try region(512, 0, 1_024, 256),
        ])
        #expect(lease.content.batches.map(\.globalSlots) == [
            [0, 1], [1, 2], [2, 3],
        ])
        #expect(lease.content.batches.allSatisfy {
            $0.globalSlots.count <= 2
        })
    }

    @Test
    func onePixelThatNeedsTwoRolesFailsBeforeEitherSurfaceIsLeased() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let canonical = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let authoritative = try makeRequest(
            device: device,
            layerID: layerID,
            role: .authoritative,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let before = [
            canonical.surface.backingSnapshot(),
            authoritative.surface.backingSnapshot(),
        ]
        let key = planKey(
            layerID: layerID,
            contentKeys: [canonical.contentKey, authoritative.contentKey]
        )

        #expect(throws: SparseTileSamplingPlanError
            .onePixelBatchExceedsTextureLimit(required: 2, maximum: 1)) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: key,
                sources: [canonical, authoritative],
                outputRegion: try region(0, 0, 1, 1),
                limits: limits(maximumTexturesPerBatch: 1)
            )
        }
        #expect(canonical.surface.backingSnapshot() == before[0])
        #expect(authoritative.surface.backingSnapshot() == before[1])
    }

    @Test
    func pageAndByteLimitsFailBeforeChangingTileStoreEvidence() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 512)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let before = fixture.request.surface.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError.pageEntryLimitExceeded(
            required: 4,
            maximum: 3
        )) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: fixture.key,
                sources: [fixture.request],
                outputRegion: try region(0, 0, 512, 512),
                limits: limits(maximumPageEntries: 3)
            )
        }
        #expect(fixture.request.surface.backingSnapshot() == before)
    }

    @Test
    func sourceOrderIsLayerThenFixedRoleAndRejectedBeforeLease() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let canonical = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let prediction = try makeRequest(
            device: device,
            layerID: layerID,
            role: .prediction,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let before = prediction.surface.backingSnapshot()
        let key = planKey(
            layerID: layerID,
            contentKeys: [canonical.contentKey, prediction.contentKey]
        )

        #expect(throws: SparseTileSamplingPlanError.sourceOrderMismatch) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: key,
                sources: [prediction, canonical],
                outputRegion: try region(0, 0, 256, 256),
                limits: .testDefaults
            )
        }
        #expect(prediction.surface.backingSnapshot() == before)
    }

    @Test
    func cacheReusesContentButAcquiresAndReturnsFreshCompleteVisibleLeases()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            addressing: .finite(size)
        )
        let cache = SparseTileSamplingPlanCache()
        let first = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 512, 256),
            limits: .testDefaults
        )
        let second = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 512, 256),
            limits: .testDefaults
        )

        #expect(first.content === second.content)
        #expect(fixture.request.surface.backingSnapshot().activeLeaseCount == 2)
        try first.retire()
        #expect(fixture.request.surface.backingSnapshot().activeLeaseCount == 1)
        try second.retire()
        #expect(fixture.request.surface.backingSnapshot().activeLeaseCount == 0)
        #expect(throws: SparseTileSamplingPlanError.leaseAlreadyRetired) {
            try second.retire()
        }
    }

    @Test
    func cacheKeyCollisionIsRejectedBeforeLeasingDifferentReferences() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let firstRequest = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size),
            contentRevision: 11
        )
        let collision = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size),
            contentRevision: 11
        )
        let key = planKey(layerID: layerID, contentKeys: [firstRequest.contentKey])
        let cache = SparseTileSamplingPlanCache()
        let first = try cache.acquire(
            key: key,
            sources: [firstRequest],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        defer { try? first.retire() }
        let before = collision.surface.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError.contentKeyCollision) {
            _ = try cache.acquire(
                key: key,
                sources: [collision],
                outputRegion: try region(0, 0, 256, 256),
                limits: .testDefaults
            )
        }
        #expect(collision.surface.backingSnapshot() == before)
    }

    @Test
    func deltaUpdateKeepsSlotsAndReusesUnaffectedRoleChunks() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let canonicalV1 = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size),
            contentRevision: 1
        )
        let canonicalV2 = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size),
            contentRevision: 2,
            disposition: .delta
        )
        let prediction = try makeRequest(
            device: device,
            layerID: layerID,
            role: .prediction,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size),
            contentRevision: 1
        )
        let firstKey = planKey(
            layerID: layerID,
            contentKeys: [canonicalV1.contentKey, prediction.contentKey]
        )
        let secondKey = planKey(
            layerID: layerID,
            contentKeys: [canonicalV2.contentKey, prediction.contentKey]
        )
        let cache = SparseTileSamplingPlanCache()
        let first = try cache.acquire(
            key: firstKey,
            sources: [canonicalV1, prediction],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        let second = try cache.acquire(
            key: secondKey,
            sources: [canonicalV2, prediction],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults,
            updating: first.content
        )
        defer {
            try? first.retire()
            try? second.retire()
        }

        let firstCanonical = try #require(first.content.bindingRecords.first {
            $0.role == .canonical
        })
        let secondCanonical = try #require(second.content.bindingRecords.first {
            $0.role == .canonical
        })
        #expect(firstCanonical.globalSlot == secondCanonical.globalSlot)
        #expect(firstCanonical.reference != secondCanonical.reference)
        let firstPredictionTable = try #require(first.content.pageTable(
            layerID: layerID, role: .prediction
        ))
        let secondPredictionTable = try #require(second.content.pageTable(
            layerID: layerID, role: .prediction
        ))
        #expect(firstPredictionTable.chunks[0]
            === secondPredictionTable.chunks[0])
        let firstPredictionChunk = try #require(first.content.bindingChunks.first {
            $0.layerID == layerID && $0.role == .prediction
        })
        let secondPredictionChunk = try #require(second.content.bindingChunks.first {
            $0.layerID == layerID && $0.role == .prediction
        })
        #expect(firstPredictionChunk === secondPredictionChunk)
        #expect(second.content.telemetry.rebuiltPageEntryCount == 1)
        #expect(second.content.telemetry.rebuiltBindingCount == 1)
    }

    @Test
    func inFlightConsumersKeepLeasesPinnedAcrossCacheInvalidationUntilFinalAck()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let cache = SparseTileSamplingPlanCache()
        let lease = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        let first = try lease.beginConsumer()
        let second = try lease.beginConsumer()
        cache.invalidate(documentGeneration: fixture.key.documentGeneration)
        try lease.retire()
        #expect(fixture.request.surface.backingSnapshot().activeLeaseCount == 1)

        try lease.completeConsumer(second)
        #expect(fixture.request.surface.backingSnapshot().activeLeaseCount == 1)
        try lease.completeConsumer(first)
        #expect(fixture.request.surface.backingSnapshot().activeLeaseCount == 0)
        #expect(throws: SparseTileSamplingPlanError.staleConsumer) {
            try lease.completeConsumer(first)
        }
    }

    @Test
    func overlappingPlanUnionCannotAllocateGlobalSlot512BeforeLeasing() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let pixelSize = PixelSize(
            width: 513 * PaintTileDescriptor.side,
            height: PaintTileDescriptor.side
        )
        let oldContentKey = SparseTileRoleContentKey(
            role: .canonical,
            contentRevision: 1,
            bindingChunkRevision: 1
        )
        let oldReferences = try makeMetadataReferences(
            layerID: layerID,
            pixelSize: pixelSize,
            coordinates: (0..<512).map { .init(x: $0, y: 0) }
        )
        let oldSnapshot = try SparseTileSourceSnapshot(
            contentKey: oldContentKey,
            addressing: .finite(pixelSize),
            layerID: layerID,
            references: oldReferences,
            changedCoordinates: oldReferences.map(\.coordinate),
            disposition: .fullSnapshot
        )
        let oldContent = try SparseTileSamplingPlanBuilder.buildFull(
            key: planKey(layerID: layerID, contentKeys: [oldContentKey]),
            sources: [oldSnapshot],
            outputRegion: try region(0, 0, 1, 1),
            limits: limits(maximumBindingSlots: 512)
        )
        #expect(oldContent.bindingRecords.map(\.globalSlot) == Array(0..<512))

        let replacement = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: pixelSize,
            coordinates: [.init(x: 512, y: 0)],
            addressing: .finite(pixelSize),
            contentRevision: 2,
            disposition: .delta
        )
        let before = replacement.surface.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError.bindingSlotLimitExceeded(
            required: 513,
            maximum: 512
        )) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: planKey(
                    layerID: layerID,
                    contentKeys: [replacement.contentKey]
                ),
                sources: [replacement],
                outputRegion: try region(
                    512 * PaintTileDescriptor.side,
                    0,
                    513 * PaintTileDescriptor.side,
                    PaintTileDescriptor.side
                ),
                limits: limits(maximumBindingSlots: 512),
                updating: oldContent
            )
        }
        #expect(replacement.surface.backingSnapshot() == before)
    }

    @Test
    func integerNeighborResolutionExposesFixedRoleOrderBeforeBilinearMix()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let canonical = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let prediction = try makeRequest(
            device: device,
            layerID: layerID,
            role: .prediction,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let key = planKey(
            layerID: layerID,
            contentKeys: [canonical.contentKey, prediction.contentKey]
        )
        let lease = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sources: [canonical, prediction],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        defer { try? lease.retire() }

        let resolution = try SparseTileCPUReferenceSampler.resolveFourNeighbors(
            at: SIMD2(8.75, 9.25),
            content: lease.content
        )

        #expect(lease.boundTextures.count == 2)
        #expect(ObjectIdentifier(lease.boundTextures[0].texture as AnyObject)
            != ObjectIdentifier(lease.boundTextures[1].texture as AnyObject))
        #expect(resolution.fraction == SIMD2<Float>(0.25, 0.75))
        #expect(resolution.neighbors.map(\.logicalPixel) == [
            SIMD2(8, 8), SIMD2(9, 8), SIMD2(8, 9), SIMD2(9, 9),
        ])
        #expect(resolution.neighbors.allSatisfy {
            $0.contributions.map(\.role) == [.canonical, .prediction]
                && $0.contributions.map(\.globalBindingSlot) == [0, 1]
        })
    }

    @Test
    func declaredRoleOrderCannotOverrideCanonicalAuthoritativePredictionOrder()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let canonical = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let prediction = try makeRequest(
            device: device,
            layerID: layerID,
            role: .prediction,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let reversedKey = planKey(
            layerID: layerID,
            contentKeys: [prediction.contentKey, canonical.contentKey]
        )
        let before = canonical.surface.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError.contentRoleMismatch) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: reversedKey,
                sources: [prediction, canonical],
                outputRegion: try region(0, 0, 256, 256),
                limits: .testDefaults
            )
        }
        #expect(canonical.surface.backingSnapshot() == before)
    }

    @Test
    func normalizedSnapshotRejectsUnsortedDuplicateAndForeignReferences()
        throws
    {
        let layerID = UUID()
        let size = PixelSize(width: 512, height: 256)
        let references = try makeMetadataReferences(
            layerID: layerID,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)]
        )
        let key = SparseTileRoleContentKey(
            role: .canonical,
            contentRevision: 1,
            bindingChunkRevision: 1
        )

        #expect(throws: SparseTileSamplingPlanError.unsortedReference) {
            _ = try SparseTileSourceSnapshot(
                contentKey: key,
                addressing: .finite(size),
                layerID: layerID,
                references: Array(references.reversed()),
                changedCoordinates: [],
                disposition: .fullSnapshot
            )
        }
        #expect(throws: SparseTileSamplingPlanError.duplicateReference(
            references[0].coordinate
        )) {
            _ = try SparseTileSourceSnapshot(
                contentKey: key,
                addressing: .finite(size),
                layerID: layerID,
                references: [references[0], references[0]],
                changedCoordinates: [],
                disposition: .fullSnapshot
            )
        }
        #expect(throws: SparseTileSamplingPlanError.foreignReference(
            references[0]
        )) {
            _ = try SparseTileSourceSnapshot(
                contentKey: key,
                addressing: .finite(size),
                layerID: UUID(),
                references: [references[0]],
                changedCoordinates: [],
                disposition: .fullSnapshot
            )
        }
    }

    @Test
    func acceptedCanonicalAndTransientAdaptersPreserveExactVisibleMetadata()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let layerID = UUID()
        let canonicalFixture = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            addressing: .finite(size)
        )
        let binding = DocumentPaintLayerBinding(
            layerID: layerID,
            generation: canonicalFixture.surface.generation,
            canonical: canonicalFixture.surface
        )
        let canonical = try binding.sparseTileSourceRequest(
            addressing: .finite(size)
        )
        #expect(canonical.role == .canonical)
        #expect(canonical.disposition == .fullSnapshot)
        #expect(canonical.changedCoordinates
            == canonical.surface.references.map(\.coordinate))

        let authoritative = try makeRequest(
            device: device,
            layerID: layerID,
            role: .authoritative,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let prediction = try makeRequest(
            device: device,
            layerID: layerID,
            role: .prediction,
            pixelSize: size,
            coordinates: [.init(x: 1, y: 0)],
            addressing: .finite(size)
        )
        let transient = try SparseTileAcceptedSourceAdapter.transient(
            layerID: layerID,
            authoritative: authoritative.surface,
            prediction: prediction.surface,
            changedRole: .prediction,
            changedCoordinates: [.init(x: 1, y: 0)],
            addressing: .finite(size)
        )
        #expect(transient.map(\.role) == [.authoritative, .prediction])
        #expect(transient[0].changedCoordinates.isEmpty)
        #expect(transient[1].changedCoordinates == [.init(x: 1, y: 0)])
        #expect(transient.allSatisfy { $0.disposition == .delta })
    }

    @Test
    func failedUpdateLeavesPreviousCachedContentCurrentAndUnleased() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let canonical = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let firstKey = planKey(
            layerID: layerID, contentKeys: [canonical.contentKey]
        )
        let cache = SparseTileSamplingPlanCache()
        let first = try cache.acquire(
            key: firstKey,
            sources: [canonical],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        let prediction = try makeRequest(
            device: device,
            layerID: layerID,
            role: .prediction,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let failingKey = planKey(
            layerID: layerID,
            contentKeys: [canonical.contentKey, prediction.contentKey]
        )
        let predictionBefore = prediction.surface.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError
            .onePixelBatchExceedsTextureLimit(required: 2, maximum: 1)) {
            _ = try cache.acquire(
                key: failingKey,
                sources: [canonical, prediction],
                outputRegion: try region(0, 0, 1, 1),
                limits: limits(maximumTexturesPerBatch: 1),
                updating: first.content
            )
        }
        #expect(prediction.surface.backingSnapshot() == predictionBefore)
        let reacquired = try cache.acquire(
            key: firstKey,
            sources: [canonical],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        #expect(reacquired.content === first.content)
        try reacquired.retire()
        try first.retire()
    }

    @Test
    func cacheRejectsDisjointPlanWhenLiveGlobalSlotUnionCannotFit() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 768, height: 256)
        let layerID = UUID()
        let firstRequest = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            addressing: .finite(size),
            contentRevision: 1
        )
        let disjoint = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 2, y: 0)],
            addressing: .finite(size),
            contentRevision: 2
        )
        let cache = SparseTileSamplingPlanCache()
        let first = try cache.acquire(
            key: planKey(layerID: layerID, contentKeys: [firstRequest.contentKey]),
            sources: [firstRequest],
            outputRegion: try region(0, 0, 512, 256),
            limits: limits(maximumBindingSlots: 2)
        )
        defer { try? first.retire() }
        let before = disjoint.surface.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError.bindingSlotLimitExceeded(
            required: 3,
            maximum: 2
        )) {
            _ = try cache.acquire(
                key: planKey(layerID: layerID, contentKeys: [disjoint.contentKey]),
                sources: [disjoint],
                outputRegion: try region(512, 0, 768, 256),
                limits: limits(maximumBindingSlots: 2)
            )
        }
        #expect(disjoint.surface.backingSnapshot() == before)
    }

    @Test
    func cacheHitStillHonorsStricterBatchLimitsBeforeLeasing() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let canonical = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let prediction = try makeRequest(
            device: device,
            layerID: layerID,
            role: .prediction,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let key = planKey(
            layerID: layerID,
            contentKeys: [canonical.contentKey, prediction.contentKey]
        )
        let cache = SparseTileSamplingPlanCache()
        let first = try cache.acquire(
            key: key,
            sources: [canonical, prediction],
            outputRegion: try region(0, 0, 1, 1),
            limits: .testDefaults
        )
        defer { try? first.retire() }
        let before = prediction.surface.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError
            .onePixelBatchExceedsTextureLimit(required: 2, maximum: 1)) {
            _ = try cache.acquire(
                key: key,
                sources: [canonical, prediction],
                outputRegion: try region(0, 0, 1, 1),
                limits: limits(maximumTexturesPerBatch: 1)
            )
        }
        #expect(prediction.surface.backingSnapshot() == before)
    }

    @Test
    func sourceRequestCapturesExactReferencesBeforeLaterSurfaceMutation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let layerID = UUID()
        let surface = TiledRasterSurface(
            device: device,
            layerID: layerID,
            pixelSize: size,
            generation: 7,
            byteBudget: 4 * PaintTileDescriptor.residentByteCount
        )
        let initial = try surface.reserveTiles(
            at: [.init(x: 0, y: 0)], pinReasons: [.dirty]
        )
        try surface.markDirty(initial)
        try surface.returnLease(initial)
        let request = try SparseTileSourceRequest(
            contentKey: SparseTileRoleContentKey(
                role: .canonical,
                contentRevision: surface.revision.rawValue,
                bindingChunkRevision: 1
            ),
            addressing: .finite(size),
            surface: surface,
            changedCoordinates: [.init(x: 0, y: 0)],
            disposition: .fullSnapshot
        )
        let key = planKey(layerID: layerID, contentKeys: [request.contentKey])
        let later = try surface.reserveTiles(
            at: [.init(x: 1, y: 0)], pinReasons: [.dirty]
        )
        try surface.markDirty(later)
        try surface.returnLease(later)

        let lease = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sources: [request],
            outputRegion: try region(0, 0, 512, 256),
            limits: .testDefaults
        )
        defer { try? lease.retire() }

        #expect(surface.references.count == 2)
        #expect(lease.content.bindingRecords.map(\.reference.coordinate)
            == [.init(x: 0, y: 0)])
    }

    @Test
    func consumerHandleStronglyPinsLeaseAfterPublicLeaseIsDropped() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let cache = SparseTileSamplingPlanCache()
        var lease: SparseTileSamplingPlanLease? = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        weak let weakLease = lease
        let consumer = try #require(lease).beginConsumer()
        try lease?.retire()
        lease = nil

        #expect(weakLease != nil)
        #expect(fixture.request.surface.backingSnapshot().activeLeaseCount == 1)
        #expect(cache.pendingRetirementCount == 1)

        try consumer.complete()
        #expect(fixture.request.surface.backingSnapshot().activeLeaseCount == 0)
        #expect(cache.pendingRetirementCount == 0)
    }

    @Test
    func firstFailedReturnIsRetainedAndRetriedWithoutDoubleReturn() throws {
        try assertReturnFailureIsRetryable(failingAttempt: 1)
    }

    @Test
    func middleFailedReturnRetainsItAndEarlierLeasesForOrderedRetry() throws {
        try assertReturnFailureIsRetryable(failingAttempt: 2)
    }

    @Test
    func concurrentSameKeyAcquiresSelectOneCanonicalContent() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let cache = SparseTileSamplingPlanCache()
        let leases = try await withThrowingTaskGroup(
            of: SparseTileSamplingPlanLease.self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    try cache.acquire(
                        key: fixture.key,
                        sources: [fixture.request],
                        outputRegion: try region(0, 0, 256, 256),
                        limits: .testDefaults
                    )
                }
            }
            var values: [SparseTileSamplingPlanLease] = []
            for try await value in group { values.append(value) }
            return values
        }
        let canonical = try #require(leases.first?.content)
        #expect(leases.allSatisfy { $0.content === canonical })
        #expect(fixture.request.surface.backingSnapshot().activeLeaseCount == 8)
        for lease in leases { try lease.retire() }
        #expect(fixture.request.surface.backingSnapshot().activeLeaseCount == 0)
        #expect(cache.pendingRetirementCount == 0)
    }

    @Test
    func concurrentSameKeyWithDifferentFingerprintRejectsTheLoser() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let firstRequest = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size),
            contentRevision: 1
        )
        let collision = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size),
            contentRevision: 1
        )
        let key = planKey(layerID: layerID, contentKeys: [firstRequest.contentKey])
        let barrier = OneShotReservationBarrier()
        let cache = SparseTileSamplingPlanCache(
            afterSlotReservation: barrier.waitOnce
        )
        let loser = Task {
            try cache.acquire(
                key: key,
                sources: [firstRequest],
                outputRegion: try region(0, 0, 256, 256),
                limits: .testDefaults
            )
        }
        barrier.waitUntilReached()
        let winner = try cache.acquire(
            key: key,
            sources: [collision],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        barrier.proceed()

        do {
            _ = try await loser.value
            Issue.record("incompatible same-key race unexpectedly succeeded")
        } catch {
            #expect(error as? SparseTileSamplingPlanError == .contentKeyCollision)
        }
        #expect(firstRequest.surface.backingSnapshot().activeLeaseCount == 0)
        #expect(collision.surface.backingSnapshot().activeLeaseCount == 1)
        try winner.retire()
        #expect(cache.pendingRetirementCount == 0)
    }

    @Test
    func extremeOutputAndSampleGeometryThrowsInsteadOfTrapping() throws {
        #expect(throws: SparseTileSamplingPlanError.arithmeticOverflow) {
            _ = try SparseTileOutputRegion(
                minX: Int.min,
                minY: 0,
                maxX: Int.max,
                maxY: 1
            )
        }

        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let lease = try SparseTileSamplingPlanCache().acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        defer { try? lease.retire() }
        #expect(throws: SparseTileSamplingPlanError.arithmeticOverflow) {
            _ = try SparseTileCPUReferenceSampler.resolveFourNeighbors(
                at: SIMD2(Double(Int.max), 0),
                content: lease.content
            )
        }
    }

    @Test
    func pageLimitsRejectBeforeAnyPageTableAllocation() throws {
        let layerID = UUID()
        let size = PixelSize(width: 1_024, height: 1_024)
        let contentKey = SparseTileRoleContentKey(
            role: .canonical,
            contentRevision: 1,
            bindingChunkRevision: 1
        )
        let source = try SparseTileSourceSnapshot(
            contentKey: contentKey,
            addressing: .finite(size),
            layerID: layerID,
            references: [],
            changedCoordinates: [],
            disposition: .fullSnapshot
        )
        let allocationProbe = IntegerProbe()

        #expect(throws: SparseTileSamplingPlanError.pageEntryLimitExceeded(
            required: 16,
            maximum: 1
        )) {
            _ = try SparseTileSamplingPlanBuilder.buildFull(
                key: planKey(layerID: layerID, contentKeys: [contentKey]),
                sources: [source],
                outputRegion: try region(0, 0, 1, 1),
                limits: limits(maximumPageEntries: 1),
                allocationObserver: { _, count in
                    allocationProbe.record(count)
                }
            )
        }
        #expect(allocationProbe.value == 0)
    }

    @Test
    func terminalBatchAndHaloFailuresPrecedeEveryPlanAllocation() throws {
        let layerID = UUID()
        let size = PixelSize(width: 256, height: 256)
        let reference = try makeMetadataReferences(
            layerID: layerID,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)]
        )
        let canonicalKey = SparseTileRoleContentKey(
            role: .canonical,
            contentRevision: 1,
            bindingChunkRevision: 1
        )
        let predictionKey = SparseTileRoleContentKey(
            role: .prediction,
            contentRevision: 1,
            bindingChunkRevision: 1
        )
        let sources = try [canonicalKey, predictionKey].map { contentKey in
            try SparseTileSourceSnapshot(
                contentKey: contentKey,
                addressing: .finite(size),
                layerID: layerID,
                references: reference,
                changedCoordinates: reference.map(\.coordinate),
                disposition: .fullSnapshot
            )
        }
        let probe = IntegerProbe()
        let observe: @Sendable (SparseTilePlanAllocationKind, Int) -> Void = {
            _, count in probe.record(count)
        }

        #expect(throws: SparseTileSamplingPlanError
            .onePixelBatchExceedsTextureLimit(required: 2, maximum: 1)) {
            _ = try SparseTileSamplingPlanBuilder.buildFull(
                key: planKey(
                    layerID: layerID,
                    contentKeys: [canonicalKey, predictionKey]
                ),
                sources: sources,
                outputRegion: try region(0, 0, 1, 1),
                limits: limits(maximumTexturesPerBatch: 1),
                allocationObserver: observe
            )
        }
        #expect(probe.value == 0)

        #expect(throws: SparseTileSamplingPlanError
            .onePixelBatchExceedsTextureLimit(required: 2, maximum: 1)) {
            _ = try SparseTileSamplingPlanBuilder.buildFull(
                key: planKey(
                    layerID: layerID,
                    contentKeys: [canonicalKey, predictionKey]
                ),
                sources: sources,
                outputRegion: try region(0, 0, 2, 1),
                limits: limits(maximumTexturesPerBatch: 1),
                allocationObserver: observe
            )
        }
        #expect(probe.value == 0)

        #expect(throws: SparseTileSamplingPlanError.arithmeticOverflow) {
            _ = try SparseTileSamplingPlanBuilder.buildFull(
                key: planKey(
                    layerID: layerID,
                    contentKeys: [canonicalKey, predictionKey]
                ),
                sources: sources,
                outputRegion: try SparseTileOutputRegion(
                    minX: Int.max - 1,
                    minY: 0,
                    maxX: Int.max,
                    maxY: 1
                ),
                limits: .testDefaults,
                allocationObserver: observe
            )
        }
        #expect(probe.value == 0)
    }

    @Test
    func duplicateLayerEntriesCannotSplitAndReorderFixedRoles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let prediction = try makeRequest(
            device: device,
            layerID: layerID,
            role: .prediction,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let canonical = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let duplicateLayerKey = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [
                .init(layerID: layerID, roles: [prediction.contentKey]),
                .init(layerID: layerID, roles: [canonical.contentKey]),
            ],
            addressingRevision: 1,
            outputGeometryRevision: 1
        )
        let predictionBefore = prediction.surface.backingSnapshot()
        let canonicalBefore = canonical.surface.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError.duplicateLayer(layerID)) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: duplicateLayerKey,
                sources: [prediction, canonical],
                outputRegion: try region(0, 0, 256, 256),
                limits: .testDefaults
            )
        }
        #expect(prediction.surface.backingSnapshot() == predictionBefore)
        #expect(canonical.surface.backingSnapshot() == canonicalBefore)
    }

    @Test
    func invalidatingAnInFlightReservationPreventsStalePublication() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let barrier = OneShotReservationBarrier()
        let cache = SparseTileSamplingPlanCache(
            afterSlotReservation: barrier.waitOnce
        )
        let acquisition = Task {
            try cache.acquire(
                key: fixture.key,
                sources: [fixture.request],
                outputRegion: try region(0, 0, 256, 256),
                limits: .testDefaults
            )
        }
        barrier.waitUntilReached()
        cache.invalidate(documentGeneration: fixture.key.documentGeneration)
        barrier.proceed()

        do {
            _ = try await acquisition.value
            Issue.record("invalidated reservation unexpectedly published")
        } catch {
            #expect(error as? SparseTileSamplingPlanError == .staleSlotOwner)
        }
        #expect(fixture.request.surface.backingSnapshot().activeLeaseCount == 0)
        #expect(cache.pendingRetirementCount == 0)

        let fresh = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        try fresh.retire()
    }

    @Test
    func staleFailedRetirementCannotFreeAReusedSlotOwner() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let layerID = UUID()
        let firstRequest = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size),
            contentRevision: 1
        )
        let secondRequest = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 1, y: 0)],
            addressing: .finite(size),
            contentRevision: 2
        )
        let probe = LeaseReturnProbe(failingAttempts: [1, 2])
        let cache = SparseTileSamplingPlanCache(returnLease: probe.call)
        var first: SparseTileSamplingPlanLease? = try cache.acquire(
            key: planKey(layerID: layerID, contentKeys: [firstRequest.contentKey]),
            sources: [firstRequest],
            outputRegion: try region(0, 0, 256, 256),
            limits: limits(maximumBindingSlots: 1)
        )
        #expect(throws: LeaseReturnProbe.InjectedError.failure) {
            try first?.retire()
        }
        first = nil
        #expect(cache.pendingRetirementCount == 1)
        #expect(throws: SparseTileSamplingPlanError.bindingSlotLimitExceeded(
            required: 2,
            maximum: 1
        )) {
            _ = try cache.acquire(
                key: planKey(
                    layerID: layerID,
                    contentKeys: [secondRequest.contentKey]
                ),
                sources: [secondRequest],
                outputRegion: try region(256, 0, 512, 256),
                limits: limits(maximumBindingSlots: 1)
            )
        }

        try cache.retryPendingRetirements()
        let second = try cache.acquire(
            key: planKey(layerID: layerID, contentKeys: [secondRequest.contentKey]),
            sources: [secondRequest],
            outputRegion: try region(256, 0, 512, 256),
            limits: limits(maximumBindingSlots: 1)
        )
        try cache.retryPendingRetirements()
        #expect(secondRequest.surface.backingSnapshot().activeLeaseCount == 1)
        try second.retire()
        #expect(cache.pendingRetirementCount == 0)
    }

    @Test
    func sparsePlanRemainsDisconnectedFromProductionRendererAndShaderABI()
        throws
    {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for path in [
            "Sources/MetalRenderer/GridRenderer.swift",
            "Sources/MetalRenderer/Shaders.metal",
            "Sources/MetalRenderer/ShaderABI.swift",
            "Sources/CShaderTypes/include/ShaderTypes.h",
        ] {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            #expect(!source.contains("SparseTileSamplingPlan"))
            #expect(!source.contains("SparseTileSourceRequest"))
        }
    }

    private func assertReturnFailureIsRetryable(failingAttempt: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let requests = try SparseTileSampleRole.allCases.map { role in
            try makeRequest(
                device: device,
                layerID: layerID,
                role: role,
                pixelSize: size,
                coordinates: [.init(x: 0, y: 0)],
                addressing: .finite(size)
            )
        }
        let key = planKey(
            layerID: layerID,
            contentKeys: requests.map(\.contentKey)
        )
        let probe = LeaseReturnProbe(failingAttempts: [failingAttempt])
        let cache = SparseTileSamplingPlanCache(returnLease: probe.call)
        var lease: SparseTileSamplingPlanLease? = try cache.acquire(
            key: key,
            sources: requests,
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )

        #expect(throws: LeaseReturnProbe.InjectedError.failure) {
            try lease?.retire()
        }
        let afterFailure = requests.map {
            $0.surface.backingSnapshot().activeLeaseCount
        }
        #expect(afterFailure.reduce(0, +) == 4 - failingAttempt)
        #expect(cache.pendingRetirementCount == 1)

        // The public lease may disappear; cache ownership keeps the exact
        // failed and not-yet-attempted returns alive and retryable.
        lease = nil
        try cache.retryPendingRetirements()
        #expect(requests.allSatisfy {
            $0.surface.backingSnapshot().activeLeaseCount == 0
        })
        #expect(cache.pendingRetirementCount == 0)
        let attempts = probe.attemptedLeases()
        #expect(attempts.count == 4)
        #expect(Dictionary(grouping: attempts, by: { $0 }).values
            .map(\.count).sorted() == [1, 1, 2])
    }
}

private struct SourceFixture {
    let layerID: UUID
    let request: SparseTileSourceRequest
    let key: SparseTileSamplingPlanKey
}

private func makeSource(
    device: any MTLDevice,
    pixelSize: PixelSize,
    coordinates: [PaintTileCoordinate],
    addressing: SparseTileAddressing
) throws -> SourceFixture {
    let layerID = UUID()
    let request = try makeRequest(
        device: device,
        layerID: layerID,
        role: .canonical,
        pixelSize: pixelSize,
        coordinates: coordinates,
        addressing: addressing
    )
    return SourceFixture(
        layerID: layerID,
        request: request,
        key: planKey(layerID: layerID, contentKeys: [request.contentKey])
    )
}

private func makeRequest(
    device: any MTLDevice,
    layerID: UUID,
    role: SparseTileSampleRole,
    pixelSize: PixelSize,
    coordinates: [PaintTileCoordinate],
    addressing: SparseTileAddressing,
    contentRevision: UInt64? = nil,
    disposition: SparseTileSourceDisposition = .fullSnapshot
) throws -> SparseTileSourceRequest {
    let surface = TiledRasterSurface(
        device: device,
        layerID: layerID,
        pixelSize: pixelSize,
        generation: 7,
        byteBudget: max(1, coordinates.count) * PaintTileDescriptor.residentByteCount
    )
    if !coordinates.isEmpty {
        let tileLease = try surface.reserveTiles(
            at: coordinates,
            pinReasons: [.dirty]
        )
        try surface.markDirty(tileLease)
        try surface.returnLease(tileLease)
    }
    let contentKey = SparseTileRoleContentKey(
        role: role,
        contentRevision: contentRevision ?? surface.revision.rawValue,
        bindingChunkRevision: 1
    )
    let request = try SparseTileSourceRequest(
        contentKey: contentKey,
        addressing: addressing,
        surface: surface,
        changedCoordinates: coordinates.sorted(),
        disposition: disposition
    )
    return request
}

private func planKey(
    layerID: UUID,
    contentKeys: [SparseTileRoleContentKey]
) -> SparseTileSamplingPlanKey {
    SparseTileSamplingPlanKey(
        documentGeneration: 7,
        orderedLayers: [
            SparseTileLayerContentKey(layerID: layerID, roles: contentKeys),
        ],
        addressingRevision: 1,
        outputGeometryRevision: 1
    )
}

private func makeMetadataReferences(
    layerID: UUID,
    pixelSize: PixelSize,
    coordinates: [PaintTileCoordinate]
) throws -> [PaintTileReference] {
    let storeIdentity = PaintTileStoreIdentity()
    let surfaceID = UUID()
    return try coordinates.enumerated().map { index, coordinate in
        PaintTileReference(
            storeIdentity: storeIdentity,
            physicalSurfaceID: surfaceID,
            layerID: layerID,
            physicalGeneration: 7,
            identity: PaintTileIdentity(
                layerID: layerID,
                coordinate: coordinate,
                tileID: PaintTileID(rawValue: UInt64(index + 1))
            ),
            descriptor: try PaintTileDescriptor(
                coordinate: coordinate,
                logicalPixelSize: pixelSize
            )
        )
    }
}

private extension SparseTilePlanLimits {
    static let testDefaults = SparseTilePlanLimits(
        maximumPageEntries: 4_096,
        maximumPageChunks: 256,
        maximumPageTableBytes: 512 * 1_024,
        maximumBindingSlots: 256,
        maximumBindingChunks: 64,
        maximumBindingBytes: 256 * 1_024,
        maximumTexturesPerBatch: 16,
        maximumBatchCount: 1_024
    )
}

private func limits(
    maximumPageEntries: Int = 4_096,
    maximumBindingSlots: Int = 256,
    maximumTexturesPerBatch: Int = 16,
    maximumBatchCount: Int = 1_024
) -> SparseTilePlanLimits {
    SparseTilePlanLimits(
        maximumPageEntries: maximumPageEntries,
        maximumPageChunks: 256,
        maximumPageTableBytes: 512 * 1_024,
        maximumBindingSlots: maximumBindingSlots,
        maximumBindingChunks: 64,
        maximumBindingBytes: 256 * 1_024,
        maximumTexturesPerBatch: maximumTexturesPerBatch,
        maximumBatchCount: maximumBatchCount
    )
}

private func region(
    _ minX: Int, _ minY: Int, _ maxX: Int, _ maxY: Int
) throws -> SparseTileOutputRegion {
    try SparseTileOutputRegion(
        minX: minX, minY: minY, maxX: maxX, maxY: maxY
    )
}

private struct CoordinateColorProvider: SparseTileCPUTexelProvider {
    let colors: [PaintTileCoordinate: SIMD4<Float>]

    func texel(
        reference: PaintTileReference,
        localX: Int,
        localY: Int
    ) throws -> SIMD4<Float> {
        colors[reference.coordinate] ?? .zero
    }
}

private struct LocalXProvider: SparseTileCPUTexelProvider {
    func texel(
        reference: PaintTileReference,
        localX: Int,
        localY: Int
    ) throws -> SIMD4<Float> {
        SIMD4(Float(localX) / 255, 0, 0, 1)
    }
}

private final class RecordingProvider: SparseTileCPUTexelProvider,
    @unchecked Sendable
{
    struct Call: Equatable {
        let coordinate: PaintTileCoordinate
        let localX: Int
        let localY: Int
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    func texel(
        reference: PaintTileReference,
        localX: Int,
        localY: Int
    ) throws -> SIMD4<Float> {
        lock.lock()
        calls.append(.init(
            coordinate: reference.coordinate,
            localX: localX,
            localY: localY
        ))
        lock.unlock()
        return SIMD4(repeating: 1)
    }

    func snapshot() -> [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class LeaseReturnProbe: @unchecked Sendable {
    enum InjectedError: Error, Equatable {
        case failure
    }

    private let lock = NSLock()
    private let failingAttempts: Set<Int>
    private var attempt = 0
    private var leases: [LeaseIdentity] = []

    fileprivate struct LeaseIdentity: Hashable {
        let surface: ObjectIdentifier
        let leaseID: PaintTileLeaseID
    }

    init(failingAttempts: Set<Int>) {
        self.failingAttempts = failingAttempts
    }

    func call(surface: TiledRasterSurface, lease: PaintTileLease) throws {
        lock.lock()
        attempt += 1
        let currentAttempt = attempt
        leases.append(.init(
            surface: ObjectIdentifier(surface),
            leaseID: lease.id
        ))
        lock.unlock()
        if failingAttempts.contains(currentAttempt) { throw InjectedError.failure }
        try surface.returnLease(lease)
    }

    func attemptedLeases() -> [LeaseIdentity] {
        lock.lock()
        defer { lock.unlock() }
        return leases
    }
}

private final class OneShotReservationBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let reached = DispatchSemaphore(value: 0)
    private let continuation = DispatchSemaphore(value: 0)
    private var shouldWait = true

    func waitOnce() {
        lock.lock()
        let wait = shouldWait
        shouldWait = false
        lock.unlock()
        guard wait else { return }
        reached.signal()
        continuation.wait()
    }

    func waitUntilReached() {
        reached.wait()
    }

    func proceed() {
        continuation.signal()
    }
}

private final class IntegerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func record(_ value: Int) {
        lock.lock()
        storedValue += value
        lock.unlock()
    }
}
